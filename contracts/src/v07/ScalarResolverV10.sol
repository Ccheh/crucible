// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";
import {IResolverSubscriptionReceiver} from "../v04/IResolverSubscriptionReceiver.sol";

/// @title  ScalarResolverV10
/// @notice **VALUE-WEIGHTED CALIBRATION** — closes the calibration-farming
///         vector demonstrated against ScalarResolverV9. V9 moved a validator's
///         calibration by a FIXED step on every resolved market, so a cartel
///         could manufacture a high accuracy record by voting with itself on
///         dust-sized throwaway markets, then use that earned weight to swing a
///         real one (`test_limitation_farmedCartelBeatsFreshHonest`).
///
///         V10 ties the calibration step to the market's ECONOMIC WEIGHT: the
///         step scales with the market's resolver fee (`feePool`, a fixed bps
///         cut of escrow, hence a faithful proxy for the value the market
///         settled), capped at one full `CALIB_STEP` per market. A dust market
///         (fee below `CALIB_FEE_REFERENCE`) moves calibration only fractionally;
///         a near-zero-fee market moves it ~not at all. Farming therefore stops
///         being free: to earn a full step a cartel must route real escrow
///         through a real-value market, per step. (HONEST residual below.)
///
///         Everything else is ScalarResolverV9: vote weight = stake scaled by an
///         on-chain, EARNED accuracy track record (calibration) — not stake
///         alone. A fresh/sybil identity's capital counts for little until it
///         earns a record by voting accurately: a self-contained, durable
///         sybil & bribery deterrent that needs NO external reputation registry.
///         (Calibration is the forecasting-skill measure prediction markets use,
///         brought on-chain as the resolution weight.)
///
///         HONEST RESIDUAL: value-weighting kills the CHEAP dust-spam farm. It
///         does not make a CAPITALISED self-dealing cartel impossible — a cartel
///         that routes real escrow through markets it fully controls recovers
///         most of that value (the resolver fee flows back to its own voting
///         validators), so its true cost is gas + capital lockup + the
///         commit/reveal time per market, not the fee itself. The deeper fix —
///         crediting calibration only for agreement with validators OUTSIDE the
///         voter's recent cohort (cohort-diversity) — is the next milestone.
///         The v0.7 generalized, stake-weighted, commit-reveal Schelling
///         resolver returning a CONTINUOUS score in [0, 10000], with
///         STAKER-PARTICIPANT DECOUPLING (a market's service and agent cannot
///         vote on it) — now extended so decoupling can be enforced at the
///         ERC-8004 **identity** level, not only the literal address.
///
///         A validator (or participant) may `linkIdentity(agentId)` to bind its
///         address to an ERC-8004 agentId it owns or operates. When a market is
///         disputed, the participants' linked identities are barred, so every
///         address an identity controls is decoupled — not just the one address
///         the market named.
///
///         HONEST SCOPE: this stops a participant voting from a DIFFERENT
///         address of the SAME linked identity. It does NOT stop an adversary
///         who votes from a fresh, unlinked identity — that residual sybil risk
///         is bounded by stake + slashing today, and is the target of
///         reputation-weighted voting (a later milestone). With
///         IDENTITY_REGISTRY == address(0) the contract behaves exactly like
///         v0.7 (address-level decoupling only).
///
///         All v0.7 mechanics preserved: commit-reveal, stake-weighted median
///         with a 40% voting-weight cap, distance-from-median slashing,
///         subscription pool, the onDispute window-denial fix, ERC-8004
///         reputation events, 7-day cooldown, pendingVotes guard.
///
/// @dev    Decoupling is enforced at COMMIT and REVEAL time via
///         `effectiveConflict`. Voting windows are opened by the bound market
///         in `onDispute` (not bootstrapped by the first commit), which closes
///         a window-denial bypass — see `onDispute`.
interface IERC8004Identity {
    function ownerOf(uint256 agentId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

contract ScalarResolverV10 is IResolver, IResolverFeeReceiver, IResolverSubscriptionReceiver, ReentrancyGuard {
    /* ------------- configurable constants ------------- */

    /// @notice Minimum stake required to vote. Set at deploy time.
    uint256 public immutable MIN_STAKE;

    /// @notice The only contract permitted to register market conflicts —
    ///         the CrucibleMarket deployment this resolver serves. Immutable,
    ///         so the contract stays admin-keyless (no owner can re-point it).
    address public immutable AUTHORIZED_MARKET;

    /* ------------- fixed constants ------------- */

    uint64  public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Total voting window split: COMMIT_WINDOW + REVEAL_WINDOW = 1 hour total.
    uint64  public constant COMMIT_WINDOW = 30 minutes;
    uint64  public constant REVEAL_WINDOW = 30 minutes;

    uint256 public constant TOLERANCE_BPS = 1500;
    uint256 public constant MAX_SLASH_BPS = 1000;
    uint256 public constant MAX_VOTING_WEIGHT_BPS = 4000;
    uint256 private constant ACC_PRECISION = 1e18;

    /// @notice conflicted[marketId][party] == true => party is a participant
    ///         in this market and may not vote on it (address-level decoupling).
    ///         Set only by AUTHORIZED_MARKET via onDispute.
    mapping(bytes32 => mapping(address => bool)) public conflicted;

    /// @notice Optional ERC-8004 IdentityRegistry. address(0) disables identity
    ///         features (pure address-level decoupling, identical to v0.7).
    address public immutable IDENTITY_REGISTRY;

    /// @notice The ERC-8004 agentId an address has linked (0 == none).
    mapping(address => uint256) public linkedAgentId;
    mapping(address => bool)    public hasLinkedIdentity;

    /// @notice conflictedAgentId[marketId][agentId] => every address linked to
    ///         this identity is barred from voting on marketId.
    mapping(bytes32 => mapping(uint256 => bool)) public conflictedAgentId;

    /* ------------- calibration (earned-accuracy) weighting ------------- */

    uint256 public constant CALIB_MIN   = 2000;   // floor  => 0.25x weight
    uint256 public constant CALIB_START = 4000;   // fresh  => 0.50x weight
    uint256 public constant CALIB_MAX   = 12000;  // proven => 1.50x weight
    uint256 public constant CALIB_STEP  = 1000;   // FULL per-market adjustment
    uint256 public constant CALIB_SCALE = 8000;   // weight = stake * calib / SCALE

    /// @notice V10: the market resolver-fee (`feePool`) at which a market grants
    ///         a FULL `CALIB_STEP`. A market's actual step is
    ///         `CALIB_STEP * min(feePool, REF) / REF`, so dust markets move
    ///         calibration only fractionally and a ~zero-fee market not at all —
    ///         this is what makes calibration-farming cost real economic value
    ///         per step instead of being free. Set at deploy; immutable so the
    ///         contract stays admin-keyless. `0` DISABLES value-weighting (every
    ///         market grants a full step, i.e. identical to ScalarResolverV9) —
    ///         useful only for differential testing, never for production.
    uint256 public immutable CALIB_FEE_REFERENCE;

    /// @notice On-chain accuracy track record (0 == never resolved => START).
    ///         Honest votes raise it toward CALIB_MAX, outliers lower it toward
    ///         CALIB_MIN. Vote weight = stake * calibration / CALIB_SCALE, so a
    ///         fresh sybil identity's capital counts for little until it earns a
    ///         record by voting accurately — with NO external reputation needed.
    mapping(address => uint256) public calibration;

    event CalibrationUpdated(address indexed validator, bytes32 indexed marketId, uint256 newCalibration, bool honest);

    constructor(
        uint256 _minStake,
        address _authorizedMarket,
        address _identityRegistry,
        uint256 _calibFeeReference
    ) {
        require(_minStake > 0, "minStake must be > 0");
        require(_authorizedMarket != address(0), "market zero");
        MIN_STAKE = _minStake;
        AUTHORIZED_MARKET = _authorizedMarket;
        IDENTITY_REGISTRY = _identityRegistry; // may be address(0) to disable
        CALIB_FEE_REFERENCE = _calibFeeReference; // 0 => value-weighting disabled
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
    error ConflictedParty();
    error NotAuthorizedMarket();
    error VotingNotOpen();
    error VotingAlreadyOpen();
    error IdentityRegistryNotSet();
    error NotIdentityOwnerOrOperator();

    /* ------------- dispute hook: open voting + decouple participants ------------- */

    event ConflictRegistered(bytes32 indexed marketId, address indexed party);
    event VotingOpened(bytes32 indexed marketId, uint64 commitDeadline, uint64 revealDeadline);

    /// @notice Bound-market hook fired the moment a market is disputed. It
    ///         (1) OPENS the commit/reveal windows and (2) registers the
    ///         market's participants (service, agent) as conflicted — both
    ///         atomically, callable ONLY by AUTHORIZED_MARKET.
    /// @dev    Opening the window HERE, rather than bootstrapping it on the
    ///         first commit, closes a window-denial bypass of decoupling: a
    ///         participant who knows marketId = keccak(service, agent, nonce)
    ///         in advance could otherwise pre-commit to start (and run out)
    ///         the commit clock BEFORE the dispute — and its conflict
    ///         registration — landed, leaving honest validators unable to
    ///         commit, the market stale, and forceResolveStale settling in the
    ///         participant's own favor (scoreBps = 10000). The zero address is
    ///         ignored, so opening voting without conflicts is a valid call.
    function onDispute(bytes32 marketId, address a, address b) external {
        if (msg.sender != AUTHORIZED_MARKET) revert NotAuthorizedMarket();
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.commitDeadline != 0) revert VotingAlreadyOpen();

        uint64 cd = uint64(block.timestamp) + COMMIT_WINDOW;
        m.commitDeadline = cd;
        m.revealDeadline = cd + REVEAL_WINDOW;
        emit VotingOpened(marketId, cd, m.revealDeadline);

        _registerParticipant(marketId, a);
        _registerParticipant(marketId, b);
    }

    /// @notice Bar a participant from a market: its literal address AND, if it
    ///         has linked an ERC-8004 identity, every address that identity
    ///         controls (identity-level decoupling).
    function _registerParticipant(bytes32 marketId, address who) internal {
        if (who == address(0)) return;
        if (!conflicted[marketId][who]) {
            conflicted[marketId][who] = true;
            emit ConflictRegistered(marketId, who);
        }
        if (hasLinkedIdentity[who]) {
            conflictedAgentId[marketId][linkedAgentId[who]] = true;
        }
    }

    /* ------------- ERC-8004 identity binding (M2) ------------- */

    event IdentityLinked(address indexed who, uint256 indexed agentId);

    /// @notice Link msg.sender to an ERC-8004 agentId it owns or operates, so
    ///         identity-level decoupling can bar every address the identity
    ///         controls. See contract NatSpec for the honest scope.
    function linkIdentity(uint256 agentId) external {
        if (IDENTITY_REGISTRY == address(0)) revert IdentityRegistryNotSet();
        address owner = IERC8004Identity(IDENTITY_REGISTRY).ownerOf(agentId);
        if (owner != msg.sender && !IERC8004Identity(IDENTITY_REGISTRY).isApprovedForAll(owner, msg.sender)) {
            revert NotIdentityOwnerOrOperator();
        }
        linkedAgentId[msg.sender] = agentId;
        hasLinkedIdentity[msg.sender] = true;
        emit IdentityLinked(msg.sender, agentId);
    }

    /// @notice True if `who` may not vote on `marketId` — barred as a literal
    ///         address OR via a conflicted linked identity.
    function effectiveConflict(bytes32 marketId, address who) public view returns (bool) {
        if (conflicted[marketId][who]) return true;
        return hasLinkedIdentity[who] && conflictedAgentId[marketId][linkedAgentId[who]];
    }

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
        if (effectiveConflict(marketId, msg.sender)) revert ConflictedParty();
        if (validatorStake[msg.sender] < MIN_STAKE) revert InsufficientStake();
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (voteCommit[marketId][msg.sender] != bytes32(0)) revert AlreadyCommitted();

        // Windows are opened by the bound market at dispute time (onDispute),
        // NOT bootstrapped by the first commit — see onDispute for why this
        // closes a window-denial bypass of staker-participant decoupling.
        if (m.commitDeadline == 0) revert VotingNotOpen();
        if (block.timestamp > m.commitDeadline) revert CommitWindowClosed();

        voteCommit[marketId][msg.sender] = voteHash;
        emit VoteCommitted(marketId, msg.sender);
    }

    function revealVote(bytes32 marketId, uint16 scoreBps, bytes32 salt) external {
        if (effectiveConflict(marketId, msg.sender)) revert ConflictedParty();
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

    /// @notice Effective calibration in [CALIB_MIN, CALIB_MAX]; 0 storage maps
    ///         to CALIB_START so a never-resolved validator starts at 0.50x.
    function effectiveCalibration(address v) public view returns (uint256) {
        uint256 c = calibration[v];
        return c == 0 ? CALIB_START : c;
    }

    /// @notice Calibration-weighted vote weight: stake scaled by earned accuracy.
    function voteWeight(address v) public view returns (uint256) {
        return (validatorStake[v] * effectiveCalibration(v)) / CALIB_SCALE;
    }

    /// @notice V10: the calibration step this market grants, scaled by its
    ///         economic weight. `CALIB_STEP * min(feePool, REF) / REF`, capped at
    ///         one full step. Returns a FULL step when value-weighting is
    ///         disabled (REF == 0). This is the anti-farming core: a dust market
    ///         (feePool << REF) yields a near-zero step, so manufacturing a
    ///         calibration record on throwaway markets earns ~nothing.
    function calibrationStepFor(uint256 marketFee) public view returns (uint256) {
        if (CALIB_FEE_REFERENCE == 0) return CALIB_STEP; // value-weighting disabled
        uint256 capped = marketFee > CALIB_FEE_REFERENCE ? CALIB_FEE_REFERENCE : marketFee;
        return (CALIB_STEP * capped) / CALIB_FEE_REFERENCE;
    }

    /// @dev Calibration moves by a VALUE-WEIGHTED `step` (see calibrationStepFor).
    ///      A step of 0 (a ~zero-fee market) leaves calibration untouched — both
    ///      up and down — so dust markets carry no calibration signal at all.
    ///      This closes the V9 dust-spam farming vector
    ///      (`test_limitation_farmedCartelBeatsFreshHonest`). HONEST residual: a
    ///      CAPITALISED cartel routing real escrow through self-dealt markets can
    ///      still farm (it recovers most of the fee via its own validators); the
    ///      deeper fix is cohort-diversity crediting — next milestone.
    function _updateCalibration(address v, bool honest, bytes32 marketId, uint256 step) internal {
        if (step == 0) return; // dust market: no calibration signal
        uint256 c = effectiveCalibration(v);
        uint256 nc;
        if (honest) {
            nc = c + step;
            if (nc > CALIB_MAX) nc = CALIB_MAX;
        } else {
            nc = c <= CALIB_MIN + step ? CALIB_MIN : c - step;
        }
        calibration[v] = nc;
        emit CalibrationUpdated(v, marketId, nc, honest);
    }

    function resolve(bytes32 marketId, bytes calldata) external returns (uint256) {
        Market storage m = _markets[marketId];
        if (m.resolved) revert AlreadyResolved();
        if (m.revealDeadline == 0 || block.timestamp <= m.revealDeadline) revert RevealWindowClosed();
        address[] storage vs = _voters[marketId];
        uint256 len = vs.length;
        if (len == 0) revert NoVotes();

        // Pass 1: total CALIBRATION-WEIGHTED voter weight (for the cap).
        uint256 totalVoterWeight = 0;
        for (uint256 i = 0; i < len;) {
            totalVoterWeight += voteWeight(vs[i]);
            unchecked { ++i; }
        }
        uint256 effectiveCap = (totalVoterWeight * MAX_VOTING_WEIGHT_BPS) / 10000;

        // Pass 2: insertion sort by vote, with capped calibration weights.
        uint16[]  memory sortedVotes   = new uint16[](len);
        uint256[] memory sortedWeights = new uint256[](len);
        uint256 totalWeight = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint16 vote_ = votes[marketId][v];
            uint256 w = voteWeight(v);
            if (w > effectiveCap) w = effectiveCap;
            totalWeight += w;
            uint256 j = i;
            while (j > 0 && sortedVotes[j - 1] > vote_) {
                sortedVotes[j]   = sortedVotes[j - 1];
                sortedWeights[j] = sortedWeights[j - 1];
                unchecked { --j; }
            }
            sortedVotes[j]   = vote_;
            sortedWeights[j] = w;
            unchecked { ++i; }
        }

        // Pass 3: CALIBRATION-weighted median (accuracy decides, not capital).
        uint256 threshold = totalWeight / 2;
        uint256 cumulative = 0;
        uint16 finalScoreBps = 0;
        for (uint256 i = 0; i < len;) {
            cumulative += sortedWeights[i];
            if (cumulative >= threshold) {
                finalScoreBps = sortedVotes[i];
                break;
            }
            unchecked { ++i; }
        }

        // Pass 4: slash outliers (on STAKE) + collect honest WEIGHT.
        uint256 totalSlashed = 0;
        uint256 honestWeight = 0;
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint256 stk = validatorStake[v];
            uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));

            if (pendingVotes[v] > 0) pendingVotes[v] -= 1;

            if (distance <= TOLERANCE_BPS) {
                honestWeight += voteWeight(v);
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

        // Pass 5: distribute feePool + slashed by calibration-weighted honest weight.
        uint256 totalRewardPool = m.feePool + totalSlashed;
        uint256 totalRewarded = 0;
        if (totalRewardPool > 0 && honestWeight > 0) {
            for (uint256 i = 0; i < len;) {
                address v = vs[i];
                uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));
                if (distance <= TOLERANCE_BPS) {
                    uint256 reward = (totalRewardPool * voteWeight(v)) / honestWeight;
                    pendingReward[v] += reward;
                    totalRewarded += reward;
                    emit RewardEarned(marketId, v, reward);
                }
                unchecked { ++i; }
            }
        }

        // Pass 6: UPDATE each voter's calibration from this market's accuracy,
        //         by a VALUE-WEIGHTED step (V10): the step scales with this
        //         market's economic weight (resolver fee), so dust markets carry
        //         ~no calibration signal and farming costs real value per step.
        //         Done AFTER weighting + reward, so it affects FUTURE markets
        //         only and never retroactively changes this resolution.
        uint256 calibStep = calibrationStepFor(m.feePool);
        for (uint256 i = 0; i < len;) {
            address v = vs[i];
            uint256 distance = _abs(int256(uint256(votes[marketId][v])) - int256(uint256(finalScoreBps)));
            _updateCalibration(v, distance <= TOLERANCE_BPS, marketId, calibStep);
            unchecked { ++i; }
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
        return "ScalarResolverV10";
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
