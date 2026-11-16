import { useMemo, useState } from "react";
import type { Hex } from "viem";
import * as actions from "../lib/actions";
import type { Clients } from "../lib/chain";
import type { Snapshot, ShadowRow, VaultRow } from "../lib/data";
import { amountsFor, bps, duration, floorTick, fromNumber, liquidityForValue, num, tickToPrice, toNumber, usd } from "../lib/math";
import { explorer, TICK_SPACING } from "../config";

type Props = {
  snapshot: Snapshot;
  clients: Clients | null;
  onConnect: () => void;
  refresh: () => void;
  now: number;
};

type Notice = { tone: "busy" | "good" | "bad"; text: string; hash?: Hex } | null;

/** Width choices offered for a range, as a percentage either side of the current price. */
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

export function Desk({ snapshot, clients, onConnect, refresh, now }: Props) {
  const { pool, mandate, account, shadows, vaults } = snapshot;
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState(false);

  const myShadow: ShadowRow | undefined = account ? shadows.find((s) => s.id === account.activeShadow) : undefined;
  const myVaults: VaultRow[] = account
    ? vaults.filter((v) => v.curator.toLowerCase() === account.address.toLowerCase() && v.closedAt === 0)
    : [];
  const lockedBonds = account
    ? shadows.filter(
        (s) =>
          s.curator.toLowerCase() === account.address.toLowerCase() &&
          s.status === "closed" &&
          s.bond > 0n &&
          now >= s.openedAt + mandate.minAge,
      )
    : [];

  async function run(label: string, job: (c: Clients) => Promise<Hex | void>) {
    if (!clients) return onConnect();
    setBusy(true);
    setNotice({ tone: "busy", text: `${label}: confirm in your wallet, then wait for the block.` });
    try {
      const hash = await job(clients);
      setNotice({ tone: "good", text: `${label}: done.`, hash: hash ?? undefined });
      refresh();
    } catch (error) {
      setNotice({ tone: "bad", text: actions.explain(error) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      {notice && (
        <div className={`notice ${notice.tone === "bad" ? "bad" : ""}`} style={{ marginBottom: 34 }} role="status">
          <span className="caps">{notice.tone === "busy" ? "In progress" : notice.tone === "good" ? "Done" : "Refused"}</span>
          <span>
            {notice.text}{" "}
            {notice.hash && (
              <a href={`${explorer}/tx/${notice.hash}`} target="_blank" rel="noreferrer">
                View the transaction
              </a>
            )}
          </span>
        </div>
      )}

      <div className="desk">
        <section className="panel">
          <span className="caps muted">i. Test tokens and trading</span>
          <h3>Fund the wallet, move the price</h3>
          <p>
            The pool trades two test tokens that anyone can mint. Swaps are what a shadow is scored against, so make
            a few.
          </p>
          {account ? (
            <div className="form">
              <div className="kv">
                <span className="caps">Test ETH</span>
                <b className="num">{num(toNumber(account.balance0), 3)}</b>
              </div>
              <div className="kv">
                <span className="caps">Test USD</span>
                <b className="num">{num(toNumber(account.balance1), 0)}</b>
              </div>
              <div className="btnrow" style={{ marginTop: 6 }}>
                <button
                  className="btn small"
                  disabled={busy}
                  onClick={() => run("Minting test tokens", (c) => actions.faucet(c, fromNumber(20), fromNumber(60_000)))}
                >
                  Mint 20 ETH and 60,000 USD
                </button>
              </div>
              <SwapForm busy={busy} run={run} price={pool.price} />
            </div>
          ) : (
            <Connect onConnect={onConnect} />
          )}
        </section>

        <section className="panel">
          <span className="caps muted">ii. Your shadow</span>
          {!account ? (
            <>
              <h3>Open a shadow</h3>
              <p>A shadow needs no capital. It needs a wallet, a range and a small bond.</p>
              <Connect onConnect={onConnect} />
            </>
          ) : myShadow ? (
            <ShadowPanel shadow={myShadow} snapshot={snapshot} busy={busy} run={run} now={now} />
          ) : (
            <OpenShadow snapshot={snapshot} busy={busy} run={run} />
          )}
          {lockedBonds.map((s) => (
            <div className="btnrow" style={{ marginTop: 16 }} key={s.id}>
              <button
                className="btn ghost small"
                disabled={busy}
                onClick={() => run(`Returning the bond of shadow ${s.id}`, (c) => actions.withdrawBond(c, s.id))}
              >
                Take back the bond of shadow No. {String(s.id).padStart(2, "0")}
              </button>
            </div>
          ))}
        </section>

        <section className="panel">
          <span className="caps muted">iii. Your vault</span>
          {!account ? (
            <>
              <h3>Manage real liquidity</h3>
              <p>Once a shadow graduates, its curator moves the vault's liquidity from here, by signed instruction.</p>
              <Connect onConnect={onConnect} />
            </>
          ) : myVaults.length === 0 ? (
            <>
              <h3>No vault yet</h3>
              <p>
                A vault opens when your shadow has {duration(mandate.minAge)} of record and scores at or above the
                passive position. Then you go live with your own stake.
              </p>
            </>
          ) : (
            myVaults.map((v) => <VaultPanel key={v.id} row={v} snapshot={snapshot} busy={busy} run={run} now={now} />)
          )}
        </section>
      </div>
    </>
  );
}

type Run = (label: string, job: (c: Clients) => Promise<Hex | void>) => Promise<void>;

function Connect({ onConnect }: { onConnect: () => void }) {
  return (
    <div className="btnrow">
      <button className="btn" onClick={onConnect}>
        Connect a wallet <span aria-hidden>→</span>
      </button>
    </div>
  );
}

function SwapForm({ busy, run, price }: { busy: boolean; run: Run; price: number }) {
  const [amount, setAmount] = useState("5000");
  const [side, setSide] = useState<"buy" | "sell">("buy");
  const value = Number(amount) || 0;
  return (
    <>
      <div className="field" style={{ marginTop: 14 }}>
        <label className="caps">Swap, in test USD</label>
        <div className="inputrow">
          <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} aria-label="Swap size in test USD" />
          <span className="unit">≈ {num(value / price, 3)} ETH</span>
        </div>
      </div>
      <div className="btnrow">
        <button
          className="btn small"
          disabled={busy || value <= 0}
          onClick={() => {
            setSide("buy");
            run("Buying test ETH", (c) => actions.swap(c, false, fromNumber(value)));
          }}
        >
          Buy ETH
        </button>
        <button
          className="btn ghost small"
          disabled={busy || value <= 0}
          onClick={() => {
            setSide("sell");
            run("Selling test ETH", (c) => actions.swap(c, true, fromNumber(value / price)));
          }}
        >
          Sell ETH
        </button>
        <span className="hint">{side === "buy" ? "Buying pushes the price up." : "Selling pushes the price down."}</span>
      </div>
    </>
  );
}

function RangeField({
  half,
  setHalf,
  tick,
}: {
  half: number;
  setHalf: (ticks: number) => void;
  tick: number;
}) {
  const { lower, upper } = rangeAround(tick, half);
  return (
    <div className="field">
      <label className="caps">Range around the current price</label>
      <div className="btnrow">
        {WIDTHS.map((w) => (
          <button key={w.ticks} className={`pill ${half === w.ticks ? "on" : ""}`} onClick={() => setHalf(w.ticks)} type="button">
            {w.label}
          </button>
        ))}
      </div>
      <p className="hint">
        {usd(tickToPrice(lower))} to {usd(tickToPrice(upper))} per ETH (ticks {lower} to {upper}).
      </p>
    </div>
  );
}

function OpenShadow({ snapshot, busy, run }: { snapshot: Snapshot; busy: boolean; run: Run }) {
  const { pool, mandate } = snapshot;
  const [half, setHalf] = useState(300);
  const [share, setShare] = useState("100");
  const { lower, upper } = rangeAround(pool.tick, half);
  const cap = (pool.liquidity * BigInt(mandate.shadowMaxShareBps)) / 10_000n;
  const percent = Math.min(100, Math.max(1, Number(share) || 0));
  const liquidity = (cap * BigInt(Math.round(percent * 100))) / 10_000n;
  const held = amountsFor(pool.price, lower, upper, liquidity);
  const value = held.amount0 * pool.price + held.amount1;

  return (
    <>
      <h3>Open a shadow</h3>
      <p>
        Pick the range you would provide liquidity on. The hook scores it against every swap from now on, as if the
        position were real.
      </p>
      <div className="form">
        <RangeField half={half} setHalf={setHalf} tick={pool.tick} />
        <div className="field">
          <label className="caps">Size, as a share of the largest shadow allowed</label>
          <div className="inputrow">
            <input inputMode="numeric" value={share} onChange={(e) => setShare(e.target.value)} aria-label="Shadow size in percent of the cap" />
            <span className="unit">% · worth {usd(value)}</span>
          </div>
        </div>
        <p className="hint">
          Bond: {toNumber(mandate.bondMin)} test ETH, returned once the shadow is closed or goes live and{" "}
          {duration(mandate.minAge)} have passed.
        </p>
        <div className="btnrow">
          <button
            className="btn"
            disabled={busy || liquidity === 0n}
            onClick={() => run("Opening the shadow", (c) => actions.openShadow(c, lower, upper, liquidity, mandate.bondMin))}
          >
            Open the shadow <span aria-hidden>→</span>
          </button>
        </div>
      </div>
    </>
  );
}

function SignedMove({
  subject,
  live,
  snapshot,
  busy,
  run,
  readyAt,
  now,
}: {
  subject: number;
  live: boolean;
  snapshot: Snapshot;
  busy: boolean;
  run: Run;
  readyAt: number;
  now: number;
}) {
  const { pool } = snapshot;
  const [half, setHalf] = useState(300);
  const { lower, upper } = rangeAround(pool.tick, half);
  const wait = readyAt - now;
  return (
    <div className="form" style={{ marginTop: 18 }}>
      <RangeField half={half} setHalf={setHalf} tick={pool.tick} />
      <div className="btnrow">
        <button
          className="btn"
          disabled={busy || wait > 0}
          onClick={() =>
            run(live ? "Moving the vault" : "Moving the shadow", async (c) => {
              const { intent, signature } = await actions.signIntent(c, subject, live, lower, upper);
              return actions.submitIntent(c, intent, signature);
            })
          }
        >
          Sign and submit the move <span aria-hidden>→</span>
        </button>
        {wait > 0 && <span className="hint">Cooldown: ready in {duration(wait)}.</span>}
      </div>
      <p className="hint">
        Your wallet signs a typed instruction first. Then it is submitted, and the hook checks it against the mandate.
      </p>
    </div>
  );
}

function ShadowPanel({
  shadow,
  snapshot,
  busy,
  run,
  now,
}: {
  shadow: ShadowRow;
  snapshot: Snapshot;
  busy: boolean;
  run: Run;
  now: number;
}) {
  const { mandate, pool, account } = snapshot;
  const [stakeUsd, setStakeUsd] = useState("20000");
  const age = now - shadow.openedAt;
  const old = age >= mandate.minAge;
  const good = shadow.score !== null && shadow.score.alphaBps >= mandate.graduationBps;
  const readyAt = (shadow.rebalances === 0 ? shadow.openedAt : shadow.lastRebalanceAt) + mandate.cooldown;

  const stake = useMemo(() => {
    const value = Number(stakeUsd) || 0;
    const liquidity = liquidityForValue(pool.price, shadow.tickLower, shadow.tickUpper, value);
    const held = amountsFor(pool.price, shadow.tickLower, shadow.tickUpper, liquidity);
    return { liquidity, amount0: held.amount0, amount1: held.amount1 };
  }, [stakeUsd, pool.price, shadow.tickLower, shadow.tickUpper]);
  const short =
    account !== null &&
    (toNumber(account.balance0) < stake.amount0 * 1.01 || toNumber(account.balance1) < stake.amount1 * 1.01);

  return (
    <>
      <h3>Shadow No. {String(shadow.id).padStart(2, "0")} is open</h3>
      <p>
        {usd(tickToPrice(shadow.tickLower))} to {usd(tickToPrice(shadow.tickUpper))}, {duration(age)} old
        {shadow.score ? `, scoring ${bps(shadow.score.alphaBps)} against the passive position.` : "."}
      </p>

      <span className="caps muted">Move it</span>
      <SignedMove subject={shadow.id} live={false} snapshot={snapshot} busy={busy} run={run} readyAt={readyAt} now={now} />

      <div className="double" />
      <span className="caps muted">Go live</span>
      {!old ? (
        <p className="hint" style={{ marginTop: 8 }}>
          {duration(mandate.minAge - age)} more of record needed before this shadow can go live.
        </p>
      ) : !good ? (
        <p className="hint" style={{ marginTop: 8 }}>
          The shadow is old enough, but it is scoring below the passive position. It cannot go live until it is level
          or ahead.
        </p>
      ) : (
        <div className="form" style={{ marginTop: 10 }}>
          <div className="field">
            <label className="caps">Your stake, in test USD of value</label>
            <div className="inputrow">
              <input inputMode="decimal" value={stakeUsd} onChange={(e) => setStakeUsd(e.target.value)} aria-label="Stake in test USD" />
              <span className="unit">
                {num(stake.amount0, 3)} ETH + {num(stake.amount1, 0)} USD
              </span>
            </div>
          </div>
          {short && <p className="hint accent">This wallet holds less than that. Mint test tokens first.</p>}
          <div className="btnrow">
            <button
              className="btn"
              disabled={busy || stake.liquidity === 0n || short}
              onClick={() =>
                run("Going live", (c) =>
                  actions.goLive(
                    c,
                    shadow.id,
                    stake.liquidity,
                    fromNumber(stake.amount0 * 1.02 + 0.000001),
                    fromNumber(stake.amount1 * 1.02 + 0.000001),
                  ),
                )
              }
            >
              Go live with this stake <span aria-hidden>→</span>
            </button>
          </div>
        </div>
      )}

      <div className="btnrow" style={{ marginTop: 22 }}>
        <button className="link" disabled={busy} onClick={() => run("Closing the shadow", (c) => actions.closeShadow(c, shadow.id))}>
          Abandon this shadow
        </button>
        <span className="hint">It stays on the record as abandoned.</span>
      </div>
    </>
  );
}

function VaultPanel({ row, snapshot, busy, run, now }: { row: VaultRow; snapshot: Snapshot; busy: boolean; run: Run; now: number }) {
  const { mandate } = snapshot;
  const readyAt = (row.rebalances === 0 ? row.openedAt : row.lastRebalanceAt) + mandate.cooldown;
  return (
    <>
      <h3>Vault No. {String(row.id).padStart(2, "0")}</h3>
      <p>
        {usd(row.nav)} under management on {usd(tickToPrice(row.tickLower))} to {usd(tickToPrice(row.tickUpper))}. Moved{" "}
        {row.rebalances} {row.rebalances === 1 ? "time" : "times"} so far.
      </p>
      <span className="caps muted">Move the liquidity</span>
      <SignedMove subject={row.id} live snapshot={snapshot} busy={busy} run={run} readyAt={readyAt} now={now} />
      {row.feeSharesDue > 0n && (
        <div className="btnrow" style={{ marginTop: 18 }}>
          <button className="btn ghost small" disabled={busy} onClick={() => run("Settling the fee", (c) => actions.settleFee(c, row.id))}>
            Settle the fee due
          </button>
          <span className="hint">{((Number(row.feeSharesDue) / Number(row.totalShares)) * 100).toFixed(3)}% of the vault, in new shares.</span>
        </div>
      )}
    </>
  );
}
