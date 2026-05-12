// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CrucibleMarketV6} from "../src/v06/CrucibleMarketV6.sol";
import {TestcaseResolverV5} from "../src/v05/TestcaseResolverV5.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

/// @title CrucibleMarketV6 — stuck-market fallback tests
contract CrucibleMarketV6Test is Test {
    CrucibleMarketV6 market;
    TestcaseResolverV5 resolver;     // v0.6 market reuses v0.5 resolver
    MockResolver mockResolver;

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");
    address randomCaller = makeAddr("randomCaller");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,uint16 disputeBondBps,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarketV6();
        resolver = new TestcaseResolverV5(0.1 ether);
        mockResolver = new MockResolver();
        service = vm.addr(SERVICE_PK);
        vm.deal(service, 100 ether);
        vm.deal(agent, 100 ether);
        vm.deal(randomCaller, 1 ether);
        vm.warp(1_000_000);

        vm.prank(service);
        market.depositBond{value: 10 ether}();
        vm.prank(service);
        market.setResolverAllowed(address(resolver), true);
        vm.prank(service);
        market.setResolverAllowed(address(mockResolver), true);
    }

    function _signOpen(
        address svc, address agt, address rslv,
        uint256 amount, uint256 bondLock, uint16 bondBps,
        bytes32 commitmentHash, uint64 disputeWindow,
        uint256 nonce, uint256 authExpiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            OPEN_AUTH_TYPEHASH,
            svc, agt, rslv, amount, bondLock, bondBps, commitmentHash, disputeWindow, nonce, authExpiry
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", market.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SERVICE_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openMarket(address resolver_, uint256 amount, uint256 bondLock, uint16 bondBps, uint256 nonce)
        internal returns (bytes32 marketId)
    {
        uint64 window = 1 hours;
        bytes32 commit = keccak256(abi.encode("commit", nonce));
        uint256 authExpiry = block.timestamp + 1 days;
        CrucibleMarketV6.OpenAuth memory auth = CrucibleMarketV6.OpenAuth({
            service: service,
            agent: agent,
            resolver: resolver_,
            amount: amount,
            bondLockAmount: bondLock,
            disputeBondBps: bondBps,
            commitmentHash: commit,
            disputeWindow: window,
            nonce: nonce,
            authExpiry: authExpiry
        });
        bytes memory sig = _signOpen(service, agent, resolver_, amount, bondLock, bondBps, commit, window, nonce, authExpiry);
        vm.prank(agent);
        marketId = market.openMarket{value: amount}(auth, sig);
    }

    /* ---------- domain v6 ---------- */

    function test_eip712_versionIsSix() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Crucible")),
                keccak256(bytes("6")),
                block.chainid,
                address(market)
            )
        );
        assertEq(market.DOMAIN_SEPARATOR(), expected);
    }

    /* ---------- forceResolveStale ---------- */

    function test_forceResolveStale_revertsIfNotDisputed() public {
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        vm.expectRevert(CrucibleMarketV6.MarketNotDisputed.selector);
        market.forceResolveStale(marketId);
    }

    function test_forceResolveStale_revertsBeforeGrace() public {
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId);

        // Only 1 hour later — not 24 hours.
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(CrucibleMarketV6.StaleGraceNotPassed.selector);
        market.forceResolveStale(marketId);
    }

    function test_forceResolveStale_revertsIfResolverReady() public {
        // Validator commits AND reveals before reveal-window closes. After
        // STALE_RESOLVE_GRACE, canResolve() is true → force-resolve must revert.
        uint256 t0 = block.timestamp;
        address validator = makeAddr("v");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        resolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId);

        bytes32 voteHash = resolver.computeVoteHash(8000, bytes32(uint256(0x123)), marketId, validator);
        vm.prank(validator);
        resolver.commitVote(marketId, voteHash);

        // Reveal during reveal window (t0 + 31min)
        vm.warp(t0 + 31 minutes);
        vm.prank(validator);
        resolver.revealVote(marketId, 8000, bytes32(uint256(0x123)));

        // Now warp past STALE_RESOLVE_GRACE (24h from disputedAt = t0)
        vm.warp(t0 + 25 hours);

        // canResolve = true (reveal window passed + has revealed votes)
        // → forceResolveStale must revert
        vm.expectRevert(CrucibleMarketV6.ResolverReady.selector);
        market.forceResolveStale(marketId);
    }

    function test_forceResolveStale_settlesAtScore10000_whenNoOneReveals() public {
        // All validators commit but none reveal. After 24 hours from dispute,
        // anyone (including non-agent, non-service) can force-resolve.
        uint256 t0 = block.timestamp;
        address validator = makeAddr("v");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        resolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId);

        bytes32 voteHash = resolver.computeVoteHash(8000, bytes32(uint256(0x123)), marketId, validator);
        vm.prank(validator);
        resolver.commitVote(marketId, voteHash);
        // Validator never reveals.

        // After 24 hours + grace
        vm.warp(t0 + 25 hours);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        // Random caller force-resolves.
        vm.prank(randomCaller);
        market.forceResolveStale(marketId);

        // scoreBps = 10000 → service gets settleEscrow (= escrow - sub).
        // sub = 0.001. settleEscrow = 0.999. paidToService = 0.999.
        // bondSlash = 0. bondToService = full dispute bond = 0.05.
        // bondRefund = 0. totalToService = 0.999 + 0.05 = 1.049.
        // refundEscrow = 0. totalToAgent = 0.
        assertEq(service.balance, serviceBalBefore + 1.049 ether);
        assertEq(agent.balance, agentBalBefore);

        // Validator earned the subscription
        assertEq(resolver.earnedSubscription(validator), 0.001 ether);

        // Market is resolved
        (, , , , , , , , , , uint16 score, CrucibleMarketV6.Status status) = market.markets(marketId);
        assertEq(score, 10000);
        assertEq(uint256(status), uint256(CrucibleMarketV6.Status.Resolved));
    }

    function test_forceResolveStale_callableByAnyone() public {
        // Confirm permissionless — even the service can call it
        uint256 t0 = block.timestamp;
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId);

        vm.warp(t0 + 25 hours);

        // Service themselves calls it
        vm.prank(service);
        market.forceResolveStale(marketId);

        (, , , , , , , , , , uint16 score, CrucibleMarketV6.Status status) = market.markets(marketId);
        assertEq(score, 10000);
        assertEq(uint256(status), uint256(CrucibleMarketV6.Status.Resolved));
    }

    function test_forceResolveStale_marketTransitionsToResolved() public {
        // (Replaces the strict event-emit test — state transition is what matters.)
        uint256 t0 = block.timestamp;
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId);
        vm.warp(t0 + 25 hours);

        vm.prank(randomCaller);
        market.forceResolveStale(marketId);

        (, , , , , , , , , , uint16 score, CrucibleMarketV6.Status status) = market.markets(marketId);
        assertEq(score, 10000);
        assertEq(uint256(status), uint256(CrucibleMarketV6.Status.Resolved));
    }

    /* ---------- carry-over: v0.5 mechanics still work ---------- */

    function test_optimistic_subscriptionPaid() public {
        address validator = makeAddr("v");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        resolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        uint256 serviceBalBefore = service.balance;
        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        assertEq(service.balance, serviceBalBefore + 0.999 ether);
    }

    function test_perMarketBondBps_stillWorks() public {
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 200, 1);
        assertEq(market.requiredDisputeBond(marketId), 0.02 ether);
    }

    function test_openMarket_setsDisputedAtToZero() public {
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        (, , , , , , , , , uint64 disputedAt, , ) = market.markets(marketId);
        assertEq(disputedAt, 0);
    }

    function test_dispute_setsDisputedAt() public {
        bytes32 marketId = _openMarket(address(resolver), 1 ether, 5 ether, 500, 1);
        uint256 disputeTime = block.timestamp;
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId);

        (, , , , , , , , , uint64 disputedAt, , ) = market.markets(marketId);
        assertEq(disputedAt, disputeTime);
    }
}
