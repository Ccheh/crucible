// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ScalarResolverV9} from "../src/v07/ScalarResolverV9.sol";

/// @notice Deploys ScalarResolverV9 (calibration-weighted consensus), bound to
///         the already-deployed CrucibleMarketV7. Vote weight = stake x earned
///         calibration: a validator's influence is its capital scaled by an
///         on-chain accuracy track record (0.25x..1.5x of stake). Fresh capital
///         starts at 0.5x; proven-accurate validators rise to 1.5x; proven-
///         inaccurate validators fall to 0.25x. This is a bounded tilt toward
///         earned accuracy, NOT a standalone whale defense (the 40% vote cap +
///         a distributed validator set handle supermajority capital).
///         IDENTITY_REGISTRY = address(0): no canonical ERC-8004 registry on Arc
///         yet, so identity-level decoupling stays dormant (address-level still
///         enforced), exactly as in V8.
contract DeployV9Script is Script {
    address constant MARKET_V7 = 0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59;
    address constant IDENTITY_REGISTRY = address(0); // none on Arc yet

    function run() external {
        vm.startBroadcast();
        ScalarResolverV9 resolver = new ScalarResolverV9(0.1 ether, MARKET_V7, IDENTITY_REGISTRY);
        vm.stopBroadcast();

        console.log("=== Crucible v0.7 / M3 - ScalarResolverV9 (calibration-weighted consensus) ===");
        console.log("Chain ID:                  ", block.chainid);
        console.log("ScalarResolverV9:          ", address(resolver));
        console.log("AUTHORIZED_MARKET (V7):    ", resolver.AUTHORIZED_MARKET());
        console.log("IDENTITY_REGISTRY:         ", resolver.IDENTITY_REGISTRY());
        console.log("MIN_STAKE:                 ", resolver.MIN_STAKE());
        console.log("CALIB_START (fresh, bps):  ", resolver.CALIB_START());
        console.log("CALIB_MIN / CALIB_MAX:     ", resolver.CALIB_MIN(), resolver.CALIB_MAX());
    }
}
