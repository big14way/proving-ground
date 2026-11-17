import { BaseError, ContractFunctionRevertedError, maxUint256, type Address, type Hex } from "viem";
import { hookAbi } from "../abi/hook";
import { vaultAbi } from "../abi/vault";
import { erc20Abi, routerAbi } from "../abi/misc";
import { addresses, chain, poolId, poolKey } from "../config";
import type { Clients } from "./chain";

const hook = { address: addresses.hook, abi: hookAbi } as const;
const vault = { address: addresses.vault, abi: vaultAbi } as const;

export type Intent = {
  poolId: Hex;
  subjectId: bigint;
  live: boolean;
  tickLower: number;
  tickUpper: number;
  nonce: bigint;
  deadline: bigint;
};

/** The typed data a curator signs. The hook is the verifying contract for shadows and vaults alike. */
export const intentTypedData = {
  domain: { name: "ProvingGround", version: "1", chainId: chain.id, verifyingContract: addresses.hook },
  types: {
    RebalanceIntent: [
      { name: "poolId", type: "bytes32" },
      { name: "subjectId", type: "uint256" },
      { name: "live", type: "bool" },
      { name: "tickLower", type: "int24" },
      { name: "tickUpper", type: "int24" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  },
  primaryType: "RebalanceIntent",
} as const;

const busyEndpoint = (error: unknown) =>
  error instanceof BaseError && /rate limit|too many requests/i.test(`${error.message} ${error.details}`);

/** When this page's latest transaction was mined. */
let settledAt = 0;
const justSettled = () => Date.now() - settledAt < 20_000;

/**
 * Asks again, twice, in the two cases where a refusal may not be real: the public endpoint is busy,
 * or it answers from a block that does not yet hold the transaction this page has just had mined
 * (an approval, say), so the next step looks as if it would fail.
 */
async function patiently<T>(job: () => Promise<T>): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      return await job();
    } catch (error) {
      if (attempt === 2 || !(busyEndpoint(error) || justSettled())) throw error;
      await new Promise((resolve) => setTimeout(resolve, 2500));
    }
  }
}

async function send(c: Clients, request: Parameters<typeof c.publicClient.simulateContract>[0]): Promise<Hex> {
  // Simulating first turns a revert into a readable error before the wallet is asked to sign.
  const { request: prepared } = await patiently(() =>
    c.publicClient.simulateContract({ ...request, account: c.account } as never),
  );
  // Wallets tend to set the gas limit to the bare estimate, and a call whose cost shifts by a few thousand
  // gas between the estimate and the block then runs out. The page sets the limit itself, with room to spare;
  // gas that is not used is not paid for.
  const estimate = await patiently(() =>
    c.publicClient.estimateContractGas({ ...request, account: c.account } as never),
  ).catch(() => null);
  const gas = estimate === null ? undefined : (estimate * 13n) / 10n + 20_000n;
  // A browser wallet signs by address; a local key (the terminal script) signs with the account object.
  const account = c.walletClient.account ?? c.account;
  const hash = await c.walletClient.writeContract({ ...prepared, account, gas } as never);
  const receipt = await c.publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    const spent = receipt.gasUsed >= (gas ?? 0n) && gas !== undefined;
    throw new Error(spent ? "The transaction ran out of gas. Nothing changed; try again." : "The transaction was mined but failed. Nothing changed.");
  }
  settledAt = Date.now();
  return hash;
}

async function ensureAllowance(c: Clients, token: Address, spender: Address, amount: bigint) {
  if (amount === 0n) return;
  const allowance = await c.publicClient.readContract({
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [c.account, spender],
  });
  if (allowance >= amount) return;
  await send(c, { address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
}

/** Test tokens are free to mint. */
export async function faucet(c: Clients, amount0: bigint, amount1: bigint) {
  await send(c, { address: addresses.token0, abi: erc20Abi, functionName: "mint", args: [c.account, amount0] });
  return send(c, { address: addresses.token1, abi: erc20Abi, functionName: "mint", args: [c.account, amount1] });
}

export async function swap(c: Clients, zeroForOne: boolean, amountIn: bigint) {
  await ensureAllowance(c, zeroForOne ? addresses.token0 : addresses.token1, addresses.router, amountIn);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + 600);
  return send(c, {
    address: addresses.router,
    abi: routerAbi,
    functionName: "swapExactTokensForTokens",
    args: [amountIn, 0n, zeroForOne, poolKey, "0x", c.account, deadline],
  });
}

export async function openShadow(c: Clients, tickLower: number, tickUpper: number, liquidity: bigint, bond: bigint) {
  const request = { ...hook, functionName: "openShadow", args: [poolId, tickLower, tickUpper, liquidity], value: bond };
  return send(c, request as never);
}

export async function closeShadow(c: Clients, shadowId: number) {
  return send(c, { ...hook, functionName: "closeShadow", args: [BigInt(shadowId)] });
}

export async function withdrawBond(c: Clients, shadowId: number) {
  return send(c, { ...hook, functionName: "withdrawBond", args: [BigInt(shadowId)] });
}

/** Builds the curator's next instruction and asks the wallet to sign it. Nothing is sent to the chain. */
export async function signIntent(
  c: Clients,
  subjectId: number,
  live: boolean,
  tickLower: number,
  tickUpper: number,
  validForSeconds = 600,
): Promise<{ intent: Intent; signature: Hex }> {
  const nonce = await c.publicClient.readContract({ ...hook, functionName: "nonces", args: [c.account] });
  const intent: Intent = {
    poolId,
    subjectId: BigInt(subjectId),
    live,
    tickLower,
    tickUpper,
    nonce,
    deadline: BigInt(Math.floor(Date.now() / 1000) + validForSeconds),
  };
  const signature = await c.walletClient.signTypedData({
    account: c.walletClient.account ?? c.account,
    ...intentTypedData,
    message: intent,
  });
  return { intent, signature };
}

/** Anyone can submit a signed instruction: a shadow's goes to the hook, a vault's to the vault. */
export async function submitIntent(c: Clients, intent: Intent, signature: Hex) {
  if (intent.live) return send(c, { ...vault, functionName: "rebalance", args: [intent, signature] });
  return send(c, { ...hook, functionName: "rebalance", args: [intent, signature] });
}

async function approveVault(c: Clients, amount0: bigint, amount1: bigint) {
  await ensureAllowance(c, addresses.token0, addresses.vault, amount0);
  await ensureAllowance(c, addresses.token1, addresses.vault, amount1);
}

export async function goLive(c: Clients, shadowId: number, liquidity: bigint, max0: bigint, max1: bigint) {
  await approveVault(c, max0, max1);
  return send(c, { ...vault, functionName: "goLive", args: [BigInt(shadowId), liquidity, max0, max1] });
}

/** Adds 1% to the quoted amounts so a small price move does not fail the deposit. */
async function quoteWithSlack(c: Clients, vaultId: number, shares: bigint) {
  const [amount0, amount1] = await c.publicClient.readContract({
    ...vault,
    functionName: "quoteDeposit",
    args: [BigInt(vaultId), shares],
  });
  return { max0: amount0 + amount0 / 100n + 1n, max1: amount1 + amount1 / 100n + 1n };
}

export async function deposit(c: Clients, vaultId: number, shares: bigint) {
  const { max0, max1 } = await quoteWithSlack(c, vaultId, shares);
  await approveVault(c, max0, max1);
  return send(c, { ...vault, functionName: "deposit", args: [BigInt(vaultId), shares, max0, max1] });
}

export async function withdraw(c: Clients, vaultId: number, shares: bigint) {
  return send(c, { ...vault, functionName: "withdraw", args: [BigInt(vaultId), shares, 0n, 0n] });
}

export async function stake(c: Clients, vaultId: number, shares: bigint) {
  const { max0, max1 } = await quoteWithSlack(c, vaultId, shares);
  await approveVault(c, max0, max1);
  return send(c, { ...vault, functionName: "stake", args: [BigInt(vaultId), shares, max0, max1] });
}

export async function unstake(c: Clients, vaultId: number, shares: bigint) {
  return send(c, { ...vault, functionName: "unstake", args: [BigInt(vaultId), shares, 0n, 0n] });
}

export async function settleFee(c: Clients, vaultId: number) {
  return send(c, { ...vault, functionName: "settleFee", args: [BigInt(vaultId)] });
}

/** What each contract error means, in plain words. */
const reasons: Record<string, string> = {
  BondTooSmall: "The bond is below the minimum.",
  ShadowAlreadyOpen: "This address already has an open shadow on this pool. Close it or take it live first.",
  ShadowTooLarge: "A shadow may be at most 1% of the pool's active liquidity. Pick a smaller size.",
  ZeroLiquidity: "The size is zero.",
  RangeNotOnSpacing: "Both ends of the range must sit on the pool's tick grid.",
  RangeTooNarrow: "The range is narrower than the mandate allows.",
  RangeTooWide: "The range is wider than the mandate allows.",
  RangeMustContainTick: "The range must contain the current price.",
  CooldownNotElapsed: "The position was moved too recently. Wait for the cooldown.",
  PriceDeviationTooHigh: "The pool price is too far from its time-weighted average right now. Try again when it settles.",
  OracleNotReady: "The pool's price average does not have a full window of history yet.",
  IntentExpired: "The signed instruction has passed its deadline.",
  BadNonce: "The signed instruction is out of order or was already used.",
  BadSignature: "The instruction was not signed by this position's curator.",
  NotCurator: "Only the shadow's curator can do this.",
  NotVaultCurator: "Only the curator can do this.",
  ShadowIsClosed: "This shadow is closed.",
  ShadowTooYoung: "The shadow has not reached the minimum age yet.",
  AlphaTooLow: "The shadow's score is below the level needed to go live.",
  Demoted: "This vault is scoring below the demotion line and is closed to new deposits.",
  OverCapacity: "This would exceed the vault's capacity: the curator's stake times the multiple they have earned.",
  OverPoolShare: "This would make the vault more than 10% of the pool's active liquidity.",
  StakeLocked: "That stake is backing outside deposits and cannot leave yet.",
  SlippageExceeded: "The price moved while the transaction was on its way. Try again.",
  RebalanceLossTooHigh: "The move would have cost more than the mandate's loss limit, so it was refused.",
  NothingToPlace: "There is nothing to place in the new range.",
  NothingToRebalance: "There is nothing to place in the new range.",
  BondLocked: "The bond is still locked.",
  NoBond: "The bond was already returned.",
  DustReserveLow: "The hook's dust reserve needs topping up.",
  VaultIsClosed: "This vault is closed.",
};

export function explain(error: unknown): string {
  if (error instanceof BaseError) {
    const reverted = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (reverted instanceof ContractFunctionRevertedError) {
      const name = reverted.data?.errorName ?? "";
      if (reasons[name]) return reasons[name];
      if (name === "Panic") return "The contract hit an arithmetic error, most often because a token approval has not reached the network yet. Wait a few seconds and try again.";
      if (name) return `The contract refused: ${name}.`;
    }
    if (/User rejected|denied/i.test(error.shortMessage)) return "You cancelled the request in your wallet.";
    if (/insufficient funds/i.test(error.message)) return "This wallet does not have enough test ETH for gas.";
    if (busyEndpoint(error)) return "The network's public endpoint is busy and turned the request away. Nothing was sent. Wait a few seconds and try again.";
    // A bare "request failed" says nothing; the endpoint's own words are in the details.
    if (/^RPC Request failed/i.test(error.shortMessage) && error.details) return `The network refused the request: ${error.details}`;
    return error.shortMessage;
  }
  return error instanceof Error ? error.message : "Something went wrong.";
}
