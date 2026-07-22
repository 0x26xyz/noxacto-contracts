// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV3Factory, IUniswapV3Pool, INonfungiblePositionManager} from "../../src/interfaces/IUniswapV3.sol";
import {NoxaLpLock} from "../../src/bridge/NoxaLpLock.sol";

/// @dev Seeds a **single-sided, permanently-locked** wNOXA/WETH Uniswap V3 pool
/// on Robinhood Chain and locks the position forever — the same L3 discipline as
/// the launchpad: token-only seed, ZERO WETH consumed.
///
///   forge script script/bridge/SeedWrappedNoxaLiquidity.s.sol:SeedWrappedNoxaLiquidity \
///     --rpc-url $RH_RPC_URL --broadcast
///
/// The broadcasting key MUST already hold `SEED_WNOXA_AMOUNT` of wNOXA (bridge a
/// founder tranche through the lockbox first). Deploys a fresh `NoxaLpLock`,
/// mints the one-sided position, and locks it. Reverts wholesale if any WETH
/// would be consumed (mispriced range) or if liquidity is zero (L3/L5).
///
/// Set `SEED_FEE_RECIPIENT` to the deployed `NoxaFeeBurner` (script/bridge/
/// DeployNoxaFeeBurner.s.sol) so 100% of LP fees are bought back and burned into
/// real NOXA on DBK. (Any address works; the burner is the buyback-and-burn path.)
contract SeedWrappedNoxaLiquidity is Script {
    using SafeERC20 for IERC20;

    struct Cfg {
        address wnoxa;
        address weth;
        address v3Factory;
        address pm;
        uint24 feeTier;
        uint256 seedAmount;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        address feeRecipient;
    }

    function _load() internal view returns (Cfg memory c) {
        c.wnoxa = vm.envAddress("WNOXA_ADDRESS");
        c.weth = vm.envAddress("WETH_ADDRESS");
        c.v3Factory = vm.envAddress("UNISWAP_V3_FACTORY");
        c.pm = vm.envAddress("UNISWAP_V3_POSITION_MANAGER");
        c.feeTier = uint24(vm.envUint("LAUNCH_FEE_TIER"));
        c.seedAmount = vm.envUint("SEED_WNOXA_AMOUNT");
        c.sqrtPriceX96 = uint160(vm.envUint("SEED_SQRT_PRICE_X96"));
        c.tickLower = int24(vm.envInt("SEED_TICK_LOWER"));
        c.tickUpper = int24(vm.envInt("SEED_TICK_UPPER"));
        c.feeRecipient = vm.envAddress("SEED_FEE_RECIPIENT");

        require(c.wnoxa != address(0) && c.weth != address(0), "token addr unset");
        require(c.v3Factory != address(0) && c.pm != address(0), "uniswap addr unset");
        require(c.feeTier != 0 && c.seedAmount != 0 && c.sqrtPriceX96 != 0, "seed params unset");
    }

    function run() external {
        Cfg memory c = _load();
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);

        // seeder = msg.sender (this same broadcaster transfers the position below);
        // the lock also validates the position is the real wNOXA/WETH pool.
        NoxaLpLock lock = new NoxaLpLock(c.pm, c.feeRecipient, msg.sender, c.wnoxa, c.weth, c.feeTier);

        address pool = IUniswapV3Factory(c.v3Factory).getPool(c.wnoxa, c.weth, c.feeTier);
        if (pool == address(0)) {
            pool = IUniswapV3Factory(c.v3Factory).createPool(c.wnoxa, c.weth, c.feeTier);
            IUniswapV3Pool(pool).initialize(c.sqrtPriceX96);
        }

        (uint256 tokenId, uint128 liquidity, uint256 wNoxaUsed) = _mintSingleSided(c, msg.sender);

        // Lock the position forever.
        INonfungiblePositionManager(c.pm).safeTransferFrom(msg.sender, address(lock), tokenId);

        vm.stopBroadcast();

        console2.log("NoxaLpLock:      ", address(lock));
        console2.log("pool:            ", pool);
        console2.log("positionId:      ", tokenId);
        console2.log("liquidity:       ", uint256(liquidity));
        console2.log("wNOXA seeded:    ", wNoxaUsed);
    }

    /// @dev Mints the token-only position; enforces L3 (zero WETH) and L5 (non-empty).
    function _mintSingleSided(Cfg memory c, address recipient)
        internal
        returns (uint256 tokenId, uint128 liquidity, uint256 wNoxaUsed)
    {
        bool tokenIsToken0 = c.wnoxa < c.weth;
        (address token0, address token1) = tokenIsToken0 ? (c.wnoxa, c.weth) : (c.weth, c.wnoxa);
        (uint256 amt0, uint256 amt1) = tokenIsToken0 ? (c.seedAmount, uint256(0)) : (uint256(0), c.seedAmount);

        IERC20(c.wnoxa).forceApprove(c.pm, c.seedAmount);

        uint256 used0;
        uint256 used1;
        (tokenId, liquidity, used0, used1) = INonfungiblePositionManager(c.pm).mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: c.feeTier,
                tickLower: c.tickLower,
                tickUpper: c.tickUpper,
                amount0Desired: amt0,
                amount1Desired: amt1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                // Buffer the deadline: forge mines the broadcast a few seconds
                // after the run() sim, so a bare block.timestamp deadline is
                // already stale ("Transaction too old") by mining time.
                deadline: block.timestamp + 3600
            })
        );

        // L3: zero WETH consumed. L5: the seed must be real (non-empty).
        require((tokenIsToken0 ? used1 : used0) == 0, "L3: WETH consumed");
        require(liquidity != 0, "L5: empty liquidity");
        wNoxaUsed = tokenIsToken0 ? used0 : used1;
    }
}
