// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter} from "../interfaces/IUniswapV3.sol";

/// @dev The wNOXA burn-back path used to return 100% of fees to real NOXA.
interface IWrappedNoxaBurn {
    function burnForReturn(uint256 amount, address dbkRecipient) external returns (uint256 nonce);
}

/// @title NoxaFeeBurner — routes 100% of bridged-NOXA LP fees back to real NOXA
/// @notice Set as the `feeRecipient` of `NoxaLpLock`, so it receives ALL trading
/// fees (wNOXA + WETH) from the wNOXA/WETH pool on Robinhood Chain. On `burn()`:
///   1. swaps the WETH side into wNOXA (a real buy in the pool), then
///   2. `burnForReturn`s the entire wNOXA balance to a dead address on DBK.
///
/// The relayer settles that burn by releasing the matching real NOXA from the
/// lockbox to the dead address on DBK — permanently removing it from circulation.
/// Net effect: every unit of fee value becomes real-NOXA supply reduction, which
/// accrues to all NOXA holders. The peg is preserved (wNOXA burned == collateral
/// burned, still 1:1). This mirrors NOXA's own buyback-and-burn of Robinhood fees.
///
/// Note: NOXA is fee-on-transfer, so the dead-address transfer on DBK may route a
/// small cut to NOXA's fee sink; the remainder is burned. wNOXA/WETH are clean.
contract NoxaFeeBurner is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Standard burn sink on DBK — real NOXA sent here leaves circulation.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable wnoxa;
    IERC20 public immutable weth;
    ISwapRouter public immutable swapRouter;
    /// @notice wNOXA/WETH pool fee tier (1% = 10000, matching the launchpad).
    uint24 public immutable feeTier;
    /// @notice Optional keeper that alone may call `burn` (anti-MEV). 0 = permissionless.
    address public immutable keeper;

    event FeesBurned(uint256 wethSwapped, uint256 wnoxaBurned, uint256 returnNonce);

    error ZeroConfig();
    error NotKeeper();
    error NothingToBurn();

    constructor(address wnoxa_, address weth_, address swapRouter_, uint24 feeTier_, address keeper_) {
        if (wnoxa_ == address(0) || weth_ == address(0) || swapRouter_ == address(0) || feeTier_ == 0) {
            revert ZeroConfig();
        }
        wnoxa = IERC20(wnoxa_);
        weth = IERC20(weth_);
        swapRouter = ISwapRouter(swapRouter_);
        feeTier = feeTier_;
        keeper = keeper_; // may be zero (permissionless)
    }

    /// @notice Convert accrued WETH fees into wNOXA and burn ALL held wNOXA back to
    /// real NOXA on DBK. Call `NoxaLpLock.claimFees()` first to push fees here.
    /// @param minWNoxaOut Minimum wNOXA out of the WETH swap (slippage/MEV guard).
    ///        Pass 0 only if there is no WETH to swap or you accept any price.
    /// @return returnNonce The wNOXA `BurnedForReturn` nonce the relayer will settle.
    function burn(uint256 minWNoxaOut) external nonReentrant returns (uint256 returnNonce) {
        if (keeper != address(0) && msg.sender != keeper) revert NotKeeper();

        // 1. Swap the WETH side into wNOXA (a real buy in the pool).
        uint256 wethBal = weth.balanceOf(address(this));
        uint256 swapped;
        if (wethBal != 0) {
            weth.forceApprove(address(swapRouter), wethBal);
            swapped = swapRouter.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(weth),
                    tokenOut: address(wnoxa),
                    fee: feeTier,
                    recipient: address(this),
                    amountIn: wethBal,
                    amountOutMinimum: minWNoxaOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // 2. Burn the entire wNOXA balance back to real NOXA on DBK (dead address).
        uint256 wnoxaBal = wnoxa.balanceOf(address(this));
        if (wnoxaBal == 0) revert NothingToBurn();
        returnNonce = IWrappedNoxaBurn(address(wnoxa)).burnForReturn(wnoxaBal, DEAD);

        emit FeesBurned(swapped, wnoxaBal, returnNonce);
    }
}
