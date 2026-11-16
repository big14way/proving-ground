// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VaultBase} from "./Vault.t.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IProvingGround} from "../src/interfaces/IProvingGround.sol";
import {IProvingGroundVault} from "../src/interfaces/IProvingGroundVault.sol";

/// @notice Properties that must hold after any sequence of actions by depositors, the curator,
/// traders and whoever submits signed instructions.
/// @dev The fuzzer calls the `act_` functions below in random order with random arguments. One live
/// vault and one shadow (of a second curator) share the pool. Calls that the contracts reject are
/// simply skipped, except withdrawals, which must never be rejected.
contract ProvingGroundInvariantTest is VaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal vaultId;
    address internal curator2;
    uint256 internal key2;
    uint256 internal shadow2;

    // What the run has seen so far.
    uint256 internal lastMark = 1e18;
    bool internal markFell;
    bool internal feeTakenAtOrBelowTheMark;
    bool internal withdrawalRejected;
    uint256 internal feesTaken;

    function setUp() public {
        _start(_vaultConfig());
        vaultId = _goLive(-300, 300, STAKE);
        (curator2, key2) = makeAddrAndKey("curator2");
        shadow2 = _openAs(curator2, -600, 600, _shadowSize());
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = this.act_deposit.selector;
        selectors[1] = this.act_withdraw.selector;
        selectors[2] = this.act_stake.selector;
        selectors[3] = this.act_unstake.selector;
        selectors[4] = this.act_swap.selector;
        selectors[5] = this.act_wait.selector;
        selectors[6] = this.act_rebalanceVault.selector;
        selectors[7] = this.act_rebalanceShadow.selector;
        selectors[8] = this.act_settleFee.selector;
        selectors[9] = this.act_reopenShadow.selector;
        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    // ------------------------------------------------------------------ actions

    function act_deposit(uint256 who, uint256 shares) external {
        address actor = who % 2 == 0 ? lp : lp2;
        shares = bound(shares, 1, 30e18);
        (uint256 mark, uint256 ratio) = _feeState();
        vm.prank(actor);
        try vault.deposit(vaultId, shares, MAX, MAX) {} catch {}
        _noteFee(mark, ratio);
    }

    function act_withdraw(uint256 who, uint256 shares) external {
        address actor = who % 3 == 0 ? lp : who % 3 == 1 ? lp2 : curator;
        uint256 balance = vault.balanceOf(actor, vaultId);
        if (balance == 0) return;
        shares = bound(shares, 1, balance);
        vm.prank(actor);
        try vault.withdraw(vaultId, shares, 0, 0) {}
        catch {
            withdrawalRejected = true;
        }
    }

    function act_stake(uint256 shares) external {
        shares = bound(shares, 1, 40e18);
        vm.prank(curator);
        try vault.stake(vaultId, shares, MAX, MAX) {} catch {}
    }

    /// @dev Never the whole stake, so the vault stays open for the rest of the run.
    function act_unstake(uint256 shares) external {
        uint256 staked = vault.getVault(vaultId).curatorShares;
        if (staked <= 1e18) return;
        shares = bound(shares, 1, staked - 1e18);
        vm.prank(curator);
        try vault.unstake(vaultId, shares, 0, 0) {} catch {}
    }

    /// @dev A swap in a new block. The price wanders but is steered back when it strays far.
    function act_swap(uint256 units, bool direction) external {
        vm.warp(vm.getBlockTimestamp() + BLOCK_TIME);
        int24 tick = _spot();
        bool zeroForOne = tick > 900 ? true : tick < -900 ? false : direction;
        _swap(keyA, zeroForOne, bound(units, 1e17, 25e18) * (zeroForOne ? unit0 : unit1) / 1e18);
    }

    function act_wait(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, BLOCK_TIME, 3 hours));
    }

    function act_rebalanceVault(uint256 offsetSteps, uint256 widthSteps) external {
        (int24 lo, int24 hi) = _rangeAroundSpot(offsetSteps, widthSteps);
        IProvingGround.RebalanceIntent memory intent = _liveIntent(vaultId, lo, hi);
        bytes memory signature = _sign(curatorKey, intent);
        try vault.rebalance(intent, signature) {} catch {}
    }

    function act_rebalanceShadow(uint256 offsetSteps, uint256 widthSteps) external {
        (int24 lo, int24 hi) = _rangeAroundSpot(offsetSteps, widthSteps);
        IProvingGround.RebalanceIntent memory intent = _intent(shadow2, lo, hi);
        bytes memory signature = _sign(key2, intent);
        try hook.rebalance(intent, signature) {} catch {}
    }

    function act_settleFee() external {
        (uint256 mark, uint256 ratio) = _feeState();
        try vault.settleFee(vaultId) {} catch {}
        _noteFee(mark, ratio);
    }

    /// @dev The second curator abandons their shadow and opens another. An early close leaves the
    /// bond locked in the hook.
    function act_reopenShadow() external {
        vm.prank(curator2);
        hook.closeShadow(shadow2);
        int24 floor_ = _floorTick();
        shadow2 = _openAs(curator2, floor_ - 600, floor_ + 600, _shadowSize());
    }

    // ------------------------------------------------------------------ helpers

    function _shadowSize() internal view returns (uint128) {
        return uint128(uint256(poolManager.getLiquidity(idA)) * 30 / 10_000);
    }

    function _rangeAroundSpot(uint256 offsetSteps, uint256 widthSteps) internal view returns (int24 lo, int24 hi) {
        int24 width = int24(uint24(bound(widthSteps, 2, 200))) * TS;
        int24 offset = int24(uint24(bound(offsetSteps, 0, uint256(uint24(width / TS)) - 1))) * TS;
        lo = _floorTick() - offset;
        hi = lo + width;
    }

    function _feeState() internal view returns (uint256 mark, uint256 ratio) {
        mark = vault.getVault(vaultId).highWaterMark;
        try vault.standing(vaultId) returns (IProvingGroundVault.Standing memory st) {
            ratio = st.valueRatio;
        } catch {}
    }

    /// @dev The mark changes only when a fee is taken.
    function _noteFee(uint256 markBefore, uint256 ratioBefore) internal {
        uint256 mark = vault.getVault(vaultId).highWaterMark;
        if (mark == markBefore) return;
        feesTaken += 1;
        if (ratioBefore <= markBefore) feeTakenAtOrBelowTheMark = true;
        if (mark < markBefore) markFell = true;
        lastMark = mark;
    }

    // ------------------------------------------------------------------ invariants

    /// @dev The vault holds exactly the idle tokens on its books, its position in the pool is the
    /// liquidity on its books, and the shares add up to the total.
    function invariant_vaultBooksMatchRealityAndSharesAddUp() public view {
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(c0.balanceOf(address(vault)), v.idle0, "token0 held equals idle0");
        assertEq(c1.balanceOf(address(vault)), v.idle1, "token1 held equals idle1");
        assertEq(_vaultPosition(vaultId, v.tickLower, v.tickUpper), v.liquidity, "position equals the books");
        assertEq(
            v.totalShares,
            v.curatorShares + vault.balanceOf(lp, vaultId) + vault.balanceOf(lp2, vaultId)
                + vault.balanceOf(curator, vaultId),
            "shares add up"
        );
        assertFalse(withdrawalRejected, "a withdrawal was rejected");
    }

    /// @dev A fee is only ever taken above the high-water mark, and the mark never comes down.
    function invariant_feeOnlyAboveTheMarkAndTheMarkOnlyRises() public view {
        assertFalse(feeTakenAtOrBelowTheMark, "fee taken at or below the mark");
        assertFalse(markFell, "the mark fell");
        assertGe(vault.getVault(vaultId).highWaterMark, 1e18);
        assertEq(vault.getVault(vaultId).highWaterMark, lastMark);
    }

    /// @dev The hook holds exactly its dust reserve in tokens and exactly the unreturned bonds in ETH.
    function invariant_hookHoldsItsDustReserveAndEveryBond() public view {
        assertEq(hook.dustReserve(c0), c0.balanceOf(address(hook)), "reserve0 equals the hook's balance");
        assertEq(hook.dustReserve(c1), c1.balanceOf(address(hook)), "reserve1 equals the hook's balance");
        uint256 bonds;
        uint256 count = hook.shadowCount();
        for (uint256 id = 1; id <= count; ++id) {
            bonds += hook.getShadow(id).bond;
        }
        assertEq(address(hook).balance, bonds, "ETH held equals the bonds owed");
    }

    /// @dev At the end of every run, everyone redeems everything. The vault must pay it all out and
    /// be left with nothing: no share is worth more than what backs it.
    function afterInvariant() public {
        _exitAll(lp);
        _exitAll(lp2);
        _exitAll(curator);
        uint256 staked = vault.getVault(vaultId).curatorShares;
        vm.prank(curator);
        vault.unstake(vaultId, staked, 0, 0);

        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        assertEq(v.totalShares, 0);
        assertEq(v.liquidity, 0);
        assertGt(v.closedAt, 0);
        assertEq(_vaultPosition(vaultId, v.tickLower, v.tickUpper), 0);
        assertEq(c0.balanceOf(address(vault)), 0, "nothing left behind, token0");
        assertEq(c1.balanceOf(address(vault)), 0, "nothing left behind, token1");
    }

    function _exitAll(address who) internal {
        uint256 balance = vault.balanceOf(who, vaultId);
        if (balance != 0) _withdraw(who, vaultId, balance);
    }
}
