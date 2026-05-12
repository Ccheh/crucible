// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IResolver} from "../interfaces/IResolver.sol";

/// @title  TestcaseResolver
/// @notice Resolves Crucible markets where the service's output is code (or any
///         testable artifact). Validators stake USDC, then submit a quality
///         score in basis points (0..10000 = 0..100% test pass rate) for each
///         disputed market. A short voting window collects votes from staked
///         validators; the final score is the stake-weighted average.
///
/// @dev    Off-chain convention: the market's commitmentHash is
///         `keccak256(input || testcases || expectedOutputHash || codeURI)`.
///         Validators fetch the artifacts via the commitmentHash's preimage
///         (which they get from the service's off-chain channel), run the
///         testcases in a sandbox, and submit their pass-rate.
///
///         v0 simplifications:
///         - No slashing (yet). Validators have stake at risk only in the
///           sense that misbehavior reduces their future fee earnings and
///           reputation. Real slashing math lands in v0.2 alongside a fee pool.
///         - No reward distribution yet. Validators do this for reputation
///           build-up and to bootstrap the resolver. v0.2 introduces a fee
///           split (resolver takes 1-3% of agent escrow).
///         - No challenge / second-round window. Single voting window only.
///
/// @dev    The contract is permissionless: anyone with `MIN_STAKE` worth of
///         USDC can register as a validator and vote on any market.
contract TestcaseResolver is IResolver, ReentrancyGuard {
    /* ---------- validator pool ---------- */

    mapping(address validator => uint256) public validatorStake;
    uint256 public totalStake;

    /// @notice Minimum stake required to vote. Filters out spam validators.
    uint256 public constant MIN_STAKE = 0.1 ether;

    /// @notice After unstaking, validator's funds lock for this period before they
    ///         can withdraw. Prevents flash-vote-and-exit attacks.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    mapping(address validator => uint256) public unstakeRequestedAmount;
    mapping(address validator => uint64) public unstakeReadyAt;

    /* ---------- per-market state ---------- */

    /// @notice Voting window: 1 hour from the first vote on a market. Short
    ///         enough that markets resolve quickly; long enough that geographically
    ///         distributed validators can participate.
    uint64 public constant VOTING_WINDOW = 1 hours;

    struct Market {
        uint64 votingDeadline;     // 0 = no votes yet
        uint16 finalScore;
        bool   resolved;
    }

    /// @dev Public votes: validator -> score (basis points)
    mapping(bytes32 marketId => Market) private _markets;
    mapping(bytes32 marketId => mapping(address validator => uint16)) public votes;
    mapping(bytes32 marketId => mapping(address validator => bool)) public hasVoted;
    mapping(bytes32 marketId => address[]) private _voters;

    /* ---------- events ---------- */

    event Staked(address indexed validator, uint256 amount, uint256 newStake);
    event UnstakeRequested(address indexed validator, uint256 amount, uint64 readyAt);
    event Unstaked(address indexed validator, uint256 amount);
    event Voted(bytes32 indexed marketId, address indexed validator, uint16 scoreBps, uint64 votingDeadline);
    event MarketResolved(bytes32 indexed marketId, uint16 finalScoreBps, uint256 voters);

    /* ---------- errors ---------- */

    error ZeroAmount();
    error InsufficientStake();
    error StakeAboveBalance();
    error ScoreOutOfRange();
    error WindowClosed();
    error AlreadyVoted();
    error AlreadyResolved();
    error NoVotes();
    error NotReady();
    error TransferFailed();
    error PendingUnstake();

    /* ---------- validator: stake / unstake ---------- */

    function stake() external payable {
        if (msg.value == 0) revert ZeroAmount();
        // Block staking while there's a pending unstake -- forces clean lifecycle
        if (unstakeRequestedAmount[msg.sender] > 0) revert PendingUnstake();
        validatorStake[msg.sender] += msg.value;
        totalStake += msg.value;
        emit Staked(msg.sender, msg.value, validatorStake[msg.sender]);
    }

    /// @notice Request to unstake. Funds become withdrawable after UNSTAKE_COOLDOWN.
    function requestUnstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (amount > validatorStake[msg.sender]) revert StakeAboveBalance();
        if (unstakeRequestedAmount[msg.sender] > 0) revert PendingUnstake();
        unstakeRequestedAmount[msg.sender] = amount;
        unstakeReadyAt[msg.sender] = uint64(block.timestamp) + UNSTAKE_COOLDOWN;
        emit UnstakeRequested(msg.sender, amount, unstakeReadyAt[msg.sender]);
    }

    function completeUnstake() external nonReentrant {
        uint256 amount = unstakeRequestedAmount[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp < unstakeReadyAt[msg.sender]) revert NotReady();

        unstakeRequestedAmount[msg.sender] = 0;
        unstakeReadyAt[msg.sender] = 0;
        validatorStake[msg.sender] -= amount;
        totalStake -= amount;

        emit Unstaked(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /* ---------- voting ---------- */

    /// @notice Submit a quality score for a market. Score is in basis points
    ///         (0..10000). The first vote on a market starts the voting window.
    function vote(bytes32 marketId, uint16 scoreBps) external {
        if (validatorStake[msg.sender] < MIN_STAKE) revert InsufficientStake();
        if (scoreBps > 10000) revert ScoreOutOfRange();

        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (hasVoted[marketId][msg.sender]) revert AlreadyVoted();

        if (m.votingDeadline == 0) {
            m.votingDeadline = uint64(block.timestamp) + VOTING_WINDOW;
        } else if (block.timestamp > m.votingDeadline) {
            revert WindowClosed();
        }

        votes[marketId][msg.sender] = scoreBps;
        hasVoted[marketId][msg.sender] = true;
        _voters[marketId].push(msg.sender);

        emit Voted(marketId, msg.sender, scoreBps, m.votingDeadline);
    }

    /* ---------- IResolver interface ---------- */

    function canResolve(bytes32 marketId) external view returns (bool) {
        Market storage m = _markets[marketId];
        if (m.resolved) return false;
        if (m.votingDeadline == 0) return false;
        if (block.timestamp <= m.votingDeadline) return false;
        return _voters[marketId].length > 0;
    }

    function resolve(bytes32 marketId, bytes calldata) external returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.votingDeadline == 0 || block.timestamp <= m.votingDeadline) revert WindowClosed();
        address[] storage vs = _voters[marketId];
        if (vs.length == 0) revert NoVotes();

        // Stake-weighted average. (Median would be more attack-resistant; we
        // keep mean for v0 simplicity, switch to median in v0.2 once sorting
        // is acceptable.)
        uint256 totalWeightedScore = 0;
        uint256 totalWeight = 0;
        uint256 len = vs.length;
        for (uint256 i = 0; i < len; ) {
            address v = vs[i];
            uint256 w = validatorStake[v];
            totalWeightedScore += uint256(votes[marketId][v]) * w;
            totalWeight += w;
            unchecked { ++i; }
        }
        uint16 finalScore = uint16(totalWeightedScore / totalWeight);
        m.finalScore = finalScore;
        m.resolved = true;
        emit MarketResolved(marketId, finalScore, len);

        return finalScore;
    }

    function name() external pure returns (string memory) {
        return "TestcaseResolver-v0";
    }

    /* ---------- views ---------- */

    function getMarket(bytes32 marketId)
        external
        view
        returns (uint64 votingDeadline, uint16 finalScore, bool resolved, uint256 voterCount)
    {
        Market storage m = _markets[marketId];
        return (m.votingDeadline, m.finalScore, m.resolved, _voters[marketId].length);
    }

    function getVoters(bytes32 marketId) external view returns (address[] memory) {
        return _voters[marketId];
    }
}
