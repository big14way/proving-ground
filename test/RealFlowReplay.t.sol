// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TwinPools} from "./utils/TwinPools.sol";
import {PriceDriver} from "./utils/PriceDriver.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IProvingGround} from "../src/interfaces/IProvingGround.sol";

/// @notice The accuracy suite again, on a price path that really happened: every swap of the
/// ETH/USDC 0.05% pool on Unichain mainnet (Uniswap v4) over seven days, recorded by
/// `script/replay/fetch_swaps.py` in `test/data/unichain-eth-usdc.bin`.
///
/// The twin pools are set up like that pool: the same fee and tick spacing, an 18-decimal token
/// against a 6-decimal one, starting at the price the real pool was at. Pool A (with the hook, holding
/// a shadow) is then taken through the recorded prices one swap at a time, so it makes one swap for
/// each real swap, in the same direction, ending at the same price. The pools' own liquidity is the
/// test's, not the real pool's, so each swap's size is whatever moves this pool to that price.
///
/// Pool B (no hook, holding the same position with real tokens) follows in one of two ways, because
/// "what would have happened had the position been real" has two honest answers:
///   - the same trades: every trader swaps the same amount, and the extra liquidity dampens the price;
///   - the same prices: arbitrage keeps the pool at the market price, so more volume flows.
/// Real flow is a mix of the two. The shadow's conservative figure is built for the first and its raw
/// figure for the second.
contract RealFlowReplayTest is TwinPools {
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    string internal constant FLOW = "test/data/unichain-eth-usdc.bin";
    string internal constant MANIFEST = "test/data/unichain-eth-usdc.json";
    uint256 internal constant RECORD = 24;

    // The real pool's settings.
    uint24 internal constant REAL_FEE = 500;
    int24 internal constant REAL_SPACING = 10;

    /// @dev The curator's range: 3% either side.
    int24 internal constant HALF_WIDTH = 300;

    // What the two figures are held to on this path.
    //
    // The raw figure is the one built for a pool that stays at market prices. There it is held far
    // tighter than the synthetic suite's 1.0%.
    //
    // The conservative figure is built for a pool whose traders swap the same amounts. On this path it
    // comes out below the real position's fees, by about twice the shadow's share of the pool: 1.6% at
    // the 1% size cap over the whole week, 2.2% over its first 5,000 swaps. That is further out than
    // the synthetic suite's 1.0%, on the side that costs the curator. It is held to three times the
    // share below, and 1.0% above.
    uint256 internal constant RAW_FEE_LIMIT_PPM = 1_000; // within 0.1%, pool B at the same prices
    int256 internal constant CONSERVATIVE_FLOOR_PER_SHARE = 3; // at most 3x the share below, same trades
    int256 internal constant CONSERVATIVE_FEE_CEILING_PPM = 10_000; // at most 1.0% above
    int256 internal constant RAW_FEE_CEILING_PPM = 15_000; // at most 1.5% above, as in the synthetic suite
    uint256 internal constant VALUE_LIMIT_PPM = 1_000; // within 10 bps

    enum Twin {
        SameTrades,
        SamePrices
    }

    PriceDriver internal driver;
    uint256 internal clock;

    function setUp() public {
        bytes memory flow = vm.readFileBinary(FLOW);
        (, uint160 start) = _record(flow, 0);
        int24 startTick = TickMath.getTickAtSqrtPrice(start);

        // No size cap and no mandate limits, as in the synthetic suite. The oracle keeps a full window
        // even when a swap lands every second.
        IProvingGround.Config memory config = _looseConfig(10_000);
        config.oracleCapacity = 1800;
        _setUpTwinWith(REAL_FEE, REAL_SPACING, 18, 6, (startTick / 60) * 60, 1e13, config);

        driver = new PriceDriver(poolManager);
        MockERC20(Currency.unwrap(c0)).transfer(address(driver), 1e29);
        MockERC20(Currency.unwrap(c1)).transfer(address(driver), 1e29);

        clock = vm.getBlockTimestamp() + TWAP_WINDOW;
        vm.warp(clock);
        driver.swapTo(keyA, start);
        driver.swapTo(keyB, start);
    }

    // ------------------------------------------------------------------ the recorded path

    /// @dev Record `i`: seconds since the previous swap, and the pool's price after this one.
    function _record(bytes memory flow, uint256 i) internal pure returns (uint32 gap, uint160 sqrtPriceX96) {
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(add(flow, 32), mul(i, 24)))
        }
        gap = uint32(word >> 224);
        sqrtPriceX96 = uint160(word >> 64);
    }

    /// @dev How many recorded swaps to replay. `REPLAY_SWAPS` shortens the run; the default is all.
    function _length(bytes memory flow) internal view returns (uint256 n) {
        n = flow.length / RECORD;
        uint256 asked = vm.envOr("REPLAY_SWAPS", uint256(0));
        if (asked != 0 && asked < n) n = asked;
    }

    /// @dev One real swap: time passes, pool A goes to the recorded price, pool B follows.
    function _step(bytes memory flow, uint256 i, Twin twin) internal returns (uint160 price) {
        uint32 gap;
        (gap, price) = _record(flow, i);
        if (gap != 0) {
            clock += gap;
            vm.warp(clock);
        }
        (bool zeroForOne, uint256 amountIn) = driver.swapTo(keyA, price);
        if (twin == Twin.SamePrices) driver.swapTo(keyB, price);
        else if (amountIn != 0) driver.swapIn(keyB, zeroForOne, amountIn);
    }

    function _around(int24 tick) internal pure returns (int24 lo, int24 hi) {
        int24 mid = (tick / REAL_SPACING) * REAL_SPACING;
        return (mid - HALF_WIDTH, mid + HALF_WIDTH);
    }

    // ------------------------------------------------------------------ fees, one range held throughout

    function _feeRun(uint256 shareBps, Twin twin) internal returns (int256 rawPpm, int256 conservativePpm) {
        bytes memory flow = vm.readFileBinary(FLOW);
        uint256 n = _length(flow);

        (, int24 tick,,) = poolManager.getSlot0(idA);
        (int24 lo, int24 hi) = _around(tick);
        uint128 liquidity = _activeShare(shareBps);
        uint256 shadowId = _openAs(curator, lo, hi, liquidity);
        (tokenId,) = _mint(keyB, lo, hi, liquidity);

        uint256 inRange;
        for (uint256 i = 1; i < n; ++i) {
            tick = TickMath.getTickAtSqrtPrice(_step(flow, i, twin));
            if (tick >= lo && tick < hi) ++inRange;
        }

        BalanceDelta collected = positionManager.collect(tokenId, 0, 0, address(this), clock + 1, "");
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        uint256 realFees = _in1(uint128(collected.amount0()), sqrtP) + uint128(collected.amount1());

        (uint256 raw0, uint256 raw1, uint256 cons0, uint256 cons1) = hook.shadowFees(shadowId);
        rawPpm = _ppm(_in1(raw0, sqrtP) + raw1, realFees);
        conservativePpm = _ppm(_in1(cons0, sqrtP) + cons1, realFees);

        console2.log(twin == Twin.SameTrades ? "pool B takes the same trades" : "pool B is kept at the same prices");
        console2.log("  real swaps replayed:", n - 1);
        console2.log("  shadow size, bps of active liquidity:", shareBps);
        console2.log("  swaps that left the price inside the range, %:", inRange * 100 / (n - 1));
        console2.log("  final tick, relative to start:", tick - (lo + HALF_WIDTH));
        console2.log("  real position's fees, USDC (6 decimals):", realFees);
        console2.log("  raw shadow fees, error ppm:", rawPpm);
        console2.log("  conservative shadow fees, error ppm:", conservativePpm);
        IProvingGround.Score memory sc = hook.scoreAtSpot(shadowId);
        console2.log("  score against the passive position, bps:", sc.alphaBps);
        console2.log("  score against simply holding, bps:", sc.alphaVsHoldBps);
    }

    function _assertSameTrades(uint256 shareBps, int256 raw, int256 conservative) internal pure {
        // A share of 100 bps is 10,000 ppm.
        int256 floor = -CONSERVATIVE_FLOOR_PER_SHARE * int256(shareBps) * 100;
        assertGe(conservative, floor, "conservative fees at most three times the share below the real position's");
        assertLe(conservative, CONSERVATIVE_FEE_CEILING_PPM, "conservative fees at most 1.0% above");
        assertLe(raw, RAW_FEE_CEILING_PPM, "raw fees at most 1.5% above");
        assertLe(conservative, raw, "the conservative figure is the lower of the two");
    }

    function _assertSamePrices(int256 raw, int256 conservative) internal pure {
        assertLe(_abs(raw), RAW_FEE_LIMIT_PPM, "raw fees within 0.1% of the real position's");
        assertLe(conservative, raw, "the conservative figure is the lower of the two");
    }

    function test_realFlow_fees_sameTrades_1pct() public {
        (int256 raw, int256 conservative) = _feeRun(100, Twin.SameTrades);
        _assertSameTrades(100, raw, conservative);
    }

    function test_realFlow_fees_sameTrades_0_1pct() public {
        (int256 raw, int256 conservative) = _feeRun(10, Twin.SameTrades);
        _assertSameTrades(10, raw, conservative);
    }

    function test_realFlow_fees_samePrices_1pct() public {
        (int256 raw, int256 conservative) = _feeRun(100, Twin.SamePrices);
        _assertSamePrices(raw, conservative);
    }

    function test_realFlow_fees_samePrices_0_1pct() public {
        (int256 raw, int256 conservative) = _feeRun(10, Twin.SamePrices);
        _assertSamePrices(raw, conservative);
    }

    // ------------------------------------------------------------------ value, re-centring whenever the price leaves

    /// @dev The curator re-centres the range every time the price leaves it. The shadow moves by a
    /// signed instruction; the real position withdraws, swaps through pool B and deposits. When pool B
    /// is kept at the same prices, an arbitrageur then puts it back at the market price, which is what
    /// leaves the cost of that swap with the position.
    function _valueRun(Twin twin) internal returns (int256 rawPpm, int256 conservativePpm) {
        bytes memory flow = vm.readFileBinary(FLOW);
        uint256 n = _length(flow);

        (, int24 tick,,) = poolManager.getSlot0(idA);
        (int24 lo, int24 hi) = _around(tick);
        uint128 liquidity = _activeShare(100);
        uint256 shadowId = _openAs(curator, lo, hi, liquidity);
        (tokenId,) = _mint(keyB, lo, hi, liquidity);
        realLiquidity = liquidity;

        for (uint256 i = 1; i < n; ++i) {
            uint160 price = _step(flow, i, twin);
            tick = TickMath.getTickAtSqrtPrice(price);
            if (tick < lo || tick >= hi) {
                (lo, hi) = _around(tick);
                _rebalance(shadowId, lo, hi);
                _realRebalance(lo, hi);
                if (twin == Twin.SamePrices) driver.swapTo(keyB, price);
            }
        }

        BalanceDelta d = positionManager.decreaseLiquidity(tokenId, realLiquidity, 0, 0, address(this), clock + 1, "");
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        uint256 realValue = _in1(idle0 + uint128(d.amount0()), sqrtP) + idle1 + uint128(d.amount1());

        IProvingGround.Score memory sc = hook.scoreAtSpot(shadowId);
        rawPpm = _ppm(sc.navRaw, realValue);
        conservativePpm = _ppm(sc.navConservative, realValue);

        console2.log("re-centring a 3% range on the real price path");
        console2.log(twin == Twin.SameTrades ? "pool B takes the same trades" : "pool B is kept at the same prices");
        console2.log("  real swaps replayed:", n - 1);
        console2.log("  moves:", hook.getShadow(shadowId).rebalances);
        console2.log("  real position's value, USDC (6 decimals):", realValue);
        console2.log("  shadow value, raw, error ppm:", rawPpm);
        console2.log("  shadow value, conservative, error ppm:", conservativePpm);
        console2.log("  modelled cost of the moves, USDC (6 decimals):", sc.rebalanceCost);
        console2.log("  score against the passive position, bps:", sc.alphaBps);
        console2.log("  score against simply holding, bps:", sc.alphaVsHoldBps);
    }

    function test_realFlow_value_recentring_samePrices_1pct() public {
        (int256 raw, int256 conservative) = _valueRun(Twin.SamePrices);
        assertLe(_abs(raw), VALUE_LIMIT_PPM, "raw value within 10 bps of the real position");
        assertLe(conservative, raw, "the conservative value is the lower of the two");
    }

    function test_realFlow_value_recentring_sameTrades_1pct_reportOnly() public {
        _valueRun(Twin.SameTrades);
    }

    // ------------------------------------------------------------------ the data

    /// @dev The recorded path is the file its manifest describes.
    function test_recordedPath_matchesItsManifest() public view {
        bytes memory flow = vm.readFileBinary(FLOW);
        string memory manifest = vm.readFile(MANIFEST);
        assertEq(flow.length, vm.parseJsonUint(manifest, ".swaps") * RECORD, "one record per swap");
        assertEq(
            vm.toString(sha256(flow)),
            string.concat("0x", vm.parseJsonString(manifest, ".sha256")),
            "SHA-256 of the path"
        );
    }
}
