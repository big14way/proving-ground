import { defineChain } from "viem";

/** Unichain Sepolia, where the hook, the vault and the demonstration pool are deployed. */
export const chain = defineChain({
  id: 1301,
  name: "Unichain Sepolia",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  // The chain's own endpoint keeps old state, which the charts read. The second is a spare for when the first is busy.
  rpcUrls: { default: { http: ["https://sepolia.unichain.org", "https://unichain-sepolia-rpc.publicnode.com"] } },
  blockExplorers: { default: { name: "Uniscan", url: "https://sepolia.uniscan.xyz" } },
  contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
  testnet: true,
});

export const addresses = {
  hook: "0x317a059533Ceb38aB84a5e7887eB311676d3d080",
  vault: "0xde5922f789865e06103275Fb108618DCA6889846",
  poolManager: "0x00B036B58a818B1BC34d502D3fE730Db729e62AC",
  router: "0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba",
  token0: "0xEE83A0D9d02Ba63762D0C6cC6DaEb57438f74015",
  token1: "0xFc99FE1A7c2b61F1C61267389939F9f0db99e174",
} as const;

export const poolId = "0x52959c5f76f1fce16dddf31c16068014ce45b3d54da05b034598061fe31744af" as const;

/** The pool key, in the field order the contracts expect. */
export const poolKey = {
  currency0: addresses.token0,
  currency1: addresses.token1,
  fee: 3000,
  tickSpacing: 60,
  hooks: addresses.hook,
} as const;

export const tokens = {
  token0: { symbol: "pgETH", name: "Test ETH", decimals: 18 },
  token1: { symbol: "pgUSD", name: "Test USD", decimals: 18 },
} as const;

export const TICK_SPACING = 60;
export const explorer = chain.blockExplorers.default.url;
