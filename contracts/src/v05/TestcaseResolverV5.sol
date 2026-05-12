// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";
import {IResolverSubscriptionReceiver} from "../v04/IResolverSubscriptionReceiver.sol";

/// @title  TestcaseResolverV5
/// @notice v0.5 of the validator network resolver. Two material additions:
///
///         (1) **Commit-reveal voting.** Validators now `commitVote(marketId,
///             voteHash)` during a commit phase (first 30 min), then
///             `revealVote(marketId, score, salt)` during a reveal phase
///             (next 30 min). The commit hash is
///             `keccak256(abi.encode(scoreBps, salt, marketId, msg.sender))`.
///             A validator cannot copy others' votes because hashes leak no
///             information (random salt). This eliminates the v0.4
///             front-running / vote-copying risk.
///
///         (2) **Configurable MIN_STAKE.** Constructor takes
///             `_minStake` so mainnet deployments can pick 1+ USDC while
///             testnet keeps 0.1 USDC. All other constants are unchanged.
///
///         Carries over all v0.4 mechanics: subscription pool with
///         MasterChef accumulator, 40% voting weight cap, ERC-8004
///         reputation events, slashing on distance-from-median,
///         pendingVotes guard, dispute reward pool.
///
/// @dev    State machine per market:
///           None         -> CommitOpen      (first commitVote)
///           CommitOpen   -> RevealOpen      (block.timestamp > commitDeadline)
///           RevealOpen   -> Resolvable      (block.timestamp > revealDeadline)
///
///         A market with zero revealed votes after revealDeadline will
///         revert in resolve() with NoVotes. The integrating market
///         contract is expected to expose a force-resolve-default path
///         for this case.
///
/// @dev    pendingVotes is incremented on REVEAL (not commit), because
///         only revealed votes commit the validator to a market outcome.
///         A validator who commits but doesn't reveal is not locked.
contract TestcaseResolverV5 is IResolver, IResolverFeeReceiver, IResolverSubscriptionReceiver, ReentrancyGuard {
    /* ------------- configurable constants ------------- */

    /// @notice Minimum stake required to vote. Set at deploy time.
    uint256 public immutable MIN_STAKE;

    /* ------------- fixed constants ------------- */

    uint64  public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Total voting window split: COMMIT_WINDOW + REVEAL_WINDOW = 1 hour total.
    uint64  public constant COMMIT_WINDOW = 30 minutes;
    uint64  public constant REVEAL_WINDOW = 30 minutes;

    uint256 public constant TOLERANCE_BPS = 1500;
    uint256 public constant MAX_SLASH_BPS = 1000;
    uint256 public constant MAX_VOTING_WEIGHT_BPS = 4000;
    uint256 private constant ACC_PRECISION = 1e18;

    constructor(uint256 _minStake) {
        require(_minStake > 0, "minStake must be > 0");
        MIN_STAKE = _minStake;
    }

    /* ------------- validator pool ------------- */

    mapping(address => uint256) public validatorStake;
    uint256 public totalStake;

    mapping(address => uint256) public pendingVotes;
    mapping(address => uint256) public unstakeRequestedAmount;
    mapping(address => uint64)  public unstakeReadyAt;

    /* ------------- subscription pool (MasterChef-style) ------------- */

    uint256 public accSubscriptionPerStake;
    mapping(address => uint256) public subscriptionDebt;
    mapping(address => uint256) public pendingSubscriptionReward;
    uint256 public totalSubscriptionReceived;

    /* ------------- per-market state ------------- */

    struct Market {
        uint64  commitDeadline;
        uint64  revealDeadline;
        uint16  finalScoreBps;
        bool    resolved;
        uint256 feePool;
    }

    mapping(bytes32 => Market) private _markets;

    /// @notice Commit hash for each (marketId, validator). Cleared on reveal.
    mapping(bytes32 => mapping(address => bytes32)) public voteCommit;

    /// @notice Revealed score for each (marketId, validator). Set on reveal.
    mapping(bytes32 => mapping(address => uint16)) public votes;
    mapping(bytes32 => mapping(address => bool))   public hasRevealed;

    /// @notice Voters who have REVEALED their vote (used in resolve).
    mapping(bytes32 => address[]) private _voters;

    /// @notice Dispute reward pool (separate from subscription).
    mapping(address => uint256) public pendingReward;

    /* ------------- events ------------- */

    event Staked(address indexed validator, uint256 amount, uint256 newStake);
    event UnstakeRequested(address indexed validator, uint256 amount, uint64 readyAt);
    event Unstaked(address indexed validator, uint256 amount);

    /// @notice v0.5: validator committed a hashed vote.
    event VoteCommitted(bytes32 indexed marketId, address indexed validator);

    /// @notice v0.5: validator revealed their committed vote.
    event VoteRevealed(bytes32 indexed marketId, address indexed validator, uint16 scoreBps);

    event MarketResolved(bytes32 indexed marketId, uint16 finalScoreBps, uint256 voters, uint256 totalSlashed, uint256 totalRewarded);
    event ValidatorSlashed(bytes32 indexed marketId, address indexed validator, uint256 amount, uint256 distance);
    event RewardEarned(bytes32 indexed marketId, address indexed validator, uint256 amount);
    event RewardClaimed(address indexed validator, uint256 amount);
    event FeeReceived(bytes32 indexed marketId, uint256 amount);

    event SubscriptionReceived(uint256 amount, uint256 newAccPerStake);
    event SubscriptionClaimed(address indexed validator, uint256 amount);
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
    error CommitWindowClosed();
    error RevealWindowNotOpen();
    error RevealWindowClosed();
    error AlreadyCommitted();
    error NoCommit();
    error WrongReveal();
    error AlreadyRevealed();
    error AlreadyResolved();
    error NoVotes();
    error NotReady();
    error PendingUnstake();
    error TransferFailed();
    error PendingVotes(uint256 count);

    /* ------------- internal: accumulator ------------- */

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
        subscriptionDebt[msg.sender] = (validatorStake[msg.sender] * accSubscriptionPerStake) / ACC_PRECISION;
        emit Unstaked(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /* ------------- commit-reveal voting ------------- */

    /// @notice Hash that a validator must compute and submit during the
    ///         commit phase. Includes msg.sender and marketId so a commit
    ///         can't be replayed across markets or by another address.
    function computeVoteHash(uint16 scoreBps, bytes32 salt, bytes32 marketId, address voter)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(scoreBps, salt, marketId, voter));
    }

    function commitVote(bytes32 marketId, bytes32 voteHash) external {
        if (validatorStake[msg.sender] < MIN_STAKE) revert InsufficientStake();
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (voteCommit[marketId][msg.sender] != bytes32(0)) revert AlreadyCommitted();

        if (m.commitDeadline == 0) {
            // Bootstrap windows on first commit.
            m.commitDeadline = uint64(block.timestamp) + COMMIT_WINDOW;
            m.revealDeadline = m.commitDeadline + REVEAL_WINDOW;
        } else if (block.timestamp > m.commitDeadline) {
            revert CommitWindowClosed();
        }

        voteCommit[marketId][msg.sender] = voteHash;
        emit VoteCommitted(marketId, msg.sender);
    }

    function revealVote(bytes32 marketId, uint16 scoreBps, bytes32 salt) external {
        if (scoreBps > 10000) revert ScoreOutOfRange();
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.commitDeadline == 0 || block.timestamp <= m.commitDeadline) revert RevealWindowNotOpen();
        if (block.timestamp > m.revealDeadline) revert RevealWindowClosed();

        bytes32 stored = voteCommit[marketId][msg.sender];
        if (stored == bytes32(0)) revert NoCommit();
        if (hasRevealed[marketId][msg.sender]) revert AlreadyRevealed();
        if (computeVoteHash(scoreBps, salt, marketId, msg.sender) != stored) revert WrongReveal();

        votes[marketId][msg.sender] = scoreBps;
        hasRevealed[marketId][msg.sender] = true;
        _voters[marketId].push(msg.sender);
        pendingVotes[msg.sender] += 1;
        emit VoteRevealed(marketId, msg.sender, scoreBps);
    }

    /* ------------- fee + subscription intakes ------------- */

    function notifyFee(bytes32 marketId) external payable {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        m.feePool += msg.value;
        emit FeeReceived(marketId, msg.value);
    }

    function notifyValidatorSubscription() external payable {
        if (msg.value == 0) return;
        if (totalStake > 0) {
            accSubscriptionPerStake += (msg.value * ACC_PRECISION) / totalStake;
        }
        totalSubscriptionReceived += msg.value;
        emit SubscriptionReceived(msg.value, accSubscriptionPerStake);
    }

    /* ------------- IResolver interface ------------- */

    function canResolve(bytes32 marketId) external view returns (bool) {
        Market storage m = _markets[marketId];
        if (m.resolved) return false;
        if (m.revealDeadline == 0) return false;
        if (block.timestamp <= m.revealDeadline) return false;
        return _voters[marketId].length > 0;
    }

    function resolve(bytes32 marketId, bytes calldata) external returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.revealDeadline == 0 || block.timestamp <= m.revealDeadline) revert RevealWindowClosed();
        address[] storage vs = _voters[marketId];
        uint256 len = vs.length;
        if (len == 0) revert NoVotes();

        // Pass 1: compute totalVoterStake for cap
        uint256 totalVoterStake = 0;
        for (uint256 i = 0; i < len;) {
            totalVoterStake += validatorStake[vs[i]];
            unchecked { ++i; }
        }
        uint256 effectiveCap = (totalVoterStake * MAX_VOTING_WEIGHT_BPS) / 10000;

        // Pass 2: insertion sort with capped weights
        uint16[]  memory sortedVotes  = new uint16[](len);
        uint256[] memory sortedStakes = new uint256[](len);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint16 vote_ = votes[marketId][v];
            uint256 stk = validatorStake[v];
            if (stk > effectiveCap) stk = effectiveCap;
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

        // Pass 3: stake-weighted median
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

        // Pass 4: slash outliers + collect honest stake
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

        // Pass 5: distribute feePool + slashed
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

    /* ------------- claims ------------- */

    function claimRewards() external nonReentrant returns (uint256) {
        uint256 amount = pendingReward[msg.sender];
        if (amount == 0) revert ZeroAmount();
        pendingReward[msg.sender] = 0;
        emit RewardClaimed(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        return amount;
    }

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

    function earnedSubscription(address v) external view returns (uint256) {
        uint256 stk = validatorStake[v];
        uint256 owed = (stk * accSubscriptionPerStake) / ACC_PRECISION;
        uint256 debt = subscriptionDebt[v];
        uint256 settled = pendingSubscriptionReward[v];
        if (owed > debt) return settled + (owed - debt);
        return settled;
    }

    /* ------------- views ------------- */

    function name() external pure returns (string memory) {
        return "TestcaseResolverV5";
    }

    function getMarket(bytes32 marketId)
        external
        view
        returns (uint64 commitDeadline, uint64 revealDeadline, uint16 finalScoreBps, bool resolved, uint256 voterCount, uint256 feePool)
    {
        Market storage m = _markets[marketId];
        return (m.commitDeadline, m.revealDeadline, m.finalScoreBps, m.resolved, _voters[marketId].length, m.feePool);
    }

    function getVoters(bytes32 marketId) external view returns (address[] memory) {
        return _voters[marketId];
    }

    /* ------------- internal helpers ------------- */

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
