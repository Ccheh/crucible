// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "./IResolverFeeReceiver.sol";

/// @title  CrucibleMarketV2
/// @notice v0.2 of the per-call prediction-market-settled payment protocol.
///
///         Two material changes over v0:
///
///         (1) **Validator fee routing.** When a market is settled through a
///             dispute (i.e. the resolver actually had to do work to decide
///             the score), a configurable fraction of the agent escrow is
///             siphoned off the top and forwarded to the resolver via
///             `notifyFee(marketId)`. Resolvers that implement
///             `IResolverFeeReceiver` use this stream to fund their validator
///             reward pool. The fee is NEVER charged on the optimistic /
///             no-dispute path, so well-behaved services pay no premium.
///
///         (2) **EIP-712 domain version "2"** ensures signatures cannot
///             cross-replay against v0 markets and vice versa.
///
///         All other semantics (bond pool, resolver whitelist, dispute window,
///         scoreBps math, reentrancy posture) match v0 exactly. The SDK shape
///         and the OpenAuth struct layout are identical, so integrators only
///         need to bump a single addr + EIP-712 version when migrating.
///
/// @dev    Fee math (only on resolveDisputed path):
///           resolverFee     = (agentEscrow * RESOLVER_FEE_BPS) / 10000
///           remainingEscrow = agentEscrow - resolverFee
///           paidToService   = (remainingEscrow * scoreBps) / 10000
///           refundToAgent   = remainingEscrow - paidToService + bondSlash
///
///         The fee is sent BEFORE the service/agent payouts. If the resolver
///         is not a fee receiver (does not implement notifyFee), the fee is
///         returned to the agent — services pick their resolvers, so a
///         non-fee-receiver resolver effectively makes disputes a touch
///         cheaper for the agent.
///
/// @dev    No admin keys, no upgrade proxy, no pause function, no fee owner.
///         The fee parameter is a contract constant baked at deployment time.
contract CrucibleMarketV2 is EIP712, ReentrancyGuard {
    /* ---------- protocol constants ---------- */

    /// @notice Fraction of agent escrow routed to the resolver fee pool on
    ///         disputed-market settlement. 200 bps = 2.00%.
    /// @dev    Immutable for the lifetime of this contract version. To change
    ///         this, deploy v0.3 with a new EIP-712 version.
    uint256 public constant RESOLVER_FEE_BPS = 200;

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
        bytes32 commitmentHash;
        uint64  disputeDeadline;
        uint16  scoreBps;
        Status  status;
    }

    mapping(bytes32 marketId => Market) public markets;

    /* ---------- EIP-712 service authorization ---------- */

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
    event MarketDisputed(bytes32 indexed marketId, address indexed by);
    event MarketResolved(
        bytes32 indexed marketId,
        uint16 scoreBps,
        uint256 paidToService,
        uint256 paidToAgent,
        uint256 bondSlashed,
        uint256 resolverFee
    );
    event ResolverFeePaid(bytes32 indexed marketId, address indexed resolver, uint256 amount);
    event ResolverFeeReturned(bytes32 indexed marketId, address indexed resolver, uint256 amount);

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

    /* ---------- constructor ---------- */

    constructor() EIP712("Crucible", "2") {}

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
            commitmentHash:  auth.commitmentHash,
            disputeDeadline: deadline,
            scoreBps:        0,
            status:          Status.Open
        });

        emit MarketOpened(
            marketId,
            auth.service,
            auth.agent,
            auth.resolver,
            auth.amount,
            auth.bondLockAmount,
            auth.commitmentHash,
            deadline
        );
    }

    /* ---------- dispute path ---------- */

    function dispute(bytes32 marketId) external {
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (msg.sender != m.agent) revert InvalidAgent();
        if (block.timestamp > m.disputeDeadline) revert WindowExpired();
        m.status = Status.Disputed;
        emit MarketDisputed(marketId, msg.sender);
    }

    /* ---------- resolve ---------- */

    /// @notice Optimistic settlement: no dispute raised, service collects fully.
    ///         No resolver fee — the resolver did no work.
    function collectAfterWindow(bytes32 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (block.timestamp <= m.disputeDeadline) revert WindowNotPassed();
        _settle(marketId, m, 10000, m.agentEscrow, 0);
    }

    /// @notice Disputed-market settlement. Pushes the resolver fee to the
    ///         resolver's pool BEFORE calling resolve, so the resolver can
    ///         distribute the fee as part of its in-line reward computation.
    function resolveDisputed(bytes32 marketId, bytes calldata resolverData) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Disputed) revert MarketNotDisputed();
        address resolverAddr = m.resolver;
        if (!IResolver(resolverAddr).canResolve(marketId)) revert ResolverNotReady();

        // 1. Try to push the resolver fee to the resolver BEFORE calling resolve.
        //    If the resolver doesn't implement IResolverFeeReceiver, the fee
        //    stays inside the agent escrow (effectively no validator subsidy).
        uint256 resolverFee = (m.agentEscrow * RESOLVER_FEE_BPS) / 10000;
        uint256 settleEscrow = m.agentEscrow;
        if (resolverFee > 0) {
            try IResolverFeeReceiver(resolverAddr).notifyFee{value: resolverFee}(marketId) {
                settleEscrow = m.agentEscrow - resolverFee;
                emit ResolverFeePaid(marketId, resolverAddr, resolverFee);
            } catch {
                // Resolver rejected the fee — fee stays in the market and is
                // split between service/agent like the regular escrow.
                emit ResolverFeeReturned(marketId, resolverAddr, resolverFee);
            }
        }

        // 2. Now call resolve. The resolver uses any deposited fee to fund
        //    validator rewards in its own logic.
        uint256 score = IResolver(resolverAddr).resolve(marketId, resolverData);
        if (score > 10000) revert ScoreOutOfRange();

        _settle(marketId, m, uint16(score), settleEscrow, m.agentEscrow - settleEscrow);
    }

    /* ---------- internal: settle ---------- */

    function _settle(
        bytes32 marketId,
        Market storage m,
        uint16 scoreBps,
        uint256 settleEscrow,
        uint256 resolverFee
    ) internal {
        // Service / agent split on remaining escrow.
        uint256 paidToService = (settleEscrow * scoreBps) / 10000;
        uint256 refundEscrowToAgent = settleEscrow - paidToService;

        // Bond slashing: proportional to (10000 - scoreBps) on FULL bondLocked.
        uint256 bondSlash = (m.bondLocked * (10000 - scoreBps)) / 10000;

        // Unlock the service's locked bond, then debit slash from pool.
        bondLocked[m.service] -= m.bondLocked;
        if (bondSlash > 0) {
            bondPool[m.service] -= bondSlash;
        }

        m.scoreBps = scoreBps;
        m.status = Status.Resolved;

        uint256 totalToAgent = refundEscrowToAgent + bondSlash;
        emit MarketResolved(marketId, scoreBps, paidToService, totalToAgent, bondSlash, resolverFee);

        if (paidToService > 0) {
            (bool ok,) = m.service.call{value: paidToService}("");
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
