// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {ProvingGroundHook} from "../src/ProvingGroundHook.sol";

/// @notice Sets up a demonstration pool on a deployed hook: two test tokens anyone can mint, a pool
/// priced like ETH/USD, three overlapping liquidity positions, and the hook's dust reserve.
///
/// Usage:
///   HOOK=<hook address> forge script script/SetupPool.s.sol --rpc-url <url> --private-key <key> --broadcast
contract SetupPool is Script {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    /// @dev 1.0001^80067 is about 3000: one test ETH costs about 3000 test USD.
    int24 internal constant START_TICK = 80_067;
    int24 internal constant CENTER = 80_040;
    /// @dev One unit of liquidity. The three positions below come to roughly 10 million USD in total.
    uint128 internal constant SCALE = 1e20;

    function run() external {
        ProvingGroundHook hook = ProvingGroundHook(vm.envAddress("HOOK"));
        IPoolManager manager = hook.poolManager();
        IPositionManager positions = IPositionManager(AddressConstants.getPositionManagerAddress(block.chainid));
        IAllowanceTransfer permit2 = IAllowanceTransfer(AddressConstants.getPermit2Address());
        address router = AddressConstants.getV4SwapRouterAddress(block.chainid);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        // The USD token must be currency1, the higher address, so that values read in USD.
        MockERC20 eth = new MockERC20("Proving Ground Test ETH", "pgETH", 18);
        MockERC20 usd = new MockERC20("Proving Ground Test USD", "pgUSD", 18);
        while (address(usd) < address(eth)) usd = new MockERC20("Proving Ground Test USD", "pgUSD", 18);

        eth.mint(deployer, 1_000_000e18);
        usd.mint(deployer, 3_000_000_000e18);
        _approve(eth, permit2, address(positions), router, address(hook));
        _approve(usd, permit2, address(positions), router, address(hook));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(eth)),
            currency1: Currency.wrap(address(usd)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));

        _mint(positions, key, CENTER - 12_000, CENTER + 12_000, 2000 * SCALE, deployer);
        _mint(positions, key, CENTER - 600, CENTER + 600, 1500 * SCALE, deployer);
        _mint(positions, key, CENTER - 120, CENTER + 180, 1000 * SCALE, deployer);

        hook.fundDust(key.currency0, 1e15);
        hook.fundDust(key.currency1, 1e15);
        vm.stopBroadcast();

        console2.log("pgETH (currency0):", address(eth));
        console2.log("pgUSD (currency1):", address(usd));
        console2.log("pool id:");
        console2.logBytes32(PoolId_unwrap(key));
        console2.log("position manager: ", address(positions));
        console2.log("swap router:      ", router);
    }

    function PoolId_unwrap(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _approve(MockERC20 token, IAllowanceTransfer permit2, address positions, address router, address hook)
        internal
    {
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), positions, type(uint160).max, type(uint48).max);
        token.approve(router, type(uint256).max);
        token.approve(hook, type(uint256).max);
    }

    function _mint(
        IPositionManager positions,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address recipient
    ) internal {
        bytes[] memory params = new bytes[](2);
        params[0] =
            abi.encode(key, tickLower, tickUpper, liquidity, type(uint128).max, type(uint128).max, recipient, "");
        params[1] = abi.encode(key.currency0, key.currency1);
        positions.modifyLiquidities(
            abi.encode(abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR)), params),
            block.timestamp + 1 hours
        );
    }
}
