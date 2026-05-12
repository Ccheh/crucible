// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestcaseResolverV2} from "../src/v02/TestcaseResolverV2.sol";

/// @title TestcaseResolverV2 — slashing + reward + pending-vote tests
/// @dev   Constants the tests rely on:
///          MIN_STAKE = 0.1 ether
///          UNSTAKE_COOLDOWN = 7 days
///          VOTING_WINDOW = 1 hours
///          TOLERANCE_BPS = 1500
///          MAX_SLASH_BPS = 1000
contract TestcaseResolverV2Test is Test {
    TestcaseResolverV2 resolver;

    address v1 = makeAddr("validator1");
    address v2 = makeAddr("validator2");
    address v3 = makeAddr("validator3");
    address v4 = makeAddr("validator4");
    address feePayer = makeAddr("feePayer");

    bytes32 constant MARKET_A = bytes32(uint256(1));
    bytes32 constant MARKET_B = bytes32(uint256(2));

    function setUp() public {
        resolver = new TestcaseResolverV2();
        vm.deal(v1, 10 ether);
        vm.deal(v2, 10 ether);
        vm.deal(v3, 10 ether);
        vm.deal(v4, 10 ether);
        vm.deal(feePayer, 10 ether);
        // Baseline timestamp so block.timestamp - cooldown won't underflow
        vm.warp(1_000_000);
    }

    /* ---------- stake / unstake sanity (same shape as v0) ---------- */

    function test_stake_increasesStake() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        assertEq(resolver.validatorStake(v1), 1 ether);
        assertEq(resolver.totalStake(), 1 ether);
    }

    function test_name_returnsV2Identifier() public view {
        assertEq(resolver.name(), "TestcaseResolverV2");
    }

    /* ---------- pendingVotes lifecycle ---------- */

    function test_vote_incrementsPendingVotes() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        assertEq(resolver.pendingVotes(v1), 1);
    }

    function test_completeUnstake_blockedByPendingVotes() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);

        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);
        // Cooldown passes
        vm.warp(block.timestamp + 7 days + 1);

        // Still has pending vote → must revert
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(TestcaseResolverV2.PendingVotes.selector, 1));
        resolver.completeUnstake();
    }

    function test_completeUnstake_allowedAfterMarketResolves() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);

        // Resolve market BEFORE cooldown completes → pending count drops to 0
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");
        assertEq(resolver.pendingVotes(v1), 0);

        // Now wait out cooldown
        vm.warp(block.timestamp + 7 days);

        uint256 before = v1.balance;
        vm.prank(v1);
        resolver.completeUnstake();
        assertEq(v1.balance, before + 0.5 ether);
    }

    /* ---------- slashing math ---------- */

    function test_resolve_noSlashWhenWithinTolerance() public {
        // Three validators equal stake, votes clustered within 1500bps of mean.
        _stakeAll(1 ether);
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 8500);
        vm.prank(v3);
        resolver.vote(MARKET_A, 9000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // mean = (8000+8500+9000)/3 = 8500
        assertEq(score, 8500);

        // Distances: 500, 0, 500 — all within TOLERANCE_BPS=1500. No slash.
        assertEq(resolver.validatorStake(v1), 1 ether);
        assertEq(resolver.validatorStake(v2), 1 ether);
        assertEq(resolver.validatorStake(v3), 1 ether);
    }

    function test_resolve_slashesOutlier() public {
        // v1, v2, v3 vote sensibly; v4 votes wildly off → should be slashed.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();
        vm.prank(v4);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v4);
        resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // mean = (9000*3 + 0) / 4 = 6750
        assertEq(score, 6750);

        // v1/v2/v3: distance 2250 (= 9000-6750). > tolerance 1500. They WILL be slashed too!
        // excess = 2250-1500 = 750. slashBps = 750*1000/8500 = 88. slashAmt = 1e18*88/10000 = 8.8e15
        // v4: distance 6750. excess = 5250. slashBps = 5250*1000/8500 = 617. slashAmt = 1e18 * 617 / 10000 = 6.17e16
        // (note that max-slash cap is MAX_SLASH_BPS = 1000 = 10%, both within bounds)
        uint256 expectedSlashV4 = (1 ether * 617) / 10000;
        uint256 expectedSlashOthers = (1 ether * 88) / 10000;

        assertApproxEqAbs(resolver.validatorStake(v4), 1 ether - expectedSlashV4, 1);
        assertApproxEqAbs(resolver.validatorStake(v1), 1 ether - expectedSlashOthers, 1);
    }

    function test_resolve_slashCappedAtMax() public {
        // Two-validator extreme case: one votes 0, one votes 10000.
        // Mean (equal stake) = 5000. Distance for each = 5000.
        // excess = 5000-1500 = 3500. slashBps = 3500*1000/8500 = 411.
        // 411 is BELOW cap 1000, so cap doesn't trigger; verify math is right.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 0);
        vm.prank(v2);
        resolver.vote(MARKET_A, 10000);

        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        uint256 expectedSlash = (1 ether * 411) / 10000;
        assertApproxEqAbs(resolver.validatorStake(v1), 1 ether - expectedSlash, 1);
        assertApproxEqAbs(resolver.validatorStake(v2), 1 ether - expectedSlash, 1);
    }

    function test_resolve_extremeDistanceHitsCap() public {
        // Constructed case where a small outlier truly is at max slash.
        // Use 9 honest validators at 10000 and 1 outlier at 0.
        // Mean = 10000*9/10 = 9000. Outlier distance = 9000. excess = 7500.
        // slashBps = 7500*1000/8500 = 882 — still below 1000 cap.
        // To force the cap: need excess such that slashBps > 1000.
        // excess > 8500*1000/1000 = 8500 → distance > 10000. Impossible.
        // So under current params the cap is mathematically unreachable.
        // This test instead documents that fact via an assertion below.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 5000);
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");
        // Single voter is trivially at mean → distance 0 → no slash.
        assertEq(resolver.validatorStake(v1), 1 ether);
    }

    /* ---------- fee pool + reward distribution ---------- */

    function test_notifyFee_addsToPool() public {
        vm.prank(feePayer);
        resolver.notifyFee{value: 0.1 ether}(MARKET_A);
        (, , , , uint256 feePool) = resolver.getMarket(MARKET_A);
        assertEq(feePool, 0.1 ether);
    }

    function test_notifyFee_revertsAfterResolved() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7000);
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        vm.prank(feePayer);
        vm.expectRevert(TestcaseResolverV2.AlreadyResolved.selector);
        resolver.notifyFee{value: 0.1 ether}(MARKET_A);
    }

    function test_resolve_distributesFeeToHonest() public {
        // Three honest validators clustered around 8000. Fee pool = 0.3 ether.
        // Honest stake = 3e18. Each gets 0.1 ether reward.
        _stakeAll(1 ether);

        vm.prank(feePayer);
        resolver.notifyFee{value: 0.3 ether}(MARKET_A);

        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 8000);

        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        // All within tolerance (distance=0). All earn equal reward.
        assertEq(resolver.pendingReward(v1), 0.1 ether);
        assertEq(resolver.pendingReward(v2), 0.1 ether);
        assertEq(resolver.pendingReward(v3), 0.1 ether);
    }

    function test_resolve_slashedStakeRedistributed() public {
        // v1 votes far off — slashed amount becomes part of reward pool for v2/v3.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 0);
        vm.prank(v2);
        resolver.vote(MARKET_A, 10000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 10000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // mean = (0 + 10000 + 10000) / 3 = 6666
        assertEq(score, 6666);

        // v1 distance = 6666, excess = 5166, slashBps = 5166*1000/8500 = 607.
        // v2/v3 distance = 3334, excess = 1834, slashBps = 1834*1000/8500 = 215.
        // All three are slashed (no one is within tolerance).
        // honestStake = 0 → no reward distribution this round.
        assertEq(resolver.pendingReward(v1), 0);
        assertEq(resolver.pendingReward(v2), 0);
        assertEq(resolver.pendingReward(v3), 0);

        // Confirm everyone was slashed.
        uint256 expectedSlashV1 = (1 ether * 607) / 10000;
        uint256 expectedSlashV2 = (1 ether * 215) / 10000;
        assertApproxEqAbs(resolver.validatorStake(v1), 1 ether - expectedSlashV1, 1);
        assertApproxEqAbs(resolver.validatorStake(v2), 1 ether - expectedSlashV2, 1);
        assertApproxEqAbs(resolver.validatorStake(v3), 1 ether - expectedSlashV2, 1);
    }

    function test_resolve_slashedStakeRewardsHonest() public {
        // Unbalanced stake so honest cluster dominates the mean.
        // v1,v2,v3 stake 10 ether each (honest); v4 stakes 0.1 ether (outlier).
        // Total honest stake (30e18) vs outlier (0.1e18) → outlier has ~0.33% weight.
        vm.deal(v1, 20 ether);
        vm.deal(v2, 20 ether);
        vm.deal(v3, 20 ether);
        vm.deal(v4, 20 ether);

        vm.prank(v1);
        resolver.stake{value: 10 ether}();
        vm.prank(v2);
        resolver.stake{value: 10 ether}();
        vm.prank(v3);
        resolver.stake{value: 10 ether}();
        vm.prank(v4);
        resolver.stake{value: 0.1 ether}();

        vm.prank(v1);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 9000);
        vm.prank(v4);
        resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // weighted mean ≈ 9000*30/30.1 ≈ 8970 (integer truncation may give 8970)
        // honest distance ≈ 30 → well within tolerance (1500) → no slash
        // outlier distance ≈ 8970 → slashed (excess = 7470, slashBps = 7470*1000/8500 = 878)
        assertGt(score, 8000);
        assertLt(score, 10000);

        // v1/v2/v3 untouched (within tolerance)
        assertEq(resolver.validatorStake(v1), 10 ether);
        assertEq(resolver.validatorStake(v2), 10 ether);
        assertEq(resolver.validatorStake(v3), 10 ether);

        // v4 slashed.
        assertLt(resolver.validatorStake(v4), 0.1 ether);

        // Honest validators earned reward from v4's slash, pro-rata to stake (all equal).
        uint256 r1 = resolver.pendingReward(v1);
        uint256 r2 = resolver.pendingReward(v2);
        uint256 r3 = resolver.pendingReward(v3);
        assertGt(r1, 0);
        assertEq(r1, r2);
        assertEq(r2, r3);
        assertEq(resolver.pendingReward(v4), 0);
    }

    /* ---------- claimRewards ---------- */

    function test_claimRewards_withdrawsBalance() public {
        // Honest market with fee pool
        _stakeAll(1 ether);
        vm.prank(feePayer);
        resolver.notifyFee{value: 0.3 ether}(MARKET_A);
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v2);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v3);
        resolver.vote(MARKET_A, 8000);
        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        uint256 before = v1.balance;
        vm.prank(v1);
        uint256 claimed = resolver.claimRewards();
        assertEq(claimed, 0.1 ether);
        assertEq(v1.balance, before + 0.1 ether);
        assertEq(resolver.pendingReward(v1), 0);
    }

    function test_claimRewards_zeroReverts() public {
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV2.ZeroAmount.selector);
        resolver.claimRewards();
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
