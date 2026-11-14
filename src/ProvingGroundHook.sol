// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IProvingGround} from "./interfaces/IProvingGround.sol";
import {Oracle} from "./libraries/Oracle.sol";
import {ScoreMath} from "./libraries/ScoreMath.sol";

/// @title ProvingGroundHook
/// @notice A liquidity curator runs a strategy as a capital-free "shadow" position. The hook scores
/// what that position would have earned from the pool's real swap flow and keeps the record on-chain.
/// @dev How a shadow is scored without touching swaps:
///  - The hook holds a dust-sized real position on the shadow's range. A v4 tick only tracks fee
///    growth while some liquidity references it, so the dust makes the pool account for the range.
///  - Fees are `virtual liquidity x fee growth inside the range`, read lazily when the score is asked for.
///  - The only work done during a swap is one oracle observation per block.
contract ProvingGroundHook is BaseHook, IUnlockCallback, IProvingGround {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using Oracle for Oracle.State;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Real liquidity the hook places on a shadow's range so the pool tracks its fee growth.
    uint128 public constant DUST = 1000;

    uint32 public immutable TWAP_WINDOW;
    uint16 public immutable ORACLE_CAPACITY;
    uint16 public immutable SHADOW_MAX_POOL_SHARE_BPS;
    uint24 public immutable DEFAULT_DYNAMIC_FEE;

    /// @notice Number of shadows ever opened. Shadow ids run from 1.
    uint256 public shadowCount;

    /// @notice Tokens set aside to fund dust positions, per currency. Anyone can add to it.
    mapping(Currency => uint256) public dustReserve;

    mapping(PoolId => PoolKey) internal _poolKeys;
    mapping(PoolId => Oracle.State) internal _oracles;
    mapping(uint256 => Shadow) internal _shadows;
    mapping(uint256 => Score) internal _finalScores;

    constructor(IPoolManager manager, Config memory config) BaseHook(manager) {
        if (
            config.twapWindow == 0 || config.oracleCapacity < 2 || config.shadowMaxPoolShareBps == 0
                || config.shadowMaxPoolShareBps > ScoreMath.BPS || config.defaultDynamicFee > LPFeeLibrary.MAX_LP_FEE
        ) revert InvalidConfig();
        TWAP_WINDOW = config.twapWindow;
        ORACLE_CAPACITY = config.oracleCapacity;
        SHADOW_MAX_POOL_SHARE_BPS = config.shadowMaxPoolShareBps;
        DEFAULT_DYNAMIC_FEE = config.defaultDynamicFee;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.afterInitialize = true;
        permissions.beforeSwap = true;
    }

    // ------------------------------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------------------------------

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        if (key.currency0.isAddressZero()) revert NativeCurrencyNotSupported();
        PoolId poolId = key.toId();
        _poolKeys[poolId] = key;
        _oracles[poolId].start(uint48(block.timestamp));
        if (LPFeeLibrary.isDynamicFee(key.fee)) poolManager.updateDynamicLPFee(key, DEFAULT_DYNAMIC_FEE);
        emit PoolRegistered(poolId, key.tickSpacing, key.fee);
        return this.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Oracle.State storage oracle = _oracles[poolId];
        // One observation per timestamp, taken before the first swap so it records the tick that
        // held since the previous observation.
        if (oracle.lastTime != uint48(block.timestamp)) {
            (, int24 tick,,) = poolManager.getSlot0(poolId);
            oracle.write(uint48(block.timestamp), tick, ORACLE_CAPACITY);
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ------------------------------------------------------------------------------------------
    // Shadows
    // ------------------------------------------------------------------------------------------

    /// @notice Adds tokens to the reserve that funds dust positions.
    function fundDust(Currency currency, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        dustReserve[currency] += amount;
        emit DustFunded(currency, msg.sender, amount);
    }

    /// @notice Opens a shadow position. No capital is taken from the caller.
    /// @param virtualLiquidity Liquidity of the virtual position, in the pool's liquidity units.
    function openShadow(PoolId poolId, int24 tickLower, int24 tickUpper, uint128 virtualLiquidity)
        external
        returns (uint256 shadowId)
    {
        PoolKey memory key = _requireKey(poolId);
        if (virtualLiquidity == 0) revert ZeroLiquidity();

        (uint160 sqrtPriceX96, int24 tick,,) = poolManager.getSlot0(poolId);
        _requireInRange(tick, tickLower, tickUpper);
        uint128 active = poolManager.getLiquidity(poolId);
        _requireSize(virtualLiquidity, active);

        shadowId = ++shadowCount;
        Shadow storage s = _shadows[shadowId];
        s.poolId = poolId;
        s.curator = msg.sender;
        s.openedAt = uint48(block.timestamp);
        s.liquidity = virtualLiquidity;
        s.openLiquidity = active;

        (uint256 amount0, uint256 amount1) = ScoreMath.amountsFor(sqrtPriceX96, tickLower, tickUpper, virtualLiquidity);
        s.hold0 = amount0.toUint128();
        s.hold1 = amount1.toUint128();

        // Benchmark: full-range liquidity worth the same as the shadow at the opening price.
        (, uint256 unitValue) = ScoreMath.perUnit(
            sqrtPriceX96, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing)
        );
        s.benchLiquidity =
            FullMath.mulDiv(ScoreMath.valueOf(amount0, amount1, sqrtPriceX96), ScoreMath.UNIT, unitValue).toUint128();
        (s.feeGrowthGlobal0Open, s.feeGrowthGlobal1Open) = poolManager.getFeeGrowthGlobals(poolId);

        _moveDust(s, shadowId, false, tickLower, tickUpper);
        emit ShadowOpened(shadowId, poolId, msg.sender, tickLower, tickUpper, virtualLiquidity, s.benchLiquidity);
    }

    /// @notice Moves a shadow to a new range, charging the modelled cost of the swap that would need.
    /// @dev If the new range would hold more liquidity than the size cap allows, the position is
    /// placed at the cap and the remainder is kept as idle token1, which earns nothing.
    function rebalanceShadow(uint256 shadowId, int24 tickLower, int24 tickUpper) external {
        Shadow storage s = _openShadow(shadowId);
        if (msg.sender != s.curator) revert NotCurator();
        _rebalanceShadow(s, shadowId, tickLower, tickUpper);
    }

    /// @notice Closes a shadow and freezes its score at the time-weighted price.
    function closeShadow(uint256 shadowId) external {
        Shadow storage s = _openShadow(shadowId);
        if (msg.sender != s.curator) revert NotCurator();

        Score memory final_ = _score(s, _twapSqrtPrice(s.poolId));
        _finalScores[shadowId] = final_;
        s.closedAt = uint48(block.timestamp);
        _moveDust(s, shadowId, true, 0, 0);
        emit ShadowClosed(shadowId, final_.alphaBps, final_.alphaVsHoldBps, final_.navConservative);
    }

    function _rebalanceShadow(Shadow storage s, uint256 shadowId, int24 tickLower, int24 tickUpper) internal {
        PoolId poolId = s.poolId;
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(poolId);
        _requireInRange(tick, tickLower, tickUpper);
        uint128 active = poolManager.getLiquidity(poolId);
        if (active == 0) revert NoActiveLiquidity();

        // What the shadow holds now: the position, its conservative fees, and any idle token1.
        (uint256 held0, uint256 held1, uint256 bonus) = _holdings(s, sqrtPriceX96);
        (uint256 liquidity, uint256 idle, uint256 cost) = ScoreMath.planRebalance(
            ScoreMath.RebalanceInput({
                held0: held0,
                held1: held1,
                sqrtPriceX96: sqrtPriceX96,
                tickLower: tickLower,
                tickUpper: tickUpper,
                maxLiquidity: uint128(uint256(active) * SHADOW_MAX_POOL_SHARE_BPS / ScoreMath.BPS),
                lpFee: lpFee,
                activeLiquidity: active
            })
        );
        if (liquidity == 0) revert NothingToRebalance();

        s.idle = idle.toUint128();
        s.rawBonus += bonus.toUint128();
        s.costPaid += cost.toUint128();
        s.liquidity = liquidity.toUint128();
        s.openLiquidity = active;
        s.lastRebalanceAt = uint48(block.timestamp);
        s.rebalances += 1;

        _moveDust(s, shadowId, true, tickLower, tickUpper);
        emit ShadowRebalanced(shadowId, tickLower, tickUpper, s.liquidity, cost);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function getShadow(uint256 shadowId) external view returns (Shadow memory) {
        return _shadows[shadowId];
    }

    function getPoolKey(PoolId poolId) external view returns (PoolKey memory) {
        return _poolKeys[poolId];
    }

    /// @notice (ring index, observations stored, time of the newest observation) for a pool's oracle.
    function oracleState(PoolId poolId) external view returns (uint16 index, uint16 count, uint48 lastTime) {
        Oracle.State storage o = _oracles[poolId];
        return (o.index, o.count, o.lastTime);
    }

    /// @notice Average tick over `TWAP_WINDOW`. Reverts with `OracleNotReady` on a pool that is too young.
    function twapTick(PoolId poolId) public view returns (int24) {
        _requireKey(poolId);
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        return _oracles[poolId].twapTick(uint48(block.timestamp), TWAP_WINDOW, tick, ORACLE_CAPACITY);
    }

    /// @notice A shadow's score at the time-weighted price. For a closed shadow, the score frozen at close.
    function score(uint256 shadowId) external view returns (Score memory) {
        Shadow storage s = _shadows[shadowId];
        if (s.curator == address(0)) revert UnknownShadow();
        if (s.closedAt != 0) return _finalScores[shadowId];
        return _score(s, _twapSqrtPrice(s.poolId));
    }

    /// @notice A shadow's score at the pool's current price.
    /// @dev The current price can be moved within a transaction. Use `score` for anything that
    /// decides money; this view exists for display and for checking the score against a real position.
    function scoreAtSpot(uint256 shadowId) external view returns (Score memory) {
        Shadow storage s = _openShadow(shadowId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(s.poolId);
        return _score(s, sqrtPriceX96);
    }

    /// @notice Fees of the current leg, in token amounts: before and after the dilution haircut.
    function shadowFees(uint256 shadowId)
        external
        view
        returns (uint256 raw0, uint256 raw1, uint256 conservative0, uint256 conservative1)
    {
        return _legFees(_openShadow(shadowId));
    }

    // ------------------------------------------------------------------------------------------
    // Scoring internals
    // ------------------------------------------------------------------------------------------

    function _legFees(Shadow storage s)
        internal
        view
        returns (uint256 raw0, uint256 raw1, uint256 conservative0, uint256 conservative1)
    {
        (uint256 growth0, uint256 growth1) = poolManager.getFeeGrowthInside(s.poolId, s.tickLower, s.tickUpper);
        uint128 liquidity = s.liquidity;
        uint128 openLiquidity = s.openLiquidity;
        raw0 = ScoreMath.feesFor(growth0, s.feeGrowthInside0Last, liquidity);
        raw1 = ScoreMath.feesFor(growth1, s.feeGrowthInside1Last, liquidity);
        conservative0 = ScoreMath.haircut(raw0, openLiquidity, liquidity);
        conservative1 = ScoreMath.haircut(raw1, openLiquidity, liquidity);
    }

    /// @dev Token amounts the shadow holds at `sqrtPriceX96` (position, conservative fees, idle
    /// token1), and the token1 value of the fees the haircut removed.
    function _holdings(Shadow storage s, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 held0, uint256 held1, uint256 haircutValue)
    {
        (uint256 raw0, uint256 raw1, uint256 fees0, uint256 fees1) = _legFees(s);
        (held0, held1) = ScoreMath.amountsFor(sqrtPriceX96, s.tickLower, s.tickUpper, s.liquidity);
        held0 += fees0;
        held1 += fees1 + s.idle;
        haircutValue = ScoreMath.valueOf(raw0 - fees0, raw1 - fees1, sqrtPriceX96);
    }

    function _score(Shadow storage s, uint160 sqrtPriceX96) internal view returns (Score memory sc) {
        sc.sqrtPriceX96 = sqrtPriceX96;
        sc.rebalanceCost = s.costPaid;

        (uint256 raw0, uint256 raw1, uint256 fees0, uint256 fees1) = _legFees(s);
        (uint256 held0, uint256 held1) = ScoreMath.amountsFor(sqrtPriceX96, s.tickLower, s.tickUpper, s.liquidity);
        sc.feesConservative = ScoreMath.valueOf(fees0, fees1, sqrtPriceX96);
        sc.feesRaw = ScoreMath.valueOf(raw0, raw1, sqrtPriceX96);
        sc.navConservative = ScoreMath.valueOf(held0 + fees0, held1 + fees1 + s.idle, sqrtPriceX96);
        sc.navRaw = sc.navConservative + s.rawBonus + ScoreMath.valueOf(raw0 - fees0, raw1 - fees1, sqrtPriceX96);

        // Benchmark: the full-range position fixed at open, with its fees left uncompounded and unhaircut.
        int24 spacing = _poolKeys[s.poolId].tickSpacing;
        uint128 benchLiquidity = s.benchLiquidity;
        (uint256 bench0, uint256 bench1) = ScoreMath.amountsFor(
            sqrtPriceX96, TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing), benchLiquidity
        );
        (uint256 global0, uint256 global1) = poolManager.getFeeGrowthGlobals(s.poolId);
        sc.feesBenchmark = ScoreMath.valueOf(
            ScoreMath.feesFor(global0, s.feeGrowthGlobal0Open, benchLiquidity),
            ScoreMath.feesFor(global1, s.feeGrowthGlobal1Open, benchLiquidity),
            sqrtPriceX96
        );
        sc.navBenchmark = ScoreMath.valueOf(bench0, bench1, sqrtPriceX96) + sc.feesBenchmark;
        sc.navHold = ScoreMath.valueOf(s.hold0, s.hold1, sqrtPriceX96);

        sc.alphaBps = ScoreMath.alphaBps(sc.navConservative, sc.navBenchmark);
        sc.alphaVsHoldBps = ScoreMath.alphaBps(sc.navConservative, sc.navHold);
    }

    function _twapSqrtPrice(PoolId poolId) internal view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(twapTick(poolId));
    }

    function _openShadow(uint256 shadowId) internal view returns (Shadow storage s) {
        s = _shadows[shadowId];
        if (s.curator == address(0)) revert UnknownShadow();
        if (s.closedAt != 0) revert ShadowIsClosed();
    }

    function _requireKey(PoolId poolId) internal view returns (PoolKey memory key) {
        key = _poolKeys[poolId];
        if (key.tickSpacing == 0) revert PoolNotRegistered();
    }

    function _requireInRange(int24 tick, int24 tickLower, int24 tickUpper) internal pure {
        if (tick < tickLower || tick >= tickUpper) revert RangeMustContainTick();
    }

    function _requireSize(uint128 liquidity, uint128 active) internal view {
        if (uint256(liquidity) * ScoreMath.BPS > uint256(active) * SHADOW_MAX_POOL_SHARE_BPS) revert ShadowTooLarge();
    }

    // ------------------------------------------------------------------------------------------
    // Dust positions
    // ------------------------------------------------------------------------------------------

    /// @dev Removes the dust from the shadow's current range (if `remove`) and places it on
    /// [tickLower, tickUpper) (unless both are zero), then snapshots fee growth on the new range.
    function _moveDust(Shadow storage s, uint256 shadowId, bool remove, int24 tickLower, int24 tickUpper) internal {
        bool add = tickLower != tickUpper;
        poolManager.unlock(abi.encode(s.poolId, shadowId, remove, s.tickLower, s.tickUpper, add, tickLower, tickUpper));
        if (add) {
            s.tickLower = tickLower;
            s.tickUpper = tickUpper;
            (s.feeGrowthInside0Last, s.feeGrowthInside1Last) =
                poolManager.getFeeGrowthInside(s.poolId, tickLower, tickUpper);
        }
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (
            PoolId poolId,
            uint256 shadowId,
            bool remove,
            int24 oldLower,
            int24 oldUpper,
            bool add,
            int24 newLower,
            int24 newUpper
        ) = abi.decode(data, (PoolId, uint256, bool, int24, int24, bool, int24, int24));
        PoolKey memory key = _poolKeys[poolId];

        int256 net0;
        int256 net1;
        if (remove) {
            BalanceDelta d = _modifyDust(key, oldLower, oldUpper, -int256(uint256(DUST)), shadowId);
            net0 += d.amount0();
            net1 += d.amount1();
        }
        if (add) {
            BalanceDelta d = _modifyDust(key, newLower, newUpper, int256(uint256(DUST)), shadowId);
            net0 += d.amount0();
            net1 += d.amount1();
        }
        _squareDust(key.currency0, net0);
        _squareDust(key.currency1, net1);
        return "";
    }

    function _modifyDust(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 delta, uint256 shadowId)
        internal
        returns (BalanceDelta callerDelta)
    {
        (callerDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: delta, salt: bytes32(shadowId)
            }),
            ""
        );
    }

    /// @dev Pays or collects the net dust amount for one currency, against the dust reserve only.
    function _squareDust(Currency currency, int256 net) internal {
        if (net < 0) {
            uint256 owed = uint256(-net);
            if (dustReserve[currency] < owed) revert DustReserveLow(currency);
            dustReserve[currency] -= owed;
            poolManager.sync(currency);
            currency.transfer(address(poolManager), owed);
            poolManager.settle();
        } else if (net > 0) {
            poolManager.take(currency, address(this), uint256(net));
            dustReserve[currency] += uint256(net);
        }
    }
}
