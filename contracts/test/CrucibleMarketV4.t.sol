// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CrucibleMarketV4} from "../src/v04/CrucibleMarketV4.sol";
import {TestcaseResolverV4} from "../src/v04/TestcaseResolverV4.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

/// @title CrucibleMarketV4 — always-on subscription + ServiceReputation event
contract CrucibleMarketV4Test is Test {
    CrucibleMarketV4 market;
    TestcaseResolverV4 fullResolver;       // implements both fee + subscription
    MockResolver mockResolver;              // implements neither

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarketV4();
        fullResolver = new TestcaseResolverV4();
        mockResolver = new MockResolver();
        service = vm.addr(SERVICE_PK);
        vm.deal(service, 100 ether);
        vm.deal(agent, 100 ether);
        vm.warp(1_000_000);

        vm.prank(service);
        market.depositBond{value: 10 ether}();
        vm.prank(service);
        market.setResolverAllowed(address(fullResolver), true);
        vm.prank(service);
        market.setResolverAllowed(address(mockResolver), true);
    }

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
        CrucibleMarketV4.OpenAuth memory auth = CrucibleMarketV4.OpenAuth({
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

    /* ---------- domain ---------- */

    function test_eip712_versionIsFour() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Crucible")),
                keccak256(bytes("4")),
                block.chainid,
                address(market)
            )
        );
        assertEq(market.DOMAIN_SEPARATOR(), expected);
    }

    /* ---------- optimistic settle: subscription IS charged ---------- */

    function test_optimistic_subscriptionPaidToResolver() public {
        // Seed a validator so subscription accumulator works.
        address validator = makeAddr("validator");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        fullResolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 1);
        uint256 serviceBalBefore = service.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        // Subscription = 0.10% of 1 ether = 0.001 ether.
        // Service gets 1 - 0.001 = 0.999 ether.
        assertEq(service.balance, serviceBalBefore + 0.999 ether);
        // Validator earned the full subscription.
        assertEq(fullResolver.earnedSubscription(validator), 0.001 ether);
        // Resolver total subscription received is 0.001.
        assertEq(fullResolver.totalSubscriptionReceived(), 0.001 ether);
    }

    function test_optimistic_subscriptionBouncesWithMockResolver() public {
        bytes32 marketId = _openMarket(address(mockResolver), 1 ether, 5 ether, 1);
        uint256 serviceBalBefore = service.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        // Mock doesn't implement IResolverSubscriptionReceiver → subscription
        // stays in escrow, service gets full 1 ether.
        assertEq(service.balance, serviceBalBefore + 1 ether);
    }

    /* ---------- disputed settle: subscription + fee both charged ---------- */

    function test_disputed_subscriptionAndFeeBothPaid() public {
        address validator = makeAddr("validator");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        fullResolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 1);
        uint256 bond = market.requiredDisputeBond(marketId);
        vm.prank(agent);
        market.dispute{value: bond}(marketId);

        // Validator votes 8000
        vm.prank(validator);
        fullResolver.vote(marketId, 8000);
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId, "");

        // Subscription 0.001, Fee 0.02. settleEscrow = 1 - 0.001 - 0.02 = 0.979.
        // Score 8000. paidToService = 0.979 * 0.8 = 0.7832
        // refundEscrow = 0.979 * 0.2 = 0.1958
        // bondSlash = 5 * 0.2 = 1.0
        // bondToService = 0.05 * 0.8 = 0.04
        // bondRefund = 0.05 - 0.04 = 0.01
        // totalToService = 0.7832 + 0.04 = 0.8232
        // totalToAgent = 0.1958 + 1.0 + 0.01 = 1.2058
        assertEq(service.balance, serviceBalBefore + 0.8232 ether);
        assertEq(agent.balance, agentBalBefore + 1.2058 ether);

        // Resolver has subscription pool + fee pool
        (, , , , uint256 feePool) = fullResolver.getMarket(marketId);
        assertEq(feePool, 0.02 ether);
        assertEq(fullResolver.totalSubscriptionReceived(), 0.001 ether);
    }

    /* ---------- ServiceReputation event ---------- */

    function test_serviceReputation_emittedOnSettle() public {
        bytes32 marketId = _openMarket(address(mockResolver), 1 ether, 5 ether, 1);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectEmit(true, true, false, true);
        emit CrucibleMarketV4.ServiceReputation(service, marketId, 10000, 0);
        market.collectAfterWindow(marketId);
    }

    /* ---------- dispute bond still works (carried from v0.3) ---------- */

    function test_dispute_requiresExactBond() public {
        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 1);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV4.WrongDisputeBond.selector);
        market.dispute{value: 0.01 ether}(marketId);
    }

    /* ---------- openMarket happy path ---------- */

    function test_openMarket_happyPath() public {
        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 1);
        (
            address svc,
            address agt,
            address rslv,
            uint256 escrow,
            uint256 bondLocked,
            ,
            ,
            ,
            uint16 score,
            CrucibleMarketV4.Status status
        ) = market.markets(marketId);
        assertEq(svc, service);
        assertEq(agt, agent);
        assertEq(rslv, address(fullResolver));
        assertEq(escrow, 1 ether);
        assertEq(bondLocked, 5 ether);
        assertEq(score, 0);
        assertEq(uint256(status), uint256(CrucibleMarketV4.Status.Open));
    }

    /* ---------- requiredDisputeBond view ---------- */

    function test_requiredDisputeBond() public {
        bytes32 marketId = _openMarket(address(fullResolver), 2 ether, 5 ether, 1);
        assertEq(market.requiredDisputeBond(marketId), 0.1 ether);
    }

    /* ---------- score = 10000 disputed (frivolous dispute) ---------- */

    function test_disputed_score10000_serviceKeepsAll() public {
        address validator = makeAddr("v");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        fullResolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 1);
        uint256 bond = market.requiredDisputeBond(marketId);
        vm.prank(agent);
        market.dispute{value: bond}(marketId);

        vm.prank(validator);
        fullResolver.vote(marketId, 10000);
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId, "");

        // sub = 0.001, fee = 0.02. settleEscrow = 0.979.
        // score = 10000. paidToService = 0.979. refundEscrow = 0.
        // bondSlash = 0. bondToService = 0.05. bondRefund = 0.
        // totalToService = 0.979 + 0.05 = 1.029. totalToAgent = 0.
        assertEq(service.balance, serviceBalBefore + 1.029 ether);
        assertEq(agent.balance, agentBalBefore);
    }
}
