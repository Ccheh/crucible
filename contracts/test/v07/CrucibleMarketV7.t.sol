// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CrucibleMarketV7} from "../../src/v07/CrucibleMarketV7.sol";
import {ScalarResolverV7} from "../../src/v07/ScalarResolverV7.sol";
import {MockResolver} from "../../src/resolvers/MockResolver.sol";

/// @title CrucibleMarketV7 — criteria pre-commitment, dispute taxonomy,
///        and end-to-end staker-participant decoupling.
contract CrucibleMarketV7Test is Test {
    CrucibleMarketV7 market;
    ScalarResolverV7 resolver;   // conflict-aware (bound to market)
    MockResolver mockResolver;   // NOT conflict-aware (graceful-degrade path)

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");
    address v1 = makeAddr("v1");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,uint16 disputeBondBps,bytes32 commitmentHash,bytes32 criteriaHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarketV7();
        resolver = new ScalarResolverV7(0.1 ether, address(market)); // bound to market
        mockResolver = new MockResolver();
        service = vm.addr(SERVICE_PK);
        vm.deal(service, 100 ether);
        vm.deal(agent, 100 ether);
        vm.deal(v1, 100 ether);
        vm.deal(v2, 100 ether);
        vm.deal(v3, 100 ether);
        vm.warp(1_000_000);

        vm.startPrank(service);
        market.depositBond{value: 20 ether}();
        market.setResolverAllowed(address(resolver), true);
        market.setResolverAllowed(address(mockResolver), true);
        vm.stopPrank();
    }

    /* ---------- signing helpers (v0.7: includes criteriaHash) ---------- */

    function _open(address rslv, uint256 amount, uint256 bondLock, uint16 bondBps, bytes32 criteria, uint256 nonce)
        internal returns (bytes32 marketId)
    {
        uint64 window = 1 hours;
        bytes32 commit = keccak256(abi.encode("deliverable", nonce));
        uint256 authExpiry = block.timestamp + 1 days;
        CrucibleMarketV7.OpenAuth memory auth = CrucibleMarketV7.OpenAuth({
            service: service, agent: agent, resolver: rslv,
            amount: amount, bondLockAmount: bondLock, disputeBondBps: bondBps,
            commitmentHash: commit, criteriaHash: criteria,
            disputeWindow: window, nonce: nonce, authExpiry: authExpiry
        });
        bytes32 structHash = keccak256(abi.encode(
            OPEN_AUTH_TYPEHASH, service, agent, rslv, amount, bondLock, bondBps,
            commit, criteria, window, nonce, authExpiry
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", market.DOMAIN_SEPARATOR(), structHash));
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(SERVICE_PK, digest);
        vm.prank(agent);
        marketId = market.openMarket{value: amount}(auth, abi.encodePacked(r, s, vv));
    }

    function _stakeVote(address who, bytes32 marketId, uint16 score, bytes32 salt) internal {
        // NB: compute the hash BEFORE vm.prank — a view call would otherwise
        // consume the single-call prank and commitVote would be sent by the
        // test contract (0 stake).
        bytes32 h = resolver.computeVoteHash(score, salt, marketId, who);
        vm.prank(who);
        resolver.commitVote(marketId, h);
    }

    /* ---------- domain ---------- */

    function test_eip712_versionIsSeven() public view {
        bytes32 expected = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("Crucible")), keccak256(bytes("7")), block.chainid, address(market)
        ));
        assertEq(market.DOMAIN_SEPARATOR(), expected);
    }

    /* ---------- criteria pre-commitment ---------- */

    function test_open_storesCriteriaHash() public {
        bytes32 criteria = keccak256("rubric: score 0-10000 by spec sections passed");
        bytes32 marketId = _open(address(resolver), 1 ether, 5 ether, 500, criteria, 1);
        ( , , , , , , , , bytes32 storedCriteria, , , , , , ) = market.markets(marketId);
        assertEq(storedCriteria, criteria);
    }

    /* ---------- dispute taxonomy ---------- */

    function test_dispute_unspecifiedKindReverts() public {
        bytes32 marketId = _open(address(resolver), 1 ether, 5 ether, 500, bytes32(0), 1);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV7.UnspecifiedDisputeKind.selector);
        market.dispute{value: 0.05 ether}(marketId, CrucibleMarketV7.DisputeKind.Unspecified);
    }

    function test_dispute_recordsKindAndDecoupling() public {
        bytes32 marketId = _open(address(resolver), 1 ether, 5 ether, 500, bytes32(0), 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId, CrucibleMarketV7.DisputeKind.Intersubjective);

        ( , , , , , , , , , , , , , CrucibleMarketV7.DisputeKind kind, bool decoupled) = market.markets(marketId);
        assertEq(uint256(kind), uint256(CrucibleMarketV7.DisputeKind.Intersubjective));
        assertTrue(decoupled);
        // Conflict actually registered in the resolver:
        assertTrue(resolver.conflicted(marketId, service));
        assertTrue(resolver.conflicted(marketId, agent));
    }

    /* ---------- end-to-end decoupling wired through the market ---------- */

    function test_dispute_serviceCannotVoteOnOwnMarket() public {
        bytes32 marketId = _open(address(resolver), 1 ether, 5 ether, 500, bytes32(0), 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId, CrucibleMarketV7.DisputeKind.Intersubjective);

        // Service stakes and tries to grade its OWN market — blocked.
        vm.prank(service);
        resolver.stake{value: 10 ether}();
        bytes32 h = resolver.computeVoteHash(10000, bytes32(uint256(0x99)), marketId, service);
        vm.prank(service);
        vm.expectRevert(ScalarResolverV7.ConflictedParty.selector);
        resolver.commitVote(marketId, h);
    }

    /* ---------- end-to-end CONTINUOUS proportional settlement ---------- */

    function test_endToEnd_proportionalSettlement_score3000() public {
        uint256 t0 = block.timestamp;
        // validators stake
        vm.prank(v1); resolver.stake{value: 1 ether}();
        vm.prank(v2); resolver.stake{value: 1 ether}();
        vm.prank(v3); resolver.stake{value: 1 ether}();

        bytes32 marketId = _open(address(resolver), 1 ether, 5 ether, 500, bytes32(0), 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId, CrucibleMarketV7.DisputeKind.Intersubjective);

        // honest votes [2000,3000,4000] -> median 3000
        _stakeVote(v1, marketId, 2000, bytes32(uint256(1)));
        _stakeVote(v2, marketId, 3000, bytes32(uint256(2)));
        _stakeVote(v3, marketId, 4000, bytes32(uint256(3)));
        vm.warp(t0 + 31 minutes);
        vm.prank(v1); resolver.revealVote(marketId, 2000, bytes32(uint256(1)));
        vm.prank(v2); resolver.revealVote(marketId, 3000, bytes32(uint256(2)));
        vm.prank(v3); resolver.revealVote(marketId, 4000, bytes32(uint256(3)));
        vm.warp(t0 + 62 minutes);

        uint256 s0 = service.balance;
        uint256 a0 = agent.balance;
        market.resolveDisputed(marketId, "");

        // escrow 1; sub=0.001; fee=0.02; settleEscrow=0.979
        // paidToService = 0.979 * 0.30 = 0.2937; bondToService = 0.05*0.30 = 0.015
        // totalToService = 0.3087
        // refundToAgent = 0.6853; bondSlash = 5 * 0.70 = 3.5; bondRefund = 0.035
        // totalToAgent = 4.2203
        assertEq(service.balance - s0, 0.3087 ether, "service proportional share");
        assertEq(agent.balance - a0, 4.2203 ether, "agent proportional refund + slashed bond");
    }

    /* ---------- graceful degrade: non-conflict-aware resolver ---------- */

    function test_dispute_decouplingFalse_forNonAwareResolver() public {
        // MockResolver has no registerConflict -> try/catch -> decouplingActive=false,
        // dispute still succeeds (no bricking).
        bytes32 marketId = _open(address(mockResolver), 1 ether, 5 ether, 500, bytes32(0), 1);
        vm.prank(agent);
        market.dispute{value: 0.05 ether}(marketId, CrucibleMarketV7.DisputeKind.Objective);

        ( , , , , , , , , , , , , , , bool decoupled) = market.markets(marketId);
        assertFalse(decoupled);
    }

    /* ---------- carry-over: optimistic path still pays the service ---------- */

    function test_optimistic_carryOver() public {
        vm.prank(v1); resolver.stake{value: 1 ether}();
        bytes32 marketId = _open(address(resolver), 1 ether, 5 ether, 500, bytes32(0), 1);
        uint256 s0 = service.balance;
        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);
        assertEq(service.balance - s0, 0.999 ether); // escrow - subscription
    }
}
