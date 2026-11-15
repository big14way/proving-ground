# Proving Ground

**Prove it on paper, on-chain. Then earn the capital.**

Proving Ground is a Uniswap v4 hook for curated liquidity. A liquidity curator runs their strategy as a capital-free *shadow* position, and the hook scores what that position would have earned from real swap flow. The score is a public on-chain record, and it decides how much real liquidity the curator may manage.

Built for the Uniswap Hook Incubator UHI11 Hookathon, themed track: Active Management and Curated Liquidity.

## Status

| Part | State |
|---|---|
| In-pool price oracle (time-weighted tick, written once per block) | Built, tested |
| Shadow positions: open, rebalance, close | Built, tested |
| Shadow score: fees, value, passive-LP benchmark, alpha | Built, tested against real positions |
| Signed rebalance instructions, checked against a fixed mandate | Built, tested |
| Bond and one open shadow per address per pool | Built, tested |
| Capacity gating, live vaults, performance fees | Not built yet |

## How the shadow score works

1. A curator opens a shadow: a tick range and an amount of *virtual* liquidity. The position needs no capital; the curator only posts a small bond (see [The mandate](#the-mandate)). A shadow may be at most 1% of the pool's active liquidity, the size at which the score is validated below.
2. The hook places a dust-sized real position (1000 liquidity units, paid from a small reserve the hook holds) on the same ticks. In Uniswap v4 a tick only tracks fee growth while some liquidity references it, so this makes the pool itself account for fees inside the shadow's range.
3. Fees the shadow would have earned are `virtual liquidity × fee growth inside the range`, read from the pool with `StateLibrary.getFeeGrowthInside`. This is the **raw** figure.
4. Real capital would have joined the pool's active liquidity and diluted that fee growth. The **conservative** figure scales the raw one by `L / (L + virtual liquidity)`, where `L` is the pool's active liquidity when the position was placed.
5. A rebalance, asked for by a signed instruction, moves the virtual position to a new range and charges a modelled cost: the pool fee on the amount that would have to be swapped, plus the price impact of that swap against the pool's active liquidity. Fees earned so far are folded into the position, as a real vault would do. If the new range would exceed the size cap, the excess is held as idle value that earns nothing.
6. The score compares the shadow against two references fixed when it opened: a **passive full-range position** of the same starting value earning the pool's fees, and **simply holding** the starting tokens. Alpha is the shadow's conservative value over the passive position's value, in basis points. The passive position's fees are not scaled down, which leans the comparison against the curator.

Nothing in steps 3 to 6 runs during a swap. Fee growth only changes when the pool trades, so the score is computed when someone asks for it.

### Price oracle

Uniswap v4 pools have no built-in price oracle. The hook records one observation per block in `beforeSwap`, taken before the first swap so it captures the tick that held since the previous observation. `score` values everything at the average tick over the oracle window, so a price pushed within a single transaction does not move it. `scoreAtSpot` values at the current pool price and exists for display and for the accuracy tests.

## The mandate

A curator never calls the hook to move a position. They sign an instruction (EIP-712 typed data) and anyone may submit it:

```
RebalanceIntent(bytes32 poolId,uint256 subjectId,bool live,int24 tickLower,int24 tickUpper,uint256 nonce,uint256 deadline)
```

The hook executes it only if every check passes. The limits are fixed when the hook is deployed; there is no owner and nothing can change them afterwards.

| Check | Rule | Value used in the tests |
|---|---|---|
| Signature | Signed by the position's curator. Contract wallets are supported through ERC-1271 | |
| Nonce and deadline | The curator's next nonce, and not past the deadline. `skipNonce` cancels outstanding instructions | |
| Range | On the pool's tick grid, contains the current tick, and neither narrower nor wider than the limits | 120 to 12,000 ticks |
| Cooldown | A minimum time since the position was opened or last moved | 300 seconds |
| Price sanity | The pool price is within a set distance of the hook's time-weighted average price | 100 ticks, 30-minute average |

An instruction that fails a check is not used up, so it can be submitted again before its deadline.

### What the price check is worth

A shadow is rebalanced at the pool's current price, and that price can be pushed for the length of one transaction. `test_withoutThePriceCheck_aFlashedPriceInflatesTheScore` runs the attack against a hook deployed with the price check switched off: push the price 288 ticks up, rebalance the shadow so that it books a sale of its token0 at the pushed price, push the price back. The shadow's score rises by 110 bps that no real position could have earned. Against the normal configuration the same rebalance reverts with `PriceDeviationTooHigh`, and it goes through once the price is back or once the average has caught up with a move that lasted.

### Bond and the one-shadow rule

Opening a shadow costs a bond in the chain's native currency (0.01 in the tests). It is returned once the shadow has been closed and a lock period has passed since it was opened (7 days in the tests), whichever comes later. An address can have one open shadow per pool. Every shadow an address opened, and every one it closed, stays on its public record (`curatorRecord`).

These rules make it costly, not impossible, to open many shadows and show off only the lucky one: each attempt needs its own address and its own locked bond.

## How it is tested

Two pools receive exactly the same swaps:

- **Pool A** has the hook, and a shadow position.
- **Pool B** is identical, has no hook, and holds the same position with real tokens.

Pool B is the ground truth. Each test compares what the hook reports for the shadow against what the real position actually did. The whole suite runs on three token pairs: two 18-decimal tokens at a price of 1, a 6-decimal against an 18-decimal token priced like a 3,000 USD asset, and the same pair the other way round.

### Fee accuracy

Error of the shadow's fees against the real position's collected fees, by shadow size as a share of the pool's active liquidity, over 300 swaps. The three token pairs agree to within 0.0001%.

| Shadow size | Price stays in range: raw | In range: conservative | Price trends through: raw | Trending: conservative |
|---|---|---|---|---|
| 0.1% | +0.11% | +0.01% | +0.04% | −0.06% |
| 1% | +1.08% | +0.07% | +0.38% | −0.62% |
| 10% (above the cap) | +10.67% | +0.61% | +2.42% | −6.89% |
| 50% (above the cap) | +52.18% | +1.45% | −5.37% | −36.91% |

Reading: when the price bounces inside the range, the raw figure overstates fees by about the shadow's share of the pool, and the conservative figure corrects it. When the price trends through the range, the raw figure is already close and the conservative one undershoots. At the supported sizes the two figures sit within about one percent of the real result. At 50% they do not, which is why the hook caps shadow size.

The tests enforce, at 0.1% and 1%: conservative fees within ±1.0% of real, raw fees no more than 1.5% above real.

### Value after rebalances

Shadow value against the real position's value after two re-centerings (one trend up, one trend down, 300 swaps). The real position rebalances by swapping through its own pool.

| Shadow size | 18/18 decimals | 6/18 decimals | 18/6 decimals |
|---|---|---|---|
| 1% | −2.6 bps | −2.6 bps | −0.8 bps |
| 10% (above the cap) | +11.2 bps | +11.2 bps | +24.3 bps |

The tests enforce: within 10 bps at 1%.

### Passive benchmark

The benchmark is a virtual full-range position. Pool B holds that position for real.

| Flow | Value error | Fee error |
|---|---|---|
| Price stays in range | below 0.0001% | +0.016% |
| Price trends away | below 0.0001% | +0.033% |

### Gas

Measured with each swap as its own transaction (`isolate` mode), on a pool with three liquidity providers and no tick crossed.

| Swap | Gas |
|---|---|
| Pool without the hook | 103,910 |
| Hook, no shadows open | 111,172 |
| Hook, five shadows open | 111,172 |
| Hook, first swap of a block (new oracle slot) | 141,588 |
| Hook, first swap of a block (oracle ring full) | 124,239 |

Open shadows add nothing to a swap; the test asserts the two figures are equal. The hook's cost is the oracle: about 7,300 gas on every swap, and about 13,000 to 30,000 more on the first swap of each block. An earlier prototype scored every open shadow inside every swap, which cost roughly 50,000 gas per shadow per swap. That design was dropped.

### Limits of these tests and of the design so far

- Synthetic swap flow, one pool configuration (0.3% fee, tick spacing 60, three overlapping liquidity providers), 300 swaps per run.
- The score is an estimate, not a proof. That is why both the raw and the conservative figures are published, and why shadow size is capped.
- The rebalance cost model ignores any protocol fee.
- The raw value does not compound the extra fees of finished legs.
- A shadow's range boundaries are initialized ticks, like any liquidity position's. A swap that crosses one pays for that tick crossing.
- Pools with a native-currency side are rejected at initialization.
- One person can still open shadows from many addresses. Each costs a locked bond, which raises the price of doing so without ruling it out.
- Whoever submits a signed instruction picks the moment, anywhere before its deadline. A curator limits that with a short deadline.
- A shadow can step out of the market by rebalancing into a range too narrow to hold its value under the size cap; the remainder waits as idle token1. It pays the modelled cost of that sale, and it can only do so at a price that passes the price check.
- A curator contract that cannot receive native currency cannot take its bond back.

## Run it

```bash
git clone --recurse-submodules <this repo>
cd proving-ground
forge test -vv
```

Requires [Foundry](https://book.getfoundry.sh/). Compiles with solc 0.8.30, `via_ir`, EVM version cancun. 145 tests.

## Layout

| Path | What |
|---|---|
| `src/ProvingGroundHook.sol` | The hook: pool registration, oracle writes, shadow lifecycle, signed instructions, bonds, scoring views, dust positions |
| `src/libraries/Oracle.sol` | Observation ring buffer and time-weighted tick |
| `src/libraries/ScoreMath.sol` | Position amounts and values, fee and haircut maths, rebalance plan and cost, alpha |
| `src/libraries/Mandate.sol` | The instruction's EIP-712 hash and the range, cooldown and price checks |
| `src/interfaces/IProvingGround.sol` | Structs, events, errors |
| `test/ShadowAccuracy.t.sol` | Twin-pool accuracy suite, run on three token pairs |
| `test/ProvingGroundHook.t.sol` | Hook behaviour, guards, bonds, the one-shadow rule, dust accounting, gas |
| `test/Mandate.t.sol` | Signed instructions and every mandate check at its limit, the price-check attack, fuzz tests |
| `test/Oracle.t.sol`, `test/ScoreMath.t.sol` | Unit and fuzz tests for the libraries |
| `test/utils/TwinPools.sol` | The twin-pool test base |
| `test/utils/` (other files) | Test scaffolding (see Credits) |

## Partner integrations

No partner integrations.

## Credits

- `test/utils/BaseTest.sol`, `test/utils/Deployers.sol` and `test/utils/libraries/EasyPosm.sol` are test scaffolding from the [Uniswap v4 template](https://github.com/uniswapfoundation/v4-template).
- Hook base contract from [OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks).
- EIP-712 domain handling, signature checking (ECDSA and ERC-1271) and safe token transfers from [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts).
- Precompiled v4 deployers for tests from [hookmate](https://github.com/akshatmittal/hookmate).
- The oracle's design (one observation per block holding a running tick sum, kept in a ring buffer) follows Uniswap v3's oracle. The code here is written for this project.
- Tests check the hook's amount maths against `LiquidityAmounts` from the v4-core test utilities.

## License

Source in `src/` is MIT, as marked in the file headers. Files under `test/utils/` keep their original license headers.
