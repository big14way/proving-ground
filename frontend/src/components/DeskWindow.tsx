import { useEffect, useMemo, useState } from "react";
import { motion, type MotionValue } from "motion/react";
import type { Hex } from "viem";
import * as actions from "../lib/actions";
import { publicClient, type Clients } from "../lib/chain";
import {
  loadPriceHistory,
  loadShadowHistory,
  loadVaultHistory,
  type Point,
  type ShadowRow,
  type Snapshot,
  type VaultRow,
} from "../lib/data";
import {
  ago,
  amountsFor,
  bps,
  duration,
  floorTick,
  fromNumber,
  liquidityForValue,
  num,
  shortAddress,
  tickToPrice,
  toNumber,
  usd,
} from "../lib/math";
import { explorer, TICK_SPACING, tokens } from "../config";
import { Chart } from "./Chart";

export type TabId = "market" | "record" | "new" | `s${number}` | `v${number}`;

type Props = {
  snapshot: Snapshot;
  clients: Clients | null;
  onConnect: () => void;
  refresh: () => void;
  now: number;
  tab: TabId;
  setTab: (tab: TabId) => void;
  noticeA: MotionValue<number>;
  noticeB: MotionValue<number>;
};

type Status = { tone: "busy" | "good" | "bad"; title: string; text: string; hash?: Hex } | null;
type Run = (label: string, job: (c: Clients) => Promise<Hex | void>) => Promise<void>;

const pad = (n: number) => String(n).padStart(2, "0");

/** Range choices, as ticks either side of the current price. */
const WIDTHS = [
  { label: "±1%", ticks: 120 },
  { label: "±3%", ticks: 300 },
  { label: "±6%", ticks: 600 },
  { label: "±12%", ticks: 1200 },
];

function rangeAround(tick: number, half: number) {
  const mid = floorTick(tick, TICK_SPACING);
  return { lower: mid - half, upper: mid + half + TICK_SPACING };
}

/** The product itself, framed as an application window: tabs, a value and its chart, and an order form. */
export function DeskWindow({ snapshot, clients, onConnect, refresh, now, tab, setTab, noticeA, noticeB }: Props) {
  const { pool, mandate, account, shadows, vaults } = snapshot;
  const [status, setStatus] = useState<Status>(null);
  const [busy, setBusy] = useState(false);
  const [points, setPoints] = useState<Point[]>([]);

  const shadow = tab.startsWith("s") ? shadows.find((s) => s.id === Number(tab.slice(1))) : undefined;
  const vault = tab.startsWith("v") ? vaults.find((v) => v.id === Number(tab.slice(1))) : undefined;
  const drift = pool.twapTick === null ? null : pool.tick - pool.twapTick;
  const priceOk = drift !== null && Math.abs(drift) <= mandate.maxDeviation;

  // The chart follows the tab. It is read from past blocks, and refreshed every 45 seconds.
  const beat = Math.floor(pool.timestamp / 45);
  const subjectKey = shadow ? `s${shadow.id}-${shadow.rebalances}-${shadow.closedAt}` : vault ? `v${vault.id}-${vault.rebalances}` : "price";
  useEffect(() => {
    let cancelled = false;
    const load = shadow
      ? loadShadowHistory(publicClient as never, shadow, pool)
      : vault
        ? loadVaultHistory(publicClient as never, vault, pool)
        : loadPriceHistory(publicClient as never, pool);
    load.then((p) => !cancelled && setPoints(p)).catch(() => !cancelled && setPoints([]));
    return () => {
      cancelled = true;
    };
  }, [subjectKey, beat]);

  const run: Run = async (label, job) => {
    if (!clients) return onConnect();
    setBusy(true);
    setStatus({ tone: "busy", title: "In progress", text: `${label}. Confirm in your wallet, then wait for the block.` });
    try {
      const hash = await job(clients);
      setStatus({ tone: "good", title: "Done", text: `${label}.`, hash: hash ?? undefined });
      refresh();
      // The public endpoint can lag a block behind the wallet's, so look once more shortly after.
      setTimeout(refresh, 2500);
    } catch (error) {
      setStatus({ tone: "bad", title: "Refused", text: actions.explain(error) });
    } finally {
      setBusy(false);
    }
  };

  // A result belongs to the tab it happened on: choosing another tab clears it, unless something is still under way.
  const pick = (id: TabId) => {
    setTab(id);
    if (!busy) setStatus(null);
  };

  const openShadows = shadows.filter((s) => s.status === "open");
  const liveVaults = vaults.filter((v) => v.closedAt === 0);
  const canOpen = !account || account.activeShadow === 0;

  // An address may run one shadow at a time: once it has one, the form to open gives way to that shadow.
  const activeShadow = account?.activeShadow ?? 0;
  useEffect(() => {
    if (tab === "new" && activeShadow !== 0) setTab(`s${activeShadow}`);
  }, [tab, activeShadow]);

  return (
    <div className="window">
      <div className="window-dots" aria-hidden>
        <i />
        <i />
        <i />
      </div>
      <div className="screen">
        <div className="bar">
          <div className="tabs" role="tablist">
            <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden style={{ flexShrink: 0 }}>
              <rect width="14" height="14" fill="var(--ink)" />
            </svg>
            <Tab id="market" tab={tab} setTab={pick} label="Market" />
            {liveVaults.map((v) => (
              <Tab key={v.id} id={`v${v.id}`} tab={tab} setTab={pick} label={`Vault ${pad(v.id)}`} />
            ))}
            {openShadows.map((s) => (
              <Tab key={s.id} id={`s${s.id}`} tab={tab} setTab={pick} label={`Shadow ${pad(s.id)}`} />
            ))}
            {shadow && shadow.status !== "open" && <Tab id={tab} tab={tab} setTab={pick} label={`Shadow ${pad(shadow.id)}`} />}
            <Tab id="record" tab={tab} setTab={pick} label="Record" />
            {canOpen && <Tab id="new" tab={tab} setTab={pick} label="New shadow" />}
          </div>
          <div className="bar-right">
            {account && (
              <span className="boxed static">
                <span className="mono">Wallet</span>
                {num(toNumber(account.balance1), 0)} {tokens.token1.symbol}
              </span>
            )}
            {clients ? (
              <a className="boxed" href={`${explorer}/address/${clients.account}`} target="_blank" rel="noreferrer">
                {shortAddress(clients.account)}
              </a>
            ) : (
              <button className="boxed" onClick={onConnect}>
                Connect wallet
              </button>
            )}
          </div>
        </div>

        {tab === "record" ? (
          <RecordTable snapshot={snapshot} now={now} setTab={pick} />
        ) : (
          <div className="panes">
            <div className="left">
              {tab === "market" || tab === "new" ? (
                <>
                  <span className="mono">{tokens.token0.symbol} price, in {tokens.token1.symbol}</span>
                  <div className="value-row">
                    <span className="value">{usd(pool.price, 2)}</span>
                    <span className={`chip ${drift === null ? "neutral" : priceOk ? "" : "warn"}`}>
                      {drift === null ? "average still filling" : `${Math.abs(drift)} ticks ${drift >= 0 ? "above" : "below"} average`}
                    </span>
                  </div>
                  <div className="stats">
                    <Stat label={`${duration(mandate.twapWindow)} average`} value={pool.twapTick === null ? "…" : usd(tickToPrice(pool.twapTick), 2)} />
                    <Stat label="Open shadows" value={String(openShadows.length)} />
                    <Stat label="Live vaults" value={String(liveVaults.length)} />
                  </div>
                  <div className="pairline">
                    <span>
                      <b>
                        {tokens.token0.symbol} / {tokens.token1.symbol}
                      </b>
                      <span className="mono">last 30 min</span>
                    </span>
                    <span className="mono">block {pool.block.toLocaleString("en-US")}</span>
                  </div>
                  <Chart points={points} format={(v) => num(v, 2)} showBenchmark={false} height={250} />
                </>
              ) : shadow ? (
                <>
                  <span className="mono">Shadow No. {pad(shadow.id)} · value, counted conservatively</span>
                  <div className="value-row">
                    <span className="value">{shadow.score ? usd(shadow.score.nav, 2) : "…"}</span>
                    <span className={`chip ${shadow.score && shadow.score.alphaBps < 0 ? "warn" : ""}`}>
                      {shadow.score ? `${bps(shadow.score.alphaBps)} vs passive` : "score pending"}
                    </span>
                  </div>
                  <div className="stats">
                    <Stat label="Passive position" value={shadow.score ? usd(shadow.score.navBenchmark, 2) : "…"} />
                    <Stat label="Simply holding" value={shadow.score ? usd(shadow.score.navHold, 2) : "…"} />
                    <Stat label="Moves" value={String(shadow.rebalances)} />
                  </div>
                  <div className="pairline">
                    <span>
                      <b>
                        {usd(tickToPrice(shadow.tickLower))} – {usd(tickToPrice(shadow.tickUpper))}
                      </b>
                      <span className="mono">{duration((shadow.closedAt || now) - shadow.openedAt)} of record</span>
                    </span>
                    <span className="legend mono">
                      <span>
                        <i /> shadow
                      </span>
                      <span>
                        <i className="dash" /> passive
                      </span>
                    </span>
                  </div>
                  <Chart points={points} format={(v) => usd(v)} height={250} />
                </>
              ) : vault ? (
                <>
                  <span className="mono">Vault No. {pad(vault.id)} · under management</span>
                  <div className="value-row">
                    <span className="value">{usd(vault.nav, 2)}</span>
                    <span className={`chip ${vault.liveAlphaBps < 0 ? "warn" : ""}`}>{bps(vault.liveAlphaBps)} vs passive, after fees</span>
                  </div>
                  <div className="stats">
                    <Stat label="Multiple earned" value={`${vault.multiple}×`} />
                    <Stat label="Curator's stake" value={`${stakeShare(vault)}%`} />
                    <Stat
                      label="Your shares"
                      value={account ? usd(myValue(vault, account.shares[vault.id] ?? 0n), 2) : "connect"}
                    />
                  </div>
                  <div className="pairline">
                    <span>
                      <b>
                        {usd(tickToPrice(vault.tickLower))} – {usd(tickToPrice(vault.tickUpper))}
                      </b>
                      <span className="mono">live for {duration((vault.closedAt || now) - vault.openedAt)}</span>
                    </span>
                    <span className="legend mono">
                      <span>
                        <i /> vault
                      </span>
                      <span>
                        <i className="dash" /> passive
                      </span>
                    </span>
                  </div>
                  <Chart points={points} format={(v) => usd(v)} height={250} />
                </>
              ) : (
                <div className="chart-empty mono">Nothing selected.</div>
              )}
            </div>

            <div className="right">
              {tab === "market" && <MarketForm snapshot={snapshot} busy={busy} run={run} connected={clients !== null} />}
              {tab === "new" && <OpenForm snapshot={snapshot} busy={busy} run={run} connected={clients !== null} />}
              {shadow && <ShadowForm key={shadow.id} shadow={shadow} snapshot={snapshot} busy={busy} run={run} now={now} connected={clients !== null} />}
              {vault && <VaultForm key={vault.id} row={vault} snapshot={snapshot} busy={busy} run={run} now={now} connected={clients !== null} />}
              {status && (
                <p className={`note ${status.tone === "bad" ? "warn" : ""}`} role="status">
                  <span className="mono sq" style={{ color: "inherit" }}>
                    {status.title}
                  </span>
                  <br />
                  {status.text}{" "}
                  {status.hash && (
                    <a href={`${explorer}/tx/${status.hash}`} target="_blank" rel="noreferrer">
                      View it
                    </a>
                  )}
                </p>
              )}
            </div>
          </div>
        )}
      </div>

      {/* Two live notes that fade in as the desk is scrolled through. */}
      {/* The first sits over the corner where a result is reported, so it steps aside while one is showing. */}
      {!status && (
        <motion.div className="toast" style={{ opacity: noticeA }}>
          <span className="mono sq">Price check</span>
          <p>{drift === null ? "Average still filling" : `${Math.abs(drift)} ticks off: ${priceOk ? "moves allowed" : "moves refused"}`}</p>
        </motion.div>
      )}
      <motion.div className="toast second" style={{ opacity: noticeB }}>
        <span className="mono sq">Latest block</span>
        <p>
          {pool.block.toLocaleString("en-US")}, {ago(pool.timestamp, Math.max(now, pool.timestamp))}
        </p>
      </motion.div>
    </div>
  );
}

function Tab({ id, tab, setTab, label }: { id: TabId; tab: TabId; setTab: (t: TabId) => void; label: string }) {
  return (
    <button role="tab" aria-selected={tab === id} className={`tab ${tab === id ? "on" : ""}`} onClick={() => setTab(id)}>
      {label}
    </button>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <span className="mono">{label}</span>
      {value}
    </div>
  );
}

function Row({ label, value, tone }: { label: string; value: string; tone?: "accent" | "warn" }) {
  return (
    <div className="row">
      <span className="mono">{label}</span>
      <b className={tone ?? ""}>{value}</b>
    </div>
  );
}

const stakeShare = (v: VaultRow) => (v.totalShares > 0n ? Math.round((Number(v.curatorShares) / Number(v.totalShares)) * 100) : 0);
const myValue = (v: VaultRow, shares: bigint) => (v.totalShares > 0n ? (Number(shares) / Number(v.totalShares)) * v.nav : 0);

function Presets({ values, current, onPick, format }: { values: number[]; current: number; onPick: (v: number) => void; format: (v: number) => string }) {
  return (
    <div className="pcts">
      {values.map((v) => (
        <button key={v} type="button" className={current === v ? "on" : ""} onClick={() => onPick(v)}>
          {format(v)}
        </button>
      ))}
    </div>
  );
}

function RangePicker({ half, setHalf, tick }: { half: number; setHalf: (h: number) => void; tick: number }) {
  const { lower, upper } = rangeAround(tick, half);
  return (
    <>
      <div className="field">
        <span className="mono">Lower</span>
        <span>{usd(tickToPrice(lower))}</span>
      </div>
      <div className="field">
        <span className="mono">Upper</span>
        <span>{usd(tickToPrice(upper))}</span>
      </div>
      <Presets values={WIDTHS.map((w) => w.ticks)} current={half} onPick={setHalf} format={(v) => WIDTHS.find((w) => w.ticks === v)!.label} />
    </>
  );
}

function AmountField({ label, value, setValue, unit }: { label: string; value: string; setValue: (v: string) => void; unit: string }) {
  return (
    <label className="field">
      <span className="mono">{label}</span>
      <input inputMode="decimal" value={value} onChange={(e) => setValue(e.target.value)} />
      <span className="unit">{unit}</span>
    </label>
  );
}

type FormProps = { snapshot: Snapshot; busy: boolean; run: Run; connected: boolean };

function MarketForm({ snapshot, busy, run, connected }: FormProps) {
  const { pool } = snapshot;
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const [amount, setAmount] = useState("5000");
  const value = Number(amount) || 0;
  return (
    <>
      <div className="seg">
        <button className={side === "buy" ? "on" : ""} onClick={() => setSide("buy")}>
          Buy
        </button>
        <button className={side === "sell" ? "on" : ""} onClick={() => setSide("sell")}>
          Sell
        </button>
      </div>
      <div className="field">
        <span className="mono">Price</span>
        <span>
          {num(pool.price, 2)} {tokens.token1.symbol}
        </span>
      </div>
      <AmountField label="Amount" value={amount} setValue={setAmount} unit={tokens.token1.symbol} />
      <Presets values={[1000, 5000, 10000, 25000]} current={value} onPick={(v) => setAmount(String(v))} format={(v) => `${v / 1000}K`} />
      <div className="rows">
        <Row label={side === "buy" ? "You get about" : "You sell about"} value={`${num(value / pool.price, 3)} ${tokens.token0.symbol}`} />
        <Row label="Pool fee" value={`${num(value * 0.003, 2)} ${tokens.token1.symbol}`} />
      </div>
      <button
        className="primary"
        disabled={busy || value <= 0}
        onClick={() =>
          run(side === "buy" ? `Buying ${tokens.token0.symbol}` : `Selling ${tokens.token0.symbol}`, (c) =>
            actions.swap(c, side === "sell", side === "buy" ? fromNumber(value) : fromNumber(value / pool.price)),
          )
        }
      >
        {connected ? `${side === "buy" ? "Buy" : "Sell"} ${tokens.token0.symbol}` : "Connect wallet"}
      </button>
      <button className="textlink" disabled={busy} onClick={() => run("Minting test tokens", (c) => actions.faucet(c, fromNumber(20), fromNumber(60_000)))}>
        Mint test tokens
      </button>
    </>
  );
}

function OpenForm({ snapshot, busy, run, connected }: FormProps) {
  const { pool, mandate } = snapshot;
  const [half, setHalf] = useState(300);
  const [share, setShare] = useState(100);
  const { lower, upper } = rangeAround(pool.tick, half);
  const cap = (pool.liquidity * BigInt(mandate.shadowMaxShareBps)) / 10_000n;
  const liquidity = (cap * BigInt(share)) / 100n;
  const held = amountsFor(pool.price, lower, upper, liquidity);
  return (
    <>
      <div className="seg">
        <button className="on">Open a shadow</button>
      </div>
      <RangePicker half={half} setHalf={setHalf} tick={pool.tick} />
      <div className="field">
        <span className="mono">Size</span>
        <span>{share}% of the cap</span>
      </div>
      <Presets values={[25, 50, 75, 100]} current={share} onPick={setShare} format={(v) => `${v}%`} />
      <div className="rows">
        <Row label="Worth" value={usd(held.amount0 * pool.price + held.amount1)} />
        <Row label="Capital needed" value="none" />
        <Row label="Bond" value={`${toNumber(mandate.bondMin)} ETH`} />
      </div>
      <button className="primary" disabled={busy || liquidity === 0n} onClick={() => run("Opening the shadow", (c) => actions.openShadow(c, lower, upper, liquidity, mandate.bondMin))}>
        {connected ? "Open the shadow" : "Connect wallet"}
      </button>
      <p className="note">The hook scores it against every swap from now on, as if the position were real.</p>
    </>
  );
}

function ShadowForm({ shadow, snapshot, busy, run, now, connected }: FormProps & { shadow: ShadowRow; now: number }) {
  const { pool, mandate, account } = snapshot;
  const [mode, setMode] = useState<"move" | "live">("move");
  const [half, setHalf] = useState(300);
  const [stakeUsd, setStakeUsd] = useState("20000");
  const mine = account !== null && account.address.toLowerCase() === shadow.curator.toLowerCase();
  const open = shadow.status === "open";
  const age = now - shadow.openedAt;
  const readyAt = (shadow.rebalances === 0 ? shadow.openedAt : shadow.lastRebalanceAt) + mandate.cooldown;
  const drift = pool.twapTick === null ? null : Math.abs(pool.tick - pool.twapTick);
  const priceOk = drift !== null && drift <= mandate.maxDeviation;
  const { lower, upper } = rangeAround(pool.tick, half);

  const stake = useMemo(() => {
    const liquidity = liquidityForValue(pool.price, shadow.tickLower, shadow.tickUpper, Number(stakeUsd) || 0);
    return { liquidity, ...amountsFor(pool.price, shadow.tickLower, shadow.tickUpper, liquidity) };
  }, [stakeUsd, pool.price, shadow.tickLower, shadow.tickUpper]);
  const oldEnough = age >= mandate.minAge;
  const goodEnough = shadow.score !== null && shadow.score.alphaBps >= mandate.graduationBps;

  if (!open || !mine) {
    return (
      <>
        <div className="seg">
          <button className="on">{open ? "Read only" : shadow.status === "live" ? "Went live" : "Abandoned"}</button>
        </div>
        <div className="rows" style={{ borderTop: 0, paddingTop: 0 }}>
          <Row label="Curator" value={shortAddress(shadow.curator)} />
          <Row label="Width" value={`${shadow.tickUpper - shadow.tickLower} ticks`} />
          <Row label="Record" value={duration((shadow.closedAt || now) - shadow.openedAt)} />
          <Row label="Raw score" value={shadow.score ? bps(shadow.score.rawAlphaBps) : "…"} />
          <Row label="Score" value={shadow.score ? bps(shadow.score.alphaBps) : "…"} tone="accent" />
          <Row label="Modelled cost" value={shadow.score ? usd(shadow.score.rebalanceCost, 2) : "…"} />
        </div>
        <p className="note">
          {open ? "Only this shadow's curator can move it, and only by a signed instruction." : "Its score is frozen on the record."}
        </p>
      </>
    );
  }

  return (
    <>
      <div className="seg">
        <button className={mode === "move" ? "on" : ""} onClick={() => setMode("move")}>
          Move
        </button>
        <button className={mode === "live" ? "on" : ""} onClick={() => setMode("live")}>
          Go live
        </button>
      </div>
      {mode === "move" ? (
        <>
          <RangePicker half={half} setHalf={setHalf} tick={pool.tick} />
          <div className="rows">
            <Row label="Cooldown" value={now >= readyAt ? "ready" : `ready in ${duration(readyAt - now)}`} tone={now >= readyAt ? undefined : "warn"} />
            <Row label="Price check" value={drift === null ? "average filling" : `${drift} ticks off`} tone={priceOk ? undefined : "warn"} />
          </div>
          <button
            className="primary"
            disabled={busy || now < readyAt}
            onClick={() =>
              run("Moving the shadow", async (c) => {
                const { intent, signature } = await actions.signIntent(c, shadow.id, false, lower, upper);
                return actions.submitIntent(c, intent, signature);
              })
            }
          >
            {connected ? "Sign and submit" : "Connect wallet"}
          </button>
        </>
      ) : (
        <>
          <AmountField label="Stake" value={stakeUsd} setValue={setStakeUsd} unit={tokens.token1.symbol} />
          <Presets values={[10000, 20000, 50000, 100000]} current={Number(stakeUsd)} onPick={(v) => setStakeUsd(String(v))} format={(v) => `${v / 1000}K`} />
          <div className="rows">
            <Row label="You add" value={`${num(stake.amount0, 3)} ${tokens.token0.symbol}`} />
            <Row label="and" value={`${num(stake.amount1, 0)} ${tokens.token1.symbol}`} />
            <Row label="Record" value={oldEnough ? "long enough" : `${duration(mandate.minAge - age)} to go`} tone={oldEnough ? undefined : "warn"} />
            <Row label="Score" value={shadow.score ? bps(shadow.score.alphaBps) : "…"} tone={goodEnough ? undefined : "warn"} />
          </div>
          <button
            className="primary"
            disabled={busy || !oldEnough || !goodEnough || stake.liquidity === 0n}
            onClick={() =>
              run("Going live", (c) =>
                actions.goLive(c, shadow.id, stake.liquidity, fromNumber(stake.amount0 * 1.02 + 0.000001), fromNumber(stake.amount1 * 1.02 + 0.000001)),
              )
            }
          >
            {connected ? "Go live" : "Connect wallet"}
          </button>
          {(!oldEnough || !goodEnough) && (
            <p className="note warn">
              {!goodEnough
                ? `Going live needs a score of at least ${bps(mandate.graduationBps)} against passive. This shadow is not there yet.`
                : `Going live needs ${duration(mandate.minAge)} of record first.`}
            </p>
          )}
        </>
      )}
      <button className="textlink" disabled={busy} onClick={() => run("Closing the shadow", (c) => actions.closeShadow(c, shadow.id))}>
        Abandon this shadow (it stays on the record)
      </button>
    </>
  );
}

function VaultForm({ row, snapshot, busy, run, now, connected }: FormProps & { row: VaultRow; now: number }) {
  const { pool, mandate, account } = snapshot;
  const mine = account !== null && account.address.toLowerCase() === row.curator.toLowerCase();
  const [mode, setMode] = useState<"deposit" | "withdraw" | "move">("deposit");
  const [amount, setAmount] = useState("5000");
  const [half, setHalf] = useState(300);
  const value = Number(amount) || 0;
  const total = row.totalShares;
  const shares = row.nav > 0 ? (total * fromNumber(value)) / fromNumber(row.nav) : 0n;
  const fraction = row.nav > 0 ? value / row.nav : 0;
  const room = row.maxTotalShares > total ? row.maxTotalShares - total : 0n;
  const roomValue = total > 0n ? (Number(room) / Number(total)) * row.nav : 0;
  const myShares = account?.shares[row.id] ?? 0n;
  const myFraction = total > 0n ? Number(myShares) / Number(total) : 0;
  const readyAt = (row.rebalances === 0 ? row.openedAt : row.lastRebalanceAt) + mandate.cooldown;
  const { lower, upper } = rangeAround(pool.tick, half);

  return (
    <>
      <div className="seg">
        <button className={mode === "deposit" ? "on" : ""} onClick={() => setMode("deposit")}>
          Deposit
        </button>
        <button className={mode === "withdraw" ? "on" : ""} onClick={() => setMode("withdraw")}>
          Withdraw
        </button>
        {mine && (
          <button className={mode === "move" ? "on" : ""} onClick={() => setMode("move")}>
            Move
          </button>
        )}
      </div>
      {mode === "deposit" && (
        <>
          <AmountField label="Amount" value={amount} setValue={setAmount} unit={tokens.token1.symbol} />
          <Presets values={[1000, 5000, 10000, 25000]} current={value} onPick={(v) => setAmount(String(v))} format={(v) => `${v / 1000}K`} />
          <div className="rows">
            <Row label="You add" value={`${num(row.amount0 * fraction, 3)} ${tokens.token0.symbol}`} />
            <Row label="and" value={`${num(row.amount1 * fraction, 0)} ${tokens.token1.symbol}`} />
            <Row label="Room left" value={row.demoted ? "closed: demoted" : usd(roomValue)} tone={row.demoted || value > roomValue ? "warn" : undefined} />
          </div>
          <button className="primary" disabled={busy || shares === 0n || row.demoted} onClick={() => run("Depositing", (c) => actions.deposit(c, row.id, shares))}>
            {connected ? "Deposit" : "Connect wallet"}
          </button>
          <p className="note">You add the same mix of tokens the vault holds. Nothing is swapped.</p>
        </>
      )}
      {mode === "withdraw" && (
        <>
          <div className="field">
            <span className="mono">Your shares</span>
            <span>{usd(myFraction * row.nav, 2)}</span>
          </div>
          <div className="rows">
            <Row label="You receive" value={`${num(row.amount0 * myFraction, 3)} ${tokens.token0.symbol}`} />
            <Row label="and" value={`${num(row.amount1 * myFraction, 0)} ${tokens.token1.symbol}`} />
            <Row label="Needs" value="no one's permission" />
          </div>
          <button className="primary" disabled={busy || (connected && myShares === 0n)} onClick={() => run("Withdrawing", (c) => actions.withdraw(c, row.id, myShares))}>
            {connected ? "Withdraw all" : "Connect wallet"}
          </button>
        </>
      )}
      {mode === "move" && mine && (
        <>
          <RangePicker half={half} setHalf={setHalf} tick={pool.tick} />
          <div className="rows">
            <Row label="Cooldown" value={now >= readyAt ? "ready" : `ready in ${duration(readyAt - now)}`} tone={now >= readyAt ? undefined : "warn"} />
            <Row label="Loss limit" value={`${(mandate.maxLossBps / 100).toFixed(2)}% at most`} />
          </div>
          <button
            className="primary"
            disabled={busy || now < readyAt}
            onClick={() =>
              run("Moving the vault", async (c) => {
                const { intent, signature } = await actions.signIntent(c, row.id, true, lower, upper);
                return actions.submitIntent(c, intent, signature);
              })
            }
          >
            Sign and submit
          </button>
          {row.feeSharesDue > 0n && (
            <button className="textlink" disabled={busy} onClick={() => run("Settling the fee", (c) => actions.settleFee(c, row.id))}>
              Settle the fee due ({((Number(row.feeSharesDue) / Number(row.totalShares)) * 100).toFixed(3)}% of the vault)
            </button>
          )}
        </>
      )}
    </>
  );
}

function RecordTable({ snapshot, now, setTab }: { snapshot: Snapshot; now: number; setTab: (t: TabId) => void }) {
  const { shadows, mandate } = snapshot;
  if (shadows.length === 0) {
    return <div className="chart-empty mono" style={{ margin: 26 }}>No shadow has been opened yet. The first line of the record is yours.</div>;
  }
  return (
    <div className="table-wrap" style={{ padding: "8px 26px 18px" }}>
      <table>
        <thead>
          <tr>
            <th>No.</th>
            <th>Curator</th>
            <th>Range, {tokens.token1.symbol} per {tokens.token0.symbol}</th>
            <th>Record</th>
            <th className="r">Raw</th>
            <th className="r">Score</th>
            <th className="r">Status</th>
          </tr>
        </thead>
        <tbody>
          {shadows.map((s) => (
            <tr key={s.id} onClick={() => setTab(s.status === "live" ? `v${s.id}` : `s${s.id}`)}>
              <td className="mono">{pad(s.id)}</td>
              <td>
                {shortAddress(s.curator)}
                <small>
                  opened {ago(s.openedAt, now)} · {s.rebalances} {s.rebalances === 1 ? "move" : "moves"}
                </small>
              </td>
              <td>
                {usd(tickToPrice(s.tickLower))} – {usd(tickToPrice(s.tickUpper))}
                <small>{s.tickUpper - s.tickLower} ticks wide</small>
              </td>
              <td>
                {duration((s.closedAt || now) - s.openedAt)}
                <small>
                  {s.status !== "open" ? "final" : now - s.openedAt < mandate.minAge ? `${duration(mandate.minAge - (now - s.openedAt))} to go` : "long enough to go live"}
                </small>
              </td>
              <td className="r muted">{s.score ? bps(s.score.rawAlphaBps) : "—"}</td>
              <td className="r">{s.score ? bps(s.score.alphaBps) : "—"}</td>
              <td className="r">
                <span className={`state ${s.status === "closed" ? "off" : ""}`}>
                  {s.status === "open" ? "Open" : s.status === "live" ? "Went live" : "Abandoned"}
                </span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
