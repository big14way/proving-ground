// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {TwinPools} from "./utils/TwinPools.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ProvingGroundHook} from "../src/ProvingGroundHook.sol";
import {IProvingGround} from "../src/interfaces/IProvingGround.sol";
import {Mandate} from "../src/libraries/Mandate.sol";
import {Oracle} from "../src/libraries/Oracle.sol";

/// @notice The signed rebalance instruction and the mandate it is checked against, exercised
/// through the hook. Every check has a case that passes at the limit and one that reverts beyond it.
contract MandateTest is TwinPools {
    using StateLibrary for IPoolManager;

    address internal stranger = makeAddr("stranger");
    uint256 internal shadowId;

    function setUp() public {
        _setUpTwin(18, 18, 0, 1e18, _config(100));
        shadowId = _openAs(curator, -300, 300, _activeShare(100));
    }

    /// @dev Lets the oracle window fill, which also clears the cooldown.
    function _ready() internal {
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
    }

    function _spot() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(idA);
    }

    /// @dev Signs first: the signing helper calls the hook, and `expectRevert` must sit directly
    /// before the call that is meant to revert.
    function _rejects(IProvingGround.RebalanceIntent memory intent, uint256 signerKey, bytes4 selector) internal {
        bytes memory signature = _sign(signerKey, intent);
        vm.expectRevert(selector);
        hook.rebalance(intent, signature);
    }

    // ------------------------------------------------------------------ check 1: signature

    /// @dev The digest is rebuilt here from the EIP-712 definition, without using the hook's code.
    function test_intent_digestFollowsEIP712() public view {
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("ProvingGround"),
                keccak256("1"),
                block.chainid,
                address(hook)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "RebalanceIntent(bytes32 poolId,uint256 subjectId,bool live,int24 tickLower,int24 tickUpper,uint256 nonce,uint256 deadline)"
                ),
                PoolId.unwrap(intent.poolId),
                intent.subjectId,
                intent.live,
                int256(intent.tickLower), // a negative tick is sign-extended to 32 bytes
                int256(intent.tickUpper),
                intent.nonce,
                intent.deadline
            )
        );
        assertEq(hook.intentDigest(intent), keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash)));
    }

    function test_intent_anyoneCanSubmitWhatTheCuratorSigned() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);

        vm.expectEmit(true, true, false, true, address(hook));
        emit IProvingGround.IntentUsed(curator, 0, stranger);
        vm.prank(stranger);
        hook.rebalance(intent, signature);

        IProvingGround.Shadow memory s = hook.getShadow(shadowId);
        assertEq(s.tickLower, -600);
        assertEq(s.tickUpper, 600);
        assertEq(s.rebalances, 1);
        assertEq(hook.nonces(curator), 1);
    }

    function test_intent_signedBySomeoneElseReverts() public {
        _ready();
        (, uint256 otherKey) = makeAddrAndKey("not the curator");
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        _rejects(intent, otherKey, IProvingGround.BadSignature.selector);
    }

    function test_intent_changedAfterSigningReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);

        intent.tickUpper = 660;
        vm.expectRevert(IProvingGround.BadSignature.selector);
        hook.rebalance(intent, signature);

        intent.tickUpper = 600;
        intent.deadline += 1 days;
        vm.expectRevert(IProvingGround.BadSignature.selector);
        hook.rebalance(intent, signature);
    }

    function test_intent_malformedSignatureReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        vm.expectRevert(IProvingGround.BadSignature.selector);
        hook.rebalance(intent, hex"1234");
    }

    function test_intent_signedForAnotherChainReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(IProvingGround.BadSignature.selector);
        hook.rebalance(intent, signature);
    }

    function test_intent_signedForAnotherHookReverts() public {
        _ready();
        ProvingGroundHook other = _deployHook(0x6666, _config(100));
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorKey, other.intentDigest(intent));
        vm.expectRevert(IProvingGround.BadSignature.selector);
        hook.rebalance(intent, abi.encodePacked(r, s, v));
    }

    function test_intent_forAnotherPoolReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        intent.poolId = idB;
        _rejects(intent, curatorKey, IProvingGround.WrongPool.selector);
    }

    function test_intent_forALiveVaultIsNotSupportedYet() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        intent.live = true;
        _rejects(intent, curatorKey, IProvingGround.LiveNotSupported.selector);
    }

    function test_intent_forAnUnknownShadowReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        intent.subjectId = 99;
        _rejects(intent, curatorKey, IProvingGround.UnknownShadow.selector);
    }

    /// @dev A curator can be a contract wallet. Its signature is checked through ERC-1271.
    function test_intent_fromAContractWallet() public {
        (address owner, uint256 ownerKey) = makeAddrAndKey("wallet owner");
        ContractWallet wallet = new ContractWallet(owner);
        uint256 walletShadow = _openAs(address(wallet), -300, 300, 1e18);
        _ready();

        IProvingGround.RebalanceIntent memory intent = _intent(walletShadow, -600, 600);
        _rejects(intent, curatorKey, IProvingGround.BadSignature.selector); // not the wallet's owner

        hook.rebalance(intent, _sign(ownerKey, intent));
        assertEq(hook.getShadow(walletShadow).tickUpper, 600);
        assertEq(hook.nonces(address(wallet)), 1);
    }

    // ------------------------------------------------------------------ check 1: nonce and deadline

    function test_nonce_aUsedIntentCannotBeReplayed() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);
        hook.rebalance(intent, signature);

        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        vm.expectRevert(IProvingGround.BadNonce.selector);
        hook.rebalance(intent, signature);
    }

    function test_nonce_mustBeTheNextOne() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        intent.nonce = 1;
        _rejects(intent, curatorKey, IProvingGround.BadNonce.selector);
    }

    function test_nonce_skippingCancelsAnOutstandingIntent() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IProvingGround.NonceSkipped(curator, 0);
        vm.prank(curator);
        hook.skipNonce();
        assertEq(hook.nonces(curator), 1);

        vm.expectRevert(IProvingGround.BadNonce.selector);
        hook.rebalance(intent, signature);
    }

    /// @dev An intent that fails a mandate check is not used up. It can be submitted again later.
    function test_nonce_aRejectedIntentIsNotSpent() public {
        _ready();
        _rebalance(shadowId, -600, 600);

        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -300, 300);
        bytes memory signature = _sign(curatorKey, intent);
        vm.expectRevert(); // still cooling down
        hook.rebalance(intent, signature);
        assertEq(hook.nonces(curator), 1);

        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        hook.rebalance(intent, signature);
        assertEq(hook.nonces(curator), 2);
    }

    function test_deadline_lastSecondPasses_nextSecondReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);

        uint256 atDeadline = vm.snapshotState();
        vm.warp(intent.deadline);
        hook.rebalance(intent, signature);
        vm.revertToState(atDeadline);

        vm.warp(intent.deadline + 1);
        vm.expectRevert(IProvingGround.IntentExpired.selector);
        hook.rebalance(intent, signature);
    }

    // ------------------------------------------------------------------ check 2: range

    function test_width_narrowestAllowedPasses_narrowerReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory tooNarrow = _intent(shadowId, 0, 60);
        _rejects(tooNarrow, curatorKey, IProvingGround.RangeTooNarrow.selector);

        _rebalance(shadowId, -60, 60); // exactly MIN_WIDTH
        assertEq(hook.getShadow(shadowId).tickUpper - hook.getShadow(shadowId).tickLower, int24(MIN_WIDTH));
    }

    function test_width_widestAllowedPasses_widerReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory tooWide = _intent(shadowId, -6000, 6060);
        _rejects(tooWide, curatorKey, IProvingGround.RangeTooWide.selector);

        _rebalance(shadowId, -6000, 6000); // exactly MAX_WIDTH
        assertEq(hook.getShadow(shadowId).tickUpper - hook.getShadow(shadowId).tickLower, int24(MAX_WIDTH));
    }

    function test_width_invertedRangeReverts() public {
        _ready();
        IProvingGround.RebalanceIntent memory inverted = _intent(shadowId, 300, -300);
        _rejects(inverted, curatorKey, IProvingGround.RangeTooNarrow.selector);
    }

    function test_range_mustSitOnTheTickGrid() public {
        _ready();
        IProvingGround.RebalanceIntent memory offGrid = _intent(shadowId, -610, 600);
        _rejects(offGrid, curatorKey, IProvingGround.RangeNotOnSpacing.selector);

        offGrid = _intent(shadowId, -600, 601);
        _rejects(offGrid, curatorKey, IProvingGround.RangeNotOnSpacing.selector);
    }

    function test_range_mustContainTheCurrentTick() public {
        _ready();
        IProvingGround.RebalanceIntent memory above = _intent(shadowId, 60, 660);
        _rejects(above, curatorKey, IProvingGround.RangeMustContainTick.selector);

        IProvingGround.RebalanceIntent memory below = _intent(shadowId, -600, 0); // upper bound is exclusive
        _rejects(below, curatorKey, IProvingGround.RangeMustContainTick.selector);

        _rebalance(shadowId, 0, 600); // lower bound is inclusive
    }

    /// @dev Whatever range is asked for, a rebalance either reverts or lands inside the mandate.
    function testFuzz_rebalance_onlyEverLandsInsideTheMandate(int256 lowerSeed, int256 upperSeed) public {
        _ready();
        // Half of the inputs are snapped to the tick grid so that the other checks get exercised too.
        int24 lower = int24(bound(lowerSeed, -9000, 9000));
        int24 upper = int24(bound(upperSeed, -9000, 9000));
        if (lowerSeed % 2 == 0) {
            lower = (lower / TS) * TS;
            upper = (upper / TS) * TS;
        }
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, lower, upper);
        try hook.rebalance(intent, _sign(curatorKey, intent)) {
            IProvingGround.Shadow memory s = hook.getShadow(shadowId);
            int24 width = s.tickUpper - s.tickLower;
            assertEq(s.tickLower, lower);
            assertEq(s.tickUpper, upper);
            assertGe(width, int24(MIN_WIDTH));
            assertLe(width, int24(MAX_WIDTH));
            assertEq(s.tickLower % TS, 0);
            assertEq(s.tickUpper % TS, 0);
            assertTrue(s.tickLower <= _spot() && _spot() < s.tickUpper);
        } catch (bytes memory reason) {
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == IProvingGround.RangeNotOnSpacing.selector
                    || selector == IProvingGround.RangeTooNarrow.selector
                    || selector == IProvingGround.RangeTooWide.selector
                    || selector == IProvingGround.RangeMustContainTick.selector,
                "reverted for a reason other than the range rules"
            );
            assertEq(hook.getShadow(shadowId).rebalances, 0);
        }
    }

    // ------------------------------------------------------------------ check 3: cooldown

    function test_cooldown_countsFromOpening() public {
        // A pool that is already old enough for the oracle, so only the cooldown is in the way.
        _ready();
        uint256 fresh = _openAs(stranger, -300, 300, 1e18);
        uint256 readyAt = vm.getBlockTimestamp() + COOLDOWN;
        (, uint256 strangerKey) = makeAddrAndKey("stranger");

        IProvingGround.RebalanceIntent memory intent = _intent(fresh, -600, 600);
        bytes memory signature = _sign(strangerKey, intent);

        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.CooldownNotElapsed.selector, readyAt));
        hook.rebalance(intent, signature);

        vm.warp(readyAt);
        hook.rebalance(intent, signature);
    }

    function test_cooldown_betweenRebalances() public {
        _ready();
        _rebalance(shadowId, -600, 600);
        uint256 readyAt = vm.getBlockTimestamp() + COOLDOWN;

        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -300, 300);
        bytes memory signature = _sign(curatorKey, intent);

        vm.expectRevert(abi.encodeWithSelector(IProvingGround.CooldownNotElapsed.selector, readyAt));
        hook.rebalance(intent, signature); // same block

        vm.warp(readyAt - 1);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.CooldownNotElapsed.selector, readyAt));
        hook.rebalance(intent, signature);

        vm.warp(readyAt);
        hook.rebalance(intent, signature);
        assertEq(hook.getShadow(shadowId).rebalances, 2);
    }

    // ------------------------------------------------------------------ check 4: price sanity

    function test_deviation_needsTheOracleOnAYoungPool() public {
        vm.warp(vm.getBlockTimestamp() + COOLDOWN); // cooldown over, oracle window not yet
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        _rejects(intent, curatorKey, Oracle.OracleNotReady.selector);
    }

    function test_deviation_aModestMovePasses() public {
        _ready();
        _swap(keyA, false, 12 * unit1);
        int24 spot = _spot();
        assertGt(spot, 30, "the price did move");
        assertLe(spot, int24(MAX_DEVIATION), "but stayed inside the limit");
        assertEq(hook.twapTick(idA), 0);

        _rebalance(shadowId, -240, 360);
        assertEq(hook.getShadow(shadowId).rebalances, 1);
    }

    /// @dev The gate for this phase: a price pushed within one block cannot be used to move a shadow.
    function test_deviation_aFlashedPriceCannotRebalanceAShadow() public {
        _ready();
        _swap(keyA, false, 60 * unit1); // the manipulation: hundreds of ticks in one swap
        int24 spot = _spot();
        assertGt(spot, int24(MAX_DEVIATION));
        int24 mid = (spot / TS) * TS;

        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, mid - 300, mid + 300);
        bytes memory signature = _sign(curatorKey, intent);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.PriceDeviationTooHigh.selector, spot, int24(0)));
        hook.rebalance(intent, signature);

        // It works in both directions.
        _swap(keyA, true, 130 * unit0);
        spot = _spot();
        assertLt(spot, -int24(MAX_DEVIATION));
        mid = (spot / TS) * TS;
        intent = _intent(shadowId, mid - 300, mid + 300);
        signature = _sign(curatorKey, intent);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.PriceDeviationTooHigh.selector, spot, int24(0)));
        hook.rebalance(intent, signature);
    }

    function test_deviation_onceThePriceIsPushedBackTheHonestRebalanceWorks() public {
        _ready();
        _swap(keyA, false, 60 * unit1);
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, -600, 600);
        bytes memory signature = _sign(curatorKey, intent);
        vm.expectRevert();
        hook.rebalance(intent, signature);

        _swap(keyA, true, 60 * unit0); // the price comes back
        assertLe(_abs(int256(_spot())), MAX_DEVIATION);
        hook.rebalance(intent, signature);
    }

    /// @dev The limit is against the average, so a move that lasts is accepted once the average follows.
    function test_deviation_aMoveThatHoldsIsAcceptedOnceTheAverageCatchesUp() public {
        _ready();
        _swap(keyA, false, 60 * unit1);
        int24 spot = _spot();
        int24 mid = (spot / TS) * TS;
        IProvingGround.RebalanceIntent memory intent = _intent(shadowId, mid - 300, mid + 300);
        intent.deadline = vm.getBlockTimestamp() + 1 days;
        bytes memory signature = _sign(curatorKey, intent);

        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW / 4);
        vm.expectRevert(); // the average has only moved a quarter of the way
        hook.rebalance(intent, signature);

        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        assertEq(hook.twapTick(idA), spot);
        hook.rebalance(intent, signature);
    }
}

/// @notice What the price check is worth. The same hook with the check switched off lets a curator
/// raise their own score with a price pushed for one transaction.
contract MandateWithoutPriceCheckTest is TwinPools {
    using StateLibrary for IPoolManager;

    function setUp() public {
        IProvingGround.Config memory config = _config(100);
        config.maxDeviationTicks = type(uint24).max;
        _setUpTwin(18, 18, 0, 1e18, config);
    }

    function test_withoutThePriceCheck_aFlashedPriceInflatesTheScore() public {
        // A wide shadow holds about half its value in token0.
        uint256 shadowId = _openAs(curator, -6000, 6000, _activeShare(100));
        vm.warp(vm.getBlockTimestamp() + TWAP_WINDOW);
        uint256 honest = hook.score(shadowId).navConservative;

        // One transaction: push the price of token0 up, rebalance into the narrowest range (the size
        // cap leaves most of the value idle, in token1, as if the token0 had been sold at the pushed
        // price), then push the price back.
        _swap(keyA, false, 60 * unit1);
        (, int24 spot,,) = poolManager.getSlot0(idA);
        int24 mid = (spot / TS) * TS;
        _rebalance(shadowId, mid, mid + 120);
        _swap(keyA, true, 60 * unit0);

        // The score is valued at the time-weighted price, which never moved.
        assertEq(hook.twapTick(idA), 0);
        IProvingGround.Score memory sc = hook.score(shadowId);
        int256 gainBps = (int256(sc.navConservative) - int256(honest)) * 10_000 / int256(honest);
        console2.log("pushed price, ticks above the average:", spot);
        console2.log("score gained from the pushed price, bps:", gainBps);
        console2.log("modelled rebalance cost, bps of value:", sc.rebalanceCost * 10_000 / honest);
        assertGt(gainBps, 30, "the unchecked hook hands out value that no real position could have earned");
    }
}

/// @notice The mandate checks on their own, at their exact limits.
contract MandateLibraryTest is Test {
    MandateHarness internal harness = new MandateHarness();

    function _intent() internal pure returns (IProvingGround.RebalanceIntent memory) {
        return IProvingGround.RebalanceIntent({
            poolId: PoolId.wrap(bytes32(uint256(1))),
            subjectId: 2,
            live: false,
            tickLower: -300,
            tickUpper: 300,
            nonce: 3,
            deadline: 4
        });
    }

    function test_structHash_changesWithEveryField() public view {
        bytes32 base = harness.structHash(_intent());
        IProvingGround.RebalanceIntent memory i = _intent();
        i.poolId = PoolId.wrap(bytes32(uint256(9)));
        assertNotEq(harness.structHash(i), base);
        i = _intent();
        i.subjectId = 9;
        assertNotEq(harness.structHash(i), base);
        i = _intent();
        i.live = true;
        assertNotEq(harness.structHash(i), base);
        i = _intent();
        i.tickLower = -360;
        assertNotEq(harness.structHash(i), base);
        i = _intent();
        i.tickUpper = 360;
        assertNotEq(harness.structHash(i), base);
        i = _intent();
        i.nonce = 9;
        assertNotEq(harness.structHash(i), base);
        i = _intent();
        i.deadline = 9;
        assertNotEq(harness.structHash(i), base);
    }

    function test_checkRange_limits() public {
        harness.checkRange(-60, 60, 0, 60, 120, 600); // narrowest
        harness.checkRange(-300, 300, 0, 60, 120, 600); // widest
        harness.checkRange(0, 120, 0, 60, 120, 600); // tick on the lower bound
        harness.checkRange(-120, 0, -1, 60, 120, 600); // tick just under the upper bound

        vm.expectRevert(IProvingGround.RangeTooNarrow.selector);
        harness.checkRange(0, 60, 0, 60, 120, 600);
        vm.expectRevert(IProvingGround.RangeTooWide.selector);
        harness.checkRange(-300, 360, 0, 60, 120, 600);
        vm.expectRevert(IProvingGround.RangeNotOnSpacing.selector);
        harness.checkRange(-61, 60, 0, 60, 120, 600);
        vm.expectRevert(IProvingGround.RangeNotOnSpacing.selector);
        harness.checkRange(-60, 61, 0, 60, 120, 600);
        vm.expectRevert(IProvingGround.RangeMustContainTick.selector);
        harness.checkRange(-120, 0, 0, 60, 120, 600);
        vm.expectRevert(IProvingGround.RangeMustContainTick.selector);
        harness.checkRange(60, 180, 59, 60, 120, 600);
    }

    function testFuzz_checkRange_passesOnlyValidRanges(
        int24 lower,
        int24 upper,
        int24 tick,
        uint8 spacingSeed,
        uint24 minWidth,
        uint24 maxWidth
    ) public view {
        int24 spacing = int24(uint24(bound(spacingSeed, 1, 200)));
        try harness.checkRange(lower, upper, tick, spacing, minWidth, maxWidth) {
            int256 width = int256(upper) - int256(lower);
            assertEq(lower % spacing, 0);
            assertEq(upper % spacing, 0);
            assertGe(width, int256(uint256(minWidth)));
            assertLe(width, int256(uint256(maxWidth)));
            assertTrue(lower <= tick && tick < upper);
        } catch {}
    }

    function test_checkCooldown_limits() public {
        harness.checkCooldown(1300, 1000, 300);
        harness.checkCooldown(1000, 1000, 0);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.CooldownNotElapsed.selector, 1300));
        harness.checkCooldown(1299, 1000, 300);
    }

    function test_checkDeviation_limits() public {
        harness.checkDeviation(100, 0, 100);
        harness.checkDeviation(-100, 0, 100);
        harness.checkDeviation(-250, -200, 50);
        harness.checkDeviation(0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.PriceDeviationTooHigh.selector, int24(101), int24(0)));
        harness.checkDeviation(101, 0, 100);
        vm.expectRevert(abi.encodeWithSelector(IProvingGround.PriceDeviationTooHigh.selector, int24(-101), int24(0)));
        harness.checkDeviation(-101, 0, 100);
    }

    function testFuzz_checkDeviation_isSymmetric(int24 a, int24 b, uint24 limit) public view {
        bool forward;
        bool backward;
        try harness.checkDeviation(a, b, limit) {
            forward = true;
        } catch {}
        try harness.checkDeviation(b, a, limit) {
            backward = true;
        } catch {}
        assertEq(forward, backward);
        int256 gap = int256(a) - int256(b);
        if (gap < 0) gap = -gap;
        assertEq(forward, uint256(gap) <= limit);
    }
}

/// @dev Exposes the library's internal functions so that their reverts can be caught.
contract MandateHarness {
    function structHash(IProvingGround.RebalanceIntent memory intent) external pure returns (bytes32) {
        return Mandate.structHash(intent);
    }

    function checkRange(int24 lower, int24 upper, int24 tick, int24 spacing, uint24 minWidth, uint24 maxWidth)
        external
        pure
    {
        Mandate.checkRange(lower, upper, tick, spacing, minWidth, maxWidth);
    }

    function checkCooldown(uint256 nowTime, uint256 lastPlacedAt, uint256 minInterval) external pure {
        Mandate.checkCooldown(nowTime, lastPlacedAt, minInterval);
    }

    function checkDeviation(int24 spot, int24 twap, uint24 limit) external pure {
        Mandate.checkDeviation(spot, twap, limit);
    }
}

/// @notice A minimal contract wallet: one owner key, signatures checked through ERC-1271.
contract ContractWallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(hash, signature) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    receive() external payable {}
}
