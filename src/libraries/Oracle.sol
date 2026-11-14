// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Oracle
/// @notice Time-weighted average tick for a Uniswap v4 pool. v4 pools carry no price oracle, so the
/// hook keeps one.
/// @dev The design follows Uniswap v3's observation ring buffer: one observation per timestamp, each
/// holding the running sum of (tick x seconds). The tick is constant between two consecutive
/// observations, so interpolating between them is exact.
library Oracle {
    /// @notice There is not enough history to cover the requested window.
    error OracleNotReady();

    struct Observation {
        uint48 time;
        int56 tickCumulative;
    }

    struct State {
        uint16 index; // ring slot of the newest observation
        uint16 count; // observations stored, capped at the ring capacity
        uint48 lastTime; // time of the newest observation, cached so a swap can skip the write cheaply
        mapping(uint256 => Observation) ring;
    }

    /// @notice Writes the first observation.
    function start(State storage self, uint48 time) internal {
        self.ring[0] = Observation({time: time, tickCumulative: 0});
        self.index = 0;
        self.count = 1;
        self.lastTime = time;
    }

    /// @notice Records an observation, at most once per timestamp.
    /// @param tick The tick that has prevailed since the previous observation, i.e. the pool tick
    /// before the first swap at `time`.
    /// @param capacity Ring size. Must be at least 2 and must not change between calls.
    function write(State storage self, uint48 time, int24 tick, uint16 capacity) internal {
        uint16 count = self.count;
        if (count == 0) {
            start(self, time);
            return;
        }
        uint16 index = self.index;
        Observation memory last = self.ring[index];
        if (last.time == time) return;

        uint16 next = uint16((uint256(index) + 1) % capacity);
        self.ring[next] = Observation({
            time: time, tickCumulative: last.tickCumulative + int56(tick) * int56(uint56(time - last.time))
        });
        self.index = next;
        self.lastTime = time;
        if (count < capacity) self.count = count + 1;
    }

    /// @notice Average tick over the last `window` seconds, rounded toward negative infinity.
    /// @dev If the ring has wrapped and no longer reaches back `window` seconds, the average is
    /// taken over everything the ring holds. Since at most one observation is written per
    /// timestamp, a full ring always covers at least `capacity - 1` seconds, so the deployer
    /// should choose `capacity >= window / block time`.
    /// @param tick The pool's current tick.
    function twapTick(State storage self, uint48 nowTime, uint32 window, int24 tick, uint16 capacity)
        internal
        view
        returns (int24 mean)
    {
        uint16 count = self.count;
        if (count == 0) revert OracleNotReady();

        uint16 index = self.index;
        Observation memory newest = self.ring[index];
        // No swap has happened in a block after `newest.time`, so the current tick has held since then.
        int56 cumulativeNow = newest.tickCumulative + int56(tick) * int56(uint56(nowTime - newest.time));

        uint16 oldestIndex = count < capacity ? 0 : uint16((uint256(index) + 1) % capacity);
        uint48 oldestTime = self.ring[oldestIndex].time;
        uint48 target = nowTime > window ? nowTime - window : 0;
        if (oldestTime > target) {
            if (count < capacity) revert OracleNotReady();
            target = oldestTime;
        }
        if (target >= nowTime) revert OracleNotReady();

        int56 cumulativeThen;
        if (target >= newest.time) {
            cumulativeThen = newest.tickCumulative + int56(tick) * int56(uint56(target - newest.time));
        } else {
            cumulativeThen = _cumulativeAt(self, target, oldestIndex, count, capacity);
        }

        int56 delta = cumulativeNow - cumulativeThen;
        int56 span = int56(uint56(nowTime - target));
        mean = int24(delta / span);
        if (delta < 0 && delta % span != 0) mean--;
    }

    /// @dev Requires oldest.time <= target < newest.time.
    function _cumulativeAt(State storage self, uint48 target, uint16 oldestIndex, uint16 count, uint16 capacity)
        private
        view
        returns (int56)
    {
        // Positions are counted from the oldest observation. Invariant: time(lo) <= target < time(hi).
        uint256 lo = 0;
        uint256 hi = uint256(count) - 1;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (self.ring[(uint256(oldestIndex) + mid) % capacity].time <= target) lo = mid;
            else hi = mid;
        }
        Observation memory a = self.ring[(uint256(oldestIndex) + lo) % capacity];
        Observation memory b = self.ring[(uint256(oldestIndex) + hi) % capacity];
        return a.tickCumulative + (b.tickCumulative - a.tickCumulative) * int56(uint56(target - a.time))
            / int56(uint56(b.time - a.time));
    }
}
