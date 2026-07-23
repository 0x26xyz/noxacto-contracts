// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NoxaLockboxManager} from "../../src/bridge/NoxaLockboxManager.sol";

/// @dev Deploys the sharded-custody NoxaLockboxManager on **DBK Chain** — the
/// fleet that lifts the single-lockbox 25K ceiling. The wNOXA (RH side) is
/// unchanged; this REPLACES the DBK lockbox the relayer settles against.
///
///   forge script script/bridge/DeployNoxaLockboxManager.s.sol:DeployNoxaLockboxManager \
///     --rpc-url $DBK_RPC_URL --broadcast \
///     --with-gas-price 3000000 --priority-gas-price 2000000
///
/// Env:
///   NOXA_ADDRESS, WRAPPED_NOXA_ADDRESS (the live wNOXA v3'), BRIDGE_AUTHORITY_COLD,
///   BRIDGE_UNLOCKER (hot relayer key; may be 0), MAX_BOX_AMOUNT (= NOXA maxWalletAmount,
///   read it fresh), UNLOCK_CAP_PER_WINDOW, UNLOCK_COUNT_PER_WINDOW, UNLOCK_WINDOW,
///   BRIDGE_FEE_BPS (inbound burn fee, bps; defaults to 100 = 1%, max 200; 0 disables).
///
/// After deploy: fund it (bridge NOXA in via lock, or ownerUnlock existing
/// collateral from the old single lockbox to the manager's active shard — the
/// manager spawns the first shard on the first lock), then repoint the relayer
/// LOCKBOX_ADDRESS = this manager + DBK_START_BLOCK, and update the UI lockbox.
contract DeployNoxaLockboxManager is Script {
    function run() external {
        address noxa = vm.envAddress("NOXA_ADDRESS");
        address wnoxa = vm.envAddress("WRAPPED_NOXA_ADDRESS");
        address cold = vm.envAddress("BRIDGE_AUTHORITY_COLD");
        address unlocker = vm.envOr("BRIDGE_UNLOCKER", address(0));
        uint256 maxBox = vm.envUint("MAX_BOX_AMOUNT");
        uint256 cap = vm.envUint("UNLOCK_CAP_PER_WINDOW");
        uint256 count = vm.envUint("UNLOCK_COUNT_PER_WINDOW");
        uint256 window = vm.envUint("UNLOCK_WINDOW");
        uint256 feeBps = vm.envOr("BRIDGE_FEE_BPS", uint256(100)); // 1% burn fee by default
        require(noxa != address(0) && wnoxa != address(0) && cold != address(0), "core addr unset");
        require(maxBox != 0 && cap != 0 && count != 0 && window != 0, "params unset");

        uint256 pk = vm.envUint("DBK_DEPLOY_KEY");
        vm.startBroadcast(pk);
        NoxaLockboxManager mgr =
            new NoxaLockboxManager(noxa, wnoxa, cold, unlocker, maxBox, cap, count, window, feeBps);
        vm.stopBroadcast();

        console2.log("NoxaLockboxManager: ", address(mgr));
        console2.log("  noxa:             ", noxa);
        console2.log("  wrappedNoxa:      ", wnoxa);
        console2.log("  owner (cold):     ", cold);
        console2.log("  unlocker (hot):   ", unlocker);
        console2.log("  maxBoxAmount:     ", maxBox);
        console2.log("  cap/count/window: ", cap);
        console2.log("  bridgeFeeBps:     ", feeBps);
        console2.log("NEXT: repoint relayer LOCKBOX_ADDRESS=this + DBK_START_BLOCK; update UI lockbox.");
    }
}
