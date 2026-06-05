// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ScalarResolverV8} from "../src/v07/ScalarResolverV8.sol";

/// @notice Deploys ScalarResolverV8 (M2: ERC-8004 identity binding), bound to
///         the already-deployed CrucibleMarketV7. IDENTITY_REGISTRY is set to
///         address(0) on Arc Testnet for now — no canonical ERC-8004
///         IdentityRegistry is live on Arc yet (it is on Ethereum/Base). With
///         a zero registry the resolver behaves exactly like v0.7 (address-level
///         decoupling); the identity layer activates by redeploying with a real
///         registry once ERC-8004 lands on Arc. Identity behavior is proven by
///         the ScalarResolverV8 test suite (mock registry).
contract DeployV8Script is Script {
    address constant MARKET_V7 = 0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59;
    address constant IDENTITY_REGISTRY = address(0); // none on Arc yet

    function run() external {
        vm.startBroadcast();
        ScalarResolverV8 resolver = new ScalarResolverV8(0.1 ether, MARKET_V7, IDENTITY_REGISTRY);
        vm.stopBroadcast();

        console.log("=== Crucible v0.7 / M2 - ScalarResolverV8 (ERC-8004 identity binding) ===");
        console.log("Chain ID:                  ", block.chainid);
        console.log("ScalarResolverV8:          ", address(resolver));
        console.log("AUTHORIZED_MARKET (V7):    ", resolver.AUTHORIZED_MARKET());
        console.log("IDENTITY_REGISTRY:         ", resolver.IDENTITY_REGISTRY());
        console.log("MIN_STAKE:                 ", resolver.MIN_STAKE());
    }
}
