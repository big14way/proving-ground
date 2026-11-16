// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {V4PoolManagerDeployer} from "hookmate/artifacts/V4PoolManager.sol";

import {ProvingGroundHook} from "../src/ProvingGroundHook.sol";
import {ProvingGroundVault} from "../src/ProvingGroundVault.sol";
import {IProvingGround} from "../src/interfaces/IProvingGround.sol";
import {IProvingGroundVault} from "../src/interfaces/IProvingGroundVault.sol";

/// @notice Deploys the Proving Ground hook and its vault, bound to each other.
/// @dev The two contracts name each other at construction, so the order matters:
///  1. Work out the address the vault will get. It is created by the deployer's transaction after
///     the hook's, so it depends only on the deployer's address and nonce.
///  2. Mine a CREATE2 salt that gives the hook an address with its permission bits (afterInitialize,
///     beforeSwap), with the vault's address already in its constructor arguments.
///  3. Deploy the hook, then the vault. The vault's constructor reverts unless it is the address
///     the hook was given.
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url <url> --private-key <key> --broadcast
/// The pool manager comes from POOL_MANAGER if set, otherwise from the known address for the chain.
/// On a local node (chain id 31337) without POOL_MANAGER, a fresh pool manager is deployed first.
/// The settings below can be overridden with environment variables of the same name.
contract Deploy is Script {
    uint160 internal constant HOOK_FLAGS = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    function run() external returns (ProvingGroundHook hook, ProvingGroundVault vault) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        IPoolManager manager = _poolManager(deployer);
        // In a broadcast, a salted `new` goes through the canonical CREATE2 factory.
        (hook, vault) = deploy(manager, hookConfig(), vaultConfig(), deployer, CREATE2_FACTORY);
        vm.stopBroadcast();

        console2.log("chain id:    ", block.chainid);
        console2.log("pool manager:", address(manager));
        console2.log("hook:        ", address(hook));
        console2.log("vault:       ", address(vault));
    }

    /// @param deployer The account whose next transactions create the two contracts.
    /// @param create2Deployer The address a salted `new` is created from: the CREATE2 factory in a
    /// broadcast, the calling contract otherwise.
    function deploy(
        IPoolManager manager,
        IProvingGround.Config memory config,
        IProvingGroundVault.VaultConfig memory vaultSettings,
        address deployer,
        address create2Deployer
    ) public returns (ProvingGroundHook hook, ProvingGroundVault vault) {
        // The hook's deployment uses the deployer's current nonce; the vault's uses the next one.
        config.vault = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);

        (address expected, bytes32 salt) = HookMiner.find(
            create2Deployer, HOOK_FLAGS, type(ProvingGroundHook).creationCode, abi.encode(manager, config)
        );
        hook = new ProvingGroundHook{salt: salt}(manager, config);
        require(address(hook) == expected, "Deploy: hook is not at the mined address");

        vault = new ProvingGroundVault(hook, vaultSettings);
        require(address(vault) == config.vault, "Deploy: vault is not at the predicted address");
    }

    /// @notice The hook's settings. `vault` is filled in by `deploy`.
    function hookConfig() public view returns (IProvingGround.Config memory) {
        return IProvingGround.Config({
            twapWindow: uint32(vm.envOr("TWAP_WINDOW", uint256(30 minutes))),
            // Should be at least TWAP_WINDOW divided by the chain's block time.
            oracleCapacity: uint16(vm.envOr("ORACLE_CAPACITY", uint256(1800))),
            shadowMaxPoolShareBps: 100,
            defaultDynamicFee: 3000,
            minWidthTicks: uint24(vm.envOr("MIN_WIDTH_TICKS", uint256(120))),
            maxWidthTicks: uint24(vm.envOr("MAX_WIDTH_TICKS", uint256(12_000))),
            maxDeviationTicks: uint24(vm.envOr("MAX_DEVIATION_TICKS", uint256(100))),
            minRebalanceInterval: uint32(vm.envOr("MIN_REBALANCE_INTERVAL", uint256(5 minutes))),
            minShadowAge: uint32(vm.envOr("MIN_SHADOW_AGE", uint256(7 days))),
            bondMin: uint128(vm.envOr("BOND_MIN", uint256(0.01 ether))),
            vault: address(0)
        });
    }

    function vaultConfig() public view returns (IProvingGroundVault.VaultConfig memory) {
        return IProvingGroundVault.VaultConfig({
            graduationAlphaBps: 0,
            demotionAlphaBps: -200,
            baseMultiple: 2,
            maxMultiple: 10,
            alphaStepBps: 50,
            liveMaxPoolShareBps: 1000,
            maxRebalanceLossBps: 50,
            perfFeeBps: uint16(vm.envOr("PERF_FEE_BPS", uint256(1000)))
        });
    }

    function _poolManager(address deployer) internal returns (IPoolManager) {
        address given = vm.envOr("POOL_MANAGER", address(0));
        if (given != address(0)) return IPoolManager(given);
        if (block.chainid == 31337) return IPoolManager(V4PoolManagerDeployer.deploy(deployer));
        return IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
    }
}
