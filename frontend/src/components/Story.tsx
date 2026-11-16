import { useRef } from "react";
import { motion, useScroll, useTransform, type MotionValue } from "motion/react";
import type { Point } from "../lib/data";

export type Step = { tag: string; title: string; text: string };

const W = 1232;
const H = 520;
const TOP = 150;
const BOTTOM = 370;
/** Where along the line each of the five notes is attached, and whether it sits above or below. */
const ANCHORS = [
  { at: 0.09, above: true },
  { at: 0.26, above: false },
  { at: 0.43, above: true },
  { at: 0.6, above: false },
  { at: 0.94, above: true },
];

function Note({ step, anchor, x, progress, index }: { step: Step; anchor: (typeof ANCHORS)[number]; x: number; progress: MotionValue<number>; index: number }) {
  // The notes appear one after another as the chart is scrolled into view.
  const opacity = useTransform(progress, [index * 0.16, index * 0.16 + 0.3], [0, 1]);
  const flip = anchor.at > 0.8;
  return (
    <motion.div
      className={`callout ${flip ? "flip" : ""}`}
      style={{ opacity, left: `${(x / W) * 100}%`, ...(anchor.above ? { top: 0 } : { bottom: 0 }) }}
    >
      <span className="mono">{step.tag}</span>
      <b>{step.title}</b>
      <span className="muted">{step.text}</span>
    </motion.div>
  );
}

/** A position's line with five notes pinned to it: the life of a shadow, read off its own chart. */
export function Story({ points, steps, upper, lower }: { points: Point[]; steps: Step[]; upper: string; lower: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start 80%", "start 25%"] });

  // With too little record, a plain rising line stands in so the notes still have something to hang on.
  const series: Point[] =
    points.length >= 2
      ? points
      : Array.from({ length: 24 }, (_, i) => ({ time: i, value: 100 + i * 0.4 + Math.sin(i * 0.9) * 0.8, benchmark: 100 + i * 0.25, hold: 0 }));
  const values = series.flatMap((p) => (p.benchmark > 0 ? [p.value, p.benchmark] : [p.value]));
  const min = Math.min(...values);
  const max = Math.max(...values);
  const t0 = series[0].time;
  const t1 = series[series.length - 1].time;
  const x = (time: number) => ((time - t0) / (t1 - t0 || 1)) * W;
  const y = (value: number) => TOP + (1 - (value - min) / (max - min || 1)) * (BOTTOM - TOP);
  const path = (pick: (p: Point) => number) => series.map((p, i) => `${i === 0 ? "M" : "L"}${x(p.time).toFixed(1)},${y(pick(p)).toFixed(1)}`).join(" ");
  const at = (fraction: number) => series[Math.min(series.length - 1, Math.round(fraction * (series.length - 1)))];
  const last = series[series.length - 1];

  return (
    <div className="story" ref={ref}>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="A shadow's value over its life, with notes">
        <line x1={W * 0.26} x2={W} y1={y(last.value)} y2={y(last.value)} stroke="var(--muted)" strokeDasharray="2 5" opacity="0.6" />
        <text x={W * 0.26 - 12} y={y(last.value) + 4} textAnchor="end">
          {upper}
        </text>
        {last.benchmark > 0 && (
          <>
            <line x1={W * 0.26} x2={W * 0.9} y1={y(last.benchmark)} y2={y(last.benchmark)} stroke="var(--muted)" strokeDasharray="2 5" opacity="0.6" />
            <text x={W * 0.26 - 12} y={y(last.benchmark) + 4} textAnchor="end">
              {lower}
            </text>
            <path d={path((p) => p.benchmark)} fill="none" stroke="var(--faint)" strokeWidth="1.3" strokeDasharray="6 5" />
          </>
        )}
        <path d={path((p) => p.value)} fill="none" stroke="var(--accent)" strokeWidth="1.6" />
        {series.map((p, i) => (
          <rect key={i} x={x(p.time) - 3.5} y={y(p.value) - 3.5} width="7" height="7" fill={i % 4 === 3 ? "var(--faint)" : "var(--accent)"} />
        ))}
        {ANCHORS.map((a, i) => {
          const p = at(a.at);
          return (
            <g key={i} className="leader">
              <line x1={x(p.time)} x2={x(p.time)} y1={y(p.value)} y2={a.above ? 84 : H - 84} stroke="var(--line-strong)" />
              <circle cx={x(p.time)} cy={y(p.value)} r="2.5" fill="var(--ink)" />
            </g>
          );
        })}
      </svg>
      {ANCHORS.map((a, i) => (
        <Note key={i} step={steps[i]} anchor={a} x={x(at(a.at).time)} progress={scrollYProgress} index={i} />
      ))}
    </div>
  );
}
