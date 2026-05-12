// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  IResolverSubscriptionReceiver
/// @notice v0.4 extension to IResolver. CrucibleMarketV4 calls
///         `notifyValidatorSubscription()` on EVERY settlement (optimistic
///         AND disputed) with a small payable USDC value attached.
///         Resolvers that implement this interface pool these subscriptions
///         globally and distribute pro-rata to ALL staked validators via a
///         MasterChef-style accumulator — independent of whether the
///         specific market had a dispute or not.
///
/// @dev    This is the v0.4 fix for the "validators only earn during
///         disputes" economic concern. By making services pay a small flat
///         subscription on every call (default 10 bps = 0.10% of escrow),
///         validators get a baseline yield from the protocol's normal
///         operation, not just from rare disputes.
///
/// @dev    Resolvers that do NOT implement this interface still work — the
///         market wraps the call in try/catch and keeps the value in the
///         escrow if the call reverts (graceful degradation, same posture
///         as the v0.2 notifyFee fallback).
interface IResolverSubscriptionReceiver {
    function notifyValidatorSubscription() external payable;
}
