// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";

/// @notice Mines a CREATE2 salt so the hook address encodes the beforeInitialize | beforeSwap | afterSwap flags, then deploys it.
/// @dev `new X{salt: s}()` inside a broadcast is routed by forge through the deterministic
///      CREATE2 deployer, so that is the deployer HookMiner must use (not the EOA).
contract DeployHookScript is Script {
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManager = _poolManager(block.chainid);

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory constructorArgs = abi.encode(poolManager);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(GasPriceFeesHook).creationCode, constructorArgs);

        console.log("PoolManager:", poolManager);
        console.log("Mined hook address:", hookAddress);
        console.logBytes32(salt);

        // PRIVATE_KEY from .env; falls back to forge's default sender for key-less dry runs
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (pk == 0) vm.startBroadcast();
        else vm.startBroadcast(pk);
        GasPriceFeesHook hook = new GasPriceFeesHook{salt: salt}(IPoolManager(poolManager));
        vm.stopBroadcast();

        require(address(hook) == hookAddress, "DeployHookScript: hook address mismatch");
        console.log("Deployed GasPriceFeesHook:", address(hook));
    }

    /// Addresses from https://developers.uniswap.org/docs/protocols/v4/deployments
    function _poolManager(uint256 chainId) internal pure returns (address) {
        if (chainId == 11155111) return 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543; // Sepolia
        if (chainId == 1301) return 0x00B036B58a818B1BC34d502D3fE730Db729e62AC; // Unichain Sepolia
        revert("DeployHookScript: unsupported chain");
    }
}
