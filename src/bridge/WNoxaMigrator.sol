// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @notice Minimal mint hook implemented by `WrappedNoxaV2.mintMigration`.
interface IMigrationMintable {
    function mintMigration(address to, uint256 amount) external;
}

/// @title WNoxaMigrator — 1:1 escrow upgrade from an old wNOXA to a new wNOXA
/// @notice Lets a holder of a deprecated wNOXA move to the hardened version in one
/// step. It **escrows** the old token and **mints** the new one 1:1 — it does NOT
/// burn the old token.
///
/// Why escrow, not burn (audit finding): the old wNOXA's only burn path
/// (`burnForReturn`) signals the DBK lockbox to RELEASE collateral. Burning during
/// migration would therefore drain the very NOXA that must keep backing the new
/// token. By escrowing the old wNOXA untouched, the old lockbox's collateral stays
/// locked and now backs the newly minted tokens. Total system backing is conserved;
/// the operator later reconciles collateral old-lockbox -> new-lockbox by sweeping
/// the escrow (`sweepEscrow`) and running it back through the old bridge.
///
/// Safety: `newToken` is minted only against old tokens actually received
/// (balance-delta), so `newMinted <= oldEscrowed <= oldSupply` — the migrator can
/// never mint more new wNOXA than old wNOXA it holds. Grant this contract the new
/// token's minter role for the cutover window, then revoke it.
///
/// Reusable: parameterised by `(oldToken, newToken)`, so the next migration is just
/// a fresh instance pointed at the new pair — no rewrite.
contract WNoxaMigrator is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice Deprecated wNOXA being escrowed (any ERC-20; balance-delta measured).
    IERC20 public immutable oldToken;
    /// @notice Hardened wNOXA being minted 1:1. This contract must hold its minter role.
    IMigrationMintable public immutable newToken;

    /// @notice Total old tokens escrowed (== total new minted by this migrator).
    uint256 public totalMigrated;

    event Migrated(address indexed account, uint256 amount);
    event EscrowSwept(address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error RenounceDisabled();

    /// @param oldToken_ The deprecated wNOXA to escrow.
    /// @param newToken_ The hardened wNOXA to mint (this contract needs its minter role).
    /// @param owner_ Cold owner (Safe) — can pause and sweep the escrow for reconciliation.
    constructor(address oldToken_, address newToken_, address owner_) Ownable(owner_) {
        if (oldToken_ == address(0) || newToken_ == address(0)) revert ZeroAddress();
        oldToken = IERC20(oldToken_);
        newToken = IMigrationMintable(newToken_);
    }

    /// @notice Upgrade `amount` of old wNOXA to new wNOXA 1:1. Caller must approve
    /// this contract for `amount` of the old token first. Mints exactly the amount
    /// actually escrowed (fee-on-transfer safe).
    function migrate(uint256 amount) external nonReentrant whenNotPaused returns (uint256 minted) {
        if (amount == 0) revert ZeroAmount();

        uint256 bal0 = oldToken.balanceOf(address(this));
        oldToken.safeTransferFrom(msg.sender, address(this), amount);
        minted = oldToken.balanceOf(address(this)) - bal0; // escrowed amount, fee-safe
        if (minted == 0) revert NothingReceived();

        totalMigrated += minted; // effects before mint
        newToken.mintMigration(msg.sender, minted);
        emit Migrated(msg.sender, minted);
    }

    /// @notice Withdraw escrowed old wNOXA for collateral reconciliation. Owner
    /// (Safe) only. The operator runs the swept old wNOXA back through the old
    /// bridge (`burnForReturn`) to move its DBK collateral into the new lockbox.
    /// Does not affect new-token supply or holders.
    function sweepEscrow(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        oldToken.safeTransfer(to, amount);
        emit EscrowSwept(to, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled to keep sweep/pause control intact; hand off via 2-step transfer.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
