// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";
import {VaultBase} from "./Vault.t.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IProvingGround} from "../src/interfaces/IProvingGround.sol";
import {IProvingGroundVault} from "../src/interfaces/IProvingGroundVault.sol";

/// @notice The whole life of a curator, start to finish, printed as a story:
///   forge test --match-test test_walkthrough -vv
/// A shadow is opened and scored, moved by a signed instruction, refused when the instruction breaks
/// the mandate, graduated into a live vault, joined by a depositor, rebalanced for real, charged a
/// fee, and exited.
contract WalkthroughTest is VaultBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _start(_vaultConfig());
    }

    // ------------------------------------------------------------------ printing

    /// @dev A token amount with four decimals.
    function _amt(uint256 amount) internal pure returns (string memory) {
        uint256 frac = (amount % 1e18) / 1e14;
        string memory digits = vm.toString(frac);
        while (bytes(digits).length < 4) digits = string.concat("0", digits);
        return string.concat(vm.toString(amount / 1e18), ".", digits);
    }

    function _bps(int256 bps) internal pure returns (string memory) {
        return string.concat(bps > 0 ? "+" : "", vm.toString(bps), " bps");
    }

    function _step(string memory title) internal pure {
        console2.log("");
        console2.log(string.concat("== ", title));
    }

    function _line(string memory label, string memory value) internal pure {
        console2.log(string.concat("   ", label, " ", value));
    }

    function _value(uint256 amount0, uint256 amount1) internal view returns (uint256) {
        (uint160 sqrtP,,,) = poolManager.getSlot0(idA);
        return _in1(amount0, sqrtP) + amount1;
    }

    // ------------------------------------------------------------------ the story

    function test_walkthrough() public {
        _step("1. A curator opens a shadow position: no capital, only a bond");
        uint128 size = _activeShare(100);
        uint256 shadowId = _openAs(curator, -300, 300, size);
        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        _line("range (ticks):", "-300 to 300");
        _line("virtual liquidity:", string.concat(_amt(size), " (1% of the pool's active liquidity)"));
        _line("what it would hold, token0 / token1:", string.concat(_amt(s.hold0), " / ", _amt(s.hold1)));
        _line("bond locked (ETH):", _amt(s.bond));

        _step("2. Other people trade in the pool: 120 swaps");
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        IProvingGround.Score memory sc = hook.score(shadowId);
        _line("shadow value, conservative:", _amt(sc.navConservative));
        _line("shadow value, raw:", _amt(sc.navRaw));
        _line("passive full-range position:", _amt(sc.navBenchmark));
        _line("simply holding the tokens:", _amt(sc.navHold));
        _line("score against the passive position:", _bps(sc.alphaBps));
        assertGt(sc.alphaBps, 0);

        _step("3. The curator signs an instruction; a keeper submits it");
        int24 floor_ = _floorTick();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, floor_ - 240, floor_ + 240);
        bytes memory signature = _sign(curatorKey, intent);
        vm.prank(keeper);
        hook.rebalance(intent, signature);
        sc = hook.score(shadowId);
        _line(
            "moved to (ticks):",
            string.concat(vm.toString(int256(floor_ - 240)), " to ", vm.toString(int256(floor_ + 240)))
        );
        _line("modelled cost of the move:", _amt(sc.rebalanceCost));
        _line("score after the move:", _bps(sc.alphaBps));

        _step("4. Instructions outside the mandate are refused");
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        intent = _intent(shadowId, floor_, floor_ + 60);
        signature = _sign(curatorKey, intent);
        vm.expectRevert(IProvingGround.RangeTooNarrow.selector);
        hook.rebalance(intent, signature);
        _line("a 60-tick range:", "refused, RangeTooNarrow");

        uint256 snapshot = vm.snapshotState();
        _swap(keyA, false, 60 * unit1);
        int24 pushed = _floorTick();
        intent = _intent(shadowId, pushed - 300, pushed + 300);
        signature = _sign(curatorKey, intent);
        vm.expectPartialRevert(IProvingGround.PriceDeviationTooHigh.selector);
        hook.rebalance(intent, signature);
        _line(
            "a rebalance at a price pushed for one transaction:",
            string.concat("refused, PriceDeviationTooHigh (", vm.toString(int256(_spot() - floor_)), " ticks off)")
        );
        vm.revertToState(snapshot);

        intent = _intent(shadowId, floor_ - 300, floor_ + 300);
        (, uint256 strangerKey) = makeAddrAndKey("not the curator");
        signature = _sign(strangerKey, intent);
        vm.expectRevert(IProvingGround.BadSignature.selector);
        hook.rebalance(intent, signature);
        _line("an instruction signed by someone else:", "refused, BadSignature");

        _step("5. Seven days on, the curator goes live with their own money");
        vm.warp(uint256(s.openedAt) + MIN_AGE);
        sc = hook.score(shadowId);
        uint256 eth = curator.balance;
        vm.prank(curator);
        uint256 vaultId = vault.goLive(shadowId, STAKE, MAX, MAX);
        IProvingGroundVault.Standing memory st = vault.standing(vaultId);
        (uint256 held0, uint256 held1) = vault.holdings(vaultId);
        _line("final shadow score:", _bps(sc.alphaBps));
        _line("bond returned (ETH):", _amt(curator.balance - eth));
        _line("curator's stake, token0 / token1:", string.concat(_amt(held0), " / ", _amt(held1)));
        _line("multiple earned by the score:", string.concat(vm.toString(st.multiple), "x"));
        _line(
            "room for outside money:",
            string.concat(vm.toString((st.maxTotalShares - STAKE) * 100 / STAKE), "% of the curator's stake")
        );

        _step("6. A depositor joins, in kind");
        uint256 shares = STAKE;
        (uint256 paid0, uint256 paid1) = _deposit(lp, vaultId, shares);
        _line("paid in, token0 / token1:", string.concat(_amt(paid0), " / ", _amt(paid1)));
        _line("share of the vault:", "50%");

        _step("7. More trading: 120 swaps. The vault earns real fees");
        _flow(120);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        st = vault.standing(vaultId);
        _line("vault value:", _amt(st.nav));
        _line("passive benchmark:", _amt(st.navBenchmark));
        _line("vault score:", _bps(st.liveAlphaBps));

        _step("8. The curator moves the real liquidity, again by signed instruction");
        floor_ = _floorTick();
        intent = _liveIntent(vaultId, floor_ - 180, floor_ + 240);
        signature = _sign(curatorKey, intent);
        (held0, held1) = vault.holdings(vaultId);
        uint256 before_ = _value(held0, held1);
        vm.prank(keeper);
        vault.rebalance(intent, signature);
        (held0, held1) = vault.holdings(vaultId);
        uint256 after_ = _value(held0, held1);
        IProvingGroundVault.Vault memory v = vault.getVault(vaultId);
        _line(
            "moved to (ticks):",
            string.concat(vm.toString(int256(v.tickLower)), " to ", vm.toString(int256(v.tickUpper)))
        );
        _line("value before / after:", string.concat(_amt(before_), " / ", _amt(after_)));
        _line("cost of the move:", _bps(-int256((before_ - after_) * 10_000 / before_)));
        _line("left idle, token0 / token1 (wei):", string.concat(vm.toString(v.idle0), " / ", vm.toString(v.idle1)));

        _step("9. The curator's fee: 10% of the gain over the passive position, nothing else");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        st = vault.standing(vaultId);
        uint256 feeShares = vault.settleFee(vaultId);
        IProvingGroundVault.Standing memory post = vault.standing(vaultId);
        _line("score before the fee:", _bps(st.liveAlphaBps));
        uint256 millionths = feeShares * 1e6 / (2 * uint256(STAKE) + feeShares);
        string memory decimals = vm.toString(millionths % 10_000);
        while (bytes(decimals).length < 4) decimals = string.concat("0", decimals);
        _line("fee, as a share of the vault:", string.concat(vm.toString(millionths / 10_000), ".", decimals, "%"));
        _line("score after the fee:", _bps(post.liveAlphaBps));
        assertEq(vault.settleFee(vaultId), 0);
        _line("settling again straight away:", "nothing due");

        _step("10. The depositor leaves. No one's permission is needed");
        (uint256 out0, uint256 out1) = _withdraw(lp, vaultId, shares);
        _line("received, token0 / token1:", string.concat(_amt(out0), " / ", _amt(out1)));
        uint256 valueOut = _value(out0, out1);
        uint256 valueIn = _value(paid0, paid1);
        _line("against simply holding what they paid in:", _bps(int256(valueOut * 10_000 / valueIn) - 10_000));
        assertGt(valueOut, valueIn, "the depositor came out ahead of holding");
        _assertBooksMatchBalances(vaultId);
        console2.log("");
    }
}
