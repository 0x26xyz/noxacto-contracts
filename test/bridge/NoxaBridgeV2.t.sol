// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";

import {WrappedNoxa} from "../../src/bridge/WrappedNoxa.sol";
import {WrappedNoxaV2} from "../../src/bridge/WrappedNoxaV2.sol";
import {NoxaLockboxV2} from "../../src/bridge/NoxaLockboxV2.sol";
import {WNoxaMigrator} from "../../src/bridge/WNoxaMigrator.sol";
import {FeeOnTransferNoxa} from "../mocks/FeeOnTransferNoxa.sol";

contract NoxaBridgeV2Test is Test {
    uint256 constant CAP = 1_000_000 ether;

    WrappedNoxaV2 internal wnoxa;
    NoxaLockboxV2 internal lockbox;
    FeeOnTransferNoxa internal noxa;

    address internal owner = makeAddr("owner"); // cold Safe stand-in
    address internal minter = makeAddr("minter"); // hot relayer key (RH mint)
    address internal unlocker = makeAddr("unlocker"); // hot relayer key (DBK unlock)
    address internal noxaOwner = makeAddr("noxaOwner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        // Realistic wall clock: Foundry defaults block.timestamp to 1, which would
        // make the very first hot unlock trip the cooldown (lastUnlockAt 0 + cooldown).
        // On mainnet the clock is ~1.7e9 so 0 + cooldown is decades past — first
        // unlock always passes. Warp so tests exercise the real behaviour.
        vm.warp(1_700_000_000);

        wnoxa = new WrappedNoxaV2(owner, CAP);
        vm.prank(owner);
        wnoxa.setMinter(minter, true);

        noxa = new FeeOnTransferNoxa(noxaOwner);
        lockbox = new NoxaLockboxV2(address(noxa), owner, unlocker, 100 ether, 1 hours);
        vm.prank(noxaOwner);
        noxa.transfer(address(lockbox), 10_000 ether); // seed collateral for unlock tests
    }

    // =======================================================================
    // WrappedNoxaV2
    // =======================================================================

    function test_wnoxa_constructor_rejectsZeroCap() public {
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20InvalidCap.selector, 0));
        new WrappedNoxaV2(owner, 0);
    }

    function test_wnoxa_constructor_rejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new WrappedNoxaV2(address(0), CAP);
    }

    function test_mint_onlyMinter() public {
        vm.expectRevert(WrappedNoxaV2.NotMinter.selector);
        vm.prank(alice);
        wnoxa.mint(alice, 1 ether, 0);

        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 0);
        assertEq(wnoxa.balanceOf(alice), 1 ether);
    }

    function test_mint_replayGuard() public {
        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 7);
        vm.expectRevert(abi.encodeWithSelector(WrappedNoxaV2.AlreadyProcessed.selector, 7));
        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 7);
    }

    function test_mint_respectsCap() public {
        vm.prank(minter);
        wnoxa.mint(alice, CAP, 0); // exactly the cap is fine
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, CAP + 1, CAP));
        vm.prank(minter);
        wnoxa.mint(alice, 1, 1);
    }

    function test_setMinter_ownerOnly_andRevoke() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wnoxa.setMinter(bob, true);

        vm.prank(owner);
        wnoxa.setMinter(minter, false); // revoke a leaked key
        vm.expectRevert(WrappedNoxaV2.NotMinter.selector);
        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 0);
    }

    function test_pause_freezesMintBurnTransfer() public {
        vm.prank(minter);
        wnoxa.mint(alice, 10 ether, 0);

        vm.prank(owner);
        wnoxa.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(minter);
        wnoxa.mint(alice, 1 ether, 1);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        wnoxa.transfer(bob, 1 ether);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        wnoxa.burnForReturn(1 ether, bob);

        vm.prank(owner);
        wnoxa.unpause();
        vm.prank(alice);
        wnoxa.transfer(bob, 1 ether); // flows again
        assertEq(wnoxa.balanceOf(bob), 1 ether);
    }

    function test_burnForReturn_incrementsNonce() public {
        vm.prank(minter);
        wnoxa.mint(alice, 10 ether, 0);
        vm.startPrank(alice);
        uint256 n0 = wnoxa.burnForReturn(1 ether, bob);
        uint256 n1 = wnoxa.burnForReturn(1 ether, bob);
        vm.stopPrank();
        assertEq(n0, 0);
        assertEq(n1, 1);
        assertEq(wnoxa.balanceOf(alice), 8 ether);
    }

    function test_renounce_disabled() public {
        vm.expectRevert(WrappedNoxaV2.RenounceDisabled.selector);
        vm.prank(owner);
        wnoxa.renounceOwnership();
    }

    // =======================================================================
    // NoxaLockboxV2
    // =======================================================================

    function test_unlock_onlyUnlocker() public {
        vm.expectRevert(NoxaLockboxV2.NotUnlocker.selector);
        vm.prank(alice);
        lockbox.unlock(1 ether, bob, 0);

        vm.prank(unlocker);
        lockbox.unlock(1 ether, bob, 0);
        assertEq(noxa.balanceOf(bob), 1 ether);
    }

    function test_unlock_capEnforced() public {
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV2.AboveUnlockCap.selector, 101 ether, 100 ether));
        vm.prank(unlocker);
        lockbox.unlock(101 ether, bob, 0);
    }

    function test_unlock_cooldownEnforced() public {
        vm.prank(unlocker);
        lockbox.unlock(100 ether, bob, 0);

        uint256 readyAt = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV2.CooldownActive.selector, readyAt));
        vm.prank(unlocker);
        lockbox.unlock(100 ether, bob, 1);

        vm.warp(readyAt);
        vm.prank(unlocker);
        lockbox.unlock(100 ether, bob, 1); // cooldown elapsed
        assertEq(noxa.balanceOf(bob), 200 ether);
    }

    function test_unlock_replayGuard() public {
        vm.prank(unlocker);
        lockbox.unlock(10 ether, bob, 5);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV2.AlreadyProcessed.selector, 5));
        vm.prank(unlocker);
        lockbox.unlock(10 ether, bob, 5);
    }

    function test_pause_freezesHotUnlock_butOwnerCanStillExit() public {
        vm.prank(owner);
        lockbox.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(unlocker);
        lockbox.unlock(1 ether, bob, 0);

        // Owner path is uncapped AND not pausable — exits always serviceable.
        vm.prank(owner);
        lockbox.ownerUnlock(5_000 ether, bob, 0); // > unlockCap, while paused
        assertEq(noxa.balanceOf(bob), 5_000 ether);
    }

    function test_ownerUnlock_ownerOnly_andSharesReplayNonce() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unlocker));
        vm.prank(unlocker);
        lockbox.ownerUnlock(1 ether, bob, 9);

        vm.prank(owner);
        lockbox.ownerUnlock(1 ether, bob, 9);
        // A hot unlock can't reuse a nonce the owner already settled.
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV2.AlreadyProcessed.selector, 9));
        vm.prank(unlocker);
        lockbox.unlock(1 ether, bob, 9);
    }

    function test_lock_feeOnTransferSafe() public {
        vm.prank(noxaOwner);
        noxa.transfer(alice, 1_000 ether);
        vm.prank(noxaOwner);
        noxa.setFee(500); // 5%

        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        (, uint256 received) = lockbox.lock(1_000 ether, alice);
        vm.stopPrank();
        assertEq(received, 950 ether); // credited the actual received, not requested
    }

    function test_lockbox_renounce_disabled() public {
        vm.expectRevert(NoxaLockboxV2.RenounceDisabled.selector);
        vm.prank(owner);
        lockbox.renounceOwnership();
    }

    // =======================================================================
    // WNoxaMigrator — escrow old, mint new 1:1
    // =======================================================================

    function _deployMigration() internal returns (WrappedNoxa oldT, WNoxaMigrator mig) {
        oldT = new WrappedNoxa(owner); // real prior-version token
        mig = new WNoxaMigrator(address(oldT), address(wnoxa), owner);
        vm.prank(owner);
        wnoxa.setMinter(address(mig), true); // grant migrator mint rights for cutover
        // Give alice some OLD wNOXA to migrate.
        vm.prank(owner);
        oldT.mint(alice, 100 ether, 0);
    }

    function test_migrate_escrowsOldAndMintsNew1to1() public {
        (WrappedNoxa oldT, WNoxaMigrator mig) = _deployMigration();

        vm.startPrank(alice);
        oldT.approve(address(mig), 40 ether);
        uint256 minted = mig.migrate(40 ether);
        vm.stopPrank();

        assertEq(minted, 40 ether);
        assertEq(wnoxa.balanceOf(alice), 40 ether); // got new
        assertEq(oldT.balanceOf(alice), 60 ether); // spent old
        assertEq(oldT.balanceOf(address(mig)), 40 ether); // ESCROWED, not burned
        assertEq(oldT.totalSupply(), 100 ether); // old supply unchanged (no burn => no collateral release)
        assertEq(mig.totalMigrated(), 40 ether);
    }

    function test_migrate_requiresMinterRole() public {
        WrappedNoxa oldT = new WrappedNoxa(owner);
        WNoxaMigrator mig = new WNoxaMigrator(address(oldT), address(wnoxa), owner);
        // NOTE: deliberately NOT granting minter role.
        vm.prank(owner);
        oldT.mint(alice, 10 ether, 0);

        vm.startPrank(alice);
        oldT.approve(address(mig), 10 ether);
        vm.expectRevert(WrappedNoxaV2.NotMinter.selector);
        mig.migrate(10 ether);
        vm.stopPrank();
    }

    function test_migrate_cannotMintMoreNewThanOldEscrowed() public {
        (WrappedNoxa oldT, WNoxaMigrator mig) = _deployMigration();
        // Alice tries to migrate more than she holds -> old transfer reverts, nothing minted.
        vm.startPrank(alice);
        oldT.approve(address(mig), 200 ether);
        vm.expectRevert(); // ERC20InsufficientBalance on the old token
        mig.migrate(200 ether);
        vm.stopPrank();
        assertEq(wnoxa.totalSupply(), 0);
    }

    function test_sweepEscrow_ownerOnly() public {
        (WrappedNoxa oldT, WNoxaMigrator mig) = _deployMigration();
        vm.startPrank(alice);
        oldT.approve(address(mig), 40 ether);
        mig.migrate(40 ether);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        mig.sweepEscrow(alice, 40 ether);

        // Owner sweeps escrowed old wNOXA (to reconcile collateral via the old bridge).
        vm.prank(owner);
        mig.sweepEscrow(owner, 40 ether);
        assertEq(oldT.balanceOf(owner), 40 ether);
        assertEq(oldT.balanceOf(address(mig)), 0);
    }

    function test_migrate_pausable() public {
        (WrappedNoxa oldT, WNoxaMigrator mig) = _deployMigration();
        vm.prank(owner);
        mig.pause();
        vm.startPrank(alice);
        oldT.approve(address(mig), 10 ether);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mig.migrate(10 ether);
        vm.stopPrank();
    }

    function test_migrate_respectsNewTokenCap() public {
        // Deploy a new token with a tiny cap, then try to migrate beyond it.
        WrappedNoxaV2 capped = new WrappedNoxaV2(owner, 30 ether);
        WrappedNoxa oldT = new WrappedNoxa(owner);
        WNoxaMigrator mig = new WNoxaMigrator(address(oldT), address(capped), owner);
        vm.prank(owner);
        capped.setMinter(address(mig), true);
        vm.prank(owner);
        oldT.mint(alice, 100 ether, 0);

        vm.startPrank(alice);
        oldT.approve(address(mig), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(ERC20Capped.ERC20ExceededCap.selector, 40 ether, 30 ether));
        mig.migrate(40 ether); // would push new supply past its cap
        vm.stopPrank();
    }
}
