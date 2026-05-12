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
import { TESTCASE_RESOLVER_V5_ABI } from "./constants.js";
import { computeVoteHash, randomSalt } from "./utils.js";

export interface ValidatorClientV6Options {
  privateKey: Hex;
  resolverAddress: Hex;
  chain?: ArcChain;
}

/**
 * v0.6 Validator client. Targets TestcaseResolverV5 (the resolver paired with
 * CrucibleMarketV6 in the v0.6 deploy).
 *
 * Material differences from v0:
 *   - vote() replaced by commitVote() + revealVote() (commit-reveal flow).
 *   - claimSubscription() lets validators withdraw their MasterChef-style
 *     accumulated subscription rewards independent of disputes.
 *   - claimRewards() withdraws per-dispute rewards.
 */
export class ValidatorClientV6 {
  readonly address: Hex;
  readonly resolver: Hex;
  readonly chain: ArcChain;
  private readonly account: PrivateKeyAccount;
  private readonly walletClient: WalletClient;
  private readonly publicClient: PublicClient;

  constructor(opts: ValidatorClientV6Options) {
    this.chain = opts.chain ?? ARC_TESTNET;
    this.resolver = opts.resolverAddress;
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

  async stake(amount: bigint): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "stake",
      value: amount,
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async requestUnstake(amount: bigint): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "requestUnstake",
      args: [amount],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async completeUnstake(): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "completeUnstake",
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /**
   * Commit a vote for `marketId` with score `scoreBps`. Caller can either
   * provide their own salt (recommended for later reveal) or let the client
   * generate a fresh random salt.
   *
   * IMPORTANT: caller must persist the salt off-chain — it cannot be recovered
   * from on-chain state. Without the salt, the validator cannot reveal.
   *
   * Returns the salt used so the caller can store it.
   */
  async commitVote(opts: {
    marketId: Hex;
    scoreBps: number;
    salt?: Hex;
  }): Promise<{ txHash: Hex; salt: Hex }> {
    const salt = opts.salt ?? randomSalt();
    const voteHash = computeVoteHash({
      scoreBps: opts.scoreBps,
      salt,
      marketId: opts.marketId,
      voter: this.address,
    });
    const txHash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "commitVote",
      args: [opts.marketId, voteHash],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash: txHash });
    return { txHash, salt };
  }

  /** Reveal a previously committed vote. */
  async revealVote(marketId: Hex, scoreBps: number, salt: Hex): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "revealVote",
      args: [marketId, scoreBps, salt],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Withdraw accumulated dispute-resolution rewards. */
  async claimRewards(): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "claimRewards",
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Withdraw accumulated always-on validator subscription. */
  async claimSubscription(): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "claimSubscription",
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async getStake(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "validatorStake",
      args: [this.address],
    });
  }

  async earnedSubscription(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "earnedSubscription",
      args: [this.address],
    });
  }

  async pendingReward(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "pendingReward",
      args: [this.address],
    });
  }

  async getMarket(marketId: Hex) {
    return this.publicClient.readContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_V5_ABI,
      functionName: "getMarket",
      args: [marketId],
    });
  }
}
