// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CrucibleMarket} from "../src/CrucibleMarket.sol";
import {MockResolver} from "../src/resolvers/MockResolver.sol";

contract CrucibleMarketTest is Test {
    CrucibleMarket market;
    MockResolver resolver;

    uint256 constant SERVICE_PK = 0xA1;
    address service;
    address agent = makeAddr("agent");

    bytes32 constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    function setUp() public {
        market = new CrucibleMarket();
        resolver = new MockResolver();
        service = vm.addr(SERVICE_PK);
        vm.deal(service, 100 ether);
        vm.deal(agent, 100 ether);

        // service deposits bond and whitelists the resolver
        vm.prank(service);
        market.depositBond{value: 10 ether}();
        vm.prank(service);
        market.setResolverAllowed(address(resolver), true);
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

    function _openHappyMarket(uint256 amount, uint256 bondLock) internal returns (bytes32 marketId) {
        uint64 window = 1 hours;
        bytes32 commit = keccak256("test-commitment");
        uint256 nonce = 1;
        uint256 authExpiry = block.timestamp + 1 days;

        CrucibleMarket.OpenAuth memory auth = CrucibleMarket.OpenAuth({
            service: service,
            agent: agent,
            resolver: address(resolver),
            amount: amount,
            bondLockAmount: bondLock,
            commitmentHash: commit,
            disputeWindow: window,
            nonce: nonce,
            authExpiry: authExpiry
        });

        bytes memory sig = _signOpen(
            service, agent, address(resolver), amount, bondLock, commit, window, nonce, authExpiry
        );

        vm.prank(agent);
        marketId = market.openMarket{value: amount}(auth, sig);
    }

    /* ---------- bond pool ---------- */

    function test_depositBond_increasesPool() public {
        assertEq(market.bondPool(service), 10 ether);
    }

    function test_withdrawBond_works() public {
        vm.prank(service);
        market.withdrawBond(3 ether);
        assertEq(market.bondPool(service), 7 ether);
    }

    function test_withdrawBond_revertsIfLocked() public {
        _openHappyMarket(1 ether, 5 ether);
        assertEq(market.bondLocked(service), 5 ether);
        // Try to withdraw more than (pool - locked)
        vm.prank(service);
        vm.expectRevert(CrucibleMarket.InsufficientBond.selector);
        market.withdrawBond(6 ether);
    }

    /* ---------- openMarket ---------- */

    function test_openMarket_happyPath() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);

        (
            address svc,
            address agt,
            address rslv,
            uint256 escrow,
            uint256 bondLocked,
            ,
            uint64 deadline,
            uint16 score,
            CrucibleMarket.Status status
        ) = market.markets(marketId);

        assertEq(svc, service);
        assertEq(agt, agent);
        assertEq(rslv, address(resolver));
        assertEq(escrow, 1 ether);
        assertEq(bondLocked, 5 ether);
        assertEq(deadline, block.timestamp + 1 hours);
        assertEq(score, 0);
        assertEq(uint256(status), uint256(CrucibleMarket.Status.Open));

        assertEq(market.bondLocked(service), 5 ether);
        // contract holds: service bond pool (10) + agent escrow (1) = 11 ether
        assertEq(address(market).balance, 11 ether);
    }

    function test_openMarket_revertsIfResolverNotAllowed() public {
        // Service un-whitelists the resolver
        vm.prank(service);
        market.setResolverAllowed(address(resolver), false);

        uint256 amount = 1 ether;
        uint256 bondLock = 5 ether;
        uint64 window = 1 hours;
        bytes32 commit = keccak256("test");
        CrucibleMarket.OpenAuth memory auth = CrucibleMarket.OpenAuth({
            service: service, agent: agent, resolver: address(resolver),
            amount: amount, bondLockAmount: bondLock, commitmentHash: commit,
            disputeWindow: window, nonce: 1, authExpiry: block.timestamp + 1 days
        });
        bytes memory sig = _signOpen(service, agent, address(resolver), amount, bondLock, commit, window, 1, block.timestamp + 1 days);

        vm.prank(agent);
        vm.expectRevert(CrucibleMarket.ResolverNotAllowed.selector);
        market.openMarket{value: amount}(auth, sig);
    }

    function test_openMarket_revertsOnForgedSig() public {
        uint256 amount = 1 ether;
        uint256 bondLock = 5 ether;
        uint64 window = 1 hours;
        bytes32 commit = keccak256("test");
        CrucibleMarket.OpenAuth memory auth = CrucibleMarket.OpenAuth({
            service: service, agent: agent, resolver: address(resolver),
            amount: amount, bondLockAmount: bondLock, commitmentHash: commit,
            disputeWindow: window, nonce: 1, authExpiry: block.timestamp + 1 days
        });
        // Sign with a different key
        uint256 fakePk = 0xDEAD;
        bytes32 structHash = keccak256(abi.encode(
            OPEN_AUTH_TYPEHASH,
            service, agent, address(resolver), amount, bondLock, commit, window, 1, block.timestamp + 1 days
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", market.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fakePk, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(agent);
        vm.expectRevert(CrucibleMarket.InvalidSignature.selector);
        market.openMarket{value: amount}(auth, badSig);
    }

    /* ---------- optimistic settle ---------- */

    function test_collectAfterWindow_scoreFullPay() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);
        uint256 serviceBalBefore = service.balance;

        vm.warp(block.timestamp + 1 hours + 1);
        market.collectAfterWindow(marketId);

        // service collected 1 ether; locked bond released
        assertEq(service.balance, serviceBalBefore + 1 ether);
        assertEq(market.bondLocked(service), 0);
        assertEq(market.bondPool(service), 10 ether); // no slash

        (,,,,,,, uint16 score, CrucibleMarket.Status status) = market.markets(marketId);
        assertEq(score, 10000);
        assertEq(uint256(status), uint256(CrucibleMarket.Status.Resolved));
    }

    function test_collectAfterWindow_revertsBeforeDeadline() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);
        vm.expectRevert(CrucibleMarket.WindowNotPassed.selector);
        market.collectAfterWindow(marketId);
    }

    /* ---------- dispute + resolve ---------- */

    function test_disputeAndResolve_score5000() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);

        uint256 agentBalBefore = agent.balance;
        uint256 serviceBalBefore = service.balance;

        vm.prank(agent);
        market.dispute(marketId);

        // Resolve at score 5000 (50%)
        market.resolveDisputed(marketId, abi.encode(uint256(5000)));

        // service receives 50% of escrow = 0.5 ether; bond slashed 50% of 5 ether = 2.5 ether to agent
        assertEq(service.balance, serviceBalBefore + 0.5 ether);
        assertEq(agent.balance, agentBalBefore + 0.5 ether + 2.5 ether);

        assertEq(market.bondLocked(service), 0);
        assertEq(market.bondPool(service), 10 ether - 2.5 ether);
    }

    function test_disputeAndResolve_score0_fullSlash() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);
        vm.prank(agent);
        market.dispute(marketId);

        uint256 agentBalBefore = agent.balance;
        uint256 serviceBalBefore = service.balance;

        market.resolveDisputed(marketId, abi.encode(uint256(0)));

        // service receives 0; agent gets full escrow (1) + full bond (5) = 6 ether
        assertEq(service.balance, serviceBalBefore);
        assertEq(agent.balance, agentBalBefore + 6 ether);
        assertEq(market.bondPool(service), 10 ether - 5 ether);
    }

    function test_dispute_revertsAfterDeadline() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(agent);
        vm.expectRevert(CrucibleMarket.WindowExpired.selector);
        market.dispute(marketId);
    }

    function test_dispute_revertsIfNotAgent() public {
        bytes32 marketId = _openHappyMarket(1 ether, 5 ether);
        vm.expectRevert(CrucibleMarket.InvalidAgent.selector);
        market.dispute(marketId);
    }

    /* ---------- replay protection ---------- */

    function test_openMarket_revertsOnSameNonce() public {
        _openHappyMarket(1 ether, 5 ether);

        // Try to reuse same nonce
        uint256 amount = 1 ether;
        uint256 bondLock = 5 ether;
        uint64 window = 1 hours;
        bytes32 commit = keccak256("test-commitment");
        CrucibleMarket.OpenAuth memory auth = CrucibleMarket.OpenAuth({
            service: service, agent: agent, resolver: address(resolver),
            amount: amount, bondLockAmount: bondLock, commitmentHash: commit,
            disputeWindow: window, nonce: 1, authExpiry: block.timestamp + 1 days
        });
        bytes memory sig = _signOpen(service, agent, address(resolver), amount, bondLock, commit, window, 1, block.timestamp + 1 days);

        vm.prank(agent);
        vm.expectRevert(CrucibleMarket.MarketAlreadyExists.selector);
        market.openMarket{value: amount}(auth, sig);
    }
}
