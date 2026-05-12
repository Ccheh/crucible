// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IResolver
/// @notice Pluggable verification logic that decides a market's quality score
///         in basis points (0..10000). 0 = total failure, 10000 = perfect.
/// @dev    Different AI tasks need different verifications: testcase
///         (deterministic code execution), oracle (Chainlink for predictions),
///         validator-vote (Schelling for subjective), TEE (hardware attestation),
///         ZK-ML (cryptographic). Each is its own resolver contract.
interface IResolver {
    function resolve(bytes32 marketId, bytes calldata data) external returns (uint256 scoreBps);
    function canResolve(bytes32 marketId) external view returns (bool);
    function name() external view returns (string memory);
}
