// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CrucibleMarketV2} from "../src/v02/CrucibleMarketV2.sol";
import {TestcaseResolverV2} from "../src/v02/TestcaseResolverV2.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

/// @title CrucibleMarketV2 — fee routing + EIP-712 v2 domain isolation tests
contract CrucibleMarketV2Test is Test {
    CrucibleMarketV2 market;
    TestcaseResolverV2 feeResolver;     // Receives notifyFee
    MockResolver mockResolver;           // Does NOT implement notifyFee → fee bounces

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarketV2();
        feeResolver = new TestcaseResolverV2();
        mockResolver = new MockResolver();
        service = vm.addr(SERVICE_PK);
        vm.deal(service, 100 ether);
        vm.deal(agent, 100 ether);
        vm.warp(1_000_000);

        vm.prank(service);
        market.depositBond{value: 10 ether}();
        vm.prank(service);
        market.setResolverAllowed(address(feeResolver), true);
        vm.prank(service);
        market.setResolverAllowed(address(mockResolver), true);
    }

    /* ---------- helpers ---------- */

    function _signOpen(
        address svc,
        address agt,
        address rslv,
        uint256 amount,
        uint256 bondLock,
        bytes32 commitmentHash,
        uint64 disputeWindow,
        uint256 nonce,
        uint256 authExpiry
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            OPEN_AUTH_TYPEHASH,
            svc, agt, rslv, amount, bondLock, commitmentHash, disputeWindow, nonce, authExpiry
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", market.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SERVICE_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    function _openMarket(address resolver_, uint256 amount, uint256 bondLock, uint256 nonce)
        internal returns (bytes32 marketId)
    {
        uint64 window = 1 hours;
        bytes32 commit = keccak256(abi.encode("commit", nonce));
        uint256 authExpiry = block.timestamp + 1 days;
        CrucibleMarketV2.OpenAuth memory auth = CrucibleMarketV2.OpenAuth({
            service: service,
            agent: agent,
            resolver: resolver_,
            amount: amount,
            bondLockAmount: bondLock,
            commitmentHash: commit,
            disputeWindow: window,
            nonce: nonce,
            authExpiry: authExpiry
        });
        bytes memory sig = _signOpen(service, agent, resolver_, amount, bondLock, commit, window, nonce, authExpiry);
        vm.prank(agent);
        marketId = market.openMarket{value: amount}(auth, sig);
    }

    /* ---------- domain version ---------- */

    function test_eip712_versionIsTwo() public view {
        // We can't read version directly, but we can check the DOMAIN_SEPARATOR matches
        // an EIP-712 domain computed with version "2".
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Crucible")),
                keccak256(bytes("2")),
                block.chainid,
                address(market)
            )
        );
        assertEq(market.DOMAIN_SEPARATOR(), expected);
    }

    /* ---------- optimistic settle: no resolver fee ---------- */

    function test_collectAfterWindow_noResolverFee() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        uint256 serviceBalBefore = service.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        // Optimistic path: service collects FULL escrow, no fee siphoned.
        assertEq(service.balance, serviceBalBefore + 1 ether);

        // Resolver fee pool is unchanged
        (, , , , uint256 feePool) = feeResolver.getMarket(marketId);
        assertEq(feePool, 0);
    }

    /* ---------- disputed settle: fee routed to resolver ---------- */

    function test_disputeAndResolve_feeRoutedToResolver() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);

        // Agent disputes
        vm.prank(agent);
        market.dispute(marketId);

        // A validator stakes + votes on the marketId in the resolver
        address validator = makeAddr("v1");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        feeResolver.stake{value: 1 ether}();
        vm.prank(validator);
        feeResolver.vote(marketId, 8000);

        // Warp past voting deadline
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId, "");

        // Score = 8000. Fee = 2% of 1 ether = 0.02 ether.
        // Remaining escrow = 0.98 ether.
        // paidToService = 0.98 * 0.8 = 0.784 ether
        // refundToAgent = 0.98 - 0.784 = 0.196 ether
        // bondSlash = 5 * 0.2 = 1 ether
        // totalToAgent = 0.196 + 1 = 1.196 ether
        assertEq(service.balance, serviceBalBefore + 0.784 ether);
        assertEq(agent.balance, agentBalBefore + 1.196 ether);

        // Resolver fee pool got the 0.02 ether
        (, , , , uint256 feePool) = feeResolver.getMarket(marketId);
        assertEq(feePool, 0.02 ether);
    }

    /* ---------- disputed settle with non-fee-receiver resolver ---------- */

    function test_disputeAndResolve_feeBouncesBackToAgent() public {
        bytes32 marketId = _openMarket(address(mockResolver), 1 ether, 5 ether, 1);

        vm.prank(agent);
        market.dispute(marketId);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId, abi.encode(uint256(8000)));

        // MockResolver does not implement notifyFee → try/catch swallows the
        // revert and the fee stays IN the escrow (settleEscrow unchanged at 1
        // ether). Score 8000 splits the full 1 ether:
        //   paidToService = 1.0 * 0.8 = 0.8
        //   refundToAgent = 0.2
        //   bondSlash      = 5 * 0.2 = 1.0
        //   totalToAgent   = 0.2 + 1.0 = 1.2
        assertEq(service.balance, serviceBalBefore + 0.8 ether);
        assertEq(agent.balance, agentBalBefore + 1.2 ether);
    }

    /* ---------- score = 10000 disputed settle: still pays fee ---------- */

    function test_disputeAndResolve_scoreMaxStillFee() public {
        // Even if dispute resolves at scoreBps=10000, the dispute consumed resolver
        // work, so the fee is taken. This is a deliberate design choice — the cost
        // of arbitration is incurred whenever a dispute is filed, not whenever the
        // service "loses".
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        vm.prank(agent);
        market.dispute(marketId);

        address validator = makeAddr("v1");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        feeResolver.stake{value: 1 ether}();
        vm.prank(validator);
        feeResolver.vote(marketId, 10000);
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId, "");

        // Fee 0.02. Remaining 0.98 all to service. Bond slash = 0.
        // refundToAgent = 0
        // agent gets 0
        assertEq(service.balance, serviceBalBefore + 0.98 ether);
        assertEq(agent.balance, agentBalBefore);
    }

    /* ---------- score = 0 disputed settle: full bond slash, agent gets fee-adjusted ---------- */

    function test_disputeAndResolve_scoreZero() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        vm.prank(agent);
        market.dispute(marketId);

        address validator = makeAddr("v1");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        feeResolver.stake{value: 1 ether}();
        vm.prank(validator);
        feeResolver.vote(marketId, 0);
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId, "");

        // Fee = 0.02. Service share = 0. refundToAgent = 0.98. bondSlash = 5.
        // agent gets 0.98 + 5 = 5.98
        assertEq(service.balance, serviceBalBefore);
        assertEq(agent.balance, agentBalBefore + 5.98 ether);
    }

    /* ---------- openMarket happy path sanity (same as V1) ---------- */

    function test_openMarket_happyPath() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);

        (
            address svc,
            address agt,
            address rslv,
            uint256 escrow,
            uint256 bondLocked,
            ,
            uint64 deadline,
            uint16 score,
            CrucibleMarketV2.Status status
        ) = market.markets(marketId);

        assertEq(svc, service);
        assertEq(agt, agent);
        assertEq(rslv, address(feeResolver));
        assertEq(escrow, 1 ether);
        assertEq(bondLocked, 5 ether);
        assertEq(deadline, block.timestamp + 1 hours);
        assertEq(score, 0);
        assertEq(uint256(status), uint256(CrucibleMarketV2.Status.Open));
    }

    function test_openMarket_revertsResolverNotAllowed() public {
        address otherResolver = address(0xBEEF);
        uint64 window = 1 hours;
        bytes32 commit = keccak256("c");
        uint256 authExpiry = block.timestamp + 1 days;
        CrucibleMarketV2.OpenAuth memory auth = CrucibleMarketV2.OpenAuth({
            service: service, agent: agent, resolver: otherResolver,
            amount: 1 ether, bondLockAmount: 5 ether, commitmentHash: commit,
            disputeWindow: window, nonce: 1, authExpiry: authExpiry
        });
        bytes memory sig = _signOpen(service, agent, otherResolver, 1 ether, 5 ether, commit, window, 1, authExpiry);

        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV2.ResolverNotAllowed.selector);
        market.openMarket{value: 1 ether}(auth, sig);
    }
}
