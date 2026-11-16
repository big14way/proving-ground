import { encodeAbiParameters, keccak256, type Address, type PublicClient } from "viem";
import { hookAbi } from "../abi/hook";
import { vaultAbi } from "../abi/vault";
import { erc20Abi, poolManagerAbi } from "../abi/misc";
import { addresses, poolId } from "../config";
import { sqrtPriceX96ToPrice, tickToPrice, toNumber } from "./math";

const hook = { address: addresses.hook, abi: hookAbi } as const;
const vault = { address: addresses.vault, abi: vaultAbi } as const;

export type Mandate = {
  twapWindow: number;
  minWidth: number;
  maxWidth: number;
  maxDeviation: number;
  cooldown: number;
  minAge: number;
  bondMin: bigint;
  shadowMaxShareBps: number;
  graduationBps: number;
  demotionBps: number;
  baseMultiple: number;
  maxMultiple: number;
  stepBps: number;
  poolShareBps: number;
  maxLossBps: number;
  perfFeeBps: number;
};

export type Pool = {
  block: bigint;
  timestamp: number;
  tick: number;
  price: number;
  sqrtPriceX96: bigint;
  liquidity: bigint;
  /** Null until the oracle has a full window of history. */
  twapTick: number | null;
};

export type ScoreView = {
  nav: number;
  navRaw: number;
  navBenchmark: number;
  navHold: number;
  alphaBps: number;
  rawAlphaBps: number;
  alphaVsHoldBps: number;
  feesConservative: number;
  feesRaw: number;
  rebalanceCost: number;
};

export type ShadowRow = {
  id: number;
  curator: Address;
  tickLower: number;
  tickUpper: number;
  openedAt: number;
  closedAt: number;
  lastRebalanceAt: number;
  rebalances: number;
  liquidity: bigint;
  bond: bigint;
  graduated: boolean;
  status: "open" | "live" | "closed";
  /** Valued at the time-weighted price; frozen for a closed shadow. Null while the oracle is warming up. */
  score: ScoreView | null;
};

export type VaultRow = {
  id: number;
  curator: Address;
  tickLower: number;
  tickUpper: number;
  openedAt: number;
  closedAt: number;
  lastRebalanceAt: number;
  rebalances: number;
  liquidity: bigint;
  totalShares: bigint;
  curatorShares: bigint;
  shadowAlphaBps: number;
  nav: number;
  navBenchmark: number;
  liveAlphaBps: number;
  capacityAlphaBps: number;
  multiple: number;
  maxTotalShares: bigint;
  demoted: boolean;
  feeSharesDue: bigint;
  amount0: number;
  amount1: number;
};

export type Account = {
  address: Address;
  eth: bigint;
  balance0: bigint;
  balance1: bigint;
  nonce: bigint;
  activeShadow: number;
  shares: Record<number, bigint>;
};

export type Snapshot = {
  mandate: Mandate;
  pool: Pool;
  shadows: ShadowRow[];
  vaults: VaultRow[];
  account: Account | null;
};

type RawScore = {
  navConservative: bigint;
  navRaw: bigint;
  navBenchmark: bigint;
  navHold: bigint;
  alphaBps: bigint;
  alphaVsHoldBps: bigint;
  feesConservative: bigint;
  feesRaw: bigint;
  rebalanceCost: bigint;
};

export function toScore(s: RawScore): ScoreView {
  const navBenchmark = toNumber(s.navBenchmark);
  const navRaw = toNumber(s.navRaw);
  return {
    nav: toNumber(s.navConservative),
    navRaw,
    navBenchmark,
    navHold: toNumber(s.navHold),
    alphaBps: Number(s.alphaBps),
    rawAlphaBps: navBenchmark > 0 ? Math.floor((navRaw / navBenchmark - 1) * 10_000) : 0,
    alphaVsHoldBps: Number(s.alphaVsHoldBps),
    feesConservative: toNumber(s.feesConservative),
    feesRaw: toNumber(s.feesRaw),
    rebalanceCost: toNumber(s.rebalanceCost),
  };
}

/** Storage slot of a pool's state inside the v4 pool manager (`_pools` is at slot 6). */
const poolSlot = BigInt(
  keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [poolId, 6n])),
);
const slotHex = (offset: bigint) => `0x${(poolSlot + offset).toString(16).padStart(64, "0")}` as const;

function decodeSlot0(word: `0x${string}`) {
  const value = BigInt(word);
  const sqrtPriceX96 = value & ((1n << 160n) - 1n);
  let tick = Number((value >> 160n) & 0xffffffn);
  if (tick >= 0x800000) tick -= 0x1000000;
  return { sqrtPriceX96, tick };
}

let mandateCache: Mandate | null = null;

async function loadMandate(client: PublicClient): Promise<Mandate> {
  if (mandateCache) return mandateCache;
  const names = [
    "TWAP_WINDOW",
    "MIN_WIDTH_TICKS",
    "MAX_WIDTH_TICKS",
    "MAX_DEVIATION_TICKS",
    "MIN_REBALANCE_INTERVAL",
    "MIN_SHADOW_AGE",
    "BOND_MIN",
    "SHADOW_MAX_POOL_SHARE_BPS",
  ] as const;
  const vaultNames = [
    "GRADUATION_ALPHA_BPS",
    "DEMOTION_ALPHA_BPS",
    "BASE_MULTIPLE",
    "MAX_MULTIPLE",
    "ALPHA_STEP_BPS",
    "LIVE_MAX_POOL_SHARE_BPS",
    "MAX_REBALANCE_LOSS_BPS",
    "PERF_FEE_BPS",
  ] as const;
  const results = await client.multicall({
    allowFailure: false,
    contracts: [
      ...names.map((functionName) => ({ ...hook, functionName })),
      ...vaultNames.map((functionName) => ({ ...vault, functionName })),
    ],
  });
  const n = (i: number) => Number(results[i] as bigint | number);
  mandateCache = {
    twapWindow: n(0),
    minWidth: n(1),
    maxWidth: n(2),
    maxDeviation: n(3),
    cooldown: n(4),
    minAge: n(5),
    bondMin: results[6] as bigint,
    shadowMaxShareBps: n(7),
    graduationBps: n(8),
    demotionBps: n(9),
    baseMultiple: n(10),
    maxMultiple: n(11),
    stepBps: n(12),
    poolShareBps: n(13),
    maxLossBps: n(14),
    perfFeeBps: n(15),
  };
  return mandateCache;
}

export async function loadSnapshot(client: PublicClient, account: Address | null): Promise<Snapshot> {
  const mandate = await loadMandate(client);
  const block = await client.getBlock();
  const blockNumber = block.number;

  const [slot0Word, liquidityWord, twap, count] = await client.multicall({
    blockNumber,
    contracts: [
      { address: addresses.poolManager, abi: poolManagerAbi, functionName: "extsload", args: [slotHex(0n)] },
      { address: addresses.poolManager, abi: poolManagerAbi, functionName: "extsload", args: [slotHex(3n)] },
      { ...hook, functionName: "twapTick", args: [poolId] },
      { ...hook, functionName: "shadowCount" },
    ],
  });
  if (slot0Word.status !== "success" || liquidityWord.status !== "success" || count.status !== "success") {
    throw new Error("Could not read the pool.");
  }
  const { sqrtPriceX96, tick } = decodeSlot0(slot0Word.result);
  const pool: Pool = {
    block: blockNumber,
    timestamp: Number(block.timestamp),
    tick,
    price: sqrtPriceX96ToPrice(sqrtPriceX96),
    sqrtPriceX96,
    liquidity: BigInt(liquidityWord.result) & ((1n << 128n) - 1n),
    twapTick: twap.status === "success" ? Number(twap.result) : null,
  };

  const ids = Array.from({ length: Number(count.result) }, (_, i) => i + 1);
  const shadowCalls = await client.multicall({
    blockNumber,
    contracts: ids.flatMap((id) => [
      { ...hook, functionName: "getShadow", args: [BigInt(id)] } as const,
      { ...hook, functionName: "score", args: [BigInt(id)] } as const,
    ]),
  });

  const shadows: ShadowRow[] = ids.map((id, i) => {
    const s = shadowCalls[2 * i];
    const sc = shadowCalls[2 * i + 1];
    if (s.status !== "success") throw new Error(`Could not read shadow ${id}.`);
    const shadow = s.result as unknown as {
      curator: Address;
      tickLower: number;
      tickUpper: number;
      openedAt: number;
      closedAt: number;
      lastRebalanceAt: number;
      rebalances: number;
      liquidity: bigint;
      bond: bigint;
      graduated: boolean;
    };
    return {
      id,
      curator: shadow.curator,
      tickLower: shadow.tickLower,
      tickUpper: shadow.tickUpper,
      openedAt: Number(shadow.openedAt),
      closedAt: Number(shadow.closedAt),
      lastRebalanceAt: Number(shadow.lastRebalanceAt),
      rebalances: Number(shadow.rebalances),
      liquidity: shadow.liquidity,
      bond: shadow.bond,
      graduated: shadow.graduated,
      status: shadow.graduated ? "live" : Number(shadow.closedAt) !== 0 ? "closed" : "open",
      score: sc.status === "success" ? toScore(sc.result as unknown as RawScore) : null,
    };
  });

  const liveIds = shadows.filter((s) => s.graduated).map((s) => s.id);
  const vaultCalls = await client.multicall({
    blockNumber,
    contracts: liveIds.flatMap((id) => [
      { ...vault, functionName: "getVault", args: [BigInt(id)] } as const,
      { ...vault, functionName: "standing", args: [BigInt(id)] } as const,
      { ...vault, functionName: "holdings", args: [BigInt(id)] } as const,
    ]),
  });
  const vaults: VaultRow[] = liveIds.map((id, i) => {
    const v = vaultCalls[3 * i];
    const st = vaultCalls[3 * i + 1];
    const h = vaultCalls[3 * i + 2];
    if (v.status !== "success") throw new Error(`Could not read vault ${id}.`);
    const raw = v.result as unknown as {
      curator: Address;
      tickLower: number;
      tickUpper: number;
      openedAt: number;
      closedAt: number;
      lastRebalanceAt: number;
      rebalances: number;
      liquidity: bigint;
      totalShares: bigint;
      curatorShares: bigint;
      shadowAlphaBps: bigint;
    };
    const standing =
      st.status === "success"
        ? (st.result as unknown as {
            nav: bigint;
            navBenchmark: bigint;
            liveAlphaBps: bigint;
            capacityAlphaBps: bigint;
            multiple: bigint;
            maxTotalShares: bigint;
            demoted: boolean;
            feeSharesDue: bigint;
          })
        : null;
    const held = h.status === "success" ? (h.result as readonly [bigint, bigint]) : ([0n, 0n] as const);
    return {
      id,
      curator: raw.curator,
      tickLower: raw.tickLower,
      tickUpper: raw.tickUpper,
      openedAt: Number(raw.openedAt),
      closedAt: Number(raw.closedAt),
      lastRebalanceAt: Number(raw.lastRebalanceAt),
      rebalances: Number(raw.rebalances),
      liquidity: raw.liquidity,
      totalShares: raw.totalShares,
      curatorShares: raw.curatorShares,
      shadowAlphaBps: Number(raw.shadowAlphaBps),
      nav: standing ? toNumber(standing.nav) : toNumber(held[0]) * pool.price + toNumber(held[1]),
      navBenchmark: standing ? toNumber(standing.navBenchmark) : 0,
      liveAlphaBps: standing ? Number(standing.liveAlphaBps) : 0,
      capacityAlphaBps: standing ? Number(standing.capacityAlphaBps) : 0,
      multiple: standing ? Number(standing.multiple) : 0,
      maxTotalShares: standing ? standing.maxTotalShares : 0n,
      demoted: standing ? standing.demoted : false,
      feeSharesDue: standing ? standing.feeSharesDue : 0n,
      amount0: toNumber(held[0]),
      amount1: toNumber(held[1]),
    };
  });

  let accountView: Account | null = null;
  if (account) {
    const [eth, base, shareCalls] = await Promise.all([
      client.getBalance({ address: account, blockNumber }),
      client.multicall({
        blockNumber,
        allowFailure: false,
        contracts: [
          { address: addresses.token0, abi: erc20Abi, functionName: "balanceOf", args: [account] },
          { address: addresses.token1, abi: erc20Abi, functionName: "balanceOf", args: [account] },
          { ...hook, functionName: "nonces", args: [account] },
          { ...hook, functionName: "activeShadowOf", args: [account, poolId] },
        ],
      }),
      client.multicall({
        blockNumber,
        allowFailure: false,
        contracts: liveIds.map(
          (id) => ({ ...vault, functionName: "balanceOf", args: [account, BigInt(id)] }) as const,
        ),
      }),
    ]);
    accountView = {
      address: account,
      eth,
      balance0: base[0] as bigint,
      balance1: base[1] as bigint,
      nonce: base[2] as bigint,
      activeShadow: Number(base[3] as bigint),
      shares: Object.fromEntries(liveIds.map((id, i) => [id, shareCalls[i] as bigint])),
    };
  }

  return { mandate, pool, shadows, vaults, account: accountView };
}

export type Point = { time: number; value: number; benchmark: number; hold: number };

/**
 * A shadow's value over its life, read by asking the hook for the score at past blocks.
 * Uses the value at the pool price of the time, which is available from the block the shadow opened.
 */
export async function loadShadowHistory(
  client: PublicClient,
  shadow: ShadowRow,
  pool: Pool,
  points = 28,
): Promise<Point[]> {
  const end = shadow.closedAt !== 0 ? shadow.closedAt - 1 : pool.timestamp;
  const start = shadow.openedAt + 1;
  if (end <= start) return [];
  // Blocks on this chain are one second apart.
  const blockAt = (time: number) => pool.block - BigInt(pool.timestamp - time);
  const times = Array.from({ length: points }, (_, i) => Math.round(start + ((end - start) * i) / (points - 1)));
  const results = await Promise.all(
    times.map((time) =>
      client
        .readContract({ ...hook, functionName: "scoreAtSpot", args: [BigInt(shadow.id)], blockNumber: blockAt(time) })
        .then((raw) => {
          const s = toScore(raw as unknown as RawScore);
          return { time, value: s.nav, benchmark: s.navBenchmark, hold: s.navHold };
        })
        .catch(() => null),
    ),
  );
  return results.filter((p): p is Point => p !== null);
}

/** A vault's value against its benchmark over its life, from the vault's standing at past blocks. */
export async function loadVaultHistory(
  client: PublicClient,
  row: VaultRow,
  pool: Pool,
  points = 20,
): Promise<Point[]> {
  const end = row.closedAt !== 0 ? row.closedAt - 1 : pool.timestamp;
  const start = row.openedAt + 1;
  if (end <= start) return [];
  const blockAt = (time: number) => pool.block - BigInt(pool.timestamp - time);
  const times = Array.from({ length: points }, (_, i) => Math.round(start + ((end - start) * i) / (points - 1)));
  const results = await Promise.all(
    times.map((time) =>
      client
        .readContract({ ...vault, functionName: "standing", args: [BigInt(row.id)], blockNumber: blockAt(time) })
        .then((raw) => {
          const st = raw as unknown as { nav: bigint; navBenchmark: bigint };
          return { time, value: toNumber(st.nav), benchmark: toNumber(st.navBenchmark), hold: 0 };
        })
        .catch(() => null),
    ),
  );
  return results.filter((p): p is Point => p !== null);
}

export function rangeLabel(tickLower: number, tickUpper: number): { low: number; high: number } {
  return { low: tickToPrice(tickLower), high: tickToPrice(tickUpper) };
}

/** The pool price over the last `seconds`, read from the pool manager's storage at past blocks. */
export async function loadPriceHistory(client: PublicClient, pool: Pool, seconds = 1800, points = 36): Promise<Point[]> {
  const blockAt = (time: number) => pool.block - BigInt(pool.timestamp - time);
  const start = pool.timestamp - seconds;
  const times = Array.from({ length: points }, (_, i) => Math.round(start + (seconds * i) / (points - 1)));
  const results = await Promise.all(
    times.map((time) =>
      client
        .readContract({
          address: addresses.poolManager,
          abi: poolManagerAbi,
          functionName: "extsload",
          args: [slotHex(0n)],
          blockNumber: blockAt(time),
        })
        .then((word) => {
          const { sqrtPriceX96 } = decodeSlot0(word);
          if (sqrtPriceX96 === 0n) return null;
          return { time, value: sqrtPriceX96ToPrice(sqrtPriceX96), benchmark: 0, hold: 0 };
        })
        .catch(() => null),
    ),
  );
  return results.filter((p): p is Point => p !== null);
}

