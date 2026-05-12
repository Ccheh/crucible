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
import { computeMarketIdV6, type SignedOpenAuthV6 } from "./utils.js";

export interface AgentClientV6Options {
  privateKey: Hex;
  marketAddress: Hex;
  chain?: ArcChain;
}

/**
 * v0.6 Agent client.
 *
 * Material differences from v0:
 *   - `openMarket` submits the v0.6 OpenAuth (with disputeBondBps).
 *   - `dispute` is now payable; bond amount = `requiredDisputeBond(marketId)`.
 *   - New `forceResolveStale` method for stuck markets after 24h grace.
 */
export class AgentClientV6 {
  readonly address: Hex;
  readonly market: Hex;
  readonly chain: ArcChain;
  private readonly account: PrivateKeyAccount;
  private readonly walletClient: WalletClient;
  private readonly publicClient: PublicClient;

  constructor(opts: AgentClientV6Options) {
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

  async openMarket(signed: SignedOpenAuthV6): Promise<{ txHash: Hex; marketId: Hex }> {
    const txHash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "openMarket",
      args: [signed.auth, signed.signature],
      value: signed.auth.amount,
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash: txHash });
    // marketId is deterministic: keccak256(service, agent, nonce). No need to
    // parse events.
    const marketId = computeMarketIdV6(signed.auth.service, signed.auth.agent, signed.auth.nonce);
    return { txHash, marketId };
  }

  /** Dispute the market. Bond amount = `requiredDisputeBond(marketId)`. */
  async dispute(marketId: Hex): Promise<Hex> {
    const bond = await this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "requiredDisputeBond",
      args: [marketId],
    });
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "dispute",
      args: [marketId],
      value: bond,
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Optimistic settlement: collect after the dispute window passes. */
  async collectAfterWindow(marketId: Hex): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "collectAfterWindow",
      args: [marketId],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Resolve a disputed market via the configured resolver. */
  async resolveDisputed(marketId: Hex, resolverData: Hex = "0x"): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "resolveDisputed",
      args: [marketId, resolverData],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** v0.6: force-resolve a stuck disputed market (24h grace; permissionless). */
  async forceResolveStale(marketId: Hex): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "forceResolveStale",
      args: [marketId],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async getMarket(marketId: Hex) {
    return this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_V6_ABI,
      functionName: "markets",
      args: [marketId],
    });
  }
}
