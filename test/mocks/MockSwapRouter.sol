// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "../../src/interfaces/IUniswapV3.sol";

/// @dev TEST-ONLY Uniswap V3 SwapRouter stand-in for BuybackTreasury tests. Pulls
/// `amountIn` of tokenIn from the caller and sends an equal amount of tokenOut to
/// `recipient` (1:1), enforcing `amountOutMinimum` like the real router. Pre-fund
/// this router with tokenOut in the test.
contract MockSwapRouter {
    error TooLittleReceived();

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p) external returns (uint256 amountOut) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = p.amountIn; // 1:1 for tests
        if (amountOut < p.amountOutMinimum) revert TooLittleReceived();
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }
}
