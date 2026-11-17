import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { AnimatePresence, motion, useScroll, useTransform } from "motion/react";
import { addresses, explorer, tokens } from "./config";
import { connect, injected, publicClient, type Clients } from "./lib/chain";
import { loadShadowHistory, loadSnapshot, type Point, type ShadowRow, type Snapshot } from "./lib/data";
import * as actions from "./lib/actions";
import { bps, duration, shortAddress, tickToPrice, toNumber, usd } from "./lib/math";
import { DeskWindow, type TabId } from "./components/DeskWindow";
import { Story, type Step } from "./components/Story";

const NAV = [
  { id: "desk", label: "Desk" },
  { id: "record", label: "Record" },
  { id: "mandate", label: "Mandate" },
  { id: "vaults", label: "Vaults" },
  { id: "questions", label: "FAQ" },
] as const;

const pad = (n: number) => String(n).padStart(2, "0");

function Mark({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 20 20" aria-hidden>
      <rect x="1" y="1" width="11" height="11" fill="none" stroke="var(--ink)" strokeWidth="1.6" />
      <rect x="7" y="7" width="12" height="12" fill="var(--ink)" />
    </svg>
  );
}

const QUESTIONS = [
  {
    q: "What is a shadow position?",
    a: "A liquidity position that exists only on paper. The curator picks a range and a size, and the hook works out what that position would have earned from the pool's real swaps. It needs no capital, only a small bond.",
  },
  {
    q: "How is the score worked out?",
    a: "The hook keeps a dust-sized real position on the shadow's ticks so the pool tracks fees there. The shadow's fees are its size times that fee growth, scaled down for the dilution real capital would have caused. Its value is compared with a passive full-range position of the same starting value.",
  },
  {
    q: "How close is the score to a real position?",
    a: "It is checked against an identical pool that holds the same position with real tokens. On synthetic swaps the conservative fee figure is within one percent at the supported size. On a replay of 76,428 real Unichain swaps, with the pool kept at market prices, the shadow's value after thirteen moves was within two basis points of the real position's. If traders are instead assumed to swap the same amounts, the score comes out up to 1.6 percent of fees below the real position: it errs against the curator.",
  },
  {
    q: "What stops a curator from gaming it?",
    a: "A position moves only by a signed instruction that passes fixed checks: range width, a cooldown, and a pool price close to its time-weighted average. Abandoned shadows stay on the record, and each one costs a locked bond.",
  },
  {
    q: "Can a curator run off with deposits?",
    a: "No. The vault only moves liquidity between ranges of the same pool, through the mandate. Deposits and withdrawals are in kind, and a withdrawal needs neither the curator, the oracle nor the hook.",
  },
];

export default function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [clients, setClients] = useState<Clients | null>(null);
  const [walletNote, setWalletNote] = useState<string | null>(null);
  const [tab, setTab] = useState<TabId>("market");
  const [storyPoints, setStoryPoints] = useState<Point[]>([]);
  const [openQuestion, setOpenQuestion] = useState<number | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const [theme, setTheme] = useState(() => document.documentElement.dataset.theme ?? "dark");

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

  // A tab nobody is looking at does not read the chain; it catches up when it is shown again.
  useEffect(() => {
    refresh();
    const whenVisible = () => !document.hidden && refresh();
    const poll = setInterval(whenVisible, 10_000);
    const clock = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    document.addEventListener("visibilitychange", whenVisible);
    return () => {
      clearInterval(poll);
      clearInterval(clock);
      document.removeEventListener("visibilitychange", whenVisible);
    };
  }, [refresh]);

  useEffect(() => {
    const ethereum = injected();
    if (!ethereum?.on) return;
    const onAccounts = () => setClients(null);
    ethereum.on("accountsChanged", onAccounts);
    return () => ethereum.removeListener?.("accountsChanged", onAccounts);
  }, []);

  // The desk pins while the page scrolls past it: it grows a little, and two notes fade in.
  const track = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: track, offset: ["start start", "end end"] });
  const scale = useTransform(scrollYProgress, [0.38, 0.96], [1, 1.064]);
  const noticeA = useTransform(scrollYProgress, [0.46, 0.8], [0, 1]);
  const noticeB = useTransform(scrollYProgress, [0.64, 0.98], [0, 1]);

  const shadows = snapshot?.shadows ?? [];
  const vaults = snapshot?.vaults ?? [];
  const pool = snapshot?.pool;
  const mandate = snapshot?.mandate;
  const open = shadows.filter((s) => s.status === "open");
  const drift = pool && pool.twapTick !== null ? pool.tick - pool.twapTick : null;
  const best = open.reduce<ShadowRow | null>((top, s) => (s.score && (!top?.score || s.score.alphaBps > top.score.alphaBps) ? s : top), null);

  // The shadow whose life the annotated chart tells: the selected one, else the newest.
  const featured: ShadowRow | undefined = useMemo(() => {
    if (tab.startsWith("s") || tab.startsWith("v")) {
      const found = shadows.find((s) => s.id === Number(tab.slice(1)));
      if (found) return found;
    }
    return [...shadows].reverse().find((s) => s.status === "open") ?? shadows[shadows.length - 1];
  }, [shadows, tab]);
  const featuredKey = featured ? `${featured.id}-${featured.closedAt}-${featured.rebalances}` : "";
  const beat = pool ? Math.floor(pool.timestamp / 45) : 0;
  useEffect(() => {
    if (!featured || !pool) return;
    let cancelled = false;
    loadShadowHistory(publicClient as never, featured, pool).then((p) => !cancelled && setStoryPoints(p));
    return () => {
      cancelled = true;
    };
  }, [featuredKey, beat]);

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

  function goTo(next: TabId) {
    setTab(next);
    document.getElementById("desk")?.scrollIntoView({ behavior: "smooth" });
  }

  const steps: Step[] = useMemo(() => {
    if (!featured || !mandate || !pool) {
      return [
        { tag: "01 Open", title: "A range and a size", text: "No capital, only a bond." },
        { tag: "02 Score", title: "Scored on real swaps", text: "Against a passive position." },
        { tag: "03 Move", title: "By signed instruction", text: "Anyone may submit it." },
        { tag: "04 Check", title: "Inside the mandate", text: "Or the move is refused." },
        { tag: "05 Graduate", title: "Real capital, capped", text: "The score sets the cap." },
      ];
    }
    const s = featured;
    const age = (s.closedAt || now) - s.openedAt;
    const ticksOff = drift === null ? null : Math.abs(drift);
    const last =
      s.status === "live"
        ? { title: `Went live as Vault No. ${pad(s.id)}`, text: "Capacity follows the score." }
        : s.status === "closed"
          ? { title: "Abandoned by its curator", text: "It stays on the record." }
          : age < mandate.minAge
            ? { title: `${duration(mandate.minAge - age)} of record to go`, text: "Then it can go live." }
            : s.score && s.score.alphaBps >= mandate.graduationBps
              ? { title: "Ready to go live", text: "With the curator's own stake." }
              : { title: "Behind the passive position", text: "It cannot go live yet." };
    return [
      { tag: "01 Open", title: `Shadow No. ${pad(s.id)}, ${s.tickUpper - s.tickLower} ticks wide`, text: `No capital. A ${toNumber(mandate.bondMin)} ETH bond.` },
      { tag: "02 Score", title: s.score ? `${bps(s.score.alphaBps)} against passive` : "Score pending", text: `Scored on ${duration(age)} of real swaps.` },
      { tag: "03 Move", title: s.rebalances === 0 ? "Not moved yet" : `Moved ${s.rebalances} ${s.rebalances === 1 ? "time" : "times"}`, text: "By signed instruction only." },
      {
        tag: "04 Check",
        title: ticksOff === null ? "Average still filling" : `Price ${ticksOff} ticks off: ${ticksOff <= mandate.maxDeviation ? "passes" : "refused"}`,
        text: `The bound is ${mandate.maxDeviation} ticks.`,
      },
      { tag: "05 Graduate", ...last },
    ];
  }, [featuredKey, featured?.score?.alphaBps, drift, mandate, now - (now % 15)]);

  const tickerItems = useMemo(() => {
    if (!snapshot || !pool || !mandate) return [];
    const items: [string, string, string][] = [[`${tokens.token0.symbol}/${tokens.token1.symbol}`, usd(pool.price, 2), drift === null ? "" : `${drift >= 0 ? "+" : "−"}${Math.abs(drift)} ticks`]];
    snapshot.shadows.forEach((s) => items.push([`SHADOW ${pad(s.id)}`, s.score ? bps(s.score.alphaBps) : "pending", s.status === "open" ? "open" : s.status === "live" ? "live" : "abandoned"]));
    snapshot.vaults.forEach((v) => items.push([`VAULT ${pad(v.id)}`, usd(v.nav), `${v.multiple}× stake`]));
    items.push(["BLOCK", pool.block.toLocaleString("en-US"), "Unichain Sepolia"]);
    items.push(["PRICE BOUND", `${mandate.maxDeviation} ticks`, `${duration(mandate.twapWindow)} average`]);
    return items;
  }, [snapshot]);

  const maxScore = Math.max(1, ...shadows.map((s) => Math.abs(s.score?.alphaBps ?? 0)));
  const maxNav = Math.max(1, ...vaults.map((v) => v.nav));

  return (
    <>
      <div className="nav-shell">
        <header className="nav">
          <a className="brand" href="#top" aria-label="Proving Ground">
            <Mark />
            Proving Ground
          </a>
          <nav className="nav-links" aria-label="Sections">
            {NAV.map((n) => (
              <a key={n.id} href={`#${n.id}`}>
                {n.label}
              </a>
            ))}
          </nav>
          <div className="nav-right">
            <button className="iconbtn" onClick={toggleTheme} aria-label="Switch between dark and light" title="Dark or light">
              <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden>
                <circle cx="7" cy="7" r="6" fill="none" stroke="var(--ink)" strokeWidth="1.3" />
                <path d="M7 1a6 6 0 0 1 0 12z" fill="var(--ink)" />
              </svg>
            </button>
            {clients ? (
              <a className="pill" href={`${explorer}/address/${clients.account}`} target="_blank" rel="noreferrer">
                {shortAddress(clients.account)}
              </a>
            ) : (
              <button className="pill" onClick={onConnect}>
                Connect wallet
              </button>
            )}
          </div>
        </header>
      </div>

      <main id="top">
        {/* ------------------------------------------------------------ hero */}
        <div className="wrap hero">
          {(error || walletNote || (watched && !clients)) && (
            <div className="banner" role="status" style={{ marginBottom: 40 }}>
              <span className="mono sq">{error ? "Network" : walletNote ? "Wallet" : "Viewing"}</span>
              <span>
                {error ?? walletNote ?? `The desk is shown as ${shortAddress(watched!)} sees it. Nothing can be sent until a wallet is connected.`}
              </span>
            </div>
          )}
          <div className="hero-grid">
            <h1>
              Prove it on paper.
              <br />
              Then earn the capital.
            </h1>
            <p className="lead">
              A Uniswap v4 hook where a liquidity manager first runs their strategy as a shadow position. The hook scores
              it on real swaps, and the score decides how much real money they may manage.
            </p>
          </div>
        </div>

        {/* ------------------------------------------------------------ the desk */}
        <div className="pin-track" id="desk" ref={track}>
          <div className="pin">
            <div className="wrap">
              <motion.div style={{ scale }}>
                {snapshot ? (
                  <DeskWindow
                    snapshot={snapshot}
                    clients={clients}
                    onConnect={onConnect}
                    refresh={refresh}
                    now={now}
                    tab={tab}
                    setTab={setTab}
                    noticeA={noticeA}
                    noticeB={noticeB}
                  />
                ) : (
                  <div className="window">
                    <div className="window-dots" aria-hidden>
                      <i />
                      <i />
                      <i />
                    </div>
                    <div className="screen">
                      <div className="chart-empty mono" style={{ height: 520, border: 0 }}>
                        {error ? "Could not reach the test network." : "Reading the pool from Unichain Sepolia…"}
                      </div>
                    </div>
                  </div>
                )}
              </motion.div>
            </div>
          </div>
        </div>

        {/* ------------------------------------------------------------ the record */}
        <section id="record">
          <div className="wrap center">
            <h2>Every shadow, on the record.</h2>
            <p className="lead">
              Shadows proving themselves on the left, the vaults that graduated on the right. An abandoned shadow stays
              listed with its score.
            </p>

            <div className="ticker" aria-hidden>
              <div className="ticker-track">
                {[...tickerItems, ...tickerItems, ...tickerItems].map(([label, value, extra], i) => (
                  <span key={i} className="mono">
                    {label}
                    <b>{value}</b>
                    <span className="accent">{extra}</span>
                  </span>
                ))}
              </div>
            </div>

            <div className="ladder">
              <div className="ladder-side left-side">
                <span className="mono">Shadows</span>
                {shadows.length === 0 && <div className="ladder-empty mono">none yet</div>}
                {[...shadows]
                  .sort((a, b) => (b.score?.alphaBps ?? -1e9) - (a.score?.alphaBps ?? -1e9))
                  .slice(0, 8)
                  .map((s) => (
                    <div key={s.id} className={`rung ${s.status === "open" ? "" : "dim"}`} onClick={() => goTo(s.status === "live" ? `v${s.id}` : `s${s.id}`)}>
                      <div className="rung-bar" style={{ width: `${34 + 66 * (Math.abs(s.score?.alphaBps ?? 0) / maxScore)}%` }}>
                        <span className="muted">
                          {pad(s.id)} · {s.status === "open" ? "open" : s.status === "live" ? "live" : "abandoned"}
                        </span>
                        <span>{s.score ? bps(s.score.alphaBps) : "pending"}</span>
                      </div>
                    </div>
                  ))}
              </div>

              <div className="ladder-mid">
                <span className="mono">Best open score, bps</span>
                <strong>{best?.score ? `${best.score.alphaBps > 0 ? "+" : best.score.alphaBps < 0 ? "−" : ""}${Math.abs(best.score.alphaBps)}` : "—"}</strong>
                <div className="limit">
                  <i />
                  <span className="mono">To go live</span>
                  {mandate ? `${mandate.graduationBps} bps · ${duration(mandate.minAge)}` : "…"}
                </div>
                <div>
                  <button className="pill big" onClick={() => goTo(snapshot?.account?.activeShadow ? `s${snapshot.account.activeShadow}` : "new")}>
                    Open a shadow
                  </button>
                </div>
              </div>

              <div className="ladder-side">
                <span className="mono">Vaults</span>
                {vaults.length === 0 && <div className="ladder-empty mono">no one has graduated yet</div>}
                {vaults.slice(0, 8).map((v) => (
                  <div key={v.id} className={`rung ${v.closedAt === 0 ? "" : "dim"}`} onClick={() => goTo(`v${v.id}`)}>
                    <div className="rung-bar" style={{ width: `${34 + 66 * (v.nav / maxNav)}%` }}>
                      <span>{usd(v.nav)}</span>
                      <span className="muted">
                        {pad(v.id)} · {v.multiple}× · {bps(v.liveAlphaBps)}
                      </span>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* ------------------------------------------------------------ the mandate */}
        <div className="band" id="mandate">
          <img className="photo" src="/photos/band-city.jpg" alt="A city skyline at night, seen across water" />
          <div className="wrap">
            <h2 className="display">The rules never blink.</h2>
            <p className="lead">
              Every move, shadow or live, passes the same fixed checks. They are set when the hook is deployed, and no
              one can change them.
            </p>
            <div className="sessions">
              <div>
                Range
                <span className="mono">{mandate ? `${mandate.minWidth}–${mandate.maxWidth.toLocaleString("en-US")} ticks` : "…"}</span>
              </div>
              <div>
                Cooldown
                <span className="mono">{mandate ? `${duration(mandate.cooldown)} between moves` : "…"}</span>
              </div>
              <div>
                Price bound
                <span className="mono">{mandate ? `${mandate.maxDeviation} ticks of average` : "…"}</span>
              </div>
              <div>
                Loss limit
                <span className="mono">{mandate ? `${(mandate.maxLossBps / 100).toFixed(2)}% per move` : "…"}</span>
              </div>
              <div>
                Record needed
                <span className="mono">{mandate ? `${duration(mandate.minAge)} to go live` : "…"}</span>
              </div>
              <div>
                Signature
                <span className="mono accent">Always required</span>
              </div>
            </div>
          </div>
        </div>

        {/* ------------------------------------------------------------ a shadow's life */}
        <section>
          <div className="wrap">
            <div className="split">
              <h2>From paper to real capital.</h2>
              <p className="lead">
                Five steps, read off {featured ? `Shadow No. ${pad(featured.id)}'s` : "a shadow's"} own chart. Nothing here
                is a mock-up: the line and the notes come from the chain.
              </p>
            </div>
            <Story
              points={storyPoints}
              steps={steps}
              upper={featured?.score ? `Shadow ${usd(featured.score.nav)}` : "Shadow"}
              lower={featured?.score ? `Passive ${usd(featured.score.navBenchmark)}` : "Passive"}
            />
          </div>
        </section>

        {/* ------------------------------------------------------------ vaults */}
        <section id="vaults">
          <div className="wrap">
            <h2>Real money, capped by the record.</h2>
            <p className="lead" style={{ marginTop: 14 }}>
              A graduated curator funds a vault with their own stake. Outside deposits are capped at a multiple of it.
            </p>

            {vaults.map((v) => {
              const total = Number(v.totalShares) || 1;
              const room = v.maxTotalShares > v.totalShares ? ((Number(v.maxTotalShares) - total) / total) * v.nav : 0;
              return (
                <div className="card" key={v.id}>
                  <div>
                    <span className="mono">Vault No. {pad(v.id)} · under management</span>
                    <div className="price">
                      <strong>{usd(v.nav)}</strong>
                      <span className="mono">test USD</span>
                    </div>
                    <p>
                      Curated by {shortAddress(v.curator)}, live for {duration((v.closedAt || now) - v.openedAt)} on{" "}
                      {usd(tickToPrice(v.tickLower))} to {usd(tickToPrice(v.tickUpper))}.
                    </p>
                    <button className="pill big" onClick={() => goTo(`v${v.id}`)}>
                      Deposit
                    </button>
                  </div>
                  <ul className="features">
                    <li>
                      <span>Score since opening, after fees</span>
                      <span>{bps(v.liveAlphaBps)}</span>
                    </li>
                    <li>
                      <span>Graduated from its shadow at</span>
                      <span>{bps(v.shadowAlphaBps)}</span>
                    </li>
                    <li>
                      <span>Multiple earned</span>
                      <span>{v.multiple}× the curator's stake</span>
                    </li>
                    <li>
                      <span>Curator's own stake</span>
                      <span>{Math.round((Number(v.curatorShares) / total) * 100)}% of the vault</span>
                    </li>
                    <li>
                      <span>{v.demoted ? "Demoted" : "Room for new deposits"}</span>
                      <span>{v.demoted ? "closed to deposits" : usd(room)}</span>
                    </li>
                  </ul>
                </div>
              );
            })}
            {snapshot && vaults.length === 0 && (
              <div className="card">
                <div>
                  <span className="mono">No vault yet</span>
                  <div className="price">
                    <strong>$0</strong>
                    <span className="mono">under management</span>
                  </div>
                  <p>No one has graduated on this pool yet. The first vault opens when a shadow has enough record and a score at or above the passive position.</p>
                  <button className="pill big" onClick={() => goTo("new")}>
                    Open a shadow
                  </button>
                </div>
                <ul className="features">
                  <li>
                    <span>Record needed</span>
                    <span>{mandate ? duration(mandate.minAge) : "…"}</span>
                  </li>
                  <li>
                    <span>Score needed</span>
                    <span>{mandate ? `${mandate.graduationBps} bps or better` : "…"}</span>
                  </li>
                  <li>
                    <span>Starting multiple</span>
                    <span>{mandate ? `${mandate.baseMultiple}× the stake` : "…"}</span>
                  </li>
                  <li>
                    <span>Highest multiple</span>
                    <span>{mandate ? `${mandate.maxMultiple}×` : "…"}</span>
                  </li>
                  <li>
                    <span>Performance fee</span>
                    <span>{mandate ? `${mandate.perfFeeBps / 100}% of gains over passive` : "…"}</span>
                  </li>
                </ul>
              </div>
            )}
            <div className="under">
              <p>
                Curating? Start with a shadow.
                <span>No capital needed. The score it earns sets how much a vault may take.</span>
              </p>
              <button className="pill dark big" onClick={() => goTo(snapshot?.account?.activeShadow ? `s${snapshot.account.activeShadow}` : "new")}>
                Open a shadow
              </button>
            </div>
          </div>
        </section>

        {/* ------------------------------------------------------------ proof */}
        <div className="proof">
          <h2 className="display">Scored on real flow, not on a promise.</h2>
          <div className="plate">
            <img className="photo" src="/photos/proof-earth.jpg" alt="City lights on Earth at night, seen from orbit" />
            <div className="pinned" style={{ left: "6%", top: "44%" }}>
              <span className="mono sq">Tests passing</span>
              <b>222</b>
            </div>
            <div className="pinned" style={{ left: "20%", top: "32%" }}>
              <span className="mono sq">Real swaps replayed</span>
              <b>76,428</b>
            </div>
            <div className="pinned" style={{ left: "44%", top: "22%" }}>
              <span className="mono sq">Added to a swap, after a block's first</span>
              <b>7,300 gas</b>
            </div>
            <div className="pinned" style={{ left: "68%", top: "17%" }}>
              <span className="mono sq">Owner keys</span>
              <b>none</b>
            </div>
          </div>
          <div className="quote">
            <p>
              “Replayed on a week of real Unichain swaps, the shadow's value after thirteen moves was within two basis
              points of a real position's.”
            </p>
            Real-flow replay, twin pools held at the same prices
            <span>76,428 ETH/USDC swaps, 10 to 17 November 2026, ETH down 13%</span>
          </div>
        </div>

        {/* ------------------------------------------------------------ questions */}
        <section id="questions">
          <div className="wrap center">
            <h2>Questions, answered.</h2>
            <p className="lead">How the score works, what a curator can and cannot do, and what protects a depositor.</p>
            <div className="faq">
              {QUESTIONS.map((item, i) => (
                <div key={i} className={`faq-item ${openQuestion === i ? "open" : ""}`}>
                  <button onClick={() => setOpenQuestion(openQuestion === i ? null : i)} aria-expanded={openQuestion === i}>
                    {item.q}
                    <span className="plus" aria-hidden />
                  </button>
                  <AnimatePresence initial={false}>
                    {openQuestion === i && (
                      <motion.div
                        initial={{ height: 0, opacity: 0 }}
                        animate={{ height: "auto", opacity: 1 }}
                        exit={{ height: 0, opacity: 0 }}
                        transition={{ duration: 0.3, ease: [0.4, 0, 0.2, 1] }}
                        style={{ overflow: "hidden" }}
                      >
                        <p>{item.a}</p>
                      </motion.div>
                    )}
                  </AnimatePresence>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ------------------------------------------------------------ closing */}
        <div className="closing">
          <img className="photo" src="/photos/closing-desk.jpg" alt="A lit desk by a window over a city at night" />
          <div className="wrap">
            <h2 className="display">Check the record first.</h2>
            <p className="lead">
              The contracts are live on Unichain Sepolia with test tokens. Open a shadow, move it, take it live, or read
              how it is tested.
            </p>
            <div className="cta-row">
              <a className="pill big" href="#desk">
                Open the desk
              </a>
              <a className="pill dark big" href="https://github.com/big14way/proving-ground" target="_blank" rel="noreferrer">
                Source and tests
              </a>
            </div>

            <div className="footer">
              <a className="brand" href="#top">
                <Mark />
                Proving Ground
              </a>
              <nav className="nav-links" aria-label="Footer">
                {NAV.map((n) => (
                  <a key={n.id} href={`#${n.id}`}>
                    {n.label}
                  </a>
                ))}
              </nav>
              <div className="footer-right">
                <a className="mono" href="#top" style={{ textDecoration: "none" }}>
                  Back to top ↑
                </a>
              </div>
            </div>
            <div className="copyright mono">
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
              <span>Built for the Uniswap Hook Incubator, UHI11. Photographs credited in the repository.</span>
            </div>
          </div>
        </div>
      </main>
    </>
  );
}
