// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ScoreMath} from "../src/libraries/ScoreMath.sol";

contract ScoreMathTest is Test {
    uint160 internal constant SQRT_1_1 = uint160(FixedPoint96.Q96);

    function _tick(int256 seed, int24 lo, int24 hi) internal pure returns (int24) {
        return int24(bound(seed, lo, hi));
    }

    // ------------------------------------------------------------------ amounts and values

    /// @dev Checked against the reference implementation in v4-core's test utilities.
    function testFuzz_amountsFor_matchesReference(int256 a, int256 b, int256 p, uint128 liquidity) public pure {
        int24 lower = _tick(a, -200_000, 199_999);
        int24 upper = _tick(b, lower + 1, 200_000);
        uint160 sqrtP = TickMath.getSqrtPriceAtTick(_tick(p, -220_000, 220_000));

        (uint256 got0, uint256 got1) = ScoreMath.amountsFor(sqrtP, lower, upper, liquidity);
        (uint256 want0, uint256 want1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtP, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), liquidity
        );
        assertEq(got0, want0);
        assertEq(got1, want1);
    }

    function test_amountsFor_isOneSidedOutsideTheRange() public pure {
        (uint256 below0, uint256 below1) = ScoreMath.amountsFor(TickMath.getSqrtPriceAtTick(-500), -300, 300, 1e18);
        assertGt(below0, 0);
        assertEq(below1, 0);
        (uint256 above0, uint256 above1) = ScoreMath.amountsFor(TickMath.getSqrtPriceAtTick(500), -300, 300, 1e18);
        assertEq(above0, 0);
        assertGt(above1, 0);
    }

    function test_toToken1_atPriceOne_isIdentity() public pure {
        assertEq(ScoreMath.toToken1(123e18, SQRT_1_1), 123e18);
        assertEq(ScoreMath.valueOf(2e18, 3e18, SQRT_1_1), 5e18);
    }

    function test_toToken1_usesThePrice() public pure {
        // sqrt price 2 means price 4.
        assertEq(ScoreMath.toToken1(1e18, SQRT_1_1 * 2), 4e18);
    }

    // ------------------------------------------------------------------ fees

    function test_feesFor_scalesGrowthByLiquidity() public pure {
        // Growth of 3 tokens per unit of liquidity (x 2^128), on 5 units of liquidity.
        assertEq(ScoreMath.feesFor(10 * ScoreMath.Q128, 7 * ScoreMath.Q128, 5), 15);
    }

    function test_feesFor_survivesTheCounterWrapping() public pure {
        uint256 then_ = type(uint256).max - ScoreMath.Q128 + 1; // one unit before the wrap
        uint256 now_ = 2 * ScoreMath.Q128; // two units after it
        assertEq(ScoreMath.feesFor(now_, then_, 7), 21);
    }

    function testFuzz_haircut_neverExceedsRaw(uint128 raw, uint128 open, uint128 liquidity) public pure {
        vm.assume(uint256(open) + liquidity > 0);
        uint256 cut = ScoreMath.haircut(raw, open, liquidity);
        assertLe(cut, raw);
        assertEq(cut, FullMath.mulDiv(raw, open, uint256(open) + liquidity));
    }

    function test_haircut_examples() public pure {
        assertEq(ScoreMath.haircut(1000, 99, 1), 990); // a shadow that is 1% of the pool gives up 1%
        assertEq(ScoreMath.haircut(1000, 1, 1), 500);
        assertEq(ScoreMath.haircut(1000, 0, 1), 0);
    }

    // ------------------------------------------------------------------ rebalance cost and plan

    function test_rebalanceCost_example() public pure {
        // Swap 1 token1 in a 0.3% pool with 1000 units of liquidity at price 1:
        // fee 0.003, price impact 1 x 1 / 1000 = 0.001.
        assertEq(ScoreMath.rebalanceCost(1e18, SQRT_1_1, 3000, 1000e18), 4e15);
    }

    function test_rebalanceCost_impactGrowsWithTheSquareOfSize() public pure {
        uint256 small = ScoreMath.rebalanceCost(1e18, SQRT_1_1, 0, 1000e18);
        uint256 big = ScoreMath.rebalanceCost(10e18, SQRT_1_1, 0, 1000e18);
        assertEq(big, 100 * small);
    }

    function _plan(uint256 held0, uint256 held1, int24 lower, int24 upper, uint128 maxLiquidity)
        internal
        pure
        returns (uint256 liquidity, uint256 idle, uint256 cost)
    {
        return ScoreMath.planRebalance(
            ScoreMath.RebalanceInput({
                held0: held0,
                held1: held1,
                sqrtPriceX96: SQRT_1_1,
                tickLower: lower,
                tickUpper: upper,
                maxLiquidity: maxLiquidity,
                lpFee: 3000,
                activeLiquidity: 1_000_000e18
            })
        );
    }

    function test_planRebalance_noSwapNeeded_costsNothing() public pure {
        // Already holding exactly the mix the range needs.
        (uint256 a0, uint256 a1) = ScoreMath.amountsFor(SQRT_1_1, -300, 300, 1000e18);
        (uint256 liquidity, uint256 idle, uint256 cost) = _plan(a0, a1, -300, 300, type(uint128).max);
        assertApproxEqRel(liquidity, 1000e18, 1e6);
        assertLe(cost, 1e6);
        assertLe(idle, 1e6);
    }

    function test_planRebalance_oneSidedHoldings_payForHalfTheSwap() public pure {
        // All token1, symmetric range at price 1: half must be swapped, at 0.3% plus a little impact.
        (uint256 liquidity,, uint256 cost) = _plan(0, 100e18, -300, 300, type(uint128).max);
        assertGt(liquidity, 0);
        assertApproxEqRel(cost, 50e18 * 3 / 1000, 0.02e18);
    }

    function test_planRebalance_respectsTheCap() public pure {
        (uint256 liquidity, uint256 idle,) = _plan(50e18, 50e18, -300, 300, 100e18);
        assertEq(liquidity, 100e18);
        assertGt(idle, 90e18, "most of the value stays idle");
    }

    function test_planRebalance_returnsZeroWhenCostEatsEverything() public pure {
        (uint256 liquidity,,) = ScoreMath.planRebalance(
            ScoreMath.RebalanceInput({
                held0: 0,
                held1: 100e18,
                sqrtPriceX96: SQRT_1_1,
                tickLower: -300,
                tickUpper: 300,
                maxLiquidity: type(uint128).max,
                lpFee: 3000,
                activeLiquidity: 1 // almost no liquidity to trade against
            })
        );
        assertEq(liquidity, 0);
    }

    /// @dev Position + idle + cost accounts for everything held: nothing is created or lost.
    function testFuzz_planRebalance_conservesValue(
        uint96 held0,
        uint96 held1,
        int256 lowerSeed,
        int256 widthSeed,
        uint128 maxLiquidity
    ) public pure {
        vm.assume(uint256(held0) + held1 > 1e12);
        int24 lower = _tick(lowerSeed, -6000, -1);
        int24 upper = _tick(widthSeed, 1, 6000);

        (uint256 liquidity, uint256 idle, uint256 cost) = _plan(held0, held1, lower, upper, maxLiquidity);
        uint256 total = uint256(held0) + held1; // price is 1
        if (liquidity == 0) return;

        assertLe(liquidity, maxLiquidity);
        (uint256 p0, uint256 p1) = ScoreMath.amountsFor(SQRT_1_1, lower, upper, uint128(liquidity));
        // Exact, up to a few wei of rounding in the liquidity conversion.
        assertApproxEqAbs(p0 + p1 + idle + cost, total, 4);
    }

    // ------------------------------------------------------------------ alpha

    function test_alphaBps_examples() public pure {
        assertEq(ScoreMath.alphaBps(110, 100), 1000);
        assertEq(ScoreMath.alphaBps(90, 100), -1000);
        assertEq(ScoreMath.alphaBps(100, 100), 0);
        assertEq(ScoreMath.alphaBps(0, 100), -10_000);
        assertEq(ScoreMath.alphaBps(100, 0), 0);
    }
}
