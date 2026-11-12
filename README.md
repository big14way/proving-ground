# Proving Ground

**Prove it on paper, on-chain. Then earn the capital.**

Proving Ground is a Uniswap v4 hook for curated liquidity. A liquidity curator runs their strategy as a capital-free *shadow* position, and the hook scores what that position would have earned from real swap flow. The score is a public on-chain record, and it decides how much real liquidity the curator may manage.

Built for the Uniswap Hook Incubator UHI11 Hookathon, themed track: Active Management and Curated Liquidity.

## Status

This repository currently holds a feasibility prototype of the scoring mechanic only.

| Part | State |
|---|---|
| Shadow scoring against live swaps (`src/ShadowHook.sol`) | Prototype, tested |
| Virtual rebalances with a modelled swap cost | Prototype, tested |
| Accuracy tests against a real position (`test/Shadow.t.sol`) | 13 tests passing |
| Capacity gating, signed rebalance instructions, live vaults, performance fees | Not built yet |

## How the shadow score works

1. A curator opens a shadow: a tick range and an amount of *virtual* liquidity. No depositor capital is involved.
2. The hook places a dust-sized real position (1000 liquidity units) on the same ticks. In Uniswap v4 a tick only tracks fee growth while some liquidity references it, so this makes the pool account for fees inside the shadow's range.
3. Fees the shadow would have earned are `virtual liquidity × fee growth inside the range`, read from the pool with `StateLibrary.getFeeGrowthInside`.
4. Real capital would have joined the pool's active liquidity and diluted that fee growth. A conservative figure scales the raw one by `L / (L + virtual liquidity)`, where `L` is the pool's active liquidity.
5. A rebalance moves the virtual position to a new range and charges a modelled cost: the pool fee on the amount that would have to be swapped, plus an optional price-impact term.

## How it is tested

Two pools receive exactly the same swaps:

- **Pool A** has the hook and a shadow position.
- **Pool B** is identical, has no hook, and holds the same position with real tokens.

Pool B is the ground truth. Each test compares what the shadow says against what the real position actually collected.

### Fee accuracy

Error of the shadow's fee figure against the real position, by shadow size as a share of the pool's active liquidity. "Raw" is step 3 above; "conservative" is step 4 using the active liquidity when the shadow opened.

| Shadow size | Price stays in range: raw | In range: conservative | Price trends through: raw | Trending: conservative |
|---|---|---|---|---|
| 0.1% | +0.10% | 0.00% | +0.03% | −0.06% |
| 1% | +1.07% | +0.07% | +0.37% | −0.61% |
| 10% | +10.67% | +0.61% | +2.42% | −6.88% |
| 50% | +52.18% | +1.45% | −5.36% | −36.91% |

Reading: when the price bounces inside the range, the raw figure overstates fees by about the shadow's share of the pool and the conservative figure corrects it. When the price trends through the range, the raw figure is already close and the conservative one undershoots. At small sizes the two figures bracket the real result to within about one percent. At 50% they do not, so large shadows are out of scope.

### Value after rebalances

Shadow value against the real position's value after two re-centerings (one trend up, one trend down, 300 random swaps):

| Shadow size | Cost model | Difference in value |
|---|---|---|
| 1% | pool fee only | −0.8 bps |
| 1% | pool fee + price impact | −3.1 bps |
| 10% | pool fee only | +29.9 bps |
| 10% | pool fee + price impact | +6.7 bps |

### Gas

Scoring a shadow on every swap is expensive: a swap cost 62,868 gas with no hook, 118,451 with one shadow scored per swap, and 343,345 with five. The conservative figure above needs no per-swap work (it is applied when the score is read), so the per-swap path in this prototype exists only to measure the difference.

### Limits of these tests

Synthetic swap flow, one pool configuration (0.3% fee, tick spacing 60, three overlapping liquidity providers), 300 swaps per run, 18-decimal tokens at a price near 1. Fee errors are logged in whole basis points.

## Run it

```bash
git clone --recurse-submodules <this repo>
cd proving-ground
forge test -vv
```

Requires [Foundry](https://book.getfoundry.sh/). Compiles with solc 0.8.30, `via_ir`, EVM version cancun.

## Layout

| Path | What |
|---|---|
| `src/ShadowHook.sol` | Prototype hook: shadow registry, dust positions, scoring, virtual rebalance |
| `test/Shadow.t.sol` | Twin-pool accuracy tests, rebalance tests, gas measurement |
| `test/utils/` | Test scaffolding (see Credits) |

## Partner integrations

No partner integrations.

## Credits

- `test/utils/BaseTest.sol`, `test/utils/Deployers.sol` and `test/utils/libraries/EasyPosm.sol` are test scaffolding from the [Uniswap v4 template](https://github.com/uniswapfoundation/v4-template).
- Hook base contract from [OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks).
- Precompiled v4 deployers for tests from [hookmate](https://github.com/akshatmittal/hookmate).

## License

Source in `src/` is MIT, as marked in the file headers. Files under `test/utils/` keep their original license headers.
