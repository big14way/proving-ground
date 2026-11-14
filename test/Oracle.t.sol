// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Oracle} from "../src/libraries/Oracle.sol";

contract OracleHarness {
    using Oracle for Oracle.State;

    Oracle.State internal state;
    uint16 public immutable capacity;

    constructor(uint16 capacity_) {
        capacity = capacity_;
    }

    function start(uint48 time) external {
        state.start(time);
    }

    function write(uint48 time, int24 tick) external {
        state.write(time, tick, capacity);
    }

    function twap(uint48 nowTime, uint32 window, int24 tick) external view returns (int24) {
        return state.twapTick(nowTime, window, tick, capacity);
    }

    function meta() external view returns (uint16 index, uint16 count, uint48 lastTime) {
        return (state.index, state.count, state.lastTime);
    }
}

contract OracleTest is Test {
    OracleHarness internal o;

    function setUp() public {
        o = new OracleHarness(8);
    }

    function test_start_writesFirstObservation() public {
        o.start(100);
        (uint16 index, uint16 count, uint48 lastTime) = o.meta();
        assertEq(index, 0);
        assertEq(count, 1);
        assertEq(lastTime, 100);
    }

    function test_write_startsAnUnstartedOracle() public {
        o.write(100, 5);
        (, uint16 count, uint48 lastTime) = o.meta();
        assertEq(count, 1);
        assertEq(lastTime, 100);
    }

    function test_write_oncePerTimestamp() public {
        o.start(100);
        o.write(112, 10);
        o.write(112, 999); // same timestamp: ignored
        (uint16 index, uint16 count,) = o.meta();
        assertEq(index, 1);
        assertEq(count, 2);
        // Only tick 10 over [100, 112) was recorded.
        assertEq(o.twap(112, 12, 0), 10);
    }

    function test_twap_constantTick() public {
        o.start(1000);
        o.write(1100, 42);
        o.write(1200, 42);
        assertEq(o.twap(1300, 300, 42), 42);
    }

    function test_twap_revertsBeforeTheWindowIsCovered() public {
        o.start(1000);
        o.write(1100, 42);
        vm.expectRevert(Oracle.OracleNotReady.selector);
        o.twap(1200, 300, 42);
        // Exactly covered: fine.
        assertEq(o.twap(1300, 300, 42), 42);
    }

    function test_twap_revertsWhenNeverStarted() public {
        vm.expectRevert(Oracle.OracleNotReady.selector);
        o.twap(5000, 300, 0);
    }

    function test_twap_revertsWhenNowIsBeforeOneWindow() public {
        o.start(1);
        vm.expectRevert(Oracle.OracleNotReady.selector);
        o.twap(100, 300, 0);
    }

    function test_twap_stepChange() public {
        o.start(1000);
        o.write(1900, 0); // tick 0 held over [1000, 1900)
        // Tick 100 has held since 1900. Half the window at 0, half at 100.
        assertEq(o.twap(2800, 1800, 100), 50);
    }

    function test_twap_interpolatesInsideTheRing() public {
        o.start(100);
        o.write(200, 10); // 10 over [100, 200)
        o.write(400, 30); // 30 over [200, 400)
        // Now 500, tick 50 since 400. Window 350 starts at 150:
        // 10 x 50 + 30 x 200 + 50 x 100 = 11500 over 350 seconds = 32.86
        assertEq(o.twap(500, 350, 50), 32);
    }

    function test_twap_targetExactlyOnAnObservation() public {
        o.start(100);
        o.write(200, 10);
        o.write(400, 30);
        // Window 300 starts at 200: 30 x 200 + 50 x 100 = 11000 over 300 = 36.67
        assertEq(o.twap(500, 300, 50), 36);
    }

    function test_twap_roundsTowardNegativeInfinity() public {
        o.start(100);
        o.write(200, -10);
        o.write(400, -30);
        // Mirror of the interpolation case: -32.86 rounds down to -33.
        assertEq(o.twap(500, 350, -50), -33);
    }

    function test_twap_sameBlockSwapDoesNotMoveIt() public {
        o.start(1000);
        o.write(3000, 7); // first swap at 3000 records the tick held until then
        // Later in the same block the pool tick is far away. The average must ignore it.
        assertEq(o.twap(3000, 1800, 5000), 7);
    }

    function test_ringWraps_andStillAnswers() public {
        o.start(1000);
        for (uint48 i = 1; i <= 20; ++i) {
            o.write(1000 + i * 10, 5);
        }
        (uint16 index, uint16 count,) = o.meta();
        assertEq(count, 8, "count is capped at capacity");
        assertEq(index, 20 % 8);
        // The ring now reaches back 70 seconds. A longer window falls back to what the ring holds.
        assertEq(o.twap(1200, 1800, 5), 5);
        assertEq(o.twap(1200, 30, 5), 5);
    }

    function test_ringWraps_usesOnlyWhatItHolds() public {
        o.start(1000);
        // Ticks 1..20, each held for 10 seconds. The ring keeps the last 8 observations: times 1130..1200.
        for (uint48 i = 1; i <= 20; ++i) {
            o.write(1000 + i * 10, int24(int48(i)));
        }
        // Over [1130, 1200): ticks 14..20, average 17.
        assertEq(o.twap(1200, 1800, 99), 17);
    }

    /// @dev Compares the ring against a brute-force average over a full history kept in memory.
    function testFuzz_twap_matchesBruteForce(uint256 seed, uint8 steps, uint16 windowSeed) public {
        uint256 n = bound(steps, 1, 40);
        OracleHarness big = new OracleHarness(64);
        uint48[] memory times = new uint48[](n + 1);
        int24[] memory ticks = new int24[](n + 1); // ticks[i] holds over [times[i-1], times[i])

        uint48 t = 10_000;
        times[0] = t;
        big.start(t);
        for (uint256 i = 1; i <= n; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            t += uint48(1 + seed % 600);
            int24 tick = int24(int256(seed >> 16) % 5000);
            times[i] = t;
            ticks[i] = tick;
            big.write(t, tick);
        }
        seed = uint256(keccak256(abi.encode(seed)));
        uint48 nowTime = t + uint48(seed % 600);
        int24 current = int24(int256(seed >> 16) % 5000);

        uint32 window = uint32(bound(windowSeed, 1, nowTime - times[0]));
        uint48 target = nowTime - window;

        // Brute force: integrate the tick over [target, nowTime).
        int256 sum;
        for (uint256 i = 1; i <= n; ++i) {
            uint48 a = times[i - 1] > target ? times[i - 1] : target;
            if (times[i] > a) sum += int256(ticks[i]) * int256(uint256(times[i] - a));
        }
        {
            uint48 a = times[n] > target ? times[n] : target;
            sum += int256(current) * int256(uint256(nowTime - a));
        }
        int256 expected = sum / int256(uint256(window));
        if (sum < 0 && sum % int256(uint256(window)) != 0) expected--;

        assertEq(big.twap(nowTime, window, current), int24(expected));
    }
}
