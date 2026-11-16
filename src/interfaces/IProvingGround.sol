// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IProvingGround
/// @notice Types, events and errors of the Proving Ground hook.
interface IProvingGround {
    /// @notice Deployment parameters. All are immutable once the hook is deployed.
    struct Config {
        uint32 twapWindow; // seconds the oracle averages over
        uint16 oracleCapacity; // observations kept per pool; should be >= twapWindow / block time
        uint16 shadowMaxPoolShareBps; // largest shadow, as a share of the pool's active liquidity
        uint24 defaultDynamicFee; // fee set on dynamic-fee pools at initialization, in pips
        // The mandate: limits every range placement must respect.
        uint24 minWidthTicks; // narrowest range allowed
        uint24 maxWidthTicks; // widest range allowed
        uint24 maxDeviationTicks; // largest gap between the pool price and its time-weighted average at a rebalance
        uint32 minRebalanceInterval; // seconds between rebalances of one position
        // The cost of opening a shadow.
        uint32 minShadowAge; // seconds a shadow's bond stays locked, counted from when it was opened
        uint128 bondMin; // smallest bond, in the chain's native currency
        // The vault contract that holds live liquidity. It alone may graduate a shadow and have a
        // live intent checked. Zero if the hook is deployed without live vaults.
        address vault;
    }

    /// @notice A curator's signed instruction to move a position to a new range.
    /// @dev EIP-712 typed data. Anyone may submit it; the hook checks it against the mandate.
    struct RebalanceIntent {
        PoolId poolId;
        uint256 subjectId; // the shadow id (or, when `live`, the vault id)
        bool live;
        int24 tickLower;
        int24 tickUpper;
        uint256 nonce; // must be the curator's next nonce
        uint256 deadline; // last timestamp at which the intent may be executed
    }

    /// @notice A capital-free position scored against live swap flow.
    struct Shadow {
        PoolId poolId;
        address curator;
        int24 tickLower;
        int24 tickUpper;
        uint48 openedAt;
        // Current leg: the stretch since the shadow was opened or last rebalanced.
        uint128 liquidity; // virtual liquidity
        uint128 openLiquidity; // pool active liquidity when this leg started
        uint256 feeGrowthInside0Last;
        uint256 feeGrowthInside1Last;
        // Benchmark: a passive full-range position with the same starting value, fixed at open.
        uint128 benchLiquidity;
        uint128 costPaid; // cumulative modelled rebalance cost, token1
        uint256 feeGrowthGlobal0Open;
        uint256 feeGrowthGlobal1Open;
        // Starting token amounts, for the comparison against simply holding.
        uint128 hold0;
        uint128 hold1;
        uint128 idle; // virtual token1 not placed in the range (see the size cap), earns nothing
        uint128 rawBonus; // raw minus conservative fees of finished legs, token1, not compounded
        uint48 closedAt;
        uint48 lastRebalanceAt;
        uint32 rebalances;
        uint128 bond; // native currency held for the curator until the shadow is closed and aged
        bool graduated; // closed by going live, rather than abandoned
    }

    /// @notice A shadow's result at one valuation price. All amounts are in token1.
    struct Score {
        uint160 sqrtPriceX96; // the price everything below is valued at
        uint256 navConservative; // position + idle + fees after the dilution haircut; rebalance costs already paid
        uint256 navRaw; // the same with unhaircut fees
        uint256 navBenchmark; // the passive full-range benchmark, fees included, no haircut
        uint256 navHold; // the starting tokens, simply held
        int256 alphaBps; // navConservative against navBenchmark
        int256 alphaVsHoldBps; // navConservative against navHold
        uint256 feesConservative; // current leg
        uint256 feesRaw; // current leg
        uint256 feesBenchmark; // since open
        uint256 rebalanceCost; // cumulative
    }

    /// @notice What a curator address has done so far. Abandoned shadows stay on the record.
    struct CuratorRecord {
        uint32 shadowsOpened;
        uint32 shadowsClosedWithoutGraduating;
    }

    event PoolRegistered(PoolId indexed poolId, int24 tickSpacing, uint24 fee);
    event DustFunded(Currency indexed currency, address indexed from, uint256 amount);
    event ShadowOpened(
        uint256 indexed shadowId,
        PoolId indexed poolId,
        address indexed curator,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 benchLiquidity
    );
    event ShadowRebalanced(uint256 indexed shadowId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 cost);
    event ShadowClosed(uint256 indexed shadowId, int256 alphaBps, int256 alphaVsHoldBps, uint256 navConservative);
    event IntentUsed(address indexed curator, uint256 nonce, address indexed submitter);
    event NonceSkipped(address indexed curator, uint256 nonce);
    event BondReturned(uint256 indexed shadowId, address indexed curator, uint256 amount);

    error InvalidConfig();
    error NativeCurrencyNotSupported();
    error PoolNotRegistered();
    error ZeroLiquidity();
    error NoActiveLiquidity();
    error ShadowTooLarge();
    error NothingToRebalance();
    error UnknownShadow();
    error ShadowIsClosed();
    error NotCurator();
    error DustReserveLow(Currency currency);

    // Opening rules.
    error BondTooSmall();
    error ShadowAlreadyOpen();
    error BondLocked(uint256 unlocksAt);
    error NoBond();
    error BondTransferFailed();

    error NotVault();

    // Intent checks.
    error WrongIntentKind(); // a live intent sent to the hook, or a shadow intent sent to the vault
    error WrongPool();
    error IntentExpired();
    error BadNonce();
    error BadSignature();

    // Mandate checks.
    error RangeNotOnSpacing();
    error RangeTooNarrow();
    error RangeTooWide();
    error RangeMustContainTick();
    error CooldownNotElapsed(uint256 readyAt);
    error PriceDeviationTooHigh(int24 spotTick, int24 twapTick);
}
