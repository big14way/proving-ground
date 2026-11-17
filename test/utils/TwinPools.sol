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
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ProvingGroundHook} from "../../src/ProvingGroundHook.sol";
import {ProvingGroundVault} from "../../src/ProvingGroundVault.sol";
import {IProvingGround} from "../../src/interfaces/IProvingGround.sol";
import {IProvingGroundVault} from "../../src/interfaces/IProvingGroundVault.sol";

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

    // The mandate and bond the hook is deployed with unless a test asks for something else.
    uint24 internal constant MIN_WIDTH = 120;
    uint24 internal constant MAX_WIDTH = 12_000;
    uint24 internal constant MAX_DEVIATION = 100;
    uint32 internal constant COOLDOWN = 300;
    uint32 internal constant MIN_AGE = 7 days;
    uint128 internal constant BOND = 0.01 ether;

    ProvingGroundHook internal hook;
    /// @dev Where the vault contract is (or would be) deployed. The hook is told this address at
    /// construction; tests that need the vault deploy it here.
    address internal vaultAt = makeAddr("vault");
    ProvingGroundVault internal vault;
    address internal curator;
    uint256 internal curatorKey;
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

    function _setUpTwin(
        uint8 decimals0,
        uint8 decimals1,
        int24 centerTick,
        uint128 liquidityScale,
        IProvingGround.Config memory config
    ) internal {
        _setUpTwinWith(FEE, TS, decimals0, decimals1, centerTick, liquidityScale, config);
    }

    /// @dev The same pair of pools at another fee tier and tick spacing.
    function _setUpTwinWith(
        uint24 fee,
        int24 spacing,
        uint8 decimals0,
        uint8 decimals1,
        int24 centerTick,
        uint128 liquidityScale,
        IProvingGround.Config memory config
    ) internal {
        deployArtifactsAndLabel();
        (c0, c1) = _deployPair(decimals0, decimals1);
        (curator, curatorKey) = makeAddrAndKey("curator");

        hook = _deployHook(0x4444, config);
        MockERC20(Currency.unwrap(c0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(hook), type(uint256).max);

        center = centerTick;
        scale = liquidityScale;
        uint160 sqrtCenter = TickMath.getSqrtPriceAtTick(centerTick);
        unit0 = FullMath.mulDiv(liquidityScale, FixedPoint96.Q96, sqrtCenter);
        unit1 = FullMath.mulDiv(liquidityScale, sqrtCenter, FixedPoint96.Q96);

        keyA = PoolKey(c0, c1, fee, spacing, IHooks(address(hook)));
        keyB = PoolKey(c0, c1, fee, spacing, IHooks(address(0)));
        idA = keyA.toId();
        idB = keyB.toId();
        poolManager.initialize(keyA, sqrtCenter);
        poolManager.initialize(keyB, sqrtCenter);

        hook.fundDust(c0, unit0);
        hook.fundDust(c1, unit1);

        _baseLiquidity(keyA);
        _baseLiquidity(keyB);
    }

    /// @dev The configuration a deployment would use: every mandate limit and the bond are on.
    /// @param maxShareBps Shadow size cap.
    function _config(uint16 maxShareBps) internal view returns (IProvingGround.Config memory) {
        return IProvingGround.Config({
            twapWindow: TWAP_WINDOW,
            oracleCapacity: ORACLE_CAPACITY,
            shadowMaxPoolShareBps: maxShareBps,
            defaultDynamicFee: FEE,
            minWidthTicks: MIN_WIDTH,
            maxWidthTicks: MAX_WIDTH,
            maxDeviationTicks: MAX_DEVIATION,
            minRebalanceInterval: COOLDOWN,
            minShadowAge: MIN_AGE,
            bondMin: BOND,
            vault: vaultAt
        });
    }

    /// @dev No cooldown, no price check, no bond, any width. For tests that measure how accurate the
    /// score is and need to place a shadow wherever the measurement requires.
    function _looseConfig(uint16 maxShareBps) internal view returns (IProvingGround.Config memory config) {
        config = _config(maxShareBps);
        config.minWidthTicks = 1;
        config.maxWidthTicks = type(uint24).max;
        config.maxDeviationTicks = type(uint24).max;
        config.minRebalanceInterval = 0;
        config.minShadowAge = 0;
        config.bondMin = 0;
    }

    function _deployHook(uint160 prefix, IProvingGround.Config memory config) internal returns (ProvingGroundHook h) {
        address at = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG) ^ (prefix << 144));
        deployCodeTo("ProvingGroundHook.sol:ProvingGroundHook", abi.encode(poolManager, config), at);
        h = ProvingGroundHook(at);
    }

    // ------------------------------------------------------------------ the vault

    /// @dev The vault configuration a deployment would use.
    function _vaultConfig() internal pure returns (IProvingGroundVault.VaultConfig memory) {
        return IProvingGroundVault.VaultConfig({
            graduationAlphaBps: 0,
            demotionAlphaBps: -200,
            baseMultiple: 2,
            maxMultiple: 10,
            alphaStepBps: 50,
            liveMaxPoolShareBps: 1000,
            maxRebalanceLossBps: 50,
            perfFeeBps: 1000
        });
    }

    /// @dev Deploys the vault at the address the hook was told to trust.
    function _deployVault(IProvingGroundVault.VaultConfig memory config) internal {
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, config), vaultAt);
        vault = ProvingGroundVault(vaultAt);
    }

    /// @dev Gives `who` plenty of both tokens and lets the vault pull them.
    function _fund(address who) internal {
        MockERC20(Currency.unwrap(c0)).transfer(who, 1e27);
        MockERC20(Currency.unwrap(c1)).transfer(who, 1e27);
        vm.startPrank(who);
        MockERC20(Currency.unwrap(c0)).approve(address(vault), type(uint256).max);
        MockERC20(Currency.unwrap(c1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The live intent a vault's curator would sign next.
    function _liveIntent(uint256 vaultId, int24 lo, int24 hi)
        internal
        view
        returns (IProvingGround.RebalanceIntent memory)
    {
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        return IProvingGround.RebalanceIntent({
            poolId: v.poolId,
            subjectId: vaultId,
            live: true,
            tickLower: lo,
            tickUpper: hi,
            nonce: hook.nonces(v.curator),
            deadline: vm.getBlockTimestamp() + 1 hours
        });
    }

    /// @dev The curator signs, this contract submits.
    function _rebalanceLive(uint256 vaultId, int24 lo, int24 hi) internal {
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, lo, hi);
        vault.rebalance(intent, _sign(curatorKey, intent));
    }

    // ------------------------------------------------------------------ shadows and signed intents

    /// @dev Opens a shadow on pool A as `who`, posting the hook's minimum bond.
    function _openAs(address who, int24 lo, int24 hi, uint128 liquidity) internal returns (uint256 shadowId) {
        uint256 bond = hook.BOND_MIN();
        vm.deal(who, who.balance + bond);
        vm.prank(who);
        shadowId = hook.openShadow{value: bond}(idA, lo, hi, liquidity);
    }

    /// @dev The intent the shadow's curator would sign next: their current nonce, valid for an hour.
    function _intent(uint256 shadowId, int24 lo, int24 hi)
        internal
        view
        returns (IProvingGround.RebalanceIntent memory)
    {
        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        return IProvingGround.RebalanceIntent({
            poolId: s.poolId,
            subjectId: shadowId,
            live: false,
            tickLower: lo,
            tickUpper: hi,
            nonce: hook.nonces(s.curator),
            deadline: vm.getBlockTimestamp() + 1 hours
        });
    }

    function _sign(uint256 privateKey, IProvingGround.RebalanceIntent memory intent)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hook.intentDigest(intent));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The curator signs, this contract submits. The submitter is never the curator in these tests.
    function _rebalance(uint256 shadowId, int24 lo, int24 hi) internal {
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, lo, hi);
        hook.rebalance(intent, _sign(curatorKey, intent));
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

    // ------------------------------------------------------------------ the real position on pool B

    uint256 internal tokenId;
    uint128 internal realLiquidity;
    uint256 internal idle0;
    uint256 internal idle1;

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
