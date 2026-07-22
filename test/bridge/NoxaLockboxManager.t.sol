// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {NoxaLockboxManager} from "../../src/bridge/NoxaLockboxManager.sol";
import {NoxaShardedBox} from "../../src/bridge/NoxaShardedBox.sol";
import {MaxWalletNoxa} from "../mocks/MaxWalletNoxa.sol";

contract NoxaLockboxManagerTest is Test {
    MaxWalletNoxa internal noxa;
    NoxaLockboxManager internal mgr;

    address internal owner = makeAddr("owner"); // cold Safe
    address internal unlocker = makeAddr("unlocker"); // hot relayer key
    address internal noxaOwner = makeAddr("noxaOwner"); // NOXA owner/faucet (excluded)
    address internal wnoxa = makeAddr("wnoxa");
    address internal bob = makeAddr("bob"); // DBK redemption recipient (capped)

    uint256 constant CAP = 25_000 ether; // NOXA max-wallet cap == maxBoxAmount
    uint256 constant VCAP = 25_000 ether; // hot value budget / window
    uint256 constant CCAP = 1000; // hot count budget / window
    uint256 constant WINDOW = 600;

    function setUp() public {
        vm.warp(1_700_000_000);
        noxa = new MaxWalletNoxa(noxaOwner, CAP, 1_000_000 ether);
        mgr = new NoxaLockboxManager(address(noxa), wnoxa, owner, unlocker, CAP, VCAP, CCAP, WINDOW);
        // A funded "faucet" that stands in for many users (excluded FIRST so it
        // can hold and lock arbitrary aggregate amounts through the manager).
        vm.prank(noxaOwner);
        noxa.setExcluded(address(this), true);
        vm.prank(noxaOwner);
        noxa.transfer(address(this), 500_000 ether);
        noxa.approve(address(mgr), type(uint256).max);
    }

    function _lock(uint256 amount, address rhRecipient) internal returns (uint256 nonce, uint256 received) {
        return mgr.lock(amount, rhRecipient);
    }

    // ---- lock routing keeps every shard under the source cap ----

    function test_lock_singleDepositSpawnsFirstBox() public {
        (uint256 nonce, uint256 received) = _lock(10_000 ether, bob);
        assertEq(nonce, 0);
        assertEq(received, 10_000 ether);
        assertEq(mgr.boxCount(), 1);
        assertEq(noxa.balanceOf(mgr.boxes(0)), 10_000 ether);
        assertEq(mgr.totalCollateral(), 10_000 ether);
        assertEq(noxa.balanceOf(address(mgr)), 0); // manager never holds NOXA between calls
    }

    function test_lock_fillsThenSpawns_neverExceedsCap() public {
        // 7 x 10k = 70k across boxes; each box must stay <= 25k or the mock reverts.
        for (uint256 i = 0; i < 7; i++) {
            _lock(10_000 ether, bob);
        }
        assertEq(mgr.totalCollateral(), 70_000 ether);
        uint256 n = mgr.boxCount();
        assertGe(n, 3); // 70k / 25k -> at least 3 boxes
        for (uint256 i = 0; i < n; i++) {
            assertLe(noxa.balanceOf(mgr.boxes(i)), CAP); // invariant: no shard over cap
        }
    }

    function test_lock_fullCapDepositAlwaysFitsAFreshBox() public {
        _lock(CAP, bob); // 25k into box0 (fresh, exactly the cap)
        assertEq(noxa.balanceOf(mgr.boxes(0)), CAP);
        _lock(CAP, bob); // box0 full -> spawn box1
        assertEq(mgr.boxCount(), 2);
        assertEq(noxa.balanceOf(mgr.boxes(1)), CAP);
    }

    function test_lock_globalNoncesIncrement() public {
        (uint256 n0,) = _lock(1_000 ether, bob);
        (uint256 n1,) = _lock(1_000 ether, bob);
        assertEq(n0, 0);
        assertEq(n1, 1);
    }

    function test_lock_zeroGuards() public {
        vm.expectRevert(NoxaLockboxManager.ZeroAmount.selector);
        mgr.lock(0, bob);
        vm.expectRevert(NoxaLockboxManager.ZeroAddress.selector);
        mgr.lock(1 ether, address(0));
    }

    // ---- unlock drains oldest-shard-first, across shards ----

    function test_unlock_singleShard() public {
        _lock(10_000 ether, bob); // box0 = 10k
        vm.prank(unlocker);
        mgr.unlock(4_000 ether, bob, 0);
        assertEq(noxa.balanceOf(bob), 4_000 ether);
        assertEq(noxa.balanceOf(mgr.boxes(0)), 6_000 ether);
    }

    function test_unlock_drainsAcrossTwoShards() public {
        _lock(CAP, bob); // box0 = 25k
        _lock(5_000 ether, bob); // box1 = 5k (box0 full)
        assertEq(mgr.boxCount(), 2);

        // Redeem 20k to a FRESH recipient (capped at 25k, so 20k is fine): all from box0.
        address r1 = makeAddr("r1");
        vm.prank(unlocker);
        mgr.unlock(20_000 ether, r1, 0);
        assertEq(noxa.balanceOf(r1), 20_000 ether);
        assertEq(noxa.balanceOf(mgr.boxes(0)), 5_000 ether); // 25k - 20k

        // Redeem 8k: 5k left in box0 (oldest) + 3k from box1 -> two shards.
        // (warp a window so the leaky-bucket value budget isn't the thing under test)
        vm.warp(block.timestamp + WINDOW);
        address r2 = makeAddr("r2");
        vm.prank(unlocker);
        mgr.unlock(8_000 ether, r2, 1);
        assertEq(noxa.balanceOf(r2), 8_000 ether);
        assertEq(noxa.balanceOf(mgr.boxes(0)), 0); // box0 drained
        assertEq(noxa.balanceOf(mgr.boxes(1)), 2_000 ether); // 5k - 3k
    }

    function test_unlock_insufficientCollateralReverts() public {
        _lock(3_000 ether, bob);
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.InsufficientCollateral.selector, 5_000 ether, 3_000 ether));
        vm.prank(unlocker);
        mgr.unlock(5_000 ether, bob, 0);
    }

    function test_unlock_replayGuard_sharedHotCold() public {
        _lock(10_000 ether, bob);
        vm.prank(unlocker);
        mgr.unlock(1_000 ether, bob, 7);
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.AlreadyProcessed.selector, 7));
        vm.prank(unlocker);
        mgr.unlock(1_000 ether, bob, 7);
        // owner path shares the same guard
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.AlreadyProcessed.selector, 7));
        vm.prank(owner);
        mgr.ownerUnlock(1_000 ether, bob, 7);
    }

    function test_unlock_onlyUnlocker() public {
        _lock(1_000 ether, bob);
        vm.expectRevert(NoxaLockboxManager.NotUnlocker.selector);
        vm.prank(bob);
        mgr.unlock(1 ether, bob, 0);
    }

    // ---- rate limit (dual leaky bucket, carried from V3) ----

    function test_unlock_valueBudget_boundsAndRefills() public {
        _lock(CAP, bob);
        _lock(CAP, bob); // 50k across two boxes
        address r = makeAddr("rr");
        vm.prank(unlocker);
        mgr.unlock(VCAP, r, 0); // exhaust value budget (25k)
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.ValueBudgetExceeded.selector, 1 ether, 0));
        vm.prank(unlocker);
        mgr.unlock(1 ether, r, 1);
        vm.warp(block.timestamp + WINDOW); // full refill
        address r2 = makeAddr("rr2");
        vm.prank(unlocker);
        mgr.unlock(VCAP, r2, 2);
        assertEq(noxa.balanceOf(r2), VCAP);
    }

    function test_unlock_leakyBucket_noBoundaryDoubleSpend() public {
        _lock(CAP, bob);
        _lock(CAP, bob);
        vm.warp(block.timestamp + WINDOW - 1);
        address r = makeAddr("r");
        vm.prank(unlocker);
        mgr.unlock(VCAP, r, 0); // full budget just before a naive window edge
        vm.warp(block.timestamp + 1);
        uint256 leaked = VCAP / WINDOW;
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.ValueBudgetExceeded.selector, VCAP, leaked));
        vm.prank(unlocker);
        mgr.unlock(VCAP, r, 1); // tumbling window would allow 2x; leaky bucket does not
    }

    function test_unlock_countBudget_boundsGriefing() public {
        // Fund enough and set a tiny count cap to exercise it.
        _lock(CAP, bob);
        vm.prank(owner);
        mgr.setUnlockCountPerWindow(5);
        vm.startPrank(unlocker);
        for (uint256 n = 0; n < 5; n++) {
            mgr.unlock(1, bob, n);
        }
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.CountBudgetExceeded.selector, 5));
        mgr.unlock(1, bob, 5);
        vm.stopPrank();
    }

    function test_setCapLower_doesNotBrickHotPath() public {
        _lock(CAP, bob);
        vm.prank(unlocker);
        mgr.unlock(VCAP, bob, 0); // fill the value bucket
        vm.prank(owner);
        mgr.setUnlockCapPerWindow(VCAP / 2); // tighten below the bucket
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.ValueBudgetExceeded.selector, 1, 0));
        vm.prank(unlocker);
        mgr.unlock(1, bob, 1); // clean revert, not a panic
    }

    // ---- owner path ----

    function test_ownerUnlock_uncapped_bypassesBucketsAndPause() public {
        _lock(CAP, bob);
        _lock(CAP, bob); // 50k
        vm.prank(owner);
        mgr.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(unlocker);
        mgr.unlock(1 ether, bob, 0);
        // owner drains 40k (> value cap, while paused) to an excluded sink (no recipient cap)
        vm.prank(noxaOwner);
        noxa.setExcluded(bob, true);
        vm.prank(owner);
        mgr.ownerUnlock(40_000 ether, bob, 0);
        assertEq(noxa.balanceOf(bob), 40_000 ether);
    }

    function test_pause_freezesLockAndHotUnlock() public {
        vm.prank(owner);
        mgr.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        mgr.lock(1 ether, bob);
    }

    // ---- recovery (clear) ----

    function test_clearProcessedBurn_reopens_batch_range_max() public {
        _lock(CAP, bob);
        vm.startPrank(unlocker);
        mgr.unlock(1, bob, 0);
        mgr.unlock(1, bob, 2);
        mgr.unlock(1, bob, type(uint256).max);
        vm.stopPrank();

        uint256[] memory ns = new uint256[](3);
        ns[0] = 0;
        ns[1] = 999; // unset -> skipped
        ns[2] = 0; // dup -> skipped
        vm.prank(owner);
        mgr.clearProcessedBurns(ns); // tolerant
        assertFalse(mgr.processedBurn(0));

        vm.prank(owner);
        mgr.clearProcessedBurnRange(type(uint256).max - 1, type(uint256).max); // no overflow
        assertFalse(mgr.processedBurn(type(uint256).max));
    }

    // ---- box access control + renounce ----

    function test_box_drain_onlyManager() public {
        _lock(1_000 ether, bob);
        NoxaShardedBox box = NoxaShardedBox(mgr.boxes(0));
        vm.expectRevert(NoxaShardedBox.NotManager.selector);
        box.drain(bob, 1 ether);
    }

    function test_renounce_disabled() public {
        vm.expectRevert(NoxaLockboxManager.RenounceDisabled.selector);
        vm.prank(owner);
        mgr.renounceOwnership();
    }

    function test_constructor_rejectsZeros() public {
        vm.expectRevert(NoxaLockboxManager.ZeroAmount.selector);
        new NoxaLockboxManager(address(noxa), wnoxa, owner, unlocker, 0, VCAP, CCAP, WINDOW);
        vm.expectRevert(NoxaLockboxManager.ZeroAddress.selector);
        new NoxaLockboxManager(address(0), wnoxa, owner, unlocker, CAP, VCAP, CCAP, WINDOW);
    }

    function test_box_constructor_rejectsZero() public {
        vm.expectRevert(NoxaShardedBox.ZeroAddress.selector);
        new NoxaShardedBox(address(0), address(mgr));
        vm.expectRevert(NoxaShardedBox.ZeroAddress.selector);
        new NoxaShardedBox(address(noxa), address(0));
    }

    // ---- owner setters + config validation ----

    function test_setters_validateAndEmit() public {
        vm.startPrank(owner);
        vm.expectRevert(NoxaLockboxManager.ZeroAmount.selector);
        mgr.setMaxBoxAmount(0);
        vm.expectRevert(NoxaLockboxManager.ZeroAmount.selector);
        mgr.setUnlockWindow(0);
        vm.expectRevert(NoxaLockboxManager.ZeroAmount.selector);
        mgr.setUnlockCountPerWindow(0);
        mgr.setMaxBoxAmount(30_000 ether);
        mgr.setUnlockWindow(300);
        mgr.setUnlockCountPerWindow(50);
        vm.stopPrank();
        assertEq(mgr.maxBoxAmount(), 30_000 ether);
        assertEq(mgr.unlockWindow(), 300);
        assertEq(mgr.unlockCountPerWindow(), 50);
    }

    function test_setUnlocker_resetsBuckets_andDisables() public {
        _lock(CAP, bob);
        vm.prank(unlocker);
        mgr.unlock(VCAP, bob, 0); // fill value bucket
        assertGt(mgr.valueBucket(), 0);
        address newKey = makeAddr("newUnlocker");
        vm.prank(owner);
        mgr.setUnlocker(newKey); // rotation resets buckets
        assertEq(mgr.valueBucket(), 0);
        assertEq(mgr.countBucket(), 0);
        assertEq(mgr.unlocker(), newKey);

        vm.prank(owner);
        mgr.setUnlocker(address(0)); // fail-safe disable
        vm.expectRevert(NoxaLockboxManager.NotUnlocker.selector);
        vm.prank(newKey);
        mgr.unlock(1, bob, 9);
    }

    function test_unpause_restoresLockAndUnlock() public {
        vm.prank(owner);
        mgr.pause();
        vm.prank(owner);
        mgr.unpause();
        _lock(1_000 ether, bob);
        vm.prank(unlocker);
        mgr.unlock(500 ether, bob, 0);
        assertEq(noxa.balanceOf(bob), 500 ether);
    }

    function test_clearProcessedBurn_single_ownerOnly_mustBeSet() public {
        _lock(1_000 ether, bob);
        vm.prank(unlocker);
        mgr.unlock(1, bob, 5);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        vm.prank(bob);
        mgr.clearProcessedBurn(5);
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.NotProcessed.selector, 99));
        vm.prank(owner);
        mgr.clearProcessedBurn(99);
        vm.prank(owner);
        mgr.clearProcessedBurn(5);
        assertFalse(mgr.processedBurn(5));
    }

    function test_clearProcessedBurnRange_badRange() public {
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.BadRange.selector, 5, 4));
        vm.prank(owner);
        mgr.clearProcessedBurnRange(5, 4);
    }

    /// The defensive DepositExceedsBoxCap guard: reachable only if the manager
    /// itself were cap-excluded (so NOXA lets it receive > cap). In production the
    /// manager is non-excluded and its own cap bounds a single deposit to ≤cap.
    function test_lock_depositExceedsBoxCap_guard() public {
        vm.prank(noxaOwner);
        noxa.setExcluded(address(mgr), true); // artificial: let the manager over-receive
        vm.expectRevert(abi.encodeWithSelector(NoxaLockboxManager.DepositExceedsBoxCap.selector, 30_000 ether, CAP));
        mgr.lock(30_000 ether, bob);
    }

    // ---- cursor: iteration stays bounded; full-drain-then-refund works ----

    function test_cursor_fullDrainThenRefund() public {
        // Fund three shards (75k), then drain everything to fresh capped recipients.
        _lock(CAP, bob);
        _lock(CAP, bob);
        _lock(CAP, bob);
        assertEq(mgr.boxCount(), 3);
        assertEq(mgr.oldestFundedIndex(), 0);

        uint256 nonce;
        for (uint256 i = 0; i < 3; i++) {
            address r = makeAddr(string(abi.encodePacked("drain", i)));
            vm.warp(block.timestamp + WINDOW); // avoid the value budget
            vm.prank(unlocker);
            mgr.unlock(CAP, r, nonce++);
        }
        assertEq(mgr.totalCollateral(), 0);
        assertEq(mgr.oldestFundedIndex(), 3); // advanced past all emptied shards

        // Refund after a full drain: the manager must re-include the reused/spawned
        // shard (the cursor bug would leave the next release unable to find funds).
        _lock(5_000 ether, bob);
        assertLe(mgr.oldestFundedIndex(), mgr.boxCount() - 1);
        assertEq(mgr.totalCollateral(), 5_000 ether);
        vm.warp(block.timestamp + WINDOW);
        address r = makeAddr("post");
        vm.prank(unlocker);
        mgr.unlock(5_000 ether, r, nonce++);
        assertEq(noxa.balanceOf(r), 5_000 ether);
        assertEq(mgr.totalCollateral(), 0);
    }

    // ---- review HIGH: manager never custodies, so stray NOXA can't brick lock ----

    function test_lock_immuneToManagerPoison() public {
        // Attacker parks NOXA directly on the manager address.
        vm.prank(noxaOwner);
        noxa.transfer(address(mgr), 24_999 ether);
        // Every lock still works: NOXA goes straight into a shard, not the manager.
        (, uint256 received) = _lock(CAP, bob);
        assertEq(received, CAP);
        assertEq(noxa.balanceOf(mgr.boxes(0)), CAP);
        // The manager's stray balance is inert (not counted, doesn't block).
        assertEq(noxa.balanceOf(address(mgr)), 24_999 ether);
    }

    // ---- review blocker: pre-funded ("poison") spawn address is absorbed ----

    function test_lock_absorbsPoisonedSpawnAddress() public {
        _lock(CAP, bob); // box0 spawned + filled; next CREATE is at manager nonce 2
        address nextBox = vm.computeCreateAddress(address(mgr), 2);
        vm.prank(noxaOwner);
        noxa.transfer(nextBox, CAP); // poison the next spawn address to the cap

        // The next lock that needs a new shard records the poisoned box as
        // collateral and spawns past it — it does NOT brick.
        (, uint256 received) = _lock(5_000 ether, bob);
        assertEq(received, 5_000 ether);
        assertGe(mgr.boxCount(), 3); // box0 + poisoned box + a fresh box for the 5k
        // The attacker's donation is now real, drainable collateral.
        assertEq(mgr.totalCollateral(), CAP + CAP + 5_000 ether);
    }

    function test_spawnBoxes_ownerEscapeHatch() public {
        uint256 before = mgr.boxCount();
        vm.prank(owner);
        mgr.spawnBoxes(3);
        assertEq(mgr.boxCount(), before + 3);
    }

    // ---- review MEDIUM: single-hop received == vaulted collateral (no over-mint) ----

    function test_lock_feeOnTransfer_receivedMatchesVaulted() public {
        vm.prank(noxaOwner);
        noxa.setFee(100); // 1%
        (, uint256 received) = _lock(10_000 ether, bob);
        // received is the shard's actual delta, not the requested 10k.
        assertEq(received, 9_900 ether);
        assertEq(noxa.balanceOf(mgr.boxes(0)), 9_900 ether); // exactly what was vaulted
        assertEq(mgr.totalCollateral(), 9_900 ether);
    }

    // ---- review LOW: owner can recover NOXA stranded on a retired (below-cursor) shard ----

    function test_ownerDrainShard_recoversStrandedNoxa() public {
        _lock(CAP, bob); // box0
        _lock(5_000 ether, bob); // box1 (box0 full)
        vm.warp(block.timestamp + WINDOW);
        address r = makeAddr("r");
        vm.prank(unlocker);
        mgr.unlock(CAP, r, 0); // drain box0 fully -> cursor advances past it
        assertEq(mgr.oldestFundedIndex(), 1);

        // Stray NOXA lands on the retired box0 (below the cursor).
        vm.prank(noxaOwner);
        noxa.transfer(mgr.boxes(0), 1_000 ether);
        assertEq(mgr.totalCollateral(), 5_000 ether); // uncounted (conservative)

        // Owner recovers it (not possible via unlock/ownerUnlock, which skip below-cursor).
        address r2 = makeAddr("recover");
        vm.prank(owner);
        mgr.ownerDrainShard(0, r2, 1_000 ether);
        assertEq(noxa.balanceOf(r2), 1_000 ether);
    }

    // ---- review should-fix: non-NOXA rescue restored; NOXA is never rescuable this way ----

    function test_rescueBoxToken_nonNoxaOnly() public {
        _lock(1_000 ether, bob);
        address box = mgr.boxes(0);
        // stray non-NOXA on a shard
        MaxWalletNoxa stray = new MaxWalletNoxa(address(this), type(uint256).max, 1_000 ether);
        stray.transfer(box, 500 ether);

        vm.expectRevert(NoxaLockboxManager.CannotRescueCollateral.selector);
        vm.prank(owner);
        mgr.rescueBoxToken(box, address(noxa), bob, 1 ether); // NOXA blocked

        vm.prank(owner);
        mgr.rescueBoxToken(box, address(stray), bob, 500 ether);
        assertEq(stray.balanceOf(bob), 500 ether);
    }

    // ---- fuzz: routing keeps shards under cap; collateral is conserved ----

    /// For any sequence of ≤cap deposits, no shard ever exceeds the cap (so the
    /// cap-enforcing mock NOXA never reverts) and totalCollateral == sum locked.
    function testFuzz_shardsNeverExceedCap(uint256[12] calldata amounts) public {
        uint256 locked;
        for (uint256 i = 0; i < 12; i++) {
            uint256 a = 1 + (amounts[i] % CAP); // 1..cap
            mgr.lock(a, bob);
            locked += a;
        }
        assertEq(mgr.totalCollateral(), locked);
        uint256 n = mgr.boxCount();
        for (uint256 i = 0; i < n; i++) {
            assertLe(noxa.balanceOf(mgr.boxes(i)), CAP);
        }
        assertEq(noxa.balanceOf(address(mgr)), 0);
    }
}
