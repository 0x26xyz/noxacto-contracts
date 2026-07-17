// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {INonfungiblePositionManager} from "../interfaces/IUniswapV3.sol";

/// @title NoxaLpLock — permanent custodian for the wNOXA/WETH V3 position
/// @notice One-off analogue of `LpLocker` for the bridged-NOXA launch. The
/// factory-gated `LpLocker` only accepts positions from the LaunchpadFactory, so
/// the wNOXA seed (an externally-minted token) needs its own permanent lock.
///
/// Invariant (custody): there is NO code path that transfers the position NFT
/// out of this contract — the liquidity is locked forever. Only accrued V3
/// trading FEES can be extracted, and they go entirely to `feeRecipient`.
///
/// Hardening (audit): `onERC721Received` locks the FIRST NFT it receives, so it
/// is gated two ways to stop a front-runner from hijacking the lock slot with a
/// junk position before the real seed transfer lands:
///   1. the NFT must come from the expected `seeder` (the deploy/seed EOA), and
///   2. the position's token pair + fee must match the expected wNOXA/WETH pool.
/// Either check alone closes the front-run; both are enforced for defense in depth.
contract NoxaLpLock is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable positionManager;
    /// @notice Receives all collected trading fees (both sides).
    address public immutable feeRecipient;
    /// @notice The only address whose position transfer will be accepted+locked.
    address public immutable seeder;
    /// @notice Expected sorted pool tokens + fee of the seed position.
    address public immutable expectedToken0;
    address public immutable expectedToken1;
    uint24 public immutable expectedFee;

    /// @notice The single locked position id (set once on receipt).
    uint256 public lockedTokenId;
    bool public locked;

    event PositionLocked(uint256 indexed tokenId);
    event FeesClaimed(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    error UnknownPosition();
    error ZeroAddress();
    error AlreadyLocked();
    error NotLocked();
    error NotSeeder();
    error WrongPosition();

    /// @param positionManager_ Uniswap V3 NonfungiblePositionManager.
    /// @param feeRecipient_ Destination for collected fees (e.g. the NoxaFeeBurner).
    /// @param seeder_ The only address whose position will be accepted (the seed EOA).
    /// @param wnoxa_ Bridged wNOXA token.
    /// @param weth_ WETH.
    /// @param feeTier_ Pool fee tier (1% = 10000).
    constructor(
        address positionManager_,
        address feeRecipient_,
        address seeder_,
        address wnoxa_,
        address weth_,
        uint24 feeTier_
    ) {
        if (
            positionManager_ == address(0) || feeRecipient_ == address(0) || seeder_ == address(0)
                || wnoxa_ == address(0) || weth_ == address(0) || feeTier_ == 0
        ) {
            revert ZeroAddress();
        }
        positionManager = INonfungiblePositionManager(positionManager_);
        feeRecipient = feeRecipient_;
        seeder = seeder_;
        (expectedToken0, expectedToken1) = wnoxa_ < weth_ ? (wnoxa_, weth_) : (weth_, wnoxa_);
        expectedFee = feeTier_;
    }

    /// @notice Accept exactly one V3 position — from the expected seeder, matching
    /// the expected wNOXA/WETH pool — and lock it forever.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert UnknownPosition();
        if (from != seeder) revert NotSeeder();
        if (locked) revert AlreadyLocked();

        // Validate the position is the real wNOXA/WETH seed, not a look-alike.
        (,, address token0, address token1, uint24 fee,,,,,,,) = positionManager.positions(tokenId);
        if (token0 != expectedToken0 || token1 != expectedToken1 || fee != expectedFee) revert WrongPosition();

        locked = true;
        lockedTokenId = tokenId;
        emit PositionLocked(tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Collect accrued V3 trading fees for the locked position and send
    /// them to `feeRecipient`. Permissionless. Principal is never touched.
    /// @dev nonReentrant + checks-effects-interactions: the only external call is
    /// `collect`, which pays out to the immutable `feeRecipient`; no drainable state.
    function claimFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!locked) revert NotLocked();
        uint256 tokenId = lockedTokenId;

        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: feeRecipient,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit FeesClaimed(tokenId, amount0, amount1);
    }
}
