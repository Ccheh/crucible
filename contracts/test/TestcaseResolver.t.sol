// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestcaseResolver} from "../src/resolvers/TestcaseResolver.sol";

contract TestcaseResolverTest is Test {
    TestcaseResolver resolver;

    address v1 = makeAddr("validator1");
    address v2 = makeAddr("validator2");
    address v3 = makeAddr("validator3");
    address spammer = makeAddr("spammer");

    bytes32 constant MARKET_A = bytes32(uint256(1));
    bytes32 constant MARKET_B = bytes32(uint256(2));

    function setUp() public {
        resolver = new TestcaseResolver();
        vm.deal(v1, 10 ether);
        vm.deal(v2, 10 ether);
        vm.deal(v3, 10 ether);
        vm.deal(spammer, 10 ether);
    }

    /* ---------- stake / unstake lifecycle ---------- */

    function test_stake_increasesStake() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        assertEq(resolver.validatorStake(v1), 1 ether);
        assertEq(resolver.totalStake(), 1 ether);
    }

    function test_stake_zeroReverts() public {
        vm.prank(v1);
        vm.expectRevert(TestcaseResolver.ZeroAmount.selector);
        resolver.stake();
    }

    function test_unstake_requiresCooldown() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);

        // Immediately try -- should revert
        vm.prank(v1);
        vm.expectRevert(TestcaseResolver.NotReady.selector);
        resolver.completeUnstake();

        // After cooldown -- works
        vm.warp(block.timestamp + 7 days + 1);
        uint256 before = v1.balance;
        vm.prank(v1);
        resolver.completeUnstake();
        assertEq(v1.balance, before + 0.5 ether);
        assertEq(resolver.validatorStake(v1), 0.5 ether);
    }

    function test_stake_blockedWhilePendingUnstake() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);

        // Try to top up while unstake pending
        vm.prank(v1);
        vm.expectRevert(TestcaseResolver.PendingUnstake.selector);
        resolver.stake{value: 1 ether}();
    }

    /* ---------- vote validation ---------- */

    function test_vote_belowMinStakeReverts() public {
        // Spammer stakes only 0.01 (below MIN_STAKE of 0.1)
        vm.prank(spammer);
        resolver.stake{value: 0.01 ether}();

        vm.prank(spammer);
        vm.expectRevert(TestcaseResolver.InsufficientStake.selector);
        resolver.vote(MARKET_A, 8000);
    }

    function test_vote_scoreOutOfRangeReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        vm.expectRevert(TestcaseResolver.ScoreOutOfRange.selector);
        resolver.vote(MARKET_A, 10001);
    }

    function test_vote_doubleVoteReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);

        vm.prank(v1);
        vm.expectRevert(TestcaseResolver.AlreadyVoted.selector);
        resolver.vote(MARKET_A, 5000);
    }

    function test_vote_pastWindowReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);

        // Warp past the window
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        vm.expectRevert(TestcaseResolver.WindowClosed.selector);
        resolver.vote(MARKET_A, 5000);
    }

    /* ---------- resolve: simple cases ---------- */

    function test_resolve_singleVoter() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7500);

        // Before window closes -- canResolve = false
        assertFalse(resolver.canResolve(MARKET_A));

        vm.warp(block.timestamp + 1 hours + 1);
        assertTrue(resolver.canResolve(MARKET_A));

        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 7500);
    }

    function test_resolve_threeValidatorsEqualStake() public {
        _stakeAll(1 ether);

        vm.prank(v1);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 7000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // weighted average: (9000+8000+7000)/3 = 8000
        assertEq(score, 8000);
    }

    function test_resolve_stakeWeighted() public {
        // v1 has 5x the stake of v2 and v3
        vm.prank(v1);
        resolver.stake{value: 5 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 10000);  // v1 says perfect
        vm.prank(v2);
        resolver.vote(MARKET_A, 0);
        vm.prank(v3);
        resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // weighted: (10000*5 + 0*1 + 0*1) / 7 = 50000/7 = 7142 (integer truncate)
        assertEq(score, 7142);
    }

    function test_resolve_revertsBeforeWindowExpiry() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7500);

        vm.expectRevert(TestcaseResolver.WindowClosed.selector);
        resolver.resolve(MARKET_A, "");
    }

    function test_resolve_revertsWhenNoVotes() public {
        // No votes on MARKET_B
        vm.expectRevert(TestcaseResolver.WindowClosed.selector);
        resolver.resolve(MARKET_B, "");
    }

    function test_resolve_doubleResolveReverts() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7500);
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        vm.expectRevert(TestcaseResolver.AlreadyResolved.selector);
        resolver.resolve(MARKET_A, "");
    }

    /* ---------- views ---------- */

    function test_getMarket_returnsCorrectFields() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7500);

        (uint64 deadline, uint16 score, bool resolved, uint256 voterCount) = resolver.getMarket(MARKET_A);
        assertEq(uint256(deadline), block.timestamp + 1 hours);
        assertEq(score, 0);
        assertFalse(resolved);
        assertEq(voterCount, 1);

        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        (, score, resolved, voterCount) = resolver.getMarket(MARKET_A);
        assertEq(score, 7500);
        assertTrue(resolved);
        assertEq(voterCount, 1);
    }

    function test_getVoters_returnsAllVoters() public {
        _stakeAll(1 ether);
        vm.prank(v1);
        resolver.vote(MARKET_A, 5000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 6000);

        address[] memory voters = resolver.getVoters(MARKET_A);
        assertEq(voters.length, 2);
        assertEq(voters[0], v1);
        assertEq(voters[1], v2);
    }

    /* ---------- canResolve / IResolver compliance ---------- */

    function test_name_returnsCorrectIdentifier() public view {
        assertEq(resolver.name(), "TestcaseResolver-v0");
    }

    /* ---------- helpers ---------- */

    function _stakeAll(uint256 amount) internal {
        vm.prank(v1);
        resolver.stake{value: amount}();
        vm.prank(v2);
        resolver.stake{value: amount}();
        vm.prank(v3);
        resolver.stake{value: amount}();
    }
}
