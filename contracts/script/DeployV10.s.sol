// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ScalarResolverV10} from "../src/v07/ScalarResolverV10.sol";

/// @notice Deploys ScalarResolverV10 (value-weighted calibration), bound to the
///         already-deployed CrucibleMarketV7. V10 ties each market's calibration
///         step to its economic weight (resolver fee), closing the V9 dust-spam
///         calibration-farming vector: a near-zero-fee market grants ~no
///         calibration, so a record can no longer be manufactured on throwaway
///         markets for free.
///
///         CALIB_FEE_REFERENCE is the resolver fee at which a market grants a
///         FULL calibration step. It is a DEPLOY-TIME TUNING PARAMETER: set it to
///         the fee of a "real-value" market under your fee schedule. With Arc
///         USDC (18 decimals) and a 2% resolver fee, 0.001 USDC of fee ≈ a 0.05
///         USDC market — a reasonable testnet floor that still filters dust.
///         Mainnet should raise it to match a meaningful settled value.
///         IDENTITY_REGISTRY = address(0): no canonical ERC-8004 registry on Arc
///         yet (identity-level decoupling dormant, as in V8/V9).
contract DeployV10Script is Script {
    address constant MARKET_V7 = 0x9934bAF33bcF0dfD14040f8ddd5DdF18eCfEFb59;
    address constant IDENTITY_REGISTRY = address(0); // none on Arc yet
    uint256 constant CALIB_FEE_REFERENCE = 0.001 ether; // testnet floor; tune on mainnet

    function run() external {
        vm.startBroadcast();
        ScalarResolverV10 resolver =
            new ScalarResolverV10(0.1 ether, MARKET_V7, IDENTITY_REGISTRY, CALIB_FEE_REFERENCE);
        vm.stopBroadcast();

        console.log("=== Crucible v0.7 / M4 - ScalarResolverV10 (value-weighted calibration) ===");
        console.log("Chain ID:                  ", block.chainid);
        console.log("ScalarResolverV10:         ", address(resolver));
        console.log("AUTHORIZED_MARKET (V7):    ", resolver.AUTHORIZED_MARKET());
        console.log("IDENTITY_REGISTRY:         ", resolver.IDENTITY_REGISTRY());
        console.log("MIN_STAKE:                 ", resolver.MIN_STAKE());
        console.log("CALIB_FEE_REFERENCE:       ", resolver.CALIB_FEE_REFERENCE());
        console.log("CALIB_STEP (full):         ", resolver.CALIB_STEP());
    }
}
