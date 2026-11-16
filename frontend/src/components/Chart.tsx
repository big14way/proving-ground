import type { Point } from "../lib/data";
import { duration } from "../lib/math";

type Props = {
  points: Point[];
  /** Formats a value for the tag on the last point and the axis. */
  format: (value: number) => string;
  /** Draws the benchmark line when the points carry one. */
  showBenchmark?: boolean;
  showHold?: boolean;
  height?: number;
};

const W = 760;
const PAD = { top: 20, right: 86, bottom: 26, left: 0 };

/** A line chart in the manner of a trading screen: one accent line, a dashed level at the last value, a tag. */
export function Chart({ points, format, showBenchmark = true, showHold = false, height = 300 }: Props) {
  if (points.length < 2) {
    return (
      <div className="chart">
        <div className="chart-empty mono" style={{ height }}>
          The line appears once there are a few minutes of record.
        </div>
      </div>
    );
  }
  const H = height;
  const withBench = showBenchmark && points.some((p) => p.benchmark > 0);
  const withHold = showHold && points.some((p) => p.hold > 0);
  const all = points.flatMap((p) => [p.value, ...(withBench ? [p.benchmark] : []), ...(withHold ? [p.hold] : [])]);
  let min = Math.min(...all);
  let max = Math.max(...all);
  const margin = (max - min) * 0.14 || max * 0.0005 || 1;
  min -= margin;
  max += margin;
  const t0 = points[0].time;
  const t1 = points[points.length - 1].time;
  const x = (time: number) => PAD.left + ((time - t0) / (t1 - t0 || 1)) * (W - PAD.left - PAD.right);
  const y = (value: number) => PAD.top + (1 - (value - min) / (max - min)) * (H - PAD.top - PAD.bottom);
  const path = (pick: (p: Point) => number) =>
    points.map((p, i) => `${i === 0 ? "M" : "L"}${x(p.time).toFixed(1)},${y(pick(p)).toFixed(1)}`).join(" ");
  const last = points[points.length - 1];
  const span = t1 - t0;
  const ticks = [0, 0.25, 0.5, 0.75].map((f) => ({ f, label: f === 0 ? "start" : `+${duration(span * f)}` }));

  return (
    <div className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Value over time">
        <line x1={PAD.left} x2={W - PAD.right} y1={y(last.value)} y2={y(last.value)} stroke="var(--accent)" strokeWidth="1" strokeDasharray="3 4" opacity="0.7" />
        {withHold && <path d={path((p) => p.hold)} fill="none" stroke="var(--faint)" strokeWidth="1.3" strokeDasharray="1.5 4" />}
        {withBench && <path d={path((p) => p.benchmark)} fill="none" stroke="var(--muted)" strokeWidth="1.3" strokeDasharray="6 5" />}
        <path d={path((p) => p.value)} fill="none" stroke="var(--accent)" strokeWidth="2" strokeLinejoin="round" />
        {points.map((p, i) =>
          i % 3 === 0 ? <rect key={i} x={x(p.time) - 2.5} y={y(p.value) - 2.5} width="5" height="5" fill="var(--accent)" /> : null,
        )}
        <g transform={`translate(${W - PAD.right + 4}, ${y(last.value) - 11})`}>
          <rect width={PAD.right - 4} height="22" fill="var(--accent)" />
          <text x={(PAD.right - 4) / 2} y="15" textAnchor="middle" style={{ fill: "var(--accent-ink)" }}>
            {format(last.value)}
          </text>
        </g>
        {ticks.map((t) => (
          <text key={t.f} x={PAD.left + t.f * (W - PAD.left - PAD.right)} y={H - 6}>
            {t.label}
          </text>
        ))}
        <text x={W - PAD.right} y={H - 6} textAnchor="end">
          now
        </text>
      </svg>
    </div>
  );
}
