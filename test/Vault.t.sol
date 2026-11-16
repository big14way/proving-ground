// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {TwinPools} from "./utils/TwinPools.sol";
import {EasyPosm} from "./utils/libraries/EasyPosm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {ProvingGroundHook} from "../src/ProvingGroundHook.sol";
import {ProvingGroundVault} from "../src/ProvingGroundVault.sol";
import {IProvingGround} from "../src/interfaces/IProvingGround.sol";
import {IProvingGroundVault} from "../src/interfaces/IProvingGroundVault.sol";

/// @notice Shared set-up for the vault tests: a hook and vault on pool A, a curator with a shadow
/// old enough and good enough to go live, and two outside depositors.
abstract contract VaultBase is TwinPools {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    uint256 internal constant MAX = type(uint256).max;
    uint128 internal constant STAKE = 20e18;

    address internal lp = makeAddr("lp");
    address internal lp2 = makeAddr("lp2");
    address internal stranger = makeAddr("stranger");

    function _start(IProvingGroundVault.VaultConfig memory config) internal {
        _setUpTwin(18, 18, 0, 1e18, _config(100));
        _deployVault(config);
        _fund(curator);
        _fund(lp);
        _fund(lp2);
    }

    uint256 internal flowAt; // how many scripted swaps have run so far

    /// @dev `n` more swaps that keep the price near the centre.
    function _flow(uint256 n) internal {
        _pingPong(flowAt, flowAt + n);
        flowAt += n;
    }

    /// @dev `n` more swaps that let the price drift.
    function _randomFlow(uint256 n) internal {
        _randomSwaps(flowAt, flowAt + n);
        flowAt += n;
    }

    /// @dev The largest multiple of the tick spacing at or below the current tick.
    function _floorTick() internal view returns (int24 floor_) {
        int24 spot = _spot();
        floor_ = (spot / TS) * TS;
        if (spot < 0 && spot % TS != 0) floor_ -= TS;
    }

    /// @dev A shadow at the 1% size cap that has seen in-range flow and reached the minimum age.
    function _provenShadow(address who, int24 lo, int24 hi) internal returns (uint256 shadowId) {
        shadowId = _openAs(who, lo, hi, _activeShare(100));
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + MIN_AGE);
    }

    function _goLive(int24 lo, int24 hi, uint128 stake) internal returns (uint256 vaultId) {
        uint256 shadowId = _provenShadow(curator, lo, hi);
        vm.prank(curator);
        vaultId = vault.goLive(shadowId, stake, MAX, MAX);
    }

    function _deposit(address who, uint256 vaultId, uint256 shares) internal returns (uint256 paid0, uint256 paid1) {
        vm.prank(who);
        (paid0, paid1) = vault.deposit(vaultId, shares, MAX, MAX);
    }

    function _withdraw(address who, uint256 vaultId, uint256 shares) internal returns (uint256 out0, uint256 out1) {
        vm.prank(who);
        (out0, out1) = vault.withdraw(vaultId, shares, 0, 0);
    }

    function _spot() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(idA);
    }

    function _vaultPosition(uint256 vaultId, int24 lo, int24 hi) internal view returns (uint128) {
        return
            poolManager.getPositionLiquidity(
                idA, Position.calculatePositionKey(address(vault), lo, hi, bytes32(vaultId))
            );
    }

    /// @dev The vault contract holds exactly the idle balances it has on its books.
    function _assertBooksMatchBalances(uint256 vaultId) internal view {
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(c0.balanceOf(address(vault)), v.idle0, "token0 held equals idle0");
        assertEq(c1.balanceOf(address(vault)), v.idle1, "token1 held equals idle1");
    }

    function _rejectsLive(IProvingGround.RebalanceIntent memory intent, uint256 signerKey, bytes4 selector) internal {
        bytes memory signature = _sign(signerKey, intent);
        vm.expectRevert(selector);
        vault.rebalance(intent, signature);
    }
}

/// @notice Going live, in-kind deposits and withdrawals, capacity, demotion and the curator's stake.
contract VaultTest is VaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    function setUp() public {
        _start(_vaultConfig());
    }

    // ------------------------------------------------------------------ deployment

    function test_config_isStoredAndSharedWithTheHook() public view {
        assertEq(address(vault.HOOK()), address(hook));
        assertEq(hook.VAULT(), address(vault));
        assertEq(address(vault.poolManager()), address(poolManager));
        assertEq(vault.MIN_SHADOW_AGE(), hook.MIN_SHADOW_AGE());
        assertEq(vault.MAX_DEVIATION_TICKS(), hook.MAX_DEVIATION_TICKS());
        assertEq(vault.GRADUATION_ALPHA_BPS(), 0);
        assertEq(vault.DEMOTION_ALPHA_BPS(), -200);
        assertEq(vault.BASE_MULTIPLE(), 2);
        assertEq(vault.MAX_MULTIPLE(), 10);
        assertEq(vault.ALPHA_STEP_BPS(), 50);
        assertEq(vault.LIVE_MAX_POOL_SHARE_BPS(), 1000);
        assertEq(vault.MAX_REBALANCE_LOSS_BPS(), 50);
        assertEq(vault.PERF_FEE_BPS(), 1000);
    }

    function test_config_invalidReverts() public {
        IProvingGroundVault.VaultConfig memory bad = _vaultConfig();
        bad.baseMultiple = 0;
        vm.expectRevert();
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, bad), vaultAt);

        bad = _vaultConfig();
        bad.maxMultiple = 1;
        vm.expectRevert();
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, bad), vaultAt);

        bad = _vaultConfig();
        bad.alphaStepBps = 0;
        vm.expectRevert();
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, bad), vaultAt);

        bad = _vaultConfig();
        bad.liveMaxPoolShareBps = 10_001;
        vm.expectRevert();
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, bad), vaultAt);

        bad = _vaultConfig();
        bad.maxRebalanceLossBps = 10_001;
        vm.expectRevert();
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, bad), vaultAt);

        bad = _vaultConfig();
        bad.perfFeeBps = 10_000;
        vm.expectRevert();
        deployCodeTo("ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, bad), vaultAt);
    }

    /// @dev A vault deployed anywhere but the address the hook trusts cannot be constructed.
    function test_config_vaultMustBeTheOneTheHookTrusts() public {
        vm.expectRevert();
        deployCodeTo(
            "ProvingGroundVault.sol:ProvingGroundVault", abi.encode(hook, _vaultConfig()), makeAddr("elsewhere")
        );
    }

    function test_contractsFitTheSizeLimit() public view {
        console2.log("hook runtime bytes: ", address(hook).code.length);
        console2.log("vault runtime bytes:", address(vault).code.length);
        assertLe(address(hook).code.length, 24_576);
        assertLe(address(vault).code.length, 24_576);
    }

    function test_hook_onlyTheVaultMayGraduateOrAuthorize() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        vm.prank(curator);
        vm.expectRevert(IProvingGround.NotVault.selector);
        hook.graduate(shadowId);

        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        intent.live = true;
        bytes memory signature = _sign(curatorKey, intent);
        vm.prank(curator);
        vm.expectRevert(IProvingGround.NotVault.selector);
        hook.authorizeLive(intent, signature, curator, 0);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(IProvingGroundVault.NotPoolManager.selector);
        vault.unlockCallback("");
    }

    // ------------------------------------------------------------------ going live

    function test_goLive_opensAVaultOnTheShadowsRange() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        int256 alpha = hook.score(shadowId).alphaBps;
        assertGt(alpha, 0, "in-range flow beats the passive benchmark");
        uint256 eth = curator.balance;
        uint256 b0 = c0.balanceOf(curator);
        uint256 b1 = c1.balanceOf(curator);
        (uint256 quote0, uint256 quote1) = (0, 0);

        vm.prank(curator);
        uint256 vaultId = vault.goLive(shadowId, STAKE, MAX, MAX);
        assertEq(vaultId, shadowId, "the vault takes the shadow's id");

        // The shadow is closed as graduated: bond back, slot free, nothing added to the abandoned count.
        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        assertTrue(s.graduated);
        assertEq(s.closedAt, vm.getBlockTimestamp());
        assertEq(s.bond, 0);
        assertEq(curator.balance, eth + BOND, "bond returned");
        assertEq(hook.activeShadowOf(curator, idA), 0);
        (uint32 opened, uint32 abandoned) = hook.curatorRecord(curator);
        assertEq(opened, 1);
        assertEq(abandoned, 0);
        assertEq(hook.score(shadowId).alphaBps, alpha, "score frozen");

        // The vault holds a real position on the shadow's range, paid for by the curator.
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(PoolId.unwrap(v.poolId), PoolId.unwrap(idA));
        assertEq(v.curator, curator);
        assertEq(v.tickLower, -300);
        assertEq(v.tickUpper, 300);
        assertEq(v.liquidity, STAKE);
        assertEq(v.totalShares, STAKE);
        assertEq(v.curatorShares, STAKE);
        assertEq(v.shadowAlphaBps, alpha);
        assertEq(v.openedAt, vm.getBlockTimestamp());
        assertEq(_vaultPosition(vaultId, -300, 300), STAKE, "real liquidity in the pool");
        (quote0, quote1) = vault.holdings(vaultId);
        assertApproxEqAbs(b0 - c0.balanceOf(curator), quote0, 1, "paid what the position holds, token0");
        assertApproxEqAbs(b1 - c1.balanceOf(curator), quote1, 1, "paid what the position holds, token1");
        assertGt(quote0, 0);
        assertGt(quote1, 0);
        _assertBooksMatchBalances(vaultId);

        // The stake is a number on the vault's books, not a transferable token.
        assertEq(vault.balanceOf(curator, vaultId), 0);
        assertEq(vault.outsideShares(vaultId), 0);

        // It starts level with its benchmark.
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        assertApproxEqAbs(st.liveAlphaBps, 0, 1);
        assertEq(st.capacityAlphaBps, alpha);
        assertFalse(st.demoted);
    }

    function test_goLive_tooYoungReverts() public {
        uint256 shadowId = _openAs(curator, -300, 300, _activeShare(100));
        uint256 readyAt = vm.getBlockTimestamp() + MIN_AGE;
        _flow(120);
        vm.warp(readyAt - 1);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(IProvingGroundVault.ShadowTooYoung.selector, readyAt));
        vault.goLive(shadowId, STAKE, MAX, MAX);

        vm.warp(readyAt);
        vm.prank(curator);
        vault.goLive(shadowId, STAKE, MAX, MAX);
    }

    function test_goLive_onlyTheShadowsCurator() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.NotVaultCurator.selector);
        vault.goLive(shadowId, STAKE, MAX, MAX);

        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.NotVaultCurator.selector);
        vault.goLive(999, STAKE, MAX, MAX);
    }

    function test_goLive_aClosedShadowCannotGraduate() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        vm.prank(curator);
        hook.closeShadow(shadowId);
        vm.prank(curator);
        vm.expectRevert(IProvingGround.ShadowIsClosed.selector);
        vault.goLive(shadowId, STAKE, MAX, MAX);
    }

    function test_goLive_onlyOncePerShadow() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        vm.prank(curator);
        vm.expectRevert(IProvingGround.ShadowIsClosed.selector);
        vault.goLive(vaultId, STAKE, MAX, MAX);
    }

    function test_goLive_needsAStake() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.ZeroShares.selector);
        vault.goLive(shadowId, 0, MAX, MAX);
    }

    function test_goLive_respectsTheCallersMaximums() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.SlippageExceeded.selector);
        vault.goLive(shadowId, STAKE, 0, MAX);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.SlippageExceeded.selector);
        vault.goLive(shadowId, STAKE, MAX, 0);
    }

    function test_goLive_abovePoolShareCapReverts() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        // Everyone else's liquidity, once the shadow's dust position is gone.
        uint256 others = poolManager.getLiquidity(idA) - hook.DUST();
        // L <= 10% of (others + L)  <=>  L <= others / 9
        uint128 most = uint128(others / 9);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.OverPoolShare.selector);
        vault.goLive(shadowId, most + 1, MAX, MAX);
        vm.prank(curator);
        vault.goLive(shadowId, most, MAX, MAX);
    }

    /// @dev After graduating, the curator's shadow slot is free and the record shows no abandonment.
    function test_goLive_freesTheShadowSlot() public {
        _goLive(-300, 300, STAKE);
        uint256 next = _openAs(curator, -600, 600, _activeShare(50));
        assertEq(hook.activeShadowOf(curator, idA), next);
    }

    // ------------------------------------------------------------------ deposit then withdraw

    /// @dev The Phase 2 gate: a deposit followed at once by a withdrawal returns the tokens to
    /// within rounding, and never more than was paid in.
    function _roundTrip(uint256 vaultId, uint256 shares) internal {
        (uint256 h0, uint256 h1) = vault.holdings(vaultId);
        (uint256 quote0, uint256 quote1) = vault.quoteDeposit(vaultId, shares);
        (uint256 paid0, uint256 paid1) = _deposit(lp, vaultId, shares);
        assertEq(paid0, quote0, "quote matches, token0");
        assertEq(paid1, quote1, "quote matches, token1");
        assertEq(vault.balanceOf(lp, vaultId), shares);
        (uint256 out0, uint256 out1) = _withdraw(lp, vaultId, shares);

        assertLe(out0, paid0, "no profit, token0");
        assertLe(out1, paid1, "no profit, token1");
        assertLe(paid0 - out0, 3, "token0 back to within rounding");
        assertLe(paid1 - out1, 3, "token1 back to within rounding");
        assertEq(vault.balanceOf(lp, vaultId), 0);

        // Those already in the vault are not worse off.
        (uint256 after0, uint256 after1) = vault.holdings(vaultId);
        assertGe(after0, h0);
        assertGe(after1, h1);
        _assertBooksMatchBalances(vaultId);
        console2.log("  round trip left behind (wei):", paid0 - out0, paid1 - out1);
    }

    function test_gate_depositThenWithdraw_freshVault() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _roundTrip(vaultId, 7e18);
    }

    function test_gate_depositThenWithdraw_withUncollectedFees() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _flow(40);
        _roundTrip(vaultId, 7e18);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertGt(v.idle0 + v.idle1, 0, "the fees were collected into idle");
    }

    function test_gate_depositThenWithdraw_afterARebalanceLeftIdleTokens() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _flow(40);
        _rebalanceLive(vaultId, -600, 600);
        _flow(20);
        _roundTrip(vaultId, 7e18);
    }

    function test_gate_depositThenWithdraw_positionOutOfRange() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _swapBoth(true, 80e18);
        assertLt(_spot(), -300);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        // The vault is now all token0 and scores below its benchmark, so use the stake path, which
        // has no standing check, to exercise the same enter and exit code.
        (uint256 h0,) = vault.holdings(vaultId);
        vm.prank(curator);
        (uint256 paid0, uint256 paid1) = vault.stake(vaultId, 5e18, MAX, MAX);
        vm.prank(curator);
        (uint256 out0, uint256 out1) = vault.unstake(vaultId, 5e18, 0, 0);
        assertEq(paid1, 0);
        assertEq(out1, 0);
        assertLe(out0, paid0);
        assertLe(paid0 - out0, 3);
        (uint256 after0,) = vault.holdings(vaultId);
        assertGe(after0, h0);
    }

    /// @dev Fees earned before a deposit belong to those who were in the vault when they were earned.
    function test_deposit_doesNotShareInEarlierFees() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _flow(40);
        (uint256 before0, uint256 before1) = vault.holdings(vaultId);

        // After a deposit, what belongs to everyone else is what the whole vault was before it.
        _deposit(lp, vaultId, STAKE);
        (uint256 after0, uint256 after1) = vault.holdings(vaultId);
        uint256 total = vault.getVault(vaultId).totalShares;
        assertApproxEqAbs(after0 * (total - STAKE) / total, before0, 2);
        assertApproxEqAbs(after1 * (total - STAKE) / total, before1, 2);
    }

    function test_deposit_respectsTheCallersMaximums() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        (uint256 quote0, uint256 quote1) = vault.quoteDeposit(vaultId, 5e18);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.SlippageExceeded.selector);
        vault.deposit(vaultId, 5e18, quote0 - 1, quote1);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.SlippageExceeded.selector);
        vault.deposit(vaultId, 5e18, quote0, quote1 - 1);
        vm.prank(lp);
        vault.deposit(vaultId, 5e18, quote0, quote1);
    }

    function test_withdraw_respectsTheCallersMinimums() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        (uint256 paid0, uint256 paid1) = _deposit(lp, vaultId, 5e18);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.SlippageExceeded.selector);
        vault.withdraw(vaultId, 5e18, paid0 + 1, 0);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.SlippageExceeded.selector);
        vault.withdraw(vaultId, 5e18, 0, paid1 + 1);
    }

    function test_depositAndWithdraw_guards() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        vm.startPrank(lp);
        vm.expectRevert(IProvingGroundVault.ZeroShares.selector);
        vault.deposit(vaultId, 0, MAX, MAX);
        vm.expectRevert(IProvingGroundVault.UnknownVault.selector);
        vault.deposit(999, 1e18, MAX, MAX);
        vm.expectRevert(IProvingGroundVault.ZeroShares.selector);
        vault.withdraw(vaultId, 0, 0, 0);
        vm.expectRevert(IProvingGroundVault.UnknownVault.selector);
        vault.withdraw(999, 1e18, 0, 0);
        // No shares, nothing to withdraw.
        vm.expectRevert();
        vault.withdraw(vaultId, 1, 0, 0);
        vm.stopPrank();
    }

    function test_shares_areTransferable() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _deposit(lp, vaultId, 6e18);
        vm.prank(lp);
        vault.transfer(lp2, vaultId, 2e18);
        assertEq(vault.balanceOf(lp, vaultId), 4e18);
        assertEq(vault.balanceOf(lp2, vaultId), 2e18);
        assertEq(vault.outsideShares(vaultId), 6e18);

        (uint256 out0, uint256 out1) = _withdraw(lp2, vaultId, 2e18);
        assertGt(out0 + out1, 0);
        vm.prank(lp2);
        vm.expectRevert();
        vault.withdraw(vaultId, 1, 0, 0);
    }

    /// @dev What the vault says it holds is what a real position with the same liquidity holds in
    /// the twin pool, and it is what a full exit pays out.
    function test_holdings_matchARealPositionInTheTwinPool() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        (uint256 tokenId,) = _mint(keyB, -300, 300, STAKE);
        _randomFlow(50);

        (uint256 held0, uint256 held1) = vault.holdings(vaultId);
        BalanceDelta real = positionManager.burn(tokenId, 0, 0, address(this), vm.getBlockTimestamp() + 1, "");
        assertApproxEqAbs(held0, uint128(real.amount0()), 2, "token0 as the real position");
        assertApproxEqAbs(held1, uint128(real.amount1()), 2, "token1 as the real position");

        vm.prank(curator);
        (uint256 out0, uint256 out1) = vault.unstake(vaultId, STAKE, 0, 0);
        assertApproxEqAbs(out0, held0, 2);
        assertApproxEqAbs(out1, held1, 2);
        console2.log("  vault holdings:", held0, held1);
        console2.log("  real position: ", uint128(real.amount0()), uint128(real.amount1()));
    }

    // ------------------------------------------------------------------ capacity

    function test_capacity_isAMultipleOfTheCuratorsStake() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        assertEq(st.maxTotalShares, uint256(STAKE) * st.multiple);
        uint256 room = st.maxTotalShares - STAKE;

        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IProvingGroundVault.OverCapacity.selector, st.maxTotalShares));
        vault.deposit(vaultId, room + 1, MAX, MAX);

        _deposit(lp, vaultId, room);
        assertEq(vault.getVault(vaultId).totalShares, st.maxTotalShares);
        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(IProvingGroundVault.OverCapacity.selector, st.maxTotalShares));
        vault.deposit(vaultId, 1, MAX, MAX);
    }

    /// @dev multiple = min(MAX, BASE + score / STEP), with the shadow's score at first.
    function test_capacity_multipleIsEarnedByTheShadowsScore() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        uint256 expected = 2 + uint256(v.shadowAlphaBps) / 50;
        if (expected > 10) expected = 10;
        assertEq(st.multiple, expected);
        assertGt(st.multiple, 2, "a positive score earned more than the base multiple");
        console2.log("  shadow score (bps):", v.shadowAlphaBps);
        console2.log("  multiple:          ", st.multiple);
    }

    function test_capacity_stakingMoreRaisesIt() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        uint256 before_ = vault.standing(vaultId).maxTotalShares;
        vm.prank(curator);
        vault.stake(vaultId, STAKE, MAX, MAX);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(v.curatorShares, 2 * uint256(STAKE));
        assertEq(v.totalShares, 2 * uint256(STAKE));
        assertEq(vault.standing(vaultId).maxTotalShares, 2 * before_);
    }

    /// @dev Once the vault has run for as long as a shadow must, its own score sets the capacity.
    function test_capacity_usesTheLiveScoreOnceTheVaultIsOldEnough() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _flow(120);
        IProvingGroundVault.Standing memory early = vault.standing(vaultId);
        assertEq(early.capacityAlphaBps, vault.getVault(vaultId).shadowAlphaBps);

        vm.warp(vault.getVault(vaultId).openedAt + MIN_AGE - 1);
        assertEq(vault.standing(vaultId).capacityAlphaBps, vault.getVault(vaultId).shadowAlphaBps);
        vm.warp(vault.getVault(vaultId).openedAt + MIN_AGE);
        IProvingGroundVault.Standing memory later = vault.standing(vaultId);
        assertEq(later.capacityAlphaBps, later.liveAlphaBps);
        assertGt(later.liveAlphaBps, 0, "the live vault earned fees a passive position would not have");
        console2.log("  live score (bps):", later.liveAlphaBps);
    }

    function test_capacity_poolShareCapAppliesToDeposits() public {
        uint256 shadowId = _provenShadow(curator, -300, 300);
        uint256 others = poolManager.getLiquidity(idA) - hook.DUST();
        uint128 stake = uint128(others / 12);
        vm.prank(curator);
        uint256 vaultId = vault.goLive(shadowId, stake, MAX, MAX);

        // Capacity would allow it; the pool-share cap does not.
        uint256 room = uint256(uint128(others / 9)) - stake;
        assertLt(stake + room + 1, vault.standing(vaultId).maxTotalShares);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.OverPoolShare.selector);
        vault.deposit(vaultId, room + 1, MAX, MAX);
        _deposit(lp, vaultId, room);
    }

    // ------------------------------------------------------------------ demotion

    /// @dev Pushes the price far below the vault's range and lets the average catch up.
    function _crash() internal {
        _swapBoth(true, 300e18);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
    }

    /// @dev The Phase 2 gate: a demoted vault takes no deposits, and withdrawals still work.
    function test_gate_demotedVaultRefusesDepositsButWithdrawalsWork() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _deposit(lp, vaultId, 10e18);
        _crash();

        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        console2.log("  live score after the crash (bps):", st.liveAlphaBps);
        assertLt(st.liveAlphaBps, -200);
        assertTrue(st.demoted);

        vm.prank(lp2);
        vm.expectRevert(abi.encodeWithSelector(IProvingGroundVault.Demoted.selector, st.liveAlphaBps));
        vault.deposit(vaultId, 1e18, MAX, MAX);

        (uint256 held0, uint256 held1) = vault.holdings(vaultId);
        (uint256 out0, uint256 out1) = _withdraw(lp, vaultId, 10e18);
        assertApproxEqAbs(out0, held0 / 3, 2, "a third of the vault, token0");
        assertApproxEqAbs(out1, held1 / 3, 2, "a third of the vault, token1");
        assertGt(out0, 0);
        _assertBooksMatchBalances(vaultId);
    }

    /// @dev A withdrawal uses neither the hook, the oracle nor the curator. Here the hook's code is
    /// replaced with code that always reverts, and the withdrawal still goes through.
    function test_gate_withdrawNeedsNothingFromTheHook() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _deposit(lp, vaultId, 10e18);
        _flow(20);

        vm.etch(address(hook), hex"fe");
        vm.expectRevert();
        hook.twapTick(idA);

        (uint256 out0, uint256 out1) = _withdraw(lp, vaultId, 10e18);
        assertGt(out0, 0);
        assertGt(out1, 0);
    }

    // ------------------------------------------------------------------ the curator's stake

    function test_stake_onlyTheCurator() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.NotVaultCurator.selector);
        vault.stake(vaultId, 1e18, MAX, MAX);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.NotVaultCurator.selector);
        vault.unstake(vaultId, 1e18, 0, 0);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.ZeroShares.selector);
        vault.stake(vaultId, 0, MAX, MAX);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.ZeroShares.selector);
        vault.unstake(vaultId, 0, 0, 0);
    }

    function test_unstake_stakeMustKeepBackingOutsideDeposits() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        _deposit(lp, vaultId, st.maxTotalShares - STAKE);

        // At capacity, not one share of stake can leave.
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.StakeLocked.selector);
        vault.unstake(vaultId, 1, 0, 0);

        // Once depositors leave, the stake they no longer need is free again.
        _withdraw(lp, vaultId, st.maxTotalShares - STAKE - (st.multiple - 1) * 1e18);
        // Outside money is now (multiple - 1) x 1e18, which needs a stake of 1e18.
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.StakeLocked.selector);
        vault.unstake(vaultId, STAKE - 1e18 + 1, 0, 0);
        vm.prank(curator);
        vault.unstake(vaultId, STAKE - 1e18, 0, 0);
        assertEq(vault.getVault(vaultId).curatorShares, 1e18);
    }

    /// @dev A stranger cannot lock the curator's stake by depositing a speck.
    function test_unstake_aDustDepositCannotLockTheStake() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _deposit(stranger_(), vaultId, 1);
        vm.prank(curator);
        vault.unstake(vaultId, STAKE - 1, 0, 0);
        assertEq(vault.getVault(vaultId).curatorShares, 1);
    }

    function stranger_() internal returns (address) {
        _fund(stranger);
        return stranger;
    }

    function test_unstake_moreThanTheStakeReverts() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.StakeLocked.selector);
        vault.unstake(vaultId, uint256(STAKE) + 1, 0, 0);
    }

    function test_unstake_theLastShareClosesTheVault() public {
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _deposit(lp, vaultId, 5e18);
        _flow(40);
        _withdraw(lp, vaultId, 5e18);

        vm.prank(curator);
        vault.unstake(vaultId, STAKE, 0, 0);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(v.closedAt, vm.getBlockTimestamp());
        assertEq(v.totalShares, 0);
        assertEq(v.liquidity, 0);
        assertEq(v.idle0, 0);
        assertEq(v.idle1, 0);
        assertEq(_vaultPosition(vaultId, -300, 300), 0);
        assertEq(c0.balanceOf(address(vault)), 0, "nothing left behind, token0");
        assertEq(c1.balanceOf(address(vault)), 0, "nothing left behind, token1");

        vm.prank(curator);
        vm.expectRevert(IProvingGroundVault.VaultIsClosed.selector);
        vault.stake(vaultId, 1e18, MAX, MAX);
        vm.prank(lp);
        vm.expectRevert(IProvingGroundVault.VaultIsClosed.selector);
        vault.deposit(vaultId, 1e18, MAX, MAX);
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -600, 600);
        _rejectsLive(intent, curatorKey, IProvingGroundVault.VaultIsClosed.selector);
    }

    // ------------------------------------------------------------------ two vaults, one contract

    function test_twoVaults_keepSeparateBooks() public {
        uint256 first = _goLive(-300, 300, STAKE);

        (address curator2, uint256 key2) = makeAddrAndKey("curator2");
        key2;
        _fund(curator2);
        uint256 shadow2 = _openAs(curator2, -600, 600, _activeShare(100));
        _flow(40);
        vm.warp(vm.getBlockTimestamp() + MIN_AGE);
        vm.prank(curator2);
        uint256 second = vault.goLive(shadow2, 30e18, MAX, MAX);
        assertEq(_vaultPosition(first, -300, 300), STAKE);
        assertEq(_vaultPosition(second, -600, 600), 30e18);

        _deposit(lp, first, 4e18);
        _deposit(lp2, second, 9e18);
        _flow(60);
        _deposit(lp2, first, 1e18);
        _deposit(lp, second, 1e18);

        // The contract holds exactly the idle balances of the two vaults together.
        IProvingGroundVault.Vault memory a = vault.getVault(first);
        IProvingGroundVault.Vault memory b = vault.getVault(second);
        assertEq(c0.balanceOf(address(vault)), uint256(a.idle0) + b.idle0);
        assertEq(c1.balanceOf(address(vault)), uint256(a.idle1) + b.idle1);
        assertGt(a.idle0 + a.idle1, 0);
        assertGt(b.idle0 + b.idle1, 0);

        // Everyone leaves the first vault. The second is untouched.
        (uint256 held0, uint256 held1) = vault.holdings(second);
        _withdraw(lp, first, 4e18);
        _withdraw(lp2, first, 1e18);
        _withdraw(curator, first, vault.balanceOf(curator, first)); // the curator's fee shares
        vm.prank(curator);
        vault.unstake(first, STAKE, 0, 0);
        b = vault.getVault(second);
        assertEq(c0.balanceOf(address(vault)), b.idle0);
        assertEq(c1.balanceOf(address(vault)), b.idle1);
        (uint256 still0, uint256 still1) = vault.holdings(second);
        assertEq(still0, held0);
        assertEq(still1, held1);

        _withdraw(lp2, second, 9e18);
        _withdraw(lp, second, 1e18);
        _withdraw(curator2, second, vault.balanceOf(curator2, second));
        vm.prank(curator2);
        vault.unstake(second, 30e18, 0, 0);
        assertEq(c0.balanceOf(address(vault)), 0);
        assertEq(c1.balanceOf(address(vault)), 0);
    }
}

/// @notice Moving real liquidity: the signed instruction, the mandate, and what the vault does in the pool.
contract VaultRebalanceTest is VaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal vaultId;

    function setUp() public {
        _start(_vaultConfig());
        vaultId = _goLive(-300, 300, STAKE);
        _deposit(lp, vaultId, 10e18);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
    }

    function _valueAtSpot() internal view returns (uint256) {
        (uint256 amount0, uint256 amount1) = vault.holdings(vaultId);
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        return _in1(amount0, sqrtP) + amount1;
    }

    function test_rebalance_movesRealLiquidityToTheNewRange() public {
        _flow(40);
        uint256 before_ = _valueAtSpot();
        uint256 nonce = hook.nonces(curator);

        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -120, 480);
        bytes memory signature = _sign(curatorKey, intent);
        vm.prank(stranger);
        vault.rebalance(intent, signature);

        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(v.tickLower, -120);
        assertEq(v.tickUpper, 480);
        assertEq(v.rebalances, 1);
        assertEq(v.lastRebalanceAt, vm.getBlockTimestamp());
        assertEq(hook.nonces(curator), nonce + 1, "the intent is spent");
        assertEq(_vaultPosition(vaultId, -300, 300), 0, "old range emptied");
        assertEq(_vaultPosition(vaultId, -120, 480), v.liquidity, "new range filled");
        assertGt(v.liquidity, 0);
        assertEq(v.totalShares, uint256(STAKE) + 10e18, "shares untouched");
        _assertBooksMatchBalances(vaultId);

        // Nearly everything is at work, and the move cost about the pool fee on what was swapped.
        uint256 after_ = _valueAtSpot();
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        uint256 idleValue = _in1(v.idle0, sqrtP) + v.idle1;
        console2.log("  value before:", before_);
        console2.log("  value after: ", after_);
        console2.log("  left idle:   ", idleValue);
        assertLt(after_, before_);
        assertGt(after_ * 10_000, before_ * 9_980, "cost under 20 bps");
        assertLt(idleValue * 100, after_, "under 1% left idle");
    }

    /// @dev The price moved by the vault's own swap is recorded by the hook like any other.
    function test_rebalance_itsSwapGoesThroughTheHooksOracle() public {
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        _rebalanceLive(vaultId, -120, 480);
        (,, uint48 lastTime) = hook.oracleState(idA);
        assertEq(lastTime, vm.getBlockTimestamp());
    }

    function test_rebalance_noSwapNeededWhenTheMixAlreadyFits() public {
        // The same range again: nothing to swap, nothing lost.
        uint256 before_ = _valueAtSpot();
        _rebalanceLive(vaultId, -300, 300);
        assertApproxEqAbs(_valueAtSpot(), before_, 4);
        assertApproxEqRel(vault.getVault(vaultId).liquidity, uint256(STAKE) + 10e18, 1e12);
    }

    function testFuzz_gate_depositThenWithdrawNeverProfits(uint256 shares, uint8 swaps) public {
        _flow(uint256(swaps) % 30);
        shares = bound(shares, 1, STAKE);
        (uint256 paid0, uint256 paid1) = _deposit(lp2, vaultId, shares);
        (uint256 out0, uint256 out1) = _withdraw(lp2, vaultId, shares);
        assertLe(out0, paid0);
        assertLe(out1, paid1);
        assertLe(paid0 - out0, 3);
        assertLe(paid1 - out1, 3);
        _assertBooksMatchBalances(vaultId);
    }

    // ------------------------------------------------------------------ the same mandate as a shadow

    function test_mandate_signatureNonceAndDeadline() public {
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -600, 600);

        (, uint256 otherKey) = makeAddrAndKey("someone else");
        _rejectsLive(intent, otherKey, IProvingGround.BadSignature.selector);

        IProvingGround.RebalanceIntent memory wrongNonce = _liveIntent(vaultId, -600, 600);
        wrongNonce.nonce += 1;
        _rejectsLive(wrongNonce, curatorKey, IProvingGround.BadNonce.selector);

        IProvingGround.RebalanceIntent memory expired = _liveIntent(vaultId, -600, 600);
        expired.deadline = vm.getBlockTimestamp() - 1;
        _rejectsLive(expired, curatorKey, IProvingGround.IntentExpired.selector);

        IProvingGround.RebalanceIntent memory otherPool = _liveIntent(vaultId, -600, 600);
        otherPool.poolId = idB;
        _rejectsLive(otherPool, curatorKey, IProvingGround.WrongPool.selector);

        IProvingGround.RebalanceIntent memory unknown = _liveIntent(vaultId, -600, 600);
        unknown.subjectId = 999;
        _rejectsLive(unknown, curatorKey, IProvingGroundVault.UnknownVault.selector);

        // The honest one works, once.
        bytes memory signature = _sign(curatorKey, intent);
        vault.rebalance(intent, signature);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.expectRevert(IProvingGround.BadNonce.selector);
        vault.rebalance(intent, signature);
    }

    /// @dev An intent says whether it moves a shadow or a vault, and each contract takes only its own kind.
    function test_mandate_shadowAndLiveIntentsAreNotInterchangeable() public {
        IProvingGround.RebalanceIntent memory shadowKind = _liveIntent(vaultId, -600, 600);
        shadowKind.live = false;
        _rejectsLive(shadowKind, curatorKey, IProvingGround.WrongIntentKind.selector);

        IProvingGround.RebalanceIntent memory liveKind = _liveIntent(vaultId, -600, 600);
        bytes memory signature = _sign(curatorKey, liveKind);
        vm.expectRevert(IProvingGround.WrongIntentKind.selector);
        hook.rebalance(liveKind, signature);
    }

    function test_mandate_rangeLimits() public {
        IProvingGround.RebalanceIntent memory narrow = _liveIntent(vaultId, _floorTick(), _floorTick() + 60);
        _rejectsLive(narrow, curatorKey, IProvingGround.RangeTooNarrow.selector);
        IProvingGround.RebalanceIntent memory wide = _liveIntent(vaultId, -6060, 6000);
        _rejectsLive(wide, curatorKey, IProvingGround.RangeTooWide.selector);
        IProvingGround.RebalanceIntent memory offGrid = _liveIntent(vaultId, -301, 300);
        _rejectsLive(offGrid, curatorKey, IProvingGround.RangeNotOnSpacing.selector);
        IProvingGround.RebalanceIntent memory away = _liveIntent(vaultId, 600, 1200);
        _rejectsLive(away, curatorKey, IProvingGround.RangeMustContainTick.selector);

        // The limits themselves are allowed.
        int24 floor_ = _floorTick();
        _rebalanceLive(vaultId, floor_ - 60, floor_ + 60);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        floor_ = _floorTick();
        _rebalanceLive(vaultId, floor_ - 6000, floor_ + 6000);
    }

    function test_mandate_cooldown() public {
        _rebalanceLive(vaultId, -600, 600);
        uint256 readyAt = vm.getBlockTimestamp() + COOLDOWN;
        vm.warp(readyAt - 1);
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -300, 300);
        bytes memory signature = _sign(curatorKey, intent);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.CooldownNotElapsed.selector, readyAt));
        vault.rebalance(intent, signature);
        vm.warp(readyAt);
        vault.rebalance(intent, signature);
    }

    function test_mandate_cooldownCountsFromGoingLive() public {
        uint256 shadow2 = _openAs(lp, -300, 300, _activeShare(100));
        shadow2;
        // A second vault, opened just now by the same curator through a new shadow.
        uint256 next = _openAs(curator, -600, 600, _activeShare(50));
        _flow(40);
        vm.warp(vm.getBlockTimestamp() + MIN_AGE);
        vm.prank(curator);
        vault.goLive(next, STAKE, MAX, MAX);

        uint256 readyAt = vm.getBlockTimestamp() + COOLDOWN;
        IProvingGround.RebalanceIntent memory intent = _liveIntent(next, -300, 300);
        bytes memory signature = _sign(curatorKey, intent);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.CooldownNotElapsed.selector, readyAt));
        vault.rebalance(intent, signature);
    }

    /// @dev The flash-price gate, for real money: a price pushed for the occasion cannot move a vault.
    function test_mandate_aFlashedPriceCannotRebalanceAVault() public {
        int24 twap = hook.twapTick(idA);
        _swap(keyA, false, 60 * unit1);
        int24 spot = _spot();
        assertGt(spot - twap, int24(MAX_DEVIATION));
        int24 mid = (spot / TS) * TS;

        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, mid - 300, mid + 300);
        bytes memory signature = _sign(curatorKey, intent);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.PriceDeviationTooHigh.selector, spot, twap));
        vault.rebalance(intent, signature);
    }

    /// @dev One nonce sequence per curator covers shadow and live intents, so `skipNonce` cancels both.
    function test_mandate_oneNonceSequenceForShadowAndLive() public {
        uint256 shadowId = _openAs(curator, -600, 600, _activeShare(50));
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        uint256 nonce = hook.nonces(curator);

        _rebalanceLive(vaultId, -600, 600);
        assertEq(hook.nonces(curator), nonce + 1);
        _rebalance(shadowId, -300, 300);
        assertEq(hook.nonces(curator), nonce + 2);

        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -300, 300);
        bytes memory signature = _sign(curatorKey, intent);
        vm.prank(curator);
        hook.skipNonce();
        vm.expectRevert(IProvingGround.BadNonce.selector);
        vault.rebalance(intent, signature);
    }

    // ------------------------------------------------------------------ what the vault does in the pool

    /// @dev A narrow range would hold more liquidity than the pool-share cap allows. The vault
    /// places what the cap allows and keeps the rest idle. While it sits at the cap it takes no
    /// deposits; withdrawals are proportional as always.
    function test_rebalance_poolShareCapLeavesTheRestIdle() public {
        _rebalanceLive(vaultId, -6000, 6000);
        vm.prank(curator);
        vault.stake(vaultId, 300e18, MAX, MAX);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);

        uint256 before_ = _valueAtSpot();
        int24 floor_ = _floorTick();
        _rebalanceLive(vaultId, floor_ - 60, floor_ + 60);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        uint256 active = poolManager.getLiquidity(idA);
        assertLe(uint256(v.liquidity) * 10_000, active * 1000, "within 10% of active liquidity");
        assertGt(uint256(v.liquidity) * 10_000, active * 990, "and close to it");
        assertGt(v.idle0, 0);
        assertGt(v.idle1, 0);
        assertApproxEqRel(_valueAtSpot(), before_, 1e14, "no swap was needed, so nothing was lost");
        _assertBooksMatchBalances(vaultId);

        // At the cap there is no room for a deposit, which would have to add to the position.
        vm.prank(lp2);
        vm.expectRevert(IProvingGroundVault.OverPoolShare.selector);
        vault.deposit(vaultId, 3e18, MAX, MAX);

        // More liquidity from others makes room. The round trip then holds with large idle balances.
        _mint(keyA, floor_ - 600, floor_ + 600, 2000 * scale);
        (uint256 paid0, uint256 paid1) = _deposit(lp2, vaultId, 3e18);
        (uint256 out0, uint256 out1) = _withdraw(lp2, vaultId, 3e18);
        assertLe(out0, paid0);
        assertLe(out1, paid1);
        assertLe(paid0 - out0, 3);
        assertLe(paid1 - out1, 3);

        // A withdrawal takes its share of the position and of the idle balances.
        (uint256 held0, uint256 held1) = vault.holdings(vaultId);
        uint256 total = vault.getVault(vaultId).totalShares;
        (out0, out1) = _withdraw(lp, vaultId, 10e18);
        assertApproxEqAbs(out0, held0 * 10e18 / total, 2);
        assertApproxEqAbs(out1, held1 * 10e18 / total, 2);
        _assertBooksMatchBalances(vaultId);
    }

    /// @dev A big one-sided move would push the price past the mandate's bound. The vault's swap
    /// stops at the bound and the unswapped tokens stay idle.
    function test_rebalance_ownSwapStopsAtThePriceBound() public {
        _rebalanceLive(vaultId, -6000, 6000);
        vm.prank(curator);
        vault.stake(vaultId, 3000e18, MAX, MAX);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        int24 twap = hook.twapTick(idA);
        int24 lo = _floorTick();
        uint256 before_ = _valueAtSpot();

        // The new range sits almost entirely above the price, so the vault must buy a lot of token0.
        _rebalanceLive(vaultId, lo, lo + 6000);
        int24 spot = _spot();
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        console2.log("  tick before the rebalance:", twap);
        console2.log("  tick after it:            ", spot);
        console2.log("  vault value:              ", before_);
        console2.log("  idle token1 left:         ", v.idle1);
        assertGe(spot - twap, int24(MAX_DEVIATION) - 1, "its swap ran up to the bound");
        assertLe(spot - twap, int24(MAX_DEVIATION), "and stopped there");
        assertGe(spot, v.tickLower);
        assertLt(spot, v.tickUpper);
        assertGt(uint256(v.idle1) * 100, before_, "what could not be swapped stayed idle: over 1% of the vault");
        assertEq(_vaultPosition(vaultId, lo, lo + 6000), v.liquidity);
        _assertBooksMatchBalances(vaultId);
    }

    /// @dev Runs in isolation mode: every call is its own transaction, so storage is priced as on-chain.
    /// forge-config: default.isolate = true
    function test_gas_vaultOperations() public {
        vm.prank(lp2);
        vault.deposit(vaultId, 5e18, MAX, MAX);
        uint256 firstDeposit = vm.lastCallGas().gasTotalUsed;
        vm.prank(lp);
        vault.deposit(vaultId, 1e18, MAX, MAX);
        uint256 deposit = vm.lastCallGas().gasTotalUsed;
        vm.prank(lp);
        vault.withdraw(vaultId, 1e18, 0, 0);
        uint256 withdraw = vm.lastCallGas().gasTotalUsed;

        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -120, 480);
        bytes memory signature = _sign(curatorKey, intent);
        vault.rebalance(intent, signature);
        uint256 rebalance = vm.lastCallGas().gasTotalUsed;

        _flow(80);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        assertGt(vault.standing(vaultId).feeSharesDue, 0);
        vm.prank(stranger);
        vault.settleFee(vaultId);
        uint256 settle = vm.lastCallGas().gasTotalUsed;

        console2.log("  deposit, first by this address:", firstDeposit);
        console2.log("  deposit, later:                ", deposit);
        console2.log("  withdraw:                      ", withdraw);
        console2.log("  rebalance with a swap:         ", rebalance);
        console2.log("  settle the fee:                ", settle);
        vm.snapshotValue("vault", "deposit, first by an address", firstDeposit);
        vm.snapshotValue("vault", "deposit", deposit);
        vm.snapshotValue("vault", "withdraw", withdraw);
        vm.snapshotValue("vault", "rebalance with a swap", rebalance);
        vm.snapshotValue("vault", "settle fee", settle);
    }

    function testFuzz_rebalance_booksAlwaysMatchBalances(int24 lowerSteps, uint24 widthSteps, uint8 swaps) public {
        _randomFlow(uint256(swaps) % 25);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        int24 floor_ = _floorTick();
        int24 width = int24(uint24(bound(widthSteps, 2, 200))) * TS;
        int24 offset = int24(bound(lowerSteps, 0, width / TS - 1)) * TS;
        int24 lo = floor_ - offset;

        uint256 before_ = _valueAtSpot();
        _rebalanceLive(vaultId, lo, lo + width);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(_vaultPosition(vaultId, lo, lo + width), v.liquidity);
        _assertBooksMatchBalances(vaultId);
        assertGe(_valueAtSpot() * 10_000, before_ * 9_950, "never more than the allowed loss");

        // And everyone can still get out.
        _withdraw(lp, vaultId, 10e18);
        vm.prank(curator);
        vault.unstake(vaultId, STAKE, 0, 0);
        assertEq(c0.balanceOf(address(vault)), 0);
        assertEq(c1.balanceOf(address(vault)), 0);
    }

    function test_rebalance_emptyVaultHasNothingToPlace() public {
        _withdraw(lp, vaultId, 10e18);
        vm.prank(curator);
        vault.unstake(vaultId, STAKE - 1, 0, 0);
        // One share of stake is left, worth less than a unit of liquidity on a wide range.
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, -6000, 6000);
        _rejectsLive(intent, curatorKey, IProvingGroundVault.NothingToPlace.selector);
    }
}

/// @notice The fifth mandate check: a rebalance may not lose more than the limit.
contract VaultLossLimitTest is VaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal vaultId;

    function setUp() public {
        IProvingGroundVault.VaultConfig memory config = _vaultConfig();
        config.maxRebalanceLossBps = 25;
        _start(config);
        vaultId = _goLive(-300, 300, STAKE);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
    }

    /// @dev The range the curator signs: almost entirely above the price, so close to half the vault
    /// has to be swapped into token0.
    function _oneSidedIntent() internal view returns (IProvingGround.RebalanceIntent memory) {
        int24 floor_ = _floorTick();
        return _liveIntent(vaultId, floor_, floor_ + 600);
    }

    /// @dev Someone who sees the signed intent pushes the price against the vault, staying inside
    /// the mandate's price bound, and submits. The vault would buy at the pushed price; the loss
    /// check, measured at the time-weighted price, refuses.
    function test_lossLimit_aSandwichedRebalanceReverts() public {
        IProvingGround.RebalanceIntent memory intent = _oneSidedIntent();
        bytes memory signature = _sign(curatorKey, intent);

        uint256 snapshot = vm.snapshotState();
        vault.rebalance(intent, signature);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertGt(v.liquidity, 0, "left alone, the rebalance is within the limit");
        vm.revertToState(snapshot);

        int24 twap = hook.twapTick(idA);
        _swap(keyA, false, 20 * unit1);
        int24 pushed = _spot();
        console2.log("  price pushed by (ticks):", pushed - twap);
        assertGt(pushed - twap, 60);
        assertLe(pushed - twap, int24(MAX_DEVIATION), "inside the price bound, so that check passes");

        vm.expectPartialRevert(IProvingGroundVault.RebalanceLossTooHigh.selector);
        vault.rebalance(intent, signature);
    }
}

/// @notice The performance fee: a share of what the vault gains on its benchmark, above a high-water mark.
contract VaultFeeTest is VaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant ONE = 1e18;
    uint256 internal vaultId;

    function setUp() public {
        _start(_vaultConfig());
        vaultId = _goLive(-300, 300, STAKE);
        _deposit(lp, vaultId, 10e18);
    }

    function _mark() internal view returns (uint256) {
        return vault.getVault(vaultId).highWaterMark;
    }

    /// @dev The fee the rule prescribes: shares worth 10% x (1 - mark / ratio) of the vault.
    function _expectedFee(uint256 ratio, uint256 mark, uint256 supply)
        internal
        pure
        returns (uint256 feeShares, uint256 fraction)
    {
        if (ratio <= mark) return (0, 0);
        fraction = (ONE / 10) * (ratio - mark) / ratio;
        feeShares = supply * fraction / (ONE - fraction);
    }

    function test_fee_startsLevelWithNothingDue() public {
        assertEq(_mark(), ONE);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        assertApproxEqAbs(st.valueRatio, ONE, 1e6);
        assertEq(st.feeSharesDue, 0);
        assertEq(vault.settleFee(vaultId), 0);
        assertEq(vault.balanceOf(curator, vaultId), 0);
        assertEq(_mark(), ONE);
    }

    function test_fee_paidOnTheGainOverTheBenchmark() public {
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        uint256 supply = vault.getVault(vaultId).totalShares;
        (uint256 held0, uint256 held1) = vault.holdings(vaultId);
        assertGt(st.valueRatio, ONE, "the vault is ahead of its benchmark");
        (uint256 expected, uint256 fraction) = _expectedFee(st.valueRatio, ONE, supply);
        assertEq(st.feeSharesDue, expected);

        // Anyone can settle it. The shares go to the curator.
        vm.prank(stranger);
        uint256 feeShares = vault.settleFee(vaultId);
        assertEq(feeShares, expected);
        assertEq(vault.balanceOf(curator, vaultId), feeShares);
        assertEq(vault.balanceOf(stranger, vaultId), 0);
        assertEq(vault.getVault(vaultId).totalShares, supply + feeShares);
        assertEq(vault.getVault(vaultId).curatorShares, STAKE, "the fee is not stake");

        // Nothing left the vault: the fee is a claim on it, worth 10% of the gain over the mark.
        (uint256 after0, uint256 after1) = vault.holdings(vaultId);
        assertEq(after0, held0);
        assertEq(after1, held1);
        uint256 feeValue = st.nav * feeShares / (supply + feeShares);
        assertApproxEqRel(feeValue, st.nav * (st.valueRatio - ONE) / st.valueRatio / 10, 1e9);

        // The mark moves to where the vault stands after paying, and nothing more is due.
        IProvingGroundVault.Standing memory post = vault.standing(vaultId);
        assertApproxEqAbs(_mark(), st.valueRatio * (ONE - fraction) / ONE, 1e3);
        assertApproxEqAbs(post.valueRatio, _mark(), 2);
        assertEq(post.feeSharesDue, 0);
        assertEq(vault.settleFee(vaultId), 0);
        assertLt(post.liveAlphaBps, st.liveAlphaBps, "depositors' score is net of the fee");

        console2.log("  score before the fee (bps):", st.liveAlphaBps);
        console2.log("  score after the fee (bps): ", post.liveAlphaBps);
        console2.log("  fee, share of the vault (1e18 = all):", fraction);
    }

    /// @dev A fall and a recovery over ground already paid for earn nothing. Only a new high does.
    function test_fee_neverTwiceForTheSameGround() public {
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        uint256 first = vault.settleFee(vaultId);
        assertGt(first, 0);
        uint256 mark = _mark();

        // The price leaves the range: the vault falls behind its benchmark.
        _swapBoth(true, 60e18);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        IProvingGroundVault.Standing memory down = vault.standing(vaultId);
        assertLt(down.valueRatio, mark);
        assertEq(down.feeSharesDue, 0);
        assertEq(vault.settleFee(vaultId), 0);
        assertEq(_mark(), mark, "the mark does not come down");

        // The price comes back. Whatever is due is measured from the mark, not from the low.
        _swapBoth(false, 55e18);
        _flow(40);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        IProvingGroundVault.Standing memory back = vault.standing(vaultId);
        assertGt(back.valueRatio, down.valueRatio, "recovered");
        uint256 supply = vault.getVault(vaultId).totalShares;
        (uint256 fromMark,) = _expectedFee(back.valueRatio, mark, supply);
        (uint256 fromLow,) = _expectedFee(back.valueRatio, down.valueRatio, supply);
        uint256 second = vault.settleFee(vaultId);
        assertEq(second, fromMark);
        assertLt(second, fromLow, "the recovery itself is not paid for");
        assertGe(_mark(), mark);
        console2.log("  ratio at first fee, low, after recovery:", mark, down.valueRatio, back.valueRatio);
        console2.log("  fee shares: first, second:", first, second);
    }

    /// @dev A deposit settles the fee before the newcomer's shares are counted, so gains made before
    /// they arrived are charged to those who were there.
    function test_fee_aDepositSettlesItFirst() public {
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        uint256 due = vault.standing(vaultId).feeSharesDue;
        assertGt(due, 0);

        (uint256 quote0, uint256 quote1) = vault.quoteDeposit(vaultId, 5e18);
        (uint256 paid0, uint256 paid1) = _deposit(lp2, vaultId, 5e18);
        assertEq(paid0, quote0);
        assertEq(paid1, quote1);
        assertEq(vault.balanceOf(curator, vaultId), due);
        assertEq(vault.standing(vaultId).feeSharesDue, 0);

        // The newcomer can leave at once with what they brought.
        (uint256 out0, uint256 out1) = _withdraw(lp2, vaultId, 5e18);
        assertLe(paid0 - out0, 3);
        assertLe(paid1 - out1, 3);
    }

    /// @dev A withdrawal never touches the oracle, so it does not settle the fee.
    function test_fee_aWithdrawalDoesNotSettleIt() public {
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        assertGt(vault.standing(vaultId).feeSharesDue, 0);
        _withdraw(lp, vaultId, 10e18);
        assertEq(vault.balanceOf(curator, vaultId), 0);
        assertEq(_mark(), ONE);
        assertGt(vault.standing(vaultId).feeSharesDue, 0, "still due, on what remains");
    }

    function test_fee_sharesAreOrdinarySharesTheCuratorCanRedeem() public {
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        uint256 feeShares = vault.settleFee(vaultId);
        assertEq(vault.outsideShares(vaultId), 10e18 + feeShares);

        (uint256 held0, uint256 held1) = vault.holdings(vaultId);
        uint256 supply = vault.getVault(vaultId).totalShares;
        (uint256 out0, uint256 out1) = _withdraw(curator, vaultId, feeShares);
        assertApproxEqAbs(out0, held0 * feeShares / supply, 2);
        assertApproxEqAbs(out1, held1 * feeShares / supply, 2);
        assertGt(out0 + out1, 0);
        _assertBooksMatchBalances(vaultId);
    }

    function test_fee_guards() public {
        vm.expectRevert(IProvingGroundVault.UnknownVault.selector);
        vault.settleFee(999);

        _withdraw(lp, vaultId, 10e18);
        vm.prank(curator);
        vault.unstake(vaultId, STAKE, 0, 0);
        vm.expectRevert(IProvingGroundVault.VaultIsClosed.selector);
        vault.settleFee(vaultId);
    }

    function testFuzz_fee_followsTheRuleAndTheMarkOnlyRises(uint8 swaps, uint8 drift, uint8 more) public {
        _flow(20 + uint256(swaps) % 100);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        for (uint256 round; round < 3; ++round) {
            IProvingGroundVault.Standing memory st = vault.standing(vaultId);
            uint256 mark = _mark();
            uint256 supply = vault.getVault(vaultId).totalShares;
            (uint256 expected,) = _expectedFee(st.valueRatio, mark, supply);

            uint256 feeShares = vault.settleFee(vaultId);
            assertEq(feeShares, expected);
            if (st.valueRatio <= mark) assertEq(feeShares, 0, "nothing at or below the mark");
            assertGe(_mark(), mark, "the mark only rises");
            IProvingGroundVault.Standing memory post = vault.standing(vaultId);
            assertEq(post.feeSharesDue, 0, "nothing more is due right after");
            if (feeShares != 0) {
                assertApproxEqAbs(post.valueRatio, _mark(), 2, "the mark is where the vault now stands");
            }

            // Something happens before the next round: a drift out and back, or more in-range flow.
            if (round == 0) {
                _swapBoth(drift % 2 == 0, (5 + uint256(drift) % 40) * 1e18);
            } else {
                _flow(uint256(more) % 60);
            }
            vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        }
    }
}

/// @notice With the fee set to zero, nothing is ever minted to the curator.
contract VaultNoFeeTest is VaultBase {
    function test_noFee_nothingIsEverDue() public {
        IProvingGroundVault.VaultConfig memory config = _vaultConfig();
        config.perfFeeBps = 0;
        _start(config);
        uint256 vaultId = _goLive(-300, 300, STAKE);
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        assertGt(st.valueRatio, 1e18);
        assertEq(st.feeSharesDue, 0);
        assertEq(vault.settleFee(vaultId), 0);
        _deposit(lp, vaultId, 5e18);
        assertEq(vault.balanceOf(curator, vaultId), 0);
    }
}
