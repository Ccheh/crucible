// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestcaseResolverV3} from "../src/v03/TestcaseResolverV3.sol";

/// @title TestcaseResolverV3 — stake-weighted MEDIAN consensus tests
contract TestcaseResolverV3Test is Test {
    TestcaseResolverV3 resolver;

    address v1 = makeAddr("v1");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");
    address v4 = makeAddr("v4");
    address v5 = makeAddr("v5");

    bytes32 constant MARKET_A = bytes32(uint256(1));
    bytes32 constant MARKET_B = bytes32(uint256(2));

    function setUp() public {
        resolver = new TestcaseResolverV3();
        vm.deal(v1, 100 ether);
        vm.deal(v2, 100 ether);
        vm.deal(v3, 100 ether);
        vm.deal(v4, 100 ether);
        vm.deal(v5, 100 ether);
        vm.warp(1_000_000);
    }

    /* ---------- sanity ---------- */

    function test_name_returnsV3() public view {
        assertEq(resolver.name(), "TestcaseResolverV3");
    }

    /* ---------- median: simple cases ---------- */

    function test_median_singleVoter() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7500);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 7500);
    }

    function test_median_threeEqualStake() public {
        // Equal-stake, sorted votes [4000, 7000, 9000].
        // Median is the middle value → 7000 (mean would also be ~6666).
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 4000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 7000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 7000);
    }

    /* ---------- median: the key property ---------- */
    /// @notice This is the test that justifies v0.3 over v0.2.
    ///         A minority outlier voting an extreme value DOES NOT drag the
    ///         consensus, regardless of their stake (so long as their stake
    ///         is less than majority).
    function test_median_outlierDoesNotDragConsensus_v2WouldFail() public {
        // 5 validators, 4 vote 9000, 1 votes 0. Equal stake.
        // mean (v0.2)   = (9000*4 + 0*1) / 5 = 7200
        // median (v0.3) = sorted [0, 9000, 9000, 9000, 9000], cum [1,2,3,4,5],
        //                  threshold = 5/2 = 2 (integer); first cum >= 2 is at idx 1 → 9000.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();
        vm.prank(v4);
        resolver.stake{value: 1 ether}();
        vm.prank(v5);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v4);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v5);
        resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // Median should be 9000 (much better than mean = 7200).
        assertEq(score, 9000);
    }

    function test_median_stakeWeightedButNotMean() public {
        // v1 stake 4, v2 stake 3, v3 stake 3 (no single majority).
        // Votes: v1=10000, v2=9000, v3=0.
        // mean   = (10000*4 + 9000*3 + 0*3) / 10 = 67000/10 = 6700
        // median = sorted [0 (3), 9000 (3), 10000 (4)], cum [3, 6, 10]
        //                  threshold = 10/2 = 5; first cum >= 5 is at idx 1 → 9000
        vm.prank(v1);
        resolver.stake{value: 4 ether}();
        vm.prank(v2);
        resolver.stake{value: 3 ether}();
        vm.prank(v3);
        resolver.stake{value: 3 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 10000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 9000);
    }

    function test_median_majorityStakeWins() public {
        // If a single validator has >50% stake, the median follows them.
        // This is intentional — majority-stake control is unrecoverable on
        // any one-shot mechanism (and v0.3 doesn't pretend otherwise).
        vm.prank(v1);
        resolver.stake{value: 6 ether}();    // 60%
        vm.prank(v2);
        resolver.stake{value: 2 ether}();    // 20%
        vm.prank(v3);
        resolver.stake{value: 2 ether}();    // 20%

        vm.prank(v1);
        resolver.vote(MARKET_A, 0);
        vm.prank(v2);
        resolver.vote(MARKET_A, 10000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 10000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // Sorted [0 (6), 10000 (2), 10000 (2)], cum [6, 8, 10]
        // threshold = 10/2 = 5; first cum >= 5 is at idx 0 → 0
        assertEq(score, 0);
    }

    /* ---------- slashing on outliers ---------- */

    function test_slash_outlierFarFromMedian() public {
        // 4 validators vote 9000 (equal stake), 1 votes 0.
        // Median = 9000. Outlier distance = 9000.
        // excess = 9000 - 1500 = 7500. slashBps = 7500*1000/8500 = 882. < cap 1000.
        // slashAmt = 1 ether * 882 / 10000 = 0.0882 ether.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();
        vm.prank(v4);
        resolver.stake{value: 1 ether}();
        vm.prank(v5);
        resolver.stake{value: 1 ether}();

        vm.prank(v1); resolver.vote(MARKET_A, 9000);
        vm.prank(v2); resolver.vote(MARKET_A, 9000);
        vm.prank(v3); resolver.vote(MARKET_A, 9000);
        vm.prank(v4); resolver.vote(MARKET_A, 9000);
        vm.prank(v5); resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        // v1-v4 unchanged
        assertEq(resolver.validatorStake(v1), 1 ether);
        // v5 slashed
        uint256 expectedSlash = (1 ether * 882) / 10000;
        assertApproxEqAbs(resolver.validatorStake(v5), 1 ether - expectedSlash, 1);
    }

    /* ---------- fee distribution ---------- */

    function test_resolve_distributesFeeToHonest() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        address feePayer = makeAddr("feePayer");
        vm.deal(feePayer, 1 ether);
        vm.prank(feePayer);
        resolver.notifyFee{value: 0.3 ether}(MARKET_A);

        vm.prank(v1); resolver.vote(MARKET_A, 8000);
        vm.prank(v2); resolver.vote(MARKET_A, 8000);
        vm.prank(v3); resolver.vote(MARKET_A, 8000);
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        // All equidistant to median (= 8000). All honest. Equal rewards.
        assertEq(resolver.pendingReward(v1), 0.1 ether);
        assertEq(resolver.pendingReward(v2), 0.1 ether);
        assertEq(resolver.pendingReward(v3), 0.1 ether);
    }

    /* ---------- pendingVotes guard (carried from v0.2) ---------- */

    function test_completeUnstake_blockedByPendingVotes() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);
        vm.warp(block.timestamp + 7 days + 1);

        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(TestcaseResolverV3.PendingVotes.selector, 1));
        resolver.completeUnstake();
    }

    function test_completeUnstake_allowedAfterResolved() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);

        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        vm.warp(block.timestamp + 7 days);
        uint256 before = v1.balance;
        vm.prank(v1);
        resolver.completeUnstake();
        assertEq(v1.balance, before + 0.5 ether);
    }

    /* ---------- claimRewards ---------- */

    function test_claimRewards_withdrawsBalance() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        address feePayer = makeAddr("feePayer");
        vm.deal(feePayer, 1 ether);
        vm.prank(feePayer);
        resolver.notifyFee{value: 0.3 ether}(MARKET_A);

        vm.prank(v1); resolver.vote(MARKET_A, 8000);
        vm.prank(v2); resolver.vote(MARKET_A, 8000);
        vm.prank(v3); resolver.vote(MARKET_A, 8000);
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        uint256 before = v1.balance;
        vm.prank(v1);
        uint256 claimed = resolver.claimRewards();
        assertEq(claimed, 0.1 ether);
        assertEq(v1.balance, before + 0.1 ether);
        assertEq(resolver.pendingReward(v1), 0);
    }
}
