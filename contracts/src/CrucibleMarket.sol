// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import {IResolver} from "./interfaces/IResolver.sol";

/// @title  CrucibleMarket (v0)
/// @notice Per-call prediction-market-settled payments for probabilistic AI services.
///         The agent locks USDC; the service locks part of a pre-staked bond;
///         after a resolution window, the resolver assigns a quality score in
///         basis points (0..10000), and funds flow proportionally.
///
/// @dev    v0 ships with an "optimistic" code path: if no dispute is raised
///         within the dispute window, the market resolves at scoreBps = 10000
///         (service collects full payment, agent gets nothing back, no bond
///         slash). If a dispute IS raised, the configured resolver is
///         consulted to determine the actual score, and funds flow per
///         (score, slash) math.
///
/// @dev    No admin keys, no upgrade proxy, no pause function. Future versions
///         deploy fresh with bumped EIP-712 domain version "2".
contract CrucibleMarket is EIP712, ReentrancyGuard {
    /* ---------- service bond pool ---------- */

    /// @notice Service-side bond pool. Each service self-manages a pool used
    ///         to back its market commitments.
    mapping(address service => uint256) public bondPool;

    /// @notice Amount of bondPool currently locked across open + disputed markets.
    mapping(address service => uint256) public bondLocked;

    /// @notice Per-service whitelist of resolvers it accepts. Required so a
    ///         malicious agent can't open a market against an unfamiliar resolver.
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

    /// @dev Service signs this off-chain; agent submits with payment to open market.
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

    /* ---------- constructor ---------- */

    constructor() EIP712("Crucible", "1") {}

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
    function collectAfterWindow(bytes32 marketId) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Open) revert MarketNotOpen();
        if (block.timestamp <= m.disputeDeadline) revert WindowNotPassed();
        _settle(marketId, m, 10000);
    }

    /// @notice Disputed-market settlement: resolver computes score, funds flow accordingly.
    function resolveDisputed(bytes32 marketId, bytes calldata resolverData) external nonReentrant {
        Market storage m = markets[marketId];
        if (m.status != Status.Disputed) revert MarketNotDisputed();
        if (!IResolver(m.resolver).canResolve(marketId)) revert ResolverNotReady();
        uint256 score = IResolver(m.resolver).resolve(marketId, resolverData);
        if (score > 10000) revert ScoreOutOfRange();
        _settle(marketId, m, uint16(score));
    }

    /* ---------- internal: settle ---------- */

    function _settle(bytes32 marketId, Market storage m, uint16 scoreBps) internal {
        uint256 paidToService = (m.agentEscrow * scoreBps) / 10000;
        uint256 refundEscrowToAgent = m.agentEscrow - paidToService;

        // Bond slashing: proportional to (10000 - scoreBps). On perfect score
        // (10000), no slash; on zero score (0), entire locked bond goes to agent.
        uint256 bondSlash = (m.bondLocked * (10000 - scoreBps)) / 10000;

        // Unlock the service's locked bond.
        bondLocked[m.service] -= m.bondLocked;
        // Debit slashed portion from the pool.
        if (bondSlash > 0) {
            bondPool[m.service] -= bondSlash;
        }

        m.scoreBps = scoreBps;
        m.status = Status.Resolved;

        uint256 totalToAgent = refundEscrowToAgent + bondSlash;
        emit MarketResolved(marketId, scoreBps, paidToService, totalToAgent, bondSlash);

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
