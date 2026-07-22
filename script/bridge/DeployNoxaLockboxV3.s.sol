// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NoxaLockboxV3} from "../../src/bridge/NoxaLockboxV3.sol";

/// @dev Deploys a per-version NoxaLockboxV3 on **DBK Chain**, paired to one wNOXA.
///
///   forge script script/bridge/DeployNoxaLockboxV3.s.sol:DeployNoxaLockboxV3 \
///     --rpc-url $DBK_RPC_URL --broadcast \
///     --with-gas-price 3000000 --priority-gas-price 2000000
///
/// Env:
///   NOXA_ADDRESS             DBK NOXA token
///   WRAPPED_NOXA_ADDRESS     the RH wNOXA this box settles for (recorded on-chain)
///   BRIDGE_AUTHORITY_COLD    cold owner (Safe/EOA) — manages unlocker, budgets, pause
///   BRIDGE_UNLOCKER          hot relayer key allowed to call unlock (may be 0 to set later)
///   UNLOCK_CAP_PER_WINDOW    hot-path VALUE budget per window (wei). MUST be non-zero.
///   UNLOCK_COUNT_PER_WINDOW  hot-path SETTLEMENT-COUNT budget per window. MUST be non-zero.
///   UNLOCK_WINDOW            leaky-bucket decay length in seconds. MUST be non-zero.
///
/// One lockbox per wNOXA version — never point a new wNOXA at an existing box
/// (its `processedBurn` map carries the old version's consumed nonces; the new
/// token restarts burnNonce at 0 and its early exits would silently strand).
///
/// FUNDING HAZARD (round-2 NEW-4): funding this box means `ownerUnlock`-ing from
/// the previous box, which BURNS an `rhBurnNonce` there — and NoxaLockboxV2 has
/// no `clearProcessedBurn`. Use a reserved high nonce that no real burn reaches
/// (e.g. type(uint256).max) for the funding release, and fund BEFORE repointing
/// the relayer (repoint-first leaves a window where v3 exits revert and the
/// relayer head-of-line blocks).
contract DeployNoxaLockboxV3 is Script {
    function run() external {
        address noxa = vm.envAddress("NOXA_ADDRESS");
        address wnoxa = vm.envAddress("WRAPPED_NOXA_ADDRESS");
        address cold = vm.envAddress("BRIDGE_AUTHORITY_COLD");
        address unlocker = vm.envOr("BRIDGE_UNLOCKER", address(0));
        uint256 cap = vm.envUint("UNLOCK_CAP_PER_WINDOW");
        uint256 count = vm.envUint("UNLOCK_COUNT_PER_WINDOW");
        uint256 window = vm.envUint("UNLOCK_WINDOW");
        require(noxa != address(0) && wnoxa != address(0) && cold != address(0), "core addr unset");
        require(cap != 0 && count != 0 && window != 0, "budget unset");

        // DBK deploy — broadcast with the DBK-funded key. Ownership is set to the
        // cold Safe in the constructor regardless of who deploys.
        uint256 pk = vm.envUint("DBK_DEPLOY_KEY");
        vm.startBroadcast(pk);
        NoxaLockboxV3 lockbox = new NoxaLockboxV3(noxa, wnoxa, cold, unlocker, cap, count, window);
        vm.stopBroadcast();

        console2.log("NoxaLockboxV3:      ", address(lockbox));
        console2.log("  noxa:             ", noxa);
        console2.log("  wrappedNoxa:      ", wnoxa);
        console2.log("  owner (cold):     ", cold);
        console2.log("  unlocker (hot):   ", unlocker);
        console2.log("  capPerWindow:     ", cap);
        console2.log("  countPerWindow:   ", count);
        console2.log("  window (s):       ", window);
        console2.log("NEXT: fund it (ownerUnlock from the old box, RESERVED high nonce),");
        console2.log("      then repoint the relayer LOCKBOX_ADDRESS + DBK_START_BLOCK.");
    }
}
