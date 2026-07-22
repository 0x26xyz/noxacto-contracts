// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NoxaFeeBurner} from "../../src/bridge/NoxaFeeBurner.sol";

/// @dev Deploys the NoxaFeeBurner on **Robinhood Chain**. This becomes the
/// `SEED_FEE_RECIPIENT` for SeedWrappedNoxaLiquidity, so 100% of the wNOXA/WETH
/// LP fees route here and get burned back to real NOXA on DBK.
///
///   forge script script/bridge/DeployNoxaFeeBurner.s.sol:DeployNoxaFeeBurner \
///     --rpc-url $RH_RPC_URL --broadcast --verify
///
/// SWAP_ROUTER MUST be the SwapRouter02 whose WETH9()/factory() match the pool's
/// WETH / V3 factory (same one the launchpad uses — NOT the UniversalRouter).
/// BURN_KEEPER is MANDATORY (review MED-2): `claimFees` is permissionless, so a
/// permissionless `burn` would be sandwichable; the keeper submits `burn` with a
/// quote-derived `minWNoxaOut` (a private-relay/keeper EOA).
contract DeployNoxaFeeBurner is Script {
    function run() external {
        address wnoxa = vm.envAddress("WRAPPED_NOXA_ADDRESS");
        address weth = vm.envAddress("WETH_ADDRESS");
        address swapRouter = vm.envAddress("SWAP_ROUTER");
        uint24 feeTier = uint24(vm.envUint("LAUNCH_FEE_TIER"));
        address keeper = vm.envAddress("BURN_KEEPER");
        // Cold owner that can rotate a leaked keeper (defaults to BRIDGE_AUTHORITY).
        address owner = vm.envOr("BURN_KEEPER_OWNER", vm.envAddress("BRIDGE_AUTHORITY"));

        require(wnoxa != address(0), "WRAPPED_NOXA_ADDRESS unset");
        require(weth != address(0), "WETH_ADDRESS unset");
        require(swapRouter != address(0), "SWAP_ROUTER unset (SwapRouter02)");
        require(feeTier != 0, "LAUNCH_FEE_TIER unset");
        require(keeper != address(0), "BURN_KEEPER unset (mandatory, MED-2)");
        require(owner != address(0), "BURN_KEEPER_OWNER/BRIDGE_AUTHORITY unset");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        NoxaFeeBurner burner = new NoxaFeeBurner(wnoxa, weth, swapRouter, feeTier, keeper, owner);
        vm.stopBroadcast();

        console2.log("NoxaFeeBurner:   ", address(burner));
        console2.log("  keeper:        ", keeper);
        console2.log("  owner:         ", owner);
        console2.log("Set SEED_FEE_RECIPIENT to this address before seeding liquidity.");
    }
}
