// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal subset of the ERC-8183 AI-job-escrow standard. ERC-8183
///         settlement is BINARY: an evaluator either `complete`s a job (full
///         escrow to the worker) or `reject`s it (full refund to the client).
///         "Discovery, pricing, evaluation logic, and reputation systems can
///         all be layered around that common flow" — i.e. graded evaluation is
///         explicitly left for protocols on top. This adapter is that layer.
interface IERC8183 {
    enum JobStatus { Open, Funded, Submitted, Completed, Rejected, Expired }
    function status(bytes32 jobId) external view returns (JobStatus);
    function escrow(bytes32 jobId) external view returns (uint256);
    function client(bytes32 jobId) external view returns (address);
    function worker(bytes32 jobId) external view returns (address);
}

/// @notice The graded-score surface this adapter consumes. Matches
///         ScalarResolverV7.getMarket (and any resolver exposing it).
interface IGradedScoreSource {
    function getMarket(bytes32 marketId)
        external
        view
        returns (uint64 commitDeadline, uint64 revealDeadline, uint16 finalScoreBps, bool resolved, uint256 voterCount, uint256 feePool);
}

/// @title  Erc8183ProportionalAdapter
/// @notice The missing graded-settlement layer for ERC-8183 jobs (and any
///         escrow): upgrades the standard's BINARY accept/reject into a
///         CONTINUOUS, score-proportional split, using a Crucible graded
///         resolver as the verdict source.
///
///         Flow: an ERC-8183 job (or its client) escrows the disputed amount
///         here via `register`, pointing at the Crucible market that will
///         grade the work. Once that market is resolved to a score in
///         [0, 10000], anyone calls `settle`: the worker receives
///         `amount * score / 10000` and the client is refunded the remainder.
///         Score 10000 == the standard's `complete`; score 0 == `reject`;
///         everything in between is the upgrade ERC-8183 itself cannot express.
///
/// @dev    Admin-keyless and standard-agnostic: it holds funds only between
///         register and settle, reads the score from an immutable resolver,
///         and never has discretion over the outcome.
contract Erc8183ProportionalAdapter is ReentrancyGuard {
    IGradedScoreSource public immutable resolver;

    struct Settlement {
        address payer;   // client (gets the refund remainder)
        address payee;   // worker (gets the score-proportional share)
        uint256 amount;  // escrow held here
        bytes32 marketId;
        bool    settled;
    }

    mapping(bytes32 id => Settlement) public settlements;

    event Registered(bytes32 indexed id, address indexed payer, address indexed payee, uint256 amount, bytes32 marketId);
    event Settled(bytes32 indexed id, uint16 scoreBps, uint256 toPayee, uint256 toPayer);

    error AlreadyRegistered();
    error ZeroEscrow();
    error ZeroParty();
    error UnknownSettlement();
    error AlreadySettled();
    error ScoreNotReady();
    error TransferFailed();

    constructor(address _resolver) {
        require(_resolver != address(0), "resolver zero");
        resolver = IGradedScoreSource(_resolver);
    }

    /// @notice Escrow an amount to be settled proportionally by `marketId`'s
    ///         resolved score. Callable by anyone holding the funds (the
    ///         ERC-8183 job contract, its client, or a test harness).
    function register(bytes32 id, address payer, address payee, bytes32 marketId)
        external
        payable
    {
        if (settlements[id].amount != 0) revert AlreadyRegistered();
        if (msg.value == 0) revert ZeroEscrow();
        if (payer == address(0) || payee == address(0)) revert ZeroParty();
        settlements[id] = Settlement(payer, payee, msg.value, marketId, false);
        emit Registered(id, payer, payee, msg.value, marketId);
    }

    /// @notice Split the escrow proportionally once the Crucible market is
    ///         resolved. Permissionless.
    function settle(bytes32 id) external nonReentrant {
        Settlement storage st = settlements[id];
        if (st.amount == 0) revert UnknownSettlement();
        if (st.settled) revert AlreadySettled();

        (, , uint16 scoreBps, bool resolved, , ) = resolver.getMarket(st.marketId);
        if (!resolved) revert ScoreNotReady();

        st.settled = true;
        uint256 amount = st.amount;
        uint256 toPayee = (amount * scoreBps) / 10000;
        uint256 toPayer = amount - toPayee;

        emit Settled(id, scoreBps, toPayee, toPayer);

        if (toPayee > 0) {
            (bool ok,) = st.payee.call{value: toPayee}("");
            if (!ok) revert TransferFailed();
        }
        if (toPayer > 0) {
            (bool ok,) = st.payer.call{value: toPayer}("");
            if (!ok) revert TransferFailed();
        }
    }

    /// @notice Preview the split for a given score without settling.
    function previewSplit(uint256 amount, uint16 scoreBps) external pure returns (uint256 toPayee, uint256 toPayer) {
        toPayee = (amount * scoreBps) / 10000;
        toPayer = amount - toPayee;
    }
}
