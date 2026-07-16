// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NoxaLockbox} from "../../src/bridge/NoxaLockbox.sol";

/// @dev Deploys the NoxaLockbox on **DBK Chain** (the source side). Never
/// hardcodes addresses — NOXA + bridge authority come from env (D11).
///
///   forge script script/bridge/DeployNoxaLockbox.s.sol:DeployNoxaLockbox \
///     --rpc-url $DBK_RPC_URL --broadcast --verify
///
/// NOXA_ADDRESS is the live DBK NOXA (0x6778980c66bcd9A8F74D73BD1b608483c40E8DdE
/// on mainnet — verify on-chain before use). BRIDGE_AUTHORITY MUST be a multisig;
/// it holds unlock rights and is the sole trust anchor of this federated bridge.
contract DeployNoxaLockbox is Script {
    function run() external {
        address noxa = vm.envAddress("NOXA_ADDRESS");
        address authority = vm.envAddress("BRIDGE_AUTHORITY");
        require(noxa != address(0), "NOXA_ADDRESS unset");
        require(authority != address(0), "BRIDGE_AUTHORITY unset");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        NoxaLockbox lockbox = new NoxaLockbox(noxa, authority);
        vm.stopBroadcast();

        console2.log("NoxaLockbox:     ", address(lockbox));
        console2.log("  noxa:          ", noxa);
        console2.log("  authority:     ", authority);
    }
}
