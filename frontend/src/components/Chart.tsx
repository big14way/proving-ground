import type { Point } from "../lib/data";
import { duration, usd } from "../lib/math";

type Props = {
  points: Point[];
  /** Draws the "simply holding" line as well. */
  showHold?: boolean;
  caption: string;
  valueLabel: string;
};

const W = 640;
const H = 250;
const PAD = { top: 12, right: 6, bottom: 26, left: 6 };

/** A plain ink line chart, drawn like a figure in a printed report. */
export function Chart({ points, showHold = true, caption, valueLabel }: Props) {
  if (points.length < 2) {
    return (
      <div className="chart">
        <div className="minihead caps">
          <span>{caption}</span>
        </div>
        <div className="empty" style={{ borderBottom: 0 }}>
          The line appears once there are a few minutes of record.
        </div>
      </div>
    );
  }

  const series = points.flatMap((p) => (showHold && p.hold > 0 ? [p.value, p.benchmark, p.hold] : [p.value, p.benchmark]));
  let min = Math.min(...series);
  let max = Math.max(...series);
  const margin = (max - min) * 0.12 || max * 0.001 || 1;
  min -= margin;
  max += margin;
  const t0 = points[0].time;
  const t1 = points[points.length - 1].time;
  const x = (time: number) => PAD.left + ((time - t0) / (t1 - t0 || 1)) * (W - PAD.left - PAD.right);
  const y = (value: number) => PAD.top + (1 - (value - min) / (max - min)) * (H - PAD.top - PAD.bottom);
  const path = (pick: (p: Point) => number) =>
    points.map((p, i) => `${i === 0 ? "M" : "L"}${x(p.time).toFixed(1)},${y(pick(p)).toFixed(1)}`).join(" ");

  const last = points[points.length - 1];
  const gridValues = [0, 0.5, 1].map((f) => min + (max - min) * f);
  const digits = max - min < 20 ? 2 : 0;

  return (
    <div className="chart">
      <div className="minihead caps">
        <span>{caption}</span>
        <span>{valueLabel}</span>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={caption}>
        {gridValues.map((v, i) => (
          <g key={i}>
            <line x1={PAD.left} x2={W - PAD.right} y1={y(v)} y2={y(v)} stroke="var(--rule)" strokeWidth="1" />
            <text x={W - PAD.right} y={y(v) - 5} textAnchor="end">
              {usd(v, digits)}
            </text>
          </g>
        ))}
        {showHold && last.hold > 0 && (
          <path d={path((p) => p.hold)} fill="none" stroke="var(--faint)" strokeWidth="1.4" strokeDasharray="1.5 4" />
        )}
        <path d={path((p) => p.benchmark)} fill="none" stroke="var(--muted)" strokeWidth="1.4" strokeDasharray="6 5" />
        <path d={path((p) => p.value)} fill="none" stroke="var(--ink)" strokeWidth="2" strokeLinejoin="round" />
        <circle cx={x(last.time)} cy={y(last.value)} r="4.5" fill="var(--accent)" />
        <line x1={PAD.left} x2={W - PAD.right} y1={H - PAD.bottom} y2={H - PAD.bottom} stroke="var(--rule-strong)" />
        <text x={PAD.left} y={H - 8}>
          OPENED
        </text>
        <text x={W - PAD.right} y={H - 8} textAnchor="end">
          {duration(t1 - t0).toUpperCase()} LATER
        </text>
      </svg>
      <div className="legend caps">
        <span>
          <i /> The position
        </span>
        <span>
          <i className="dash" /> Passive full-range position
        </span>
        {showHold && last.hold > 0 && (
          <span>
            <i className="dots" /> Simply holding
          </span>
        )}
      </div>
    </div>
  );
}
