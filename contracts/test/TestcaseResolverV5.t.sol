// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestcaseResolverV5} from "../src/v05/TestcaseResolverV5.sol";

/// @title TestcaseResolverV5 — commit-reveal + adjustable minStake tests
contract TestcaseResolverV5Test is Test {
    TestcaseResolverV5 resolver;

    address v1 = makeAddr("v1");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");
    address v4 = makeAddr("v4");
    address v5 = makeAddr("v5");
    address feePayer = makeAddr("feePayer");

    bytes32 constant MARKET_A = bytes32(uint256(1));
    bytes32 constant MARKET_B = bytes32(uint256(2));

    bytes32 constant SALT_1 = bytes32(uint256(0xAAA1));
    bytes32 constant SALT_2 = bytes32(uint256(0xBBB2));
    bytes32 constant SALT_3 = bytes32(uint256(0xCCC3));
    bytes32 constant SALT_4 = bytes32(uint256(0xDDD4));
    bytes32 constant SALT_5 = bytes32(uint256(0xEEE5));

    function setUp() public {
        resolver = new TestcaseResolverV5(0.1 ether); // testnet config
        vm.deal(v1, 100 ether);
        vm.deal(v2, 100 ether);
        vm.deal(v3, 100 ether);
        vm.deal(v4, 100 ether);
        vm.deal(v5, 100 ether);
        vm.deal(feePayer, 100 ether);
        vm.warp(1_000_000);
    }

    /* ---------- constructor + name ---------- */

    function test_name() public view {
        assertEq(resolver.name(), "TestcaseResolverV5");
    }

    function test_constructor_setsMinStake() public view {
        assertEq(resolver.MIN_STAKE(), 0.1 ether);
    }

    function test_constructor_zeroMinStakeReverts() public {
        vm.expectRevert("minStake must be > 0");
        new TestcaseResolverV5(0);
    }

    function test_constructor_alternativeMinStakeFlexibility() public {
        TestcaseResolverV5 mainnetResolver = new TestcaseResolverV5(1 ether);
        assertEq(mainnetResolver.MIN_STAKE(), 1 ether);
    }

    /* ---------- helper ---------- */

    function _commitAndReveal(address voter, bytes32 marketId, uint16 score, bytes32 salt) internal {
        bytes32 h = resolver.computeVoteHash(score, salt, marketId, voter);
        vm.prank(voter);
        resolver.commitVote(marketId, h);
    }

    function _revealAfterCommit(address voter, bytes32 marketId, uint16 score, bytes32 salt) internal {
        vm.prank(voter);
        resolver.revealVote(marketId, score, salt);
    }

    /* ---------- commit phase ---------- */

    function test_commit_belowMinStakeReverts() public {
        // v1 has 0 stake — can't commit
        bytes32 h = resolver.computeVoteHash(8000, SALT_1, MARKET_A, v1);
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.InsufficientStake.selector);
        resolver.commitVote(MARKET_A, h);
    }

    function test_commit_doubleCommitReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);
        bytes32 h = resolver.computeVoteHash(7000, SALT_2, MARKET_A, v1);
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.AlreadyCommitted.selector);
        resolver.commitVote(MARKET_A, h);
    }

    function test_commit_afterCommitWindowReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        // Advance past commit window
        vm.warp(block.timestamp + 31 minutes);

        bytes32 h = resolver.computeVoteHash(7000, SALT_2, MARKET_A, v2);
        vm.prank(v2);
        vm.expectRevert(TestcaseResolverV5.CommitWindowClosed.selector);
        resolver.commitVote(MARKET_A, h);
    }

    /* ---------- reveal phase ---------- */

    function test_reveal_beforeWindowReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        // Still in commit window — can't reveal yet
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.RevealWindowNotOpen.selector);
        resolver.revealVote(MARKET_A, 8000, SALT_1);
    }

    function test_reveal_afterRevealWindowReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);
        // Skip past both windows
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.RevealWindowClosed.selector);
        resolver.revealVote(MARKET_A, 8000, SALT_1);
    }

    function test_reveal_wrongScoreReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        vm.warp(block.timestamp + 31 minutes);
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.WrongReveal.selector);
        resolver.revealVote(MARKET_A, 9000, SALT_1);
    }

    function test_reveal_wrongSaltReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        vm.warp(block.timestamp + 31 minutes);
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.WrongReveal.selector);
        resolver.revealVote(MARKET_A, 8000, SALT_2);
    }

    function test_reveal_succeeds() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        vm.warp(block.timestamp + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 8000, SALT_1);

        assertEq(resolver.votes(MARKET_A, v1), 8000);
        assertEq(resolver.hasRevealed(MARKET_A, v1), true);
        assertEq(resolver.pendingVotes(v1), 1);
    }

    function test_reveal_doubleRevealReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        vm.warp(block.timestamp + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 8000, SALT_1);

        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV5.AlreadyRevealed.selector);
        resolver.revealVote(MARKET_A, 8000, SALT_1);
    }

    function test_reveal_noCommitReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        vm.warp(block.timestamp + 31 minutes);
        vm.prank(v2);
        vm.expectRevert(TestcaseResolverV5.NoCommit.selector);
        resolver.revealVote(MARKET_A, 8000, SALT_1);
    }

    /* ---------- full resolve via commit-reveal ---------- */

    function test_fullLifecycle_medianResolves() public {
        // Three equal-stake validators, commit + reveal + resolve.
        // Use absolute timestamps (Foundry's vm.warp doesn't update test-body
        // reads of block.timestamp between calls).
        uint256 t0 = block.timestamp;
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        _commitAndReveal(v1, MARKET_A, 4000, SALT_1);
        _commitAndReveal(v2, MARKET_A, 9000, SALT_2);
        _commitAndReveal(v3, MARKET_A, 7000, SALT_3);

        vm.warp(t0 + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 4000, SALT_1);
        _revealAfterCommit(v2, MARKET_A, 9000, SALT_2);
        _revealAfterCommit(v3, MARKET_A, 7000, SALT_3);

        vm.warp(t0 + 62 minutes);
        uint256 score = resolver.resolve(MARKET_A, "");
        // Median of equal-weighted [4000, 7000, 9000] = 7000
        assertEq(score, 7000);
    }

    function test_resolve_unrevealedCommitsDoNotCount() public {
        uint256 t0 = block.timestamp;
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);
        _commitAndReveal(v2, MARKET_A, 9000, SALT_2);
        _commitAndReveal(v3, MARKET_A, 0, SALT_3);

        vm.warp(t0 + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 8000, SALT_1);
        _revealAfterCommit(v2, MARKET_A, 9000, SALT_2);

        vm.warp(t0 + 62 minutes);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 8000);
        assertEq(resolver.pendingVotes(v3), 0);
    }

    function test_resolve_anti_copyAttack_demoBenefit() public {
        uint256 t0 = block.timestamp;
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);
        _commitAndReveal(v2, MARKET_A, 7500, SALT_2);

        vm.warp(t0 + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 8000, SALT_1);
        _revealAfterCommit(v2, MARKET_A, 7500, SALT_2);

        vm.warp(t0 + 62 minutes);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 7500);
    }

    /* ---------- subscription carry-over from v0.4 ---------- */

    function test_subscription_accumulates() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.2 ether}();

        assertEq(resolver.earnedSubscription(v1), 0.1 ether);
        assertEq(resolver.earnedSubscription(v2), 0.1 ether);
    }

    /* ---------- voting cap carry-over from v0.4 ---------- */

    function test_votingCap_protectsAgainst55PercentAttack() public {
        uint256 t0 = block.timestamp;
        vm.prank(v1);
        resolver.stake{value: 55 ether}();
        vm.prank(v2);
        resolver.stake{value: 30 ether}();
        vm.prank(v3);
        resolver.stake{value: 15 ether}();

        _commitAndReveal(v1, MARKET_A, 0, SALT_1);
        _commitAndReveal(v2, MARKET_A, 10000, SALT_2);
        _commitAndReveal(v3, MARKET_A, 10000, SALT_3);

        vm.warp(t0 + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 0, SALT_1);
        _revealAfterCommit(v2, MARKET_A, 10000, SALT_2);
        _revealAfterCommit(v3, MARKET_A, 10000, SALT_3);

        vm.warp(t0 + 62 minutes);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 10000);
    }

    /* ---------- pendingVotes blocks unstake (carried) ---------- */

    function test_pendingVotes_onlyIncrementOnReveal() public {
        // v1 commits but doesn't reveal — pendingVotes stays 0
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        _commitAndReveal(v1, MARKET_A, 8000, SALT_1);

        assertEq(resolver.pendingVotes(v1), 0);

        // Now reveal
        vm.warp(block.timestamp + 31 minutes);
        _revealAfterCommit(v1, MARKET_A, 8000, SALT_1);
        assertEq(resolver.pendingVotes(v1), 1);
    }

    /* ---------- computeVoteHash sanity ---------- */

    function test_computeVoteHash_differsBySenderAndMarket() public view {
        bytes32 h1 = resolver.computeVoteHash(8000, SALT_1, MARKET_A, v1);
        bytes32 h2 = resolver.computeVoteHash(8000, SALT_1, MARKET_A, v2);
        bytes32 h3 = resolver.computeVoteHash(8000, SALT_1, MARKET_B, v1);
        assertTrue(h1 != h2);
        assertTrue(h1 != h3);
    }
}
