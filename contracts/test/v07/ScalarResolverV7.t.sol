// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ScalarResolverV7} from "../../src/v07/ScalarResolverV7.sol";

/// @title ScalarResolverV7 — staker-participant decoupling + window-denial fix
/// @dev   The test contract acts as the AUTHORIZED_MARKET so it can call
///        onDispute directly (in production the CrucibleMarket does).
contract ScalarResolverV7Test is Test {
    ScalarResolverV7 resolver;

    address v1 = makeAddr("v1");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");
    address service = makeAddr("service");
    address agent   = makeAddr("agent");
    address attacker = makeAddr("attacker");

    bytes32 constant MARKET_A = bytes32(uint256(1));
    bytes32 constant MARKET_B = bytes32(uint256(2));

    bytes32 constant SALT_1 = bytes32(uint256(0xAAA1));
    bytes32 constant SALT_2 = bytes32(uint256(0xBBB2));
    bytes32 constant SALT_3 = bytes32(uint256(0xCCC3));
    bytes32 constant SALT_S = bytes32(uint256(0x5151));

    function setUp() public {
        resolver = new ScalarResolverV7(0.1 ether, address(this));
        vm.deal(v1, 100 ether);
        vm.deal(v2, 100 ether);
        vm.deal(v3, 100 ether);
        vm.deal(service, 1000 ether);
        vm.deal(agent, 100 ether);
        vm.deal(attacker, 100 ether);
        vm.warp(1_000_000);
    }

    /* ---------- helpers ---------- */

    function _stake(address who, uint256 amt) internal {
        vm.prank(who);
        resolver.stake{value: amt}();
    }
    function _openVoting(bytes32 marketId) internal {
        resolver.onDispute(marketId, address(0), address(0)); // caller = this = market
    }
    function _commit(address voter, bytes32 marketId, uint16 score, bytes32 salt) internal {
        bytes32 h = resolver.computeVoteHash(score, salt, marketId, voter);
        vm.prank(voter);
        resolver.commitVote(marketId, h);
    }
    function _reveal(address voter, bytes32 marketId, uint16 score, bytes32 salt) internal {
        vm.prank(voter);
        resolver.revealVote(marketId, score, salt);
    }

    /* ---------- wiring ---------- */

    function test_constructor_setsAuthorizedMarket() public view {
        assertEq(resolver.AUTHORIZED_MARKET(), address(this));
        assertEq(resolver.name(), "ScalarResolverV7");
    }

    function test_constructor_zeroMarketReverts() public {
        vm.expectRevert("market zero");
        new ScalarResolverV7(0.1 ether, address(0));
    }

    /* ---------- onDispute authorization + effects ---------- */

    function test_onDispute_onlyAuthorizedMarket() public {
        vm.prank(attacker);
        vm.expectRevert(ScalarResolverV7.NotAuthorizedMarket.selector);
        resolver.onDispute(MARKET_A, service, agent);
    }

    function test_onDispute_opensVotingAndRegistersConflict() public {
        resolver.onDispute(MARKET_A, service, agent);
        assertTrue(resolver.conflicted(MARKET_A, service));
        assertTrue(resolver.conflicted(MARKET_A, agent));
        (uint64 commitDeadline, , , , , ) = resolver.getMarket(MARKET_A);
        assertGt(commitDeadline, 0); // voting opened
    }

    function test_onDispute_twiceReverts() public {
        resolver.onDispute(MARKET_A, service, agent);
        vm.expectRevert(ScalarResolverV7.VotingAlreadyOpen.selector);
        resolver.onDispute(MARKET_A, service, agent);
    }

    function test_onDispute_ignoresZeroAddress() public {
        resolver.onDispute(MARKET_A, service, address(0));
        assertTrue(resolver.conflicted(MARKET_A, service));
        assertFalse(resolver.conflicted(MARKET_A, address(0)));
    }

    /* ---------- THE window-denial fix ---------- */

    function test_cannotCommitBeforeVotingOpened() public {
        // The pre-dispute pre-commit attack: a participant who knows marketId
        // tries to start the commit clock before dispute. Now rejected.
        _stake(service, 50 ether);
        bytes32 h = resolver.computeVoteHash(10000, SALT_S, MARKET_A, service);
        vm.prank(service);
        vm.expectRevert(ScalarResolverV7.VotingNotOpen.selector);
        resolver.commitVote(MARKET_A, h);
    }

    /* ---------- decoupling: conflicted party cannot vote ---------- */

    function test_conflictedParty_cannotCommit() public {
        resolver.onDispute(MARKET_A, service, agent); // opens voting + conflicts
        _stake(service, 50 ether);
        bytes32 h = resolver.computeVoteHash(10000, SALT_S, MARKET_A, service);
        vm.prank(service);
        vm.expectRevert(ScalarResolverV7.ConflictedParty.selector);
        resolver.commitVote(MARKET_A, h);
    }

    /* ---------- headline: self-vote cannot skew the market ---------- */

    function test_decoupling_blocksSelfVoteSkew() public {
        uint256 t0 = block.timestamp;
        resolver.onDispute(MARKET_A, service, agent);

        _stake(service, 500 ether); // majority stake
        bytes32 hs = resolver.computeVoteHash(10000, SALT_S, MARKET_A, service);
        vm.prank(service);
        vm.expectRevert(ScalarResolverV7.ConflictedParty.selector);
        resolver.commitVote(MARKET_A, hs); // blocked at the door

        _stake(v1, 1 ether);
        _stake(v2, 1 ether);
        _stake(v3, 1 ether);
        _commit(v1, MARKET_A, 2000, SALT_1);
        _commit(v2, MARKET_A, 3000, SALT_2);
        _commit(v3, MARKET_A, 4000, SALT_3);

        vm.warp(t0 + 31 minutes);
        _reveal(v1, MARKET_A, 2000, SALT_1);
        _reveal(v2, MARKET_A, 3000, SALT_2);
        _reveal(v3, MARKET_A, 4000, SALT_3);

        vm.warp(t0 + 62 minutes);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 3000); // honest median; 500-ETH party could not move it
        assertEq(resolver.getVoters(MARKET_A).length, 3);
        assertEq(resolver.votes(MARKET_A, service), 0);
    }

    /* ---------- non-conflicted validators unaffected ---------- */

    function test_nonConflicted_resolveNormally() public {
        uint256 t0 = block.timestamp;
        resolver.onDispute(MARKET_A, service, agent);

        _stake(v1, 1 ether);
        _stake(v2, 1 ether);
        _stake(v3, 1 ether);
        _commit(v1, MARKET_A, 6000, SALT_1);
        _commit(v2, MARKET_A, 8000, SALT_2);
        _commit(v3, MARKET_A, 7000, SALT_3);
        vm.warp(t0 + 31 minutes);
        _reveal(v1, MARKET_A, 6000, SALT_1);
        _reveal(v2, MARKET_A, 8000, SALT_2);
        _reveal(v3, MARKET_A, 7000, SALT_3);
        vm.warp(t0 + 62 minutes);
        assertEq(resolver.resolve(MARKET_A, ""), 7000);
    }

    /* ---------- conflict is per-market ---------- */

    function test_conflict_isPerMarket() public {
        uint256 t0 = block.timestamp;
        resolver.onDispute(MARKET_A, service, agent); // service barred on A
        _openVoting(MARKET_B);                         // B opened, no conflicts

        _stake(service, 1 ether);
        _commit(service, MARKET_B, 5000, SALT_S);       // allowed on B
        vm.warp(t0 + 31 minutes);
        _reveal(service, MARKET_B, 5000, SALT_S);
        vm.warp(t0 + 62 minutes);
        assertEq(resolver.resolve(MARKET_B, ""), 5000);
        assertFalse(resolver.conflicted(MARKET_B, service));
    }

    /* ---------- edge: all validators conflicted => stuck (handoff to market) ---------- */

    function test_allConflicted_noVotes_cannotResolve() public {
        uint256 t0 = block.timestamp;
        // both honest-looking validators happen to be the two participants
        resolver.onDispute(MARKET_A, v1, v2);
        _stake(v1, 1 ether);
        _stake(v2, 1 ether);

        bytes32 h1 = resolver.computeVoteHash(9000, SALT_1, MARKET_A, v1);
        vm.prank(v1);
        vm.expectRevert(ScalarResolverV7.ConflictedParty.selector);
        resolver.commitVote(MARKET_A, h1);

        vm.warp(t0 + 62 minutes);
        assertFalse(resolver.canResolve(MARKET_A)); // no voters -> market force-resolves
    }
}
