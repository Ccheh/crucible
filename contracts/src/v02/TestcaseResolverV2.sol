// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "./IResolverFeeReceiver.sol";

/// @title  TestcaseResolverV2
/// @notice v0.2 of the validator network resolver. Adds:
///         (1) **Slashing** — validators whose vote diverges from the final
///             consensus score lose stake proportional to the distance.
///         (2) **Reward fee pool** — when a market is resolved through dispute,
///             a fee (paid by CrucibleMarketV2 on resolveDisputed) is distributed
///             pro-rata to validators whose vote was *close enough* to consensus.
///         (3) **Pending-vote-aware unstake** — validators must wait for their
///             votes' markets to resolve before unstaking, not just the flat
///             7-day cooldown of v0.
///
/// @dev    The math:
///           finalScoreBps  = stake-weighted mean of votes
///           distance       = |vote - finalScoreBps|  (0..10000)
///           tolerance      = TOLERANCE_BPS (e.g., 1500)
///           if distance <= tolerance:
///             validator is HONEST -> earns reward
///           else:
///             validator is SLASHED proportional to (distance - tolerance)
///             slashAmount = stake * (distance - tolerance) / 8500  (capped at MAX_SLASH_BPS)
///
///         Reward distribution: honest validators split the market's fee pool
///         proportional to their stake. (Closer-to-consensus does NOT get more
///         reward in v0.2 — keep simple, refine in v0.3.)
///
/// @dev    Receives fees via the `notifyFee(marketId)` function called by
///         CrucibleMarketV2 with USDC value attached. NO admin keys, NO upgrade
///         proxy. Future versions deploy fresh.
contract TestcaseResolverV2 is IResolver, IResolverFeeReceiver, ReentrancyGuard {
    /* ------------- constants ------------- */

    /// @notice Minimum stake to vote. Filters spam.
    uint256 public constant MIN_STAKE = 0.1 ether;

    /// @notice Flat unstake cooldown PLUS pending-votes guard.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Per-market voting window, auto-opens on first vote.
    uint64 public constant VOTING_WINDOW = 1 hours;

    /// @notice Validators within +/- TOLERANCE_BPS of consensus are honest (rewarded).
    uint256 public constant TOLERANCE_BPS = 1500; // 15 percentage points

    /// @notice Max fraction of stake that can be slashed per market resolution.
    uint256 public constant MAX_SLASH_BPS = 1000; // 10%

    /* ------------- validator pool ------------- */

    mapping(address => uint256) public validatorStake;
    uint256 public totalStake;

    /// @notice Number of unresolved markets where a validator has voted.
    /// @dev Must reach 0 before completeUnstake can succeed.
    mapping(address => uint256) public pendingVotes;

    mapping(address => uint256) public unstakeRequestedAmount;
    mapping(address => uint64) public unstakeReadyAt;

    /* ------------- per-market state ------------- */

    struct Market {
        uint64 votingDeadline;
        uint16 finalScoreBps;
        bool   resolved;
        uint256 feePool;          // USDC pooled for this market's reward distribution
    }

    mapping(bytes32 => Market) private _markets;
    mapping(bytes32 => mapping(address => uint16)) public votes;
    mapping(bytes32 => mapping(address => bool)) public hasVoted;
    mapping(bytes32 => address[]) private _voters;

    /// @notice Pending reward amounts for each validator (claimable via claimRewards).
    mapping(address => uint256) public pendingReward;

    /* ------------- events ------------- */

    event Staked(address indexed validator, uint256 amount, uint256 newStake);
    event UnstakeRequested(address indexed validator, uint256 amount, uint64 readyAt);
    event Unstaked(address indexed validator, uint256 amount);
    event Voted(bytes32 indexed marketId, address indexed validator, uint16 scoreBps);
    event MarketResolved(bytes32 indexed marketId, uint16 finalScoreBps, uint256 voters, uint256 totalSlashed, uint256 totalRewarded);
    event ValidatorSlashed(bytes32 indexed marketId, address indexed validator, uint256 amount, uint256 distance);
    event RewardEarned(bytes32 indexed marketId, address indexed validator, uint256 amount);
    event RewardClaimed(address indexed validator, uint256 amount);
    event FeeReceived(bytes32 indexed marketId, uint256 amount);

    /* ------------- errors ------------- */

    error ZeroAmount();
    error InsufficientStake();
    error StakeAboveBalance();
    error ScoreOutOfRange();
    error WindowClosed();
    error AlreadyVoted();
    error AlreadyResolved();
    error NoVotes();
    error NotReady();
    error PendingUnstake();
    error TransferFailed();
    error PendingVotes(uint256 count);

    /* ------------- validator: stake / unstake ------------- */

    function stake() external payable {
        if (msg.value == 0) revert ZeroAmount();
        if (unstakeRequestedAmount[msg.sender] > 0) revert PendingUnstake();
        validatorStake[msg.sender] += msg.value;
        totalStake += msg.value;
        emit Staked(msg.sender, msg.value, validatorStake[msg.sender]);
    }

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
        // CRITICAL v0.2 difference: must have NO pending votes to unstake.
        // Protects against vote-and-flee — validator must let their markets resolve.
        if (pendingVotes[msg.sender] > 0) revert PendingVotes(pendingVotes[msg.sender]);

        unstakeRequestedAmount[msg.sender] = 0;
        unstakeReadyAt[msg.sender] = 0;
        // Cap by current stake (in case slashing reduced it during cooldown)
        if (amount > validatorStake[msg.sender]) amount = validatorStake[msg.sender];
        validatorStake[msg.sender] -= amount;
        totalStake -= amount;
        emit Unstaked(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /* ------------- voting ------------- */

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
        pendingVotes[msg.sender] += 1;
        emit Voted(marketId, msg.sender, scoreBps);
    }

    /* ------------- fee pool intake ------------- */

    /// @notice Called by CrucibleMarketV2 when a disputed market resolves.
    ///         The market sends a fee amount destined for the validator network.
    function notifyFee(bytes32 marketId) external payable {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        m.feePool += msg.value;
        emit FeeReceived(marketId, msg.value);
    }

    /* ------------- IResolver interface ------------- */

    function canResolve(bytes32 marketId) external view returns (bool) {
        Market storage m = _markets[marketId];
        if (m.resolved) return false;
        if (m.votingDeadline == 0) return false;
        if (block.timestamp <= m.votingDeadline) return false;
        return _voters[marketId].length > 0;
    }

    /// @notice Resolve a market. Computes stake-weighted mean, slashes outliers,
    ///         distributes fee pool to honest validators.
    function resolve(bytes32 marketId, bytes calldata) external returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.votingDeadline == 0 || block.timestamp <= m.votingDeadline) revert WindowClosed();
        address[] storage vs = _voters[marketId];
        uint256 len = vs.length;
        if (len == 0) revert NoVotes();

        // ---------- Pass 1: compute stake-weighted mean ----------
        uint256 totalWeightedScore = 0;
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint256 w = validatorStake[v];
            totalWeightedScore += uint256(votes[marketId][v]) * w;
            totalWeight += w;
            unchecked { ++i; }
        }
        uint16 finalScoreBps = uint16(totalWeightedScore / totalWeight);

        // ---------- Pass 2: compute slashing + honest stake ----------
        uint256 totalSlashed = 0;
        uint256 honestStake = 0;
        // Track per-validator data inline to avoid extra storage
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint256 stk = validatorStake[v];
            uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));

            // Decrement pending-vote count for this validator
            if (pendingVotes[v] > 0) pendingVotes[v] -= 1;

            if (distance <= TOLERANCE_BPS) {
                honestStake += stk;
            } else {
                // Slash: proportional to (distance - tolerance) / (10000 - tolerance)
                uint256 excess = distance - TOLERANCE_BPS;
                uint256 slashBps = (excess * MAX_SLASH_BPS) / (10000 - TOLERANCE_BPS);
                if (slashBps > MAX_SLASH_BPS) slashBps = MAX_SLASH_BPS;
                uint256 slashAmt = (stk * slashBps) / 10000;
                if (slashAmt > 0 && slashAmt <= stk) {
                    validatorStake[v] -= slashAmt;
                    totalStake -= slashAmt;
                    totalSlashed += slashAmt;
                    emit ValidatorSlashed(marketId, v, slashAmt, distance);
                }
            }
            unchecked { ++i; }
        }

        // ---------- Pass 3: distribute fee pool + redistribute slashed amount ----------
        // Total reward = feePool + totalSlashed. Distribute proportional to honest stake.
        uint256 totalRewardPool = m.feePool + totalSlashed;
        uint256 totalRewarded = 0;
        if (totalRewardPool > 0 && honestStake > 0) {
            for (uint256 i = 0; i < len;) {
                address v = vs[i];
                uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));
                if (distance <= TOLERANCE_BPS) {
                    uint256 reward = (totalRewardPool * validatorStake[v]) / honestStake;
                    // Re-read stake after potential mid-loop changes (paranoid)
                    pendingReward[v] += reward;
                    totalRewarded += reward;
                    emit RewardEarned(marketId, v, reward);
                }
                unchecked { ++i; }
            }
        }
        // Any dust from rounding stays in contract (negligible)

        m.finalScoreBps = finalScoreBps;
        m.resolved = true;
        emit MarketResolved(marketId, finalScoreBps, len, totalSlashed, totalRewarded);

        return finalScoreBps;
    }

    /* ------------- reward claim ------------- */

    function claimRewards() external nonReentrant returns (uint256) {
        uint256 amount = pendingReward[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingReward[msg.sender] = 0;
        emit RewardClaimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        return amount;
    }

    /* ------------- views ------------- */

    function name() external pure returns (string memory) {
        return "TestcaseResolverV2";
    }

    function getMarket(bytes32 marketId)
        external
        view
        returns (uint64 votingDeadline, uint16 finalScoreBps, bool resolved, uint256 voterCount, uint256 feePool)
    {
        Market storage m = _markets[marketId];
        return (m.votingDeadline, m.finalScoreBps, m.resolved, _voters[marketId].length, m.feePool);
    }

    function getVoters(bytes32 marketId) external view returns (address[] memory) {
        return _voters[marketId];
    }

    /* ------------- internal helpers ------------- */

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
