// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {WrappedNoxaV3} from "../../src/bridge/WrappedNoxaV3.sol";

/// @dev Owner ops for WrappedNoxaV3 — grant/revoke minters and manage the wallet
/// cap exclusion list. Broadcast key MUST be the token owner (BRIDGE_AUTHORITY).
///
///   forge script script/bridge/ConfigureWNoxaV3.s.sol:ConfigureWNoxaV3 \
///     --rpc-url $RH_RPC_URL --broadcast
///
/// Env (all optional except WNOXA_V3; unset = skipped):
///   WNOXA_V3            the deployed WrappedNoxaV3
///   MINTER_GRANT        address to setMinter(_, true)   (relayer hot key, or migrator)
///   MINTER_REVOKE       address to setMinter(_, false)  (e.g. migrator after cutover)
///   EXCLUDE_ADDRESSES   comma-separated list to setCapExcluded(_, true)
///                       (the wNOXA/WETH pool once created, NoxaFeeBurner, DEAD)
///
/// Typical sequences:
///   cutover:    MINTER_GRANT=<relayer>, then MINTER_GRANT=<migrator>
///   post-seed:  EXCLUDE_ADDRESSES=<pool>,<burner>,0x000000000000000000000000000000000000dEaD
///   close-out:  MINTER_REVOKE=<migrator>
contract ConfigureWNoxaV3 is Script {
    function run() external {
        WrappedNoxaV3 wnoxa = WrappedNoxaV3(vm.envAddress("WNOXA_V3"));

        address grant = vm.envOr("MINTER_GRANT", address(0));
        address revoke = vm.envOr("MINTER_REVOKE", address(0));
        address[] memory exclude = vm.envOr("EXCLUDE_ADDRESSES", ",", new address[](0));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        if (grant != address(0)) {
            wnoxa.setMinter(grant, true);
            console2.log("minter granted:  ", grant);
        }
        if (revoke != address(0)) {
            wnoxa.setMinter(revoke, false);
            console2.log("minter revoked:  ", revoke);
        }
        for (uint256 i = 0; i < exclude.length; i++) {
            wnoxa.setCapExcluded(exclude[i], true);
            console2.log("cap-excluded:    ", exclude[i]);
        }

        vm.stopBroadcast();

        console2.log("maxWalletAmount: ", wnoxa.maxWalletAmount());
        console2.log("totalEscrowed:   ", wnoxa.totalEscrowed());
    }
}
