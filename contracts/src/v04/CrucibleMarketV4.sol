// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";
import {IResolverSubscriptionReceiver} from "./IResolverSubscriptionReceiver.sol";

/// @title  CrucibleMarketV4
/// @notice v0.4 of the per-call prediction-market-settled payment protocol.
///         One material change over v0.3:
///
///         **Always-on validator subscription.** On EVERY settlement
///         (optimistic + disputed), `VALIDATOR_SUBSCRIPTION_BPS = 10`
///         (0.10% of agent escrow) is siphoned and routed to the resolver
///         via `notifyValidatorSubscription()`. Resolvers that pool this
///         globally (via MasterChef-style accumulator, see TestcaseResolverV4)
///         give validators a baseline yield from normal protocol operation —
///         independent of the rare dispute path.
///
///         This addresses the most-cited v0.3 economic concern: validators
///         in v0.3 only earned during disputes, which made the equilibrium
///         fragile in healthy markets where disputes are rare.
///
///         All v0.3 mechanics preserved: dispute bond, RESOLVER_FEE_BPS on
///         disputed path, EIP-712 OpenAuth, bond pool, resolver whitelist.
///
/// @dev    Settlement totals on the disputed path:
///           subscription   = agentEscrow * VALIDATOR_SUBSCRIPTION_BPS / 10000
///           resolverFee    = agentEscrow * RESOLVER_FEE_BPS / 10000
///           settleEscrow   = agentEscrow - subscription (if accepted) - resolverFee (if accepted)
///           paidToService  = settleEscrow * scoreBps / 10000
///           refundEscrow   = settleEscrow - paidToService
///           bondSlash      = bondLocked  * (10000 - scoreBps) / 10000
///           bondToService  = disputeBond * scoreBps / 10000
///           bondRefund     = disputeBond - bondToService
///           totalToService = paidToService + bondToService
///           totalToAgent   = refundEscrow + bondSlash + bondRefund
///
/// @dev    Settlement totals on the optimistic path:
///           subscription   = agentEscrow * VALIDATOR_SUBSCRIPTION_BPS / 10000
///           settleEscrow   = agentEscrow - subscription (if accepted)
///           paidToService  = settleEscrow
///           (no fee, no bond, no slash)
///
/// @dev    Domain version bumped to "4".
contract CrucibleMarketV4 is EIP712, ReentrancyGuard {
    /* ---------- protocol constants ---------- */

    /// @notice 2% — fee for disputed-path arbitration. Same as v0.2/v0.3.
    uint256 public constant RESOLVER_FEE_BPS = 200;

    /// @notice 5% — agent's dispute bond. Same as v0.3.
    uint256 public constant DISPUTE_BOND_BPS = 500;

    /// @notice **v0.4 NEW**: 0.10% of every escrow — always-on validator
    ///         subscription. Charged on BOTH optimistic and disputed paths.
    uint256 public constant VALIDATOR_SUBSCRIPTION_BPS = 10;

    /* ---------- service bond pool ---------- */

    mapping(address service => uint256) public bondPool;
    mapping(address service => uint256) public bondLocked;
    mapping(address service => mapping(address resolver => bool)) public resolverAllowed;

    /* ---------- markets ---------- */

    enum Status {
        None,
        Open,
        Disputed,
        Resolved
    }

    struct Market {
        address service;
        address agent;
        address resolver;
        uint256 agentEscrow;
        uint256 bondLocked;
        uint256 disputeBond;
        bytes32 commitmentHash;
        uint64  disputeDeadline;
        uint16  scoreBps;
        Status  status;
    }

    mapping(bytes32 marketId => Market) public markets;

    /* ---------- EIP-712 OpenAuth ---------- */

    struct OpenAuth {
        address service;
        address agent;
        address resolver;
        uint256 amount;
        uint256 bondLockAmount;
        bytes32 commitmentHash;
        uint64  disputeWindow;
        uint256 nonce;
        uint256 authExpiry;
    }

    bytes32 private constant OPEN_AUTH_TYPEHASH = keccak256(
        "OpenAuth(address service,address agent,address resolver,uint256 amount,uint256 bondLockAmount,bytes32 commitmentHash,uint64 disputeWindow,uint256 nonce,uint256 authExpiry)"
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
        bytes32 commitmentHash,
        uint64  disputeDeadline
    );
    event MarketDisputed(bytes32 indexed marketId, address indexed by, uint256 bond);

    /// @notice v0.4: extended event signature includes subscription amount
    ///         (useful for ERC-8004-style reputation indexers).
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
    event ResolverFeePaid(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ResolverFeeReturned(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ValidatorSubscriptionPaid(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ValidatorSubscriptionReturned(bytes32 indexed marketId, address indexed resolver, uint256 amount);

    /// @notice v0.4: ERC-8004-compatible service-reputation event. Emitted
    ///         on every resolution.
    event ServiceReputation(
        address indexed service,
        bytes32 indexed marketId,
        uint16 finalScoreBps,
        uint256 bondSlashed
    );

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

    constructor() EIP712("Crucible", "4") {}

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
        return (markets[marketId].agentEscrow * DISPUTE_BOND_BPS) / 10000;
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

        bytes32 structHash = keccak256(abi.encode(
            OPEN_AUTH_TYPEHASH,
            auth.service,
            auth.agent,
            auth.resolver,
            auth.amount,
            auth.bondLockAmount,
            auth.commitmentHash,
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
            service:         auth.service,
            agent:           auth.agent,
            resolver:        auth.resolver,
            agentEscrow:     auth.amount,
            bondLocked:      auth.bondLockAmount,
            disputeBond:     0,
            commitmentHash:  auth.commitmentHash,
            disputeDeadline: deadline,
            scoreBps:        0,
            status:          Status.Open
        });

        emit MarketOpened(
            marketId, auth.service, auth.agent, auth.resolver,
            auth.amount, auth.bondLockAmount, auth.commitmentHash, deadline
        );
    }

    /* ---------- dispute ---------- */

    function dispute(bytes32 marketId) external payable nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (msg.sender != m.agent) revert InvalidAgent();
        if (block.timestamp > m.disputeDeadline) revert WindowExpired();

        uint256 expected = (m.agentEscrow * DISPUTE_BOND_BPS) / 10000;
        if (msg.value != expected) revert WrongDisputeBond();

        m.disputeBond = expected;
        m.status = Status.Disputed;
        emit MarketDisputed(marketId, msg.sender, expected);
    }

    /* ---------- internal helpers ---------- */

    /// @notice Push subscription to resolver. Returns the amount the
    ///         resolver accepted (0 if not a subscription receiver).
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

    /// @notice Optimistic settlement: service collects full escrow MINUS
    ///         the validator subscription (if resolver accepts).
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

        // 1. Push subscription (always-on, optimistic + disputed).
        uint256 subPaid = _pushSubscription(marketId, resolverAddr, m.agentEscrow);

        // 2. Push resolver fee (disputed only).
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

        // 3. Resolve.
        uint256 score = IResolver(resolverAddr).resolve(marketId, resolverData);
        if (score > 10000) revert ScoreOutOfRange();

        _settle(marketId, m, uint16(score), settleEscrow, feePaid, subPaid);
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
