// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TwinPools} from "./utils/TwinPools.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ProvingGroundHook} from "../src/ProvingGroundHook.sol";
import {IProvingGround} from "../src/interfaces/IProvingGround.sol";
import {Oracle} from "../src/libraries/Oracle.sol";

/// @notice Behaviour of the hook itself: pool registration, the oracle wired into swaps, the shadow
/// lifecycle and its guards, dust accounting, and swap gas.
contract ProvingGroundHookTest is TwinPools {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal stranger = makeAddr("stranger");

    function setUp() public {
        // Default size cap: a shadow may be at most 1% of the pool's active liquidity.
        _setUpTwin(18, 18, 0, 1e18, 100);
    }

    function _open() internal returns (uint256 shadowId) {
        shadowId = hook.openShadow(idA, -300, 300, _activeShare(100));
    }

    function _dustLiquidity(uint256 shadowId, int24 lo, int24 hi) internal view returns (uint128) {
        return
            poolManager.getPositionLiquidity(
                idA, Position.calculatePositionKey(address(hook), lo, hi, bytes32(shadowId))
            );
    }

    function _assertReserveMatchesBalance() internal view {
        assertEq(hook.dustReserve(c0), c0.balanceOf(address(hook)), "reserve0 equals the hook's balance");
        assertEq(hook.dustReserve(c1), c1.balanceOf(address(hook)), "reserve1 equals the hook's balance");
    }

    // ------------------------------------------------------------------ deployment and pools

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.afterInitialize);
        assertTrue(p.beforeSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
    }

    function test_config_isStored() public view {
        assertEq(hook.TWAP_WINDOW(), TWAP_WINDOW);
        assertEq(hook.ORACLE_CAPACITY(), ORACLE_CAPACITY);
        assertEq(hook.SHADOW_MAX_POOL_SHARE_BPS(), 100);
        assertEq(hook.DEFAULT_DYNAMIC_FEE(), FEE);
    }

    function test_config_invalidReverts() public {
        address at = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (uint160(0x7777) << 144));
        IProvingGround.Config memory bad = IProvingGround.Config({
            twapWindow: 0, oracleCapacity: 720, shadowMaxPoolShareBps: 100, defaultDynamicFee: 3000
        });
        vm.expectRevert();
        deployCodeTo("ProvingGroundHook.sol:ProvingGroundHook", abi.encode(poolManager, bad), at);
    }

    function test_initialize_registersPoolAndStartsOracle() public view {
        PoolKey memory stored = hook.getPoolKey(idA);
        assertEq(Currency.unwrap(stored.currency0), Currency.unwrap(c0));
        assertEq(Currency.unwrap(stored.currency1), Currency.unwrap(c1));
        assertEq(stored.fee, FEE);
        assertEq(stored.tickSpacing, TS);
        (, uint16 count,) = hook.oracleState(idA);
        assertEq(count, 1);
    }

    function test_initialize_rejectsNativeCurrency() public {
        PoolKey memory native = PoolKey(Currency.wrap(address(0)), c1, FEE, TS, IHooks(address(hook)));
        vm.expectRevert();
        poolManager.initialize(native, TickMath.getSqrtPriceAtTick(0));
    }

    function test_initialize_setsFeeOnDynamicFeePool() public {
        PoolKey memory dynamicKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, TS, IHooks(address(hook)));
        poolManager.initialize(dynamicKey, TickMath.getSqrtPriceAtTick(0));
        (,,, uint24 lpFee) = poolManager.getSlot0(dynamicKey.toId());
        assertEq(lpFee, FEE);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert();
        hook.unlockCallback("");
    }

    // ------------------------------------------------------------------ oracle wired into swaps

    function test_oracle_oneObservationPerBlock() public {
        (, uint16 before_,) = hook.oracleState(idA);
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        _swap(keyA, true, unit0);
        _swap(keyA, false, unit1);
        _swap(keyA, true, unit0);
        (, uint16 afterOneBlock, uint48 lastTime) = hook.oracleState(idA);
        assertEq(afterOneBlock, before_ + 1);
        assertEq(lastTime, vm.getBlockTimestamp());

        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        _swap(keyA, true, unit0);
        (, uint16 afterTwoBlocks,) = hook.oracleState(idA);
        assertEq(afterTwoBlocks, before_ + 2);
    }

    function test_twap_notReadyOnAYoungPool() public {
        vm.expectRevert(Oracle.OracleNotReady.selector);
        hook.twapTick(idA);
    }

    function test_twap_unknownPoolReverts() public {
        vm.expectRevert(IProvingGround.PoolNotRegistered.selector);
        hook.twapTick(idB);
    }

    function test_twap_readyAfterOneWindow_withNoSwapsAtAll() public {
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        assertEq(hook.twapTick(idA), 0);
    }

    function test_twap_ignoresSameBlockPriceMove_andOnlyDriftsAfter() public {
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        assertEq(hook.twapTick(idA), 0);

        // A large swap moves the pool price by hundreds of ticks inside one block.
        _swap(keyA, false, 60 * unit1);
        (, int24 spot,,) = poolManager.getSlot0(idA);
        assertGt(spot, 200, "spot moved a long way");
        assertEq(hook.twapTick(idA), 0, "the average is untouched in the same block");

        // One block later the moved price has only one block's weight in the window.
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        int24 twap = hook.twapTick(idA);
        assertGt(twap, 0);
        assertLe(twap, spot * int24(int256(BLOCK_TIME)) / int24(int256(uint256(TWAP_WINDOW))) + 1);
    }

    // ------------------------------------------------------------------ opening a shadow

    function test_open_recordsTheShadow() public {
        uint128 liquidity = _activeShare(100);
        uint128 active = poolManager.getLiquidity(idA);
        uint256 shadowId = hook.openShadow(idA, -300, 300, liquidity);
        assertEq(shadowId, 1);
        assertEq(hook.shadowCount(), 1);

        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        assertEq(PoolId.unwrap(s.poolId), PoolId.unwrap(idA));
        assertEq(s.curator, address(this));
        assertEq(s.tickLower, -300);
        assertEq(s.tickUpper, 300);
        assertEq(s.liquidity, liquidity);
        assertEq(s.openLiquidity, active);
        assertEq(s.openedAt, vm.getBlockTimestamp());
        assertEq(s.closedAt, 0);

        // Starting amounts, checked against an independent implementation.
        (uint256 e0, uint256 e1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(-300),
            TickMath.getSqrtPriceAtTick(300),
            liquidity
        );
        assertEq(s.hold0, e0);
        assertEq(s.hold1, e1);

        // At a price of 1 a full-range unit of liquidity is worth 2 token1, so the benchmark holds
        // half the shadow's starting value in liquidity units.
        assertApproxEqRel(uint256(s.benchLiquidity) * 2, e0 + e1, 1e12);
    }

    function test_open_takesNothingFromTheCurator_andPlacesDust() public {
        uint256 liquidity = _activeShare(100);
        vm.prank(stranger); // holds no tokens and has approved nothing
        uint256 shadowId = hook.openShadow(idA, -300, 300, uint128(liquidity));

        assertEq(_dustLiquidity(shadowId, -300, 300), hook.DUST());
        assertEq(c0.balanceOf(stranger), 0);
        assertEq(c1.balanceOf(stranger), 0);
        _assertReserveMatchesBalance();
    }

    function test_open_startsWithZeroFeesAndFlatScore() public {
        uint256 shadowId = _open();
        (uint256 r0, uint256 r1, uint256 k0, uint256 k1) = hook.shadowFees(shadowId);
        assertEq(r0 + r1 + k0 + k1, 0);

        IProvingGround.Score memory sc = hook.scoreAtSpot(shadowId);
        assertEq(sc.navConservative, sc.navHold);
        assertEq(sc.navRaw, sc.navConservative);
        assertApproxEqRel(sc.navBenchmark, sc.navHold, 1e12);
        assertEq(sc.alphaVsHoldBps, 0);
        assertEq(sc.rebalanceCost, 0);
    }

    function test_open_unknownPoolReverts() public {
        vm.expectRevert(IProvingGround.PoolNotRegistered.selector);
        hook.openShadow(idB, -300, 300, 1e18);
    }

    function test_open_zeroLiquidityReverts() public {
        vm.expectRevert(IProvingGround.ZeroLiquidity.selector);
        hook.openShadow(idA, -300, 300, 0);
    }

    function test_open_rangeMustContainTheCurrentTick() public {
        vm.expectRevert(IProvingGround.RangeMustContainTick.selector);
        hook.openShadow(idA, 60, 300, 1e18);
        vm.expectRevert(IProvingGround.RangeMustContainTick.selector);
        hook.openShadow(idA, -300, 0, 1e18); // the upper tick is exclusive
        hook.openShadow(idA, 0, 60, 1e18); // the lower tick is inclusive
    }

    function test_open_sizeCap() public {
        uint128 atCap = _activeShare(100);
        vm.expectRevert(IProvingGround.ShadowTooLarge.selector);
        hook.openShadow(idA, -300, 300, atCap + 1e18);
        hook.openShadow(idA, -300, 300, atCap);
    }

    function test_open_revertsWhenTheDustReserveIsEmpty() public {
        ProvingGroundHook bare = _deployHook(0x5555, 100);
        PoolKey memory key = PoolKey(c0, c1, 500, 10, IHooks(address(bare)));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        _mint(key, -600, 600, 1000e18);

        vm.expectRevert(abi.encodeWithSelector(IProvingGround.DustReserveLow.selector, c0));
        bare.openShadow(key.toId(), -300, 300, 1e18);
    }

    function test_fundDust_pullsTokensAndCredits() public {
        uint256 before_ = hook.dustReserve(c0);
        hook.fundDust(c0, 1234);
        assertEq(hook.dustReserve(c0), before_ + 1234);
        _assertReserveMatchesBalance();
    }

    function test_twoShadowsOnTheSameRange_areIndependent() public {
        uint256 a = hook.openShadow(idA, -300, 300, 1e18);
        vm.prank(stranger);
        uint256 b = hook.openShadow(idA, -300, 300, 2e18);
        assertEq(_dustLiquidity(a, -300, 300), hook.DUST());
        assertEq(_dustLiquidity(b, -300, 300), hook.DUST());

        _pingPong(0, 20);
        (uint256 a0, uint256 a1,,) = hook.shadowFees(a);
        (uint256 b0, uint256 b1,,) = hook.shadowFees(b);
        assertGt(a0 + a1, 0);
        assertApproxEqAbs(b0, 2 * a0, 2);
        assertApproxEqAbs(b1, 2 * a1, 2);
    }

    // ------------------------------------------------------------------ rebalancing a shadow

    function test_rebalance_onlyCurator() public {
        uint256 shadowId = _open();
        vm.prank(stranger);
        vm.expectRevert(IProvingGround.NotCurator.selector);
        hook.rebalanceShadow(shadowId, -600, 600);
    }

    function test_rebalance_unknownShadowReverts() public {
        vm.expectRevert(IProvingGround.UnknownShadow.selector);
        hook.rebalanceShadow(99, -600, 600);
    }

    function test_rebalance_newRangeMustContainTheCurrentTick() public {
        uint256 shadowId = _open();
        vm.expectRevert(IProvingGround.RangeMustContainTick.selector);
        hook.rebalanceShadow(shadowId, 300, 900);
    }

    function test_rebalance_movesDust_chargesCost_andFoldsFeesIn() public {
        uint256 shadowId = _open();
        _randomSwaps(0, 40);
        for (uint256 i; i < 4; ++i) {
            _swapBoth(false, 15e18);
        }

        IProvingGround.Score memory before_ = hook.scoreAtSpot(shadowId);
        assertGt(before_.feesConservative, 0);

        (, int24 tick,,) = poolManager.getSlot0(idA);
        int24 mid = (tick / TS) * TS;
        hook.rebalanceShadow(shadowId, mid - 300, mid + 300);

        assertEq(_dustLiquidity(shadowId, -300, 300), 0, "dust left the old range");
        assertEq(_dustLiquidity(shadowId, mid - 300, mid + 300), hook.DUST(), "dust sits on the new range");
        _assertReserveMatchesBalance();

        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        assertEq(s.tickLower, mid - 300);
        assertEq(s.tickUpper, mid + 300);
        assertEq(s.rebalances, 1);
        assertEq(s.lastRebalanceAt, vm.getBlockTimestamp());
        assertEq(s.openLiquidity, poolManager.getLiquidity(idA) - hook.DUST(), "leg restarts from the pool's liquidity");

        IProvingGround.Score memory after_ = hook.scoreAtSpot(shadowId);
        assertGt(after_.rebalanceCost, 0);
        assertEq(after_.feesConservative, 0, "fees were folded into the position");
        // Value drops by exactly the modelled cost, up to rounding in the liquidity conversion.
        assertApproxEqRel(after_.navConservative, before_.navConservative - after_.rebalanceCost, 1e9);
        // The benchmark is fixed at open and does not notice the rebalance.
        assertEq(after_.navBenchmark, before_.navBenchmark);
        assertEq(after_.navHold, before_.navHold);
        // The raw figure keeps the haircut it was spared on the finished leg.
        assertEq(after_.navRaw - after_.navConservative, before_.navRaw - before_.navConservative);
    }

    function test_rebalance_intoTheSameMixCostsAlmostNothing() public {
        uint256 shadowId = _open();
        hook.rebalanceShadow(shadowId, -300, 300);
        IProvingGround.Score memory sc = hook.scoreAtSpot(shadowId);
        assertLe(sc.rebalanceCost, 1e6, "no swap needed, so no cost beyond rounding");
    }

    function test_rebalance_aboveTheSizeCap_keepsTheRestIdle() public {
        uint256 shadowId = _open(); // exactly at the cap on a 600-tick range
        IProvingGround.Score memory before_ = hook.scoreAtSpot(shadowId);
        uint256 cap = uint256(poolManager.getLiquidity(idA)) * 100 / 10_000;

        // The same value on a much narrower range would be far more liquidity than the cap allows.
        hook.rebalanceShadow(shadowId, -60, 60);

        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        assertEq(s.liquidity, cap, "position sits at the cap");
        assertGt(s.idle, 0, "the remainder is idle");

        IProvingGround.Score memory after_ = hook.scoreAtSpot(shadowId);
        assertApproxEqRel(after_.navConservative, before_.navConservative - after_.rebalanceCost, 1e9);
        // Most of the value is idle now: the narrow range holds about a fifth of what the wide one did.
        assertGt(s.idle, after_.navConservative / 2);

        // Going back to the wide range puts the idle value to work again.
        hook.rebalanceShadow(shadowId, -300, 300);
        s = hook.getShadow(shadowId);
        assertLe(s.idle, 1e6, "nothing idle beyond rounding");
        assertEq(s.rebalances, 2);
    }

    // ------------------------------------------------------------------ closing a shadow

    function test_close_onlyCurator() public {
        uint256 shadowId = _open();
        vm.prank(stranger);
        vm.expectRevert(IProvingGround.NotCurator.selector);
        hook.closeShadow(shadowId);
    }

    function test_close_needsTheOracle() public {
        uint256 shadowId = _open();
        vm.expectRevert(Oracle.OracleNotReady.selector);
        hook.closeShadow(shadowId);
    }

    function test_close_freezesTheScore_andReturnsTheDust() public {
        uint256 reserve0 = hook.dustReserve(c0);
        uint256 reserve1 = hook.dustReserve(c1);
        uint256 shadowId = _open();
        _pingPong(0, 200); // 200 blocks: longer than the oracle window

        IProvingGround.Score memory live = hook.score(shadowId);
        hook.closeShadow(shadowId);

        assertEq(_dustLiquidity(shadowId, -300, 300), 0);
        _assertReserveMatchesBalance();
        // Rounding on the way in and out costs the reserve a few wei at most; dust fees can add a little.
        assertApproxEqAbs(hook.dustReserve(c0), reserve0, 20);
        assertApproxEqAbs(hook.dustReserve(c1), reserve1, 20);

        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        assertEq(s.closedAt, vm.getBlockTimestamp());

        IProvingGround.Score memory frozen = hook.score(shadowId);
        assertEq(frozen.navConservative, live.navConservative);
        assertEq(frozen.alphaBps, live.alphaBps);

        _pingPong(200, 260);
        IProvingGround.Score memory later = hook.score(shadowId);
        assertEq(later.navConservative, frozen.navConservative, "a closed score no longer moves");
        assertEq(later.navBenchmark, frozen.navBenchmark);
    }

    function test_closed_shadowRejectsFurtherUse() public {
        uint256 shadowId = _open();
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        hook.closeShadow(shadowId);

        vm.expectRevert(IProvingGround.ShadowIsClosed.selector);
        hook.closeShadow(shadowId);
        vm.expectRevert(IProvingGround.ShadowIsClosed.selector);
        hook.rebalanceShadow(shadowId, -600, 600);
        vm.expectRevert(IProvingGround.ShadowIsClosed.selector);
        hook.scoreAtSpot(shadowId);
        vm.expectRevert(IProvingGround.ShadowIsClosed.selector);
        hook.shadowFees(shadowId);
    }

    function test_score_unknownShadowReverts() public {
        vm.expectRevert(IProvingGround.UnknownShadow.selector);
        hook.score(1);
    }

    function test_score_isValuedAtTheTimeWeightedPrice() public {
        uint256 shadowId = _open();
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        _swap(keyA, false, 60 * unit1); // spot jumps, the average does not

        IProvingGround.Score memory twapScore = hook.score(shadowId);
        IProvingGround.Score memory spotScore = hook.scoreAtSpot(shadowId);
        assertEq(twapScore.sqrtPriceX96, TickMath.getSqrtPriceAtTick(0));
        assertGt(spotScore.sqrtPriceX96, twapScore.sqrtPriceX96);
        // At the unmoved average price the position is still worth what it started at, plus fees.
        assertEq(twapScore.navConservative, twapScore.navHold + twapScore.feesConservative);
    }

    // ------------------------------------------------------------------ gas

    /// @dev Gas of one swap as its own transaction. A swap the other way goes first so every
    /// measurement starts from the same kind of state.
    function _gasOfSwap(PoolKey memory k, bool newBlock) internal returns (uint256) {
        _swap(k, true, unit0);
        if (newBlock) vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        _swap(k, false, unit1);
        return vm.lastCallGas().gasTotalUsed;
    }

    /// @dev Shadows are scored lazily, so a swap costs the same however many are open.
    /// Runs in isolation mode: every call is its own transaction, so storage is priced as on-chain.
    /// forge-config: default.isolate = true
    function test_gas_swapCostDoesNotDependOnShadows() public {
        // Swap both ways on both pools first, so no measurement pays for a storage slot's first use.
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        _swap(keyA, true, unit0); // also writes this block's oracle observation
        _swap(keyA, false, unit1);
        _swap(keyB, true, unit0);
        _swap(keyB, false, unit1);

        uint256 plain = _gasOfSwap(keyB, false);
        uint256 none = _gasOfSwap(keyA, false);
        for (uint256 i; i < 5; ++i) {
            hook.openShadow(idA, -300 - int24(int256(i)) * 60, 300, 1e18);
        }
        uint256 five = _gasOfSwap(keyA, false);
        uint256 firstOfBlock = _gasOfSwap(keyA, true);

        // Fill the oracle ring, so a write replaces an old observation instead of using a new slot.
        for (uint256 i; i < ORACLE_CAPACITY; ++i) {
            vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
            if (i % 2 == 0) _swap(keyA, true, unit0);
            else _swap(keyA, false, unit1);
        }
        (, uint16 count,) = hook.oracleState(idA);
        assertEq(count, ORACLE_CAPACITY);
        uint256 firstOfBlockRingFull = _gasOfSwap(keyA, true);

        console2.log("swap gas, pool without the hook:", plain);
        console2.log("swap gas, hook, no shadows:", none);
        console2.log("swap gas, hook, five shadows open:", five);
        console2.log("swap gas, hook, first swap of a block, new oracle slot:", firstOfBlock);
        console2.log("swap gas, hook, first swap of a block, oracle ring full:", firstOfBlockRingFull);

        assertEq(five, none, "open shadows add nothing to a swap");
    }
}
