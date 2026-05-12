import {
  createWalletClient,
  createPublicClient,
  defineChain,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

import { ARC_TESTNET, CRUCIBLE_MARKET_ABI, type ArcChain } from "./constants.js";
import type { MarketState, OpenAuth, SignedOpenAuth, Hex } from "./types.js";
import { computeMarketId } from "./utils.js";

export interface AgentClientOptions {
  privateKey: Hex;
  marketAddress: Hex;
  chain?: ArcChain;
}

/** Agent-side client: open markets with a signed service auth, dispute, query state. */
export class AgentClient {
  readonly address: Hex;
  readonly market: Hex;
  readonly chain: ArcChain;
  private readonly account: PrivateKeyAccount;
  private readonly walletClient: WalletClient;
  private readonly publicClient: PublicClient;

  constructor(opts: AgentClientOptions) {
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

  /**
   * Submit a signed OpenAuth + the agent's payment to open a Crucible market.
   * The market enters status=Open with a dispute window of `auth.disputeWindow` seconds.
   * Returns the on-chain tx hash and the derived deterministic marketId.
   */
  async openMarket(signedAuth: SignedOpenAuth): Promise<{ txHash: Hex; marketId: Hex }> {
    if (signedAuth.auth.agent.toLowerCase() !== this.address.toLowerCase()) {
      throw new Error(`OpenAuth.agent (${signedAuth.auth.agent}) does not match this client address (${this.address})`);
    }
    const txHash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "openMarket",
      args: [signedAuth.auth, signedAuth.signature],
      value: signedAuth.auth.amount,
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash: txHash });
    const marketId = computeMarketId(signedAuth.auth.service, this.address, signedAuth.auth.nonce);
    return { txHash, marketId };
  }

  /** Dispute the market within the dispute window. Only the agent can call. */
  async dispute(marketId: Hex): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "dispute",
      args: [marketId],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Collect after dispute window passes (anyone can call, but typically agent or service). */
  async collectAfterWindow(marketId: Hex): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "collectAfterWindow",
      args: [marketId],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  /** Trigger resolution of a disputed market via its resolver. */
  async resolveDisputed(marketId: Hex, resolverData: Hex = "0x"): Promise<Hex> {
    const hash = await this.walletClient.writeContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "resolveDisputed",
      args: [marketId, resolverData],
      chain: null,
      account: this.account,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });
    return hash;
  }

  async getMarket(marketId: Hex): Promise<MarketState> {
    const result = await this.publicClient.readContract({
      address: this.market,
      abi: CRUCIBLE_MARKET_ABI,
      functionName: "markets",
      args: [marketId],
    });
    return {
      service: result[0] as Hex,
      agent: result[1] as Hex,
      resolver: result[2] as Hex,
      agentEscrow: result[3],
      bondLocked: result[4],
      commitmentHash: result[5] as Hex,
      disputeDeadline: BigInt(result[6]),
      scoreBps: Number(result[7]),
      status: Number(result[8]),
    };
  }
}
