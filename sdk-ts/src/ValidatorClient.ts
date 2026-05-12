import {
  createWalletClient,
  createPublicClient,
  defineChain,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import { ARC_TESTNET, TESTCASE_RESOLVER_ABI, type ArcChain } from "./constants.js";
import type { ValidatorMarketState, Hex } from "./types.js";

export interface ValidatorClientOptions {
  privateKey: Hex;
  resolverAddress: Hex;  // a TestcaseResolver deployment
  chain?: ArcChain;
}

/** Validator-side client for TestcaseResolver: stake, request unstake, complete unstake, vote. */
export class ValidatorClient {
  readonly address: Hex;
  readonly resolver: Hex;
  readonly chain: ArcChain;
  private readonly account: PrivateKeyAccount;
  private readonly walletClient: WalletClient;
  private readonly publicClient: PublicClient;

  constructor(opts: ValidatorClientOptions) {
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
      abi: TESTCASE_RESOLVER_ABI,
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
      abi: TESTCASE_RESOLVER_ABI,
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
      abi: TESTCASE_RESOLVER_ABI,
      functionName: "completeUnstake",
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Vote on a market's quality. scoreBps in [0, 10000]. */
  async vote(marketId: Hex, scoreBps: number): Promise<Hex> {
    if (scoreBps < 0 || scoreBps > 10000) throw new Error("scoreBps must be in [0, 10000]");
    const hash = await this.walletClient.writeContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_ABI,
      functionName: "vote",
      args: [marketId, scoreBps],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async getStake(): Promise<bigint> {
    return this.publicClient.readContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_ABI,
      functionName: "validatorStake",
      args: [this.address],
    });
  }

  async getMarket(marketId: Hex): Promise<ValidatorMarketState> {
    const result = await this.publicClient.readContract({
      address: this.resolver,
      abi: TESTCASE_RESOLVER_ABI,
      functionName: "getMarket",
      args: [marketId],
    });
    return {
      votingDeadline: BigInt(result[0]),
      finalScore: Number(result[1]),
      resolved: result[2],
      voterCount: result[3],
    };
  }
}
