// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CrucibleMarket} from "../src/CrucibleMarket.sol";
import {TestcaseResolver} from "../src/resolvers/TestcaseResolver.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

contract DeployScript is Script {
    function run() external {
        vm.startBroadcast();

        CrucibleMarket market = new CrucibleMarket();
        TestcaseResolver testcaseResolver = new TestcaseResolver();
        MockResolver mockResolver = new MockResolver();

        vm.stopBroadcast();

        console.log("=== Crucible v0 Deployment ===");
        console.log("Chain ID:", block.chainid);
        console.log("CrucibleMarket:    ", address(market));
        console.log("TestcaseResolver:  ", address(testcaseResolver));
        console.log("MockResolver:      ", address(mockResolver));
    }
}
