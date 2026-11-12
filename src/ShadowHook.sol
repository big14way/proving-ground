// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @notice Feasibility prototype: score a capital-free "shadow" LP position against live swap flow.
/// A dust-sized real position keeps the shadow range's ticks initialized so the pool tracks
/// fee growth inside it; the hook scales that growth by the shadow's virtual liquidity.
contract ShadowHook is BaseHook, IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    uint128 internal constant DUST = 1000;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant UNIT = 1e18;

    struct Shadow {
        address curator;
        int24 lower;
        int24 upper;
        uint128 liq; // virtual liquidity
        uint256 fgLast0;
        uint256 fgLast1;
        uint256 fees0; // dilution-corrected virtual fees since last rebalance
        uint256 fees1;
        uint256 naive0; // uncorrected, kept only to measure the overstatement
        uint256 naive1;
        uint256 costPaid1; // cumulative modelled rebalance cost, in token1
    }

    PoolKey public key;
    PoolId public id;
    Shadow[] public shadows;
    uint24 public slippagePips; // extra haircut on rebalance swaps, on top of the pool fee

    uint128 transient preLiq;
    int24 transient preTick;

    constructor(IPoolManager m) BaseHook(m) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
    }

    function setKey(PoolKey calldata k) external {
        require(address(key.hooks) == address(0), "set");
        key = k;
        id = k.toId();
    }

    function setSlippagePips(uint24 s) external {
        slippagePips = s;
    }

    bool public modelImpact;

    function setModelImpact(bool on) external {
        modelImpact = on;
    }

    // ------------------------------------------------------------------ shadows

    function openShadow(int24 lower, int24 upper, uint128 liq) external returns (uint256 sid) {
        sid = shadows.length;
        shadows.push();
        Shadow storage s = shadows[sid];
        s.curator = msg.sender;
        s.liq = liq;
        _place(s, sid, lower, upper);
    }

    function rebalance(uint256 sid, int24 newLower, int24 newUpper) external {
        Shadow storage s = shadows[sid];
        require(msg.sender == s.curator, "curator");
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);

        // What the virtual position holds right now, fees included.
        (uint256 x0, uint256 x1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(s.lower), TickMath.getSqrtPriceAtTick(s.upper), s.liq
        );
        x0 += s.fees0;
        x1 += s.fees1;

        // Token mix the new range needs per UNIT of liquidity at this price.
        (uint256 r0, uint256 r1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(newLower), TickMath.getSqrtPriceAtTick(newUpper), uint128(UNIT)
        );
        uint256 v = _in1(r0, sqrtP) + r1;
        uint256 total = _in1(x0, sqrtP) + x1;

        // First-order cost of the swap needed to reach that mix: pool fee plus a slippage haircut.
        uint256 need0 = FullMath.mulDiv(r0, FullMath.mulDiv(total, UNIT, v), UNIT);
        uint256 swapped0 = x0 > need0 ? x0 - need0 : need0 - x0;
        uint256 swapped1 = _in1(swapped0, sqrtP);
        uint256 cost1 = swapped1 * (uint256(key.fee) + slippagePips) / 1e6;
        if (modelImpact) {
            // Price impact of trading `swapped1` against the pool's active liquidity L:
            // average execution is worse by about swapped1 / (L * sqrtP).
            uint256 L = poolManager.getLiquidity(id);
            cost1 += FullMath.mulDiv(FullMath.mulDiv(swapped1, FixedPoint96.Q96, sqrtP), swapped1, L);
        }
        s.costPaid1 += cost1;

        _unlock(s.lower, s.upper, -int256(uint256(DUST)), sid);
        s.liq = uint128(FullMath.mulDiv(total - cost1, UNIT, v));
        s.fees0 = 0;
        s.fees1 = 0;
        _place(s, sid, newLower, newUpper);
    }

    /// @notice Shadow net asset value, in token1, at the pool's current price.
    function nav(uint256 sid) external view returns (uint256) {
        Shadow storage s = shadows[sid];
        (uint160 sqrtP,,,) = poolManager.getSlot0(id);
        (uint256 x0, uint256 x1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(s.lower), TickMath.getSqrtPriceAtTick(s.upper), s.liq
        );
        return _in1(x0 + s.fees0, sqrtP) + x1 + s.fees1;
    }

    function _place(Shadow storage s, uint256 sid, int24 lower, int24 upper) internal {
        s.lower = lower;
        s.upper = upper;
        _unlock(lower, upper, int256(uint256(DUST)), sid);
        (s.fgLast0, s.fgLast1) = poolManager.getFeeGrowthInside(id, lower, upper);
    }

    function _in1(uint256 amount0, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }

    // ------------------------------------------------------------------ dust position plumbing

    function _unlock(int24 lower, int24 upper, int256 delta, uint256 sid) internal {
        poolManager.unlock(abi.encode(lower, upper, delta, sid));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "pm");
        (int24 lower, int24 upper, int256 delta, uint256 sid) = abi.decode(data, (int24, int24, int256, uint256));
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: delta, salt: bytes32(sid)}), ""
        );
        _square(key.currency0, d.amount0());
        _square(key.currency1, d.amount1());
        return "";
    }

    function _square(Currency c, int128 amt) internal {
        if (amt < 0) c.settle(poolManager, address(this), uint128(-amt), false);
        else if (amt > 0) c.take(poolManager, address(this), uint128(amt), false);
    }

    // ------------------------------------------------------------------ scoring

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (, int24 tick,,) = poolManager.getSlot0(id);
        preTick = tick;
        preLiq = poolManager.getLiquidity(id);
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        uint128 postLiq = poolManager.getLiquidity(id);
        uint256 n = shadows.length;
        for (uint256 i; i < n; ++i) {
            Shadow storage s = shadows[i];
            (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthInside(id, s.lower, s.upper);
            uint256 d0;
            uint256 d1;
            unchecked {
                d0 = fg0 - s.fgLast0;
                d1 = fg1 - s.fgLast1;
            }
            if (d0 == 0 && d1 == 0) continue;
            s.fgLast0 = fg0;
            s.fgLast1 = fg1;

            // Real capital would have joined the active liquidity and diluted fee growth.
            // Scale by L / (L + virtual), using the active liquidity the swap ran against.
            uint256 L = (preTick >= s.lower && preTick < s.upper) ? preLiq : postLiq;
            uint256 n0 = FullMath.mulDiv(d0, s.liq, Q128);
            uint256 n1 = FullMath.mulDiv(d1, s.liq, Q128);
            s.naive0 += n0;
            s.naive1 += n1;
            s.fees0 += FullMath.mulDiv(n0, L, L + s.liq);
            s.fees1 += FullMath.mulDiv(n1, L, L + s.liq);
        }
        return (this.afterSwap.selector, 0);
    }
}
