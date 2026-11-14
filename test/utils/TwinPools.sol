// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseTest} from "./BaseTest.sol";
import {EasyPosm} from "./libraries/EasyPosm.sol";

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

import {ProvingGroundHook} from "../../src/ProvingGroundHook.sol";
import {IProvingGround} from "../../src/interfaces/IProvingGround.sol";

/// @notice Two pools that receive exactly the same swaps.
/// Pool A carries the hook, so positions on it can be shadows (no capital).
/// Pool B is identical but has no hook, and holds the same positions with real tokens.
/// Pool B is the ground truth every shadow figure is judged against.
///
/// Everything is expressed relative to a centre tick and a liquidity scale, so the same flow can run
/// on tokens with different decimals and at prices far from 1.
abstract contract TwinPools is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    int24 internal constant TS = 60;
    uint24 internal constant FEE = 3000;
    uint32 internal constant TWAP_WINDOW = 1800;
    uint16 internal constant ORACLE_CAPACITY = 720;
    uint256 internal constant BLOCK_TIME = 12;

    ProvingGroundHook internal hook;
    Currency internal c0;
    Currency internal c1;
    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolId internal idA;
    PoolId internal idB;

    int24 internal center; // tick both pools start at
    uint128 internal scale; // one "unit" of liquidity
    uint256 internal unit0; // token0 amount matching one unit of liquidity at the centre price
    uint256 internal unit1; // token1 amount matching one unit of liquidity at the centre price

    /// @param maxShareBps Shadow size cap the hook is deployed with.
    function _setUpTwin(uint8 decimals0, uint8 decimals1, int24 centerTick, uint128 liquidityScale, uint16 maxShareBps)
        internal
    {
        deployArtifactsAndLabel();
        (c0, c1) = _deployPair(decimals0, decimals1);

        hook = _deployHook(0x4444, maxShareBps);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);

        center = centerTick;
        scale = liquidityScale;
        uint160 sqrtCenter = TickMath.getSqrtPriceAtTick(centerTick);
        unit0 = FullMath.mulDiv(liquidityScale, FixedPoint96.Q96, sqrtCenter);
        unit1 = FullMath.mulDiv(liquidityScale, sqrtCenter, FixedPoint96.Q96);

        keyA = PoolKey(c0, c1, FEE, TS, IHooks(address(hook)));
        keyB = PoolKey(c0, c1, FEE, TS, IHooks(address(0)));
        idA = keyA.toId();
        idB = keyB.toId();
        poolManager.initialize(keyA, sqrtCenter);
        poolManager.initialize(keyB, sqrtCenter);

        hook.fundDust(c0, unit0);
        hook.fundDust(c1, unit1);

        _baseLiquidity(keyA);
        _baseLiquidity(keyB);
    }

    function _deployHook(uint160 prefix, uint16 maxShareBps) internal returns (ProvingGroundHook h) {
        address at = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (prefix << 144));
        IProvingGround.Config memory config = IProvingGround.Config({
            twapWindow: TWAP_WINDOW,
            oracleCapacity: ORACLE_CAPACITY,
            shadowMaxPoolShareBps: maxShareBps,
            defaultDynamicFee: FEE
        });
        deployCodeTo("ProvingGroundHook.sol:ProvingGroundHook", abi.encode(poolManager, config), at);
        h = ProvingGroundHook(at);
    }

    /// @dev Deploys two tokens so that currency0 has `decimals0` and currency1 has `decimals1`.
    function _deployPair(uint8 decimals0, uint8 decimals1) internal returns (Currency currency0, Currency currency1) {
        MockERC20 a = _deployToken(decimals0);
        MockERC20 b = _deployToken(decimals1);
        while (address(b) < address(a)) b = _deployToken(decimals1);
        currency0 = Currency.wrap(address(a));
        currency1 = Currency.wrap(address(b));
    }

    function _deployToken(uint8 decimals_) internal returns (MockERC20 token) {
        token = new MockERC20("Test Token", "TEST", decimals_);
        token.mint(address(this), 1e30);
        token.approve(address(permit2), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(address(token), address(poolManager), type(uint160).max, type(uint48).max);
    }

    /// @dev Three overlapping LPs, so swaps cross initialized ticks inside the shadow's range.
    function _baseLiquidity(PoolKey memory k) internal {
        _mint(k, center - 12000, center + 12000, 2000 * scale);
        _mint(k, center - 600, center + 600, 1500 * scale);
        _mint(k, center - 120, center + 180, 1000 * scale);
    }

    function _mint(PoolKey memory k, int24 lo, int24 hi, uint128 liq) internal returns (uint256 tid, BalanceDelta d) {
        (tid, d) = positionManager.mint(
            k, lo, hi, liq, type(uint128).max, type(uint128).max, address(this), vm.getBlockTimestamp() + 1, ""
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, uint256 amountIn) internal {
        swapRouter.swapExactTokensForTokens(amountIn, 0, zeroForOne, k, "", address(this), vm.getBlockTimestamp() + 1);
    }

    /// @dev One block passes, then both pools take the same swap. `units` is 1e18-scaled.
    function _swapBoth(bool zeroForOne, uint256 units) internal {
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        uint256 amountIn = FullMath.mulDiv(units, zeroForOne ? unit0 : unit1, 1e18);
        _swap(keyA, zeroForOne, amountIn);
        _swap(keyB, zeroForOne, amountIn);
    }

    /// @dev Pseudo-random flow. The price drifts through the shadow's range.
    function _randomSwaps(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            uint256 h = uint256(keccak256(abi.encode(i)));
            _swapBoth(h & 1 == 1, 0.5e18 + (h >> 8) % 20e18);
        }
    }

    /// @dev Flow that keeps the price inside the shadow's range: the worst case for fee dilution.
    function _pingPong(uint256 from, uint256 to) internal {
        for (uint256 i = from; i < to; ++i) {
            uint256 h = uint256(keccak256(abi.encode(i)));
            (, int24 tick,,) = poolManager.getSlot0(idA);
            bool zeroForOne = tick > center + 150 ? true : tick < center - 150 ? false : h & 1 == 1;
            _swapBoth(zeroForOne, 0.5e18 + (h >> 8) % 8e18);
        }
    }

    function _in1(uint256 amount0, uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(amount0, sqrtP, FixedPoint96.Q96), sqrtP, FixedPoint96.Q96);
    }

    /// @dev Error of `measured` against `truth`, in parts per million of `truth`.
    function _ppm(uint256 measured, uint256 truth) internal pure returns (int256) {
        return (int256(measured) - int256(truth)) * 1e6 / int256(truth);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _activeShare(uint256 bps) internal view returns (uint128) {
        return uint128(uint256(poolManager.getLiquidity(idB)) * bps / 10_000);
    }
}
