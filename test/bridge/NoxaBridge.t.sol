// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {NoxaLockbox} from "../../src/bridge/NoxaLockbox.sol";
import {WrappedNoxa} from "../../src/bridge/WrappedNoxa.sol";
import {FeeOnTransferNoxa} from "../mocks/FeeOnTransferNoxa.sol";

contract NoxaBridgeTest is Test {
    FeeOnTransferNoxa internal noxa;
    NoxaLockbox internal lockbox;
    WrappedNoxa internal wnoxa;

    address internal authority = makeAddr("authority"); // multisig stand-in
    address internal noxaOwner = makeAddr("noxaOwner"); // source-token owner (hostile-capable)
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        noxa = new FeeOnTransferNoxa(noxaOwner);
        lockbox = new NoxaLockbox(address(noxa), authority);
        wnoxa = new WrappedNoxa(authority);

        // Fund alice with real NOXA to bridge (no fee on this seeding transfer path
        // because we set fee after). Move from owner via a fee-free window.
        vm.prank(noxaOwner);
        noxa.transfer(alice, 10_000 ether);
    }

    // ---------------------------------------------------------------------
    // Constructors
    // ---------------------------------------------------------------------

    function test_lockbox_constructor_rejectsZeroNoxa() public {
        vm.expectRevert(NoxaLockbox.ZeroAddress.selector);
        new NoxaLockbox(address(0), authority);
    }

    function test_lockbox_constructor_rejectsZeroAuthority() public {
        // Ownable base guards the authority (runs before the derived body).
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new NoxaLockbox(address(noxa), address(0));
    }

    function test_wnoxa_constructor_rejectsZeroAuthority() public {
        // Ownable(address(0)) reverts first in the base constructor.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WrappedNoxa(address(0));
    }

    // ---------------------------------------------------------------------
    // Inbound: lock (DBK) -> mint (RH)
    // ---------------------------------------------------------------------

    function test_lock_noFee_recordsFullAmount() public {
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        (uint256 nonce, uint256 received) = lockbox.lock(1_000 ether, alice);
        vm.stopPrank();

        assertEq(nonce, 0);
        assertEq(received, 1_000 ether);
        assertEq(noxa.balanceOf(address(lockbox)), 1_000 ether);
    }

    function test_lock_feeOnTransfer_recordsReceivedNotRequested() public {
        vm.prank(noxaOwner);
        noxa.setFee(500); // 5%

        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        (, uint256 received) = lockbox.lock(1_000 ether, alice);
        vm.stopPrank();

        // 5% tax => lockbox actually receives 950; that is what must be minted.
        assertEq(received, 950 ether);
        assertEq(noxa.balanceOf(address(lockbox)), 950 ether);
    }

    function test_lock_hostileFullFee_reverts() public {
        vm.prank(noxaOwner);
        noxa.setFee(10_000); // 100% — nothing arrives

        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        vm.expectRevert(NoxaLockbox.NothingReceived.selector);
        lockbox.lock(1_000 ether, alice);
        vm.stopPrank();
    }

    function test_lock_reverts_onZeroAmountOrRecipient() public {
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        vm.expectRevert(NoxaLockbox.ZeroAmount.selector);
        lockbox.lock(0, alice);
        vm.expectRevert(NoxaLockbox.ZeroAddress.selector);
        lockbox.lock(1_000 ether, address(0));
        vm.stopPrank();
    }

    function test_lock_whenPaused_reverts() public {
        vm.prank(authority);
        lockbox.pause();
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        lockbox.lock(1_000 ether, alice);
        vm.stopPrank();
    }

    function test_mint_onlyAuthority_andIdempotent() public {
        // relayer settles lock nonce 7 for alice with 950 wNOXA
        vm.prank(authority);
        wnoxa.mint(alice, 950 ether, 7);
        assertEq(wnoxa.balanceOf(alice), 950 ether);
        assertEq(wnoxa.totalSupply(), 950 ether);

        // replay of the same nonce is rejected
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxa.AlreadyProcessed.selector, uint256(7)));
        wnoxa.mint(alice, 950 ether, 7);

        // non-authority cannot mint
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wnoxa.mint(alice, 1 ether, 8);
    }

    function test_mint_reverts_onZeroInputs() public {
        vm.startPrank(authority);
        vm.expectRevert(WrappedNoxa.ZeroAddress.selector);
        wnoxa.mint(address(0), 1 ether, 1);
        vm.expectRevert(WrappedNoxa.ZeroAmount.selector);
        wnoxa.mint(alice, 0, 1);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Outbound: burn (RH) -> unlock (DBK)
    // ---------------------------------------------------------------------

    function test_burnForReturn_emitsNonceAndBurns() public {
        vm.prank(authority);
        wnoxa.mint(alice, 1_000 ether, 0);

        vm.prank(alice);
        uint256 nonce = wnoxa.burnForReturn(400 ether, alice);
        assertEq(nonce, 0);
        assertEq(wnoxa.balanceOf(alice), 600 ether);
        assertEq(wnoxa.totalSupply(), 600 ether);
    }

    function test_unlock_onlyAuthority_idempotent_releasesCollateral() public {
        // Seed lockbox with collateral via a real lock.
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        lockbox.lock(1_000 ether, alice);
        vm.stopPrank();

        uint256 bobBefore = noxa.balanceOf(bob);
        vm.prank(authority);
        lockbox.unlock(400 ether, bob, 0);
        assertEq(noxa.balanceOf(bob) - bobBefore, 400 ether);

        // replay of the same RH burn nonce is rejected
        vm.prank(authority);
        vm.expectRevert(abi.encodeWithSelector(NoxaLockbox.AlreadyProcessed.selector, uint256(0)));
        lockbox.unlock(400 ether, bob, 0);

        // non-authority cannot unlock
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        lockbox.unlock(1 ether, bob, 1);
    }

    function test_pause_unpause_reopensLocks() public {
        vm.prank(authority);
        lockbox.pause();
        vm.prank(authority);
        lockbox.unpause();

        vm.startPrank(alice);
        noxa.approve(address(lockbox), 100 ether);
        (, uint256 received) = lockbox.lock(100 ether, alice);
        vm.stopPrank();
        assertEq(received, 100 ether);
    }

    function test_unlock_worksWhilePaused() public {
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        lockbox.lock(1_000 ether, alice);
        vm.stopPrank();

        vm.prank(authority);
        lockbox.pause();

        vm.prank(authority);
        lockbox.unlock(100 ether, bob, 0); // exits stay open under pause
        assertEq(noxa.balanceOf(bob), 100 ether);
    }

    // ---------------------------------------------------------------------
    // Round-trip peg + collateralization invariant
    // ---------------------------------------------------------------------

    /// @dev Full round trip under a live fee, asserting the collateralization
    /// invariant `NOXA.balanceOf(lockbox) >= wNOXA.totalSupply()` holds at each step.
    function test_roundTrip_keepsCollateralCovered() public {
        vm.prank(noxaOwner);
        noxa.setFee(300); // 3%

        // Inbound: alice locks 1000 -> 970 received -> 970 wNOXA minted.
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        (uint256 lockN, uint256 received) = lockbox.lock(1_000 ether, alice);
        vm.stopPrank();
        assertEq(received, 970 ether);

        vm.prank(authority);
        wnoxa.mint(alice, received, lockN);
        _assertCovered();

        // Outbound: alice burns 970 -> authority unlocks 970 from the box.
        vm.prank(alice);
        uint256 burnN = wnoxa.burnForReturn(received, alice);
        _assertCovered(); // supply dropped first; still covered

        vm.prank(authority);
        lockbox.unlock(received, alice, burnN);
        _assertCovered();

        assertEq(wnoxa.totalSupply(), 0);
        assertEq(noxa.balanceOf(address(lockbox)), 0);
    }

    function testFuzz_lock_neverMintsMoreThanReceived(uint256 amount, uint16 feeBps) public {
        amount = bound(amount, 1, 10_000 ether);
        feeBps = uint16(bound(feeBps, 0, 9_999)); // exclude 100% (would revert)

        vm.prank(noxaOwner);
        noxa.setFee(feeBps);

        uint256 bal0 = noxa.balanceOf(address(lockbox));
        vm.startPrank(alice);
        noxa.approve(address(lockbox), amount);
        uint256 aliceBal = noxa.balanceOf(alice);
        if (amount > aliceBal) {
            vm.expectRevert();
            lockbox.lock(amount, alice);
            vm.stopPrank();
            return;
        }
        try lockbox.lock(amount, alice) returns (uint256, uint256 received) {
            uint256 actualDelta = noxa.balanceOf(address(lockbox)) - bal0;
            assertEq(received, actualDelta);
            assertLe(received, amount);
        } catch {
            // full-fee edge => NothingReceived
        }
        vm.stopPrank();
    }

    function _assertCovered() internal view {
        assertGe(noxa.balanceOf(address(lockbox)), wnoxa.totalSupply());
    }
}
