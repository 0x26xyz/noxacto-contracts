// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title WrappedNoxaV2 (wNOXA) — hardened Robinhood-Chain mirror of DBK NOXA
/// @notice Successor to `WrappedNoxa`, addressing the 2026-07 audit's CRITICAL-1
/// (single owner key = unlimited unbacked mint). The trust model is unchanged —
/// this is still a federated, custodial bridge whose peg rests on the relayer +
/// off-chain monitoring — but the blast radius of a compromised *hot* key is now
/// bounded:
///
/// - **Mint authority is a revocable role, not ownership.** The cold owner (a
///   Safe) grants `isMinter` to the hot relayer key and to the migration helper;
///   it never has to be the hot key itself, and can revoke a leaked key.
/// - **Hard supply cap.** `ERC20Capped` bounds total supply to the real source
///   NOXA supply, so even a compromised minter cannot mint beyond what could ever
///   be collateralised.
/// - **Circuit breaker.** `pause()` freezes ALL mint/burn/transfer — a kill
///   switch for an incident or a clean migration cutover.
///
/// Renounce stays disabled; hand off via 2-step `transferOwnership` (e.g. to a
/// Safe). See `WrappedNoxa` for the original design notes and bridge flow.
contract WrappedNoxaV2 is ERC20Capped, Ownable2Step, Pausable {
    /// @notice Addresses allowed to mint (the hot relayer key; the migrator during cutover).
    mapping(address account => bool) public isMinter;

    /// @notice Inbound replay guard: DBK lock nonces already minted here.
    mapping(uint256 srcLockNonce => bool) public processedLock;

    /// @notice Monotonic nonce for outbound (RH -> DBK) burns.
    uint256 public burnNonce;

    event MinterSet(address indexed account, bool allowed);
    /// @param srcLockNonce The `Locked` event nonce on the DBK lockbox this mint settles.
    event Minted(uint256 indexed srcLockNonce, address indexed to, uint256 amount);
    /// @notice Emitted for a migration mint (escrow-backed, no bridge nonce consumed).
    event MigrationMinted(address indexed to, uint256 amount);
    /// @param nonce Outbound nonce; the DBK `unlock` must consume exactly this value.
    event BurnedForReturn(uint256 indexed nonce, address indexed burner, address indexed dbkRecipient, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NotMinter();
    error AlreadyProcessed(uint256 srcLockNonce);
    error RenounceDisabled();

    /// @param bridgeAuthority_ Cold owner (Safe) — manages minters, cap-bounded mint, pause.
    /// @param maxSupply_ Hard cap on wNOXA supply; set to the real DBK NOXA total supply
    ///        (e.g. 1_000_000e18). Bounds a compromised minter. Must be non-zero.
    constructor(address bridgeAuthority_, uint256 maxSupply_)
        ERC20("Wrapped NOXA (DBK)", "wNOXA")
        ERC20Capped(maxSupply_)
        Ownable(bridgeAuthority_)
    {
        // bridgeAuthority_ == 0 rejected by Ownable; maxSupply_ == 0 rejected by ERC20Capped.
    }

    // -----------------------------------------------------------------------
    // Owner: role + circuit-breaker management
    // -----------------------------------------------------------------------

    /// @notice Grant or revoke mint rights. Owner (Safe) only. Revoking a leaked
    /// hot key is the primary incident response short of `pause()`.
    function setMinter(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isMinter[account] = allowed;
        emit MinterSet(account, allowed);
    }

    /// @notice Freeze all token movement (mint/burn/transfer). Owner only.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -----------------------------------------------------------------------
    // Bridge mint (relayer) + migration mint (escrow helper)
    // -----------------------------------------------------------------------

    /// @notice Settle an inbound bridge: mint wNOXA for a DBK lock. Idempotent per
    /// `srcLockNonce`. `amount` MUST equal the fee-adjusted `received` from the DBK
    /// `Locked` event. Minter-gated; cap-bounded via `_update`.
    function mint(address to, uint256 amount, uint256 srcLockNonce) external onlyMinter whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (processedLock[srcLockNonce]) revert AlreadyProcessed(srcLockNonce);
        processedLock[srcLockNonce] = true;
        _mint(to, amount);
        emit Minted(srcLockNonce, to, amount);
    }

    /// @notice Mint for a 1:1 migration from a prior wNOXA version. Used by the
    /// escrow `WNoxaMigrator`, which mints only against old wNOXA it has escrowed —
    /// so the DBK collateral backing the escrowed tokens now backs these. Carries
    /// NO bridge nonce (must not touch `processedLock`, which would collide with a
    /// real DBK lock nonce). Cap-bounded; the migrator's escrow bounds it to the
    /// old supply. Grant the migrator `isMinter` for the cutover, then revoke.
    function mintMigration(address to, uint256 amount) external onlyMinter whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
        emit MigrationMinted(to, amount);
    }

    /// @notice Begin an outbound bridge: burn the caller's wNOXA and signal the
    /// authority to release NOXA from the DBK lockbox to `dbkRecipient`.
    function burnForReturn(uint256 amount, address dbkRecipient) external whenNotPaused returns (uint256 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (dbkRecipient == address(0)) revert ZeroAddress();
        _burn(msg.sender, amount); // reverts on insufficient balance
        nonce = burnNonce++;
        emit BurnedForReturn(nonce, msg.sender, dbkRecipient, amount);
    }

    /// @notice Disabled — renouncing would strand DBK lockers awaiting settlement.
    /// Hand off via 2-step `transferOwnership`/`acceptOwnership`.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // -----------------------------------------------------------------------
    // Internal
    // -----------------------------------------------------------------------

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert NotMinter();
        _;
    }

    /// @dev Single hook enforcing both the pause circuit-breaker (all movement) and
    /// the supply cap (mint only, via ERC20Capped).
    function _update(address from, address to, uint256 value) internal override(ERC20Capped) {
        _requireNotPaused();
        super._update(from, to, value);
    }
}
