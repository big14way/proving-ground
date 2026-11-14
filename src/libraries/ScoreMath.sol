// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";

/// @title ScoreMath
/// @notice Pure maths for scoring a virtual liquidity position. All values are in token1 units.
library ScoreMath {
    uint256 internal constant Q128 = 1 << 128;
    /// @dev Liquidity amount used when pricing "one unit" of a range. Large, so that rounding in
    /// the per-unit figures stays below one wei for any realistic position.
    uint256 internal constant UNIT = 1e30;
    uint256 internal constant BPS = 10_000;

    /// @notice Token amounts held by `liquidity` on [tickLower, tickUpper) at price `sqrtPriceX96`.
    function amountsFor(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, false);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, false);
        }
    }

    /// @notice Converts an amount of token0 into token1 at `sqrtPriceX96`.
    function toToken1(uint256 amount0, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtPriceX96, FixedPoint96.Q96), sqrtPriceX96, FixedPoint96.Q96);
    }

    /// @notice Value of a pair of token amounts, in token1.
    function valueOf(uint256 amount0, uint256 amount1, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return toToken1(amount0, sqrtPriceX96) + amount1;
    }

    /// @notice Fees earned by `liquidity` while fee growth moved from `growthThen` to `growthNow`.
    /// @dev Fee growth wraps by design, so the difference is taken unchecked.
    function feesFor(uint256 growthNow, uint256 growthThen, uint128 liquidity) internal pure returns (uint256) {
        uint256 delta;
        unchecked {
            delta = growthNow - growthThen;
        }
        return FullMath.mulDiv(delta, liquidity, Q128);
    }

    /// @notice Scales raw virtual fees down for the dilution real capital would have caused:
    /// `raw x L / (L + virtual)`, with L the pool's active liquidity when the position was placed.
    function haircut(uint256 rawFees, uint128 openLiquidity, uint128 liquidity) internal pure returns (uint256) {
        return FullMath.mulDiv(rawFees, openLiquidity, uint256(openLiquidity) + liquidity);
    }

    /// @notice Token0 amount and token1 value held by `UNIT` of liquidity on a range.
    function perUnit(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        internal
        pure
        returns (uint256 unitAmount0, uint256 unitValue)
    {
        uint256 unitAmount1;
        (unitAmount0, unitAmount1) = amountsFor(sqrtPriceX96, tickLower, tickUpper, uint128(UNIT));
        unitValue = valueOf(unitAmount0, unitAmount1, sqrtPriceX96);
    }

    /// @notice Modelled cost of the swap a rebalance needs, in token1: the pool fee on the amount
    /// swapped, plus price impact against the pool's active liquidity.
    /// @dev Swapping `dy` of token1 against liquidity L moves sqrt(price) by dy / L, so the average
    /// execution price is worse by about dy / (L x sqrt(price)).
    function rebalanceCost(uint256 swapped1, uint160 sqrtPriceX96, uint24 lpFee, uint128 activeLiquidity)
        internal
        pure
        returns (uint256)
    {
        uint256 fee = FullMath.mulDiv(swapped1, lpFee, 1e6);
        uint256 impact =
            FullMath.mulDiv(FullMath.mulDiv(swapped1, FixedPoint96.Q96, sqrtPriceX96), swapped1, activeLiquidity);
        return fee + impact;
    }

    struct RebalanceInput {
        uint256 held0; // token0 the shadow holds now
        uint256 held1; // token1 the shadow holds now
        uint160 sqrtPriceX96;
        int24 tickLower; // the new range
        int24 tickUpper;
        uint128 maxLiquidity; // size cap for the new position
        uint24 lpFee;
        uint128 activeLiquidity;
    }

    /// @notice Works out a virtual rebalance: the liquidity placed on the new range, the token1 left
    /// idle, and the modelled cost. Returns zero liquidity when the cost would consume everything.
    /// @dev Aims to put the whole value to work, but never above `maxLiquidity`. What does not fit
    /// stays idle as token1.
    function planRebalance(RebalanceInput memory p)
        internal
        pure
        returns (uint256 liquidity, uint256 idle, uint256 cost)
    {
        uint256 total = valueOf(p.held0, p.held1, p.sqrtPriceX96);
        (uint256 unitAmount0, uint256 unitValue) = perUnit(p.sqrtPriceX96, p.tickLower, p.tickUpper);
        if (unitValue == 0) return (0, 0, 0);

        liquidity = FullMath.mulDiv(total, UNIT, unitValue);
        if (liquidity > p.maxLiquidity) liquidity = p.maxLiquidity;

        // The swap that reaches the token mix that position needs, and what it would cost.
        uint256 need0 = FullMath.mulDiv(unitAmount0, liquidity, UNIT);
        uint256 swapped1 = toToken1(p.held0 > need0 ? p.held0 - need0 : need0 - p.held0, p.sqrtPriceX96);
        cost = rebalanceCost(swapped1, p.sqrtPriceX96, p.lpFee, p.activeLiquidity);
        if (cost >= total) return (0, 0, cost);

        // Whatever the cost leaves either fits in the position or stays idle.
        uint256 budget = total - cost;
        uint256 affordable = FullMath.mulDiv(budget, UNIT, unitValue);
        if (affordable < liquidity) liquidity = affordable;
        (uint256 placed0, uint256 placed1) = amountsFor(p.sqrtPriceX96, p.tickLower, p.tickUpper, uint128(liquidity));
        uint256 placed = valueOf(placed0, placed1, p.sqrtPriceX96);
        idle = budget > placed ? budget - placed : 0;
    }

    /// @notice (value / baseline - 1) in basis points. Zero when there is no baseline.
    function alphaBps(uint256 value, uint256 baseline) internal pure returns (int256) {
        if (baseline == 0) return 0;
        return int256(FullMath.mulDiv(value, BPS, baseline)) - int256(BPS);
    }
}
