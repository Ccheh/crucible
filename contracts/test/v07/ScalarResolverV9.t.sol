// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ScalarResolverV9} from "../../src/v07/ScalarResolverV9.sol";

/// @title ScalarResolverV9 — calibration-weighted consensus
/// @dev   The test contract is AUTHORIZED_MARKET (opens voting via onDispute).
///        HONEST framing: calibration is a *bounded* tilt (0.25x–1.5x) that
///        makes earned accuracy decide outcomes among comparable-stake
///        validators and makes fresh capital worth less per unit. It is NOT a
///        standalone whale defense — a supermajority whale is still bounded by
///        the 40% vote cap + a distributed validator set, not by calibration.
contract ScalarResolverV9Test is Test {
    ScalarResolverV9 resolver;

    address Hh1 = makeAddr("Hh1"); // become proven (high-calibration)
    address Hh2 = makeAddr("Hh2");
    address L1  = makeAddr("L1");  // stay fresh (low-calibration)
    address L2  = makeAddr("L2");

    function setUp() public {
        resolver = new ScalarResolverV9(0.1 ether, address(this), address(0));
        vm.deal(Hh1, 1000 ether);
        vm.deal(Hh2, 1000 ether);
        vm.deal(L1, 1000 ether);
        vm.deal(L2, 1000 ether);
        vm.warp(1_000_000);
    }

    function _stake(address who, uint256 amt) internal { vm.prank(who); resolver.stake{value: amt}(); }

    function _cycle(bytes32 mkt, address[] memory voters, uint16[] memory scores) internal returns (uint256) {
        resolver.onDispute(mkt, address(0), address(0));
        uint256 t = block.timestamp;
        for (uint256 i; i < voters.length; i++) {
            bytes32 h = resolver.computeVoteHash(scores[i], bytes32(uint256(i + 1)), mkt, voters[i]);
            vm.prank(voters[i]); resolver.commitVote(mkt, h);
        }
        vm.warp(t + 31 minutes);
        for (uint256 i; i < voters.length; i++) { vm.prank(voters[i]); resolver.revealVote(mkt, scores[i], bytes32(uint256(i + 1))); }
        vm.warp(t + 62 minutes);
        return resolver.resolve(mkt, "");
    }

    function _two(address a, address b) internal pure returns (address[] memory r) { r = new address[](2); r[0]=a; r[1]=b; }
    function _two16(uint16 a, uint16 b) internal pure returns (uint16[] memory r) { r = new uint16[](2); r[0]=a; r[1]=b; }
    function _four(address a, address b, address c, address d) internal pure returns (address[] memory r) { r = new address[](4); r[0]=a; r[1]=b; r[2]=c; r[3]=d; }
    function _four16(uint16 a, uint16 b, uint16 c, uint16 d) internal pure returns (uint16[] memory r) { r = new uint16[](4); r[0]=a; r[1]=b; r[2]=c; r[3]=d; }

    /* ---------- basics ---------- */

    function test_name_and_freshCalibration() public view {
        assertEq(resolver.name(), "ScalarResolverV9");
        assertEq(resolver.effectiveCalibration(Hh1), resolver.CALIB_START()); // fresh => START (0.5x)
    }

    /* ---------- calibration rises on honest, falls on outlier ---------- */

    function test_calibration_risesAndFalls() public {
        _stake(Hh1, 1 ether); _stake(L1, 1 ether);
        _cycle(bytes32(uint256(1)), _two(Hh1, L1), _two16(3000, 9999)); // median 3000; Hh1 honest, L1 outlier
        assertEq(resolver.calibration(Hh1), resolver.CALIB_START() + resolver.CALIB_STEP()); // 5000
        assertEq(resolver.calibration(L1), resolver.CALIB_START() - resolver.CALIB_STEP());  // 3000
    }

    /* ---------- voteWeight scales with earned calibration ---------- */

    function test_voteWeight_scalesWithCalibration() public {
        _stake(Hh1, 1 ether); _stake(Hh2, 1 ether);
        // two honest rounds -> Hh1 calibration 4000 -> 6000 (0.75x)
        _cycle(bytes32(uint256(2)), _two(Hh1, Hh2), _two16(5000, 5000));
        _cycle(bytes32(uint256(3)), _two(Hh1, Hh2), _two16(5000, 5000));
        assertEq(resolver.effectiveCalibration(Hh1), 6000);
        // equal stake, but proven Hh1 outweighs a fresh validator
        assertEq(resolver.voteWeight(Hh1), 1 ether * 6000 / 8000);  // 0.75x
        _stake(L1, 1 ether);
        assertEq(resolver.voteWeight(L1), 1 ether * 4000 / 8000);   // 0.50x fresh
        assertGt(resolver.voteWeight(Hh1), resolver.voteWeight(L1));
    }

    /* ---------- CONTROL: 4 equal-stake fresh validators, two camps ---------- */

    function test_control_allFresh_lowCampWins() public {
        _stake(Hh1, 1 ether); _stake(Hh2, 1 ether); _stake(L1, 1 ether); _stake(L2, 1 ether);
        // all fresh (0.5x), camps vote 2000 vs 8000 -> weighted median = 2000.
        uint256 score = _cycle(bytes32(uint256(4)), _four(L1, L2, Hh1, Hh2), _four16(2000, 2000, 8000, 8000));
        assertEq(score, 2000);
    }

    /* ---------- HEADLINE: earned accuracy flips the outcome ---------- */

    function test_headline_calibrationFlipsBetweenEqualStakeCamps() public {
        _stake(Hh1, 1 ether); _stake(Hh2, 1 ether); _stake(L1, 1 ether); _stake(L2, 1 ether);

        // Hh1, Hh2 earn calibration (two honest rounds together, L1/L2 abstain).
        _cycle(bytes32(uint256(10)), _two(Hh1, Hh2), _two16(5000, 5000));
        _cycle(bytes32(uint256(11)), _two(Hh1, Hh2), _two16(5000, 5000));
        assertEq(resolver.calibration(Hh1), 6000); // 0.75x
        assertEq(resolver.effectiveCalibration(L1), 4000); // still fresh 0.5x

        // SAME stakes and SAME camp votes as the control — but now the high camp
        // is PROVEN. Outcome flips 2000 -> 8000: earned accuracy, not capital,
        // decides the resolution.
        uint256 score = _cycle(bytes32(uint256(12)), _four(L1, L2, Hh1, Hh2), _four16(2000, 2000, 8000, 8000));
        assertEq(score, 8000);
    }

    /* ---------- KNOWN LIMITATION (demonstrated honestly, not hidden) ---------- */

    /// @dev Calibration rewards a *track record of voting-with-consensus*, which
    ///      a cartel can MANUFACTURE by voting with ITSELF on throwaway markets.
    ///      Once farmed to the 1.50x ceiling, a 2-validator cartel can override
    ///      FOUR equal-stake FRESH honest validators (cartel weight 3.0 > honest
    ///      2.0) while holding HALF the stake. This is the flip side of the
    ///      headline and is disclosed in docs/README honest-limits.
    ///      Why it is bounded / mitigated, not fatal:
    ///        (1) farming costs real USDC — each market needs escrow + dispute
    ///            bond on CrucibleMarketV7;
    ///        (2) the edge VANISHES once honest validators have themselves
    ///            accrued calibration (it is only a bootstrap-phase asymmetry);
    ///        (3) value-weighted calibration gain (future work) makes farming on
    ///            dust-sized throwaway markets worthless.
    function test_limitation_farmedCartelBeatsFreshHonest() public {
        address A1 = makeAddr("A1");
        address A2 = makeAddr("A2");
        address H3 = makeAddr("H3");
        address H4 = makeAddr("H4");
        address[6] memory who = [A1, A2, L1, L2, H3, H4];
        for (uint256 i; i < 6; i++) { vm.deal(who[i], 1000 ether); _stake(who[i], 1 ether); }

        // Farm the cartel (A1, A2) to the 1.50x ceiling via 8 honest self-rounds.
        for (uint256 r; r < 8; r++) {
            _cycle(bytes32(uint256(100 + r)), _two(A1, A2), _two16(5000, 5000));
        }
        assertEq(resolver.effectiveCalibration(A1), resolver.CALIB_MAX()); // 12000 = 1.5x
        assertEq(resolver.effectiveCalibration(L1), resolver.CALIB_START()); // honest stay fresh 0.5x

        // Contested market: 4 fresh-honest push the true score 2000; the farmed
        // 2-cartel pushes 10000. Cartel weight 3.0 > honest weight 2.0 -> cartel
        // wins with HALF the stake. The test ASSERTS the limitation so a future
        // mitigation that closes it will visibly flip this expectation.
        address[] memory voters = new address[](6);
        voters[0] = L1; voters[1] = L2; voters[2] = H3; voters[3] = H4; voters[4] = A1; voters[5] = A2;
        uint16[] memory scores = new uint16[](6);
        scores[0] = 2000; scores[1] = 2000; scores[2] = 2000; scores[3] = 2000; scores[4] = 10000; scores[5] = 10000;
        uint256 score = _cycle(bytes32(uint256(200)), voters, scores);
        assertEq(score, 10000);
    }
}
