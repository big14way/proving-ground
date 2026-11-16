// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IProvingGroundVault
/// @notice Types, events and errors of the vault that holds live liquidity.
interface IProvingGroundVault {
    /// @notice Deployment parameters. All are immutable once the vault is deployed.
    struct VaultConfig {
        int32 graduationAlphaBps; // shadow score a curator needs to go live
        int32 demotionAlphaBps; // live score below which a vault takes no new deposits
        uint16 baseMultiple; // total shares allowed per share of curator stake, at a score of zero or less
        uint16 maxMultiple; // the most that multiple can reach
        uint16 alphaStepBps; // each step of score adds one to the multiple
        uint16 liveMaxPoolShareBps; // largest vault position, as a share of the pool's active liquidity
        uint16 maxRebalanceLossBps; // most value a single rebalance may lose, measured at the time-weighted price
        uint16 perfFeeBps; // the curator's share of what the vault gains on its benchmark above the high-water mark
    }

    /// @notice A curator's live position and the claims on it.
    struct Vault {
        PoolId poolId;
        address curator;
        int24 tickLower;
        int24 tickUpper;
        uint48 openedAt;
        uint128 liquidity; // real liquidity in the pool, owned by the vault contract
        uint128 idle0; // token0 held outside the position
        uint128 idle1; // token1 held outside the position
        uint256 totalShares;
        uint256 curatorShares; // the curator's stake; counted in totalShares, not transferable
        int256 shadowAlphaBps; // the shadow's final score, fixed when the vault opened
        // Benchmark: a passive full-range position with the same value as the vault when it opened.
        uint128 benchLiquidity;
        uint256 benchShares; // shares outstanding when the benchmark was sized
        uint256 feeGrowthGlobal0Open;
        uint256 feeGrowthGlobal1Open;
        uint48 lastRebalanceAt;
        uint48 closedAt; // set when the last share is redeemed
        uint32 rebalances;
        // The highest value per share, relative to the benchmark, that a fee has been paid up to.
        // 1e18 is level with the benchmark, and it starts there.
        uint256 highWaterMark;
    }

    /// @notice A vault's standing at the pool's time-weighted price. Values are in token1.
    struct Standing {
        uint256 nav; // position, uncollected fees and idle balances
        uint256 navBenchmark; // the benchmark, scaled to the shares now outstanding
        uint256 valueRatio; // nav over navBenchmark, 1e18 = level
        int256 liveAlphaBps; // value per share against the benchmark, since the vault opened
        int256 capacityAlphaBps; // the score that sets capacity: the shadow's at first, then the live one
        uint256 multiple; // total shares allowed per share of curator stake
        uint256 maxTotalShares; // capacity
        bool demoted; // live score below the demotion line: no new deposits
        uint256 feeSharesDue; // shares a fee settlement would mint to the curator now
    }

    event VaultOpened(
        uint256 indexed vaultId,
        PoolId indexed poolId,
        address indexed curator,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int256 shadowAlphaBps
    );
    event Entered(
        uint256 indexed vaultId, address indexed account, bool stake, uint256 shares, uint256 amount0, uint256 amount1
    );
    event Exited(
        uint256 indexed vaultId, address indexed account, bool stake, uint256 shares, uint256 amount0, uint256 amount1
    );
    event VaultRebalanced(
        uint256 indexed vaultId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 valueBefore,
        uint256 valueAfter
    );
    event VaultClosed(uint256 indexed vaultId);
    event FeeSettled(
        uint256 indexed vaultId, address indexed curator, uint256 feeShares, uint256 valueRatio, uint256 highWaterMark
    );

    error InvalidVaultConfig();
    error NotPoolManager();
    error NotVaultCurator();
    error UnknownVault();
    error VaultIsClosed();
    error ZeroShares();

    // Going live.
    error ShadowTooYoung(uint256 readyAt);
    error AlphaTooLow(int256 alphaBps);

    // Deposits and stake.
    error Demoted(int256 liveAlphaBps);
    error OverCapacity(uint256 maxTotalShares);
    error OverPoolShare();
    error StakeLocked();
    error SlippageExceeded();

    // Rebalancing.
    error NothingToPlace();
    error RebalanceLossTooHigh(uint256 valueBefore, uint256 valueAfter);
}
