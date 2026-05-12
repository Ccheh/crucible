// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CrucibleMarketV3} from "../src/v03/CrucibleMarketV3.sol";
import {TestcaseResolverV3} from "../src/v03/TestcaseResolverV3.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

/// @title CrucibleMarketV3 — dispute-bond tests
contract CrucibleMarketV3Test is Test {
    CrucibleMarketV3 market;
    TestcaseResolverV3 feeResolver;
    MockResolver mockResolver;

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarketV3();
        feeResolver = new TestcaseResolverV3();
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
        CrucibleMarketV3.OpenAuth memory auth = CrucibleMarketV3.OpenAuth({
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

    function _disputeWithBond(bytes32 marketId) internal {
        uint256 bond = market.requiredDisputeBond(marketId);
        vm.prank(agent);
        market.dispute{value: bond}(marketId);
    }

    /* ---------- domain version ---------- */

    function test_eip712_versionIsThree() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Crucible")),
                keccak256(bytes("3")),
                block.chainid,
                address(market)
            )
        );
        assertEq(market.DOMAIN_SEPARATOR(), expected);
    }

    /* ---------- dispute bond requirement ---------- */

    function test_dispute_revertsWithoutBond() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV3.WrongDisputeBond.selector);
        market.dispute(marketId);
    }

    function test_dispute_revertsWithWrongBond() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV3.WrongDisputeBond.selector);
        market.dispute{value: 0.01 ether}(marketId);
    }

    function test_dispute_succeedsWithExactBond() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        uint256 expectedBond = market.requiredDisputeBond(marketId);
        // 5% of 1 ether = 0.05 ether
        assertEq(expectedBond, 0.05 ether);
        vm.prank(agent);
        market.dispute{value: expectedBond}(marketId);
    }

    function test_requiredDisputeBond_view() public {
        bytes32 marketId = _openMarket(address(feeResolver), 2 ether, 5 ether, 1);
        // 5% of 2 ether = 0.1 ether
        assertEq(market.requiredDisputeBond(marketId), 0.1 ether);
    }

    /* ---------- optimistic path: no bond, no fee ---------- */

    function test_collectAfterWindow_noBondNoFee() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        uint256 serviceBalBefore = service.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        // Service gets full 1 ether escrow, no fee siphoned.
        assertEq(service.balance, serviceBalBefore + 1 ether);
        (, , , , uint256 feePool) = feeResolver.getMarket(marketId);
        assertEq(feePool, 0);
    }

    /* ---------- disputed path settlement math ---------- */

    function test_disputeAndResolve_scoreZero_agentGetsAllBondBack() public {
        // Agent absolutely right: scoreBps = 0.
        // resolverFee = 0.02 ether (2% of 1 ether escrow)
        // settleEscrow = 0.98 ether
        // paidToService = 0
        // refundEscrow = 0.98
        // bondSlash = 5 (full bond → agent)
        // bondToService = 0 * 0.05 = 0
        // bondRefund = 0.05 (full dispute bond → agent)
        // totalToService = 0
        // totalToAgent = 0.98 + 5 + 0.05 = 6.03
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        _disputeWithBond(marketId);

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

        assertEq(service.balance, serviceBalBefore);
        assertEq(agent.balance, agentBalBefore + 6.03 ether);
    }

    function test_disputeAndResolve_scoreMax_serviceKeepsBond() public {
        // Agent absolutely wrong: scoreBps = 10000.
        // resolverFee = 0.02. settleEscrow = 0.98.
        // paidToService = 0.98, refundEscrow = 0
        // bondSlash = 0, bondToService = 0.05 (full bond → service), bondRefund = 0
        // totalToService = 0.98 + 0.05 = 1.03
        // totalToAgent = 0
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        _disputeWithBond(marketId);

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

        assertEq(service.balance, serviceBalBefore + 1.03 ether);
        assertEq(agent.balance, agentBalBefore);
    }

    function test_disputeAndResolve_score5000_bondSplitsEvenly() public {
        // Half-right: scoreBps = 5000.
        // resolverFee = 0.02. settleEscrow = 0.98.
        // paidToService = 0.49, refundEscrow = 0.49
        // bondSlash = 2.5 (half-bond → agent)
        // bondToService = 0.025, bondRefund = 0.025
        // totalToService = 0.49 + 0.025 = 0.515
        // totalToAgent = 0.49 + 2.5 + 0.025 = 3.015
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        _disputeWithBond(marketId);

        // Two-validator median: votes 4000 and 6000 → median = either 4000 or 6000
        // depending on order. Use MockResolver to force exact score.
        bytes32 marketId2 = _openMarket(address(mockResolver), 1 ether, 5 ether, 2);
        _disputeWithBond(marketId2);

        uint256 serviceBalBefore = service.balance;
        uint256 agentBalBefore = agent.balance;

        market.resolveDisputed(marketId2, abi.encode(uint256(5000)));

        // Mock resolver doesn't accept notifyFee → fee stays in escrow.
        // settleEscrow = 1 ether (no fee deduction). paidToService = 0.5,
        // refundEscrow = 0.5, bondSlash = 2.5, bondToService = 0.025,
        // bondRefund = 0.025. totalToService = 0.525. totalToAgent = 3.025.
        assertEq(service.balance, serviceBalBefore + 0.525 ether);
        assertEq(agent.balance, agentBalBefore + 3.025 ether);
    }

    function test_dispute_revertsAfterDeadline() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 bond = market.requiredDisputeBond(marketId);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV3.WindowExpired.selector);
        market.dispute{value: bond}(marketId);
    }

    function test_openMarket_happyPath() public {
        bytes32 marketId = _openMarket(address(feeResolver), 1 ether, 5 ether, 1);
        (
            address svc,
            address agt,
            address rslv,
            uint256 escrow,
            uint256 bondLocked,
            uint256 disputeBond,
            ,
            uint64 deadline,
            uint16 score,
            CrucibleMarketV3.Status status
        ) = market.markets(marketId);
        assertEq(svc, service);
        assertEq(agt, agent);
        assertEq(rslv, address(feeResolver));
        assertEq(escrow, 1 ether);
        assertEq(bondLocked, 5 ether);
        assertEq(disputeBond, 0);  // not yet disputed
        assertEq(deadline, block.timestamp + 1 hours);
        assertEq(score, 0);
        assertEq(uint256(status), uint256(CrucibleMarketV3.Status.Open));
    }
}
