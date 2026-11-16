import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Hex } from "viem";
import { addresses, explorer, tokens } from "./config";
import { connect, injected, publicClient, type Clients } from "./lib/chain";
import { loadShadowHistory, loadSnapshot, type Point, type ShadowRow, type Snapshot, type VaultRow } from "./lib/data";
import * as actions from "./lib/actions";
import { ago, bps, duration, fromNumber, num, shortAddress, tickToPrice, toNumber, usd } from "./lib/math";
import { Chart } from "./components/Chart";
import { Desk } from "./components/Desk";

const SECTIONS = [
  { id: "front", label: "Front page", nav: null },
  { id: "record", label: "The record", nav: "The record" },
  { id: "figure", label: "A shadow, drawn", nav: "The figure" },
  { id: "vaults", label: "Live vaults", nav: "Vaults" },
  { id: "mandate", label: "The mandate", nav: "The mandate" },
  { id: "desk", label: "The desk", nav: "The desk" },
] as const;

const pad = (n: number) => String(n).padStart(2, "0");

function Mark() {
  return (
    <svg width="34" height="22" viewBox="0 0 34 22" aria-hidden>
      <circle cx="10" cy="11" r="8.2" fill="none" stroke="var(--ink)" strokeWidth="1.6" />
      <circle cx="21" cy="11" r="8.2" fill="var(--ink)" />
      <circle cx="31.2" cy="18.4" r="2" fill="var(--accent)" />
    </svg>
  );
}

/** Fades a block in the first time it scrolls into view. */
function Reveal({ children, className = "" }: { children: React.ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      (entries) => entries.forEach((e) => e.isIntersecting && el.classList.add("in")),
      { threshold: 0.08 },
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  return (
    <div ref={ref} className={`reveal ${className}`}>
      {children}
    </div>
  );
}

export default function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [clients, setClients] = useState<Clients | null>(null);
  const [walletNote, setWalletNote] = useState<string | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [history, setHistory] = useState<Point[]>([]);
  const [filter, setFilter] = useState<"all" | "open" | "live" | "closed">("all");
  const [page, setPage] = useState(0);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme ?? "light");

  // `?as=0x…` shows the page as that address sees it, read-only, without connecting a wallet.
  const watched = useMemo(() => {
    const value = new URLSearchParams(window.location.search).get("as");
    return value && /^0x[0-9a-fA-F]{40}$/.test(value) ? (value as `0x${string}`) : null;
  }, []);
  const account = clients?.account ?? watched;

  const refresh = useCallback(() => {
    loadSnapshot(publicClient as never, account)
      .then((s) => {
        setSnapshot(s);
        setError(null);
      })
      .catch((e: unknown) => setError(e instanceof Error ? e.message : "Could not reach the network."));
  }, [account]);

  useEffect(() => {
    refresh();
    const poll = setInterval(refresh, 10_000);
    const clock = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => {
      clearInterval(poll);
      clearInterval(clock);
    };
  }, [refresh]);

  // Follow the wallet if the user switches account.
  useEffect(() => {
    const ethereum = injected();
    if (!ethereum?.on) return;
    const onAccounts = () => setClients(null);
    ethereum.on("accountsChanged", onAccounts);
    return () => ethereum.removeListener?.("accountsChanged", onAccounts);
  }, []);

  // Which "page" of the record the reader is on, for the running head in the nav.
  useEffect(() => {
    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (e.isIntersecting) setPage(SECTIONS.findIndex((s) => s.id === e.target.id));
        });
      },
      { rootMargin: "-45% 0px -50% 0px" },
    );
    SECTIONS.forEach((s) => {
      const el = document.getElementById(s.id);
      if (el) observer.observe(el);
    });
    return () => observer.disconnect();
  }, [snapshot === null]);

  const shadows = snapshot?.shadows ?? [];
  const featured: ShadowRow | undefined = useMemo(() => {
    if (selected !== null) return shadows.find((s) => s.id === selected);
    return [...shadows].reverse().find((s) => s.status === "open") ?? shadows[shadows.length - 1];
  }, [shadows, selected]);

  const featuredKey = featured ? `${featured.id}-${featured.closedAt}-${featured.rebalances}` : "";
  const historyTick = snapshot ? Math.floor(snapshot.pool.timestamp / 45) : 0;
  useEffect(() => {
    if (!featured || !snapshot) return;
    let cancelled = false;
    loadShadowHistory(publicClient as never, featured, snapshot.pool).then((points) => {
      if (!cancelled) setHistory(points);
    });
    return () => {
      cancelled = true;
    };
  }, [featuredKey, historyTick]);

  async function onConnect() {
    setWalletNote(null);
    try {
      setClients(await connect());
    } catch (e) {
      setWalletNote(actions.explain(e));
    }
  }

  function toggleTheme() {
    const next = theme === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    try {
      localStorage.setItem("pg-theme", next);
    } catch {
      /* private window: the choice just does not persist */
    }
    setTheme(next);
  }

  const pool = snapshot?.pool;
  const mandate = snapshot?.mandate;
  const open = shadows.filter((s) => s.status === "open");
  const live = shadows.filter((s) => s.status === "live");
  const closed = shadows.filter((s) => s.status === "closed");
  const rows = filter === "all" ? shadows : filter === "open" ? open : filter === "live" ? live : closed;
  const drift = pool && pool.twapTick !== null ? pool.tick - pool.twapTick : null;
  const best = open.reduce<ShadowRow | null>(
    (top, s) => (s.score && (!top?.score || s.score.alphaBps > top.score.alphaBps) ? s : top),
    null,
  );

  const tickerItems = useMemo(() => {
    if (!snapshot || !pool || !mandate) return [];
    const items: React.ReactNode[] = [
      <>
        <b>{tokens.token0.symbol}</b> trades at {usd(pool.price, 2)}
        {drift !== null ? `, ${Math.abs(drift)} ticks from its ${duration(mandate.twapWindow)} average` : ""}
      </>,
    ];
    snapshot.shadows.forEach((s) => {
      if (s.status === "open" && s.score) {
        items.push(
          <>
            <b>Shadow No. {pad(s.id)}</b> scores {bps(s.score.alphaBps)} against a passive position after{" "}
            {duration(now - s.openedAt)}
          </>,
        );
      }
      if (s.status === "closed") {
        items.push(
          <>
            <b>Shadow No. {pad(s.id)}</b> was abandoned and stays on the record
          </>,
        );
      }
    });
    snapshot.vaults.forEach((v) => {
      items.push(
        <>
          <b>Vault No. {pad(v.id)}</b> holds {usd(v.nav)} and may take {v.multiple}× its curator's stake
        </>,
      );
    });
    items.push(
      <>
        <b>The mandate</b> allows a move every {duration(mandate.cooldown)}, within {mandate.maxDeviation} ticks of the
        average price
      </>,
    );
    return items;
  }, [snapshot, now - (now % 20)]);

  return (
    <>
      <div className="ticker">
        <span className="caps">Unichain Sepolia{pool ? ` — block ${pool.block.toLocaleString("en-US")}` : ""}</span>
        <div className="track-wrap">
          <div className="track">
            {[...tickerItems, ...tickerItems].map((item, i) => (
              <span key={i}>{item}</span>
            ))}
          </div>
        </div>
        <span className="caps">
          {tokens.token0.symbol} · <span className="num">{pool ? usd(pool.price, 2) : "…"}</span>
        </span>
      </div>

      <header className="nav">
        <a className="brand" href="#front" aria-label="Proving Ground, front page">
          <Mark />
          <span>Proving Ground</span>
          <sup>v4</sup>
        </a>
        <nav className="nav-links" aria-label="Sections">
          {SECTIONS.filter((s) => s.nav).map((s) => (
            <a key={s.id} href={`#${s.id}`} className={SECTIONS[page]?.id === s.id ? "on" : ""}>
              {s.nav}
            </a>
          ))}
        </nav>
        <div className="nav-right">
          <span className="pageref">
            p. {page + 1} — {SECTIONS[page]?.label}
          </span>
          <button className="iconbtn" onClick={toggleTheme} aria-label="Switch between the day and night edition" title="Day or night edition">
            <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
              <circle cx="7" cy="7" r="6" fill="none" stroke="var(--ink)" strokeWidth="1.3" />
              <path d="M7 1a6 6 0 0 1 0 12z" fill="var(--ink)" />
            </svg>
          </button>
          {clients ? (
            <a className="btn ghost" href={`${explorer}/address/${clients.account}`} target="_blank" rel="noreferrer">
              {shortAddress(clients.account)}
            </a>
          ) : (
            <button className="btn" onClick={onConnect}>
              Connect wallet <span aria-hidden>→</span>
            </button>
          )}
        </div>
      </header>

      <main className="wrap">
        {(error || walletNote) && (
          <div className="notice bad" style={{ marginTop: 18 }} role="alert">
            <span className="caps">{error ? "Network" : "Wallet"}</span>
            <span>
              {error ?? walletNote}{" "}
              {error && (
                <button className="link" onClick={refresh}>
                  Try again
                </button>
              )}
            </span>
          </div>
        )}

        {watched && !clients && (
          <div className="notice" style={{ marginTop: 18 }}>
            <span className="caps">Viewing</span>
            <span>
              The desk is shown as {shortAddress(watched)} sees it. Nothing can be sent until a wallet is connected.
            </span>
          </div>
        )}

        {/* ------------------------------------------------------------ front page */}
        <section id="front">
          <div className="runhead caps">
            <span>The Proving Ground — a public record</span>
            <span>A Uniswap v4 hook</span>
            <span>Filed on Unichain Sepolia</span>
          </div>

          <div className="hero">
            <h1>
              Prove it on paper. Then <em>earn</em> the capital<span className="dot">.</span>
            </h1>

            <aside className="widget" aria-label="The pool, live">
              <div className="widget-head caps">
                <span>The pool</span>
                <span className="live">
                  <i /> Live
                </span>
              </div>
              <div className="widget-big">
                <strong className="num">{pool ? Math.round(pool.price).toLocaleString("en-US") : "…"}</strong>
                <span>
                  test USD for one test ETH.{" "}
                  {drift === null
                    ? "The price average is still filling."
                    : `${Math.abs(drift)} ticks ${drift >= 0 ? "above" : "below"} its average.`}
                </span>
              </div>
              <DriftAxis drift={drift} bound={mandate?.maxDeviation ?? 100} />
              <div className="widget-foot">
                In: <em>block {pool ? pool.block.toLocaleString("en-US") : "…"}</em>
                {pool ? `, ${ago(pool.timestamp, Math.max(now, pool.timestamp))}` : ""}
              </div>
            </aside>
          </div>

          <div className="byline" />
          <div className="byline-row caps">
            <span>
              {snapshot ? `${open.length} open · ${live.length} live · ${closed.length} abandoned` : "Reading the record"}
            </span>
            <span className="accent">
              {best?.score ? `Δ ${bps(best.score.alphaBps)} · best open shadow, No. ${pad(best.id)}` : "Δ scores are against a passive position"}
            </span>
          </div>

          <div className="below">
            <div>
              <p className="lead">
                <b>Proving Ground is a Uniswap v4 hook for curated liquidity.</b> A manager first runs their strategy as
                a shadow position that needs no capital. The hook scores it against the pool's real swaps, and that score
                decides how much real money they may manage.
              </p>
              <div className="cta-row">
                <a className="btn" href="#desk">
                  Open a shadow <span aria-hidden>→</span>
                </a>
                <a className="link" href="#record">
                  Read the record ↓
                </a>
              </div>
            </div>

            <nav className="toc" aria-label="In this record">
              <div className="minihead caps">
                <span>In this record</span>
                <span>p.</span>
              </div>
              {SECTIONS.slice(1).map((s, i) => (
                <a key={s.id} href={`#${s.id}`}>
                  <span>{s.label}</span>
                  <i />
                  <span>{i + 2}</span>
                </a>
              ))}
            </nav>

            <div>
              <div className="minihead caps">
                <span>The mandate, at a glance</span>
              </div>
              <KV label="Range width" value={mandate ? `${mandate.minWidth}–${mandate.maxWidth.toLocaleString("en-US")} ticks` : null} />
              <KV label="Between moves" value={mandate ? duration(mandate.cooldown) : null} />
              <KV label="Price bound" value={mandate ? `${mandate.maxDeviation} ticks of average` : null} />
              <KV label="Loss per move" value={mandate ? `${(mandate.maxLossBps / 100).toFixed(2)}% at most` : null} />
              <KV label="Record needed" value={mandate ? duration(mandate.minAge) : null} />
              <KV label="Bond" value={mandate ? `${toNumber(mandate.bondMin)} ETH` : null} />
            </div>
          </div>
        </section>

        {/* ------------------------------------------------------------ the record */}
        <section id="record" className="section">
          <div className="section-head">
            <span className="caps">§ 01 — The record</span>
            <span className="pageref">Proving Ground · p. 2</span>
          </div>
          <Reveal>
            <div className="title-row">
              <h2>
                The <em>record.</em>
              </h2>
              <p>
                Every shadow opened on this pool, including the ones that were abandoned. A curator cannot hide a bad
                run: closing a shadow freezes its score here for good.
              </p>
            </div>

            <div className="pills">
              <div>
                {(
                  [
                    ["all", "All", shadows.length],
                    ["open", "Open", open.length],
                    ["live", "Live", live.length],
                    ["closed", "Abandoned", closed.length],
                  ] as const
                ).map(([key, label, count]) => (
                  <button key={key} className={`pill ${filter === key ? "on" : ""}`} onClick={() => setFilter(key)}>
                    {label} <small>{count}</small>
                  </button>
                ))}
              </div>
              <span className="pageref">
                Showing {rows.length} of {shadows.length}
              </span>
            </div>

            <div className="table-scroll">
              <table className="table">
                <thead>
                  <tr>
                    <th>No.</th>
                    <th>Curator</th>
                    <th>Range, USD per ETH</th>
                    <th>Record</th>
                    <th className="r">Raw</th>
                    <th className="r">Score</th>
                    <th className="r">Status</th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((s) => (
                    <tr
                      key={s.id}
                      className={featured?.id === s.id ? "sel" : ""}
                      onClick={() => {
                        setSelected(s.id);
                        document.getElementById("figure")?.scrollIntoView({ behavior: "smooth" });
                      }}
                    >
                      <td className="no">{pad(s.id)}</td>
                      <td className="name">
                        {shortAddress(s.curator)}
                        <small>
                          opened {ago(s.openedAt, now)} · moved {s.rebalances} {s.rebalances === 1 ? "time" : "times"}
                        </small>
                      </td>
                      <td className="sub num">
                        {usd(tickToPrice(s.tickLower))} – {usd(tickToPrice(s.tickUpper))}
                        <small>{s.tickUpper - s.tickLower} ticks wide</small>
                      </td>
                      <td className="sub">
                        {duration((s.closedAt || now) - s.openedAt)}
                        <small>
                          {s.status === "open" && mandate && now - s.openedAt < mandate.minAge
                            ? `${duration(mandate.minAge - (now - s.openedAt))} to go`
                            : s.status === "open"
                              ? "long enough to go live"
                              : "final"}
                        </small>
                      </td>
                      <td className="r big num muted">{s.score ? bps(s.score.rawAlphaBps) : "—"}</td>
                      <td className="r big num">{s.score ? bps(s.score.alphaBps) : "—"}</td>
                      <td className="r">
                        {s.status === "open" && <span className="status">Open</span>}
                        {s.status === "live" && <span className="status live-st">Went live</span>}
                        {s.status === "closed" && <span className="status off">Abandoned</span>}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              {snapshot && rows.length === 0 && (
                <div className="empty">
                  {shadows.length === 0 ? "No shadow has been opened yet. The first line of the record is yours." : "Nothing under this heading."}
                </div>
              )}
              {!snapshot && <div className="empty">Reading the record from the chain…</div>}
            </div>
            <div className="tablefoot">
              <span className="serif">
                Scores are in basis points against a passive full-range position of the same starting value. Raw is before
                the haircut for the dilution real capital would have caused.
              </span>
              <span className="caps">{pool ? `Read at block ${pool.block.toLocaleString("en-US")}` : ""}</span>
            </div>
          </Reveal>
        </section>

        {/* ------------------------------------------------------------ the figure */}
        <section id="figure" className="section">
          <div className="section-head">
            <span className="caps">§ 02 — By the numbers</span>
            <span className="pageref">Proving Ground · p. 3</span>
          </div>
          <Reveal>
            {featured ? (
              <FigureSection shadow={featured} history={history} now={now} twapWindow={mandate?.twapWindow ?? 300} />
            ) : (
              <div className="title-row">
                <h2>
                  A shadow, <em>drawn.</em>
                </h2>
                <p>Once a shadow is open, its value is drawn here against the passive position it has to beat.</p>
              </div>
            )}
          </Reveal>
        </section>

        {/* ------------------------------------------------------------ vaults */}
        <section id="vaults" className="section">
          <div className="section-head">
            <span className="caps">§ 03 — Live vaults</span>
            <span className="pageref">Proving Ground · p. 4</span>
          </div>
          <Reveal>
            <div className="title-row">
              <h2>
                Real money, <em>earned.</em>
              </h2>
              <p>
                A curator who graduates funds a vault with their own stake. Outside deposits are capped at a multiple of
                that stake, and the multiple is set by the score. Deposits and withdrawals are in kind: nothing is
                swapped, and leaving needs no one's permission.
              </p>
            </div>
            {snapshot && snapshot.vaults.length === 0 && (
              <div className="empty" style={{ borderTop: "2px solid var(--rule-strong)" }}>
                No one has graduated yet. A shadow needs {mandate ? duration(mandate.minAge) : "a minimum"} of record and a
                score at or above the passive position.
              </div>
            )}
            {snapshot?.vaults.map((v) => (
              <VaultBlock
                key={v.id}
                row={v}
                snapshot={snapshot}
                clients={clients}
                onConnect={onConnect}
                refresh={refresh}
                now={now}
              />
            ))}
          </Reveal>
        </section>

        {/* ------------------------------------------------------------ the mandate */}
        <section id="mandate" className="section">
          <div className="section-head">
            <span className="caps">§ 04 — The mandate</span>
            <span className="pageref">Proving Ground · p. 5</span>
          </div>
          <Reveal>
            <MandateSection snapshot={snapshot} subject={featured} now={now} />
          </Reveal>
        </section>

        {/* ------------------------------------------------------------ the desk */}
        <section id="desk" className="section">
          <div className="section-head">
            <span className="caps">§ 05 — The desk</span>
            <span className="pageref">Proving Ground · p. 6</span>
          </div>
          <Reveal>
            <div className="title-row">
              <h2>
                Your <em>desk.</em>
              </h2>
              <p>
                Everything a curator does, from one wallet on the test network: fund it, trade, open a shadow, move it by
                signed instruction, and go live.
              </p>
            </div>
            {snapshot ? (
              <Desk snapshot={snapshot} clients={clients} onConnect={onConnect} refresh={refresh} now={now} />
            ) : (
              <div className="empty">Reading the pool…</div>
            )}
          </Reveal>
        </section>

        <footer>
          <div className="closing">
            <h2>
              Check the record <em>before</em> the deposit<span className="accent">.</span>
            </h2>
            <p className="lead" style={{ margin: 0 }}>
              The score is an estimate, tested against real positions and published with its error. The contracts have no
              owner, and their limits cannot be changed after deployment.
            </p>
          </div>
          <div className="colophon caps">
            <span>
              Hook{" "}
              <a href={`${explorer}/address/${addresses.hook}`} target="_blank" rel="noreferrer">
                {shortAddress(addresses.hook)}
              </a>{" "}
              · Vault{" "}
              <a href={`${explorer}/address/${addresses.vault}`} target="_blank" rel="noreferrer">
                {shortAddress(addresses.vault)}
              </a>{" "}
              · Unichain Sepolia
            </span>
            <span>Built for the Uniswap Hook Incubator, UHI11</span>
            <a href="https://github.com/big14way/proving-ground" target="_blank" rel="noreferrer">
              Source and tests
            </a>
          </div>
        </footer>
      </main>
    </>
  );
}

function KV({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="kv">
      <span className="caps">{label}</span>
      <b className="num">{value ?? <span className="skeleton">00000</span>}</b>
    </div>
  );
}

/** Where the pool price sits against its average, on the scale the mandate allows. */
function DriftAxis({ drift, bound }: { drift: number | null; bound: number }) {
  const W = 250;
  const clamp = drift === null ? 0 : Math.max(-bound, Math.min(bound, drift));
  const x = (v: number) => 6 + ((v + bound) / (2 * bound)) * (W - 12);
  return (
    <svg width="100%" viewBox={`0 0 ${W} 34`} role="img" aria-label="Pool price against its average">
      <line x1="6" x2={W - 6} y1="12" y2="12" stroke="var(--rule-strong)" strokeWidth="1" />
      {Array.from({ length: 11 }, (_, i) => (
        <line key={i} x1={6 + (i * (W - 12)) / 10} x2={6 + (i * (W - 12)) / 10} y1="8" y2="12" stroke="var(--muted)" strokeWidth="1" />
      ))}
      <circle cx={x(0)} cy="12" r="3.6" fill="var(--ink)" />
      {drift !== null && <circle cx={x(clamp)} cy="12" r="4.4" fill="var(--accent)" />}
      <text x="6" y="30" fontSize="9" fontFamily="var(--sans)" fontWeight="500" letterSpacing="0.8" fill="var(--muted)">
        −{bound}
      </text>
      <text x={W / 2} y="30" textAnchor="middle" fontSize="9" fontFamily="var(--sans)" fontWeight="500" letterSpacing="0.8" fill="var(--muted)">
        AVERAGE
      </text>
      <text x={W - 6} y="30" textAnchor="end" fontSize="9" fontFamily="var(--sans)" fontWeight="500" letterSpacing="0.8" fill="var(--muted)">
        +{bound}
      </text>
    </svg>
  );
}

function FigureSection({ shadow, history, now, twapWindow }: { shadow: ShadowRow; history: Point[]; now: number; twapWindow: number }) {
  const score = shadow.score;
  const alpha = score?.alphaBps ?? null;
  return (
    <div className="figure">
      <div>
        <div className="giant num">
          {alpha === null ? "—" : `${alpha > 0 ? "+" : alpha < 0 ? "−" : ""}${Math.abs(alpha)}`}
          <span>bps</span>
        </div>
        <div className="double" />
        <span className="caps muted">
          Shadow No. {pad(shadow.id)} · against a passive position · {duration((shadow.closedAt || now) - shadow.openedAt)} of record
        </span>
        <p className="giant-note">
          {alpha === null
            ? `The score appears once the pool has ${duration(twapWindow)} of price history.`
            : alpha >= 0
              ? "Ahead of a passive liquidity provider, after the haircut. That is the bar for going live."
              : "Behind a passive liquidity provider. A shadow in this state cannot go live."}
        </p>
      </div>

      <div>
        <h2 style={{ marginBottom: 30 }}>
          A shadow, <em>drawn.</em>
        </h2>
        <Chart
          points={history}
          caption={`Fig. 1 — Shadow No. ${pad(shadow.id)}, value in test USD`}
          valueLabel={shadow.status === "open" ? "At the pool price of each moment" : "Until it closed"}
        />
        <div className="figrow">
          <strong className="num">{score ? usd(score.nav) : "—"}</strong>
          <p>
            what the shadow is worth now, counted conservatively. <em>{score ? usd(score.navRaw) : "—"} before the haircut.</em>
          </p>
        </div>
        <div className="figrow">
          <strong className="num">{score ? usd(score.navBenchmark) : "—"}</strong>
          <p>what a passive full-range position of the same starting value is worth, fees included.</p>
        </div>
        <div className="figrow">
          <strong className="num">{score ? usd(score.navHold) : "—"}</strong>
          <p>
            what simply holding the starting tokens is worth. <em>{score ? bps(score.alphaVsHoldBps) : ""} against it.</em>
          </p>
        </div>
        <div className="figrow">
          <strong className="num">{shadow.rebalances}</strong>
          <p>
            {shadow.rebalances === 1 ? "move" : "moves"} by signed instruction, at a modelled cost of{" "}
            {score ? usd(score.rebalanceCost, 2) : "—"} in fees and price impact.
          </p>
        </div>
      </div>
    </div>
  );
}

function VaultBlock({
  row,
  snapshot,
  clients,
  onConnect,
  refresh,
  now,
}: {
  row: VaultRow;
  snapshot: Snapshot;
  clients: Clients | null;
  onConnect: () => void;
  refresh: () => void;
  now: number;
}) {
  const [amount, setAmount] = useState("5000");
  const [note, setNote] = useState<{ bad: boolean; text: string; hash?: Hex } | null>(null);
  const [busy, setBusy] = useState(false);
  const account = snapshot.account;
  const myShares = account?.shares[row.id] ?? 0n;
  const total = row.totalShares;
  const closed = row.closedAt !== 0;

  const value = Number(amount) || 0;
  const shares = row.nav > 0 ? (total * fromNumber(value)) / fromNumber(row.nav) : 0n;
  const fraction = row.nav > 0 ? value / row.nav : 0;
  const room = row.maxTotalShares > total ? row.maxTotalShares - total : 0n;
  const roomValue = total > 0n ? (Number(room) / Number(total)) * row.nav : 0;
  const stakeShare = total > 0n ? Number(row.curatorShares) / Number(total) : 0;
  const myValue = total > 0n ? (Number(myShares) / Number(total)) * row.nav : 0;
  const usedOfCap = row.maxTotalShares > 0n ? Math.min(1, Number(total) / Number(row.maxTotalShares)) : 1;
  const stakeOfCap = row.maxTotalShares > 0n ? Math.min(1, Number(row.curatorShares) / Number(row.maxTotalShares)) : 0;

  const state = closed
    ? { text: "Closed", tone: "off" }
    : row.demoted
      ? { text: "Demoted: no new deposits", tone: "off" }
      : room === 0n
        ? { text: "At capacity", tone: "" }
        : { text: "Open to deposits", tone: "" };

  async function run(label: string, job: (c: Clients) => Promise<Hex>) {
    if (!clients) return onConnect();
    setBusy(true);
    setNote({ bad: false, text: `${label}: confirm in your wallet, then wait for the block.` });
    try {
      const hash = await job(clients);
      setNote({ bad: false, text: `${label}: done.`, hash });
      refresh();
    } catch (e) {
      setNote({ bad: true, text: actions.explain(e) });
    } finally {
      setBusy(false);
    }
  }

  return (
    <article className="vault">
      <div>
        <span className="caps muted">Vault No. {pad(row.id)}</span>
        <h3>{shortAddress(row.curator)}</h3>
        <p className="sub">
          Live for {duration((row.closedAt || now) - row.openedAt)}, on {usd(tickToPrice(row.tickLower))} to{" "}
          {usd(tickToPrice(row.tickUpper))}. Graduated at {bps(row.shadowAlphaBps)}.
        </p>
        <span className={`status ${state.tone}`}>{state.text}</span>
      </div>

      <div>
        <KV label="Under management" value={usd(row.nav)} />
        <KV label="Score since opening, after fees" value={bps(row.liveAlphaBps)} />
        <KV label="Holdings" value={`${num(row.amount0, 2)} ETH + ${num(row.amount1, 0)} USD`} />
        <KV label="Multiple earned" value={`${row.multiple}× the stake`} />
        <div className="meter">
          <svg viewBox="0 0 400 22" role="img" aria-label="Capacity used">
            <line x1="4" x2="396" y1="11" y2="11" stroke="var(--muted)" strokeWidth="1" />
            <line x1="4" x2={4 + 392 * usedOfCap} y1="11" y2="11" stroke="var(--accent)" strokeWidth="2" />
            <line x1="4" x2={4 + 392 * stakeOfCap} y1="11" y2="11" stroke="var(--ink)" strokeWidth="2" />
            <circle cx="4" cy="11" r="4" fill="var(--ink)" />
            <circle cx={4 + 392 * stakeOfCap} cy="11" r="4" fill="var(--ink)" />
            <circle cx={4 + 392 * usedOfCap} cy="11" r="4" fill="var(--accent)" />
            <circle cx="396" cy="11" r="4" fill="var(--paper)" stroke="var(--ink)" strokeWidth="1.4" />
          </svg>
        </div>
        <div className="meter-labels caps">
          <span>Curator's stake {(stakeShare * 100).toFixed(0)}%</span>
          <span>{room > 0n ? `Room for ${usd(roomValue)} more` : "No room left"}</span>
        </div>
      </div>

      <div className="form">
        {myShares > 0n && (
          <div className="kv" style={{ borderTop: "1px solid var(--rule-strong)" }}>
            <span className="caps">Your shares</span>
            <b className="num">{usd(myValue)}</b>
          </div>
        )}
        {!closed && (
          <>
            <div className="field">
              <label className="caps">Deposit, in test USD of value</label>
              <div className="inputrow">
                <input inputMode="decimal" value={amount} onChange={(e) => setAmount(e.target.value)} aria-label="Deposit value in test USD" />
                <span className="unit">
                  {num(row.amount0 * fraction, 3)} ETH + {num(row.amount1 * fraction, 0)} USD
                </span>
              </div>
            </div>
            <div className="btnrow">
              <button className="btn" disabled={busy || shares === 0n || row.demoted} onClick={() => run("Depositing", (c) => actions.deposit(c, row.id, shares))}>
                {clients ? "Deposit" : "Connect to deposit"} <span aria-hidden>→</span>
              </button>
              {myShares > 0n && (
                <button className="btn ghost" disabled={busy} onClick={() => run("Withdrawing", (c) => actions.withdraw(c, row.id, myShares))}>
                  Withdraw all
                </button>
              )}
            </div>
            <p className="hint">You add the same mix of tokens the vault holds, and take the same mix out.</p>
          </>
        )}
        {note && (
          <p className={`hint ${note.bad ? "accent" : ""}`} role="status">
            {note.text}{" "}
            {note.hash && (
              <a href={`${explorer}/tx/${note.hash}`} target="_blank" rel="noreferrer">
                View the transaction
              </a>
            )}
          </p>
        )}
      </div>
    </article>
  );
}

function MandateSection({ snapshot, subject, now }: { snapshot: Snapshot | null; subject: ShadowRow | undefined; now: number }) {
  const mandate = snapshot?.mandate;
  const pool = snapshot?.pool;
  const drift = pool && pool.twapTick !== null ? Math.abs(pool.tick - pool.twapTick) : null;
  const priceOk = drift !== null && mandate ? drift <= mandate.maxDeviation : null;
  const openSubject = subject?.status === "open" ? subject : undefined;
  const readyAt = openSubject && mandate ? (openSubject.rebalances === 0 ? openSubject.openedAt : openSubject.lastRebalanceAt) + mandate.cooldown : null;
  const cooled = readyAt !== null ? now >= readyAt : null;
  const passing = [true, true, cooled ?? true, priceOk ?? false].filter(Boolean).length;

  const steps = [
    {
      n: "01",
      title: "Signature",
      body: "Only the curator's signature can move a position. Anyone may carry the signed instruction to the chain; each one works once and expires.",
      verdict: openSubject ? `Curator ${shortAddress(openSubject.curator)}` : "Typed data, contract wallets too",
      done: true,
    },
    {
      n: "02",
      title: "Range",
      body: mandate
        ? `The new range sits on the pool's tick grid, contains the current price, and is between ${mandate.minWidth} and ${mandate.maxWidth.toLocaleString("en-US")} ticks wide.`
        : "",
      verdict: openSubject ? `Now ${openSubject.tickUpper - openSubject.tickLower} ticks wide` : "Checked on every move",
      done: true,
    },
    {
      n: "03",
      title: "Cooldown",
      body: mandate ? `At least ${duration(mandate.cooldown)} must pass between one move and the next.` : "",
      verdict: cooled === null ? "Per position" : cooled ? "Ready to move" : `Ready in ${duration((readyAt ?? now) - now)}`,
      done: cooled !== false,
    },
    {
      n: "04",
      title: "Price",
      body: mandate
        ? `The pool price must be within ${mandate.maxDeviation} ticks of its ${duration(mandate.twapWindow)} average, so a price pushed for one transaction cannot be used.`
        : "",
      verdict: drift === null ? "Average still filling" : `Now ${drift} ticks off: ${priceOk ? "passes" : "would be refused"}`,
      done: priceOk === true,
    },
    {
      n: "05",
      title: "Loss limit",
      body: mandate
        ? `For real money only. After the vault's own swap, its tokens must be worth at least ${(100 - mandate.maxLossBps / 100).toFixed(1)}% of what they were, at the average price.`
        : "",
      verdict: "Live vaults only",
      done: false,
    },
  ];

  return (
    <>
      <div className="title-row">
        <h2>
          Signed, then <em>checked.</em>
        </h2>
        <div className="elapsed">
          <span className="caps muted">Checks passing right now</span>
          <b className="num">
            <em>{passing} of</em>4
          </b>
        </div>
      </div>
      <div className="steps">
        {steps.map((s) => (
          <div key={s.n} className={`step ${s.done ? "done" : ""}`}>
            <span className="caps muted">Check</span>
            <b className="num">{s.n}</b>
            <h4>{s.title}</h4>
            <p>{s.body}</p>
            <div className="verdict caps">{s.verdict}</div>
          </div>
        ))}
      </div>
    </>
  );
}
