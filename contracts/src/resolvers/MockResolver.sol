// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IResolver} from "../interfaces/IResolver.sol";

/// @notice Minimal resolver for v0 testing: takes a uint256 score directly from
///         the `data` argument and returns it verbatim. This stands in for a
///         real validator network or oracle. Replace with real resolvers in v0.2+.
///
/// @dev    DO NOT USE IN PRODUCTION. This trusts whoever calls `resolveDisputed`
///         to provide a fair score, which is fine for testing the market
///         mechanics in isolation but fails the trust model in the wild.
contract MockResolver is IResolver {
    function resolve(bytes32, bytes calldata data) external pure returns (uint256 scoreBps) {
        scoreBps = abi.decode(data, (uint256));
    }

    function canResolve(bytes32) external pure returns (bool) {
        return true;
    }

    function name() external pure returns (string memory) {
        return "MockResolver";
    }
}
