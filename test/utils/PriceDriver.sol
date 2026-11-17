// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice A trader for tests that replay a recorded price path. It can swap a pool to an exact
/// price, reporting what that took, and make an ordinary swap of a given size. It pays from its own
/// balance, so it must be handed tokens first.
contract PriceDriver is IUnlockCallback {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPoolManager public immutable poolManager;

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    /// @notice Swaps `key`'s pool until its price is exactly `target`.
    /// @return zeroForOne The direction the swap took.
    /// @return amountIn What it paid in, pool fee included. Zero if the pool was already there.
    function swapTo(PoolKey calldata key, uint160 target) external returns (bool zeroForOne, uint256 amountIn) {
        PoolKey memory k = key;
        (uint160 current,,,) = poolManager.getSlot0(k.toId());
        if (current == target) return (false, 0);
        zeroForOne = target < current;
        // Exact input, far more than is needed: the price limit ends the swap.
        amountIn = _swap(key, zeroForOne, type(int128).min, target);
    }

    /// @notice Swaps exactly `amountIn` in the given direction, wherever that takes the price.
    function swapIn(PoolKey calldata key, bool zeroForOne, uint256 amountIn) external {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        _swap(key, zeroForOne, -int256(amountIn), limit);
    }

    function _swap(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (uint256 amountIn)
    {
        SwapParams memory params =
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit});
        return abi.decode(poolManager.unlock(abi.encode(key, params)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "not the pool manager");
        (PoolKey memory key, SwapParams memory params) = abi.decode(data, (PoolKey, SwapParams));
        BalanceDelta delta = poolManager.swap(key, params, "");

        (Currency paid, Currency received) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 owed, int128 due) =
            params.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        uint256 amountIn = uint256(uint128(-owed));
        if (amountIn != 0) {
            poolManager.sync(paid);
            IERC20(Currency.unwrap(paid)).transfer(address(poolManager), amountIn);
            poolManager.settle();
        }
        if (due > 0) poolManager.take(received, address(this), uint256(uint128(due)));
        return abi.encode(amountIn);
    }
}
