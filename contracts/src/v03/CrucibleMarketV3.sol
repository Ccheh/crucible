// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import {IResolver} from "../interfaces/IResolver.sol";
import {IResolverFeeReceiver} from "../v02/IResolverFeeReceiver.sol";

/// @title  CrucibleMarketV3
/// @notice v0.3 of the per-call prediction-market-settled payment protocol.
///
///         One material change over v0.2: **dispute bond**. When an agent
///         calls `dispute(marketId)` they MUST attach
///         `(agentEscrow * DISPUTE_BOND_BPS) / 10000` of additional value as
///         a bond. At settlement, the bond is split between service and
///         agent proportional to the final scoreBps (mirroring how the
///         service's pre-staked bond is split). This makes sybil dispute
///         spam costly: a frivolous dispute that resolves at scoreBps=10000
///         transfers the entire dispute bond to the service.
///
///         All other v0.2 mechanics — bond pool, resolver whitelist,
///         RESOLVER_FEE_BPS routing, EIP-712 OpenAuth — are unchanged.
///
/// @dev    Settlement math (disputed path):
///           resolverFee     = agentEscrow * RESOLVER_FEE_BPS / 10000
///           settleEscrow    = agentEscrow - resolverFee (if resolver took fee)
///           paidToService   = settleEscrow * scoreBps / 10000
///           refundEscrow    = settleEscrow - paidToService
///           bondSlash       = bondLocked  * (10000 - scoreBps) / 10000
///           bondToService   = disputeBond * scoreBps / 10000
///           bondRefund      = disputeBond - bondToService
///           totalToService  = paidToService + bondToService
///           totalToAgent    = refundEscrow + bondSlash + bondRefund
///
/// @dev    Domain version bumped to "3" — v0.3 OpenAuth sigs cannot
///         cross-replay against v0/v0.2 markets.
contract CrucibleMarketV3 is EIP712, ReentrancyGuard {
    /* ---------- protocol constants ---------- */

    /// @notice Fraction of agent escrow routed to the resolver fee pool on
    ///         the disputed-resolution path. 200 bps = 2.00%.
    uint256 public constant RESOLVER_FEE_BPS = 200;

    /// @notice Fraction of agent escrow the agent must post as a dispute
    ///         bond. 500 bps = 5.00%. Bond is split per score on settlement.
    uint256 public constant DISPUTE_BOND_BPS = 500;

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
    event MarketResolved(
        bytes32 indexed marketId,
        uint16  scoreBps,
        uint256 paidToService,
        uint256 paidToAgent,
        uint256 bondSlashed,
        uint256 resolverFee,
        uint256 disputeBondToService
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
    error WrongDisputeBond();

    constructor() EIP712("Crucible", "3") {}

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

    /// @notice Helper for off-chain agents: exact dispute bond required for
    ///         a given market.
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

    /* ---------- dispute (payable, bond required) ---------- */

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

    /* ---------- resolve ---------- */

    function collectAfterWindow(bytes32 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (block.timestamp <= m.disputeDeadline) revert WindowNotPassed();
        // Optimistic path — no dispute, no resolver fee, no dispute bond.
        _settle(marketId, m, 10000, m.agentEscrow, 0);
    }

    function resolveDisputed(bytes32 marketId, bytes calldata resolverData) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Disputed) revert MarketNotDisputed();
        address resolverAddr = m.resolver;
        if (!IResolver(resolverAddr).canResolve(marketId)) revert ResolverNotReady();

        // 1. Push resolver fee BEFORE resolve so resolver can in-line distribute rewards.
        uint256 resolverFee = (m.agentEscrow * RESOLVER_FEE_BPS) / 10000;
        uint256 settleEscrow = m.agentEscrow;
        if (resolverFee > 0) {
            try IResolverFeeReceiver(resolverAddr).notifyFee{value: resolverFee}(marketId) {
                settleEscrow = m.agentEscrow - resolverFee;
                emit ResolverFeePaid(marketId, resolverAddr, resolverFee);
            } catch {
                emit ResolverFeeReturned(marketId, resolverAddr, resolverFee);
            }
        }

        // 2. Resolve.
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
        uint256 paidToService = (settleEscrow * scoreBps) / 10000;
        uint256 refundEscrowToAgent = settleEscrow - paidToService;

        uint256 bondSlash = (m.bondLocked * (10000 - scoreBps)) / 10000;

        // Dispute bond split: bondToService at score=10000, bondRefund at score=0.
        // (disputeBond is zero on the optimistic path.)
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

        emit MarketResolved(marketId, scoreBps, totalToService, totalToAgent, bondSlash, resolverFee, bondToService);

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
