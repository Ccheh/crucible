// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CrucibleMarketV6} from "../src/v06/CrucibleMarketV6.sol";
import {TestcaseResolverV5} from "../src/v05/TestcaseResolverV5.sol";

/// @notice Deploys the production v0.6 stack: CrucibleMarketV6 (latest market
///         contract with stuck-market fallback) paired with TestcaseResolverV5
///         (the resolver with commit-reveal + configurable MIN_STAKE +
///         subscription pool + voting cap + ERC-8004 events).
///
///         MIN_STAKE for the testnet deploy: 0.1 ether (testnet-easy).
///         For mainnet, redeploy with a higher value (e.g. 1 ether).
contract DeployV6Script is Script {
    function run() external {
        vm.startBroadcast();

        CrucibleMarketV6 market = new CrucibleMarketV6();
        TestcaseResolverV5 resolver = new TestcaseResolverV5(0.1 ether);

        vm.stopBroadcast();

        console.log("=== Crucible v0.6 deployment ===");
        console.log("Chain ID:           ", block.chainid);
        console.log("CrucibleMarketV6:   ", address(market));
        console.log("TestcaseResolverV5: ", address(resolver));
        console.log("MIN_STAKE:          ", resolver.MIN_STAKE());
    }
}
