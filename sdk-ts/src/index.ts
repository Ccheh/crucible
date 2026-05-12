export {
  ARC_TESTNET,
  CRUCIBLE_ARC_TESTNET,
  CRUCIBLE_MARKET_ABI,
  TESTCASE_RESOLVER_ABI,
  MarketStatus,
  type ArcChain,
} from "./constants.js";

export type {
  Hex,
  OpenAuth,
  SignedOpenAuth,
  MarketState,
  ValidatorMarketState,
} from "./types.js";

export {
  buildDomain,
  OPEN_AUTH_TYPES,
  computeMarketId,
  randomNonce,
  codeGenCommitment,
} from "./utils.js";

export { ServiceClient } from "./ServiceClient.js";
export type { ServiceClientOptions } from "./ServiceClient.js";

export { AgentClient } from "./AgentClient.js";
export type { AgentClientOptions } from "./AgentClient.js";

export { ValidatorClient } from "./ValidatorClient.js";
export type { ValidatorClientOptions } from "./ValidatorClient.js";

// v0.6 module (re-exported under namespaced names — see also `@crucible/sdk/v06`).
export * as v06 from "./v06/index.js";
