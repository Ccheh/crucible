// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {TestcaseResolverV4} from "../src/v04/TestcaseResolverV4.sol";

/// @title TestcaseResolverV4 — subscription + voting cap + ERC-8004 events
contract TestcaseResolverV4Test is Test {
    TestcaseResolverV4 resolver;

    address v1 = makeAddr("v1");
    address v2 = makeAddr("v2");
    address v3 = makeAddr("v3");
    address v4 = makeAddr("v4");
    address v5 = makeAddr("v5");
    address feePayer = makeAddr("feePayer");

    bytes32 constant MARKET_A = bytes32(uint256(1));
    bytes32 constant MARKET_B = bytes32(uint256(2));

    function setUp() public {
        resolver = new TestcaseResolverV4();
        vm.deal(v1, 100 ether);
        vm.deal(v2, 100 ether);
        vm.deal(v3, 100 ether);
        vm.deal(v4, 100 ether);
        vm.deal(v5, 100 ether);
        vm.deal(feePayer, 100 ether);
        vm.warp(1_000_000);
    }

    function test_name_returnsV4() public view {
        assertEq(resolver.name(), "TestcaseResolverV4");
    }

    /* ---------- subscription accumulator: simple cases ---------- */

    function test_subscription_singleValidator_getsFullAmount() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();

        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.1 ether}();

        assertEq(resolver.earnedSubscription(v1), 0.1 ether);
    }

    function test_subscription_twoEqualValidators_splitEqual() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.2 ether}();

        assertEq(resolver.earnedSubscription(v1), 0.1 ether);
        assertEq(resolver.earnedSubscription(v2), 0.1 ether);
    }

    function test_subscription_unequalStake_proportional() public {
        // v1 stakes 3, v2 stakes 1. Pool of 0.4 ether → v1 gets 0.3, v2 gets 0.1.
        vm.prank(v1);
        resolver.stake{value: 3 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.4 ether}();

        assertEq(resolver.earnedSubscription(v1), 0.3 ether);
        assertEq(resolver.earnedSubscription(v2), 0.1 ether);
    }

    function test_subscription_lateJoinerDoesNotGetPriorRewards() public {
        // v1 stakes first; subscription arrives; v2 joins after; v2 earns nothing for prior pool.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.1 ether}();

        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        // v2 should have 0 earned (their debt is set at current accumulator value).
        assertEq(resolver.earnedSubscription(v2), 0);
        // v1 still has the full 0.1.
        assertEq(resolver.earnedSubscription(v1), 0.1 ether);

        // Now another subscription comes in — both split it.
        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.2 ether}();

        assertEq(resolver.earnedSubscription(v1), 0.1 ether + 0.1 ether);
        assertEq(resolver.earnedSubscription(v2), 0.1 ether);
    }

    function test_subscription_claimAndZero() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.1 ether}();

        uint256 before = v1.balance;
        vm.prank(v1);
        uint256 amt = resolver.claimSubscription();
        assertEq(amt, 0.1 ether);
        assertEq(v1.balance, before + 0.1 ether);
        assertEq(resolver.earnedSubscription(v1), 0);
    }

    function test_subscription_claimZeroReverts() public {
        vm.prank(v1);
        vm.expectRevert(TestcaseResolverV4.ZeroAmount.selector);
        resolver.claimSubscription();
    }

    function test_subscription_zeroTotalStake_held() public {
        // No validators staked. Subscription arrives — accumulator does not
        // change, but value sits in contract. (Edge case.)
        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.1 ether}();
        assertEq(address(resolver).balance, 0.1 ether);
        assertEq(resolver.accSubscriptionPerStake(), 0);
    }

    /* ---------- voting weight cap ---------- */

    function test_votingCap_capsLargeStake() public {
        // v1 stakes 6 (60%), v2 stakes 2, v3 stakes 2. Total 10.
        // Effective cap = 10 * 40% = 4. v1's effective vote weight = 4 (not 6).
        // Votes: v1=0, v2=10000, v3=10000.
        // Capped sorted: [0 (4), 10000 (2), 10000 (2)], cum [4, 6, 8].
        // Total cappedWeight = 8. Threshold = 4. First idx with cum >= 4 is idx 0 → 0.
        // BUT WAIT: under v0.3 mean would be (0*6+10000*4)/10=4000. v0.3 median = 0.
        // Under v0.4 with cap → median should be ... let me trace again.
        // cappedStakes: v1=4, v2=2, v3=2. totalWeight = 8.
        // Sorted by vote ascending: [0 (4), 10000 (2), 10000 (2)]
        // cumulative: [4, 6, 8]. threshold = 8/2 = 4. cum[0] = 4 >= 4 → median = 0.
        // Hmm same answer. Need a test where the cap actually changes the outcome.

        // Better test: v1 stakes 10 (>50%), v2 stakes 5, v3 stakes 5.
        // Without cap: v1 = 10/20 = 50% — borderline.
        // Votes: v1=10000, v2=0, v3=0.
        // Without cap (v0.3): sorted [0 (5), 0 (5), 10000 (10)] cum [5, 10, 20], threshold=10
        //   cum[0]=5 < 10, cum[1]=10 >= 10 → median = 0
        // With cap (v0.4): v1 capped at 20*0.4=8. sorted [0 (5), 0 (5), 10000 (8)] cum [5,10,18], threshold=9
        //   cum[0]=5 < 9, cum[1]=10 >= 9 → median = 0
        // Same result.

        // Strongest test: v1 stakes massively, votes against everyone.
        // v1 stakes 100, v2 stakes 1, v3 stakes 1. Total 102.
        // v1 votes 0, v2 votes 10000, v3 votes 10000.
        // Without cap: sorted [0 (100), 10000 (1), 10000 (1)] cum [100,101,102], threshold=51
        //   cum[0]=100 >= 51 → median = 0   (v1 dominates)
        // With cap (40%): v1 effective = 102*0.4 = 40.8 → 40 (int)
        //   sorted [0 (40), 10000 (1), 10000 (1)] cum [40, 41, 42], threshold = 42/2 = 21
        //   cum[0]=40 >= 21 → median still 0.
        // Hmm! Because v1 still has 40/42 = 95% of CAPPED weight. Cap doesn't help here.

        // I think the cap is only effective when other validators have more total stake
        // than the cap allows. Let me reconsider.
        // The cap is computed FROM total voter stake. If v1 has 95% of stake, v1 still
        // dominates capped weight too.

        // The cap only helps if the OTHER voters can collectively outvote the capped one.
        // For that, we need other voters' total stake to be > capped weight.
        // capped weight = totalVoterStake * 40% = ~40
        // So need other voters' stake > 40, i.e., other voters > 40% of total.
        // If v1 is 60%, others are 40% combined → equal weight; cap helps decide.
        // If v1 is 95%, others are 5% → cap can't help even when applied.

        // OK proper test: v1 = 60%, others = 40%.
        // v1 stakes 6, v2 stakes 2, v3 stakes 2. Total = 10.
        // v1 votes 0 (bad), v2 votes 10000 (good), v3 votes 10000 (good).
        // Without cap: sorted [0 (6), 10000 (2), 10000 (2)] cum [6,8,10], threshold=5
        //   cum[0]=6 >= 5 → median = 0. v1 wins.
        // With cap (40%): v1 effective = 10*0.4 = 4. v2,v3 unchanged (2 each).
        //   sorted [0 (4), 10000 (2), 10000 (2)] cum [4, 6, 8], threshold=4
        //   cum[0]=4 >= 4 → median = 0. Still v1 wins?!
        //
        // Hmm the issue is my threshold is >= 50%, not strictly >. Let me think.
        // Stake-weighted median: smallest v such that cumulative <= v is >= 50%.
        // cum[0] = 4. totalWeight = 8. threshold = 4. cum[0] >= 4 → return idx 0.
        // But intuitively, with capped weights 4/2/2, the v1 vote represents 50% of weight.
        // The median should be at the boundary — could be 0 or 10000.

        // Actually with EVEN total weight (8) and ONE voter at exactly 50%, it's a tie.
        // The median convention I'm using picks the LOWER value at the tie boundary.

        // For a more decisive test, make v1 just under 50%.
        // v1 stakes 4, v2 stakes 3, v3 stakes 3. Total = 10.
        // Without cap: v1 has 40% of stake.
        // v1 votes 0, v2 votes 10000, v3 votes 10000.
        // sorted [0 (4), 10000 (3), 10000 (3)] cum [4, 7, 10] threshold=5
        // cum[0]=4 < 5, cum[1]=7 >= 5 → median = 10000. v2/v3 win.
        // Cap doesn't change this because v1 is already at 40%.

        // The cap PROTECTS when v1 would otherwise be 50-70%. Below 40% no effect, above 50%
        // capped to 40% which makes others' votes count comparably.

        // FINAL useful test: v1 stakes 55%, others 45% combined.
        // v1 stakes 55, v2 stakes 30, v3 stakes 15. Total = 100. v1=55%, v2=30%, v3=15%.
        // v1 votes 0, v2 votes 10000, v3 votes 10000.
        // Without cap: sorted [0 (55), 10000 (30), 10000 (15)] cum [55, 85, 100] threshold=50
        //   cum[0]=55 >= 50 → median = 0. v1 wins via majority.
        // With cap (40% of 100 = 40): v1 → 40, v2=30, v3=15. totalWeight=85.
        //   sorted [0 (40), 10000 (30), 10000 (15)] cum [40, 70, 85] threshold=85/2=42
        //   cum[0]=40 < 42, cum[1]=70 >= 42 → median = 10000. v2/v3 win.

        vm.prank(v1);
        resolver.stake{value: 55 ether}();
        vm.prank(v2);
        resolver.stake{value: 30 ether}();
        vm.prank(v3);
        resolver.stake{value: 15 ether}();

        vm.prank(v1); resolver.vote(MARKET_A, 0);
        vm.prank(v2); resolver.vote(MARKET_A, 10000);
        vm.prank(v3); resolver.vote(MARKET_A, 10000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        assertEq(score, 10000, "Cap should prevent 55% stake from controlling consensus");
    }

    function test_votingCap_doesNotAffectUncappedScenarios() public {
        // Equal stakes, no one near 40% individually.
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();
        vm.prank(v3);
        resolver.stake{value: 1 ether}();

        vm.prank(v1); resolver.vote(MARKET_A, 4000);
        vm.prank(v2); resolver.vote(MARKET_A, 7000);
        vm.prank(v3); resolver.vote(MARKET_A, 9000);

        vm.warp(block.timestamp + 1 hours + 1);
        uint256 score = resolver.resolve(MARKET_A, "");
        // Each has 33% (< 40% cap), so cap is a no-op. Same as v0.3 median: 7000.
        assertEq(score, 7000);
    }

    /* ---------- ERC-8004 reputation event ---------- */

    function test_reputation_eventEmittedForHonestVoter() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v2);
        resolver.stake{value: 1 ether}();

        vm.prank(v1); resolver.vote(MARKET_A, 8000);
        vm.prank(v2); resolver.vote(MARKET_A, 8500);
        vm.warp(block.timestamp + 1 hours + 1);

        // Expect ValidatorReputation events for both voters
        vm.expectEmit(true, true, false, false);
        emit TestcaseResolverV4.ValidatorReputation(v1, MARKET_A, 8000, 0, 0, true);
        vm.expectEmit(true, true, false, false);
        emit TestcaseResolverV4.ValidatorReputation(v2, MARKET_A, 8500, 0, 0, true);
        // Don't check exact deviation / slashed values, just that the event fires.
        resolver.resolve(MARKET_A, "");
    }

    /* ---------- slashing settles subscription correctly ---------- */

    function test_slash_settlesSubscriptionBeforeStakeReduction() public {
        // v1, v2, v3, v4, v5: 4 honest at 9000, 1 outlier at 0.
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

        // Subscription arrives — each accrues 0.02
        vm.prank(feePayer);
        resolver.notifyValidatorSubscription{value: 0.1 ether}();
        assertEq(resolver.earnedSubscription(v5), 0.02 ether);

        vm.prank(v1); resolver.vote(MARKET_A, 9000);
        vm.prank(v2); resolver.vote(MARKET_A, 9000);
        vm.prank(v3); resolver.vote(MARKET_A, 9000);
        vm.prank(v4); resolver.vote(MARKET_A, 9000);
        vm.prank(v5); resolver.vote(MARKET_A, 0);

        vm.warp(block.timestamp + 1 hours + 1);
        resolver.resolve(MARKET_A, "");

        // v5 had 0.02 earned BEFORE the slash. After resolve, the slash
        // settles their accumulator (so 0.02 is preserved as pendingReward).
        // Their stake is reduced but they didn't lose their pre-slash sub.
        assertEq(resolver.pendingSubscriptionReward(v5), 0.02 ether);
        assertLt(resolver.validatorStake(v5), 1 ether);
    }

    /* ---------- IResolver compliance (sanity carrying from v0.3) ---------- */

    function test_resolve_singleVoter() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 7500);
        vm.warp(block.timestamp + 1 hours + 1);
        assertEq(resolver.resolve(MARKET_A, ""), 7500);
    }

    function test_pendingVotes_blocksUnstake() public {
        vm.prank(v1);
        resolver.stake{value: 1 ether}();
        vm.prank(v1);
        resolver.vote(MARKET_A, 8000);
        vm.prank(v1);
        resolver.requestUnstake(0.5 ether);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(TestcaseResolverV4.PendingVotes.selector, 1));
        resolver.completeUnstake();
    }
}
