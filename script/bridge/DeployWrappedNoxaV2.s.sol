// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {WrappedNoxaV2} from "../../src/bridge/WrappedNoxaV2.sol";

/// @dev Deploys the hardened WrappedNoxaV2 (wNOXA) on **Robinhood Chain**.
///
///   forge script script/bridge/DeployWrappedNoxaV2.s.sol:DeployWrappedNoxaV2 \
///     --rpc-url $RH_RPC_URL --broadcast --verify
///
/// BRIDGE_AUTHORITY is the cold owner (a Safe once available; an EOA to start is
/// fine — ownership is transferable via 2-step later). After deploy, the owner
/// must `setMinter(relayerKey, true)` for the hot relayer, and `setMinter(migrator,
/// true)` for the migration window (then revoke). WNOXA_MAX_SUPPLY should equal the
/// real DBK NOXA total supply (e.g. 1_000_000e18) — the compromised-minter bound.
contract DeployWrappedNoxaV2 is Script {
    function run() external {
        address authority = vm.envAddress("BRIDGE_AUTHORITY");
        require(authority != address(0), "BRIDGE_AUTHORITY unset");
        uint256 maxSupply = vm.envUint("WNOXA_MAX_SUPPLY");
        require(maxSupply != 0, "WNOXA_MAX_SUPPLY unset");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        WrappedNoxaV2 wnoxa = new WrappedNoxaV2(authority, maxSupply);
        vm.stopBroadcast();

        console2.log("WrappedNoxaV2:   ", address(wnoxa));
        console2.log("  authority:     ", authority);
        console2.log("  maxSupply:     ", maxSupply);
        console2.log("NEXT: owner.setMinter(relayer,true); grant migrator during cutover.");
    }
}
