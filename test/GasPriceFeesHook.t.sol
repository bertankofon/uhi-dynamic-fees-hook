// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

import {GasPriceFeesHook} from "../src/GasPriceFeesHook.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    GasPriceFeesHook hook;

    uint160 constant FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Set gas price = 10 gwei and deploy our hook. The constructor records it as the first sample.
        // (Foundry's default gas price is 0.)
        vm.txGasPrice(10 gwei);
        deployCodeTo("GasPriceFeesHook.sol", abi.encode(manager), address(FLAGS));
        hook = GasPriceFeesHook(address(FLAGS));

        // DYNAMIC_FEE_FLAG (0x800000) instead of a fixed fee marks the pool as dynamic-fee
        (key,) = initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 100 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    PoolSwapTest.TestSettings testSettings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

    SwapParams smallSwap =
        SwapParams({zeroForOne: true, amountSpecified: -0.00001 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

    /// Swaps and returns the LP fee the PoolManager actually applied, read from its Swap event.
    function _swapAndGetAppliedFee() internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(key, smallSwap, testSettings, ZERO_BYTES);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                return fee;
            }
        }
        revert("Swap event not found");
    }

    function _expectedFee(uint256 gasPrice, uint256 avg) internal pure returns (uint24) {
        if (gasPrice > (avg * 11) / 10) return 2500;
        if (gasPrice < (avg * 9) / 10) return 10000;
        return 5000;
    }

    // ---------------------------------------------------------------------
    // Lesson test
    // ---------------------------------------------------------------------

    function test_feeUpdatesWithGasPrice() public {
        // Current gas price is 10 gwei; moving average should also be 10
        uint128 gasPrice = uint128(tx.gasprice);
        uint128 movingAverageGasPrice = hook.movingAverageGasPrice();
        uint104 movingAverageGasPriceCount = hook.movingAverageGasPriceCount();
        assertEq(gasPrice, 10 gwei);
        assertEq(movingAverageGasPrice, 10 gwei);
        assertEq(movingAverageGasPriceCount, 1);

        // 1. Swap at gasprice = 10 gwei -> BASE_FEE, average stays 10
        uint256 balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, smallSwap, testSettings, ZERO_BYTES);
        uint256 balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromBaseFeeSwap = balanceOfToken1After - balanceOfToken1Before;
        assertGt(balanceOfToken1After, balanceOfToken1Before);

        assertEq(hook.movingAverageGasPrice(), 10 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 2);

        // 2. Swap at lower gasprice = 4 gwei -> higher fee
        vm.txGasPrice(4 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, smallSwap, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromIncreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;
        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // (10 + 10 + 4) / 3 = 8 gwei
        assertEq(hook.movingAverageGasPrice(), 8 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 3);

        // 3. Swap at higher gasprice = 12 gwei -> lower fee
        vm.txGasPrice(12 gwei);
        balanceOfToken1Before = currency1.balanceOfSelf();
        swapRouter.swap(key, smallSwap, testSettings, ZERO_BYTES);
        balanceOfToken1After = currency1.balanceOfSelf();
        uint256 outputFromDecreasedFeeSwap = balanceOfToken1After - balanceOfToken1Before;
        assertGt(balanceOfToken1After, balanceOfToken1Before);

        // (10 + 10 + 4 + 12) / 4 = 9 gwei
        assertEq(hook.movingAverageGasPrice(), 9 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 4);

        // 4. Compare outputs: lower fee -> more tokens out
        console.log("Base Fee Output", outputFromBaseFeeSwap);
        console.log("Increased Fee Output", outputFromIncreasedFeeSwap);
        console.log("Decreased Fee Output", outputFromDecreasedFeeSwap);

        assertGt(outputFromDecreasedFeeSwap, outputFromBaseFeeSwap);
        assertGt(outputFromBaseFeeSwap, outputFromIncreasedFeeSwap);
    }

    // ---------------------------------------------------------------------
    // Extra unit tests
    // ---------------------------------------------------------------------

    /// Same flow as the lesson test, but asserts the exact fee the PoolManager applied (from the Swap event)
    function test_appliedFeeMatchesGasBand() public {
        assertEq(_swapAndGetAppliedFee(), 5000); // 10 gwei == avg 10 -> 0.5%

        vm.txGasPrice(4 gwei);
        assertEq(_swapAndGetAppliedFee(), 10000); // 4 < 10*0.9 -> 1%

        vm.txGasPrice(12 gwei);
        assertEq(_swapAndGetAppliedFee(), 2500); // avg now 8; 12 > 8*1.1 -> 0.25%
    }

    /// Thresholds are strict: exactly ±10% still pays BASE_FEE
    function test_getFee_boundaries() public {
        // avg = 10 gwei
        vm.txGasPrice(11 gwei);
        assertEq(hook.getFee(), 5000);
        vm.txGasPrice(11 gwei + 1);
        assertEq(hook.getFee(), 2500);

        vm.txGasPrice(9 gwei);
        assertEq(hook.getFee(), 5000);
        vm.txGasPrice(9 gwei - 1);
        assertEq(hook.getFee(), 10000);
    }

    function test_revertsOnStaticFeePool() public {
        // beforeInitialize reverts; PoolManager wraps hook reverts in CustomRevert.WrappedError
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(GasPriceFeesHook.MustUseDynamicFee.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);
    }

    /// Adding liquidity is not a sample: only swaps (and the constructor) update the average
    function test_liquidityDoesNotUpdateAverage() public {
        vm.txGasPrice(100 gwei);
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(0)}),
            ZERO_BYTES
        );
        assertEq(hook.movingAverageGasPrice(), 10 gwei);
        assertEq(hook.movingAverageGasPriceCount(), 1);
    }

    /// Caveat: if the hook is deployed with gasprice 0, the average starts at 0 and any
    /// non-zero gas price looks "high", so the first swaps always get the discount.
    function test_zeroGasDeployment_startsDiscounted() public {
        vm.txGasPrice(0);
        address hookAddr = address(FLAGS | (uint160(1) << 100));
        deployCodeTo("GasPriceFeesHook.sol", abi.encode(manager), hookAddr);
        GasPriceFeesHook zeroHook = GasPriceFeesHook(hookAddr);

        assertEq(zeroHook.movingAverageGasPrice(), 0);
        vm.txGasPrice(1 gwei);
        assertEq(zeroHook.getFee(), 2500);
    }

    function test_permissions() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeSwap && p.afterSwap);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.beforeSwapReturnDelta);
    }

    // ---------------------------------------------------------------------
    // Fuzz tests
    // ---------------------------------------------------------------------

    /// bound(): any gas price from 0 to 1000 gwei gets the right band, and the average updates correctly
    function testFuzz_feeAndAverage(uint256 gasPrice) public {
        gasPrice = bound(gasPrice, 0, 1000 gwei);

        uint256 avgBefore = hook.movingAverageGasPrice();
        uint256 countBefore = hook.movingAverageGasPriceCount();

        vm.txGasPrice(gasPrice);
        assertEq(_swapAndGetAppliedFee(), _expectedFee(gasPrice, avgBefore));

        assertEq(hook.movingAverageGasPrice(), (avgBefore * countBefore + gasPrice) / (countBefore + 1));
        assertEq(hook.movingAverageGasPriceCount(), countBefore + 1);
    }

    /// vm.assume(): only keep runs where gas is more than 10% above average -> always the discount
    /// (uint40 caps it at ~1100 gwei, so almost every run passes the assume; a uint256 would be rejected ~always)
    function testFuzz_highGasAlwaysDiscounted(uint40 gasPrice) public {
        vm.assume(gasPrice > 11 gwei);
        vm.txGasPrice(gasPrice);
        assertEq(_swapAndGetAppliedFee(), 2500);
    }

    /// Sequence fuzz: several swaps at random gas prices, each must use the band of the average *before* it
    function testFuzz_sequence(uint64[5] memory prices) public {
        for (uint256 i; i < prices.length; i++) {
            uint256 gp = bound(prices[i], 1 gwei, 200 gwei);
            uint256 avg = hook.movingAverageGasPrice();
            vm.txGasPrice(gp);
            assertEq(_swapAndGetAppliedFee(), _expectedFee(gp, avg));
        }
        assertEq(hook.movingAverageGasPriceCount(), 1 + prices.length);
    }
}
