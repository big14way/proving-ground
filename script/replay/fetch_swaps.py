#!/usr/bin/env python3
"""Fetches real swaps of one Uniswap v4 pool and writes the price path the replay test reads.

    python3 script/replay/fetch_swaps.py            # the window recorded in test/data/*.json
    python3 script/replay/fetch_swaps.py --from-block N --to-block M --out test/data/name

Reads `Swap` events of the pool from the chain's public endpoint, 1,000 blocks at a time (fewer where
that is too much for one answer), and writes
two files next to each other:

    <out>.bin   one 24-byte record per swap: seconds since the previous swap (uint32, big-endian),
                then the pool's sqrtPriceX96 after the swap (uint160, big-endian)
    <out>.json  where the data came from, how many swaps, the real volume, and the SHA-256 of the .bin

Standard library only. Running it again over the same blocks gives the same .bin, byte for byte.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import sys
import time
import urllib.request

RPC = "https://mainnet.unichain.org"  # --rpc picks another endpoint; the chain's data is the same from any of them
CHAIN_ID = 130
POOL_MANAGER = "0x1F98400000000000000000000000000000000004"
# ETH / USDC, 0.05% fee, tick spacing 10, no hook: the deepest ETH/USDC pool on Unichain's v4.
POOL_ID = "0x3258f413c7a88cda2fa8709a589d221a80f6574f63df5a5b6774485d8acc39d9"
POOL = {"currency0": "ETH (native)", "currency1": "USDC", "fee": 500, "tickSpacing": 10, "hooks": "none"}
# keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)")
SWAP_TOPIC = "0x40e9cecb9f5f1f1c5b9c97dec2917b7ee92e57ba5563708daca94dd84ad7112f"
SPAN = 1000  # this endpoint's limit on blocks per eth_getLogs; --span sets it for another


def rpc(method, params, tries=4):
    return call(RPC, method, params, tries)


def call(url, method, params, tries=4):
    """One JSON-RPC call. Returns None if it keeps failing, so the caller can ask for less at a time."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    for attempt in range(tries):
        try:
            request = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
            answer = json.load(urllib.request.urlopen(request, timeout=90))
            if "error" not in answer:
                return answer["result"]
        except Exception:  # HTTP errors, timeouts, responses cut short
            pass
        time.sleep(min(20, 2 ** attempt))
    return None


def swap_logs(start, end, cache):
    """The pool's Swap events in blocks start..end, in order. A range the endpoint will not serve in one
    answer (a busy hour makes the response too large) is split in two and asked for again."""
    path = os.path.join(cache, f"{start}-{end}.json") if cache else None
    if path and os.path.exists(path):
        with open(path) as file:
            return json.load(file)
    logs = rpc(
        "eth_getLogs",
        [{"address": POOL_MANAGER, "topics": [SWAP_TOPIC, POOL_ID], "fromBlock": hex(start), "toBlock": hex(end)}],
    )
    if logs is None:
        if start == end:
            sys.exit(f"could not read the logs of block {start}")
        middle = (start + end) // 2
        logs = swap_logs(start, middle, None) + swap_logs(middle + 1, end, None)
    logs = [{"blockNumber": log["blockNumber"], "data": log["data"]} for log in logs]
    if path:
        with open(path, "w") as file:
            json.dump(logs, file)
    return logs


def signed(word, bits=256):
    value = int(word, 16)
    return value - (1 << bits) if value >> (bits - 1) else value


def main():
    global RPC
    parser = argparse.ArgumentParser()
    parser.add_argument("--from-block", type=int, default=63_575_200)
    parser.add_argument("--to-block", type=int, default=64_180_000)
    parser.add_argument("--out", default="test/data/unichain-eth-usdc")
    parser.add_argument("--rpc", default=RPC, help="JSON-RPC endpoint to read from")
    parser.add_argument("--span", type=int, default=SPAN, help="blocks per eth_getLogs request")
    parser.add_argument("--workers", type=int, default=4, help="requests in flight at once")
    parser.add_argument("--cache", default="", help="a folder to keep fetched ranges in, so a rerun resumes")
    args = parser.parse_args()
    if args.cache:
        os.makedirs(args.cache, exist_ok=True)
    RPC = args.rpc

    records = bytearray()
    count = 0
    volume_usdc = 0
    volume_eth = 0
    previous_block = None
    first_block = last_block = None
    low = high = None

    ranges = [
        (start, min(start + args.span - 1, args.to_block))
        for start in range(args.from_block, args.to_block + 1, args.span)
    ]
    with concurrent.futures.ThreadPoolExecutor(args.workers) as pool:
        answers = pool.map(lambda r: swap_logs(r[0], r[1], args.cache), ranges)
        for (start, end), logs in zip(ranges, answers):
            for log in logs:
                data = log["data"][2:]
                words = [data[i : i + 64] for i in range(0, len(data), 64)]
                amount0, amount1 = signed(words[0]), signed(words[1])
                sqrt_price = int(words[2], 16)
                block = int(log["blockNumber"], 16)
                delta = 0 if previous_block is None else block - previous_block  # blocks are one second apart
                records += delta.to_bytes(4, "big") + sqrt_price.to_bytes(20, "big")
                previous_block = block
                first_block = block if first_block is None else first_block
                last_block = block
                low = sqrt_price if low is None else min(low, sqrt_price)
                high = sqrt_price if high is None else max(high, sqrt_price)
                volume_eth += abs(amount0)
                volume_usdc += abs(amount1)
                count += 1
            print(f"blocks {start}-{end}: {len(logs)} swaps, {count} so far", file=sys.stderr, flush=True)

    def timestamp(block):
        header = rpc("eth_getBlockByNumber", [hex(block), False], tries=8)
        if header is None:
            sys.exit(f"could not read block {block}")
        return int(header["timestamp"], 16)

    with open(args.out + ".bin", "wb") as file:
        file.write(records)
    manifest = {
        "chainId": CHAIN_ID,
        "chain": "Unichain mainnet",
        "poolManager": POOL_MANAGER,
        "poolId": POOL_ID,
        "pool": POOL,
        "fromBlock": args.from_block,
        "toBlock": args.to_block,
        "firstSwapBlock": first_block,
        "lastSwapBlock": last_block,
        "firstSwapTime": timestamp(first_block),
        "lastSwapTime": timestamp(last_block),
        "swaps": count,
        "volumeEth": round(volume_eth / 1e18, 2),
        "volumeUsdc": round(volume_usdc / 1e6, 2),
        "lowestSqrtPriceX96": str(low),
        "highestSqrtPriceX96": str(high),
        "recordBytes": 24,
        "sha256": hashlib.sha256(records).hexdigest(),
    }
    with open(args.out + ".json", "w") as file:
        json.dump(manifest, file, indent=2)
        file.write("\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
