// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title NoxaLockbox — DBK-Chain custody for the NOXA <-> wNOXA bridge
/// @notice Locks real NOXA on DBK Chain to back `WrappedNoxa` (wNOXA) minted on
/// Robinhood Chain. Federated, custodial bridge; `WrappedNoxa` documents the
/// full trust model.
///
/// Invariant (collateralization): the NOXA held here MUST always cover the wNOXA
/// supply on Robinhood Chain, i.e. `NOXA.balanceOf(this) >= wNOXA.totalSupply()`.
/// This cannot be enforced on-chain across chains; it is preserved by:
///   1. minting wNOXA only against the fee-adjusted `received` amount below, and
///   2. releasing NOXA only via `unlock`, once per Robinhood burn nonce.
/// Off-chain monitoring MUST alert on any drift.
///
/// The source NOXA is **fee-on-transfer** (owner-configurable). Every inbound
/// transfer is therefore measured by balance delta — the requested `amount` is
/// never trusted. A hostile source-token owner could raise the fee toward 100%;
/// that only reduces what a locker receives (and thus mints), never over-mints.
contract NoxaLockbox is ReentrancyGuard, Ownable2Step, Pausable {
    using SafeERC20 for IERC20;

    /// @notice The DBK-Chain NOXA token being locked (0x6778...8dDE on mainnet).
    IERC20 public immutable noxa;

    /// @notice Monotonic nonce for inbound (DBK -> RH) locks.
    uint256 public lockNonce;
    /// @notice Outbound replay guard: Robinhood burn nonces already released here.
    mapping(uint256 rhBurnNonce => bool) public processedBurn;

    /// @param nonce Inbound nonce; the Robinhood `mint` must consume exactly this value.
    /// @param received Fee-adjusted amount actually received — the amount to mint on RH.
    event Locked(uint256 indexed nonce, address indexed from, address indexed rhRecipient, uint256 received);
    /// @param rhBurnNonce The Robinhood `BurnedForReturn` nonce this release settles.
    event Unlocked(uint256 indexed rhBurnNonce, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NothingReceived();
    error AlreadyProcessed(uint256 rhBurnNonce);
    error RenounceDisabled();

    /// @param noxa_ The DBK NOXA token address.
    /// @param bridgeAuthority_ Multisig that owns unlock rights (also the Ownable owner).
    constructor(address noxa_, address bridgeAuthority_) Ownable(bridgeAuthority_) {
        // `bridgeAuthority_ == 0` is already rejected by Ownable (OwnableInvalidOwner).
        if (noxa_ == address(0)) revert ZeroAddress();
        noxa = IERC20(noxa_);
    }

    /// @notice Lock NOXA to bridge it to Robinhood Chain. Measures the actual
    /// received amount (fee-on-transfer safe) and emits it for the RH mint.
    /// @param amount Amount to pull from the caller (pre-fee).
    /// @param rhRecipient Address to receive wNOXA on Robinhood Chain.
    /// @return nonce Inbound nonce the RH mint must reference.
    /// @return received Fee-adjusted amount that will be minted on RH.
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

    /// @notice Release locked NOXA to settle a Robinhood-side burn. Authority-only,
    /// idempotent per `rhBurnNonce`. Not blocked by pause so users can always exit.
    /// @param amount Amount of NOXA to release from the lockbox (matches the burned wNOXA).
    /// @param to DBK recipient. Receives fee-adjusted NOXA (source token taxes the transfer).
    /// @param rhBurnNonce The Robinhood `BurnedForReturn` nonce being settled.
    function unlock(uint256 amount, address to, uint256 rhBurnNonce) external onlyOwner nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (processedBurn[rhBurnNonce]) revert AlreadyProcessed(rhBurnNonce);
        processedBurn[rhBurnNonce] = true;

        noxa.safeTransfer(to, amount);
        emit Unlocked(rhBurnNonce, to, amount);
    }

    /// @notice Emergency stop for new inbound locks (exits via `unlock` stay open).
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled. `Ownable.renounceOwnership` is a one-step, irreversible
    /// footgun: renouncing here would make `unlock` permanently uncallable and
    /// freeze ALL locked NOXA collateral forever. Ownership can still be handed
    /// over via the 2-step `transferOwnership`/`acceptOwnership` (e.g. to a Safe).
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
