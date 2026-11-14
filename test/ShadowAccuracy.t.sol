// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TwinPools} from "./utils/TwinPools.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {IProvingGround} from "../src/interfaces/IProvingGround.sol";

/// @notice Checks every figure the hook reports for a shadow against a real position that received
/// the same swaps. Errors are logged in parts per million (10,000 ppm = 1%).
///
/// The hook is deployed with no size cap here so that sizes far above the supported 1% can be
/// measured and reported. Only the 0.1% and 1% sizes carry pass/fail limits.
abstract contract AccuracySuite is TwinPools {
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    // Limits at the supported shadow size (up to 1% of the pool's active liquidity).
    uint256 internal constant CONSERVATIVE_FEE_LIMIT_PPM = 10_000; // within 1.0% either way
    int256 internal constant RAW_FEE_UPPER_PPM = 15_000; // overstates by at most 1.5%
    int256 internal constant RAW_FEE_LOWER_PPM = -1_000;
    uint256 internal constant VALUE_LIMIT_PPM = 1_000; // 10 bps after two rebalances
    uint256 internal constant BENCHMARK_LIMIT_PPM = 10_000; // within 1.0%

    // The real position on pool B.
    uint256 internal tokenId;
    uint128 internal realLiquidity;
    uint256 internal idle0;
    uint256 internal idle1;

    // ------------------------------------------------------------------ fees

    function _feeRun(uint256 shareBps, bool inRange) internal returns (int256 rawPpm, int256 conservativePpm) {
        uint128 liquidity = _activeShare(shareBps);
        uint256 shadowId = hook.openShadow(idA, center - 300, center + 300, liquidity);
        (tokenId,) = _mint(keyB, center - 300, center + 300, liquidity);

        if (inRange) _pingPong(0, 300);
        else _randomSwaps(0, 300);

        BalanceDelta collected = positionManager.collect(tokenId, 0, 0, address(this), vm.getBlockTimestamp() + 1, "");
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(idA);
        uint256 realFees = _in1(uint128(collected.amount0()), sqrtP) + uint128(collected.amount1());

        (uint256 raw0, uint256 raw1, uint256 cons0, uint256 cons1) = hook.shadowFees(shadowId);
        rawPpm = _ppm(_in1(raw0, sqrtP) + raw1, realFees);
        conservativePpm = _ppm(_in1(cons0, sqrtP) + cons1, realFees);

        console2.log(inRange ? "flow: price stays in range" : "flow: price trends through the range");
        console2.log("  shadow size, bps of active liquidity:", shareBps);
        console2.log("  final tick, relative to start:", tick - center);
        console2.log("  real fees, token1 units:", realFees);
        console2.log("  raw shadow fees, error ppm:", rawPpm);
        console2.log("  conservative shadow fees, error ppm:", conservativePpm);
    }

    function _assertFeeLimits(int256 rawPpm, int256 conservativePpm) internal pure {
        assertLe(_abs(conservativePpm), CONSERVATIVE_FEE_LIMIT_PPM, "conservative fees within 1.0% of real");
        assertLe(rawPpm, RAW_FEE_UPPER_PPM, "raw fees overstate by at most 1.5%");
        assertGe(rawPpm, RAW_FEE_LOWER_PPM, "raw fees do not understate");
    }

    function test_fees_trending_0_1pct() public {
        (int256 raw, int256 cons) = _feeRun(10, false);
        _assertFeeLimits(raw, cons);
    }

    function test_fees_trending_1pct() public {
        (int256 raw, int256 cons) = _feeRun(100, false);
        _assertFeeLimits(raw, cons);
    }

    function test_fees_inrange_0_1pct() public {
        (int256 raw, int256 cons) = _feeRun(10, true);
        _assertFeeLimits(raw, cons);
    }

    function test_fees_inrange_1pct() public {
        (int256 raw, int256 cons) = _feeRun(100, true);
        _assertFeeLimits(raw, cons);
    }

    // Above the supported size. Measured and reported, not held to a limit.
    function test_fees_trending_10pct_reportOnly() public {
        _feeRun(1000, false);
    }

    function test_fees_trending_50pct_reportOnly() public {
        _feeRun(5000, false);
    }

    function test_fees_inrange_10pct_reportOnly() public {
        _feeRun(1000, true);
    }

    function test_fees_inrange_50pct_reportOnly() public {
        _feeRun(5000, true);
    }

    // ------------------------------------------------------------------ value across rebalances

    /// @dev Moves the real position the way a vault would: withdraw, swap through the pool to the
    /// mix the new range needs, deposit. The swap pays the pool fee and moves the price.
    function _realRebalance(int24 lo, int24 hi) internal {
        BalanceDelta d = positionManager.decreaseLiquidity(
            tokenId, realLiquidity, 0, 0, address(this), vm.getBlockTimestamp() + 1, ""
        );
        uint256 x0 = idle0 + uint128(d.amount0());
        uint256 x1 = idle1 + uint128(d.amount1());

        (uint160 sqrtP,,,) = poolManager.getSlot0(idB);
        uint160 sLo = TickMath.getSqrtPriceAtTick(lo);
        uint160 sHi = TickMath.getSqrtPriceAtTick(hi);
        (uint256 r0, uint256 r1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sLo, sHi, 1e18);
        uint256 need0 = FullMath.mulDiv(r0, _in1(x0, sqrtP) + x1, _in1(r0, sqrtP) + r1);

        uint256 b0 = c0.balanceOf(address(this));
        uint256 b1 = c1.balanceOf(address(this));
        if (x0 > need0) _swap(keyB, true, x0 - need0);
        else if (need0 > x0) _swap(keyB, false, _in1(need0 - x0, sqrtP));
        x0 = x0 + c0.balanceOf(address(this)) - b0;
        x1 = x1 + c1.balanceOf(address(this)) - b1;

        (sqrtP,,,) = poolManager.getSlot0(idB);
        realLiquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sLo, sHi, x0, x1);
        BalanceDelta m;
        (tokenId, m) = _mint(keyB, lo, hi, realLiquidity);
        uint256 used0 = uint128(-m.amount0());
        uint256 used1 = uint128(-m.amount1());
        idle0 = x0 > used0 ? x0 - used0 : 0;
        idle1 = x1 > used1 ? x1 - used1 : 0;
    }

    function _recenterBoth(uint256 shadowId) internal {
        (, int24 tick,,) = poolManager.getSlot0(idA);
        int24 mid = (tick / TS) * TS;
        hook.rebalanceShadow(shadowId, mid - 300, mid + 300);
        _realRebalance(mid - 300, mid + 300);
        console2.log("  rebalanced around tick, relative to start:", mid - center);
    }

    function _valueRun(uint256 shareBps) internal returns (int256 errorPpm) {
        uint128 liquidity = _activeShare(shareBps);
        uint256 shadowId = hook.openShadow(idA, center - 300, center + 300, liquidity);
        (tokenId,) = _mint(keyB, center - 300, center + 300, liquidity);
        realLiquidity = liquidity;

        _randomSwaps(0, 100);
        // Price trends up and out of range.
        for (uint256 i; i < 6; ++i) {
            _swapBoth(false, 15e18);
        }
        _recenterBoth(shadowId);
        _randomSwaps(100, 200);
        // Price trends down.
        for (uint256 i; i < 10; ++i) {
            _swapBoth(true, 15e18);
        }
        _recenterBoth(shadowId);
        _randomSwaps(200, 300);

        BalanceDelta d = positionManager.decreaseLiquidity(
            tokenId, realLiquidity, 0, 0, address(this), vm.getBlockTimestamp() + 1, ""
        );
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        uint256 realValue = _in1(idle0 + uint128(d.amount0()), sqrtP) + idle1 + uint128(d.amount1());

        IProvingGround.Score memory sc = hook.scoreAtSpot(shadowId);
        errorPpm = _ppm(sc.navConservative, realValue);

        console2.log("shadow size, bps of active liquidity:", shareBps);
        console2.log("  value of simply holding:", sc.navHold);
        console2.log("  real position value:", realValue);
        console2.log("  shadow value (conservative):", sc.navConservative);
        console2.log("  shadow value (raw):", sc.navRaw);
        console2.log("  shadow vs real, error ppm:", errorPpm);
        console2.log("  modelled rebalance cost:", sc.rebalanceCost);
        console2.log("  alpha vs passive benchmark at spot, bps:", sc.alphaBps);
        console2.log("  alpha vs passive benchmark at the time-weighted price, bps:", hook.score(shadowId).alphaBps);

        assertGe(sc.navRaw, sc.navConservative, "raw value is never below conservative");
        assertEq(hook.getShadow(shadowId).rebalances, 2);
    }

    function test_value_after_two_rebalances_1pct() public {
        int256 errorPpm = _valueRun(100);
        assertLe(_abs(errorPpm), VALUE_LIMIT_PPM, "shadow value within 10 bps of the real position");
    }

    function test_value_after_two_rebalances_10pct_reportOnly() public {
        _valueRun(1000);
    }

    // ------------------------------------------------------------------ passive benchmark

    /// @dev The hook's benchmark is a virtual full-range position. Pool B holds that position for real.
    function _benchmarkRun(bool inRange) internal {
        uint256 shadowId = hook.openShadow(idA, center - 300, center + 300, _activeShare(100));
        IProvingGround.Shadow memory s = hook.getShadow(shadowId);

        (uint160 sqrtOpen,,,) = poolManager.getSlot0(idA);
        BalanceDelta paid;
        (tokenId, paid) = _mint(keyB, TickMath.minUsableTick(TS), TickMath.maxUsableTick(TS), s.benchLiquidity);
        uint256 realStart = _in1(uint128(-paid.amount0()), sqrtOpen) + uint128(-paid.amount1());
        uint256 shadowStart = _in1(s.hold0, sqrtOpen) + s.hold1;
        assertLe(_abs(_ppm(realStart, shadowStart)), 100, "benchmark starts at the shadow's starting value");

        if (inRange) {
            _pingPong(0, 300);
        } else {
            _randomSwaps(0, 150);
            for (uint256 i; i < 8; ++i) {
                _swapBoth(false, 15e18);
            }
            _randomSwaps(150, 300);
        }

        BalanceDelta fees = positionManager.collect(tokenId, 0, 0, address(this), vm.getBlockTimestamp() + 1, "");
        BalanceDelta principal = positionManager.decreaseLiquidity(
            tokenId, s.benchLiquidity, 0, 0, address(this), vm.getBlockTimestamp() + 1, ""
        );
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(idA);
        uint256 realFees = _in1(uint128(fees.amount0()), sqrtP) + uint128(fees.amount1());
        uint256 realValue = realFees + _in1(uint128(principal.amount0()), sqrtP) + uint128(principal.amount1());

        IProvingGround.Score memory sc = hook.scoreAtSpot(shadowId);
        int256 feesPpm = _ppm(sc.feesBenchmark, realFees);
        int256 valuePpm = _ppm(sc.navBenchmark, realValue);

        console2.log(inRange ? "flow: price stays in range" : "flow: price trends away");
        console2.log("  final tick, relative to start:", tick - center);
        console2.log("  real full-range position, value:", realValue);
        console2.log("  virtual benchmark, value error ppm:", valuePpm);
        console2.log("  real full-range position, fees:", realFees);
        console2.log("  virtual benchmark, fees error ppm:", feesPpm);

        assertLe(_abs(valuePpm), BENCHMARK_LIMIT_PPM, "benchmark value within 1.0% of a real full-range position");
        assertLe(_abs(feesPpm), BENCHMARK_LIMIT_PPM, "benchmark fees within 1.0% of a real full-range position");
    }

    function test_benchmark_trending() public {
        _benchmarkRun(false);
    }

    function test_benchmark_inrange() public {
        _benchmarkRun(true);
    }
}

/// @notice Two 18-decimal tokens at a price of 1.
contract Accuracy18x18Test is AccuracySuite {
    function setUp() public {
        _setUpTwin(18, 18, 0, 1e18, 10_000);
    }
}

/// @notice A 6-decimal token0 against an 18-decimal token1, priced like 3,000 token0 per token1.
contract Accuracy6x18Test is AccuracySuite {
    function setUp() public {
        _setUpTwin(6, 18, 196260, 1e13, 10_000);
    }
}

/// @notice An 18-decimal token0 against a 6-decimal token1, priced like 3,000 token1 per token0.
contract Accuracy18x6Test is AccuracySuite {
    function setUp() public {
        _setUpTwin(18, 6, -196260, 1e13, 10_000);
    }
}
