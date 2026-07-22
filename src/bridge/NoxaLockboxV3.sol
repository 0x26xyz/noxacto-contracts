// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title NoxaLockboxV3 — hardened DBK-Chain custody, per-version + leaky-bucket rate limit
/// @notice Successor to `NoxaLockboxV2`, closing the 2026-07-22 adversarial review
/// (rounds 1 and 2):
///
/// - **Leaky-bucket rate limit (round-2 NEW-1).** The earlier draft used a
///   fixed/"tumbling" window with a hard reset, so a burst at `windowStart +
///   window - 1` plus another at `+ window` released 2x the cap in ONE SECOND.
///   Here the hot path meters TWO continuously-decaying buckets — one on NOXA
///   value, one on settlement COUNT — each draining at `cap / window` per second.
///   The bucket LEVEL can never exceed its cap, so the *instantaneous* burst is
///   bounded to 1x cap (adjacent same-instant releases sum to <= cap) — that is
///   what kills the tumbling boundary attack. Throughput over a longer interval
///   Delta follows the standard leaky-bucket bound `cap + (cap/window)*Delta`,
///   i.e. up to ~2x cap over a full window (one full bucket + one window of
///   drain). Size the cap to HALF the value you can tolerate losing to a leaked
///   key per window, and set drift alarms to the ~2x/window figure, NOT 1x.
/// - **Count metering (round-2 NEW-2).** The value budget alone did not bound the
///   griefing attack, which is denominated in nonces (a leaked key pre-consumes
///   burn nonces for 1 wei each). The count bucket bounds settlements to
///   `unlockCountPerWindow` per window, so a leaked key can brick only a bounded
///   number of nonces before the owner reacts — all recoverable (below).
/// - **Recoverable replay guard, batched (round-2 NEW-3 / round-1 HIGH-2).**
///   `clearProcessedBurn(s)`/`clearProcessedBurnRange` let the cold owner reopen
///   nonces settled in error or maliciously pre-consumed. Clearing is inherently
///   racy against a still-leaked key, so the recovery runbook is strictly:
///   **pause() -> setUnlocker(rotate/0) -> clear -> unpause()** — `pause()` blocks
///   `unlock`, so the attacker cannot re-brick while frozen. Never clear first.
/// - **One lockbox per wNOXA version (round-1 HIGH-3).** Fresh `processedBurn`
///   map per instance; the paired `wrappedNoxa` is recorded for auditability.
///   Never point a new wNOXA at an existing box.
///
/// ALERTING (round-2 NEW-5/NEW-6): `processedBurn` is no longer write-once — any
/// off-chain drift monitor MUST consume `ProcessedBurnCleared` or it will
/// double-count a re-settled burn, and the owner can now pay a burn twice (no
/// escalation over `ownerUnlock`, but page on it). Config setters
/// (`UnlockCapPerWindowSet`/`UnlockWindowSet`/`UnlockCountPerWindowSet`) can also
/// refresh the budget — page on those too.
///
/// TRUST MODEL (unchanged, documented): `ownerUnlock` is uncapped and not
/// pausable (liveness), and `unlock`'s `amount`/`to` are not bound on-chain to
/// the burn event (the relayer binds them). With `clearProcessedBurn` added, the
/// cold owner holds every lever — release any amount, to anyone, any nonce,
/// repeatedly. This box MUST sit behind a Safe before it holds meaningful value.
contract NoxaLockboxV3 is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The DBK-Chain NOXA token being locked.
    IERC20 public immutable noxa;
    /// @notice The RH-side wNOXA this box settles for (informational; the relayer
    /// enforces the pairing off-chain). Recorded to make misconfiguration auditable.
    address public immutable wrappedNoxa;

    /// @notice Hot key allowed to call the rate-limited `unlock`. Rotatable by owner.
    address public unlocker;
    /// @notice Max NOXA the hot path may release per `unlockWindow` (leaky bucket). Non-zero.
    uint256 public unlockCapPerWindow;
    /// @notice Max hot-path settlements per `unlockWindow` (leaky bucket). Non-zero.
    /// @dev Decay is floored per call (Math.mulDiv), which is CONSERVATIVE: bursts
    /// faster than `unlockWindow/unlockCountPerWindow` apart credit no decay, so the
    /// effective sustained rate can sit slightly BELOW nominal (never above — safe).
    /// Size this generously above the relayer's real per-window settlement rate.
    uint256 public unlockCountPerWindow;
    /// @notice Rolling-window / decay length in seconds. Non-zero.
    uint256 public unlockWindow;

    /// @notice Current value-bucket level (NOXA released, decaying at cap/window per s).
    uint256 public valueBucket;
    /// @notice Current count-bucket level (settlements, decaying at count/window per s).
    uint256 public countBucket;
    /// @notice Timestamp both buckets last decayed to.
    uint256 public lastUnlockAt;

    /// @notice Monotonic nonce for inbound (DBK -> RH) locks.
    uint256 public lockNonce;
    /// @notice Outbound replay guard: RH burn nonces already released here (shared by
    /// `unlock` and `ownerUnlock`). Clearable by the owner — NOT write-once (see NEW-5).
    mapping(uint256 rhBurnNonce => bool) public processedBurn;

    event UnlockerSet(address indexed unlocker);
    event UnlockCapPerWindowSet(uint256 cap);
    event UnlockCountPerWindowSet(uint256 count);
    event UnlockWindowSet(uint256 window);
    event ProcessedBurnCleared(uint256 indexed rhBurnNonce);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    /// @param nonce Inbound nonce; the RH `mint` must consume exactly this value.
    /// @param received Fee-adjusted amount actually received — the amount to mint on RH.
    event Locked(uint256 indexed nonce, address indexed from, address indexed rhRecipient, uint256 received);
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
    error CannotRescueCollateral();
    error RenounceDisabled();

    /// @param noxa_ The DBK NOXA token address.
    /// @param wrappedNoxa_ The RH wNOXA this box settles for (recorded only).
    /// @param bridgeAuthority_ Cold owner (Safe) — manages the hot unlocker, budgets, pause.
    /// @param unlocker_ Hot relayer key (may be 0 to leave the hot path disabled until set).
    /// @param unlockCapPerWindow_ Per-window hot-path VALUE budget. MUST be non-zero.
    /// @param unlockCountPerWindow_ Per-window hot-path SETTLEMENT-COUNT budget. MUST be non-zero.
    /// @param unlockWindow_ Bucket decay length in seconds. MUST be non-zero.
    constructor(
        address noxa_,
        address wrappedNoxa_,
        address bridgeAuthority_,
        address unlocker_,
        uint256 unlockCapPerWindow_,
        uint256 unlockCountPerWindow_,
        uint256 unlockWindow_
    ) Ownable(bridgeAuthority_) {
        if (noxa_ == address(0) || wrappedNoxa_ == address(0)) revert ZeroAddress();
        if (unlockCapPerWindow_ == 0 || unlockCountPerWindow_ == 0 || unlockWindow_ == 0) revert ZeroAmount();
        noxa = IERC20(noxa_);
        wrappedNoxa = wrappedNoxa_;
        unlocker = unlocker_;
        unlockCapPerWindow = unlockCapPerWindow_;
        unlockCountPerWindow = unlockCountPerWindow_;
        unlockWindow = unlockWindow_;
        lastUnlockAt = block.timestamp;
        emit UnlockerSet(unlocker_);
        emit UnlockCapPerWindowSet(unlockCapPerWindow_);
        emit UnlockCountPerWindowSet(unlockCountPerWindow_);
        emit UnlockWindowSet(unlockWindow_);
    }

    // -----------------------------------------------------------------------
    // Owner config (ALL of these can refresh the hot budget — alert on them)
    // -----------------------------------------------------------------------

    /// @notice Rotate (or disable with 0) the hot key. Resets BOTH hot buckets: a
    /// new key must not inherit the old (possibly attacker-filled) budget usage,
    /// and this de-throttles the relayer immediately after a pause->rotate->clear
    /// recovery (round-2: clearing griefed nonces alone left the buckets full).
    function setUnlocker(address unlocker_) external onlyOwner {
        unlocker = unlocker_; // 0 intentionally disables the hot path (fail-safe)
        valueBucket = 0;
        countBucket = 0;
        lastUnlockAt = block.timestamp;
        emit UnlockerSet(unlocker_);
    }

    /// @notice Lower/raise the value budget. Clamps the standing `valueBucket` to
    /// the new cap so lowering it can never leave `valueBucket > cap` — which would
    /// otherwise underflow `cap - vUsed` in `unlock` and brick the hot path (round-2).
    function setUnlockCapPerWindow(uint256 cap_) external onlyOwner {
        if (cap_ == 0) revert ZeroAmount();
        unlockCapPerWindow = cap_;
        if (valueBucket > cap_) valueBucket = cap_;
        emit UnlockCapPerWindowSet(cap_);
    }

    function setUnlockCountPerWindow(uint256 count_) external onlyOwner {
        if (count_ == 0) revert ZeroAmount();
        unlockCountPerWindow = count_;
        if (countBucket > count_) countBucket = count_; // same invariant as the value bucket
        emit UnlockCountPerWindowSet(count_);
    }

    function setUnlockWindow(uint256 window_) external onlyOwner {
        if (window_ == 0) revert ZeroAmount();
        unlockWindow = window_;
        emit UnlockWindowSet(window_);
    }

    /// @notice Reopen a burn nonce settled in error or maliciously pre-consumed, so
    /// a real future burn at that nonce can settle. Owner only, event-logged. Moves
    /// no funds. Recovery ordering is MANDATORY: pause() -> rotate unlocker -> clear
    /// -> unpause(); clearing while the hot key is still live is racy (NEW-3).
    function clearProcessedBurn(uint256 rhBurnNonce) external onlyOwner {
        _clear(rhBurnNonce);
    }

    /// @notice Batch form — recover many bricked nonces in one owner tx (a leaked
    /// key can consume up to `unlockCountPerWindow` per window). TOLERANT: nonces
    /// that are already unset (or duplicated in the list) are skipped, not reverted,
    /// so an over-broad or de-duplicated recovery list still succeeds (round-2).
    function clearProcessedBurns(uint256[] calldata rhBurnNonces) external onlyOwner {
        for (uint256 i = 0; i < rhBurnNonces.length; i++) {
            uint256 n = rhBurnNonces[i];
            if (processedBurn[n]) {
                processedBurn[n] = false;
                emit ProcessedBurnCleared(n);
            }
        }
    }

    /// @notice Range form — clear every SET nonce in [from, to] inclusive. Unset
    /// nonces are skipped. Terminates correctly even when `to == type(uint256).max`
    /// (the reserved funding nonce) — the loop breaks on `n == to` before `n++`
    /// could overflow (round-2). For SPARSE nonces use `clearProcessedBurns`; a
    /// huge contiguous range will exhaust gas (owner's responsibility).
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

    function _clear(uint256 rhBurnNonce) internal {
        if (!processedBurn[rhBurnNonce]) revert NotProcessed(rhBurnNonce);
        processedBurn[rhBurnNonce] = false;
        emit ProcessedBurnCleared(rhBurnNonce);
    }

    /// @notice Recover a non-NOXA ERC-20 sent here by mistake. Cannot touch the
    /// custodied NOXA collateral (that would break the peg). Owner only.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(noxa)) revert CannotRescueCollateral();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
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

    /// @notice Lock NOXA to bridge it to Robinhood Chain. Measures actual received
    /// (fee-on-transfer safe) and emits it for the RH mint.
    function lock(uint256 amount, address rhRecipient)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 nonce, uint256 received)
    {
        if (amount == 0) revert ZeroAmount();
        if (rhRecipient == address(0)) revert ZeroAddress();

        uint256 bal0 = noxa.balanceOf(address(this));
        noxa.safeTransferFrom(msg.sender, address(this), amount);
        received = noxa.balanceOf(address(this)) - bal0; // fee-on-transfer safe
        if (received == 0) revert NothingReceived();

        nonce = lockNonce++;
        emit Locked(nonce, msg.sender, rhRecipient, received);
    }

    // -----------------------------------------------------------------------
    // Outbound: burn (RH) -> unlock (DBK)
    // -----------------------------------------------------------------------

    /// @notice Routine return: release NOXA to settle a Robinhood burn. Hot path —
    /// `unlocker` only, bounded by BOTH leaky buckets (value and count) so neither a
    /// large drain nor a many-nonce grief can evade it by fragmenting across calls or
    /// blocks; haltable via `pause()`. Idempotent per `rhBurnNonce`.
    function unlock(uint256 amount, address to, uint256 rhBurnNonce) external nonReentrant whenNotPaused {
        if (msg.sender != unlocker) revert NotUnlocker();
        if (amount == 0) revert ZeroAmount();

        uint256 elapsed = block.timestamp - lastUnlockAt;

        // Value bucket: decay, check, refill. `valueBucket <= unlockCapPerWindow`
        // holds after every unlock (write below) AND after a cap change (setter
        // clamps it), so `vUsed <= cap`. The subtraction is written saturating
        // anyway — defense in depth against any future path that could break the
        // invariant, so the hot path degrades to a clean revert, never a panic.
        uint256 vLeaked = Math.mulDiv(elapsed, unlockCapPerWindow, unlockWindow);
        uint256 vUsed = valueBucket > vLeaked ? valueBucket - vLeaked : 0;
        uint256 vRemaining = unlockCapPerWindow > vUsed ? unlockCapPerWindow - vUsed : 0;
        if (amount > vRemaining) revert ValueBudgetExceeded(amount, vRemaining);

        // Count bucket: same discipline, metering the scarce resource (nonces).
        uint256 cLeaked = Math.mulDiv(elapsed, unlockCountPerWindow, unlockWindow);
        uint256 cUsed = countBucket > cLeaked ? countBucket - cLeaked : 0;
        if (cUsed + 1 > unlockCountPerWindow) revert CountBudgetExceeded(unlockCountPerWindow);

        valueBucket = vUsed + amount;
        countBucket = cUsed + 1;
        lastUnlockAt = block.timestamp; // effects before interaction

        _release(amount, to, rhBurnNonce, false);
    }

    /// @notice Large/emergency return: uncapped release by the cold owner (Safe).
    /// Not gated by pause, so exits can always be serviced while the hot path is
    /// frozen. Idempotent per `rhBurnNonce`. Does NOT touch the hot buckets.
    function ownerUnlock(uint256 amount, address to, uint256 rhBurnNonce) external onlyOwner nonReentrant {
        _release(amount, to, rhBurnNonce, true);
    }

    function _release(uint256 amount, address to, uint256 rhBurnNonce, bool viaOwner) internal {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (processedBurn[rhBurnNonce]) revert AlreadyProcessed(rhBurnNonce);
        processedBurn[rhBurnNonce] = true; // effects
        noxa.safeTransfer(to, amount); // interaction
        emit Unlocked(rhBurnNonce, to, amount, viaOwner);
    }

    /// @notice Disabled — renouncing would freeze all locked NOXA forever. Hand off
    /// via 2-step `transferOwnership`/`acceptOwnership`.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
