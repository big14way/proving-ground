// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseTest} from "./utils/BaseTest.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Deploy} from "../script/Deploy.s.sol";
import {ProvingGroundHook} from "../src/ProvingGroundHook.sol";
import {ProvingGroundVault} from "../src/ProvingGroundVault.sol";
import {IProvingGround} from "../src/interfaces/IProvingGround.sol";

/// @notice The deployment script's path: a mined hook address with the right permission bits, and
/// a hook and vault that name each other.
contract DeployTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    Deploy internal script;

    function setUp() public {
        deployArtifactsAndLabel();
        script = new Deploy();
    }

    function test_deploy_minesTheHookAddressAndBindsTheVault() public {
        IProvingGround.Config memory config = script.hookConfig();
        // Outside a broadcast, the script contract itself is the deployer of both.
        (ProvingGroundHook hook, ProvingGroundVault vault) =
            script.deploy(poolManager, config, script.vaultConfig(), address(script), address(script));

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, flags, "the address carries the permission bits");
        assertEq(hook.VAULT(), address(vault));
        assertEq(address(vault.HOOK()), address(hook));
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.TWAP_WINDOW(), config.twapWindow);
        assertEq(hook.MIN_SHADOW_AGE(), config.minShadowAge);
        assertEq(vault.MIN_SHADOW_AGE(), config.minShadowAge);
        assertEq(vault.PERF_FEE_BPS(), 1000);

        // The pool manager accepts it as a hook: a pool initializes and is registered.
        (Currency c0, Currency c1) = deployCurrencyPair();
        PoolKey memory key = PoolKey(c0, c1, 3000, 60, IHooks(address(hook)));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        assertEq(hook.getPoolKey(key.toId()).tickSpacing, 60);
    }

    function test_deploy_twiceGivesTwoIndependentPairs() public {
        (ProvingGroundHook hookA, ProvingGroundVault vaultA) =
            script.deploy(poolManager, script.hookConfig(), script.vaultConfig(), address(script), address(script));
        (ProvingGroundHook hookB, ProvingGroundVault vaultB) =
            script.deploy(poolManager, script.hookConfig(), script.vaultConfig(), address(script), address(script));
        assertTrue(address(hookA) != address(hookB));
        assertEq(hookA.VAULT(), address(vaultA));
        assertEq(hookB.VAULT(), address(vaultB));
    }
}
