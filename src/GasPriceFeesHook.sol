// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title GasPriceFeesHook
/// @notice Dynamic fee hook: charges lower swap fees when gas is expensive and higher fees when gas is cheap,
///         relative to the average gas price this hook has seen.
/// @dev Fees are in pips (1_000_000 = 100%). The fee is returned per swap from beforeSwap as an override,
///      so the pool must be initialized with LPFeeLibrary.DYNAMIC_FEE_FLAG.
contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Average gas price over every tx that touched this hook (cumulative average, all samples weigh the same)
    uint128 public movingAverageGasPrice;
    // Number of samples in the average; denominator for the next update
    uint104 public movingAverageGasPriceCount;

    // The default base fee we charge
    uint24 public constant BASE_FEE = 5000; // 0.5%

    error MustUseDynamicFee();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        // The deployment tx is our first gas price sample
        updateMovingAverage();
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev A static-fee pool would silently ignore our override fee, so refuse to be attached to one.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        // For a longer-lived fee change (e.g. once per block) we'd call poolManager.updateDynamicLPFee(key, fee).
        // Here we override per swap: bit 23 (OVERRIDE_FEE_FLAG) tells the PoolManager to use this value.
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    /// @notice Fee for a swap sent at the current tx.gasprice. Public so it can be inspected off-chain and in tests.
    function getFee() public view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // gasPrice > average * 1.1 -> halve the fee
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }

        // gasPrice < average * 0.9 -> double the fee
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }

        return BASE_FEE;
    }

    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++;
    }
}
