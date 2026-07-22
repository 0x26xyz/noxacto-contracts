// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {NoxaShardedBox} from "./NoxaShardedBox.sol";

/// @title NoxaLockboxManager — sharded-custody bridge lockbox for the 25K-capped NOXA
/// @notice Lifts the single-lockbox 25,000-NOXA ceiling (docs/noxa-wallet-cap.md
/// §4). The source NOXA caps every non-excluded wallet at 25,000, and our custody
/// address cannot be exempted, so ONE lockbox tops out at 25K total collateral.
/// This manager shards custody across many `NoxaShardedBox` leaves (each ≤ cap),
/// giving N x 25K capacity, while presenting the relayer a SINGLE address with:
///
/// - **One global lock nonce + one global `processedBurn` map.** Per-box nonces
///   would collide on the RH `processedLock` map (the round-1 HIGH-3 failure, now
///   across shards); centralising them here keeps every inbound/outbound nonce
///   unique and every burn settleable exactly once, either path.
/// - **Lazy box spawning.** `lock` routes each deposit into a box with headroom
///   and spawns a fresh box only when the newest is too full to hold it — so a
///   whole ~25K deposit always fits (a fresh box holds the cap). The manager only
///   ever holds NOXA transiently within a `lock` call (in, then straight to a
///   box), so it never itself trips the source cap.
/// - **The V3 hot/cold split, carried over verbatim.** Routine returns run
///   through the rate-limited `unlock` (hot `unlocker`, dual leaky buckets on
///   value AND settlement count, pausable); large/emergency returns run through
///   the uncapped, unpausable cold `ownerUnlock`. A release DRAINS oldest-box-
///   first across shards (at most two boxes for any single ≤cap redemption), and
///   the replay guard + rate limit meter the total, not per box.
/// - **Recoverable replay guard, batched.** `clearProcessedBurn(s)` /
///   `clearProcessedBurnRange` for pause-first recovery, exactly as V3.
///
/// Collateral invariant (relayer-enforced off-chain): `totalCollateral()` (the
/// sum over all shards) + migrator escrow >= wNOXA.totalSupply(). Renounce stays
/// disabled; hand off via 2-step transfer to a Safe.
contract NoxaLockboxManager is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The DBK-Chain NOXA token being custodied.
    IERC20 public immutable noxa;
    /// @notice The RH wNOXA this manager settles for (informational; relayer-enforced).
    address public immutable wrappedNoxa;

    /// @notice Per-box fill ceiling — the source token's max-wallet cap. A box is
    /// never filled past this (NOXA would revert the transfer). Owner-settable to
    /// track the source token if it ever changes its cap.
    uint256 public maxBoxAmount;

    /// @notice All custody shards ever spawned, oldest first. `boxes[length-1]` is
    /// the active box. Drained shards stay in the array but are skipped via the
    /// cursor below, so iteration cost tracks CONCURRENT collateral, not lifetime
    /// churn (the array only ever appends; it is never iterated whole).
    address[] public boxes;

    /// @notice Lowest box index that may still hold NOXA. Locks fund the active
    /// (highest) box; releases drain oldest-first from here and advance it past
    /// emptied leading shards. Invariant: every funded shard is in
    /// `[oldestFundedIndex, boxes.length)`.
    uint256 public oldestFundedIndex;

    /// @notice Max fresh shards a single `lock` will spawn past pre-funded (poison)
    /// addresses before deferring to the owner's `spawnBoxes` escape hatch.
    uint256 public constant MAX_SPAWNS_PER_LOCK = 8;
    /// @notice Per-call bound on the owner's `spawnBoxes` recovery.
    uint256 public constant MAX_SPAWN_BATCH = 64;

    /// @notice Hot key allowed to call the rate-limited `unlock`. Rotatable by owner.
    address public unlocker;
    /// @notice Hot-path VALUE budget per `unlockWindow` (leaky bucket). Non-zero.
    uint256 public unlockCapPerWindow;
    /// @notice Hot-path SETTLEMENT-COUNT budget per `unlockWindow` (leaky bucket). Non-zero.
    uint256 public unlockCountPerWindow;
    /// @notice Leaky-bucket decay length in seconds. Non-zero.
    uint256 public unlockWindow;
    uint256 public valueBucket;
    uint256 public countBucket;
    uint256 public lastUnlockAt;

    /// @notice Monotonic GLOBAL nonce for inbound (DBK -> RH) locks.
    uint256 public lockNonce;
    /// @notice GLOBAL outbound replay guard (shared by unlock + ownerUnlock; clearable).
    mapping(uint256 rhBurnNonce => bool) public processedBurn;

    event BoxSpawned(uint256 indexed index, address indexed box);
    event UnlockerSet(address indexed unlocker);
    event UnlockCapPerWindowSet(uint256 cap);
    event UnlockCountPerWindowSet(uint256 count);
    event UnlockWindowSet(uint256 window);
    event MaxBoxAmountSet(uint256 amount);
    event ProcessedBurnCleared(uint256 indexed rhBurnNonce);
    event TokenRescued(address indexed box, address indexed token, address indexed to, uint256 amount);
    event ShardDrained(uint256 indexed index, address indexed to, uint256 amount);
    /// @param nonce Inbound nonce; the RH `mint` must consume exactly this value.
    /// @param received Fee-adjusted amount actually custodied — the amount to mint on RH.
    /// @dev BYTE-IDENTICAL to `NoxaLockboxV3.Locked` (same topic0), so the relayer
    /// and UI decode it unchanged when `LOCKBOX_ADDRESS` is repointed at this
    /// manager. The shard the deposit landed in is emitted separately as
    /// `LockRouted` (observability only; the relayer settles via the manager, not
    /// per shard, so it never needs the box address).
    event Locked(uint256 indexed nonce, address indexed from, address indexed rhRecipient, uint256 received);
    /// @param box The shard `nonce`'s deposit was routed into.
    event LockRouted(uint256 indexed nonce, address indexed box);
    /// @param rhBurnNonce The RH `BurnedForReturn` nonce this release settles.
    /// @param viaOwner True if released through the uncapped owner path.
    event Unlocked(uint256 indexed rhBurnNonce, address indexed to, uint256 amount, bool viaOwner);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error NotUnlocker();
    error ValueBudgetExceeded(uint256 requested, uint256 remaining);
    error CountBudgetExceeded(uint256 perWindow);
    error AlreadyProcessed(uint256 rhBurnNonce);
    error NotProcessed(uint256 rhBurnNonce);
    error BadRange(uint256 from, uint256 to);
    error InsufficientCollateral(uint256 requested, uint256 available);
    error DepositExceedsBoxCap(uint256 received, uint256 maxBox);
    error BoxSpawnBlocked();
    error CannotRescueCollateral();
    error RenounceDisabled();

    /// @param noxa_ DBK NOXA token.
    /// @param wrappedNoxa_ RH wNOXA this manager settles for (recorded only).
    /// @param bridgeAuthority_ Cold owner (Safe) — manages unlocker, budgets, cap, pause.
    /// @param unlocker_ Hot relayer key (may be 0 to leave the hot path disabled until set).
    /// @param maxBoxAmount_ Per-box fill ceiling = source token max-wallet cap (25_000e18). Non-zero.
    /// @param unlockCapPerWindow_ Hot-path per-window value budget. Non-zero.
    /// @param unlockCountPerWindow_ Hot-path per-window settlement-count budget. Non-zero.
    /// @param unlockWindow_ Leaky-bucket decay length (seconds). Non-zero.
    constructor(
        address noxa_,
        address wrappedNoxa_,
        address bridgeAuthority_,
        address unlocker_,
        uint256 maxBoxAmount_,
        uint256 unlockCapPerWindow_,
        uint256 unlockCountPerWindow_,
        uint256 unlockWindow_
    ) Ownable(bridgeAuthority_) {
        if (noxa_ == address(0) || wrappedNoxa_ == address(0)) revert ZeroAddress();
        if (maxBoxAmount_ == 0 || unlockCapPerWindow_ == 0 || unlockCountPerWindow_ == 0 || unlockWindow_ == 0) {
            revert ZeroAmount();
        }
        noxa = IERC20(noxa_);
        wrappedNoxa = wrappedNoxa_;
        maxBoxAmount = maxBoxAmount_;
        unlocker = unlocker_;
        unlockCapPerWindow = unlockCapPerWindow_;
        unlockCountPerWindow = unlockCountPerWindow_;
        unlockWindow = unlockWindow_;
        lastUnlockAt = block.timestamp;
        emit MaxBoxAmountSet(maxBoxAmount_);
        emit UnlockerSet(unlocker_);
        emit UnlockCapPerWindowSet(unlockCapPerWindow_);
        emit UnlockCountPerWindowSet(unlockCountPerWindow_);
        emit UnlockWindowSet(unlockWindow_);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function boxCount() external view returns (uint256) {
        return boxes.length;
    }

    /// @notice Live sum of NOXA across all shards — the collateral figure the
    /// relayer's drift breaker sums against wNOXA supply.
    function totalCollateral() public view returns (uint256 total) {
        uint256 n = boxes.length;
        for (uint256 i = oldestFundedIndex; i < n; i++) {
            total += noxa.balanceOf(boxes[i]);
        }
    }

    // -----------------------------------------------------------------------
    // Owner config
    // -----------------------------------------------------------------------

    function setUnlocker(address unlocker_) external onlyOwner {
        unlocker = unlocker_; // 0 disables the hot path (fail-safe)
        valueBucket = 0; // reset the hot budget on rotation (V3 semantics)
        countBucket = 0;
        lastUnlockAt = block.timestamp;
        emit UnlockerSet(unlocker_);
    }

    function setUnlockCapPerWindow(uint256 cap_) external onlyOwner {
        if (cap_ == 0) revert ZeroAmount();
        unlockCapPerWindow = cap_;
        if (valueBucket > cap_) valueBucket = cap_; // clamp so a lower cap can't underflow unlock()
        emit UnlockCapPerWindowSet(cap_);
    }

    function setUnlockCountPerWindow(uint256 count_) external onlyOwner {
        if (count_ == 0) revert ZeroAmount();
        unlockCountPerWindow = count_;
        if (countBucket > count_) countBucket = count_;
        emit UnlockCountPerWindowSet(count_);
    }

    function setUnlockWindow(uint256 window_) external onlyOwner {
        if (window_ == 0) revert ZeroAmount();
        unlockWindow = window_;
        emit UnlockWindowSet(window_);
    }

    /// @notice Track the source token's cap if it ever changes. Non-zero.
    function setMaxBoxAmount(uint256 amount_) external onlyOwner {
        if (amount_ == 0) revert ZeroAmount();
        maxBoxAmount = amount_;
        emit MaxBoxAmountSet(amount_);
    }

    function clearProcessedBurn(uint256 rhBurnNonce) external onlyOwner {
        if (!processedBurn[rhBurnNonce]) revert NotProcessed(rhBurnNonce);
        processedBurn[rhBurnNonce] = false;
        emit ProcessedBurnCleared(rhBurnNonce);
    }

    /// @notice Tolerant batch clear (unset/duplicate nonces skipped). Pause-first
    /// recovery: pause() -> rotate unlocker -> clear -> unpause().
    function clearProcessedBurns(uint256[] calldata rhBurnNonces) external onlyOwner {
        for (uint256 i = 0; i < rhBurnNonces.length; i++) {
            uint256 n = rhBurnNonces[i];
            if (processedBurn[n]) {
                processedBurn[n] = false;
                emit ProcessedBurnCleared(n);
            }
        }
    }

    /// @notice Range clear [from, to] inclusive; terminates safely at type(uint256).max.
    function clearProcessedBurnRange(uint256 from, uint256 to) external onlyOwner {
        if (to < from) revert BadRange(from, to);
        for (uint256 n = from;; n++) {
            if (processedBurn[n]) {
                processedBurn[n] = false;
                emit ProcessedBurnCleared(n);
            }
            if (n == to) break;
        }
    }

    /// @notice Recover a NON-NOXA ERC-20 that landed on shard `index` (airdrop /
    /// mistaken transfer). Cannot move the custodied NOXA (that would break the
    /// peg). Owner only. Restores `NoxaLockboxV3.rescueToken`. Index-based (like
    /// `ownerDrainShard`) so a mistyped shard address can't send tokens astray.
    function rescueBoxToken(uint256 index, address token, address to, uint256 amount) external onlyOwner {
        if (index >= boxes.length) revert BadRange(index, boxes.length);
        if (token == address(noxa)) revert CannotRescueCollateral();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        address box = boxes[index];
        NoxaShardedBox(box).rescueToken(token, to, amount);
        emit TokenRescued(box, token, to, amount);
    }

    /// @notice Recover ANY ERC-20 (NOXA included) sitting DIRECTLY on the manager
    /// address. The manager custodies nothing itself: `lock` pulls NOXA STRAIGHT
    /// into a shard and `totalCollateral()` sums only shard balances, so a token on
    /// the manager is always a stray transfer to the published bridge address and
    /// moving it can never touch collateral or the peg. This is the single most
    /// common way users lose funds (sending to the address they approve for `lock`),
    /// and without it those tokens are unrecoverable. Distinct from `rescueBoxToken`,
    /// which reaches a SHARD and forbids NOXA (real collateral lives there). Owner only.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(address(this), token, to, amount);
    }

    /// @notice Move NOXA out of a specific shard by index. The recovery lever for
    /// NOXA transferred DIRECTLY to a shard outside the `lock` path — including a
    /// RETIRED shard below `oldestFundedIndex`, which `totalCollateral`/`_release`
    /// deliberately skip and thus could otherwise strand forever (review LOW). No
    /// broader than `ownerUnlock` (the cold owner can already move collateral);
    /// does NOT consume a burn nonce (it settles nothing). Owner only.
    function ownerDrainShard(uint256 index, address to, uint256 amount) external onlyOwner nonReentrant {
        if (index >= boxes.length) revert BadRange(index, boxes.length);
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        NoxaShardedBox(boxes[index]).drain(to, amount);
        emit ShardDrained(index, to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Inbound: lock (DBK) -> mint (RH)
    // -----------------------------------------------------------------------

    /// @notice Lock NOXA to bridge it to Robinhood Chain. Pulls from the caller,
    /// routes it into a shard with headroom (spawning a fresh shard if the active
    /// one is too full), and emits a single global `Locked`. Fee-on-transfer safe
    /// on both hops. The manager holds NOXA only within this call.
    function lock(uint256 amount, address rhRecipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 nonce, uint256 received)
    {
        if (amount == 0) revert ZeroAmount();
        if (rhRecipient == address(0)) revert ZeroAddress();
        if (amount > maxBoxAmount) revert DepositExceedsBoxCap(amount, maxBoxAmount);

        // Route on the REQUESTED amount (an upper bound on what the shard receives,
        // since a fee only shrinks it), then pull the caller's NOXA STRAIGHT INTO
        // the shard. The manager never itself holds NOXA, so:
        //  - stray NOXA donated to the manager can never trip the source cap and
        //    brick `lock` (review HIGH: no transient-hold DoS), and
        //  - `received` is a SINGLE-hop balance delta measured at the shard, so it
        //    equals the collateral actually vaulted — RH mints exactly what backs
        //    it, even under a future fee-on-transfer (review MEDIUM: no over-mint).
        address box = _boxWithHeadroom(amount);
        uint256 box0 = noxa.balanceOf(box);
        noxa.safeTransferFrom(msg.sender, box, amount);
        received = noxa.balanceOf(box) - box0; // fee-on-transfer safe, single hop
        if (received == 0) revert NothingReceived();

        nonce = lockNonce++;
        emit Locked(nonce, msg.sender, rhRecipient, received);
        emit LockRouted(nonce, box);
    }

    /// @dev Return the active shard if `amount` fits under the cap, else spawn
    /// fresh shards until one has headroom. A spawn address is a plain CREATE
    /// (deterministic from the manager nonce), so an attacker can PRE-FUND it —
    /// even 1 wei is enough to fail the headroom check for an exactly-cap deposit,
    /// since `balance + amount <= maxBoxAmount` then requires balance == 0. Defence
    /// on the SUCCESS path: each spawned shard is RECORDED before the check, so a
    /// poisoned shard's donation becomes drainable collateral and the loop advances
    /// past it. LIMIT (review, LOW): if ALL `MAX_SPAWNS_PER_LOCK` consecutive spawn
    /// addresses are poisoned, this reverts `BoxSpawnBlocked` and the revert ROLLS
    /// BACK the records — nothing is absorbed, and the poison persists. Impact is
    /// bounded: 1-wei poison blocks ONLY exactly-cap locks (a user locks cap-minus-
    /// dust and succeeds; sub-cap locks route through poisoned shards normally), and
    /// blocking a wider band costs the attacker proportional, forfeitable NOXA. The
    /// owner clears it with `spawnBoxes` (which absorbs the poison and advances the
    /// frontier). NOT made permissionless deliberately: that would let a griefer
    /// bloat `boxes[]` with empty trailing shards and gas-DoS `totalCollateral()`
    /// (summed every tick by the relayer), which the cursor does NOT skip.
    function _boxWithHeadroom(uint256 amount) internal returns (address box) {
        uint256 n = boxes.length;
        if (n != 0) {
            uint256 activeIdx = n - 1;
            box = boxes[activeIdx];
            if (noxa.balanceOf(box) + amount <= maxBoxAmount) {
                if (oldestFundedIndex > activeIdx) oldestFundedIndex = activeIdx;
                return box;
            }
        }
        for (uint256 t = 0; t < MAX_SPAWNS_PER_LOCK; t++) {
            (address fresh, uint256 idx) = _spawn();
            if (noxa.balanceOf(fresh) + amount <= maxBoxAmount) {
                if (oldestFundedIndex > idx) oldestFundedIndex = idx;
                return fresh;
            }
            // fresh shard arrived pre-funded past the cap: it is now recorded
            // collateral (cursor clamped in _spawn); try the next address.
        }
        revert BoxSpawnBlocked();
    }

    /// @dev Deploy + register one shard. If it arrives with a balance (a pre-funded
    /// "poison" address), clamp the cursor so that collateral is counted and drainable.
    function _spawn() internal returns (address box, uint256 idx) {
        NoxaShardedBox fresh = new NoxaShardedBox(address(noxa), address(this));
        box = address(fresh);
        boxes.push(box);
        idx = boxes.length - 1;
        if (noxa.balanceOf(box) != 0 && oldestFundedIndex > idx) oldestFundedIndex = idx;
        emit BoxSpawned(idx, box);
    }

    /// @notice Owner escape hatch for the poison-spawn grief: pre-spawn `count`
    /// shards, skipping past pre-funded (poisoned) addresses so `lock` can resume.
    /// Each spawned shard is registered; a poisoned one becomes drainable collateral
    /// (recover it with `ownerDrainShard`). Owner-only ON PURPOSE — a permissionless
    /// version would let a griefer bloat `boxes[]` with empty shards and gas-DoS the
    /// per-tick `totalCollateral()`. Bounded per call.
    function spawnBoxes(uint256 count) external onlyOwner {
        if (count == 0 || count > MAX_SPAWN_BATCH) revert BadRange(0, count);
        for (uint256 i = 0; i < count; i++) {
            _spawn();
        }
    }

    // -----------------------------------------------------------------------
    // Outbound: burn (RH) -> unlock (DBK)
    // -----------------------------------------------------------------------

    /// @notice Routine return: release NOXA to settle a Robinhood burn. Hot path —
    /// `unlocker` only, bounded by BOTH leaky buckets (value + count), pausable.
    /// Idempotent per `rhBurnNonce`. Drains oldest-shard-first.
    function unlock(uint256 amount, address to, uint256 rhBurnNonce) external nonReentrant whenNotPaused {
        if (msg.sender != unlocker) revert NotUnlocker();
        if (amount == 0) revert ZeroAmount();

        uint256 elapsed = block.timestamp - lastUnlockAt;

        uint256 vLeaked = Math.mulDiv(elapsed, unlockCapPerWindow, unlockWindow);
        uint256 vUsed = valueBucket > vLeaked ? valueBucket - vLeaked : 0;
        uint256 vRemaining = unlockCapPerWindow > vUsed ? unlockCapPerWindow - vUsed : 0;
        if (amount > vRemaining) revert ValueBudgetExceeded(amount, vRemaining);

        uint256 cLeaked = Math.mulDiv(elapsed, unlockCountPerWindow, unlockWindow);
        uint256 cUsed = countBucket > cLeaked ? countBucket - cLeaked : 0;
        if (cUsed + 1 > unlockCountPerWindow) revert CountBudgetExceeded(unlockCountPerWindow);

        valueBucket = vUsed + amount;
        countBucket = cUsed + 1;
        lastUnlockAt = block.timestamp; // effects before interaction

        _release(amount, to, rhBurnNonce, false);
    }

    /// @notice Large/emergency return: uncapped release by the cold owner. Not
    /// gated by pause. Idempotent per `rhBurnNonce`. Does NOT touch the hot buckets.
    function ownerUnlock(uint256 amount, address to, uint256 rhBurnNonce) external onlyOwner nonReentrant {
        _release(amount, to, rhBurnNonce, true);
    }

    function _release(uint256 amount, address to, uint256 rhBurnNonce, bool viaOwner) internal {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (processedBurn[rhBurnNonce]) revert AlreadyProcessed(rhBurnNonce);
        processedBurn[rhBurnNonce] = true; // effects before interactions

        // Drain oldest funded shard first; iterates only [oldestFundedIndex, len)
        // so cost tracks concurrent collateral, not lifetime churn. At most two
        // shards for any single ≤cap release.
        uint256 remaining = amount;
        uint256 len = boxes.length;
        for (uint256 i = oldestFundedIndex; i < len && remaining != 0; i++) {
            address box = boxes[i];
            uint256 bal = noxa.balanceOf(box);
            if (bal == 0) continue;
            uint256 take = bal < remaining ? bal : remaining;
            NoxaShardedBox(box).drain(to, take);
            remaining -= take;
        }
        if (remaining != 0) revert InsufficientCollateral(amount, amount - remaining);

        // Advance the cursor past shards this (and prior) releases fully emptied.
        uint256 j = oldestFundedIndex;
        while (j < len && noxa.balanceOf(boxes[j]) == 0) j++;
        oldestFundedIndex = j;

        emit Unlocked(rhBurnNonce, to, amount, viaOwner);
    }

    /// @notice Disabled — renouncing would freeze all sharded NOXA forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
