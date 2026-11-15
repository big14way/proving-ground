// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IProvingGround} from "../interfaces/IProvingGround.sol";

/// @title Mandate
/// @notice The limits a curator's range placements must respect, and the EIP-712 hash of the signed
/// instruction that asks for one. The same checks apply to a shadow and to a live vault.
library Mandate {
    bytes32 internal constant REBALANCE_INTENT_TYPEHASH = keccak256(
        "RebalanceIntent(bytes32 poolId,uint256 subjectId,bool live,int24 tickLower,int24 tickUpper,uint256 nonce,uint256 deadline)"
    );

    /// @notice EIP-712 struct hash of an intent.
    function structHash(IProvingGround.RebalanceIntent memory intent) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                REBALANCE_INTENT_TYPEHASH,
                intent.poolId,
                intent.subjectId,
                intent.live,
                intent.tickLower,
                intent.tickUpper,
                intent.nonce,
                intent.deadline
            )
        );
    }

    /// @notice The range sits on the pool's tick grid, is neither too narrow nor too wide, and
    /// contains the current tick (lower bound inclusive, upper bound exclusive).
    function checkRange(
        int24 tickLower,
        int24 tickUpper,
        int24 tick,
        int24 tickSpacing,
        uint24 minWidthTicks,
        uint24 maxWidthTicks
    ) internal pure {
        if (tickLower % tickSpacing != 0 || tickUpper % tickSpacing != 0) {
            revert IProvingGround.RangeNotOnSpacing();
        }
        int256 width = int256(tickUpper) - int256(tickLower);
        if (width < int256(uint256(minWidthTicks))) revert IProvingGround.RangeTooNarrow();
        if (width > int256(uint256(maxWidthTicks))) revert IProvingGround.RangeTooWide();
        if (tick < tickLower || tick >= tickUpper) revert IProvingGround.RangeMustContainTick();
    }

    /// @notice At least `minInterval` seconds have passed since the position was last placed.
    function checkCooldown(uint256 nowTime, uint256 lastPlacedAt, uint256 minInterval) internal pure {
        uint256 readyAt = lastPlacedAt + minInterval;
        if (nowTime < readyAt) revert IProvingGround.CooldownNotElapsed(readyAt);
    }

    /// @notice The pool price is within `maxDeviationTicks` of its time-weighted average, so the
    /// position is not being placed at a price someone pushed for the occasion.
    function checkDeviation(int24 spotTick, int24 twapTick, uint24 maxDeviationTicks) internal pure {
        int256 gap = int256(spotTick) - int256(twapTick);
        if (gap < 0) gap = -gap;
        if (uint256(gap) > maxDeviationTicks) revert IProvingGround.PriceDeviationTooHigh(spotTick, twapTick);
    }
}
