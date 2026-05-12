// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IResolverFeeReceiver
/// @notice Optional extension to IResolver. CrucibleMarketV2 calls
///         `notifyFee(marketId)` with a payable USDC value attached on the
///         disputed-resolution path; resolvers that accept the fee should
///         credit it to their validator reward pool for this market.
///
/// @dev    Resolvers that do not implement this interface still work — the
///         market wraps the call in try/catch and refunds the fee to the
///         agent if the call reverts.
interface IResolverFeeReceiver {
    function notifyFee(bytes32 marketId) external payable;
}
