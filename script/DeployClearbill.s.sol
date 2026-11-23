// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { ClearbillRegistry } from "../src/ClearbillRegistry.sol";
import { ClearbillInvoices } from "../src/ClearbillInvoices.sol";

/// @notice Deploys ClearbillRegistry and ClearbillInvoices on QDay Aevum Testnet (chain ID 44005).
/// @dev Strictly refuses to run on any chain other than 44005 and binds to official Aevum tUSD8.
contract DeployClearbill is Script {
    uint256 internal constant AEVUM_TESTNET_CHAIN_ID = 44005;
    address internal constant OFFICIAL_TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external {
        require(
            block.chainid == AEVUM_TESTNET_CHAIN_ID,
            "ABORT: must run on QDay Aevum Testnet (44005) only"
        );
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        ClearbillRegistry registry = new ClearbillRegistry();
        ClearbillInvoices invoices = new ClearbillInvoices(OFFICIAL_TUSD8);
        vm.stopBroadcast();

        console2.log("QDay Aevum Testnet (44005) Deployment:");
        console2.log("  Official tUSD8:    ", OFFICIAL_TUSD8);
        console2.log("  ClearbillRegistry: ", address(registry));
        console2.log("  ClearbillInvoices: ", address(invoices));
    }
}
