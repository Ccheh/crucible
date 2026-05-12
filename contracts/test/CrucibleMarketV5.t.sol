// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CrucibleMarketV5} from "../src/v05/CrucibleMarketV5.sol";
import {TestcaseResolverV5} from "../src/v05/TestcaseResolverV5.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

/// @title CrucibleMarketV5 — per-market disputeBondBps tests
contract CrucibleMarketV5Test is Test {
    CrucibleMarketV5 market;
    TestcaseResolverV5 fullResolver;
    MockResolver mockResolver;

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,uint16 disputeBondBps,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarketV5();
        fullResolver = new TestcaseResolverV5(0.1 ether);
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
        CrucibleMarketV5.OpenAuth memory auth = CrucibleMarketV5.OpenAuth({
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

    /* ---------- domain v5 ---------- */

    function test_eip712_versionIsFive() public view {
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Crucible")),
                keccak256(bytes("5")),
                block.chainid,
                address(market)
            )
        );
        assertEq(market.DOMAIN_SEPARATOR(), expected);
    }

    /* ---------- per-market bond: range validation ---------- */

    function test_openMarket_bondBpsBelowMinReverts() public {
        // 99 bps below MIN of 100 bps
        uint64 window = 1 hours;
        bytes32 commit = keccak256("c");
        uint256 authExpiry = block.timestamp + 1 days;
        CrucibleMarketV5.OpenAuth memory auth = CrucibleMarketV5.OpenAuth({
            service: service, agent: agent, resolver: address(fullResolver),
            amount: 1 ether, bondLockAmount: 5 ether, disputeBondBps: 99,
            commitmentHash: commit, disputeWindow: window, nonce: 1, authExpiry: authExpiry
        });
        bytes memory sig = _signOpen(service, agent, address(fullResolver), 1 ether, 5 ether, 99, commit, window, 1, authExpiry);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV5.DisputeBondOutOfRange.selector);
        market.openMarket{value: 1 ether}(auth, sig);
    }

    function test_openMarket_bondBpsAboveMaxReverts() public {
        // 5001 bps above MAX of 5000 bps
        uint64 window = 1 hours;
        bytes32 commit = keccak256("c2");
        uint256 authExpiry = block.timestamp + 1 days;
        CrucibleMarketV5.OpenAuth memory auth = CrucibleMarketV5.OpenAuth({
            service: service, agent: agent, resolver: address(fullResolver),
            amount: 1 ether, bondLockAmount: 5 ether, disputeBondBps: 5001,
            commitmentHash: commit, disputeWindow: window, nonce: 2, authExpiry: authExpiry
        });
        bytes memory sig = _signOpen(service, agent, address(fullResolver), 1 ether, 5 ether, 5001, commit, window, 2, authExpiry);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV5.DisputeBondOutOfRange.selector);
        market.openMarket{value: 1 ether}(auth, sig);
    }

    function test_openMarket_bondBpsAtMin_succeeds() public {
        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 100, 1);
        // 1% of 1 ether = 0.01 ether
        assertEq(market.requiredDisputeBond(marketId), 0.01 ether);
    }

    function test_openMarket_bondBpsAtMax_succeeds() public {
        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 5000, 2);
        // 50% of 1 ether = 0.5 ether
        assertEq(market.requiredDisputeBond(marketId), 0.5 ether);
    }

    /* ---------- per-market bond: different bonds for different markets ---------- */

    function test_openMarket_differentMarketsHaveDifferentBonds() public {
        bytes32 lowBondMarket = _openMarket(address(fullResolver), 1 ether, 5 ether, 100, 1);   // 1%
        bytes32 highBondMarket = _openMarket(address(fullResolver), 1 ether, 5 ether, 2000, 2); // 20%

        assertEq(market.requiredDisputeBond(lowBondMarket), 0.01 ether);
        assertEq(market.requiredDisputeBond(highBondMarket), 0.2 ether);
    }

    function test_dispute_usesPerMarketBond() public {
        bytes32 lowBondMarket = _openMarket(address(fullResolver), 1 ether, 5 ether, 100, 1);

        // Wrong bond (using 5% instead of 1%) reverts
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV5.WrongDisputeBond.selector);
        market.dispute{value: 0.05 ether}(lowBondMarket);

        // Correct 1% bond succeeds
        vm.prank(agent);
        market.dispute{value: 0.01 ether}(lowBondMarket);
    }

    /* ---------- subscription still works ---------- */

    function test_optimistic_subscriptionPaid() public {
        address validator = makeAddr("v");
        vm.deal(validator, 5 ether);
        vm.prank(validator);
        fullResolver.stake{value: 1 ether}();

        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 500, 1);
        uint256 serviceBalBefore = service.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        // sub = 0.001, service gets 0.999
        assertEq(service.balance, serviceBalBefore + 0.999 ether);
        assertEq(fullResolver.earnedSubscription(validator), 0.001 ether);
    }

    /* ---------- ServiceReputation event still emits ---------- */

    function test_serviceReputation_emitted() public {
        bytes32 marketId = _openMarket(address(mockResolver), 1 ether, 5 ether, 500, 1);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectEmit(true, true, false, true);
        emit CrucibleMarketV5.ServiceReputation(service, marketId, 10000, 0);
        market.collectAfterWindow(marketId);
    }

    /* ---------- happy path with default-like config ---------- */

    function test_openMarket_happyPathWith500BpsBond() public {
        bytes32 marketId = _openMarket(address(fullResolver), 1 ether, 5 ether, 500, 1);
        (
            address svc,
            address agt,
            address rslv,
            uint256 escrow,
            uint256 bondLocked,
            uint256 disputeBond,
            uint16 bondBps,
            ,
            ,
            ,
            CrucibleMarketV5.Status status
        ) = market.markets(marketId);
        assertEq(svc, service);
        assertEq(agt, agent);
        assertEq(rslv, address(fullResolver));
        assertEq(escrow, 1 ether);
        assertEq(bondLocked, 5 ether);
        assertEq(disputeBond, 0); // not yet disputed
        assertEq(bondBps, 500);
        assertEq(uint256(status), uint256(CrucibleMarketV5.Status.Open));
    }

    /* ---------- signature with different bondBps fails ---------- */

    function test_openMarket_tamperedBondBpsFails() public {
        // Sign with bondBps=500, then try to use the sig with bondBps=200.
        uint64 window = 1 hours;
        bytes32 commit = keccak256("ct");
        uint256 authExpiry = block.timestamp + 1 days;
        bytes memory sig = _signOpen(service, agent, address(fullResolver), 1 ether, 5 ether, 500, commit, window, 1, authExpiry);

        // Try to use sig with different bondBps
        CrucibleMarketV5.OpenAuth memory auth = CrucibleMarketV5.OpenAuth({
            service: service, agent: agent, resolver: address(fullResolver),
            amount: 1 ether, bondLockAmount: 5 ether, disputeBondBps: 200,
            commitmentHash: commit, disputeWindow: window, nonce: 1, authExpiry: authExpiry
        });
        vm.prank(agent);
        vm.expectRevert(CrucibleMarketV5.InvalidSignature.selector);
        market.openMarket{value: 1 ether}(auth, sig);
    }
}
