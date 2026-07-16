// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title WrappedNoxa (wNOXA) — Robinhood Chain mirror of DBK-Chain NOXA
/// @notice Synthetic ERC-20 minted 1:1 against real NOXA locked in the
/// `NoxaLockbox` on DBK Chain. This is a **federated, custodial bridge**: the
/// peg is only as trustworthy as the bridge authority (a multisig). Market this
/// as *bridged* NOXA, never the canonical token.
///
/// Design notes vs the source token:
/// - The source NOXA is fee-on-transfer; wNOXA is a **clean** ERC-20 with no
///   tax. The peg is held by locked collateral, not by mirroring fees.
/// - Fixed source supply (1,000,000) is non-dilutable, but this mirror cannot
///   see DBK collateral, so mint authority is trusted. Off-chain monitoring MUST
///   assert `NOXA.balanceOf(lockbox) >= wNOXA.totalSupply()` at all times.
///
/// Bridge flow:
/// - Inbound (DBK -> RH): user locks NOXA on DBK (emits `Locked(nonce,...)`);
///   the authority calls `mint(to, amount, srcLockNonce)` here, once per nonce.
/// - Outbound (RH -> DBK): user calls `burnForReturn(amount, dbkRecipient)`;
///   the authority observes `BurnedForReturn(nonce,...)` and releases NOXA from
///   the lockbox on DBK.
contract WrappedNoxa is ERC20, Ownable2Step {
    /// @notice Inbound replay guard: DBK lock nonces already minted here.
    mapping(uint256 srcLockNonce => bool) public processedLock;

    /// @notice Monotonic nonce for outbound (RH -> DBK) burns.
    uint256 public burnNonce;

    /// @param srcLockNonce The `Locked` event nonce on the DBK lockbox this mint settles.
    event Minted(uint256 indexed srcLockNonce, address indexed to, uint256 amount);
    /// @param nonce Outbound nonce; the DBK `unlock` must consume exactly this value.
    event BurnedForReturn(uint256 indexed nonce, address indexed burner, address indexed dbkRecipient, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error AlreadyProcessed(uint256 srcLockNonce);
    error RenounceDisabled();

    /// @param bridgeAuthority_ Multisig that owns mint rights (also the Ownable owner).
    constructor(address bridgeAuthority_) ERC20("Wrapped NOXA (DBK)", "wNOXA") Ownable(bridgeAuthority_) {
        // `bridgeAuthority_ == 0` is already rejected by Ownable (OwnableInvalidOwner).
    }

    /// @notice Settle an inbound bridge: mint wNOXA for a DBK lock. Idempotent
    /// per `srcLockNonce`, so a relayer replay is harmless.
    /// @dev `amount` MUST equal the fee-adjusted `received` amount emitted by the
    /// DBK `Locked` event — never the user's requested lock amount.
    function mint(address to, uint256 amount, uint256 srcLockNonce) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (processedLock[srcLockNonce]) revert AlreadyProcessed(srcLockNonce);
        processedLock[srcLockNonce] = true;
        _mint(to, amount);
        emit Minted(srcLockNonce, to, amount);
    }

    /// @notice Begin an outbound bridge: burn the caller's wNOXA and signal the
    /// authority to release NOXA from the DBK lockbox to `dbkRecipient`.
    /// @dev The user receives fee-adjusted NOXA on DBK (the source token taxes
    /// the release transfer); the peg is preserved because exactly `amount` of
    /// backing is freed from the lockbox.
    function burnForReturn(uint256 amount, address dbkRecipient) external returns (uint256 nonce) {
        if (amount == 0) revert ZeroAmount();
        if (dbkRecipient == address(0)) revert ZeroAddress();
        _burn(msg.sender, amount); // reverts on insufficient balance
        nonce = burnNonce++;
        emit BurnedForReturn(nonce, msg.sender, dbkRecipient, amount);
    }

    /// @notice Disabled. Renouncing would make `mint` permanently uncallable and
    /// strand anyone who locked NOXA on DBK awaiting settlement. Hand over via the
    /// 2-step `transferOwnership`/`acceptOwnership` instead (e.g. to a Safe).
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
