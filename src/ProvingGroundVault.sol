// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ERC6909} from "@uniswap/v4-core/src/ERC6909.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ProvingGroundHook} from "./ProvingGroundHook.sol";
import {IProvingGround} from "./interfaces/IProvingGround.sol";
import {IProvingGroundVault} from "./interfaces/IProvingGroundVault.sol";
import {ScoreMath} from "./libraries/ScoreMath.sol";

/// @title ProvingGroundVault
/// @notice Holds the real liquidity of curators who have graduated from a shadow on the Proving
/// Ground hook. One vault per graduated shadow; the vault id is the shadow id.
/// @dev What keeps depositors safe:
///  - Deposits and withdrawals are in kind and proportional. A depositor adds the same fraction to
///    the position and to the idle balances and gets that fraction of shares; a withdrawer takes the
///    same fraction out. Nothing is swapped and nothing is priced, so neither can be done at an unfair
///    price, and a withdrawal needs neither the curator, the oracle nor the hook.
///  - The position moves only through `rebalance`, and only after the hook has accepted the
///    curator's signed instruction and passed it through the same mandate checks a shadow gets. The
///    vault then refuses any execution that loses more than `MAX_REBALANCE_LOSS_BPS` of value.
///  - Outside money is capped at a multiple of the curator's own stake. The multiple is earned by
///    score: the shadow's at first, the vault's own once it has run for `MIN_SHADOW_AGE`.
///  - The curator is paid a share of what the vault gains on a passive full-range position, and only
///    above a high-water mark, so never for matching the market and never twice for the same ground.
/// Shares are ERC-6909 tokens, one id per vault. The curator's stake is tracked separately and cannot
/// be transferred. Fee-on-transfer and rebasing tokens are not supported.
contract ProvingGroundVault is IProvingGroundVault, IUnlockCallback, ERC6909, ReentrancyGuard {
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    ProvingGroundHook public immutable HOOK;
    IPoolManager public immutable poolManager;

    // Copied from the hook, so both contracts work to the same limits.
    uint256 public immutable MIN_SHADOW_AGE;
    uint24 public immutable MAX_DEVIATION_TICKS;

    int256 public immutable GRADUATION_ALPHA_BPS;
    int256 public immutable DEMOTION_ALPHA_BPS;
    uint256 public immutable BASE_MULTIPLE;
    uint256 public immutable MAX_MULTIPLE;
    uint256 public immutable ALPHA_STEP_BPS;
    uint256 public immutable LIVE_MAX_POOL_SHARE_BPS;
    uint256 public immutable MAX_REBALANCE_LOSS_BPS;
    uint256 public immutable PERF_FEE_BPS;

    /// @dev Fixed-point one, for the value ratio and the high-water mark.
    uint256 internal constant ONE = 1e18;

    mapping(uint256 => Vault) internal _vaults;
    mapping(PoolId => PoolKey) internal _poolKeys;

    enum Action {
        Enter,
        Exit,
        Rebalance
    }

    /// @dev What an external function asks the unlock callback to do.
    struct Call {
        Action action;
        uint256 vaultId;
        address account; // who pays in, or who is paid out
        uint256 shares;
        uint256 limit0; // most to pay in, or least to receive
        uint256 limit1;
        int24 tickLower; // rebalance only: the new range
        int24 tickUpper;
        int24 twap; // rebalance only: the time-weighted tick the hook returned
    }

    constructor(ProvingGroundHook hook, VaultConfig memory config) {
        if (
            hook.VAULT() != address(this) || config.baseMultiple == 0 || config.maxMultiple < config.baseMultiple
                || config.alphaStepBps == 0 || config.liveMaxPoolShareBps == 0
                || config.liveMaxPoolShareBps > ScoreMath.BPS || config.maxRebalanceLossBps > ScoreMath.BPS
                || config.perfFeeBps >= ScoreMath.BPS
        ) revert InvalidVaultConfig();
        HOOK = hook;
        poolManager = hook.poolManager();
        MIN_SHADOW_AGE = hook.MIN_SHADOW_AGE();
        MAX_DEVIATION_TICKS = hook.MAX_DEVIATION_TICKS();
        GRADUATION_ALPHA_BPS = config.graduationAlphaBps;
        DEMOTION_ALPHA_BPS = config.demotionAlphaBps;
        BASE_MULTIPLE = config.baseMultiple;
        MAX_MULTIPLE = config.maxMultiple;
        ALPHA_STEP_BPS = config.alphaStepBps;
        LIVE_MAX_POOL_SHARE_BPS = config.liveMaxPoolShareBps;
        MAX_REBALANCE_LOSS_BPS = config.maxRebalanceLossBps;
        PERF_FEE_BPS = config.perfFeeBps;
    }

    // ------------------------------------------------------------------------------------------
    // Going live
    // ------------------------------------------------------------------------------------------

    /// @notice Turns the caller's shadow into a live vault. The shadow must be at least
    /// `MIN_SHADOW_AGE` old and score at least `GRADUATION_ALPHA_BPS` against the passive benchmark.
    /// The vault starts on the shadow's current range, and the caller funds it: `liquidity` of real
    /// liquidity, which becomes the curator's stake.
    /// @param max0 Most token0 the caller is willing to pay in.
    /// @param max1 Most token1 the caller is willing to pay in.
    function goLive(uint256 shadowId, uint128 liquidity, uint256 max0, uint256 max1)
        external
        nonReentrant
        returns (uint256 vaultId)
    {
        IProvingGround.Shadow memory s = HOOK.getShadow(shadowId);
        if (msg.sender != s.curator) revert NotVaultCurator();
        if (liquidity == 0) revert ZeroShares();
        uint256 readyAt = uint256(s.openedAt) + MIN_SHADOW_AGE;
        if (block.timestamp < readyAt) revert ShadowTooYoung(readyAt);
        int256 alpha = HOOK.score(shadowId).alphaBps;
        if (alpha < GRADUATION_ALPHA_BPS) revert AlphaTooLow(alpha);

        // Closes the shadow as graduated and freezes the score just read. Reverts if it is closed.
        HOOK.graduate(shadowId);

        vaultId = shadowId;
        PoolId poolId = s.poolId;
        if (_poolKeys[poolId].tickSpacing == 0) _poolKeys[poolId] = HOOK.getPoolKey(poolId);

        Vault storage v = _vaults[vaultId];
        v.poolId = poolId;
        v.curator = msg.sender;
        v.tickLower = s.tickLower;
        v.tickUpper = s.tickUpper;
        v.openedAt = uint48(block.timestamp);
        v.shadowAlphaBps = alpha;
        v.highWaterMark = ONE;

        (uint256 paid0, uint256 paid1) =
            _unlock(Call(Action.Enter, vaultId, msg.sender, liquidity, max0, max1, 0, 0, 0));
        v.totalShares = liquidity;
        v.curatorShares = liquidity;
        _checkPoolShare(v);

        // Benchmark: full-range liquidity worth what the vault is worth now, at the time-weighted price.
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(HOOK.twapTick(poolId));
        int24 spacing = _poolKeys[poolId].tickSpacing;
        (, uint256 unitValue) =
            ScoreMath.perUnit(sqrtTwap, TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing));
        v.benchLiquidity = FullMath.mulDiv(_nav(v, vaultId, sqrtTwap), ScoreMath.UNIT, unitValue).toUint128();
        v.benchShares = liquidity;
        (v.feeGrowthGlobal0Open, v.feeGrowthGlobal1Open) = poolManager.getFeeGrowthGlobals(poolId);

        emit VaultOpened(vaultId, poolId, msg.sender, s.tickLower, s.tickUpper, liquidity, alpha);
        emit Entered(vaultId, msg.sender, true, liquidity, paid0, paid1);
    }

    // ------------------------------------------------------------------------------------------
    // Deposits and withdrawals
    // ------------------------------------------------------------------------------------------

    /// @notice Buys `shares` of a vault by adding the same fraction to its position and idle
    /// balances. Refused while the vault is demoted, above its capacity, or above the pool-share cap.
    /// @param max0 Most token0 the caller is willing to pay in.
    /// @param max1 Most token1 the caller is willing to pay in.
    function deposit(uint256 vaultId, uint256 shares, uint256 max0, uint256 max1)
        external
        nonReentrant
        returns (uint256 paid0, uint256 paid1)
    {
        Vault storage v = _openVault(vaultId);
        if (shares == 0) revert ZeroShares();
        Standing memory st = _standing(v, vaultId);
        // Any fee owed on gains so far is taken first, so the newcomer does not pay for gains they missed.
        if (_settleFee(v, vaultId, st) != 0) st = _standing(v, vaultId);
        if (st.demoted) revert Demoted(st.liveAlphaBps);
        if (v.totalShares + shares > st.maxTotalShares) revert OverCapacity(st.maxTotalShares);

        (paid0, paid1) = _unlock(Call(Action.Enter, vaultId, msg.sender, shares, max0, max1, 0, 0, 0));
        v.totalShares += shares;
        _mint(msg.sender, vaultId, shares);
        _checkPoolShare(v);
        emit Entered(vaultId, msg.sender, false, shares, paid0, paid1);
    }

    /// @notice Redeems `shares` for the same fraction of the position and idle balances. Always
    /// available: it does not depend on the vault's standing, the oracle or the curator.
    /// @param min0 Least token0 the caller will accept.
    /// @param min1 Least token1 the caller will accept.
    function withdraw(uint256 vaultId, uint256 shares, uint256 min0, uint256 min1)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        Vault storage v = _knownVault(vaultId);
        if (shares == 0) revert ZeroShares();
        _burn(msg.sender, vaultId, shares);
        (out0, out1) = _unlock(Call(Action.Exit, vaultId, msg.sender, shares, min0, min1, 0, 0, 0));
        v.totalShares -= shares;
        emit Exited(vaultId, msg.sender, false, shares, out0, out1);
    }

    /// @notice Adds to the curator's own stake, which raises the vault's capacity.
    function stake(uint256 vaultId, uint256 shares, uint256 max0, uint256 max1)
        external
        nonReentrant
        returns (uint256 paid0, uint256 paid1)
    {
        Vault storage v = _openVault(vaultId);
        if (msg.sender != v.curator) revert NotVaultCurator();
        if (shares == 0) revert ZeroShares();

        (paid0, paid1) = _unlock(Call(Action.Enter, vaultId, msg.sender, shares, max0, max1, 0, 0, 0));
        v.totalShares += shares;
        v.curatorShares += shares;
        _checkPoolShare(v);
        emit Entered(vaultId, msg.sender, true, shares, paid0, paid1);
    }

    /// @notice Takes out part of the curator's stake. What remains must still back the outside
    /// deposits at the vault's current multiple. Redeeming the last share closes the vault.
    function unstake(uint256 vaultId, uint256 shares, uint256 min0, uint256 min1)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        Vault storage v = _openVault(vaultId);
        if (msg.sender != v.curator) revert NotVaultCurator();
        if (shares == 0) revert ZeroShares();
        if (shares > v.curatorShares) revert StakeLocked();

        (out0, out1) = _unlock(Call(Action.Exit, vaultId, msg.sender, shares, min0, min1, 0, 0, 0));
        v.totalShares -= shares;
        v.curatorShares -= shares;
        if (v.totalShares == 0) {
            v.closedAt = uint48(block.timestamp);
            emit VaultClosed(vaultId);
        } else if (v.totalShares != v.curatorShares) {
            // Outside money is still in: the stake left must cover it.
            if (v.totalShares > _standing(v, vaultId).maxTotalShares) revert StakeLocked();
        }
        emit Exited(vaultId, msg.sender, true, shares, out0, out1);
    }

    // ------------------------------------------------------------------------------------------
    // Performance fee
    // ------------------------------------------------------------------------------------------

    /// @notice Pays the curator their fee, in new shares of the vault. Anyone may call it.
    /// @dev Let R be the vault's value per share over the benchmark's value per share, and H the
    /// high-water mark. If R is above H the curator is minted shares worth `PERF_FEE_BPS x (1 - H/R)`
    /// of the vault, and H moves to R as it stands after that dilution. Nothing is paid at or below H.
    /// Deposits settle the fee first. Withdrawals do not, so that they never depend on the oracle.
    function settleFee(uint256 vaultId) external nonReentrant returns (uint256 feeShares) {
        Vault storage v = _openVault(vaultId);
        return _settleFee(v, vaultId, _standing(v, vaultId));
    }

    function _settleFee(Vault storage v, uint256 vaultId, Standing memory st) internal returns (uint256 feeShares) {
        feeShares = st.feeSharesDue;
        if (feeShares == 0) return 0;
        (, uint256 mark) = _feeDue(v, st.valueRatio);
        v.totalShares += feeShares;
        v.highWaterMark = mark;
        _mint(v.curator, vaultId, feeShares);
        emit FeeSettled(vaultId, v.curator, feeShares, st.valueRatio, mark);
    }

    /// @dev The fee shares due at a value ratio, and the high-water mark after they are minted.
    function _feeDue(Vault storage v, uint256 valueRatio) internal view returns (uint256 feeShares, uint256 mark) {
        mark = v.highWaterMark;
        if (valueRatio <= mark) return (0, mark);
        // The fee as a fraction of the whole vault.
        uint256 fraction = FullMath.mulDiv(PERF_FEE_BPS * ONE / ScoreMath.BPS, valueRatio - mark, valueRatio);
        feeShares = FullMath.mulDiv(v.totalShares, fraction, ONE - fraction);
        // The mark moves to the ratio as it stands once the new shares exist.
        if (feeShares != 0) mark = FullMath.mulDivRoundingUp(valueRatio, v.totalShares, v.totalShares + feeShares);
    }

    // ------------------------------------------------------------------------------------------
    // Rebalancing
    // ------------------------------------------------------------------------------------------

    /// @notice Executes a curator's signed instruction to move a vault's liquidity to a new range.
    /// Anyone may submit it. The hook verifies the signature and applies the mandate (range width and
    /// tick grid, cooldown, pool price close to its time-weighted average). The vault then removes
    /// its liquidity, swaps through the pool toward the token mix the new range needs, and places what
    /// it can; anything left stays idle. The call reverts if the swap cost more than
    /// `MAX_REBALANCE_LOSS_BPS` of the vault's value at the time-weighted price.
    function rebalance(IProvingGround.RebalanceIntent calldata intent, bytes calldata signature) external nonReentrant {
        uint256 vaultId = intent.subjectId;
        Vault storage v = _openVault(vaultId);
        if (PoolId.unwrap(intent.poolId) != PoolId.unwrap(v.poolId)) revert IProvingGround.WrongPool();

        int24 twap =
            HOOK.authorizeLive(intent, signature, v.curator, v.rebalances == 0 ? v.openedAt : v.lastRebalanceAt);
        (uint256 valueBefore, uint256 valueAfter) =
            _unlock(Call(Action.Rebalance, vaultId, address(0), 0, 0, 0, intent.tickLower, intent.tickUpper, twap));
        v.lastRebalanceAt = uint48(block.timestamp);
        v.rebalances += 1;
        emit VaultRebalanced(vaultId, intent.tickLower, intent.tickUpper, v.liquidity, valueBefore, valueAfter);
    }

    // ------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------

    function getVault(uint256 vaultId) external view returns (Vault memory) {
        return _vaults[vaultId];
    }

    /// @notice Shares of a vault held by outside depositors (everything but the curator's stake).
    function outsideShares(uint256 vaultId) external view returns (uint256) {
        Vault storage v = _vaults[vaultId];
        return v.totalShares - v.curatorShares;
    }

    /// @notice The tokens a vault holds right now: its position at the pool's current price, the
    /// fees not yet collected, and its idle balances.
    function holdings(uint256 vaultId) external view returns (uint256 amount0, uint256 amount1) {
        Vault storage v = _knownVault(vaultId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(v.poolId);
        return _holdings(v, vaultId, sqrtPriceX96);
    }

    /// @notice A vault's score, capacity and whether it is demoted, at the time-weighted price.
    function standing(uint256 vaultId) external view returns (Standing memory) {
        return _standing(_knownVault(vaultId), vaultId);
    }

    /// @notice What buying `shares` would cost at the pool's current price, after any fee due is
    /// settled. Use it to set the `max0` and `max1` of a deposit; the price can move before the deposit lands.
    function quoteDeposit(uint256 vaultId, uint256 shares) external view returns (uint256 amount0, uint256 amount1) {
        Vault storage v = _openVault(vaultId);
        uint256 supply = v.totalShares + _standing(v, vaultId).feeSharesDue;
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(v.poolId);
        uint128 added = FullMath.mulDivRoundingUp(v.liquidity, shares, supply).toUint128();
        (amount0, amount1) = _amountsRoundingUp(sqrtPriceX96, v.tickLower, v.tickUpper, added);
        (uint256 fees0, uint256 fees1) = _pendingFees(v, vaultId);
        amount0 += FullMath.mulDivRoundingUp(v.idle0 + fees0, shares, supply);
        amount1 += FullMath.mulDivRoundingUp(v.idle1 + fees1, shares, supply);
    }

    // ------------------------------------------------------------------------------------------
    // Standing internals
    // ------------------------------------------------------------------------------------------

    function _standing(Vault storage v, uint256 vaultId) internal view returns (Standing memory st) {
        PoolId poolId = v.poolId;
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(HOOK.twapTick(poolId));
        st.nav = _nav(v, vaultId, sqrtTwap);

        // Benchmark: the full-range position fixed when the vault opened, fees left uncompounded,
        // scaled from the shares that existed then to the shares that exist now.
        if (v.benchShares != 0) {
            int24 spacing = _poolKeys[poolId].tickSpacing;
            uint128 benchLiquidity = v.benchLiquidity;
            (uint256 bench0, uint256 bench1) = ScoreMath.amountsFor(
                sqrtTwap, TickMath.minUsableTick(spacing), TickMath.maxUsableTick(spacing), benchLiquidity
            );
            (uint256 global0, uint256 global1) = poolManager.getFeeGrowthGlobals(poolId);
            uint256 bench = ScoreMath.valueOf(
                bench0 + ScoreMath.feesFor(global0, v.feeGrowthGlobal0Open, benchLiquidity),
                bench1 + ScoreMath.feesFor(global1, v.feeGrowthGlobal1Open, benchLiquidity),
                sqrtTwap
            );
            st.navBenchmark = FullMath.mulDiv(bench, v.totalShares, v.benchShares);
        }
        st.liveAlphaBps = ScoreMath.alphaBps(st.nav, st.navBenchmark);
        if (st.navBenchmark != 0) {
            st.valueRatio = FullMath.mulDiv(st.nav, ONE, st.navBenchmark);
            (st.feeSharesDue,) = _feeDue(v, st.valueRatio);
        }

        // The shadow's record counts until the live one is as long as the shadow had to be.
        st.capacityAlphaBps =
            block.timestamp < uint256(v.openedAt) + MIN_SHADOW_AGE ? v.shadowAlphaBps : st.liveAlphaBps;
        st.multiple = BASE_MULTIPLE;
        if (st.capacityAlphaBps > 0) {
            st.multiple += uint256(st.capacityAlphaBps) / ALPHA_STEP_BPS;
            if (st.multiple > MAX_MULTIPLE) st.multiple = MAX_MULTIPLE;
        }
        st.maxTotalShares = v.curatorShares * st.multiple;
        st.demoted = st.liveAlphaBps < DEMOTION_ALPHA_BPS;
    }

    /// @dev Value of everything the vault holds, in token1, with the position taken at `sqrtPriceX96`.
    function _nav(Vault storage v, uint256 vaultId, uint160 sqrtPriceX96) internal view returns (uint256) {
        (uint256 amount0, uint256 amount1) = _holdings(v, vaultId, sqrtPriceX96);
        return ScoreMath.valueOf(amount0, amount1, sqrtPriceX96);
    }

    function _holdings(Vault storage v, uint256 vaultId, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = ScoreMath.amountsFor(sqrtPriceX96, v.tickLower, v.tickUpper, v.liquidity);
        (uint256 fees0, uint256 fees1) = _pendingFees(v, vaultId);
        amount0 += fees0 + v.idle0;
        amount1 += fees1 + v.idle1;
    }

    /// @dev Fees the position has earned and not yet collected.
    function _pendingFees(Vault storage v, uint256 vaultId) internal view returns (uint256 fees0, uint256 fees1) {
        uint128 liquidity = v.liquidity;
        if (liquidity == 0) return (0, 0);
        (, uint256 last0, uint256 last1) =
            poolManager.getPositionInfo(v.poolId, address(this), v.tickLower, v.tickUpper, bytes32(vaultId));
        (uint256 growth0, uint256 growth1) = poolManager.getFeeGrowthInside(v.poolId, v.tickLower, v.tickUpper);
        fees0 = ScoreMath.feesFor(growth0, last0, liquidity);
        fees1 = ScoreMath.feesFor(growth1, last1, liquidity);
    }

    function _amountsRoundingUp(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPriceX96 <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtPriceX96 < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    function _knownVault(uint256 vaultId) internal view returns (Vault storage v) {
        v = _vaults[vaultId];
        if (v.curator == address(0)) revert UnknownVault();
    }

    function _openVault(uint256 vaultId) internal view returns (Vault storage v) {
        v = _knownVault(vaultId);
        if (v.closedAt != 0) revert VaultIsClosed();
    }

    /// @dev The vault's position may be at most `LIVE_MAX_POOL_SHARE_BPS` of the pool's active liquidity.
    function _checkPoolShare(Vault storage v) internal view {
        if (
            uint256(v.liquidity) * ScoreMath.BPS > uint256(poolManager.getLiquidity(v.poolId)) * LIVE_MAX_POOL_SHARE_BPS
        ) {
            revert OverPoolShare();
        }
    }

    // ------------------------------------------------------------------------------------------
    // Pool operations
    // ------------------------------------------------------------------------------------------

    function _unlock(Call memory call) internal returns (uint256, uint256) {
        return abi.decode(poolManager.unlock(abi.encode(call)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Call memory call = abi.decode(data, (Call));
        Vault storage v = _vaults[call.vaultId];
        PoolKey memory key = _poolKeys[v.poolId];

        uint256 a;
        uint256 b;
        if (call.action == Action.Enter) (a, b) = _enter(v, key, call);
        else if (call.action == Action.Exit) (a, b) = _exit(v, key, call);
        else (a, b) = _rebalance(v, key, call);
        return abi.encode(a, b);
    }

    /// @dev One token's side of an entry: the idle balance after the newcomer matches their fraction
    /// of it (rounded up), and what the newcomer pays in total.
    function _matchIdle(uint256 idle, uint256 fees, int256 delta, uint256 shares, uint256 supply)
        internal
        pure
        returns (uint256 idleAfter, uint256 paid)
    {
        idle += fees;
        uint256 matched = supply == 0 ? 0 : FullMath.mulDivRoundingUp(idle, shares, supply);
        idleAfter = idle + matched;
        paid = uint256(int256(fees) - delta) + matched;
    }

    /// @dev Adds `call.shares` worth to the position and the idle balances, paid by `call.account`.
    /// Rounds against the newcomer. For the very first entry the shares are the liquidity.
    function _enter(Vault storage v, PoolKey memory key, Call memory call)
        internal
        returns (uint256 paid0, uint256 paid1)
    {
        uint256 supply = v.totalShares;
        int256 delta0;
        int256 delta1;
        uint256 fees0;
        uint256 fees1;
        {
            uint128 liquidity = v.liquidity;
            uint128 added =
                (supply == 0 ? call.shares : FullMath.mulDivRoundingUp(liquidity, call.shares, supply)).toUint128();
            // One call adds the liquidity and collects the fees the position has earned so far.
            (delta0, delta1, fees0, fees1) = _modify(key, v, call.vaultId, int256(uint256(added)), liquidity);
            v.liquidity = liquidity + added;
        }

        // The fees join the idle balances before the newcomer matches their fraction of them.
        // `delta` is what the pool owes the vault: the fees, less what the new liquidity costs.
        uint256 idle;
        (idle, paid0) = _matchIdle(v.idle0, fees0, delta0, call.shares, supply);
        v.idle0 = idle.toUint128();
        (idle, paid1) = _matchIdle(v.idle1, fees1, delta1, call.shares, supply);
        v.idle1 = idle.toUint128();
        if (paid0 > call.limit0 || paid1 > call.limit1) revert SlippageExceeded();

        _pull(key.currency0, call.account, paid0);
        _pull(key.currency1, call.account, paid1);
        _square(key.currency0, delta0);
        _square(key.currency1, delta1);
    }

    /// @dev Takes `call.shares` worth out of the position and the idle balances and sends it to
    /// `call.account`. Rounds against the leaver. Reads the share supply as it was before the exit.
    function _exit(Vault storage v, PoolKey memory key, Call memory call)
        internal
        returns (uint256 out0, uint256 out1)
    {
        uint256 supply = v.totalShares;
        uint128 liquidity = v.liquidity;
        uint128 removed = FullMath.mulDiv(liquidity, call.shares, supply).toUint128();

        (int256 delta0, int256 delta1, uint256 fees0, uint256 fees1) =
            _modify(key, v, call.vaultId, -int256(uint256(removed)), liquidity);

        uint256 idle0 = v.idle0 + fees0;
        uint256 idle1 = v.idle1 + fees1;
        uint256 share0 = FullMath.mulDiv(idle0, call.shares, supply);
        uint256 share1 = FullMath.mulDiv(idle1, call.shares, supply);
        // `delta` is the liquidity removed plus all the fees; only the liquidity part is the leaver's.
        out0 = uint256(delta0) - fees0 + share0;
        out1 = uint256(delta1) - fees1 + share1;
        if (out0 < call.limit0 || out1 < call.limit1) revert SlippageExceeded();

        v.liquidity = liquidity - removed;
        v.idle0 = (idle0 - share0).toUint128();
        v.idle1 = (idle1 - share1).toUint128();

        _square(key.currency0, delta0);
        _square(key.currency1, delta1);
        if (out0 != 0) key.currency0.transfer(call.account, out0);
        if (out1 != 0) key.currency1.transfer(call.account, out1);
    }

    /// @dev Moves the whole vault to [call.tickLower, call.tickUpper). Returns its value before and
    /// after the swap, in token1 at the time-weighted price.
    function _rebalance(Vault storage v, PoolKey memory key, Call memory call)
        internal
        returns (uint256 valueBefore, uint256 valueAfter)
    {
        PoolId poolId = v.poolId;
        uint160 sqrtTwap = TickMath.getSqrtPriceAtTick(call.twap);

        // 1. Take everything out of the old range. The fees come with it.
        (int256 net0, int256 net1,,) = _modify(key, v, call.vaultId, -int256(uint256(v.liquidity)), v.liquidity);
        uint256 have0 = v.idle0 + uint256(net0);
        uint256 have1 = v.idle1 + uint256(net1);
        valueBefore = ScoreMath.valueOf(have0, have1, sqrtTwap);

        v.tickLower = call.tickLower;
        v.tickUpper = call.tickUpper;
        v.liquidity = 0;

        // 2. Swap toward the token mix the new range needs, never past the mandate's price bound.
        (uint160 sqrtPriceX96,,, uint24 lpFee) = poolManager.getSlot0(poolId);
        (bool zeroForOne, uint256 amountIn, uint160 limit) = _swapPlan(
            Mix({
                have0: have0,
                have1: have1,
                sqrtPriceX96: sqrtPriceX96,
                tickLower: call.tickLower,
                tickUpper: call.tickUpper,
                cap: _liquidityCap(poolId),
                active: poolManager.getLiquidity(poolId),
                lpFee: lpFee
            }),
            call.twap
        );
        if (amountIn != 0) {
            BalanceDelta swapped = poolManager.swap(
                key,
                SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit}),
                ""
            );
            net0 += swapped.amount0();
            net1 += swapped.amount1();
            have0 = uint256(int256(have0) + swapped.amount0());
            have1 = uint256(int256(have1) + swapped.amount1());
            (sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        }

        // 3. The fifth mandate check: the swap may not have cost more than the allowed loss.
        valueAfter = ScoreMath.valueOf(have0, have1, sqrtTwap);
        if (valueAfter * ScoreMath.BPS < valueBefore * (ScoreMath.BPS - MAX_REBALANCE_LOSS_BPS)) {
            revert RebalanceLossTooHigh(valueBefore, valueAfter);
        }

        // 4. Place as much as the balances and the pool-share cap allow. The rest stays idle.
        // One wei of each token is held back so rounding in the pool can never ask for more than is there.
        uint128 placed = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(call.tickLower),
            TickMath.getSqrtPriceAtTick(call.tickUpper),
            have0 == 0 ? 0 : have0 - 1,
            have1 == 0 ? 0 : have1 - 1
        );
        uint128 cap = _liquidityCap(poolId);
        if (placed > cap) placed = cap;
        if (placed == 0) revert NothingToPlace();

        (int256 delta0, int256 delta1,,) = _modify(key, v, call.vaultId, int256(uint256(placed)), 0);
        net0 += delta0;
        net1 += delta1;
        v.liquidity = placed;
        v.idle0 = uint256(int256(have0) + delta0).toUint128();
        v.idle1 = uint256(int256(have1) + delta1).toUint128();

        _square(key.currency0, net0);
        _square(key.currency1, net1);
    }

    /// @dev What the swap sizing works from: the vault's balances once its old position is out, the
    /// new range, and the state of the pool without the vault in it.
    struct Mix {
        uint256 have0;
        uint256 have1;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 cap; // pool-share cap on the new position
        uint128 active; // the pool's active liquidity
        uint24 lpFee;
    }

    /// @dev Which token to sell, how much, and the price the swap must not pass. Sells only what the
    /// new range is short of, and never more than is spare. The amount is zero when no swap is
    /// needed or none is possible.
    /// A swap moves the price, and near the edge of a range a small move changes the mix the range
    /// needs by a lot. So the amount is first sized at the current price and then refined against the
    /// price the swap is expected to end at, assuming the pool's liquidity holds along the way. Any
    /// error in that estimate only leaves a little more idle.
    function _swapPlan(Mix memory m, int24 twap)
        internal
        view
        returns (bool zeroForOne, uint256 amountIn, uint160 limit)
    {
        (uint256 need0, uint256 need1) = _needs(m, m.have0, m.have1, m.sqrtPriceX96);
        if (m.have0 < need0) {
            amountIn =
                _lesser(ScoreMath.toToken1(need0 - m.have0, m.sqrtPriceX96), m.have1 > need1 ? m.have1 - need1 : 0);
        } else if (m.have1 < need1) {
            zeroForOne = true;
            amountIn = _lesser(ScoreMath.toToken0(need1 - m.have1, m.sqrtPriceX96), m.have0 - need0);
        }
        if (amountIn == 0 || m.active == 0 || m.lpFee >= 1e6) return (zeroForOne, 0, 0);

        limit = _priceLimit(zeroForOne, m.tickLower, m.tickUpper, twap);
        if (zeroForOne ? limit >= m.sqrtPriceX96 : limit <= m.sqrtPriceX96) return (zeroForOne, 0, 0);
        // The most the pool can take before the price reaches the limit, fee included.
        uint256 room = FullMath.mulDivRoundingUp(
            zeroForOne
                ? SqrtPriceMath.getAmount0Delta(limit, m.sqrtPriceX96, m.active, true)
                : SqrtPriceMath.getAmount1Delta(m.sqrtPriceX96, limit, m.active, true),
            1e6,
            1e6 - m.lpFee
        );

        for (uint256 i; i < 3; ++i) {
            amountIn = _lesser(amountIn, room);
            uint160 next = SqrtPriceMath.getNextSqrtPriceFromInput(
                m.sqrtPriceX96, m.active, FullMath.mulDiv(amountIn, 1e6 - m.lpFee, 1e6), zeroForOne
            );
            uint256 after0;
            uint256 after1;
            if (zeroForOne) {
                after0 = m.have0 - amountIn;
                after1 = m.have1 + SqrtPriceMath.getAmount1Delta(next, m.sqrtPriceX96, m.active, false);
            } else {
                after0 = m.have0 + SqrtPriceMath.getAmount0Delta(m.sqrtPriceX96, next, m.active, false);
                after1 = m.have1 - amountIn;
            }
            (need0, need1) = _needs(m, after0, after1, next);

            // Still short of the token being bought: sell more. Short of the token being sold: sell less.
            uint256 more;
            uint256 less;
            if (zeroForOne) {
                if (after1 < need1) {
                    more = _lesser(ScoreMath.toToken0(need1 - after1, next), after0 > need0 ? after0 - need0 : 0);
                } else if (after0 < need0) {
                    less = need0 - after0;
                }
            } else {
                if (after0 < need0) {
                    more = _lesser(ScoreMath.toToken1(need0 - after0, next), after1 > need1 ? after1 - need1 : 0);
                } else if (after1 < need1) {
                    less = need1 - after1;
                }
            }
            if (less >= amountIn) return (zeroForOne, 0, 0);
            amountIn = amountIn + more - less;
        }
        amountIn = _lesser(amountIn, room);
    }

    /// @dev The token amounts the new range would hold if everything the vault has were placed in it
    /// at `sqrtPriceX96`, up to the pool-share cap.
    function _needs(Mix memory m, uint256 have0, uint256 have1, uint160 sqrtPriceX96)
        internal
        pure
        returns (uint256 need0, uint256 need1)
    {
        (, uint256 unitValue) = ScoreMath.perUnit(sqrtPriceX96, m.tickLower, m.tickUpper);
        if (unitValue == 0) return (0, 0);
        uint256 target = FullMath.mulDiv(ScoreMath.valueOf(have0, have1, sqrtPriceX96), ScoreMath.UNIT, unitValue);
        if (target > m.cap) target = m.cap;
        return ScoreMath.amountsFor(sqrtPriceX96, m.tickLower, m.tickUpper, uint128(target));
    }

    function _lesser(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The furthest the vault's own swap may push the price: it stays inside the new range and
    /// within `MAX_DEVIATION_TICKS` of the time-weighted average.
    function _priceLimit(bool zeroForOne, int24 tickLower, int24 tickUpper, int24 twap)
        internal
        view
        returns (uint160)
    {
        int256 deviation = int256(uint256(MAX_DEVIATION_TICKS));
        if (zeroForOne) {
            int256 floorTick = int256(twap) - deviation;
            if (floorTick < tickLower) floorTick = tickLower;
            return TickMath.getSqrtPriceAtTick(int24(floorTick)) + 1;
        }
        int256 ceilingTick = int256(twap) + deviation;
        if (ceilingTick > tickUpper) ceilingTick = tickUpper;
        return TickMath.getSqrtPriceAtTick(int24(ceilingTick)) - 1;
    }

    /// @dev Largest position the pool-share cap allows, given the active liquidity of everyone else.
    /// Solves `L <= share x (others + L)`.
    function _liquidityCap(PoolId poolId) internal view returns (uint128) {
        if (LIVE_MAX_POOL_SHARE_BPS == ScoreMath.BPS) return type(uint128).max;
        uint256 cap = uint256(poolManager.getLiquidity(poolId)) * LIVE_MAX_POOL_SHARE_BPS
            / (ScoreMath.BPS - LIVE_MAX_POOL_SHARE_BPS);
        return cap > type(uint128).max ? type(uint128).max : uint128(cap);
    }

    /// @dev Changes the vault's position by `liquidityDelta`. Skipped when there is no position to
    /// touch. Returns what the pool owes the vault (negative when the vault owes) and the fees collected.
    function _modify(PoolKey memory key, Vault storage v, uint256 vaultId, int256 liquidityDelta, uint128 current)
        internal
        returns (int256 delta0, int256 delta1, uint256 fees0, uint256 fees1)
    {
        if (current == 0 && liquidityDelta == 0) return (0, 0, 0, 0);
        (BalanceDelta delta, BalanceDelta fees) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: v.tickLower, tickUpper: v.tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(vaultId)
            }),
            ""
        );
        return (delta.amount0(), delta.amount1(), uint256(uint128(fees.amount0())), uint256(uint128(fees.amount1())));
    }

    function _pull(Currency currency, address from, uint256 amount) internal {
        if (amount != 0) IERC20(Currency.unwrap(currency)).safeTransferFrom(from, address(this), amount);
    }

    /// @dev Settles one currency with the pool manager: pays what the vault owes, or collects what it is owed.
    function _square(Currency currency, int256 delta) internal {
        if (delta < 0) {
            poolManager.sync(currency);
            currency.transfer(address(poolManager), uint256(-delta));
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }
}
