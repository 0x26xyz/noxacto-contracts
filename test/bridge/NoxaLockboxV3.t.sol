// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {NoxaLockboxV3} from "../../src/bridge/NoxaLockboxV3.sol";
import {FeeOnTransferNoxa} from "../mocks/FeeOnTransferNoxa.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract NoxaLockboxV3Test is Test {
    NoxaLockboxV3 internal lockbox;
    FeeOnTransferNoxa internal noxa;

    address internal owner = makeAddr("owner"); // cold Safe
    address internal unlocker = makeAddr("unlocker"); // hot relayer key
    address internal noxaOwner = makeAddr("noxaOwner");
    address internal wnoxa = makeAddr("wnoxa");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 constant CAP = 100 ether; // value budget / window
    uint256 constant COUNT = 20; // settlement budget / window
    uint256 constant WINDOW = 1 hours;

    function setUp() public {
        vm.warp(1_700_000_000);
        noxa = new FeeOnTransferNoxa(noxaOwner);
        lockbox = new NoxaLockboxV3(address(noxa), wnoxa, owner, unlocker, CAP, COUNT, WINDOW);
        vm.prank(noxaOwner);
        noxa.transfer(address(lockbox), 100_000 ether);
    }

    // ---- constructor validation ----

    function test_constructor_rejectsZeroBudget() public {
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        new NoxaLockboxV3(address(noxa), wnoxa, owner, unlocker, 0, COUNT, WINDOW);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        new NoxaLockboxV3(address(noxa), wnoxa, owner, unlocker, CAP, 0, WINDOW);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        new NoxaLockboxV3(address(noxa), wnoxa, owner, unlocker, CAP, COUNT, 0);
    }

    function test_constructor_rejectsZeroAddrs() public {
        vm.expectRevert(NoxaLockboxV3.ZeroAddress.selector);
        new NoxaLockboxV3(address(0), wnoxa, owner, unlocker, CAP, COUNT, WINDOW);
        vm.expectRevert(NoxaLockboxV3.ZeroAddress.selector);
        new NoxaLockboxV3(address(noxa), address(0), owner, unlocker, CAP, COUNT, WINDOW);
    }

    // ---- NEW-1: leaky bucket has NO boundary 2x burst ----

    /// The exact round-2 PoC A: spend full budget just before the old window edge,
    /// then try to spend it again a second later. A tumbling window allowed 2x;
    /// the leaky bucket must cap the burst at 1x.
    function test_leakyBucket_noBoundaryDoubleSpend() public {
        // Warp near where a naive window would have reset (window - 1s in).
        vm.warp(block.timestamp + WINDOW - 1);
        vm.prank(unlocker);
        lockbox.unlock(CAP, bob, 0); // full value budget

        // One second later a tumbling window would refill; the bucket has decayed
        // only CAP/WINDOW, so almost nothing is available.
        vm.warp(block.timestamp + 1);
        uint256 leaked = CAP / WINDOW; // ~1s of decay
        vm.expectRevert(
            abi.encodeWithSelector(NoxaLockboxV3.ValueBudgetExceeded.selector, CAP, leaked)
        );
        vm.prank(unlocker);
        lockbox.unlock(CAP, bob, 1);

        // Only the tiny decayed amount is releasable — burst bound == 1x cap.
        vm.prank(unlocker);
        lockbox.unlock(leaked, bob, 1);
        assertEq(noxa.balanceOf(bob), CAP + leaked);
    }

    function test_leakyBucket_fragmentationBounded() public {
        vm.startPrank(unlocker);
        for (uint256 i = 0; i < 10; i++) {
            lockbox.unlock(10 ether, bob, 1000 + i); // 10 * 10 = 100 = CAP, no time passing
        }
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.ValueBudgetExceeded.selector, 1, 0));
        lockbox.unlock(1, bob, 2000);
        vm.stopPrank();
        assertEq(noxa.balanceOf(bob), CAP);
    }

    function test_leakyBucket_fullRefillAfterWindow() public {
        vm.prank(unlocker);
        lockbox.unlock(CAP, bob, 0);
        vm.warp(block.timestamp + WINDOW); // one full window of decay
        vm.prank(unlocker);
        lockbox.unlock(CAP, bob, 1);
        assertEq(noxa.balanceOf(bob), 2 * CAP);
    }

    function test_leakyBucket_partialDecay() public {
        vm.prank(unlocker);
        lockbox.unlock(CAP, bob, 0); // bucket full
        vm.warp(block.timestamp + WINDOW / 4); // 25% decays
        vm.prank(unlocker);
        lockbox.unlock(CAP / 4, bob, 1); // exactly the decayed headroom
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.ValueBudgetExceeded.selector, 1, 0));
        vm.prank(unlocker);
        lockbox.unlock(1, bob, 2);
    }

    // ---- NEW-2: count bucket bounds nonce-griefing ----

    function test_countBucket_boundsSettlementCount() public {
        vm.startPrank(unlocker);
        for (uint256 n = 0; n < COUNT; n++) {
            lockbox.unlock(1, alice, n); // 1 wei each — value budget barely touched
        }
        // The (COUNT+1)th settlement in the window is refused despite huge value headroom.
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.CountBudgetExceeded.selector, COUNT));
        lockbox.unlock(1, alice, COUNT);
        vm.stopPrank();
    }

    function test_countBucket_refillsWithTime() public {
        vm.startPrank(unlocker);
        for (uint256 n = 0; n < COUNT; n++) {
            lockbox.unlock(1, alice, n);
        }
        vm.stopPrank();
        vm.warp(block.timestamp + WINDOW); // fully decays the count bucket
        vm.prank(unlocker);
        lockbox.unlock(1, alice, 100);
        assertTrue(lockbox.processedBurn(100));
    }

    function test_unlock_onlyUnlocker_andNonZero() public {
        vm.expectRevert(NoxaLockboxV3.NotUnlocker.selector);
        vm.prank(alice);
        lockbox.unlock(1 ether, bob, 0);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        vm.prank(unlocker);
        lockbox.unlock(0, bob, 0);
    }

    // ---- NEW-3: batched, pause-first recovery ----

    function test_clearProcessedBurn_single_reopensNonce() public {
        vm.prank(unlocker);
        lockbox.unlock(1 ether, alice, 7); // mis-settled
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.AlreadyProcessed.selector, 7));
        vm.prank(unlocker);
        lockbox.unlock(10 ether, bob, 7);

        vm.expectEmit(true, false, false, false);
        emit NoxaLockboxV3.ProcessedBurnCleared(7);
        vm.prank(owner);
        lockbox.clearProcessedBurn(7);

        vm.prank(owner);
        lockbox.ownerUnlock(10 ether, bob, 7);
        assertEq(noxa.balanceOf(bob), 10 ether);
    }

    /// Tolerant batch: unset + duplicate nonces are skipped, not reverted (round-2 fix).
    function test_clearProcessedBurns_batch_tolerantOfUnsetAndDup() public {
        vm.startPrank(unlocker);
        for (uint256 n = 0; n < 5; n++) {
            lockbox.unlock(1, alice, n);
        }
        vm.stopPrank();
        uint256[] memory nonces = new uint256[](7);
        nonces[0] = 0;
        nonces[1] = 999; // unset — skipped, no revert
        nonces[2] = 1;
        nonces[3] = 0; // duplicate — skipped on 2nd pass
        nonces[4] = 2;
        nonces[5] = 3;
        nonces[6] = 4;
        vm.prank(owner);
        lockbox.clearProcessedBurns(nonces); // must not revert
        for (uint256 i = 0; i < 5; i++) {
            assertFalse(lockbox.processedBurn(i));
        }
    }

    function test_clearProcessedBurnRange_skipsUnset_andHandlesMax() public {
        vm.startPrank(unlocker);
        lockbox.unlock(1, alice, 10);
        lockbox.unlock(1, alice, 12); // 11 left unset
        lockbox.unlock(1, alice, type(uint256).max); // reserved funding-style nonce
        vm.stopPrank();
        vm.prank(owner);
        lockbox.clearProcessedBurnRange(10, 12); // 11 skipped, no revert
        assertFalse(lockbox.processedBurn(10));
        assertFalse(lockbox.processedBurn(12));

        // Range terminating at type(uint256).max must not overflow-revert (round-2).
        vm.prank(owner);
        lockbox.clearProcessedBurnRange(type(uint256).max - 1, type(uint256).max);
        assertFalse(lockbox.processedBurn(type(uint256).max));

        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.BadRange.selector, 5, 4));
        vm.prank(owner);
        lockbox.clearProcessedBurnRange(5, 4);
    }

    /// round-2: lowering the cap below the standing bucket must NOT panic the hot path.
    function test_setCapLower_doesNotBrickHotPath() public {
        vm.prank(unlocker);
        lockbox.unlock(CAP, bob, 0); // valueBucket = CAP (full)
        vm.prank(owner);
        lockbox.setUnlockCapPerWindow(CAP / 2); // tighten below the bucket
        // Next unlock degrades to a clean ValueBudgetExceeded, never Panic(0x11).
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.ValueBudgetExceeded.selector, 1, 0));
        vm.prank(unlocker);
        lockbox.unlock(1, bob, 1);
    }

    /// round-2: rotating the unlocker resets the hot buckets, de-throttling recovery.
    function test_setUnlocker_resetsBuckets() public {
        vm.startPrank(unlocker);
        for (uint256 n = 0; n < COUNT; n++) {
            lockbox.unlock(1, alice, n); // fill the count bucket
        }
        vm.stopPrank();
        assertEq(lockbox.countBucket(), COUNT);

        address newKey = makeAddr("newUnlocker");
        vm.prank(owner);
        lockbox.setUnlocker(newKey); // rotation resets buckets
        assertEq(lockbox.valueBucket(), 0);
        assertEq(lockbox.countBucket(), 0);

        // The new key can settle immediately — not stalled by the old key's usage.
        vm.prank(newKey);
        lockbox.unlock(CAP, bob, 1000);
        assertEq(noxa.balanceOf(bob), CAP);
    }

    function test_clear_ownerOnly_andMustBeSet() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        lockbox.clearProcessedBurn(1);
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.NotProcessed.selector, 1));
        vm.prank(owner);
        lockbox.clearProcessedBurn(1);
    }

    /// pause() blocks the hot key so recovery (pause -> clear) can't be re-bricked.
    function test_pauseFirst_recoveryIsSafe() public {
        vm.prank(unlocker);
        lockbox.unlock(1, alice, 42);
        vm.prank(owner);
        lockbox.pause();
        // Attacker (leaked hot key) cannot re-consume while paused.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(unlocker);
        lockbox.unlock(1, alice, 42);
        // Owner clears + settles via the un-pausable owner path.
        vm.prank(owner);
        lockbox.clearProcessedBurn(42);
        vm.prank(owner);
        lockbox.ownerUnlock(5 ether, bob, 42);
        assertEq(noxa.balanceOf(bob), 5 ether);
    }

    // ---- shared replay guard + owner path ----

    function test_ownerUnlock_uncapped_bypassesBucketsAndPause() public {
        vm.prank(owner);
        lockbox.pause();
        vm.prank(owner);
        lockbox.ownerUnlock(50_000 ether, bob, 0); // >> value cap, while paused
        assertEq(noxa.balanceOf(bob), 50_000 ether);
        // shares the replay guard with the hot path
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxV3.AlreadyProcessed.selector, 0));
        vm.prank(owner);
        lockbox.ownerUnlock(1 ether, bob, 0);
    }

    // ---- lock (fee-on-transfer safe) ----

    function test_lock_feeOnTransferSafe() public {
        vm.prank(noxaOwner);
        noxa.transfer(alice, 1_000 ether);
        vm.prank(noxaOwner);
        noxa.setFee(500); // 5%
        vm.startPrank(alice);
        noxa.approve(address(lockbox), 1_000 ether);
        (, uint256 received) = lockbox.lock(1_000 ether, alice);
        vm.stopPrank();
        assertEq(received, 950 ether);
    }

    // ---- rescueToken ----

    function test_rescueToken_blocksNoxa_guardsZero_allowsOthers() public {
        vm.expectRevert(NoxaLockboxV3.CannotRescueCollateral.selector);
        vm.prank(owner);
        lockbox.rescueToken(address(noxa), owner, 1 ether);

        MockERC20 stray = new MockERC20("STRAY", "STR", 18);
        stray.mint(address(lockbox), 5 ether);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        vm.prank(owner);
        lockbox.rescueToken(address(stray), bob, 0);
        vm.prank(owner);
        lockbox.rescueToken(address(stray), bob, 5 ether);
        assertEq(stray.balanceOf(bob), 5 ether);
    }

    // ---- setters ----

    function test_setters_validateAndEmit() public {
        vm.startPrank(owner);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        lockbox.setUnlockCapPerWindow(0);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        lockbox.setUnlockCountPerWindow(0);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        lockbox.setUnlockWindow(0);
        lockbox.setUnlockCapPerWindow(50 ether);
        lockbox.setUnlockCountPerWindow(5);
        lockbox.setUnlockWindow(30 minutes);
        lockbox.setUnlocker(address(0));
        vm.stopPrank();
        assertEq(lockbox.unlockCapPerWindow(), 50 ether);
        assertEq(lockbox.unlockCountPerWindow(), 5);
        assertEq(lockbox.unlockWindow(), 30 minutes);
        assertEq(lockbox.unlocker(), address(0));
    }

    function test_renounce_disabled() public {
        vm.expectRevert(NoxaLockboxV3.RenounceDisabled.selector);
        vm.prank(owner);
        lockbox.renounceOwnership();
    }

    function test_lock_zeroGuards() public {
        vm.startPrank(alice);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        lockbox.lock(0, alice);
        vm.expectRevert(NoxaLockboxV3.ZeroAddress.selector);
        lockbox.lock(1 ether, address(0));
        vm.stopPrank();
    }

    function test_release_zeroGuards() public {
        vm.startPrank(owner);
        vm.expectRevert(NoxaLockboxV3.ZeroAmount.selector);
        lockbox.ownerUnlock(0, bob, 0);
        vm.expectRevert(NoxaLockboxV3.ZeroAddress.selector);
        lockbox.ownerUnlock(1 ether, address(0), 0);
        vm.stopPrank();
    }

    function test_unpause_restoresHotPath() public {
        vm.prank(owner);
        lockbox.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(unlocker);
        lockbox.unlock(1 ether, bob, 0);
        vm.prank(owner);
        lockbox.unpause();
        vm.prank(unlocker);
        lockbox.unlock(1 ether, bob, 0);
        assertEq(noxa.balanceOf(bob), 1 ether);
    }

    function test_freshBox_hasCleanReplayMap() public view {
        assertFalse(lockbox.processedBurn(0));
        assertEq(lockbox.wrappedNoxa(), wnoxa);
    }

    // ---- fuzz: the leaky-bucket invariant (level never exceeds cap) ----

    /// The fundamental leaky-bucket guarantee, which is exactly what refutes the
    /// tumbling-window "2x in one second" bug: after ANY interleaving of unlocks
    /// and time gaps, the value/count bucket levels never exceed their caps — so no
    /// single instant can release more than one cap (adjacent same-instant releases
    /// sum to <= cap). Sustained rate is cap/window; there is no boundary to double.
    function testFuzz_bucketLevelsNeverExceedCap(uint256[10] calldata amounts, uint32[10] calldata gaps) public {
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + (gaps[i] % (2 hours)));
            uint256 a = 1 + (amounts[i] % (CAP * 2)); // may exceed remaining -> reverts, skipped

            uint256 elapsed = block.timestamp - lockbox.lastUnlockAt();
            uint256 vLeaked = (elapsed * CAP) / WINDOW;
            uint256 vUsed = lockbox.valueBucket() > vLeaked ? lockbox.valueBucket() - vLeaked : 0;
            uint256 cLeaked = (elapsed * COUNT) / WINDOW;
            uint256 cUsed = lockbox.countBucket() > cLeaked ? lockbox.countBucket() - cLeaked : 0;
            if (a > CAP - vUsed || cUsed + 1 > COUNT) continue; // would revert

            vm.prank(unlocker);
            lockbox.unlock(a, bob, 6000 + i);

            // Post-condition: neither bucket ever sits above its cap.
            assertLe(lockbox.valueBucket(), CAP);
            assertLe(lockbox.countBucket(), COUNT);
        }
    }
}
