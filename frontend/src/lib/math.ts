/** Price of token0 in token1 at a tick. Both test tokens have 18 decimals. */
export function tickToPrice(tick: number): number {
  return Math.pow(1.0001, tick);
}

export function priceToTick(price: number): number {
  return Math.log(price) / Math.log(1.0001);
}

/** The largest multiple of `spacing` at or below `tick`. */
export function floorTick(tick: number, spacing: number): number {
  return Math.floor(tick / spacing) * spacing;
}

export function nearestTick(tick: number, spacing: number): number {
  return Math.round(tick / spacing) * spacing;
}

const Q96 = 2 ** 96;

export function sqrtPriceX96ToPrice(sqrtPriceX96: bigint): number {
  const s = Number(sqrtPriceX96) / Q96;
  return s * s;
}

/** Token amounts held by `liquidity` on [tickLower, tickUpper) at `price`, as plain numbers. */
export function amountsFor(price: number, tickLower: number, tickUpper: number, liquidity: bigint) {
  const L = Number(liquidity) / 1e18;
  const s = Math.sqrt(price);
  const a = Math.sqrt(tickToPrice(tickLower));
  const b = Math.sqrt(tickToPrice(tickUpper));
  if (s <= a) return { amount0: L * (1 / a - 1 / b), amount1: 0 };
  if (s < b) return { amount0: L * (1 / s - 1 / b), amount1: L * (s - a) };
  return { amount0: 0, amount1: L * (b - a) };
}

/** Liquidity whose position on the range is worth `value` (in token1) at `price`. */
export function liquidityForValue(price: number, tickLower: number, tickUpper: number, value: number): bigint {
  const unit = amountsFor(price, tickLower, tickUpper, 10n ** 18n);
  const unitValue = unit.amount0 * price + unit.amount1;
  if (unitValue <= 0) return 0n;
  return BigInt(Math.floor((value / unitValue) * 1e6)) * 10n ** 12n;
}

export function toNumber(amount: bigint, decimals = 18): number {
  return Number(amount) / 10 ** decimals;
}

export function fromNumber(amount: number, decimals = 18): bigint {
  if (!Number.isFinite(amount) || amount <= 0) return 0n;
  return BigInt(Math.floor(amount * 1e6)) * 10n ** BigInt(decimals - 6);
}

export function usd(value: number, digits = 0): string {
  return value.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function num(value: number, digits = 2): string {
  return value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function bps(value: bigint | number): string {
  const n = Number(value);
  return `${n > 0 ? "+" : n < 0 ? "−" : ""}${Math.abs(n).toLocaleString("en-US")} bps`;
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function duration(seconds: number): string {
  if (seconds < 0) seconds = 0;
  if (seconds < 90) return `${Math.floor(seconds)} sec`;
  if (seconds < 5400) return `${Math.floor(seconds / 60)} min`;
  if (seconds < 172800) return `${(seconds / 3600).toFixed(1)} hr`;
  return `${Math.floor(seconds / 86400)} days`;
}

export function ago(timestamp: number, now: number): string {
  return `${duration(now - timestamp)} ago`;
}
