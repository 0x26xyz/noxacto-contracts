// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {NoxaLockboxV2} from "../../src/bridge/NoxaLockboxV2.sol";

/// @dev DEPRECATED — do NOT deploy. Kept only to build/verify the already-live v2
/// lockbox. NoxaLockboxV2's hot-path limit is a per-tx cap plus an optional
/// cooldown, and the shipped `UNLOCK_COOLDOWN=0` default nullifies the rate limit
/// entirely (a leaked key drains via many caller-chosen nonces). It also has no
/// way to reopen a mis-settled `processedBurn` nonce. Deploy `NoxaLockboxV3`
/// (leaky-bucket value+count budgets, clearable replay guard, one box per wNOXA
/// version) via `DeployNoxaLockboxV3.s.sol` instead. See the 2026-07 review.
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
