import {
  createWalletClient,
  createPublicClient,
  defineChain,
  http,
  parseEther,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import { ARC_TESTNET, CRUCIBLE_MARKET_ABI, type ArcChain } from "./constants.js";
import type { OpenAuth, SignedOpenAuth, Hex } from "./types.js";
import { buildDomain, OPEN_AUTH_TYPES, randomNonce } from "./utils.js";

export interface ServiceClientOptions {
  privateKey: Hex;
  marketAddress: Hex;
  chain?: ArcChain;
}

/** Service-side client: manage bond pool, whitelist resolvers, sign OpenAuth messages. */
export class ServiceClient {
  readonly address: Hex;
  readonly market: Hex;
  readonly chain: ArcChain;
  private readonly account: PrivateKeyAccount;
  private readonly walletClient: WalletClient;
  private readonly publicClient: PublicClient;

  constructor(opts: ServiceClientOptions) {
    this.chain = opts.chain ?? ARC_TESTNET;
    this.market = opts.marketAddress;
    this.account = privateKeyToAccount(opts.privateKey);
    this.address = this.account.address;
    const viemChain = defineChain({
      id: this.chain.chainId,
      name: "Arc Testnet",
      nativeCurrency: { name: "USDC", symbol: "USDC", decimals: 18 },
      rpcUrls: { default: { http: [this.chain.rpc] } },
    });
    const transport = http(this.chain.rpc, { timeout: 60_000, retryCount: 2 });
    this.walletClient = createWalletClient({ account: this.account, chain: viemChain, transport });
    this.publicClient = createPublicClient({ chain: viemChain, transport });
  }

  /** Deposit USDC into the service's bond pool. */
  async depositBond(amount: bigint): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "depositBond",
      value: amount,
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Withdraw USDC from the bond pool. Reverts if bondPool - bondLocked < amount. */
  async withdrawBond(amount: bigint): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "withdrawBond",
      args: [amount],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Whitelist (or revoke) a resolver this service is willing to accept markets against. */
  async setResolverAllowed(resolver: Hex, allowed: boolean): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "setResolverAllowed",
      args: [resolver, allowed],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Sign an EIP-712 OpenAuth so the named agent can open a Crucible market with the
   * specified parameters. The agent submits this signed auth + payment on-chain via
   * `AgentClient.openMarket`.
   */
  async signOpenAuth(opts: {
    agent: Hex;
    resolver: Hex;
    amount: bigint;
    bondLockAmount: bigint;
    commitmentHash: Hex;
    disputeWindow: number;       // seconds
    expirySeconds?: number;       // how long the auth is valid; default 600s
    nonce?: bigint;
  }): Promise<SignedOpenAuth> {
    const nonce = opts.nonce ?? randomNonce();
    const authExpiry = BigInt(Math.floor(Date.now() / 1000) + (opts.expirySeconds ?? 600));
    const auth: OpenAuth = {
      service: this.address,
      agent: opts.agent,
      resolver: opts.resolver,
      amount: opts.amount,
      bondLockAmount: opts.bondLockAmount,
      commitmentHash: opts.commitmentHash,
      disputeWindow: BigInt(opts.disputeWindow),
      nonce,
      authExpiry,
    };
    const signature = await this.account.signTypedData({
      domain: buildDomain(this.market, this.chain.chainId),
      types: OPEN_AUTH_TYPES,
      primaryType: "OpenAuth",
      message: auth,
    });
    return { auth, signature };
  }

  async bondPool(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "bondPool",
      args: [this.address],
    });
  }

  async bondLocked(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "bondLocked",
      args: [this.address],
    });
  }

  async bondAvailable(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "bondAvailable",
      args: [this.address],
    });
  }
}
