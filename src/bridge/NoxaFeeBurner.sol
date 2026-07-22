// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
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
contract NoxaFeeBurner is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @notice Standard burn sink on DBK — real NOXA sent here leaves circulation.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IERC20 public immutable wnoxa;
    IERC20 public immutable weth;
    ISwapRouter public immutable swapRouter;
    /// @notice wNOXA/WETH pool fee tier (1% = 10000, matching the launchpad).
    uint24 public immutable feeTier;
    /// @notice The keeper that alone may call `burn`. MANDATORY (review MED-2):
    /// `claimFees()` on the lock is permissionless, so a permissionless `burn`
    /// would let anyone sandwich the WETH->wNOXA swap in a thin 1% pool and
    /// extract 100% of accrued fee value. The keeper supplies `minWNoxaOut`.
    /// ROTATABLE by the cold owner (`setKeeper`) — a leaked keeper is revocable,
    /// mirroring `WrappedNoxaV3.setMinter`, so the flywheel isn't permanently
    /// griefable and the whole stack need not be redeployed (round-3 finding).
    address public keeper;

    event FeesBurned(uint256 wethSwapped, uint256 wnoxaBurned, uint256 returnNonce);
    event KeeperSet(address indexed keeper);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    error ZeroConfig();
    error NotKeeper();
    error NothingToBurn();
    error ZeroAddress();
    error ZeroAmount();
    error RenounceDisabled();

    /// @param owner_ Cold owner (Safe) that may rotate the keeper. Non-zero.
    /// @param keeper_ Initial keeper (the private-relay/keeper EOA). Non-zero.
    constructor(address wnoxa_, address weth_, address swapRouter_, uint24 feeTier_, address keeper_, address owner_)
        Ownable(owner_)
    {
        if (
            wnoxa_ == address(0) || weth_ == address(0) || swapRouter_ == address(0) || feeTier_ == 0
                || keeper_ == address(0) // keeper is mandatory — see MED-2
        ) {
            revert ZeroConfig();
        }
        wnoxa = IERC20(wnoxa_);
        weth = IERC20(weth_);
        swapRouter = ISwapRouter(swapRouter_);
        feeTier = feeTier_;
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Rotate the keeper. Cold owner (Safe) only. Primary response to a
    /// leaked keeper key — no need to redeploy the burner (whose `feeRecipient`
    /// binding on the locked LP position is immutable).
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroConfig();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Recover tokens stranded on the burner — WETH that cannot be swapped
    /// (a broken or too-thin pool leaves `burn` reverting with the WETH trapped),
    /// or any airdrop. The burner only ever holds fee value in transit, never peg
    /// collateral, so an owner sweep touches no invariant. Owner (Safe) only.
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /// @notice Disabled — renouncing would strand keeper rotation. Hand off via
    /// 2-step `transferOwnership`.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Convert accrued WETH fees into wNOXA and burn ALL held wNOXA back to
    /// real NOXA on DBK. Call `NoxaLpLock.claimFees()` first to push fees here.
    /// @param minWNoxaOut Minimum wNOXA out of the WETH swap (slippage/MEV guard);
    ///        the keeper derives it off-chain from a quote/TWAP. Pass 0 only if
    ///        there is no WETH to swap.
    /// @return returnNonce The wNOXA `BurnedForReturn` nonce the relayer will settle.
    function burn(uint256 minWNoxaOut) external nonReentrant returns (uint256 returnNonce) {
        if (msg.sender != keeper) revert NotKeeper(); // keeper mandatory (MED-2)

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
