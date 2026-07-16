// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NoxaLockboxV2} from "../../src/bridge/NoxaLockboxV2.sol";

/// @dev Deploys the hardened NoxaLockboxV2 on **DBK Chain**.
///
///   forge script script/bridge/DeployNoxaLockboxV2.s.sol:DeployNoxaLockboxV2 \
///     --rpc-url $DBK_RPC_URL --broadcast --verify \
///     --with-gas-price 3000000 --priority-gas-price 2000000
///
/// BRIDGE_AUTHORITY = cold owner (Safe/EOA). UNLOCKER = hot relayer key for routine
/// returns, bounded by UNLOCK_CAP per tx and UNLOCK_COOLDOWN seconds between txs.
/// Large/emergency returns go through the owner's uncapped `ownerUnlock`. Pick a
/// cap that covers ordinary returns but caps a leaked-key drain to one cap/cooldown.
contract DeployNoxaLockboxV2 is Script {
    function run() external {
        address noxa = vm.envAddress("NOXA_ADDRESS");
        require(noxa != address(0), "NOXA_ADDRESS unset");
        address authority = vm.envAddress("BRIDGE_AUTHORITY");
        require(authority != address(0), "BRIDGE_AUTHORITY unset");
        address unlocker = vm.envAddress("UNLOCKER"); // may be 0; set later via setUnlocker
        uint256 cap = vm.envUint("UNLOCK_CAP");
        uint256 cooldown = vm.envUint("UNLOCK_COOLDOWN");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        NoxaLockboxV2 lockbox = new NoxaLockboxV2(noxa, authority, unlocker, cap, cooldown);
        vm.stopBroadcast();

        console2.log("NoxaLockboxV2:   ", address(lockbox));
        console2.log("  noxa:          ", noxa);
        console2.log("  authority:     ", authority);
        console2.log("  unlocker:      ", unlocker);
        console2.log("  unlockCap:     ", cap);
        console2.log("  unlockCooldown:", cooldown);
    }
}
