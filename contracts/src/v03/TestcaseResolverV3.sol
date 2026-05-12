// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";

/// @title  TestcaseResolverV3
/// @notice v0.3 of the validator resolver. The headline change is the
///         consensus algorithm: **stake-weighted median** replaces the
///         stake-weighted mean of v0.2.
///
///         The mean is dragged by a single large stake. The median is the
///         smallest score `v` such that the cumulative stake of validators
///         voting `<= v` covers ≥ 50% of total voted stake. A single large
///         outlier vote moves the median by AT MOST one position in the
///         sorted list, instead of by its entire weight.
///
///         All other v0.2 mechanics — slashing on distance-from-consensus,
///         fee-pool intake via notifyFee, pendingVotes-aware unstake,
///         claimRewards — are unchanged.
///
/// @dev    Sort cost: O(M²) insertion sort on M voters per market. Memory
///         only; storage is untouched. Typical M ≤ 20 in v0/v0.2 testnet
///         runs → < 250 compares, gas-bounded. For M > ~60 a future version
///         should adopt a sorted-on-insert data structure.
///
/// @dev    Same constants as v0.2:
///           MIN_STAKE        = 0.1 ether
///           UNSTAKE_COOLDOWN = 7 days
///           VOTING_WINDOW    = 1 hours
///           TOLERANCE_BPS    = 1500   (15pp around the median is honest)
///           MAX_SLASH_BPS    = 1000   (cap = 10% of validator's stake)
///
/// @dev    No admin keys, no upgrade proxy, no fee owner.
contract TestcaseResolverV3 is IResolver, IResolverFeeReceiver, ReentrancyGuard {
    /* ------------- constants ------------- */

    uint256 public constant MIN_STAKE = 0.1 ether;
    uint64  public constant UNSTAKE_COOLDOWN = 7 days;
    uint64  public constant VOTING_WINDOW = 1 hours;
    uint256 public constant TOLERANCE_BPS = 1500;
    uint256 public constant MAX_SLASH_BPS = 1000;

    /* ------------- validator pool ------------- */

    mapping(address => uint256) public validatorStake;
    uint256 public totalStake;

    mapping(address => uint256) public pendingVotes;
    mapping(address => uint256) public unstakeRequestedAmount;
    mapping(address => uint64)  public unstakeReadyAt;

    /* ------------- per-market state ------------- */

    struct Market {
        uint64  votingDeadline;
        uint16  finalScoreBps;
        bool    resolved;
        uint256 feePool;
    }

    mapping(bytes32 => Market) private _markets;
    mapping(bytes32 => mapping(address => uint16)) public votes;
    mapping(bytes32 => mapping(address => bool))   public hasVoted;
    mapping(bytes32 => address[]) private _voters;

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
        if (pendingVotes[msg.sender] > 0) revert PendingVotes(pendingVotes[msg.sender]);

        unstakeRequestedAmount[msg.sender] = 0;
        unstakeReadyAt[msg.sender] = 0;
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

    /* ------------- fee intake ------------- */

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

    /// @notice Resolve a market via stake-weighted MEDIAN, then slash outliers
    ///         and distribute the reward pool to honest validators.
    function resolve(bytes32 marketId, bytes calldata) external returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.votingDeadline == 0 || block.timestamp <= m.votingDeadline) revert WindowClosed();
        address[] storage vs = _voters[marketId];
        uint256 len = vs.length;
        if (len == 0) revert NoVotes();

        // ---------- Pass 1: copy + insertion-sort (vote, stake) pairs ----------
        uint16[]  memory sortedVotes  = new uint16[](len);
        uint256[] memory sortedStakes = new uint256[](len);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint16 vote_ = votes[marketId][v];
            uint256 stk = validatorStake[v];
            totalWeight += stk;

            // Insertion sort: shift larger entries right, place current at j
            uint256 j = i;
            while (j > 0 && sortedVotes[j - 1] > vote_) {
                sortedVotes[j]  = sortedVotes[j - 1];
                sortedStakes[j] = sortedStakes[j - 1];
                unchecked { --j; }
            }
            sortedVotes[j]  = vote_;
            sortedStakes[j] = stk;
            unchecked { ++i; }
        }

        // ---------- Pass 2: find stake-weighted median ----------
        // Median is the smallest v such that cumulativeStake(votes <= v) >= totalWeight / 2.
        uint256 threshold = totalWeight / 2;
        uint256 cumulative = 0;
        uint16 finalScoreBps = 0;
        for (uint256 i = 0; i < len;) {
            cumulative += sortedStakes[i];
            if (cumulative >= threshold) {
                finalScoreBps = sortedVotes[i];
                break;
            }
            unchecked { ++i; }
        }

        // ---------- Pass 3: slash outliers + collect honest stake ----------
        uint256 totalSlashed = 0;
        uint256 honestStake = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint256 stk = validatorStake[v];
            uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));

            if (pendingVotes[v] > 0) pendingVotes[v] -= 1;

            if (distance <= TOLERANCE_BPS) {
                honestStake += stk;
            } else {
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

        // ---------- Pass 4: distribute fee pool + redistribute slashed amount ----------
        uint256 totalRewardPool = m.feePool + totalSlashed;
        uint256 totalRewarded = 0;
        if (totalRewardPool > 0 && honestStake > 0) {
            for (uint256 i = 0; i < len;) {
                address v = vs[i];
                uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));
                if (distance <= TOLERANCE_BPS) {
                    uint256 reward = (totalRewardPool * validatorStake[v]) / honestStake;
                    pendingReward[v] += reward;
                    totalRewarded += reward;
                    emit RewardEarned(marketId, v, reward);
                }
                unchecked { ++i; }
            }
        }

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
        return "TestcaseResolverV3";
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

    /* ------------- internal ------------- */

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
