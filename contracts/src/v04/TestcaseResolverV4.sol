// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";
import {IResolverSubscriptionReceiver} from "./IResolverSubscriptionReceiver.sol";

/// @title  TestcaseResolverV4
/// @notice v0.4 of the validator network resolver. Three material changes:
///
///         (1) **Always-on validator subscription (MasterChef-style).**
///             CrucibleMarketV4 calls `notifyValidatorSubscription()` on
///             EVERY settlement (optimistic + disputed) with ~0.10% of the
///             agent escrow. The fee accumulates in a global pool and is
///             distributed pro-rata to ALL staked validators via the
///             accumulator pattern (accSubscriptionPerStake). Validators
///             now earn a baseline yield even when their specific markets
///             do not see disputes.
///
///         (2) **Stake voting weight cap.** At resolve time, no single
///             validator's effective stake for the median computation
///             exceeds `MAX_VOTING_WEIGHT_BPS = 4000` (40%) of total voter
///             stake. This neuters the >50%-stake attacker who would
///             otherwise dominate the median.
///
///         (3) **ERC-8004 reputation events.** Each resolved market emits
///             `ValidatorReputation(validator, marketId, vote, deviation,
///             slashed)` — a stable schema that off-chain ERC-8004
///             reputation indexers (Circle's stack pushes this) can
///             subscribe to.
///
///         Carries over v0.3 stake-weighted median + v0.2 slashing + fee
///         pool + pendingVotes guard.
///
/// @dev    No admin keys, no upgrade proxy, no fee owner. Standard
///         deployment: deploy fresh; v0.5 will replace if needed.
contract TestcaseResolverV4 is IResolver, IResolverFeeReceiver, IResolverSubscriptionReceiver, ReentrancyGuard {
    /* ------------- constants ------------- */

    uint256 public constant MIN_STAKE = 0.1 ether;
    uint64  public constant UNSTAKE_COOLDOWN = 7 days;
    uint64  public constant VOTING_WINDOW = 1 hours;
    uint256 public constant TOLERANCE_BPS = 1500;
    uint256 public constant MAX_SLASH_BPS = 1000;

    /// @notice Effective voting-weight cap. No single validator's stake counts
    ///         for more than this fraction of total voter stake in median
    ///         computation. 4000 bps = 40%.
    uint256 public constant MAX_VOTING_WEIGHT_BPS = 4000;

    /// @notice Scaling factor for accSubscriptionPerStake. Standard 1e18.
    uint256 private constant ACC_PRECISION = 1e18;

    /* ------------- validator pool ------------- */

    mapping(address => uint256) public validatorStake;
    uint256 public totalStake;

    mapping(address => uint256) public pendingVotes;
    mapping(address => uint256) public unstakeRequestedAmount;
    mapping(address => uint64)  public unstakeReadyAt;

    /* ------------- MasterChef-style global subscription pool ------------- */

    /// @notice Accumulated subscription reward per unit of stake, scaled by
    ///         ACC_PRECISION.
    uint256 public accSubscriptionPerStake;

    /// @notice For each validator, the (stake * accSubscriptionPerStake)
    ///         snapshot at the last time they staked / unstaked / claimed.
    mapping(address => uint256) public subscriptionDebt;

    /// @notice Subscription rewards that have been settled for the
    ///         validator but not yet withdrawn.
    mapping(address => uint256) public pendingSubscriptionReward;

    /// @notice Total subscription value received across all time (for
    ///         transparency).
    uint256 public totalSubscriptionReceived;

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

    /// @notice Pending dispute rewards (separate from subscription rewards).
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

    /// @notice v0.4: subscription fee received.
    event SubscriptionReceived(uint256 amount, uint256 newAccPerStake);

    /// @notice v0.4: subscription reward claimed by a validator.
    event SubscriptionClaimed(address indexed validator, uint256 amount);

    /// @notice v0.4: ERC-8004-compatible per-validator reputation update.
    event ValidatorReputation(
        address indexed validator,
        bytes32 indexed marketId,
        uint16 vote,
        uint256 deviation,
        uint256 slashedAmount,
        bool honest
    );

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

    /* ------------- internal: accumulator settlement ------------- */

    function _settleValidator(address v) internal {
        uint256 stk = validatorStake[v];
        if (stk > 0) {
            uint256 owed = (stk * accSubscriptionPerStake) / ACC_PRECISION;
            uint256 debt = subscriptionDebt[v];
            if (owed > debt) {
                pendingSubscriptionReward[v] += (owed - debt);
            }
        }
        subscriptionDebt[v] = (stk * accSubscriptionPerStake) / ACC_PRECISION;
    }

    /* ------------- validator: stake / unstake ------------- */

    function stake() external payable {
        if (msg.value == 0) revert ZeroAmount();
        if (unstakeRequestedAmount[msg.sender] > 0) revert PendingUnstake();
        _settleValidator(msg.sender);
        validatorStake[msg.sender] += msg.value;
        totalStake += msg.value;
        // Reset debt to the new stake's current accumulator value.
        subscriptionDebt[msg.sender] = (validatorStake[msg.sender] * accSubscriptionPerStake) / ACC_PRECISION;
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

        _settleValidator(msg.sender);

        unstakeRequestedAmount[msg.sender] = 0;
        unstakeReadyAt[msg.sender] = 0;
        if (amount > validatorStake[msg.sender]) amount = validatorStake[msg.sender];
        validatorStake[msg.sender] -= amount;
        totalStake -= amount;
        // Update debt for remaining stake.
        subscriptionDebt[msg.sender] = (validatorStake[msg.sender] * accSubscriptionPerStake) / ACC_PRECISION;
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

    /* ------------- fee intakes ------------- */

    function notifyFee(bytes32 marketId) external payable {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        m.feePool += msg.value;
        emit FeeReceived(marketId, msg.value);
    }

    /// @notice v0.4: always-on validator subscription. Called by
    ///         CrucibleMarketV4 on EVERY settlement.
    function notifyValidatorSubscription() external payable {
        if (msg.value == 0) return;
        if (totalStake > 0) {
            accSubscriptionPerStake += (msg.value * ACC_PRECISION) / totalStake;
        }
        // If totalStake == 0, the value is held in the contract for any
        // future stake to bootstrap from. (Edge case; unlikely on a live
        // network with seeded validators.)
        totalSubscriptionReceived += msg.value;
        emit SubscriptionReceived(msg.value, accSubscriptionPerStake);
    }

    /* ------------- IResolver interface ------------- */

    function canResolve(bytes32 marketId) external view returns (bool) {
        Market storage m = _markets[marketId];
        if (m.resolved) return false;
        if (m.votingDeadline == 0) return false;
        if (block.timestamp <= m.votingDeadline) return false;
        return _voters[marketId].length > 0;
    }

    /// @notice Stake-weighted median with effective-stake cap, then slash
    ///         outliers, then distribute fee + slash to honest validators.
    function resolve(bytes32 marketId, bytes calldata) external returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.votingDeadline == 0 || block.timestamp <= m.votingDeadline) revert WindowClosed();
        address[] storage vs = _voters[marketId];
        uint256 len = vs.length;
        if (len == 0) revert NoVotes();

        // ---------- Pass 1: copy + insertion-sort (vote, effectiveStake) pairs ----------
        // First compute totalVoterStake to derive the per-voter effective cap.
        uint256 totalVoterStake = 0;
        for (uint256 i = 0; i < len;) {
            totalVoterStake += validatorStake[vs[i]];
            unchecked { ++i; }
        }
        uint256 effectiveCap = (totalVoterStake * MAX_VOTING_WEIGHT_BPS) / 10000;

        uint16[]  memory sortedVotes  = new uint16[](len);
        uint256[] memory sortedStakes = new uint256[](len);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint16 vote_ = votes[marketId][v];
            uint256 stk = validatorStake[v];
            if (stk > effectiveCap) stk = effectiveCap;   // v0.4 cap
            totalWeight += stk;

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

        // ---------- Pass 2: stake-weighted median ----------
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

        // ---------- Pass 3: slash outliers + collect honest stake (uses REAL stake) ----------
        uint256 totalSlashed = 0;
        uint256 honestStake = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint256 stk = validatorStake[v];
            uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));

            if (pendingVotes[v] > 0) pendingVotes[v] -= 1;

            if (distance <= TOLERANCE_BPS) {
                honestStake += stk;
                emit ValidatorReputation(v, marketId, votes[marketId][v], distance, 0, true);
            } else {
                uint256 excess = distance - TOLERANCE_BPS;
                uint256 slashBps = (excess * MAX_SLASH_BPS) / (10000 - TOLERANCE_BPS);
                if (slashBps > MAX_SLASH_BPS) slashBps = MAX_SLASH_BPS;
                uint256 slashAmt = (stk * slashBps) / 10000;
                if (slashAmt > 0 && slashAmt <= stk) {
                    // Settle their subscription before mutating their stake.
                    _settleValidator(v);
                    validatorStake[v] -= slashAmt;
                    totalStake -= slashAmt;
                    subscriptionDebt[v] = (validatorStake[v] * accSubscriptionPerStake) / ACC_PRECISION;
                    totalSlashed += slashAmt;
                    emit ValidatorSlashed(marketId, v, slashAmt, distance);
                    emit ValidatorReputation(v, marketId, votes[marketId][v], distance, slashAmt, false);
                } else {
                    emit ValidatorReputation(v, marketId, votes[marketId][v], distance, 0, false);
                }
            }
            unchecked { ++i; }
        }

        // ---------- Pass 4: distribute feePool + slashed to honest ----------
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

    /// @notice v0.4: claim accumulated subscription rewards. Settles the
    ///         accumulator first.
    function claimSubscription() external nonReentrant returns (uint256) {
        _settleValidator(msg.sender);
        uint256 amount = pendingSubscriptionReward[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingSubscriptionReward[msg.sender] = 0;
        emit SubscriptionClaimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        return amount;
    }

    /// @notice View: a validator's earned (but unsettled) subscription
    ///         reward as of right now.
    function earnedSubscription(address v) external view returns (uint256) {
        uint256 stk = validatorStake[v];
        uint256 owed = (stk * accSubscriptionPerStake) / ACC_PRECISION;
        uint256 debt = subscriptionDebt[v];
        uint256 settled = pendingSubscriptionReward[v];
        if (owed > debt) {
            return settled + (owed - debt);
        }
        return settled;
    }

    /* ------------- views ------------- */

    function name() external pure returns (string memory) {
        return "TestcaseResolverV4";
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
