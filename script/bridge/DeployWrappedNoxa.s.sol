// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {WrappedNoxa} from "../../src/bridge/WrappedNoxa.sol";

/// @dev Deploys WrappedNoxa (wNOXA) on **Robinhood Chain** (the destination side).
///
///   forge script script/bridge/DeployWrappedNoxa.s.sol:DeployWrappedNoxa \
///     --rpc-url $RH_RPC_URL --broadcast --verify
///
/// BRIDGE_AUTHORITY MUST be a multisig (ideally the same signer set as the DBK
/// lockbox authority). It owns mint rights — the sole trust anchor on this side.
contract DeployWrappedNoxa is Script {
    function run() external {
        address authority = vm.envAddress("BRIDGE_AUTHORITY");
        require(authority != address(0), "BRIDGE_AUTHORITY unset");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        WrappedNoxa wnoxa = new WrappedNoxa(authority);
        vm.stopBroadcast();

        console2.log("WrappedNoxa:     ", address(wnoxa));
        console2.log("  authority:     ", authority);
    }
}
