// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {WrappedNoxaV3} from "../../src/bridge/WrappedNoxaV3.sol";

/// @dev Deploys the cap-native WrappedNoxaV3 (wNOXA) on **Robinhood Chain**.
///
///   forge script script/bridge/DeployWrappedNoxaV3.s.sol:DeployWrappedNoxaV3 \
///     --rpc-url $RH_RPC_URL --broadcast --verify
///
/// BRIDGE_AUTHORITY is the cold owner (a Safe once available; an EOA to start is
/// fine — ownership is transferable via 2-step later). WNOXA_MAX_SUPPLY should
/// equal the real DBK NOXA total supply (1_000_000e18) — the compromised-minter
/// bound. WNOXA_MAX_WALLET mirrors the source token's live `maxWalletAmount()`
/// (25_000e18, verified on-chain 2026-07-22) — read it fresh before deploying:
///   cast call $NOXA "maxWalletAmount()(uint256)" --rpc-url https://rpc.dbkchain.io
///
/// After deploy run ConfigureWNoxaV3.s.sol (minters + cap exclusions), then
/// DeployWNoxaMigrator.s.sol with OLD_WNOXA = the v2 token.
contract DeployWrappedNoxaV3 is Script {
    function run() external {
        address authority = vm.envAddress("BRIDGE_AUTHORITY");
        require(authority != address(0), "BRIDGE_AUTHORITY unset");
        uint256 maxSupply = vm.envUint("WNOXA_MAX_SUPPLY");
        require(maxSupply != 0, "WNOXA_MAX_SUPPLY unset");
        uint256 maxWallet = vm.envUint("WNOXA_MAX_WALLET");
        require(maxWallet != 0 && maxWallet <= maxSupply, "WNOXA_MAX_WALLET unset/oversized");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        WrappedNoxaV3 wnoxa = new WrappedNoxaV3(authority, maxSupply, maxWallet);
        vm.stopBroadcast();

        console2.log("WrappedNoxaV3:   ", address(wnoxa));
        console2.log("  authority:     ", authority);
        console2.log("  maxSupply:     ", maxSupply);
        console2.log("  maxWallet:     ", maxWallet);
        console2.log("NEXT: ConfigureWNoxaV3.s.sol (minters + exclusions); migrator v2->v3;");
        console2.log("      after the pool exists, setCapExcluded(pool, true) BEFORE volume grows.");
    }
}
