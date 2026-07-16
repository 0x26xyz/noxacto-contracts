// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {WNoxaMigrator} from "../../src/bridge/WNoxaMigrator.sol";

/// @dev Deploys the WNoxaMigrator on **Robinhood Chain** (same chain as wNOXA).
///
///   forge script script/bridge/DeployWNoxaMigrator.s.sol:DeployWNoxaMigrator \
///     --rpc-url $RH_RPC_URL --broadcast --verify
///
/// OLD_WNOXA = the deprecated wNOXA to escrow; NEW_WNOXA = the hardened WrappedNoxaV2
/// to mint. After deploy, the NEW token's owner must grant this contract minter
/// rights: `newWnoxa.setMinter(migrator, true)`. Revoke it once migration closes.
/// The migrator escrows old wNOXA (never burns it) and mints new 1:1; the operator
/// later reconciles collateral by `sweepEscrow`-ing the old tokens through the old
/// bridge into the new lockbox.
contract DeployWNoxaMigrator is Script {
    function run() external {
        address oldWnoxa = vm.envAddress("OLD_WNOXA");
        address newWnoxa = vm.envAddress("NEW_WNOXA");
        address owner = vm.envAddress("MIGRATOR_OWNER");
        require(oldWnoxa != address(0) && newWnoxa != address(0) && owner != address(0), "unset arg");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        WNoxaMigrator mig = new WNoxaMigrator(oldWnoxa, newWnoxa, owner);
        vm.stopBroadcast();

        console2.log("WNoxaMigrator:   ", address(mig));
        console2.log("  oldToken:      ", oldWnoxa);
        console2.log("  newToken:      ", newWnoxa);
        console2.log("  owner:         ", owner);
        console2.log("NEXT: newWnoxa.setMinter(migrator,true), then announce the upgrade button.");
    }
}
