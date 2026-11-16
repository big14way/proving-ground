// Drives the deployed contracts from a terminal, through the same functions the page's buttons call.
// Useful for preparing a demonstration, and as an end-to-end check of the page's write paths.
//
//   DEMO_PRIVATE_KEY=0x... npx tsx scripts/demo.ts <command> [arguments]
//
//   status                      what the account and the record look like
//   faucet                      mint test tokens to the account
//   swap <buy|sell> <usd>       one swap
//   flow <count> <seconds>      a stream of swaps that keeps the price near where it started
//   open <half-width-ticks>     open a shadow around the current price, at the size cap
//   move <half-width-ticks>     sign and submit a move of the account's open shadow
//   live <stake-usd>            take the open shadow live with a stake of that value
//   deposit <vault> <usd>       deposit into a vault
//   withdraw <vault>            withdraw all of the account's shares
//   move-vault <vault> <half>   sign and submit a move of a vault
//   settle <vault>              settle the performance fee
//   close                       abandon the open shadow
import { createWalletClient, http } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chain, TICK_SPACING } from "../src/config";
import { publicClient, type Clients } from "../src/lib/chain";
import { loadSnapshot } from "../src/lib/data";
import * as actions from "../src/lib/actions";
import { amountsFor, floorTick, fromNumber, liquidityForValue, tickToPrice, toNumber } from "../src/lib/math";

const key = process.env.DEMO_PRIVATE_KEY as `0x${string}` | undefined;
if (!key) throw new Error("Set DEMO_PRIVATE_KEY to a funded test key.");
const account = privateKeyToAccount(key);
const walletClient = createWalletClient({ account, chain, transport: http() });
const c: Clients = { publicClient, walletClient, account: account.address };

const [command, a, b] = process.argv.slice(2);
const snapshot = () => loadSnapshot(publicClient as never, account.address);
const around = (tick: number, half: number) => {
  const mid = floorTick(tick, TICK_SPACING);
  return { lower: mid - half, upper: mid + half + TICK_SPACING };
};
const sleep = (seconds: number) => new Promise((r) => setTimeout(r, seconds * 1000));

async function main() {
  const s = await snapshot();
  const { pool, mandate } = s;
  const me = s.account!;

  switch (command) {
    case "status": {
      console.log(`block ${pool.block}  price ${pool.price.toFixed(2)}  tick ${pool.tick}  average tick ${pool.twapTick}`);
      console.log(`account ${me.address}  ${toNumber(me.balance0).toFixed(2)} ETH  ${toNumber(me.balance1).toFixed(0)} USD  open shadow ${me.activeShadow}`);
      for (const sh of s.shadows) {
        console.log(`shadow ${sh.id}  ${sh.status}  ticks ${sh.tickLower}..${sh.tickUpper}  score ${sh.score?.alphaBps ?? "n/a"} bps  moves ${sh.rebalances}`);
      }
      for (const v of s.vaults) {
        console.log(
          `vault ${v.id}  value ${v.nav.toFixed(0)}  score ${v.liveAlphaBps} bps  multiple ${v.multiple}  fee due ${v.feeSharesDue}  my shares ${me.shares[v.id]}`,
        );
      }
      return;
    }
    case "faucet":
      return console.log(await actions.faucet(c, fromNumber(1000), fromNumber(3_000_000)));
    case "swap":
      return console.log(await actions.swap(c, a !== "buy", a === "buy" ? fromNumber(Number(b)) : fromNumber(Number(b) / pool.price)));
    case "flow": {
      const home = pool.tick;
      for (let i = 0; i < Number(a); i++) {
        const now = (await snapshot()).pool;
        const buy = now.tick < home - 60 ? true : now.tick > home + 60 ? false : Math.random() < 0.5;
        const usd = 1500 + Math.random() * 9000;
        try {
          await actions.swap(c, !buy, buy ? fromNumber(usd) : fromNumber(usd / now.price));
          console.log(`${i}  tick ${now.tick}  ${buy ? "buy" : "sell"}  ${usd.toFixed(0)} USD`);
        } catch (e) {
          console.log(`${i}  failed: ${actions.explain(e)}`);
        }
        await sleep(Number(b ?? 8));
      }
      return;
    }
    case "open": {
      const { lower, upper } = around(pool.tick, Number(a ?? 300));
      const liquidity = (pool.liquidity * BigInt(mandate.shadowMaxShareBps)) / 10_000n;
      return console.log(await actions.openShadow(c, lower, upper, liquidity, mandate.bondMin));
    }
    case "move": {
      const { lower, upper } = around(pool.tick, Number(a ?? 300));
      const signed = await actions.signIntent(c, me.activeShadow, false, lower, upper);
      console.log("signed", signed.signature.slice(0, 20), "nonce", signed.intent.nonce);
      return console.log(await actions.submitIntent(c, signed.intent, signed.signature));
    }
    case "live": {
      const shadow = s.shadows.find((x) => x.id === me.activeShadow)!;
      const liquidity = liquidityForValue(pool.price, shadow.tickLower, shadow.tickUpper, Number(a));
      const held = amountsFor(pool.price, shadow.tickLower, shadow.tickUpper, liquidity);
      console.log(`stake ${held.amount0.toFixed(3)} ETH + ${held.amount1.toFixed(0)} USD on ${tickToPrice(shadow.tickLower).toFixed(0)}..${tickToPrice(shadow.tickUpper).toFixed(0)}`);
      return console.log(
        await actions.goLive(c, shadow.id, liquidity, fromNumber(held.amount0 * 1.02 + 0.000001), fromNumber(held.amount1 * 1.02 + 0.000001)),
      );
    }
    case "deposit": {
      const v = s.vaults.find((x) => x.id === Number(a))!;
      const shares = (v.totalShares * fromNumber(Number(b))) / fromNumber(v.nav);
      return console.log(await actions.deposit(c, v.id, shares));
    }
    case "withdraw":
      return console.log(await actions.withdraw(c, Number(a), me.shares[Number(a)]));
    case "move-vault": {
      const { lower, upper } = around(pool.tick, Number(b ?? 300));
      const signed = await actions.signIntent(c, Number(a), true, lower, upper);
      return console.log(await actions.submitIntent(c, signed.intent, signed.signature));
    }
    case "settle":
      return console.log(await actions.settleFee(c, Number(a)));
    case "close":
      return console.log(await actions.closeShadow(c, me.activeShadow));
    default:
      throw new Error("Unknown command. See the list at the top of this file.");
  }
}

main().catch((e) => {
  console.error(actions.explain(e));
  process.exit(1);
});
