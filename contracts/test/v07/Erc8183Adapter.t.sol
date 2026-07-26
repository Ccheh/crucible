// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Erc8183ProportionalAdapter, IGradedScoreSource} from "../../src/v07/Erc8183ProportionalAdapter.sol";
import {ScalarResolverV7} from "../../src/v07/ScalarResolverV7.sol";

/// @dev settable graded-score source for unit tests.
contract MockGradedResolver is IGradedScoreSource {
    mapping(bytes32 => uint16) public s;
    mapping(bytes32 => bool) public r;
    function set(bytes32 m, uint16 score, bool resolved) external { s[m] = score; r[m] = resolved; }
    function getMarket(bytes32 m) external view returns (uint64, uint64, uint16, bool, uint256, uint256) {
        return (0, 0, s[m], r[m], 0, 0);
    }
}

/// @dev a binary ERC-8183-style job, to contrast with the graded upgrade.
contract MockErc8183Job {
    address public client;
    address public worker;
    uint256 public amount;
    bytes32 public jobId;

    function fund(bytes32 _jobId, address _client, address _worker) external payable {
        jobId = _jobId; client = _client; worker = _worker; amount = msg.value;
    }
    /// standard ERC-8183 terminal: complete() => 100% to worker.
    function completeBinary() external {
        uint256 a = amount; amount = 0;
        (bool ok,) = worker.call{value: a}(""); require(ok, "x");
    }
    /// upgrade: route the escrow to the graded adapter instead of binary settle.
    function escalateToGraded(Erc8183ProportionalAdapter adapter, bytes32 marketId) external {
        uint256 a = amount; amount = 0;
        adapter.register{value: a}(jobId, client, worker, marketId);
    }
}

contract Erc8183AdapterTest is Test {
    Erc8183ProportionalAdapter adapter;
    MockGradedResolver mockRes;

    address client = makeAddr("client"); // payer
    address worker = makeAddr("worker"); // payee

    bytes32 constant JOB = bytes32(uint256(0x8183));
    bytes32 constant MKT = bytes32(uint256(1));

    function setUp() public {
        mockRes = new MockGradedResolver();
        adapter = new Erc8183ProportionalAdapter(address(mockRes));
        vm.deal(address(this), 100 ether);
    }

    /* ---------- proportional split ---------- */

    function test_settle_score5000_splitsHalf() public {
        mockRes.set(MKT, 5000, true);
        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
        uint256 w0 = worker.balance; uint256 c0 = client.balance;
        adapter.settle(JOB);
        assertEq(worker.balance - w0, 0.5 ether);
        assertEq(client.balance - c0, 0.5 ether);
    }

    function test_settle_score10000_allToWorker_equalsComplete() public {
        mockRes.set(MKT, 10000, true);
        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
        uint256 w0 = worker.balance; uint256 c0 = client.balance;
        adapter.settle(JOB);
        assertEq(worker.balance - w0, 1 ether);
        assertEq(client.balance - c0, 0);
    }

    function test_settle_score0_allToClient_equalsReject() public {
        mockRes.set(MKT, 0, true);
        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
        uint256 w0 = worker.balance; uint256 c0 = client.balance;
        adapter.settle(JOB);
        assertEq(worker.balance - w0, 0);
        assertEq(client.balance - c0, 1 ether);
    }

    /* ---------- guards ---------- */

    function test_settle_unresolvedReverts() public {
        mockRes.set(MKT, 7000, false); // not resolved yet
        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
        vm.expectRevert(Erc8183ProportionalAdapter.ScoreNotReady.selector);
        adapter.settle(JOB);
    }

    function test_settle_doubleReverts() public {
        mockRes.set(MKT, 5000, true);
        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
        adapter.settle(JOB);
        vm.expectRevert(Erc8183ProportionalAdapter.AlreadySettled.selector);
        adapter.settle(JOB);
    }

    function test_register_guards() public {
        vm.expectRevert(Erc8183ProportionalAdapter.ZeroEscrow.selector);
        adapter.register{value: 0}(JOB, client, worker, MKT);

        vm.expectRevert(Erc8183ProportionalAdapter.ZeroParty.selector);
        adapter.register{value: 1 ether}(JOB, address(0), worker, MKT);

        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
        vm.expectRevert(Erc8183ProportionalAdapter.AlreadyRegistered.selector);
        adapter.register{value: 1 ether}(JOB, client, worker, MKT);
    }

    /* ---------- the upgrade narrative: binary vs graded ---------- */

    function test_erc8183_binaryVsGraded() public {
        // Binary path: worker gets 100% regardless of quality.
        MockErc8183Job jobA = new MockErc8183Job();
        jobA.fund{value: 1 ether}(JOB, client, worker);
        uint256 w0 = worker.balance;
        jobA.completeBinary();
        assertEq(worker.balance - w0, 1 ether, "binary = all-or-nothing");

        // Graded path: same job, mediocre work scored 3000 -> worker gets 30%.
        MockErc8183Job jobB = new MockErc8183Job();
        bytes32 jobBId = bytes32(uint256(0x8184));
        bytes32 mktB = bytes32(uint256(2));
        jobB.fund{value: 1 ether}(jobBId, client, worker);
        mockRes.set(mktB, 3000, true);
        jobB.escalateToGraded(adapter, mktB);

        uint256 w1 = worker.balance; uint256 c1 = client.balance;
        adapter.settle(jobBId);
        assertEq(worker.balance - w1, 0.3 ether, "graded = proportional to score");
        assertEq(client.balance - c1, 0.7 ether);
    }

    /* ---------- integration with the REAL resolver ---------- */

    function test_integration_realScalarResolver() public {
        // Bind a real ScalarResolverV7 (authorizedMarket = this test, unused here),
        // run a genuine commit-reveal resolution, then settle the 8183 escrow by
        // the resolver's own finalScoreBps.
        ScalarResolverV7 res = new ScalarResolverV7(0.1 ether, address(this));
        Erc8183ProportionalAdapter realAdapter = new Erc8183ProportionalAdapter(address(res));

        address a1 = makeAddr("a1"); address a2 = makeAddr("a2"); address a3 = makeAddr("a3");
        vm.deal(a1, 10 ether); vm.deal(a2, 10 ether); vm.deal(a3, 10 ether);
        uint256 t0 = block.timestamp;
        vm.prank(a1); res.stake{value: 1 ether}();
        vm.prank(a2); res.stake{value: 1 ether}();
        vm.prank(a3); res.stake{value: 1 ether}();

        bytes32 mkt = bytes32(uint256(0xBEEF));
        res.onDispute(mkt, address(0), address(0)); // open voting (caller = this = market)
        bytes32 h1 = res.computeVoteHash(7000, bytes32(uint256(1)), mkt, a1);
        bytes32 h2 = res.computeVoteHash(8000, bytes32(uint256(2)), mkt, a2);
        bytes32 h3 = res.computeVoteHash(9000, bytes32(uint256(3)), mkt, a3);
        vm.prank(a1); res.commitVote(mkt, h1);
        vm.prank(a2); res.commitVote(mkt, h2);
        vm.prank(a3); res.commitVote(mkt, h3);
        vm.warp(t0 + 31 minutes);
        vm.prank(a1); res.revealVote(mkt, 7000, bytes32(uint256(1)));
        vm.prank(a2); res.revealVote(mkt, 8000, bytes32(uint256(2)));
        vm.prank(a3); res.revealVote(mkt, 9000, bytes32(uint256(3)));
        vm.warp(t0 + 62 minutes);
        res.resolve(mkt, ""); // finalScoreBps = median 8000

        realAdapter.register{value: 1 ether}(JOB, client, worker, mkt);
        uint256 w0 = worker.balance; uint256 c0 = client.balance;
        realAdapter.settle(JOB);
        assertEq(worker.balance - w0, 0.8 ether); // 80% by the real resolved score
        assertEq(client.balance - c0, 0.2 ether);
    }

    /* ---------- invariants: value conservation for ANY score ---------- */

    /// @dev The continuous split conserves value at every score — no bucket
    ///      discontinuities, no value created or destroyed (contrast a
    ///      4-tier step function where a wei can fall between tiers).
    function testFuzz_previewSplit_conserves(uint256 amount, uint16 scoreBps) public view {
        amount = bound(amount, 0, 1e30);
        scoreBps = uint16(bound(uint256(scoreBps), 0, 10000));
        (uint256 toPayee, uint256 toPayer) = adapter.previewSplit(amount, scoreBps);
        assertEq(toPayee + toPayer, amount); // exact conservation
        assertLe(toPayee, amount);
    }

    function testFuzz_settle_noWeiStuck(uint256 amount, uint16 scoreBps) public {
        amount = bound(amount, 1, 100 ether);
        scoreBps = uint16(bound(uint256(scoreBps), 0, 10000));
        mockRes.set(MKT, scoreBps, true);
        adapter.register{value: amount}(JOB, client, worker, MKT);
        uint256 w0 = worker.balance;
        uint256 c0 = client.balance;
        adapter.settle(JOB);
        // everything escrowed leaves the adapter; nothing stranded.
        assertEq((worker.balance - w0) + (client.balance - c0), amount);
        assertEq(address(adapter).balance, 0);
    }

    receive() external payable {}
}
