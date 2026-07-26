// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";
import {IResolverSubscriptionReceiver} from "../v04/IResolverSubscriptionReceiver.sol";

/// @notice Hook the market fires on the resolver when a market is disputed:
///         opens the resolver's voting windows AND registers the market's
///         participants as conflicted (staker-participant decoupling), so the
///         window cannot be pre-opened/denied before the conflict lands.
interface IResolverHook {
    function onDispute(bytes32 marketId, address a, address b) external;
}

/// @title  CrucibleMarketV7
/// @notice v0.7 of the graded-resolution settlement market. Two material
///         additions over v0.6, both aimed at the failure modes optimistic
///         oracles (UMA et al.) bleed on:
///
///         (1) **Pre-committed, machine-checkable resolution criteria.**
///             A market now carries a `criteriaHash` SEPARATE from the
///             deliverable commitment (`commitmentHash`). The criteria — the
///             rubric by which the score is judged — are fixed and signed at
///             open time, so resolution cannot be litigated against
///             retroactively re-interpreted rules (the ambiguity that decided
///             the June-2026 $60M MSTR/UMA dispute). Off-chain validators
///             score the deliverable strictly against `criteriaHash`.
///
///         (2) **Typed dispute taxonomy + staker-participant decoupling.**
///             The disputer must declare a `DisputeKind` (Objective or
///             Intersubjective), recorded and emitted on-chain so the
///             resolution lens is explicit and not negotiable after the fact.
///             At dispute time the market also registers (service, agent) with
///             the resolver as conflicted parties; if the resolver supports it
///             (the canonical ScalarResolverV7 does), they are barred from
///             voting on their own market. `decouplingActive` records whether
///             that guarantee is in force for the market.
///
///         All v0.6 mechanics preserved: per-market disputeBondBps, optimistic
///         + disputed settlement math, resolver fee + validator subscription
///         routing, force-resolve of stuck markets, ServiceReputation events.
///         EIP-712 domain bumps to "7" and the OpenAuth typehash gains
///         `criteriaHash`, so v0.6 and v0.7 signatures cannot cross-replay.
contract CrucibleMarketV7 is EIP712, ReentrancyGuard {
    /* ---------- protocol constants ---------- */

    uint256 public constant RESOLVER_FEE_BPS = 200;
    uint256 public constant VALIDATOR_SUBSCRIPTION_BPS = 10;
    uint256 public constant MIN_DISPUTE_BOND_BPS = 100;
    uint256 public constant MAX_DISPUTE_BOND_BPS = 5000;

    /// @notice Time (from dispute moment) after which anyone can force-settle
    ///         a stuck disputed market at scoreBps=10000.
    uint256 public constant STALE_RESOLVE_GRACE = 24 hours;

    /* ---------- service bond pool ---------- */

    mapping(address service => uint256) public bondPool;
    mapping(address service => uint256) public bondLocked;
    mapping(address service => mapping(address resolver => bool)) public resolverAllowed;

    /* ---------- markets ---------- */

    enum Status { None, Open, Disputed, Resolved }

    /// @notice The lens under which a dispute is to be judged. Declared by the
    ///         disputer and fixed on-chain. Unspecified is rejected.
    enum DisputeKind { Unspecified, Objective, Intersubjective }

    struct Market {
        address service;
        address agent;
        address resolver;
        uint256 agentEscrow;
        uint256 bondLocked;
        uint256 disputeBond;
        uint16  disputeBondBps;
        bytes32 commitmentHash;   // commitment to the DELIVERABLE
        bytes32 criteriaHash;     // v0.7: commitment to the RESOLUTION CRITERIA
        uint64  disputeDeadline;
        uint64  disputedAt;
        uint16  scoreBps;
        Status  status;
        DisputeKind disputeKind;  // v0.7: typed dispute lens (set on dispute)
        bool    decouplingActive; // v0.7: was the resolver conflict-aware?
    }

    mapping(bytes32 marketId => Market) public markets;

    /* ---------- EIP-712 OpenAuth (v0.7: adds criteriaHash) ---------- */

    struct OpenAuth {
        address service;
        address agent;
        address resolver;
        uint256 amount;
        uint256 bondLockAmount;
        uint16  disputeBondBps;
        bytes32 commitmentHash;
        bytes32 criteriaHash;
        uint64  disputeWindow;
        uint256 nonce;
        uint256 authExpiry;
    }

    bytes32 private constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,uint16 disputeBondBps,bytes32 commitmentHash,bytes32 criteriaHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
    );

    /* ---------- events ---------- */

    event BondDeposited(address indexed service, uint256 amount, uint256 newPool);
    event BondWithdrawn(address indexed service, uint256 amount, uint256 newPool);
    event ResolverAllowedChanged(address indexed service, address indexed resolver, bool allowed);

    event MarketOpened(
        bytes32 indexed marketId,
        address indexed service,
        address indexed agent,
        address resolver,
        uint256 agentEscrow,
        uint256 bondLocked,
        uint16  disputeBondBps,
        bytes32 commitmentHash,
        bytes32 criteriaHash,
        uint64  disputeDeadline
    );
    event MarketDisputed(
        bytes32 indexed marketId,
        address indexed by,
        uint256 bond,
        uint8   disputeKind,
        bool    decouplingActive
    );
    event MarketResolved(
        bytes32 indexed marketId,
        uint16  scoreBps,
        uint256 paidToService,
        uint256 paidToAgent,
        uint256 bondSlashed,
        uint256 resolverFee,
        uint256 disputeBondToService,
        uint256 validatorSubscription
    );

    event MarketForceResolved(bytes32 indexed marketId, address indexed caller, uint64 stuckSince);

    event ResolverFeePaid(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ResolverFeeReturned(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ValidatorSubscriptionPaid(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ValidatorSubscriptionReturned(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ServiceReputation(address indexed service, bytes32 indexed marketId, uint16 finalScoreBps, uint256 bondSlashed);

    /* ---------- errors ---------- */

    error ZeroAmount();
    error InsufficientBond();
    error ResolverNotAllowed();
    error MarketAlreadyExists();
    error MarketNotOpen();
    error MarketNotDisputed();
    error WindowNotPassed();
    error WindowExpired();
    error AuthExpired();
    error AmountMismatch();
    error InvalidAgent();
    error InvalidSignature();
    error ScoreOutOfRange();
    error ResolverNotReady();
    error TransferFailed();
    error WrongDisputeBond();
    error DisputeBondOutOfRange();
    error StaleGraceNotPassed();
    error ResolverReady();
    error UnspecifiedDisputeKind();

    constructor() EIP712("Crucible", "7") {}

    /* ---------- service: bond + resolver whitelist ---------- */

    function depositBond() external payable {
        if (msg.value == 0) revert ZeroAmount();
        bondPool[msg.sender] += msg.value;
        emit BondDeposited(msg.sender, msg.value, bondPool[msg.sender]);
    }

    function withdrawBond(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 pool = bondPool[msg.sender];
        uint256 locked = bondLocked[msg.sender];
        if (pool < locked + amount) revert InsufficientBond();
        unchecked { bondPool[msg.sender] = pool - amount; }
        emit BondWithdrawn(msg.sender, amount, bondPool[msg.sender]);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    function setResolverAllowed(address resolver, bool allowed) external {
        resolverAllowed[msg.sender][resolver] = allowed;
        emit ResolverAllowedChanged(msg.sender, resolver, allowed);
    }

    function bondAvailable(address service) external view returns (uint256) {
        return bondPool[service] - bondLocked[service];
    }

    function requiredDisputeBond(bytes32 marketId) external view returns (uint256) {
        Market storage m = markets[marketId];
        return (m.agentEscrow * uint256(m.disputeBondBps)) / 10000;
    }

    /* ---------- agent: open a market ---------- */

    function openMarket(OpenAuth calldata auth, bytes calldata signature)
        external
        payable
        nonReentrant
        returns (bytes32 marketId)
    {
        if (auth.amount == 0) revert ZeroAmount();
        if (msg.value != auth.amount) revert AmountMismatch();
        if (auth.agent != msg.sender) revert InvalidAgent();
        if (block.timestamp > auth.authExpiry) revert AuthExpired();
        if (!resolverAllowed[auth.service][auth.resolver]) revert ResolverNotAllowed();
        if (auth.disputeBondBps < MIN_DISPUTE_BOND_BPS || auth.disputeBondBps > MAX_DISPUTE_BOND_BPS) {
            revert DisputeBondOutOfRange();
        }

        bytes32 structHash = keccak256(abi.encode(
            OPEN_AUTH_TYPEHASH,
            auth.service,
            auth.agent,
            auth.resolver,
            auth.amount,
            auth.bondLockAmount,
            auth.disputeBondBps,
            auth.commitmentHash,
            auth.criteriaHash,
            auth.disputeWindow,
            auth.nonce,
            auth.authExpiry
        ));
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (recovered != auth.service) revert InvalidSignature();

        uint256 pool = bondPool[auth.service];
        uint256 locked = bondLocked[auth.service];
        if (pool < locked + auth.bondLockAmount) revert InsufficientBond();
        bondLocked[auth.service] = locked + auth.bondLockAmount;

        marketId = _marketId(auth.service, auth.agent, auth.nonce);
        if (markets[marketId].status != Status.None) revert MarketAlreadyExists();

        uint64 deadline = uint64(block.timestamp) + auth.disputeWindow;
        markets[marketId] = Market({
            service:          auth.service,
            agent:            auth.agent,
            resolver:         auth.resolver,
            agentEscrow:      auth.amount,
            bondLocked:       auth.bondLockAmount,
            disputeBond:      0,
            disputeBondBps:   auth.disputeBondBps,
            commitmentHash:   auth.commitmentHash,
            criteriaHash:     auth.criteriaHash,
            disputeDeadline:  deadline,
            disputedAt:       0,
            scoreBps:         0,
            status:           Status.Open,
            disputeKind:      DisputeKind.Unspecified,
            decouplingActive: false
        });

        emit MarketOpened(
            marketId, auth.service, auth.agent, auth.resolver,
            auth.amount, auth.bondLockAmount, auth.disputeBondBps,
            auth.commitmentHash, auth.criteriaHash, deadline
        );
    }

    /* ---------- dispute ---------- */

    /// @notice Open a dispute, declaring the lens (Objective | Intersubjective)
    ///         under which the deliverable is to be judged against the
    ///         pre-committed `criteriaHash`. Registers the market's participants
    ///         with the resolver so they cannot vote on it.
    function dispute(bytes32 marketId, DisputeKind kind) external payable nonReentrant {
        if (kind == DisputeKind.Unspecified) revert UnspecifiedDisputeKind();
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (msg.sender != m.agent) revert InvalidAgent();
        if (block.timestamp > m.disputeDeadline) revert WindowExpired();

        uint256 expected = (m.agentEscrow * uint256(m.disputeBondBps)) / 10000;
        if (msg.value != expected) revert WrongDisputeBond();

        m.disputeBond = expected;
        m.disputedAt = uint64(block.timestamp);
        m.status = Status.Disputed;
        m.disputeKind = kind;

        // Open the resolver's voting window AND bar the service + agent from
        // voting on this market, atomically. Tolerant of resolvers that don't
        // implement the hook (decouplingActive stays false, no bricking).
        bool decoupled;
        try IResolverHook(m.resolver).onDispute(marketId, m.service, m.agent) {
            decoupled = true;
        } catch {
            decoupled = false;
        }
        m.decouplingActive = decoupled;

        emit MarketDisputed(marketId, msg.sender, expected, uint8(kind), decoupled);
    }

    /* ---------- internal: subscription push ---------- */

    function _pushSubscription(bytes32 marketId, address resolverAddr, uint256 escrow) internal returns (uint256) {
        uint256 sub = (escrow * VALIDATOR_SUBSCRIPTION_BPS) / 10000;
        if (sub == 0) return 0;
        try IResolverSubscriptionReceiver(resolverAddr).notifyValidatorSubscription{value: sub}() {
            emit ValidatorSubscriptionPaid(marketId, resolverAddr, sub);
            return sub;
        } catch {
            emit ValidatorSubscriptionReturned(marketId, resolverAddr, sub);
            return 0;
        }
    }

    /* ---------- resolve ---------- */

    function collectAfterWindow(bytes32 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (block.timestamp <= m.disputeDeadline) revert WindowNotPassed();

        uint256 subPaid = _pushSubscription(marketId, m.resolver, m.agentEscrow);
        uint256 settleEscrow = m.agentEscrow - subPaid;
        _settle(marketId, m, 10000, settleEscrow, 0, subPaid);
    }

    function resolveDisputed(bytes32 marketId, bytes calldata resolverData) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Disputed) revert MarketNotDisputed();
        address resolverAddr = m.resolver;
        if (!IResolver(resolverAddr).canResolve(marketId)) revert ResolverNotReady();

        uint256 subPaid = _pushSubscription(marketId, resolverAddr, m.agentEscrow);
        uint256 resolverFee = (m.agentEscrow * RESOLVER_FEE_BPS) / 10000;
        uint256 feePaid = 0;
        if (resolverFee > 0) {
            try IResolverFeeReceiver(resolverAddr).notifyFee{value: resolverFee}(marketId) {
                feePaid = resolverFee;
                emit ResolverFeePaid(marketId, resolverAddr, resolverFee);
            } catch {
                emit ResolverFeeReturned(marketId, resolverAddr, resolverFee);
            }
        }

        uint256 settleEscrow = m.agentEscrow - subPaid - feePaid;
        uint256 score = IResolver(resolverAddr).resolve(marketId, resolverData);
        if (score > 10000) revert ScoreOutOfRange();

        _settle(marketId, m, uint16(score), settleEscrow, feePaid, subPaid);
    }

    /// @notice Force-settle a stuck disputed market at scoreBps=10000 after the
    ///         stale grace, when the resolver still cannot resolve.
    function forceResolveStale(bytes32 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Disputed) revert MarketNotDisputed();
        if (block.timestamp <= uint256(m.disputedAt) + STALE_RESOLVE_GRACE) revert StaleGraceNotPassed();
        if (IResolver(m.resolver).canResolve(marketId)) revert ResolverReady();

        emit MarketForceResolved(marketId, msg.sender, m.disputedAt);

        uint256 subPaid = _pushSubscription(marketId, m.resolver, m.agentEscrow);
        uint256 settleEscrow = m.agentEscrow - subPaid;
        _settle(marketId, m, 10000, settleEscrow, 0, subPaid);
    }

    /* ---------- internal: settle ---------- */

    function _settle(
        bytes32 marketId,
        Market storage m,
        uint16 scoreBps,
        uint256 settleEscrow,
        uint256 resolverFee,
        uint256 validatorSub
    ) internal {
        uint256 paidToService = (settleEscrow * scoreBps) / 10000;
        uint256 refundEscrowToAgent = settleEscrow - paidToService;

        uint256 bondSlash = (m.bondLocked * (10000 - scoreBps)) / 10000;
        uint256 bondToService = (m.disputeBond * scoreBps) / 10000;
        uint256 bondRefund    = m.disputeBond - bondToService;

        bondLocked[m.service] -= m.bondLocked;
        if (bondSlash > 0) {
            bondPool[m.service] -= bondSlash;
        }

        m.scoreBps = scoreBps;
        m.status = Status.Resolved;

        uint256 totalToService = paidToService + bondToService;
        uint256 totalToAgent   = refundEscrowToAgent + bondSlash + bondRefund;

        emit MarketResolved(marketId, scoreBps, totalToService, totalToAgent, bondSlash, resolverFee, bondToService, validatorSub);
        emit ServiceReputation(m.service, marketId, scoreBps, bondSlash);

        if (totalToService > 0) {
            (bool ok,) = m.service.call{value: totalToService}("");
            if (!ok) revert TransferFailed();
        }
        if (totalToAgent > 0) {
            (bool ok,) = m.agent.call{value: totalToAgent}("");
            if (!ok) revert TransferFailed();
        }
    }

    /* ---------- views ---------- */

    function _marketId(address service, address agent, uint256 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encode(service, agent, nonce));
    }

    function marketIdOf(address service, address agent, uint256 nonce) external pure returns (bytes32) {
        return _marketId(service, agent, nonce);
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
