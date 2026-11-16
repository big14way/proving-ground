# Proving Ground

**Prove it on paper, on-chain. Then earn the capital.**

Proving Ground is a Uniswap v4 hook for curated liquidity. A liquidity curator runs their strategy as a capital-free *shadow* position, and the hook scores what that position would have earned from real swap flow. The score is a public on-chain record, and it decides how much real liquidity the curator may manage. Once live, the curator moves that liquidity only through signed instructions that the hook checks against fixed limits.

Built for the Uniswap Hook Incubator UHI11 Hookathon, themed track: Active Management and Curated Liquidity.

## Status

| Part | State |
|---|---|
| In-pool price oracle (time-weighted tick, written once per block) | Built, tested |
| Shadow positions: open, rebalance, close | Built, tested |
| Shadow score: fees, value, passive-LP benchmark, alpha | Built, tested against real positions |
| Signed rebalance instructions, checked against a fixed mandate | Built, tested |
| Bond and one open shadow per address per pool | Built, tested |
| Live vaults: going live, in-kind deposits and withdrawals, shares | Built, tested |
| Capacity earned by score, pool-share cap, demotion | Built, tested |
| Live rebalancing through the pool, with a loss limit | Built, tested |
| Performance fee, paid only above a high-water mark against the passive benchmark | Built, tested |
| Invariant tests over random sequences of actions | Built, passing |

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

A curator never calls a contract to move a position, shadow or live. They sign an instruction (EIP-712 typed data) and anyone may submit it:

```
RebalanceIntent(bytes32 poolId,uint256 subjectId,bool live,int24 tickLower,int24 tickUpper,uint256 nonce,uint256 deadline)
```

It is executed only if every check passes. `live` says whether it moves a shadow (submitted to the hook) or a live vault (submitted to the vault, which hands it to the hook to be checked). Both kinds go through the same checking code in the hook and share one nonce sequence per curator. The limits are fixed at deployment; there is no owner and nothing can change them afterwards.

| Check | Rule | Value used in the tests |
|---|---|---|
| Signature | Signed by the position's curator. Contract wallets are supported through ERC-1271 | |
| Nonce and deadline | The curator's next nonce, and not past the deadline. `skipNonce` cancels outstanding instructions | |
| Range | On the pool's tick grid, contains the current tick, and neither narrower nor wider than the limits | 120 to 12,000 ticks |
| Cooldown | A minimum time since the position was opened or last moved | 300 seconds |
| Price sanity | The pool price is within a set distance of the hook's time-weighted average price | 100 ticks, 30-minute average |
| Loss limit (live vaults only) | After the vault's swap, its tokens are worth at least a set fraction of what they were before, at the time-weighted price | 0.5% at most lost |

An instruction that fails a check is not used up, so it can be submitted again before its deadline.

### What the price check is worth

A shadow is rebalanced at the pool's current price, and that price can be pushed for the length of one transaction. `test_withoutThePriceCheck_aFlashedPriceInflatesTheScore` runs the attack against a hook deployed with the price check switched off: push the price 288 ticks up, rebalance the shadow so that it books a sale of its token0 at the pushed price, push the price back. The shadow's score rises by 110 bps that no real position could have earned. Against the normal configuration the same rebalance reverts with `PriceDeviationTooHigh`, and it goes through once the price is back or once the average has caught up with a move that lasted.

### Bond and the one-shadow rule

Opening a shadow costs a bond in the chain's native currency (0.01 in the tests). It is returned once the shadow has been closed and a lock period has passed since it was opened (7 days in the tests), whichever comes later. An address can have one open shadow per pool. Every shadow an address opened, and every one it closed, stays on its public record (`curatorRecord`).

These rules make it costly, not impossible, to open many shadows and show off only the lucky one: each attempt needs its own address and its own locked bond.

## Live vaults

A curator can go live once their shadow has reached the minimum age (7 days in the tests) and scores at or above the graduation line (0 bps in the tests: at least as good as the passive position, after the haircut). `goLive` closes the shadow as graduated, returns its bond, and opens a vault on the shadow's current range. The curator funds it, and that first deposit is the curator's **stake**.

Real liquidity is held by a second contract, `ProvingGroundVault`, because the hook and the vault together do not fit in one contract under the 24,576-byte limit. The two are bound at deployment: the hook is given the vault's address, the vault refuses to deploy anywhere else, and neither has an owner.

### Deposits and withdrawals

Both are in kind and proportional. Nothing is swapped and nothing is priced.

- A depositor asks for a number of shares and adds that fraction to the vault's position and to its idle balances. Fees the position has earned are collected first, so a newcomer pays for their share of them.
- A withdrawer takes the same fraction out of the position and the idle balances.
- A withdrawal uses neither the hook, the oracle nor the curator. One test replaces the hook's code with code that always reverts, and the withdrawal still goes through.
- Rounding goes against whoever is entering or leaving. A deposit followed at once by a withdrawal returns the tokens to within 3 wei, and never more than was paid in (fuzz-tested).
- Shares are ERC-6909 tokens, one id per vault. The curator's stake is a number on the vault's books and cannot be transferred.

What the vault reports as its holdings matches a real position of the same size in the twin pool to within 2 wei.

### Capacity

Outside money is limited by the curator's own money in the vault:

```
total shares <= curator's stake x multiple
multiple = min(maximum, base + score / step)
```

In the tests the base is 2, each 50 bps of score adds 1, and the maximum is 10. The score is the shadow's final score for the vault's first 7 days. After that it is the vault's own: its value per share against a passive full-range position fixed when the vault opened. In the test run the shadow scores 110 bps, so the vault opens with a multiple of 4.

- **Pool-share cap.** A vault's position may be at most 10% of the pool's active liquidity. Checked when going live, on every deposit, and when a rebalance places liquidity.
- **Demotion.** A vault whose own score is below −200 bps takes no new deposits. Withdrawals are unaffected.
- **Stake.** The curator can add stake at any time, and can take out only what is not needed to back the outside deposits at the current multiple. Taking out the last share closes the vault.

### Performance fee

The curator is paid a share (10% in the tests) of what the vault gains **on its benchmark**, and only above a high-water mark:

```
R = vault value per share / benchmark value per share      (both at the time-weighted price)
if R > H:  mint the curator shares worth  fee x (1 - H/R)  of the vault, then set H to R after that dilution
```

- `H` starts level with the benchmark. Matching a passive position earns nothing, and falling behind and recovering over ground already paid for earns nothing.
- The fee is paid in new shares of the vault, so no tokens leave it. They are ordinary shares the curator can redeem; they are not stake.
- Anyone can call `settleFee`. A deposit settles it first, so a newcomer is not charged for gains made before they arrived. A withdrawal does not, so that it never depends on the oracle.
- The score a vault reports is net of fees. In the test run it is 114 bps before the fee and 103 bps after.

### Moving live liquidity

The vault calls the hook's `authorizeLive`, which verifies the signature, nonce and deadline and applies the range, cooldown and price checks. Then, in one pool-manager unlock, the vault:

1. removes all its liquidity, which also collects its fees;
2. swaps through the same pool toward the token mix the new range needs, with a price limit that keeps the price inside the new range and inside the mandate's price bound;
3. checks the loss limit: the tokens after the swap must be worth at least 99.5% of the tokens before it, at the time-weighted price;
4. adds as much liquidity as its balances and the pool-share cap allow. Anything left stays idle and is shared in proportion like everything else.

The swap is sized for the price it is expected to end at, not the price it starts from. Near the edge of a range a move of two ticks changes the mix the range needs by several percent, and sizing at the starting price left about 2% of a small vault idle in testing.

| Test case | Result |
|---|---|
| Small vault moved from ±300 ticks to a range 120 below and 480 above | Cost 8 bps of the vault's value; a few hundred million wei left idle out of 0.9e18 |
| Vault that would need a swap larger than the price bound allows | Its swap stops 99 ticks from the average (bound: 100); the unswapped 23% of the vault stays idle |
| Narrow range that would exceed the pool-share cap | Position placed at the cap, no swap, the rest idle in both tokens |
| Signed instruction held back while the price is pushed 88 ticks against the vault (inside the bound) | The swap would lose about 35 bps instead of 9; with a 25 bps loss limit the call reverts |

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
| Hook, no shadows open | 111,216 |
| Hook, five shadows open | 111,216 |
| Hook, first swap of a block (new oracle slot) | 141,632 |
| Hook, first swap of a block (oracle ring full) | 124,283 |

Open shadows add nothing to a swap; the test asserts the two figures are equal. The hook's cost is the oracle: about 7,300 gas on every swap, and about 13,000 to 30,000 more on the first swap of each block. An earlier prototype scored every open shadow inside every swap, which cost roughly 50,000 gas per shadow per swap. That design was dropped.

| Vault operation | Gas |
|---|---|
| Deposit | 242,857 (259,957 for an address's first shares) |
| Withdraw | 167,200 |
| Rebalance with a swap | 476,650 |
| Settle the fee | 154,055 |

The figures in both tables are written to `snapshots/` by the tests, so a change shows up in a diff.

### Invariants

`test/Invariants.t.sol` lets the fuzzer call deposits, withdrawals, stake changes, swaps, waits, vault and shadow rebalances, fee settlements and shadow closures in random order (24 runs of 80 calls for each property), and checks after every call that:

- the vault contract holds exactly the idle tokens on its books, its position in the pool is the liquidity on its books, and the shares add up to the total;
- no withdrawal was ever rejected;
- a fee was only ever taken above the high-water mark, and the mark never came down;
- the hook holds exactly its dust reserve in tokens and exactly the unreturned bonds in native currency.

At the end of every run everyone redeems everything. The vault must pay it all out and be left with a zero balance of both tokens.

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
- The fee is taken on each new high and is not given back if the vault later falls behind.
- A depositor who withdraws before the fee is settled leaves without paying it on gains since the last settlement. That is the curator's loss, and anyone can settle at any time.
- Fee shares count as outside shares, so they need stake behind them like any deposit, and the curator must redeem them before taking out the last of the stake.
- Deposits have no lock-up. Someone can deposit just before fees accrue and withdraw just after, taking a share of them. Capacity and the pool-share cap limit how much.
- The loss limit bounds what a sandwich can take from one rebalance. It does not make that zero.
- A vault sitting at the pool-share cap takes no deposits, because a deposit must add to the position. It reopens when the pool grows or the curator moves to a wider range.
- At the size cap a shadow's unplaced remainder is booked as token1, while a vault's stays in whatever mix is left over. The two differ there.
- The vault sizes its swap assuming the pool's liquidity stays the same along the swap's path. When it does not, more is left idle; nothing is lost.
- A curator cannot withdraw the stake that backs outside deposits, so cannot fully exit while depositors remain.
- Fee-on-transfer and rebasing tokens are not supported.

## Run it

```bash
git clone --recurse-submodules <this repo>
cd proving-ground
forge test -vv
```

Requires [Foundry](https://book.getfoundry.sh/). Compiles with solc 0.8.30, `via_ir`, EVM version cancun. 215 tests, including three invariant properties.

### The whole story in one run

```bash
forge test --match-test test_walkthrough -vv
```

prints a curator's life from start to finish with the figures at each step: the shadow is opened and scored, moved by a signed instruction, refused when an instruction breaks the mandate, graduated into a live vault, joined by a depositor, rebalanced for real, charged a fee, and exited.

### Deploy

```bash
forge script script/Deploy.s.sol --rpc-url <url> --private-key <key> --broadcast
```

The hook and the vault name each other at construction. The script works out the address the vault will get, mines a CREATE2 salt that gives the hook its permission bits with that address in its constructor arguments, then deploys the hook and the vault. The pool manager is taken from `POOL_MANAGER`, or from the known address for the chain; on a local node a fresh one is deployed. Settings such as `MIN_SHADOW_AGE` and `TWAP_WINDOW` can be overridden with environment variables (see the script). `test/Deploy.t.sol` covers the same path, and the script has been run against a local node.

## Layout

| Path | What |
|---|---|
| `src/ProvingGroundHook.sol` | The hook: pool registration, oracle writes, shadow lifecycle, signed instructions for shadows and vaults, bonds, scoring views, dust positions |
| `src/ProvingGroundVault.sol` | Live vaults: going live, in-kind deposits and withdrawals, ERC-6909 shares, capacity, live rebalancing, performance fee |
| `src/libraries/Oracle.sol` | Observation ring buffer and time-weighted tick |
| `src/libraries/ScoreMath.sol` | Position amounts and values, fee and haircut maths, rebalance plan and cost, alpha |
| `src/libraries/Mandate.sol` | The instruction's EIP-712 hash and the range, cooldown and price checks |
| `src/interfaces/IProvingGround.sol`, `IProvingGroundVault.sol` | Structs, events, errors |
| `test/ShadowAccuracy.t.sol` | Twin-pool accuracy suite, run on three token pairs |
| `test/ProvingGroundHook.t.sol` | Hook behaviour, guards, bonds, the one-shadow rule, dust accounting, gas |
| `test/Mandate.t.sol` | Signed instructions and every mandate check at its limit, the price-check attack, fuzz tests |
| `test/Vault.t.sol` | Going live, the deposit and withdrawal round trip, capacity, demotion, stake, live rebalancing, the loss limit, the performance fee, gas |
| `test/Walkthrough.t.sol` | The end-to-end story, printed step by step |
| `script/Deploy.s.sol`, `test/Deploy.t.sol` | Deployment of the hook and vault as a bound pair, and its test |
| `test/Invariants.t.sol` | Invariant properties of the vault and the hook under random sequences of actions |
| `snapshots/` | Gas figures written by the tests |
| `test/Oracle.t.sol`, `test/ScoreMath.t.sol` | Unit and fuzz tests for the libraries |
| `test/utils/TwinPools.sol` | The twin-pool test base |
| `test/utils/` (other files) | Test scaffolding (see Credits) |

## Partner integrations

No partner integrations.

## Credits

- `test/utils/BaseTest.sol`, `test/utils/Deployers.sol` and `test/utils/libraries/EasyPosm.sol` are test scaffolding from the [Uniswap v4 template](https://github.com/uniswapfoundation/v4-template).
- Hook base contract from [OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks).
- EIP-712 domain handling, signature checking (ECDSA and ERC-1271), safe token transfers and the reentrancy guard from [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts).
- Vault shares use the `ERC6909` contract from [Uniswap v4-core](https://github.com/Uniswap/v4-core) (itself adapted from Solmate), and `LiquidityAmounts` from [v4-periphery](https://github.com/Uniswap/v4-periphery).
- Precompiled v4 deployers for tests, and the per-chain v4 addresses used by the deploy script, from [hookmate](https://github.com/akshatmittal/hookmate). The deploy script mines the hook address with `HookMiner` from v4-periphery.
- The oracle's design (one observation per block holding a running tick sum, kept in a ring buffer) follows Uniswap v3's oracle. The code here is written for this project.
- Tests check the hook's amount maths against `LiquidityAmounts` from the v4-core test utilities.

## License

Source in `src/` is MIT, as marked in the file headers. Files under `test/utils/` keep their original license headers.
