// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {FeeOnTransferNoxa} from "../../test/mocks/FeeOnTransferNoxa.sol";

/// @dev TESTNET-ONLY. Deploys a fee-on-transfer NOXA stand-in (fixed 1M supply
/// minted to the deployer) so the bridge can be rehearsed end-to-end without real
/// NOXA. NEVER deploy this to mainnet — mainnet uses the real NOXA at
/// 0x6778980c66bcd9A8F74D73BD1b608483c40E8DdE.
///
///   MOCK_NOXA_FEE_BPS=500 \
///   forge script script/bridge/DeployMockNoxa.s.sol:DeployMockNoxa \
///     --rpc-url $RH_RPC_URL --broadcast
///
/// Optional MOCK_NOXA_FEE_BPS (default 500 = 5%) sets the transfer fee so the
/// rehearsal exercises the lockbox's balance-delta accounting.
contract DeployMockNoxa is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint16 feeBps = uint16(vm.envOr("MOCK_NOXA_FEE_BPS", uint256(500)));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        FeeOnTransferNoxa noxa = new FeeOnTransferNoxa(deployer);
        if (feeBps != 0) noxa.setFee(feeBps);
        vm.stopBroadcast();

        console2.log("MockNOXA (FeeOnTransferNoxa):", address(noxa));
        console2.log("  owner/holder:             ", deployer);
        console2.log("  feeBps:                   ", feeBps);
        console2.log("Use this as NOXA_ADDRESS for the lockbox + relayer on testnet.");
    }
}
