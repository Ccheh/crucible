// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ScalarResolverV8} from "../../src/v07/ScalarResolverV8.sol";

/// @dev minimal ERC-8004 IdentityRegistry mock (ownerOf + isApprovedForAll).
contract MockErc8004 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    function setOwner(uint256 agentId, address owner) external { ownerOf[agentId] = owner; }
    function setApproval(address owner, address operator, bool ok) external { isApprovedForAll[owner][operator] = ok; }
}

/// @title ScalarResolverV8 — ERC-8004 identity binding (M2)
contract ScalarResolverV8Test is Test {
    ScalarResolverV8 resolver;
    MockErc8004 idr;

    address service = makeAddr("service");   // identity owner + market participant
    address opAddr  = makeAddr("opAddr");    // operator of service's identity
    address agent   = makeAddr("agent");
    address v1      = makeAddr("v1");        // unrelated honest validator
    address attacker = makeAddr("attacker");

    uint256 constant SERVICE_AGENTID = 1;
    bytes32 constant MARKET_A = bytes32(uint256(0xA));
    bytes32 constant SALT = bytes32(uint256(0x5));

    function setUp() public {
        idr = new MockErc8004();
        resolver = new ScalarResolverV8(0.1 ether, address(this), address(idr));
        idr.setOwner(SERVICE_AGENTID, service);
        idr.setApproval(service, opAddr, true); // opAddr operates service's identity
        vm.deal(service, 100 ether);
        vm.deal(opAddr, 100 ether);
        vm.deal(v1, 100 ether);
        vm.deal(attacker, 100 ether);
        vm.warp(1_000_000);
    }

    /* ---------- linkIdentity ---------- */

    function test_linkIdentity_owner() public {
        vm.prank(service);
        resolver.linkIdentity(SERVICE_AGENTID);
        assertEq(resolver.linkedAgentId(service), SERVICE_AGENTID);
        assertTrue(resolver.hasLinkedIdentity(service));
    }

    function test_linkIdentity_operator() public {
        vm.prank(opAddr);
        resolver.linkIdentity(SERVICE_AGENTID); // opAddr is an approved operator
        assertEq(resolver.linkedAgentId(opAddr), SERVICE_AGENTID);
    }

    function test_linkIdentity_notOwnerNorOperator_reverts() public {
        vm.prank(attacker);
        vm.expectRevert(ScalarResolverV8.NotIdentityOwnerOrOperator.selector);
        resolver.linkIdentity(SERVICE_AGENTID);
    }

    function test_linkIdentity_registryDisabled_reverts() public {
        ScalarResolverV8 noId = new ScalarResolverV8(0.1 ether, address(this), address(0));
        vm.prank(service);
        vm.expectRevert(ScalarResolverV8.IdentityRegistryNotSet.selector);
        noId.linkIdentity(SERVICE_AGENTID);
    }

    /* ---------- headline M2: identity-level decoupling ---------- */

    function test_identityLevelConflict_barsOtherAddressOfSameIdentity() public {
        // service and its operator opAddr both link the same ERC-8004 identity.
        vm.prank(service); resolver.linkIdentity(SERVICE_AGENTID);
        vm.prank(opAddr);  resolver.linkIdentity(SERVICE_AGENTID);

        // opAddr stakes and would try to vote on service's own market via a
        // different address — the sybil-via-operator move.
        vm.prank(opAddr); resolver.stake{value: 10 ether}();

        // Market disputed: only `service` (and `agent`) are named by the market.
        resolver.onDispute(MARKET_A, service, agent);

        // opAddr was NOT named, but is barred via the shared identity.
        assertTrue(resolver.effectiveConflict(MARKET_A, opAddr));
        bytes32 h = resolver.computeVoteHash(10000, SALT, MARKET_A, opAddr);
        vm.prank(opAddr);
        vm.expectRevert(ScalarResolverV8.ConflictedParty.selector);
        resolver.commitVote(MARKET_A, h);
    }

    function test_unlinkedValidator_canVote() public {
        resolver.onDispute(MARKET_A, service, agent);
        uint256 t0 = block.timestamp;
        // v1 has no identity and is not a participant -> votes normally
        vm.prank(v1); resolver.stake{value: 1 ether}();
        bytes32 h = resolver.computeVoteHash(7000, SALT, MARKET_A, v1);
        vm.prank(v1); resolver.commitVote(MARKET_A, h);
        vm.warp(t0 + 31 minutes);
        vm.prank(v1); resolver.revealVote(MARKET_A, 7000, SALT);
        vm.warp(t0 + 62 minutes);
        assertEq(resolver.resolve(MARKET_A, ""), 7000);
    }

    /* ---------- graceful: registry disabled => pure v0.7 address-level ---------- */

    function test_registryDisabled_addressLevelOnly() public {
        ScalarResolverV8 noId = new ScalarResolverV8(0.1 ether, address(this), address(0));
        noId.onDispute(MARKET_A, service, agent);
        assertTrue(noId.effectiveConflict(MARKET_A, service)); // address-level still works
        assertFalse(noId.effectiveConflict(MARKET_A, opAddr)); // no identity expansion
        assertEq(noId.name(), "ScalarResolverV8");
    }
}
