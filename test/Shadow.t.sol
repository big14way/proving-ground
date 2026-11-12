// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {BaseTest} from "./utils/BaseTest.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

import {ShadowHook} from "../src/ShadowHook.sol";

/// Pool A carries the hook and a capital-free shadow position.
/// Pool B is an identical pool with no hook where the SAME position is held with real money.
/// Both pools receive the same swaps. Pool B is the ground truth the shadow score is judged against.
contract ShadowTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    ShadowHook hook;
    Currency c0;
    Currency c1;
    PoolKey keyA;
    PoolKey keyB;
    PoolId idA;
    PoolId idB;

    int24 constant TS = 60;
    uint24 constant FEE = 3000;

    // real position bookkeeping (pool B)
    uint256 tokenId;
    uint128 realLiq;
    uint256 idle0;
    uint256 idle1;

    function setUp() public {
        deployArtifactsAndLabel();
        (c0, c1) = deployCurrencyPair();

        address flagAddr = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG) ^ (uint160(0x4444) << 144));
        deployCodeTo("ShadowHook.sol:ShadowHook", abi.encode(poolManager), flagAddr);
        hook = ShadowHook(flagAddr);

        keyA = PoolKey(c0, c1, FEE, TS, IHooks(address(hook)));
        keyB = PoolKey(c0, c1, FEE, TS, IHooks(address(0)));
        idA = keyA.toId();
        idB = keyB.toId();
        poolManager.initialize(keyA, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(keyB, Constants.SQRT_PRICE_1_1);
        hook.setKey(keyA);
        c0.transfer(address(hook), 1e6);
        c1.transfer(address(hook), 1e6);

        _base(keyA);
        _base(keyB);
    }

    // Three overlapping LPs so swaps cross initialized ticks inside the shadow range.
    function _base(PoolKey memory k) internal {
        _mint(k, -12000, 12000, 2000e18);
        _mint(k, -600, 600, 1500e18);
        _mint(k, -120, 180, 1000e18);
    }

    function _mint(PoolKey memory k, int24 lo, int24 hi, uint128 liq) internal returns (uint256 tid, BalanceDelta d) {
        (tid, d) = positionManager.mint(k, lo, hi, liq, 1e24, 1e24, address(this), block.timestamp + 1, "");
    }

    function _swap(PoolKey memory k, bool z, uint256 amt) internal {
        swapRouter.swapExactTokensForTokens(amt, 0, z, k, "", address(this), block.timestamp + 1);
    }

    function _swapBoth(bool z, uint256 amt) internal {
        _swap(keyA, z, amt);
        _swap(keyB, z, amt);
    }

    function _randomSwaps(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            uint256 h = uint256(keccak256(abi.encode(i)));
            _swapBoth(h & 1 == 1, 0.5e18 + (h >> 8) % 20e18);
        }
    }

    // Flow that keeps the price inside the shadow range: the worst case for dilution.
    function _pingPong(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            uint256 h = uint256(keccak256(abi.encode(i)));
            (, int24 tick,,) = poolManager.getSlot0(idA);
            bool z = tick > 150 ? true : tick < -150 ? false : h & 1 == 1;
            _swapBoth(z, 0.5e18 + (h >> 8) % 8e18);
        }
    }

    function _in1(uint256 a0, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(a0, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }

    function _bps(uint256 shadow, uint256 real) internal pure returns (int256) {
        return (int256(shadow) - int256(real)) * 10000 / int256(real);
    }

    // ------------------------------------------------------------------ 1. fee accuracy vs dilution

    function _feeAccuracy(uint256 ratioBps) internal returns (int256 naiveErr, int256 fixedErr) {
        uint128 lv = uint128(uint256(poolManager.getLiquidity(idB)) * ratioBps / 10000);
        uint256 sid = hook.openShadow(-300, 300, lv);
        (tokenId,) = _mint(keyB, -300, 300, lv);

        if (inRangeFlow) _pingPong(0, 300);
        else _randomSwaps(0, 300);

        BalanceDelta col = positionManager.collect(tokenId, 0, 0, address(this), block.timestamp + 1, "");
        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(idA);
        uint256 realV = _in1(uint128(col.amount0()), sqrtP) + uint128(col.amount1());

        (,,,,,, uint256 f0, uint256 f1, uint256 n0, uint256 n1,) = hook.shadows(sid);
        uint256 fixedV = _in1(f0, sqrtP) + f1;
        uint256 naiveV = _in1(n0, sqrtP) + n1;

        naiveErr = _bps(naiveV, realV);
        fixedErr = _bps(fixedV, realV);
        console2.log("shadow size, bps of active liquidity:", ratioBps);
        console2.log("  final tick:", tick);
        console2.log("  real fees (token1 units, 1e18):", realV);
        console2.log("  naive shadow error bps:", naiveErr);
        console2.log("  corrected shadow error bps:", fixedErr);

        // Lazy alternative: no per-swap work, one haircut applied at checkpoint time.
        uint256 l0 = uint256(lv) * 10000 / ratioBps; // active liquidity when the shadow opened
        uint256 l1 = poolManager.getLiquidity(idA); // active liquidity at checkpoint
        uint256 lmin = l0 < l1 ? l0 : l1;
        console2.log("  lazy haircut (open liquidity) error bps:", _bps(naiveV * l0 / (l0 + lv), realV));
        console2.log("  lazy haircut (min of open/now) error bps:", _bps(naiveV * lmin / (lmin + lv), realV));
    }

    function test_fees_size_0_1pct() public {
        (, int256 e) = _feeAccuracy(10);
        assertLt(e < 0 ? -e : e, 100, "corrected within 1%");
    }

    function test_fees_size_1pct() public {
        (, int256 e) = _feeAccuracy(100);
        assertLt(e < 0 ? -e : e, 100, "corrected within 1%");
    }

    function test_fees_size_10pct() public {
        _feeAccuracy(1000);
    }

    function test_fees_size_50pct() public {
        _feeAccuracy(5000);
    }

    bool inRangeFlow;

    function test_inrange_fees_size_0_1pct() public {
        inRangeFlow = true;
        _feeAccuracy(10);
    }

    function test_inrange_fees_size_1pct() public {
        inRangeFlow = true;
        _feeAccuracy(100);
    }

    function test_inrange_fees_size_10pct() public {
        inRangeFlow = true;
        _feeAccuracy(1000);
    }

    function test_inrange_fees_size_50pct() public {
        inRangeFlow = true;
        _feeAccuracy(5000);
    }

    function test_nav_10pct_with_impact_model() public {
        hook.setModelImpact(true);
        _navRun(1000, 0);
    }

    function test_nav_1pct_with_impact_model() public {
        hook.setModelImpact(true);
        _navRun(100, 0);
    }

    // ------------------------------------------------------------------ 2. rebalances and net asset value

    function _realRebalance(int24 lo, int24 hi) internal {
        BalanceDelta d = positionManager.decreaseLiquidity(tokenId, realLiq, 0, 0, address(this), block.timestamp + 1, "");
        uint256 x0 = idle0 + uint128(d.amount0());
        uint256 x1 = idle1 + uint128(d.amount1());

        (uint160 sqrtP,,,) = poolManager.getSlot0(idB);
        uint160 sLo = TickMath.getSqrtPriceAtTick(lo);
        uint160 sHi = TickMath.getSqrtPriceAtTick(hi);
        (uint256 r0, uint256 r1) = LiquidityAmounts.getAmountsForLiquidity(sqrtP, sLo, sHi, 1e18);
        uint256 need0 = FullMath.mulDiv(r0, FullMath.mulDiv(_in1(x0, sqrtP) + x1, 1e18, _in1(r0, sqrtP) + r1), 1e18);

        // A real swap through the pool itself: pays the fee and moves the price.
        uint256 b0 = c0.balanceOf(address(this));
        uint256 b1 = c1.balanceOf(address(this));
        if (x0 > need0) _swap(keyB, true, x0 - need0);
        else if (need0 > x0) _swap(keyB, false, _in1(need0 - x0, sqrtP));
        x0 = x0 + c0.balanceOf(address(this)) - b0;
        x1 = x1 + c1.balanceOf(address(this)) - b1;

        (sqrtP,,,) = poolManager.getSlot0(idB);
        realLiq = LiquidityAmounts.getLiquidityForAmounts(sqrtP, sLo, sHi, x0, x1);
        BalanceDelta m;
        (tokenId, m) = _mint(keyB, lo, hi, realLiq);
        uint256 u0 = uint128(-m.amount0());
        uint256 u1 = uint128(-m.amount1());
        idle0 = x0 > u0 ? x0 - u0 : 0;
        idle1 = x1 > u1 ? x1 - u1 : 0;
    }

    function _recenterBoth(uint256 sid) internal {
        (, int24 tick,,) = poolManager.getSlot0(idA);
        int24 c = (tick / TS) * TS;
        hook.rebalance(sid, c - 300, c + 300);
        _realRebalance(c - 300, c + 300);
        console2.log("  rebalanced around tick:", c);
    }

    function _navRun(uint256 ratioBps, uint24 slipPips) internal {
        hook.setSlippagePips(slipPips);
        uint128 lv = uint128(uint256(poolManager.getLiquidity(idB)) * ratioBps / 10000);
        (uint256 h0, uint256 h1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(-300), TickMath.getSqrtPriceAtTick(300), lv
        );
        uint256 sid = hook.openShadow(-300, 300, lv);
        (tokenId,) = _mint(keyB, -300, 300, lv);
        realLiq = lv;

        _randomSwaps(0, 100);
        for (uint256 i; i < 6; ++i) _swapBoth(false, 15e18); // price trends up, out of range
        _recenterBoth(sid);
        _randomSwaps(100, 200);
        for (uint256 i; i < 10; ++i) _swapBoth(true, 15e18); // price trends down
        _recenterBoth(sid);
        _randomSwaps(200, 300);

        BalanceDelta d = positionManager.decreaseLiquidity(tokenId, realLiq, 0, 0, address(this), block.timestamp + 1, "");
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        uint256 realNav = _in1(idle0 + uint128(d.amount0()), sqrtP) + idle1 + uint128(d.amount1());
        uint256 shadowNav = hook.nav(sid);
        uint256 hodl = _in1(h0, sqrtP) + h1;
        (,,,,,,,,,, uint256 cost) = hook.shadows(sid);

        console2.log("shadow size bps:", ratioBps);
        console2.log("  hold-tokens value:", hodl);
        console2.log("  real position value:", realNav);
        console2.log("  shadow value:", shadowNav);
        console2.log("  shadow vs real, bps of value:", _bps(shadowNav, realNav));
        console2.log("  real profit vs holding:", int256(realNav) - int256(hodl));
        console2.log("  shadow profit vs holding:", int256(shadowNav) - int256(hodl));
        console2.log("  modelled rebalance cost:", cost);
    }

    function test_nav_1pct() public {
        _navRun(100, 0);
    }

    function test_nav_10pct() public {
        _navRun(1000, 0);
    }

    // ------------------------------------------------------------------ 3. gas added per swap

    function _gasOfSwap(PoolKey memory k) internal returns (uint256 g) {
        _swap(k, true, 1e18); // warm
        g = gasleft();
        _swap(k, false, 1e18);
        g -= gasleft();
    }

    function test_gas() public {
        uint256 plain = _gasOfSwap(keyB);
        uint256 none = _gasOfSwap(keyA);
        hook.openShadow(-300, 300, 1e18);
        uint256 one = _gasOfSwap(keyA);
        for (uint256 i; i < 4; ++i) hook.openShadow(-300 - int24(int256(i + 1)) * 60, 300, 1e18);
        uint256 five = _gasOfSwap(keyA);
        console2.log("swap gas, no hook:", plain);
        console2.log("swap gas, hook with 0 shadows:", none);
        console2.log("swap gas, 1 shadow:", one);
        console2.log("swap gas, 5 shadows:", five);
    }
}
