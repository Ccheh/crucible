// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {CrucibleMarketV7} from "../src/v07/CrucibleMarketV7.sol";
import {ScalarResolverV7} from "../src/v07/ScalarResolverV7.sol";
import {Erc8183ProportionalAdapter} from "../src/v07/Erc8183ProportionalAdapter.sol";

/// @notice Deploys the Crucible v0.7 graded-resolution layer:
///         - CrucibleMarketV7  : market with pre-committed criteria, typed
///                               dispute taxonomy, and the onDispute hook.
///         - ScalarResolverV7  : generalized stake-weighted commit-reveal
///                               resolver with STAKER-PARTICIPANT DECOUPLING
///                               (bound to the market, admin-keyless).
///         - Erc8183ProportionalAdapter : binary-to-proportional settlement
///                               adapter for ERC-8183 jobs / any escrow.
///
///         Deploy order matters: the resolver takes the market address as an
///         immutable constructor arg (keyless conflict authorization), so the
///         market is deployed first.
///
///         MIN_STAKE = 0.1 ether for testnet; raise for mainnet.
contract DeployV7Script is Script {
    function run() external {
        vm.startBroadcast();

        CrucibleMarketV7 market = new CrucibleMarketV7();
        ScalarResolverV7 resolver = new ScalarResolverV7(0.1 ether, address(market));
        Erc8183ProportionalAdapter adapter = new Erc8183ProportionalAdapter(address(resolver));

        vm.stopBroadcast();

        console.log("=== Crucible v0.7 (graded-resolution layer) ===");
        console.log("Chain ID:                   ", block.chainid);
        console.log("CrucibleMarketV7:           ", address(market));
        console.log("ScalarResolverV7:           ", address(resolver));
        console.log("Erc8183ProportionalAdapter: ", address(adapter));
        console.log("resolver.AUTHORIZED_MARKET: ", resolver.AUTHORIZED_MARKET());
        console.log("MIN_STAKE:                  ", resolver.MIN_STAKE());
    }
}
