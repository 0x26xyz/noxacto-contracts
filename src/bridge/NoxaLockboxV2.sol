// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title NoxaLockboxV2 — hardened DBK-Chain custody for the NOXA <-> wNOXA bridge
/// @notice Successor to `NoxaLockbox`, addressing the 2026-07 audit's CRITICAL-1
/// (a single owner key could drain 100% of the lockbox, unstoppably, because the
/// original `unlock` was owner-only AND non-pausable). This version separates a
/// **hot, rate-limited** unlocker from the **cold** owner:
///
/// - Routine returns run through `unlock`, callable only by the hot `unlocker`
///   key, bounded by `unlockCap` per tx and `unlockCooldown` between txs, and
///   **freezable via `pause()`** — so a compromised relayer key can drain at most
///   one cap per cooldown before the owner pauses and rotates it.
/// - Large/emergency returns run through `ownerUnlock`, callable only by the cold
///   owner (a Safe), uncapped and NOT pausable — so genuine exits can always be
///   serviced even while the hot path is frozen.
///
/// `lock` accounting (fee-on-transfer safe, balance-delta) and the per-burn-nonce
/// replay guard are unchanged from `NoxaLockbox`. Renounce stays disabled. The
/// 1:1 backing invariant is still off-chain (the relayer binds amounts); this
/// only bounds the damage a leaked hot key can do before intervention.
contract NoxaLockboxV2 is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The DBK-Chain NOXA token being locked.
    IERC20 public immutable noxa;

    /// @notice Hot key allowed to call the rate-limited `unlock`. Rotatable by owner.
    address public unlocker;
    /// @notice Max NOXA a single `unlock` (hot path) may release. Owner-settable.
    uint256 public unlockCap;
    /// @notice Min seconds between hot-path `unlock` calls. Owner-settable.
    uint256 public unlockCooldown;
    /// @notice Timestamp of the last hot-path `unlock`.
    uint256 public lastUnlockAt;

    /// @notice Monotonic nonce for inbound (DBK -> RH) locks.
    uint256 public lockNonce;
    /// @notice Outbound replay guard: Robinhood burn nonces already released here
    /// (shared by both `unlock` and `ownerUnlock` — a burn settles once, either way).
    mapping(uint256 rhBurnNonce => bool) public processedBurn;

    event UnlockerSet(address indexed unlocker);
    event UnlockCapSet(uint256 cap);
    event UnlockCooldownSet(uint256 cooldown);
    /// @param nonce Inbound nonce; the Robinhood `mint` must consume exactly this value.
    /// @param received Fee-adjusted amount actually received — the amount to mint on RH.
    event Locked(uint256 indexed nonce, address indexed from, address indexed rhRecipient, uint256 received);
    /// @param rhBurnNonce The Robinhood `BurnedForReturn` nonce this release settles.
    /// @param viaOwner True if released through the uncapped owner path.
    event Unlocked(uint256 indexed rhBurnNonce, address indexed to, uint256 amount, bool viaOwner);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error NotUnlocker();
    error AboveUnlockCap(uint256 amount, uint256 cap);
    error CooldownActive(uint256 readyAt);
    error AlreadyProcessed(uint256 rhBurnNonce);
    error RenounceDisabled();

    /// @param noxa_ The DBK NOXA token address.
    /// @param bridgeAuthority_ Cold owner (Safe) — manages the hot unlocker, caps, pause.
    /// @param unlocker_ Hot relayer key for routine returns (may be set later if 0).
    /// @param unlockCap_ Per-tx release cap on the hot path.
    /// @param unlockCooldown_ Min seconds between hot-path releases.
    constructor(
        address noxa_,
        address bridgeAuthority_,
        address unlocker_,
        uint256 unlockCap_,
        uint256 unlockCooldown_
    ) Ownable(bridgeAuthority_) {
        if (noxa_ == address(0)) revert ZeroAddress();
        noxa = IERC20(noxa_);
        unlocker = unlocker_; // may be 0 at deploy; set before arming the relayer
        unlockCap = unlockCap_;
        unlockCooldown = unlockCooldown_;
        emit UnlockerSet(unlocker_);
        emit UnlockCapSet(unlockCap_);
        emit UnlockCooldownSet(unlockCooldown_);
    }

    // -----------------------------------------------------------------------
    // Owner config
    // -----------------------------------------------------------------------

    function setUnlocker(address unlocker_) external onlyOwner {
        unlocker = unlocker_;
        emit UnlockerSet(unlocker_);
    }

    function setUnlockCap(uint256 cap_) external onlyOwner {
        unlockCap = cap_;
        emit UnlockCapSet(cap_);
    }

    function setUnlockCooldown(uint256 cooldown_) external onlyOwner {
        unlockCooldown = cooldown_;
        emit UnlockCooldownSet(cooldown_);
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

    /// @notice Routine return: release NOXA to settle a Robinhood burn. Hot-path —
    /// `unlocker` only, capped by `unlockCap`, rate-limited by `unlockCooldown`, and
    /// haltable via `pause()`. Idempotent per `rhBurnNonce`.
    function unlock(uint256 amount, address to, uint256 rhBurnNonce) external nonReentrant whenNotPaused {
        if (msg.sender != unlocker) revert NotUnlocker();
        if (amount > unlockCap) revert AboveUnlockCap(amount, unlockCap);
        uint256 readyAt = lastUnlockAt + unlockCooldown;
        if (block.timestamp < readyAt) revert CooldownActive(readyAt);
        lastUnlockAt = block.timestamp; // effects before interaction
        _release(amount, to, rhBurnNonce, false);
    }

    /// @notice Large/emergency return: uncapped release by the cold owner (Safe).
    /// Not gated by pause, so exits can always be serviced while the hot path is
    /// frozen. Idempotent per `rhBurnNonce`.
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
