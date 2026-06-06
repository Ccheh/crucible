// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ScalarResolverV10} from "../../src/v07/ScalarResolverV10.sol";

/// @title ScalarResolverV10 — value-weighted calibration (anti-farming)
/// @dev   Closes the V9 dust-spam calibration-farming vector: the per-market
///        calibration step now scales with the market's economic weight
///        (resolver fee / feePool). A dust (≈zero-fee) market moves calibration
///        by ~0, so a cartel can no longer manufacture an accuracy record on
///        throwaway markets. The test contract is AUTHORIZED_MARKET and funds
///        feePool via notifyFee to simulate real-value markets.
contract ScalarResolverV10Test is Test {
    ScalarResolverV10 resolver;

    /// @dev Resolver-fee at which a market grants a FULL calibration step.
    uint256 constant REF = 0.01 ether;

    address Hh1 = makeAddr("Hh1");
    address Hh2 = makeAddr("Hh2");
    address L1  = makeAddr("L1");
    address L2  = makeAddr("L2");

    function setUp() public {
        resolver = new ScalarResolverV10(0.1 ether, address(this), address(0), REF);
        vm.deal(address(this), 1_000_000 ether); // to fund market fees
        vm.deal(Hh1, 1000 ether);
        vm.deal(Hh2, 1000 ether);
        vm.deal(L1, 1000 ether);
        vm.deal(L2, 1000 ether);
        vm.warp(1_000_000);
    }

    function _stake(address who, uint256 amt) internal { vm.prank(who); resolver.stake{value: amt}(); }

    /// @dev Run a full market. `fee` is pushed into feePool (the market's
    ///      economic weight) before resolution; fee == 0 models a dust market.
    function _cycleFee(bytes32 mkt, address[] memory voters, uint16[] memory scores, uint256 fee) internal returns (uint256) {
        resolver.onDispute(mkt, address(0), address(0));
        if (fee > 0) resolver.notifyFee{value: fee}(mkt);
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

    function test_name_and_reference() public view {
        assertEq(resolver.name(), "ScalarResolverV10");
        assertEq(resolver.CALIB_FEE_REFERENCE(), REF);
    }

    /// @dev The anti-farming core, as a pure view: step scales with fee, capped.
    function test_calibrationStepFor_scales() public view {
        assertEq(resolver.calibrationStepFor(0), 0);                       // dust => no signal
        assertEq(resolver.calibrationStepFor(REF / 2), resolver.CALIB_STEP() / 2);
        assertEq(resolver.calibrationStepFor(REF), resolver.CALIB_STEP()); // full step at reference
        assertEq(resolver.calibrationStepFor(REF * 5), resolver.CALIB_STEP()); // capped at one step
    }

    /* ---------- dust markets carry NO calibration signal ---------- */

    function test_dustMarket_noCalibrationGain() public {
        _stake(Hh1, 1 ether); _stake(Hh2, 1 ether);
        // honest, agreeing voters — but a ZERO-fee market: calibration must not move.
        _cycleFee(bytes32(uint256(1)), _two(Hh1, Hh2), _two16(5000, 5000), 0);
        assertEq(resolver.effectiveCalibration(Hh1), resolver.CALIB_START()); // still 4000
        assertEq(resolver.calibration(Hh1), 0); // never written
    }

    /* ---------- valued markets DO move calibration (mechanism intact) ---------- */

    function test_valuedMarket_calibrationRises() public {
        _stake(Hh1, 1 ether); _stake(Hh2, 1 ether);
        _cycleFee(bytes32(uint256(2)), _two(Hh1, Hh2), _two16(5000, 5000), REF);     // full step
        assertEq(resolver.calibration(Hh1), resolver.CALIB_START() + resolver.CALIB_STEP()); // 5000
        _cycleFee(bytes32(uint256(3)), _two(Hh1, Hh2), _two16(5000, 5000), REF / 2); // half step
        assertEq(resolver.calibration(Hh1), 5500);
    }

    /* ============================================================= */
    /*  THE FIX: dust-spam farming can no longer override honest      */
    /* ============================================================= */

    /// @dev This is the V9 attack (`test_limitation_farmedCartelBeatsFreshHonest`)
    ///      replayed under V10. The cartel farms on DUST markets — which now
    ///      grant zero calibration — so it stays at the fresh 0.50x weight and
    ///      CANNOT override four equal-stake honest validators. Outcome resolves
    ///      to the honest true value 2000 (V9 resolved to the cartel's 10000).
    function test_fix_dustFarmingCannotOverrideHonest() public {
        address A1 = makeAddr("A1");
        address A2 = makeAddr("A2");
        address H3 = makeAddr("H3");
        address H4 = makeAddr("H4");
        address[6] memory who = [A1, A2, L1, L2, H3, H4];
        for (uint256 i; i < 6; i++) { vm.deal(who[i], 1000 ether); _stake(who[i], 1 ether); }

        // Cartel tries the V9 farm: 8 self-dealt rounds — but on DUST markets.
        for (uint256 r; r < 8; r++) {
            _cycleFee(bytes32(uint256(100 + r)), _two(A1, A2), _two16(5000, 5000), 0);
        }
        // Farming produced NOTHING: cartel is still fresh.
        assertEq(resolver.effectiveCalibration(A1), resolver.CALIB_START()); // 4000, not 12000

        // Contested market: 4 honest push true 2000, cartel pushes 10000.
        address[] memory voters = new address[](6);
        voters[0] = L1; voters[1] = L2; voters[2] = H3; voters[3] = H4; voters[4] = A1; voters[5] = A2;
        uint16[] memory scores = new uint16[](6);
        scores[0] = 2000; scores[1] = 2000; scores[2] = 2000; scores[3] = 2000; scores[4] = 10000; scores[5] = 10000;
        uint256 score = _cycleFee(bytes32(uint256(200)), voters, scores, 0);
        assertEq(score, 2000); // honest wins — the fix (V9 gave 10000)
    }

    /* ---------- the legitimate mechanism still works on valued markets ---------- */

    /// @dev V9's headline, now requiring real economic value to earn calibration:
    ///      two validators that earn calibration on VALUED markets still flip a
    ///      market's outcome 2000 -> 8000 against two equal-stake fresh ones.
    function test_headline_stillWorks_onValuedMarkets() public {
        _stake(Hh1, 1 ether); _stake(Hh2, 1 ether); _stake(L1, 1 ether); _stake(L2, 1 ether);

        // Earn calibration the honest way: two full-value markets.
        _cycleFee(bytes32(uint256(10)), _two(Hh1, Hh2), _two16(5000, 5000), REF);
        _cycleFee(bytes32(uint256(11)), _two(Hh1, Hh2), _two16(5000, 5000), REF);
        assertEq(resolver.calibration(Hh1), 6000);              // 0.75x
        assertEq(resolver.effectiveCalibration(L1), 4000);      // fresh 0.50x

        uint256 score = _cycleFee(bytes32(uint256(12)), _four(L1, L2, Hh1, Hh2), _four16(2000, 2000, 8000, 8000), 0);
        assertEq(score, 8000); // earned accuracy (on real markets) decides
    }
}
