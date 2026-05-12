import {
  createWalletClient,
  createPublicClient,
  defineChain,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import { ARC_TESTNET, type ArcChain } from "../constants.js";
import type { Hex } from "../types.js";
import { CRUCIBLE_MARKET_V6_ABI } from "./constants.js";
import {
  buildDomainV6,
  OPEN_AUTH_V6_TYPES,
  randomNonceV6,
  type OpenAuthV6,
  type SignedOpenAuthV6,
} from "./utils.js";

export interface ServiceClientV6Options {
  privateKey: Hex;
  marketAddress: Hex;
  chain?: ArcChain;
}

/**
 * v0.6 Service client.
 *
 * Material differences from v0:
 *   - signOpenAuth now requires `disputeBondBps` (per-market dispute bond rate,
 *     in basis points, range [100, 5000]).
 *   - EIP-712 domain version is "6".
 */
export class ServiceClientV6 {
  readonly address: Hex;
  readonly market: Hex;
  readonly chain: ArcChain;
  private readonly account: PrivateKeyAccount;
  private readonly walletClient: WalletClient;
  private readonly publicClient: PublicClient;

  constructor(opts: ServiceClientV6Options) {
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

  async depositBond(amount: bigint): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "depositBond",
      value: amount,
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async withdrawBond(amount: bigint): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "withdrawBond",
      args: [amount],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async setResolverAllowed(resolver: Hex, allowed: boolean): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "setResolverAllowed",
      args: [resolver, allowed],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Sign a v0.6 OpenAuth message authorizing the named agent to open a market.
   * REQUIRES `disputeBondBps` in range [100, 5000].
   */
  async signOpenAuth(opts: {
    agent: Hex;
    resolver: Hex;
    amount: bigint;
    bondLockAmount: bigint;
    disputeBondBps: number;
    commitmentHash: Hex;
    disputeWindow: number;
    expirySeconds?: number;
    nonce?: bigint;
  }): Promise<SignedOpenAuthV6> {
    if (opts.disputeBondBps < 100 || opts.disputeBondBps > 5000) {
      throw new Error(`disputeBondBps must be in [100, 5000], got ${opts.disputeBondBps}`);
    }
    const nonce = opts.nonce ?? randomNonceV6();
    const authExpiry = BigInt(Math.floor(Date.now() / 1000) + (opts.expirySeconds ?? 600));
    const auth: OpenAuthV6 = {
      service: this.address,
      agent: opts.agent,
      resolver: opts.resolver,
      amount: opts.amount,
      bondLockAmount: opts.bondLockAmount,
      disputeBondBps: opts.disputeBondBps,
      commitmentHash: opts.commitmentHash,
      disputeWindow: BigInt(opts.disputeWindow),
      nonce,
      authExpiry,
    };
    const signature = await this.account.signTypedData({
      domain: buildDomainV6(this.market, this.chain.chainId),
      types: OPEN_AUTH_V6_TYPES,
      primaryType: "OpenAuth",
      message: auth,
    });
    return { auth, signature };
  }

  async bondPool(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "bondPool",
      args: [this.address],
    });
  }

  async bondAvailable(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "bondAvailable",
      args: [this.address],
    });
  }
}
