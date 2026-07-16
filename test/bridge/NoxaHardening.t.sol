// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {NoxaLockbox} from "../../src/bridge/NoxaLockbox.sol";
import {WrappedNoxa} from "../../src/bridge/WrappedNoxa.sol";

/// @dev Malicious source token: on `transferFrom` it re-enters the lockbox's
/// `lock`, simulating a reentrancy attack from a hostile fee-on-transfer token.
contract ReentrantNoxa is ERC20 {
    NoxaLockbox public target;
    bool internal arming;

    constructor() ERC20("Reentrant NOXA", "rNOXA") {
        _mint(msg.sender, 1_000 ether);
    }

    function setTarget(NoxaLockbox t) external {
        target = t;
    }

    function arm() external {
        arming = true;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool ok) {
        ok = super.transferFrom(from, to, value);
        if (arming) {
            arming = false;
            // Re-enter while the outer lock() still holds the ReentrancyGuard.
            target.lock(1 ether, address(0xBEEF));
        }
    }
}

contract NoxaHardeningTest is Test {
    address internal authority = makeAddr("authority");
    address internal alice = makeAddr("alice");

    // ---- Reentrancy ----

    function test_lock_blocksReentrancy() public {
        ReentrantNoxa rt = new ReentrantNoxa(); // mints 1000 to this test contract
        NoxaLockbox lb = new NoxaLockbox(address(rt), authority);
        rt.setTarget(lb);
        rt.transfer(alice, 100 ether);

        vm.startPrank(alice);
        rt.approve(address(lb), type(uint256).max);
        vm.stopPrank();

        // Arm the reentrancy, then a lock() must revert wholesale (guard trips).
        rt.arm();
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        lb.lock(10 ether, alice);

        // Nothing was locked; no partial state.
        assertEq(rt.balanceOf(address(lb)), 0);
        assertEq(lb.lockNonce(), 0);
    }

    // ---- renounceOwnership disabled (would otherwise freeze all funds) ----

    function test_lockbox_renounceOwnership_disabled() public {
        ERC20 noxa = new ReentrantNoxa();
        NoxaLockbox lb = new NoxaLockbox(address(noxa), authority);
        vm.prank(authority);
        vm.expectRevert(NoxaLockbox.RenounceDisabled.selector);
        lb.renounceOwnership();
        assertEq(lb.owner(), authority); // ownership intact
    }

    function test_wnoxa_renounceOwnership_disabled() public {
        WrappedNoxa w = new WrappedNoxa(authority);
        vm.prank(authority);
        vm.expectRevert(WrappedNoxa.RenounceDisabled.selector);
        w.renounceOwnership();
        assertEq(w.owner(), authority);
    }

    /// @dev The 2-step ownership handoff (e.g. to a Safe) still works — only the
    /// one-step renounce footgun is removed.
    function test_transferOwnership_twoStep_stillWorks() public {
        WrappedNoxa w = new WrappedNoxa(authority);
        address safe = makeAddr("safe");
        vm.prank(authority);
        w.transferOwnership(safe);
        assertEq(w.owner(), authority); // not yet — pending
        vm.prank(safe);
        w.acceptOwnership();
        assertEq(w.owner(), safe);
    }
}
