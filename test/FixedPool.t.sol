pragma solidity ^0.8.24;

import "@limitbreak/lb-amm-core/test/LBAMMCorePoolBase.t.sol";

import {MAX_HEIGHT_SPACING} from "../src/Constants.sol";

import "../src/DataTypes.sol";
import "../src/Errors.sol";
import {FixedPoolType} from "../src/FixedPoolType.sol";
import {FixedPoolQuoter} from "../src/FixedPoolQuoter.sol";
import {FixedPoolDecoder} from "../src/libraries/FixedPoolDecoder.sol";
import {FixedHelper} from "../src/libraries/FixedHelper.sol";
import {SqrtPriceCalculator} from "@limitbreak/lb-amm-hooks-and-handlers/src/hooks/libraries/SqrtPriceCalculator.sol";
import "@limitbreak/lb-amm-core/src/DataTypes.sol";

import {MockLiquidityHookAudit} from "@limitbreak/lb-amm-core/test/mocks/MockLiquidityHookAuditAMM10.sol";

contract FixedPoolTest is LBAMMCorePoolBaseTest {
    uint160 public constant FIXED_MIN_SQRT_RATIO = 7_922_816_252;
    uint160 public constant FIXED_MAX_SQRT_RATIO = 792_281_625_142_643_375_935_439_503_360_000_000_000_000_000_000;
    FixedPoolType public fixedPool;
    FixedPoolQuoter public fixedPoolQuoter;

    uint256 public daveKey;
    address public dave;

    function setUp() public virtual override {
        super.setUp();

        (dave, daveKey) = makeAddrAndKey("dave");

        address fixedPoolAddress = address(1112);

        fixedPool = FixedPoolType(address(new FixedPoolType(address(amm))));
        vm.etch(fixedPoolAddress, address(fixedPool).code);
        fixedPool = FixedPoolType(fixedPoolAddress);
        fixedPoolQuoter = new FixedPoolQuoter(address(amm), address(fixedPool));

        vm.label(address(fixedPool), "Fixed Pool");
        vm.label(address(fixedPoolQuoter), "Fixed Quotor");
    }

    function test_correctAdjustmentOfNextHeightAbove() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), carol, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory initialParams = FixedLiquidityModificationParams({
            amount0: 100e6,
            amount1: 100 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });
        _addFixedLiquidityNoHookData(initialParams, liquidityParams, carol, bytes4(0));

        FixedHeightState memory heightState0 = fixedPool.getFixedHeightState(poolId, true);
        FixedHeightState memory heightState1 = fixedPool.getFixedHeightState(poolId, false);
        uint256 heightAbove0Before = heightState0.nextHeightAbove;
        uint256 heightAbove1Before = heightState1.nextHeightAbove;

        initialParams.amount0 = 100_000e6;
        initialParams.amount1 = 100_000 ether;

        _addFixedLiquidityNoHookData(initialParams, liquidityParams, bob, bytes4(0));

        heightState0 = fixedPool.getFixedHeightState(poolId, true);
        heightState1 = fixedPool.getFixedHeightState(poolId, false);
        uint256 heightAbove0After = heightState0.nextHeightAbove;
        uint256 heightAbove1After = heightState1.nextHeightAbove;

        assertEq(heightAbove0After, heightAbove0Before, "Height above 0 should not change");
        assertEq(heightAbove1After, heightAbove1Before, "Height above 1 should not change");
    }

    function test_proportionalWithdrawalOfDepositedLiquidity() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        fixedParams.amount0 = (fixedParams.amount0 * 49) / 100;
        fixedParams.amount1 = (fixedParams.amount1 * 20) / 100;

        (uint256 removed0, uint256 removed1,,) =
            _removeFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));

        uint256 totalRemaining0 = deposit0 - removed0;
        uint256 totalRemaining1 = deposit1 - removed1;

        fixedParams.amount0 = totalRemaining0 + 1;
        fixedParams.amount1 = totalRemaining1 + 1;

        _removeFixedLiquidity(
            fixedParams,
            liquidityParams,
            _emptyLiquidityHooksExtraData(),
            alice,
            bytes4(FixedPool__InsufficientLiquidityForRemoval.selector)
        );

        fixedParams.amount0 = totalRemaining0;
        fixedParams.amount1 = totalRemaining1;
        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));
    }

    function test_addLiquidityIncorrectInsertionHints() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 100_000_000_000,
            endHeightInsertionHint1: 100_000_000_000,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
    }

    function test_correctReserveAllocation() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        PoolState memory state = amm.getPoolState(poolId);
        uint256 reserve0 = state.reserve0;
        uint256 reserve1 = state.reserve1;

        (deposit0, deposit1,,) = _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        state = amm.getPoolState(poolId);

        assertEq(state.reserve0, reserve0 + deposit0, "Reserve0 mismatch after second add liquidity");
        assertEq(state.reserve1, reserve1 + deposit1, "Reserve1 mismatch after second add liquidity");
    }

    function test_feeGrowthCalculations() public {
        // Testing potential rounding errors in the fee growth calculation
        uint256 numOfDepositors = 10;

        address[] memory depositors = new address[](numOfDepositors);
        uint256[] memory amounts = new uint256[](numOfDepositors);
        uint256[] memory amount0Collected = new uint256[](numOfDepositors);
        uint256[] memory amount1Collected = new uint256[](numOfDepositors);

        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(currency2),
            token1: address(currency3),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 79_228_162_514_264_337_593_543_950_336, bytes4(0));

        for (uint256 i = 0; i < numOfDepositors; i++) {
            depositors[i] = address(uint160(i + 1));
            amounts[i] = 1000e6 * (i + 1);

            _mintAndApprove(address(currency2), depositors[i], address(amm), amounts[i]);
            _mintAndApprove(address(currency3), depositors[i], address(amm), amounts[i]);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: amounts[i],
                amount1: amounts[i],
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, depositors[i], bytes4(0));
        }

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});
        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

        _mintAndApprove(address(currency2), alice, address(amm), 10 ether);
        _mintAndApprove(address(currency3), alice, address(amm), 10 ether);

        uint256 expectedLPFee0 = 0;
        uint256 expectedLPFee1 = 0;

        for (uint256 i = 0; i < numOfDepositors; i++) {
            _executeFixedPoolSingleSwap(
                SwapOrder({
                    deadline: block.timestamp + 1000,
                    recipient: alice,
                    amountSpecified: 10_000e6,
                    minAmountSpecified: 0,
                    limitAmount: 0,
                    tokenIn: address(currency2),
                    tokenOut: address(currency3)
                }),
                poolId,
                exchangeFee,
                feeOnTop,
                _emptySwapHooksExtraData(),
                bytes(""),
                bytes4(0)
            );
            _executeFixedPoolSingleSwap(
                SwapOrder({
                    deadline: block.timestamp + 1000,
                    recipient: alice,
                    amountSpecified: 10_000e6,
                    minAmountSpecified: 0,
                    limitAmount: 0,
                    tokenIn: address(currency3),
                    tokenOut: address(currency2)
                }),
                poolId,
                exchangeFee,
                feeOnTop,
                _emptySwapHooksExtraData(),
                bytes(""),
                bytes4(0)
            );
            console2.log("Swap executed", i);

            uint256 expectedLPFeeforThisSwap = FullMath.mulDiv(uint256(10_000e6), 500, 10_000);
            expectedLPFee0 += expectedLPFeeforThisSwap;
            expectedLPFee1 += expectedLPFeeforThisSwap;
        }

        for (uint256 i = numOfDepositors; i < numOfDepositors; i++) {
            address depositor = depositors[i];
            uint256 amount = amounts[i];

            _mintAndApprove(address(currency2), depositor, address(amm), amount);
            _mintAndApprove(address(currency3), depositor, address(amm), amount);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: amount,
                amount1: amount,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, depositor, bytes4(0));
        }

        for (uint256 i = 0; i < numOfDepositors; i++) {
            _executeFixedPoolSingleSwap(
                SwapOrder({
                    deadline: block.timestamp + 1000,
                    recipient: alice,
                    amountSpecified: 10_000e6,
                    minAmountSpecified: 0,
                    limitAmount: 0,
                    tokenIn: address(currency2),
                    tokenOut: address(currency3)
                }),
                poolId,
                exchangeFee,
                feeOnTop,
                _emptySwapHooksExtraData(),
                bytes(""),
                bytes4(0)
            );
            _executeFixedPoolSingleSwap(
                SwapOrder({
                    deadline: block.timestamp + 1000,
                    recipient: alice,
                    amountSpecified: 10_000e6,
                    minAmountSpecified: 0,
                    limitAmount: 0,
                    tokenIn: address(currency3),
                    tokenOut: address(currency2)
                }),
                poolId,
                exchangeFee,
                feeOnTop,
                _emptySwapHooksExtraData(),
                bytes(""),
                bytes4(0)
            );

            uint256 expectedLPFeeforThisSwap = FullMath.mulDiv(uint256(10_000e6), 500, 10_000);
            expectedLPFee0 += expectedLPFeeforThisSwap;
            expectedLPFee1 += expectedLPFeeforThisSwap;
        }

        {
            uint256 totalFeesCollected0;
            uint256 totalFeesCollected1;

            for (uint256 i = 0; i < numOfDepositors; i++) {
                (amount0Collected[i], amount1Collected[i]) = _collectFixedPoolLPFees(poolId, depositors[i], bytes4(0));

                totalFeesCollected0 += amount0Collected[i];
                totalFeesCollected1 += amount1Collected[i];
            }

            uint256 protocolFee0 = amm.getProtocolFees(address(currency2));
            uint256 protocolFee1 = amm.getProtocolFees(address(currency3));

            assertApproxEqAbs(
                totalFeesCollected0, expectedLPFee0 - protocolFee0, 15, "Total fees collected token0 mismatch"
            );
            assertApproxEqAbs(
                totalFeesCollected1, expectedLPFee1 - protocolFee1, 15, "Total fees collected token1 mismatch"
            );
        }
    }

    function test_minAmountRounding() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 100_000e6 - 1,
            minLiquidityAmount1: 100_000 ether - 1,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        liquidityParams.minLiquidityAmount0 = 100_000e6 + 1;
        liquidityParams.minLiquidityAmount1 = 100_000 ether + 1;

        _addFixedLiquidityNoHookData(
            fixedParams, liquidityParams, alice, bytes4(LBAMM__InsufficientLiquidityChange.selector)
        );
    }

    function test_poolHeightPrecision() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(
            details, MAX_HEIGHT_SPACING + 1, 1, FIXED_MIN_SQRT_RATIO, bytes4(FixedPool__InvalidHeightSpacing.selector)
        );

        poolId = _createFixedPoolNoHookData(
            details, 1, MAX_HEIGHT_SPACING + 1, FIXED_MIN_SQRT_RATIO, bytes4(FixedPool__InvalidHeightSpacing.selector)
        );
    }

    function test_differentHeightSpacing() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        _createFixedPoolNoHookData(details, 8, 9, 1_120_455_419_495_722_798_374_638_764_549_163, bytes4(0));
    }

    function test_accurateHeightPrecision() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId =
            _createFixedPoolNoHookData(details, 8, 9, 1_120_455_419_495_722_798_374_638_764_549_163, bytes4(0));

        uint256 precision0Good = FixedPoolDecoder.getPoolHeightPrecision(poolId, true);
        uint256 precision1Good = FixedPoolDecoder.getPoolHeightPrecision(poolId, false);

        assertEq(precision0Good, 1e8, "Precision0 mismatch");
        assertEq(precision1Good, 1e9, "Precision1 mismatch");
    }

    function test_hookLifeCycle() public {
        MockLiquidityHookAudit mockLiquidityHookAudit = new MockLiquidityHookAudit();

        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(mockLiquidityHookAudit),
            poolParams: bytes("")
        });

        bytes32 poolId =
            _createFixedPoolNoHookData(details, 1, 1, 1_120_455_419_495_722_798_374_638_764_549_163, bytes4(0));

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        uint256 stateTrackerPosition = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByPosition();
        uint256 stateTrackerPool = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByPool();
        uint256 stateTrackerToken = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByToken();

        assertEq(stateTrackerPool, 1, "Pool state should be 1");
        assertEq(stateTrackerPosition, 0, "Position state should be not updated");
        assertEq(stateTrackerToken, 0, "Token state should be not updated");

        // Add the liquidity hook, should now trigger the state updates
        liquidityParams.liquidityHook = address(mockLiquidityHookAudit);
        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        stateTrackerPosition = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByPosition();
        stateTrackerPool = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByPool();
        stateTrackerToken = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByToken();

        assertEq(stateTrackerPool, 2, "Pool state should be 2");
        assertEq(stateTrackerPosition, 1, "Position state should be 1");
        assertEq(stateTrackerToken, 0, "Token state should be not updated");

        changePrank(usdc.owner());
        _setTokenSettings(
            address(usdc),
            address(mockLiquidityHookAudit),
            TokenFlagSettings(false, false, true, false, false, false, false, false, false, false),
            bytes4(0)
        );

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        stateTrackerPosition = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByPosition();
        stateTrackerPool = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByPool();
        stateTrackerToken = mockLiquidityHookAudit.stateOnlyToBeUpdatedIfCalledByToken();

        assertEq(stateTrackerPool, 3, "Pool state should be 3");
        assertEq(stateTrackerPosition, 2, "Position state should be 2");
        assertEq(stateTrackerToken, 1, "Token state should be 1");
    }

    function test_computePoolID() public view {
        FixedPoolCreationDetails memory fixedPoolDetails = FixedPoolCreationDetails({
            spacing0: 1,
            spacing1: 1,
            packedRatio: FixedHelper.normalizePriceToRatio(1_120_455_419_495_722_798_374_638_764_549_163)
        });

        PoolCreationDetails memory poolCreationDetails = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: abi.encode(fixedPoolDetails)
        });

        bytes32 expectedPoolId = _generatePoolId(poolCreationDetails, fixedPoolDetails);

        bytes32 poolId = fixedPool.computePoolId(poolCreationDetails);

        assertEq(poolId, expectedPoolId, "Pool ID mismatch");
    }

    function test_createFixedPool() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId =
            _createFixedPoolNoHookData(details, 1, 1, 1_120_455_419_495_722_798_374_638_764_549_163, bytes4(0));

        PoolState memory state = amm.getPoolState(poolId);

        assertEq(state.token0, details.token0, "Token0 mismatch");
        assertEq(state.token1, details.token1, "Token1 mismatch");
        assertEq(state.poolHook, details.poolHook, "Pool hook mismatch");
    }

    function test_createFixedPool_revert_InvalidPriceHigh() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        _createFixedPoolNoHookData(details, 1, 1, FIXED_MAX_SQRT_RATIO + 1, bytes4(FixedPool__InvalidPackedRatio.selector));
    }

    function test_createFixedPool_revert_InvalidPriceLow() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        _createFixedPoolNoHookData(details, 1, 1, FIXED_MIN_SQRT_RATIO - 1, bytes4(FixedPool__InvalidPackedRatio.selector));
    }

    function test_createFixedPool_revert_InvalidHeightSpacing0() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        _createFixedPoolNoHookData(
            details, MAX_HEIGHT_SPACING + 1, 1, FIXED_MIN_SQRT_RATIO, bytes4(FixedPool__InvalidHeightSpacing.selector)
        );
    }

    function test_createFixedPool_revert_InvalidHeightSpacing1() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        _createFixedPoolNoHookData(
            details, 1, MAX_HEIGHT_SPACING + 1, FIXED_MIN_SQRT_RATIO, bytes4(FixedPool__InvalidHeightSpacing.selector)
        );
    }

    function test_addFixedLiquidity() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
    }

    function test_addFixedLiquidityMultiple() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        FixedPositionInfo memory positionInfo =
            fixedPool.getPositionInfo(_generatePositionId(poolId, alice, address(0)));
        uint256 nextHeightAbove0 = fixedPool.getFixedHeightState(poolId, true).nextHeightAbove;
        uint256 nextHeightAbove1 = fixedPool.getFixedHeightState(poolId, false).nextHeightAbove;

        assertEq(nextHeightAbove0, deposit0, "heightState0 incorrect update");
        assertEq(nextHeightAbove1, deposit1, "heightState1 incorrect update");
        assertEq(positionInfo.startHeight0, 0, "positionInfo.startHeight0 incorrect");
        assertEq(positionInfo.startHeight1, 0, "positionInfo.startHeight1 incorrect");
        assertEq(positionInfo.endHeight0, deposit0, "positionInfo.endHeight0 incorrect");
        assertEq(positionInfo.endHeight1, deposit1, "positionInfo.endHeight1 incorrect");

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        (deposit0, deposit1,,) = _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        positionInfo = fixedPool.getPositionInfo(_generatePositionId(poolId, alice, address(0)));
        nextHeightAbove0 = fixedPool.getFixedHeightState(poolId, true).nextHeightAbove;
        nextHeightAbove1 = fixedPool.getFixedHeightState(poolId, false).nextHeightAbove;

        assertEq(nextHeightAbove0, deposit0 * 2, "heightState0 incorrect update");
        assertEq(nextHeightAbove1, deposit1 * 2, "heightState1 incorrect update");
        assertEq(positionInfo.startHeight0, 0, "positionInfo.startHeight0 incorrect");
        assertEq(positionInfo.startHeight1, 0, "positionInfo.startHeight1 incorrect");
        assertEq(positionInfo.endHeight0, deposit0 * 2, "positionInfo.endHeight0 incorrect");
        assertEq(positionInfo.endHeight1, deposit1 * 2, "positionInfo.endHeight1 incorrect");
    }

    function test_addFixedLiquidityNoLiquidityChange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 0,
            amount1: 0,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, FixedPool__BothTokenAmountsZeroOnDeposit.selector);

        assertEq(deposit0, 0, "Deposit0 should be 0");
        assertEq(deposit1, 0, "Deposit1 should be 0");

        FixedPositionInfo memory positionInfo =
            fixedPool.getPositionInfo(_generatePositionId(poolId, alice, address(0)));
        uint256 nextHeightAbove0 = fixedPool.getFixedHeightState(poolId, true).nextHeightAbove;
        uint256 nextHeightAbove1 = fixedPool.getFixedHeightState(poolId, false).nextHeightAbove;

        assertEq(nextHeightAbove0, deposit0, "heightState0 incorrect update");
        assertEq(nextHeightAbove1, deposit1, "heightState1 incorrect update");
        assertEq(positionInfo.startHeight0, 0, "positionInfo.startHeight0 incorrect");
        assertEq(positionInfo.startHeight1, 0, "positionInfo.startHeight1 incorrect");
        assertEq(positionInfo.endHeight0, deposit0, "positionInfo.endHeight0 incorrect");
        assertEq(positionInfo.endHeight1, deposit1, "positionInfo.endHeight1 incorrect");

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        fixedParams.amount0 = 100_000e6;
        fixedParams.amount1 = 100_000 ether;

        (deposit0, deposit1,,) = _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        positionInfo = fixedPool.getPositionInfo(_generatePositionId(poolId, alice, address(0)));
        nextHeightAbove0 = fixedPool.getFixedHeightState(poolId, true).nextHeightAbove;
        nextHeightAbove1 = fixedPool.getFixedHeightState(poolId, false).nextHeightAbove;

        assertEq(nextHeightAbove0, deposit0, "heightState0 incorrect update");
        assertEq(nextHeightAbove1, deposit1, "heightState1 incorrect update");
        assertEq(positionInfo.startHeight0, 0, "positionInfo.startHeight0 incorrect");
        assertEq(positionInfo.startHeight1, 0, "positionInfo.startHeight1 incorrect");
        assertEq(positionInfo.endHeight0, deposit0, "positionInfo.endHeight0 incorrect");
        assertEq(positionInfo.endHeight1, deposit1, "positionInfo.endHeight1 incorrect");

        fixedParams.amount0 = 0;
        fixedParams.amount1 = 0;

        (deposit0, deposit1,,) = _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, FixedPool__BothTokenAmountsZeroOnDeposit.selector);

        assertEq(deposit0, 0, "Deposit0 should be 0");
        assertEq(deposit1, 0, "Deposit1 should be 0");

        FixedPositionInfo memory positionInfoNew =
            fixedPool.getPositionInfo(_generatePositionId(poolId, alice, address(0)));
        uint256 nextHeightAbove0New = fixedPool.getFixedHeightState(poolId, true).nextHeightAbove;
        uint256 nextHeightAbove1New = fixedPool.getFixedHeightState(poolId, false).nextHeightAbove;

        assertEq(nextHeightAbove0New, nextHeightAbove0, "heightState0 incorrect update");
        assertEq(nextHeightAbove1New, nextHeightAbove1, "heightState1 incorrect update");
        assertEq(positionInfoNew.startHeight0, positionInfo.startHeight0, "positionInfo.startHeight0 incorrect");
        assertEq(positionInfoNew.startHeight1, positionInfo.startHeight1, "positionInfo.startHeight1 incorrect");
        assertEq(positionInfoNew.endHeight0, positionInfo.endHeight0, "positionInfo.endHeight0 incorrect");
        assertEq(positionInfoNew.endHeight1, positionInfo.endHeight1, "positionInfo.endHeight1 incorrect");
    }

    function test_removeFixedLiquidity() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        fixedParams.amount0 = deposit0 / 2;
        fixedParams.amount1 = deposit1;

        _removeFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));
        _removeFixedLiquidity(
            fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(PANIC_SELECTOR)
        );
    }

    function test_removeFixedLiquidityMultiple() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        fixedParams.amount0 = deposit0 / 2;
        fixedParams.amount1 = deposit1 / 2;

        _removeFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));
    }

    function test_removeFixedLiquidityMultiple_addInRange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: true,
            addInRange1: true,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        fixedParams.amount0 = deposit0 / 2;
        fixedParams.amount1 = deposit1 / 2;

        _removeFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));
    }

    function test_removeFixedLiquidity_halfLiquidity() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        fixedParams.amount0 = deposit0 / 2;
        fixedParams.amount1 = deposit1 / 2;

        _removeFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));
    }

    function test_addLiquidityRemovePartialAddLiquidityRemoveAll() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        fixedParams.amount0 = deposit0 / 2;
        fixedParams.amount1 = deposit1 / 2;

        _removeFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));

        fixedParams.amount0 = deposit0;
        fixedParams.amount1 = deposit1;

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: deposit0 + (deposit0 / 2),
            minAmount1: deposit1 + (deposit0 / 2)
        });
        _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), alice, bytes4(0));
    }

    function test_addMultipleLiquidityRemoveOneLpFeeAllocation() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), carol, address(amm), 1_000_000 ether);
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1_000e6, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1 ether, 0, 0, address(weth), address(usdc)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        uint256 fee0AliceCollected;
        uint256 fee1AliceCollected;
        uint256 fee0BobCollected;
        uint256 fee1BobCollected;
        {
            (fee0AliceCollected, fee1AliceCollected) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected, fee1BobCollected) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));

            assertEq(fee0BobCollected, fee0AliceCollected, "Fixed Liquidity: fee0 collected should be equal");
            assertEq(fee1BobCollected, fee1AliceCollected, "Fixed Liquidity: fee1 collected should be equal");
        }

        PoolState memory state = amm.getPoolState(poolId);

        FixedLiquidityWithdrawAllParams memory withdrawParams;

        _removeAllFixedLiquidity(withdrawParams, liquidityParams, _emptyLiquidityHooksExtraData(), bob, bytes4(0));

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1_000e6, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1 ether, 0, 0, address(weth), address(usdc)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        state = amm.getPoolState(poolId);

        {
            (fee0AliceCollected, fee1AliceCollected) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected, fee1BobCollected) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            
            uint160 currentPriceX96 = fixedPool.getCurrentPriceX96(address(amm), poolId);
            uint256 allowedSwapDeviation0For1 = FixedHelper.calculateFixedSwap(1, currentPriceX96, true);
            uint256 allowedSwapDeviation1For0 = FixedHelper.calculateFixedSwap(1, currentPriceX96, false);
            uint256 allowedLPFeeDeviation0 = allowedSwapDeviation0For1 + FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(1, Q96, currentPriceX96), Q96, currentPriceX96);
            uint256 allowedLPFeeDeviation1 = allowedSwapDeviation1For0 + FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(1, currentPriceX96, Q96), currentPriceX96, Q96);

            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertEq(fee1BobCollected, 0, "Fixed Liquidity: fee1 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 49375000, allowedLPFeeDeviation0, "Fixed Liquidity: fee0 collected should be 49375000");
            assertApproxEqAbs(fee1AliceCollected, 49375000000000000, allowedLPFeeDeviation1, "Fixed Liquidity: fee1 collected should be 49375000000000000");
        }
    }

    function test_addMultipleLiquidityRemoveOneBeforeSwapLpFeeAllocation() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        (uint256 deposit0Bob, uint256 deposit1Bob,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));
        console2.log("Bob Deposit0: %d, Deposit1: %d", deposit0Bob, deposit1Bob);

        fixedParams.amount0 = deposit0Bob;
        fixedParams.amount1 = deposit1Bob;

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        (uint256 bobWithdraw0, uint256 bobWithdraw1,,) =
            _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), bob, bytes4(0));
        console2.log("Bob Withdraw0: %d, Withdraw1: %d", bobWithdraw0, bobWithdraw1);

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("Carol executes swap: 1000 in");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        uint256 fee0AliceCollected;
        uint256 fee0BobCollected;
        {
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
        }

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));

            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
        }
    }

    function test_addMultipleLiquidityRemoveOneBeforeSwapReaddAfterSwapFeeAllocation_base() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        (uint256 deposit0Bob, uint256 deposit1Bob,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        fixedParams.amount0 = deposit0Bob;
        fixedParams.amount1 = deposit1Bob;

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), bob, bytes4(0));

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("Carol executes swap: 1000 in");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        uint256 fee0AliceCollected;
        uint256 fee0BobCollected;
        {
            console2.log("Collecting fees after first swap and bob readd");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
        }

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            console2.log("Collecting fees after second swap");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            console2.log("Alice collected fee0: %d", fee0AliceCollected);
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            console2.log("Bob collected fee0: %d", fee0BobCollected);

            assertEq(fee0AliceCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
            assertEq(fee0BobCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
        }
    }

    function test_addMultipleLiquidityAddOneSwapThenAddAnotherFeeAllocation() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("----- Carol executes swap 1 -----");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        console2.log("----- Bob adds liquidity -----");
        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        uint256 fee0AliceCollected;
        uint256 fee0BobCollected;
        {
            console2.log("---- alice collects fees ----");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            console2.log("---- bob collects fees ----");

            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
        }

        console2.log("----- Carol executes swap 2 -----");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            console2.log("Collecting fees after second swap");
            console2.log("---- alice collects fees ----");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            console2.log("Alice collected fee0: %d", fee0AliceCollected);
            console2.log("---- bob collects fees ----");
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            console2.log("Bob collected fee0: %d", fee0BobCollected);

            assertEq(fee0AliceCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
            assertEq(fee0BobCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
        }
    }

    function test_addMultipleLiquidityRemoveOneLpFeeAllocation_addInRange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: true,
            addInRange1: true,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), carol, address(amm), 1_000_000 ether);
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1_000e6, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1 ether, 0, 0, address(weth), address(usdc)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        uint256 fee0AliceCollected;
        uint256 fee1AliceCollected;
        uint256 fee0BobCollected;
        uint256 fee1BobCollected;
        {
            (fee0AliceCollected, fee1AliceCollected) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected, fee1BobCollected) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));

            assertEq(fee0BobCollected, fee0AliceCollected, "Fixed Liquidity: fee0 collected should be equal");
            assertEq(fee1BobCollected, fee1AliceCollected, "Fixed Liquidity: fee1 collected should be equal");
        }

        PoolState memory state = amm.getPoolState(poolId);

        FixedLiquidityWithdrawAllParams memory withdrawParams;

        _removeAllFixedLiquidity(withdrawParams, liquidityParams, _emptyLiquidityHooksExtraData(), bob, bytes4(0));

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1_000e6, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1 ether, 0, 0, address(weth), address(usdc)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            (fee0AliceCollected, fee1AliceCollected) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected, fee1BobCollected) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            
            uint160 currentPriceX96 = fixedPool.getCurrentPriceX96(address(amm), poolId);
            uint256 allowedLPFeeDeviation0 = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(1, Q96, currentPriceX96), Q96, currentPriceX96);
            uint256 allowedLPFeeDeviation1 = FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(1, currentPriceX96, Q96), currentPriceX96, Q96);

            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertEq(fee1BobCollected, 0, "Fixed Liquidity: fee1 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 49375000, allowedLPFeeDeviation0, "Fixed Liquidity: fee0 collected should be 49375000");
            assertApproxEqAbs(fee1AliceCollected, 49375000000000000, allowedLPFeeDeviation1, "Fixed Liquidity: fee1 collected should be 49375000000000000");
        }
    }

    function test_addMultipleLiquidityRemoveOneBeforeSwapLpFeeAllocation_addInRange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: true,
            addInRange1: true,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        (uint256 deposit0Bob, uint256 deposit1Bob,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));
        console2.log("Bob Deposit0: %d, Deposit1: %d", deposit0Bob, deposit1Bob);

        fixedParams.amount0 = deposit0Bob;
        fixedParams.amount1 = deposit1Bob;

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        (uint256 bobWithdraw0, uint256 bobWithdraw1,,) =
            _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), bob, bytes4(0));
        console2.log("Bob Withdraw0: %d, Withdraw1: %d", bobWithdraw0, bobWithdraw1);

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("Carol executes swap: 1000 in");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        uint256 fee0AliceCollected;
        uint256 fee0BobCollected;
        {
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
        }

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));

            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
        }
    }

    function test_addMultipleLiquidityRemoveOneBeforeSwapReaddAfterSwapFeeAllocation_addInRange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: true,
            addInRange1: true,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        (uint256 deposit0Bob, uint256 deposit1Bob,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        fixedParams.amount0 = deposit0Bob;
        fixedParams.amount1 = deposit1Bob;

        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: fixedParams.amount0,
            minAmount1: fixedParams.amount1
        });
        _removeAllFixedLiquidity(withdrawAllParams, liquidityParams, _emptyLiquidityHooksExtraData(), bob, bytes4(0));

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("Carol executes swap: 1000 in");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        uint256 fee0AliceCollected;
        uint256 fee0BobCollected;
        {
            console2.log("Collecting fees after first swap and bob readd");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
        }

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            console2.log("Collecting fees after second swap");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            console2.log("Alice collected fee0: %d", fee0AliceCollected);
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            console2.log("Bob collected fee0: %d", fee0BobCollected);

            assertEq(fee0AliceCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
            assertEq(fee0BobCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
        }
    }

    function test_addMultipleLiquidityAddOneSwapThenAddAnotherFeeAllocation_addInRange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(usdc), bob, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), bob, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: true,
            addInRange1: true,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("----- Carol executes swap 1 -----");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        console2.log("----- Bob adds liquidity -----");
        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, bob, bytes4(0));

        uint256 fee0AliceCollected;
        uint256 fee0BobCollected;
        {
            console2.log("---- alice collects fees ----");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            console2.log("---- bob collects fees ----");

            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            assertEq(fee0BobCollected, 0, "Fixed Liquidity: fee0 collected should be 0");
            assertApproxEqAbs(fee0AliceCollected, 50, 1, "Fixed Liquidity: fee0 collected should be 50");
        }

        console2.log("----- Carol executes swap 2 -----");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        {
            console2.log("Collecting fees after second swap");
            console2.log("---- alice collects fees ----");
            (fee0AliceCollected,) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));
            console2.log("Alice collected fee0: %d", fee0AliceCollected);
            console2.log("---- bob collects fees ----");
            (fee0BobCollected,) = _collectFixedPoolLPFees(poolId, bob, bytes4(0));
            console2.log("Bob collected fee0: %d", fee0BobCollected);

            assertEq(fee0AliceCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
            assertEq(fee0BobCollected, 25, "Fixed Liquidity: fee0 collected should be 25");
        }
    }

    function test_addLiquiditySwapThenAddAdditionalLiquidityToSamePosition() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0Alice, uint256 deposit1Alice,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("----- Carol executes swap 1 -----");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        (deposit0Alice, deposit1Alice,,) = _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        console2.log("Alice additional Deposit0: %d, Deposit1: %d", deposit0Alice, deposit1Alice);

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );
    }

    function test_addLiquiditySwapThenAddAdditionalLiquidityToSamePosition_addInRange() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: true,
            addInRange1: true,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        changePrank(carol);
        _mintAndApprove(address(usdc), carol, address(amm), 1_000_000e6);
        console2.log("----- Carol executes swap 1 -----");
        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        _executeFixedPoolSingleSwap(
            SwapOrder(block.timestamp + 1, carol, 1000, 0, 0, address(usdc), address(weth)),
            poolId,
            BPSFeeWithRecipient(address(0), 0),
            FlatFeeWithRecipient(address(0), 0),
            _emptySwapHooksExtraData(),
            bytes(""),
            bytes4(0)
        );
    }

    function test_removeFixedLiquidity_revert_InsufficientLiquidityToken0() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        fixedParams.amount0 = deposit0 + 1;
        fixedParams.amount1 = deposit1;

        _removeFixedLiquidity(
            fixedParams,
            liquidityParams,
            _emptyLiquidityHooksExtraData(),
            alice,
            bytes4(FixedPool__InsufficientLiquidityForRemoval.selector)
        );
    }

    function test_removeFixedLiquidity_revert_InsufficientLiquidityToken1() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        (uint256 deposit0, uint256 deposit1,,) =
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));

        fixedParams.amount0 = deposit0;
        fixedParams.amount1 = deposit1 + 1;

        _removeFixedLiquidity(
            fixedParams,
            liquidityParams,
            _emptyLiquidityHooksExtraData(),
            alice,
            bytes4(FixedPool__InsufficientLiquidityForRemoval.selector)
        );
    }

    function _createFixedPool(
        PoolCreationDetails memory details,
        uint8 spacing0,
        uint8 spacing1,
        uint160 sqrtPriceRatioX96,
        bytes memory token0HookData,
        bytes memory token1HookData,
        bytes memory poolHookData,
        bytes4 errorSelector
    ) internal returns (bytes32 poolId) {
        details.poolParams = abi.encode(
            FixedPoolCreationDetails({spacing0: spacing0, spacing1: spacing1, packedRatio: FixedHelper.normalizePriceToRatio(sqrtPriceRatioX96)})
        );
        poolId = _createPool(details, token0HookData, token1HookData, poolHookData, errorSelector);
    }

    function _createFixedPoolNoHookData(
        PoolCreationDetails memory details,
        uint8 spacing0,
        uint8 spacing1,
        uint160 sqrtPriceRatioX96,
        bytes4 errorSelector
    ) internal returns (bytes32 poolId) {
        poolId = _createFixedPool(
            details, spacing0, spacing1, sqrtPriceRatioX96, bytes(""), bytes(""), bytes(""), errorSelector
        );
    }

    function _createStandardFixedPool() internal returns (bytes32 poolId) {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        poolId = _createFixedPoolNoHookData(details, 1, 1, 1_120_455_419_495_722_798_374_638_764_549_163, bytes4(0));
    }

    function _addFixedLiquidity(
        FixedLiquidityModificationParams memory fixedParams,
        LiquidityModificationParams memory liquidityParams,
        LiquidityHooksExtraData memory liquidityHooksExtraData,
        address provider,
        bytes4 errorSelector
    ) internal returns (uint256 deposit0, uint256 deposit1, uint256 fee0, uint256 fee1) {
        liquidityParams.poolParams = abi.encode(fixedParams);
        changePrank(provider);
        (deposit0, deposit1, fee0, fee1) = _executeAddLiquidity(liquidityParams, liquidityHooksExtraData, errorSelector);

        if (errorSelector == bytes4(0)) {
            // if (fixedParams.addInRange0) {
            //     assertApproxEqAbs(deposit0, fixedParams.amount0, 5, "deposit0 mismatch");
            // } else {
            //     assertEq(deposit0, fixedParams.amount0, "deposit0 mismatch");
            // }
            // if (fixedParams.addInRange1) {
            //     assertApproxEqAbs(deposit1, fixedParams.amount1, 5, "deposit1 mismatch");
            // } else {
            //     assertEq(deposit1, fixedParams.amount1, "deposit1 mismatch");
            // }
        }
    }

    function _addFixedLiquidityNoHookData(
        FixedLiquidityModificationParams memory fixedParams,
        LiquidityModificationParams memory liquidityParams,
        address provider,
        bytes4 errorSelector
    ) internal returns (uint256 deposit0, uint256 deposit1, uint256 fee0, uint256 fee1) {
        (deposit0, deposit1, fee0, fee1) =
            _addFixedLiquidity(fixedParams, liquidityParams, _emptyLiquidityHooksExtraData(), provider, errorSelector);
    }

    function _addStandardFixedLiquidity(bytes32 poolId) internal {
        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
            liquidityHook: address(0),
            poolId: poolId,
            minLiquidityAmount0: 0,
            minLiquidityAmount1: 0,
            maxLiquidityAmount0: type(uint256).max,
            maxLiquidityAmount1: type(uint256).max,
            maxHookFee0: type(uint256).max,
            maxHookFee1: type(uint256).max,
            poolParams: bytes("")
        });

        FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
            amount0: 100_000e6,
            amount1: 100_000 ether,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
        });

        _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
    }

    function _removeFixedLiquidity(
        FixedLiquidityModificationParams memory fixedParams,
        LiquidityModificationParams memory liquidityParams,
        LiquidityHooksExtraData memory liquidityHooksExtraData,
        address provider,
        bytes4 errorSelector
    ) internal returns (uint256 withdraw0, uint256 withdraw1, uint256 fee0, uint256 fee1) {
        FixedLiquidityWithdrawalParams memory fixedWithdrawalParams = FixedLiquidityWithdrawalParams({
            withdrawAll: false,
            params: abi.encode(fixedParams)
        });
        liquidityParams.poolParams = abi.encode(fixedWithdrawalParams);

        changePrank(provider);

        (withdraw0, withdraw1, fee0, fee1) =
            _executeRemoveLiquidity(liquidityParams, liquidityHooksExtraData, errorSelector);

        if (errorSelector == bytes4(0)) {
            assertEq(withdraw0, fixedParams.amount0, "Fixed Liquidity: withdraw0 mismatch");
            assertEq(withdraw1, fixedParams.amount1, "Fixed Liquidity: withdraw1 mismatch");
        }
    }

    function _removeAllFixedLiquidity(
        FixedLiquidityWithdrawAllParams memory fixedParams,
        LiquidityModificationParams memory liquidityParams,
        LiquidityHooksExtraData memory liquidityHooksExtraData,
        address provider,
        bytes4 errorSelector
    ) internal returns (uint256 withdraw0, uint256 withdraw1, uint256 fee0, uint256 fee1) {
        FixedLiquidityWithdrawalParams memory fixedWithdrawalParams = FixedLiquidityWithdrawalParams({
            withdrawAll: true,
            params: abi.encode(fixedParams)
        });
        liquidityParams.poolParams = abi.encode(fixedWithdrawalParams);

        changePrank(provider);

        (withdraw0, withdraw1, fee0, fee1) =
            _executeRemoveLiquidity(liquidityParams, liquidityHooksExtraData, errorSelector);

        if (errorSelector == bytes4(0)) {
            assertGe(withdraw0, fixedParams.minAmount0, "Fixed Liquidity: withdraw0 mismatch");
            assertGe(withdraw1, fixedParams.minAmount1, "Fixed Liquidity: withdraw1 mismatch");
        }
    }

    function test_swapByInputFixedPool() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolId);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});

        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

        _swapByInputFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
    }

    function test_swapByInputOneForZeroFixedPool() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolId);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});

        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

        _swapByInputOneForZeroFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
    }

    function test_swapByOutputFixedPool() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolId);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});

        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

        _swapByOutputFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
    }

    function test_swapByOutputOneForZeroSwapFixedPool() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolId);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});

        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

        _swapByOutputOneForZeroFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
    }

    function test_multiSwap_swapByInput() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32[] memory poolIds = new bytes32[](2);

        poolIds[0] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[0]);

        details.token0 = address(weth);
        details.token1 = address(currency2);

        poolIds[1] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(currency2), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[1]);

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(100e6),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(usdc),
            tokenOut: address(currency2)
        });

        SwapHooksExtraData[] memory swapHooksExtraData = new SwapHooksExtraData[](2);
        bytes memory transferData;
        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        _executeFixedPoolMultiSwap(
            swapOrder, poolIds, exchangeFee, feeOnTop, swapHooksExtraData, transferData, bytes4(0)
        );
    }

    function test_multiSwap_swapByInputWithTokenHook() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32[] memory poolIds = new bytes32[](2);

        poolIds[0] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[0]);

        details.token0 = address(weth);
        details.token1 = address(currency2);

        poolIds[1] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(currency2), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[1]);

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(100e6),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(usdc),
            tokenOut: address(currency2)
        });

        SwapHooksExtraData[] memory swapHooksExtraData = new SwapHooksExtraData[](2);
        bytes memory transferData;
        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        MultiHopHopCountAndIndexHook mhhcih = new MultiHopHopCountAndIndexHook();
        {
            changePrank(address(0));
            amm.setTokenSettings(address(currency2), address(mhhcih), TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG);
            changePrank(alice);
        }

        _executeFixedPoolMultiSwap(
            swapOrder, poolIds, exchangeFee, feeOnTop, swapHooksExtraData, transferData, bytes4(0)
        );

        // Validate the currency 2 hop was index 1
        assertEq(mhhcih.lastHopIndex(), 1);
        // Validate the swap contained two hops.
        assertEq(mhhcih.lastNumberOfHops(), 2);
    }

    function test_multiSwap_swapByOutput() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32[] memory poolIds = new bytes32[](2);

        poolIds[0] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[0]);

        details.token0 = address(weth);
        details.token1 = address(currency2);

        poolIds[1] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(currency2), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[1]);

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: -int256(90_250_000),
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(usdc),
            tokenOut: address(currency2)
        });

        bytes32[] memory poolIdsFlip = new bytes32[](2);
        poolIdsFlip[0] = poolIds[1];
        poolIdsFlip[1] = poolIds[0];

        SwapHooksExtraData[] memory swapHooksExtraData = new SwapHooksExtraData[](2);
        bytes memory transferData;
        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        _executeFixedPoolMultiSwap(
            swapOrder, poolIdsFlip, exchangeFee, feeOnTop, swapHooksExtraData, transferData, bytes4(0)
        );
    }

    function test_multiSwap_swapByOutputWithTokenHook() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32[] memory poolIds = new bytes32[](2);

        poolIds[0] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[0]);

        details.token0 = address(weth);
        details.token1 = address(currency2);

        poolIds[1] = _createFixedPoolNoHookData(details, 1, 1, _calculatePriceLimit(1, 1), bytes4(0));

        _mintAndApprove(address(currency2), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolIds[1]);

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: -int256(90_250_000),
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(usdc),
            tokenOut: address(currency2)
        });

        bytes32[] memory poolIdsFlip = new bytes32[](2);
        poolIdsFlip[0] = poolIds[1];
        poolIdsFlip[1] = poolIds[0];

        SwapHooksExtraData[] memory swapHooksExtraData = new SwapHooksExtraData[](2);
        bytes memory transferData;
        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        MultiHopHopCountAndIndexHook mhhcih = new MultiHopHopCountAndIndexHook();
        {
            changePrank(address(0));
            amm.setTokenSettings(address(currency2), address(mhhcih), TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG);
            changePrank(alice);
        }

        _executeFixedPoolMultiSwap(
            swapOrder, poolIdsFlip, exchangeFee, feeOnTop, swapHooksExtraData, transferData, bytes4(0)
        );

        // Validate the currency 2 hop was index 0
        assertEq(mhhcih.lastHopIndex(), 0);
        // Validate the swap contained two hops.
        assertEq(mhhcih.lastNumberOfHops(), 2);
    }

    function test_singleSwap_ExchangeFeeAndFeeOnTop() public {
        bytes32 poolId = _createStandardFixedPool();

        _mintAndApprove(address(usdc), alice, address(amm), 1_000_000e6);
        _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

        _addStandardFixedLiquidity(poolId);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 100, recipient: exchangeFeeRecipient});

        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 100, recipient: feeOnTopRecipient});

        _swapByInputFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
        _swapByOutputFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
        _swapByInputOneForZeroFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
        _swapByOutputOneForZeroFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));
    }

    function test_singleSwap_swapByInput_partialFill() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 79_228_162_514_264_337_593_543_950_336, bytes4(0));

        {
            _mintAndApprove(address(usdc), alice, address(amm), 1_000_000 ether);
            _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: 10 ether,
                amount1: 10 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolId);
        uint256 reserves1 = poolState.reserve1;

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(reserves1 * 1055 / 1000),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        (, uint256 amountIn) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        assertLt(amountIn, uint256(swapOrder.amountSpecified), "Amount in should be less than specified");
    }

    function test_singleSwap_swapByInput_partialFillWithExchangeFee() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 79_228_162_514_264_337_593_543_950_336, bytes4(0));

        {
            _mintAndApprove(address(usdc), alice, address(amm), 1_000_000 ether);
            _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: 10 ether,
                amount1: 10 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({
            recipient: dave,
            BPS: 500
        });
        FlatFeeWithRecipient memory feeOnTop;

        PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolId);
        uint256 reserves1 = poolState.reserve1;

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(reserves1 * 1500 / 1000),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        (, uint256 amountIn) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0), false
        );

        assertLt(amountIn, uint256(swapOrder.amountSpecified), "Amount in should be less than specified");
    }

    function test_singleSwap_swapByOutput_partialFill() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 79_228_162_514_264_337_593_543_950_336, bytes4(0));

        {
            _mintAndApprove(address(usdc), alice, address(amm), 1_000_000 ether);
            _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: 10 ether,
                amount1: 10 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolId);
        uint256 reserves0 = poolState.reserve0;

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: -int256(reserves0 * 1055 / 1000),
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        (, uint256 amountOut) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        assertLt(amountOut, uint256(-swapOrder.amountSpecified), "Amount out should be less than specified");
    }

    function test_singleSwap_partialFill_compareInputAndOutputBased() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 79_228_162_514_264_337_593_543_950_336, bytes4(0));

        {
            _mintAndApprove(address(usdc), alice, address(amm), 1_000_000 ether);
            _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: 10 ether,
                amount1: 10 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolId);
        uint256 reserves0 = poolState.reserve0;
        uint256 reserves1 = poolState.reserve1;

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(reserves1 * 1055 / 1000),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        uint256 snapshot = vm.snapshot();

        (uint256 amountInSwapByInput, uint256 amountOutSwapByOut) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        vm.revertToState(snapshot);

        swapOrder.amountSpecified = -int256(reserves0 * 1055 / 1000);
        swapOrder.limitAmount = type(uint256).max;

        (uint256 amountInSwapByOutput, uint256 amountOutSwapByInput) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        assertEq(amountInSwapByInput, amountInSwapByOutput, "Amount in mismatch");
        assertEq(amountOutSwapByOut, amountOutSwapByInput, "Amount out mismatch");
    }

    function test_singleSwap_partialFillMinAmount() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 79_228_162_514_264_337_593_543_950_336, bytes4(0));

        {
            _mintAndApprove(address(usdc), alice, address(amm), 1_000_000 ether);
            _mintAndApprove(address(weth), alice, address(amm), 1_000_000 ether);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: 10 ether,
                amount1: 10 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        BPSFeeWithRecipient memory exchangeFee;
        FlatFeeWithRecipient memory feeOnTop;

        PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolId);
        uint256 reserves0 = poolState.reserve0;
        uint256 reserves1 = poolState.reserve1;

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(reserves1 * 1055 / 1000),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        uint256 snapshot = vm.snapshot();

        (uint256 amountInSwapByInput, uint256 amountOutSwapByOut) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        vm.revertToState(snapshot);

        swapOrder.minAmountSpecified = amountInSwapByInput + 1;
        _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), LBAMM__PartialFillLessThanMinimumSpecified.selector
        );

        vm.revertToState(snapshot);

        swapOrder.amountSpecified = -int256(reserves0 * 1055 / 1000);
        swapOrder.minAmountSpecified = 0;
        swapOrder.limitAmount = type(uint256).max;

        (uint256 amountInSwapByOutput, uint256 amountOutSwapByInput) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        vm.revertToState(snapshot);

        swapOrder.minAmountSpecified = amountOutSwapByInput + 1;
        _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), LBAMM__PartialFillLessThanMinimumSpecified.selector
        );

        assertEq(amountInSwapByInput, amountInSwapByOutput, "Amount in mismatch");
        assertEq(amountOutSwapByOut, amountOutSwapByInput, "Amount out mismatch");
    }

    function test_currentPriceX96() public {
        bytes32 poolId = _createStandardFixedPool();

        uint160 currentPriceX96 = fixedPool.getCurrentPriceX96(address(amm), poolId);
        (uint256 ratio0, uint256 ratio1) = FixedHelper.unpackRatio(
            FixedHelper.normalizePriceToRatio(1_120_455_419_495_722_798_374_638_764_549_163),
            false
        );
        uint256 adjustedPriceX96 = SqrtPriceCalculator.computeRatioX96(ratio1, ratio0);

        assertEq(currentPriceX96, adjustedPriceX96, "Current price mismatch");
    }

    function test_collectFeesFixedPool() public {
        bytes32 poolId = _createStandardFixedPool();

        _addStandardFixedLiquidity(poolId);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});

        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

        _swapByInputFixedPoolNoExtraData(alice, poolId, exchangeFee, feeOnTop, bytes4(0));

        (uint256 fee0, uint256 fee1) = _collectFixedPoolLPFees(poolId, alice, bytes4(0));

        assertGt(fee0, 0, "Collected amount0 should be greater than zero");
        assertEq(fee1, 0, "Collected amount1 should be greater than zero");
    }

    function _collectFixedPoolLPFees(bytes32 poolId, address provider, bytes4 errorSelector)
        internal
        returns (uint256 fee0, uint256 fee1)
    {
        LiquidityCollectFeesParams memory liquidityParams =
            LiquidityCollectFeesParams({
                poolId: poolId,
                liquidityHook: address(0),
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

        changePrank(provider);
        (fee0, fee1) = _executeCollectFees(liquidityParams, _emptyLiquidityHooksExtraData(), errorSelector);
    }

    function _swapByInputFixedPool(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: recipient,
            amountSpecified: 1000e6,
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(usdc),
            tokenOut: address(weth)
        });

        return _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector
        );
    }

    function _swapByInputOneForZeroFixedPool(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal {
        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: recipient,
            amountSpecified: 1000e6,
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector
        );
    }

    function _swapByInputFixedPoolNoExtraData(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        bytes4 errorSelector
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        return _swapByInputFixedPool(
            recipient, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), errorSelector
        );
    }

    function _swapByInputOneForZeroFixedPoolNoExtraData(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        bytes4 errorSelector
    ) internal {
        _swapByInputOneForZeroFixedPool(
            recipient, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), errorSelector
        );
    }

    function _swapByOutputFixedPool(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal {
        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: recipient,
            amountSpecified: -1 ether,
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(usdc),
            tokenOut: address(weth)
        });

        _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector
        );
    }

    function _swapByOutputOneForZeroFixedPool(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal {
        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: recipient,
            amountSpecified: -1000e6,
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector
        );
    }

    function _swapByOutputFixedPoolNoExtraData(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        bytes4 errorSelector
    ) internal {
        _swapByOutputFixedPool(
            recipient, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), errorSelector
        );
    }

    function _swapByOutputOneForZeroFixedPoolNoExtraData(
        address recipient,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        bytes4 errorSelector
    ) internal {
        _swapByOutputOneForZeroFixedPool(
            recipient, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), errorSelector
        );
    }

    struct TestSwapCache {
        bool zeroForOne;
        bool inputSwap;
        uint16 poolFeeBPS;
        uint256 expectedLpFee;
        uint256 expectedProtocolFee;
        uint256 expectedAmountIn;
        uint256 expectedAmountOut;
    }

    function _initializeSwapTestCache(bytes32 poolId, SwapTestCache memory cache, SwapOrder memory swapOrder)
        internal
        view
    {
        PoolState memory state = LimitBreakAMM(amm).getPoolState(poolId);

        _initializeProtocolFees(cache, swapOrder);

        cache.poolId = poolId;
        cache.poolFeeBPS = _getPoolFee(poolId);
        cache.inputSwap = swapOrder.amountSpecified > 0;
        cache.zeroForOne = swapOrder.tokenIn < swapOrder.tokenOut;
        cache.reserveOut = cache.zeroForOne ? state.reserve1 : state.reserve0;
        cache.amountSpecifiedAbs = uint256(cache.inputSwap ? swapOrder.amountSpecified : -swapOrder.amountSpecified);
    }

    function _executeFixedPoolSingleSwap(
        SwapOrder memory swapOrder,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        (amountIn, amountOut) = _executeFixedPoolSingleSwap(swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector, true);
    }

    function _executeFixedPoolSingleSwap(
        SwapOrder memory swapOrder,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector,
        bool verifyProtocolFees
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        SwapTestCache memory cache;

        _initializeSwapTestCache(poolId, cache, swapOrder);

        ProtocolFeeStructure memory protocolFeeStructure = _getProtocolFeeStructure(poolId, exchangeFee, feeOnTop);

        if (swapOrder.amountSpecified > 0) {
            _applyBeforeSwapFeesSwapByInput(cache, swapOrder, exchangeFee, feeOnTop, protocolFeeStructure);

            _calculateSwapByInputSwap(cache, protocolFeeStructure);

            _applyAfterSwapFeesSwapByInput(cache, swapOrder);
        } else {
            _applyBeforeSwapFeesSwapByOutput(cache, swapOrder);

            _calculateSwapByOutputSwap(cache, protocolFeeStructure);

            _applyAfterSwapFeesSwapByOutput(cache, swapOrder, exchangeFee, feeOnTop, protocolFeeStructure);
        }
        {
            changePrank(swapOrder.recipient);
            (amountIn, amountOut) = _executeSingleSwap(
                swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector
            );
        }

        if (errorSelector == bytes4(0)) {
            if (swapOrder.amountSpecified > 0) {
                assertApproxEqAbs(amountOut, cache.amountUnspecifiedExpected, 1, "Fixed Swap: Amount out mismatch");
            } else {
                FixedPoolStateView memory state = fixedPool.getFixedPoolState(cache.poolId);
                uint256 allowedDeviation = FixedHelper.calculateFixedSwap(1, state.sqrtPriceX96, !cache.zeroForOne) + 1;
                assertApproxEqAbs(amountIn, cache.amountUnspecifiedExpected, allowedDeviation, "Fixed Swap: Amount in mismatch");
            }
            if (verifyProtocolFees) {
                _verifyProtocolFees(swapOrder, cache);
            }
        }
    }

    ///////////////////////
    /// Fixed Swap Helpers
    ///////////////////////

    function _calculateSwapByInputSwap(SwapTestCache memory cache, ProtocolFeeStructure memory protocolFeeStructure)
        internal
        view
    {
        uint256 amountIn = cache.amountSpecifiedAbs;
        _applyLPFeesSwapByInput(cache, protocolFeeStructure);
        _calculateFixedDeltaY(cache);
        cache.allowedProtocolFeeDeviation0 = FullMath.mulDivRoundingUp(cache.allowedLPFeeDeviation0, protocolFeeStructure.lpFeeBPS, MAX_BPS);
        cache.allowedProtocolFeeDeviation1 = FullMath.mulDivRoundingUp(cache.allowedLPFeeDeviation1, protocolFeeStructure.lpFeeBPS, MAX_BPS);
        if (cache.amountUnspecifiedExpected > cache.reserveOut) {
            uint256 expectedProtocolFees0 = cache.expectedProtocolFees0;
            uint256 expectedProtocolFees1 = cache.expectedProtocolFees1;
            cache.amountUnspecifiedExpected = cache.amountSpecifiedAbs;
            cache.amountSpecifiedAbs = cache.reserveOut;
            _calculateFixedDeltaX(cache);
            _applyLPFeesSwapByOutput(cache, protocolFeeStructure);
            cache.expectedProtocolFees0 -= expectedProtocolFees0;
            cache.expectedProtocolFees1 -= expectedProtocolFees1;
            (cache.amountUnspecifiedExpected, cache.amountSpecifiedAbs) =
                (cache.amountSpecifiedAbs, cache.amountUnspecifiedExpected);
            if (cache.amountSpecifiedAbs > amountIn) {
                cache.amountSpecifiedAbs = amountIn;
            }
        }
    }

    function _calculateSwapByOutputSwap(SwapTestCache memory cache, ProtocolFeeStructure memory protocolFeeStructure)
        internal
        view
    {
        if (cache.amountSpecifiedAbs > cache.reserveOut) {
            cache.amountSpecifiedAbs = cache.reserveOut;
        }
        _calculateFixedDeltaX(cache);
        cache.allowedProtocolFeeDeviation0 = FullMath.mulDivRoundingUp(cache.allowedLPFeeDeviation0, protocolFeeStructure.lpFeeBPS, MAX_BPS);
        cache.allowedProtocolFeeDeviation1 = FullMath.mulDivRoundingUp(cache.allowedLPFeeDeviation1, protocolFeeStructure.lpFeeBPS, MAX_BPS);
        _applyLPFeesSwapByOutput(cache, protocolFeeStructure);
        console2.log("amountUnspecifiedExpected after fees: ", cache.amountUnspecifiedExpected);
    }

    function _calculateFixedDeltaY(SwapTestCache memory cache) internal view {
        FixedPoolStateView memory state = fixedPool.getFixedPoolState(cache.poolId);
        uint160 sqrtPriceX96 = state.sqrtPriceX96;
        uint256 amountOut;

        amountOut = cache.amountUnspecifiedExpected = FixedHelper.calculateFixedSwapRoundingDown(cache.amountSpecifiedAbs, sqrtPriceX96, cache.zeroForOne == cache.inputSwap);
        if (cache.zeroForOne) {
            uint256 allowedSwapDeviation = FixedHelper.calculateFixedSwap(1, state.sqrtPriceX96, !cache.zeroForOne);
            cache.allowedLPFeeDeviation0 = allowedSwapDeviation + FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
        } else {
            uint256 allowedSwapDeviation = FixedHelper.calculateFixedSwap(1, state.sqrtPriceX96, !cache.zeroForOne);
            cache.allowedLPFeeDeviation1 = allowedSwapDeviation + FullMath.mulDivRoundingUp(FullMath.mulDivRoundingUp(1, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        }
    }

    function _calculateFixedDeltaX(SwapTestCache memory cache) internal view {
        FixedPoolStateView memory state = fixedPool.getFixedPoolState(cache.poolId);
        uint160 sqrtPriceX96 = state.sqrtPriceX96;
        uint256 amountIn;

        amountIn = cache.amountUnspecifiedExpected = FixedHelper.calculateFixedSwap(cache.amountSpecifiedAbs, sqrtPriceX96, cache.zeroForOne == cache.inputSwap);
        if (cache.zeroForOne) {
            uint256 allowedSwapDeviation = FixedHelper.calculateFixedSwap(1, state.sqrtPriceX96, !cache.zeroForOne);
            cache.allowedLPFeeDeviation0 = allowedSwapDeviation + FullMath.mulDiv(FullMath.mulDiv(1, sqrtPriceX96, Q96), sqrtPriceX96, Q96);
        } else {
            uint256 allowedSwapDeviation = FixedHelper.calculateFixedSwap(1, state.sqrtPriceX96, !cache.zeroForOne);
            cache.allowedLPFeeDeviation1 = allowedSwapDeviation + FullMath.mulDiv(FullMath.mulDiv(1, Q96, sqrtPriceX96), Q96, sqrtPriceX96);
        }
    }

    function _applyLPFeesSwapByInput(SwapTestCache memory cache, ProtocolFeeStructure memory protocolFeeStructure)
        internal
        pure
    {
        uint256 reserveAmount = FullMath.mulDiv(cache.amountSpecifiedAbs, MAX_BPS - cache.poolFeeBPS, MAX_BPS);
        uint256 lpFeeAmount = cache.amountSpecifiedAbs - reserveAmount;
        console2.log("lpFeeAmount: ", lpFeeAmount);

        unchecked {
            cache.amountSpecifiedAbs -= lpFeeAmount;
        }
        if (protocolFeeStructure.lpFeeBPS > 0) {
            uint256 protocolFeeAmount = FullMath.mulDiv(lpFeeAmount, protocolFeeStructure.lpFeeBPS, MAX_BPS);
            console2.log("protocolFeeAmount: ", protocolFeeAmount);
            unchecked {
                lpFeeAmount -= protocolFeeAmount;
            }
            if (cache.zeroForOne) {
                cache.expectedProtocolFees0 += protocolFeeAmount;
            } else {
                cache.expectedProtocolFees1 += protocolFeeAmount;
            }
        }
    }

    function _applyLPFeesSwapByOutput(SwapTestCache memory cache, ProtocolFeeStructure memory protocolFeeStructure)
        internal
        pure
    {
        uint256 lpFeeAmount =
            FullMath.mulDivRoundingUp(cache.amountUnspecifiedExpected, cache.poolFeeBPS, MAX_BPS - cache.poolFeeBPS);
        console2.log("lpFeeAmount: ", lpFeeAmount);
        unchecked {
            cache.amountUnspecifiedExpected += lpFeeAmount;
        }
        if (protocolFeeStructure.lpFeeBPS > 0) {
            uint256 protocolFeeAmount = FullMath.mulDiv(lpFeeAmount, protocolFeeStructure.lpFeeBPS, MAX_BPS);
            unchecked {
                lpFeeAmount -= protocolFeeAmount;
            }
            if (cache.zeroForOne) {
                cache.expectedProtocolFees0 += protocolFeeAmount;
            } else {
                cache.expectedProtocolFees1 += protocolFeeAmount;
            }
        }
    }

    function _getPoolFee(bytes32 poolId) internal pure returns (uint16) {
        return FixedPoolDecoder.getPoolFee(poolId);
    }

    function _generatePoolId(
        PoolCreationDetails memory poolCreationDetails,
        FixedPoolCreationDetails memory fixedPoolDetails
    ) internal view returns (bytes32 poolId) {
        poolId = EfficientHash.efficientHash(
            bytes32(uint256(uint160(address(fixedPool)))),
            bytes32(uint256(poolCreationDetails.fee)),
            bytes32(uint256(fixedPoolDetails.spacing0)),
            bytes32(uint256(fixedPoolDetails.spacing1)),
            bytes32(FixedHelper.simplifyRatio(fixedPoolDetails.packedRatio)),
            bytes32(uint256(uint160(poolCreationDetails.token0))),
            bytes32(uint256(uint160(poolCreationDetails.token1))),
            bytes32(uint256(uint160(poolCreationDetails.poolHook)))
        ) & POOL_HASH_MASK;

        poolId = poolId | bytes32((uint256(uint160(address(fixedPool))) << 144))
            | bytes32(uint256(poolCreationDetails.fee) << 0) | bytes32(uint256(uint24(fixedPoolDetails.spacing0)) << 24)
            | bytes32(uint256(uint24(fixedPoolDetails.spacing1)) << 16);
    }

    function _generatePositionId(bytes32 poolId, address provider, address hook)
        internal
        pure
        returns (bytes32 positionId)
    {
        positionId =
            EfficientHash.efficientHash(bytes32(uint256(uint160(provider))), bytes32(uint256(uint160(hook))), poolId);
    }

    function _executeFixedPoolMultiSwap(
        SwapOrder memory swapOrder,
        bytes32[] memory poolIds,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData[] memory swapHooksExtraDatas,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        SwapTestCache memory cache;

        _initializeSwapTestCache(poolIds[0], cache, swapOrder);

        ProtocolFeeStructure memory protocolFeeStructure = _getProtocolFeeStructure(poolIds[0], exchangeFee, feeOnTop);

        address tokenIn = swapOrder.tokenIn;
        address tokenOut = swapOrder.tokenOut;

        if (cache.inputSwap) {
            _applyExternalFeesSwapByInput(cache, exchangeFee, feeOnTop, protocolFeeStructure);
            for (uint256 i = 0; i < poolIds.length; i++) {
                protocolFeeStructure = _getProtocolFeeStructure(poolIds[i], exchangeFee, feeOnTop);

                {
                    PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolIds[i]);
                    cache.poolFeeBPS = _getPoolFee(poolIds[i]);
                    cache.poolId = poolIds[i];
                    if (poolState.token0 == tokenIn || poolState.token1 == tokenIn) {
                        cache.zeroForOne = poolState.token0 == tokenIn;
                    } else {
                        tokenIn = tokenOut;
                        tokenOut = poolState.token0 == tokenIn ? poolState.token1 : poolState.token0;
                        cache.zeroForOne = poolState.token0 == tokenIn;
                    }
                }
                _applyBeforeSwapHookFeesSwapByInput(cache, swapOrder, protocolFeeStructure);
                _calculateSwapByInputSwap(cache, protocolFeeStructure);
                _applyAfterSwapHookFeesSwapByInput(cache, swapOrder);
            }
        } else {
            for (uint256 i = 0; i < poolIds.length; i++) {
                protocolFeeStructure = _getProtocolFeeStructure(poolIds[i], exchangeFee, feeOnTop);

                {
                    PoolState memory poolState = LimitBreakAMM(amm).getPoolState(poolIds[i]);
                    cache.poolFeeBPS = _getPoolFee(poolIds[i]);
                    cache.poolId = poolIds[i];
                    if (poolState.token0 == tokenIn || poolState.token1 == tokenIn) {
                        cache.zeroForOne = poolState.token0 == tokenIn;
                    } else {
                        tokenIn = tokenOut;
                        tokenOut = poolState.token0 == tokenIn ? poolState.token1 : poolState.token0;
                        cache.zeroForOne = poolState.token0 == tokenIn;
                    }
                }
                _applyBeforeSwapHookFeesSwapByOutput(cache, swapOrder);
                _calculateSwapByOutputSwap(cache, protocolFeeStructure);
                _applyAfterSwapHookFeesSwapByOutput(cache, swapOrder, protocolFeeStructure);
                cache.amountSpecifiedAbs = cache.amountUnspecifiedExpected;
            }
            _applyExternalFeesSwapByOutput(cache, exchangeFee, feeOnTop, protocolFeeStructure);
        }

        (amountIn, amountOut) = _executeMultiSwap(
            swapOrder, poolIds, exchangeFee, feeOnTop, swapHooksExtraDatas, transferData, errorSelector
        );

        if (errorSelector == bytes4(0)) {
            if (cache.inputSwap) {
                assertEq(amountIn, uint256(swapOrder.amountSpecified), "MultiSwap: amountIn mismatch");
                assertEq(amountOut, uint256(cache.amountUnspecifiedExpected), "MultiSwap: amountOut mismatch");
            } else {
                assertEq(amountOut, uint256(-swapOrder.amountSpecified), "MultiSwap: amountOut mismatch");
                assertEq(amountIn, uint256(cache.amountUnspecifiedExpected), "MultiSwap: amountIn mismatch");
            }
            console2.log("amountIn: ", amountIn);
            console2.log("amountOut: ", amountOut);
        }
    }

    function test_singleSwap_compareFees() public {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(currency2),
            token1: address(currency3),
            fee: 0,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 2**95, bytes4(0));

        {
            _mintAndApprove(address(currency2), alice, address(amm), 1_000_000 ether);
            _mintAndApprove(address(currency3), alice, address(amm), 1_000_000 ether);

            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityModificationParams memory fixedParams = FixedLiquidityModificationParams({
                amount0: 1_000 ether,
                amount1: 1_000 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        {
            FixedFeeTokenHook ffth = new FixedFeeTokenHook();
            changePrank(address(0));
            amm.setTokenSettings(address(currency2), address(ffth), TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG);
            changePrank(address(this));
        }

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({
            recipient: address(1337),
            BPS: 2_000
        });
        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({
            recipient: address(1338),
            amount: 10 ether
        });

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(125 ether),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(currency2),
            tokenOut: address(currency3)
        });

        SwapHooksExtraData memory shed;
        changePrank(swapOrder.recipient);
        (uint256 amountInSwapByIn, uint256 amountOutSwapByIn) = _executeSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, shed, bytes(""), bytes4(0)
        );

        console2.log("Amount In (in-based): ", amountInSwapByIn);
        console2.log("Amount Out (in-based): ", amountOutSwapByIn);

        swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: -int256(amountOutSwapByIn),
            minAmountSpecified: 0,
            limitAmount: amountOutSwapByIn,
            tokenIn: address(currency2),
            tokenOut: address(currency3)
        });
        (uint256 amountInSwapByOut, uint256 amountOutSwapByOut) = _executeSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, shed, bytes(""), bytes4(0)
        );
        console2.log("Amount In (out-based): ", amountInSwapByOut);
        console2.log("Amount Out (out-based): ", amountOutSwapByOut);

        assertEq(amountInSwapByIn, amountInSwapByOut);
        assertEq(amountOutSwapByIn, amountOutSwapByOut);
    }
}

contract FixedFeeTokenHook is ILimitBreakAMMTokenHook {
    function hookFlags() external view returns (uint32 requiredFlags, uint32 supportedFlags) {
        return (TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG,
            TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG);
    }
    
    function validatePoolCreation(bytes32,address,bool,PoolCreationDetails calldata,bytes calldata) external { }
    
    function beforeSwap(
        SwapContext calldata,
        HookSwapParams calldata swapParams,
        bytes calldata
    ) external returns (uint256 fee) {
        if (swapParams.inputSwap) {
            return 5 ether;
        }
        return 0;
    }
    
    function afterSwap(
        SwapContext calldata,
        HookSwapParams calldata swapParams,
        bytes calldata
    ) external returns (uint256 fee) {
        if (!swapParams.inputSwap) {
            return 5 ether;
        }
        return 0;
    }
    
    function validateCollectFees(bool,LiquidityContext calldata,LiquidityCollectFeesParams calldata,uint256,uint256,bytes calldata) external returns (uint256,uint256) { }    
    function validateAddLiquidity(bool,LiquidityContext calldata,LiquidityModificationParams calldata,uint256,uint256,uint256,uint256,bytes calldata) external returns (uint256,uint256) { }    
    function validateRemoveLiquidity(bool,LiquidityContext calldata,LiquidityModificationParams calldata,uint256,uint256,uint256,uint256,bytes calldata) external returns (uint256,uint256) { }    
    function beforeFlashloan(address,address,uint256,address,bytes calldata) external returns (address feeToken, uint256 fee) { }    
    function validateFlashloanFee(address,address,uint256,address,uint256,address,bytes calldata) external returns (bool allowed) { }
    function tokenHookManifestUri() external view returns(string memory manifestUri) { }
    function validateHandlerOrder(address, bool, address, address, uint256, uint256, bytes calldata, bytes calldata) external pure { }
}

contract MultiHopHopCountAndIndexHook is ILimitBreakAMMTokenHook {
    uint256 public lastNumberOfHops;
    uint256 public lastHopIndex;

    function hookFlags() external view returns (uint32 requiredFlags, uint32 supportedFlags) {
        return (TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG,
            TOKEN_SETTINGS_BEFORE_SWAP_HOOK_FLAG | TOKEN_SETTINGS_AFTER_SWAP_HOOK_FLAG);
    }
    
    function validatePoolCreation(bytes32,address,bool,PoolCreationDetails calldata,bytes calldata) external { }
    
    function beforeSwap(
        SwapContext calldata context,
        HookSwapParams calldata swapParams,
        bytes calldata
    ) external returns (uint256 fee) {
        lastNumberOfHops = context.numberOfHops;
        lastHopIndex = swapParams.hopIndex;
    }
    
    function afterSwap(
        SwapContext calldata context,
        HookSwapParams calldata swapParams,
        bytes calldata
    ) external returns (uint256 fee) {
        lastNumberOfHops = context.numberOfHops;
        lastHopIndex = swapParams.hopIndex;
    }
    
    function validateCollectFees(bool,LiquidityContext calldata,LiquidityCollectFeesParams calldata,uint256,uint256,bytes calldata) external returns (uint256,uint256) { }    
    function validateAddLiquidity(bool,LiquidityContext calldata,LiquidityModificationParams calldata,uint256,uint256,uint256,uint256,bytes calldata) external returns (uint256,uint256) { }    
    function validateRemoveLiquidity(bool,LiquidityContext calldata,LiquidityModificationParams calldata,uint256,uint256,uint256,uint256,bytes calldata) external returns (uint256,uint256) { }    
    function beforeFlashloan(address,address,uint256,address,bytes calldata) external returns (address feeToken, uint256 fee) { }    
    function validateFlashloanFee(address,address,uint256,address,uint256,address,bytes calldata) external returns (bool allowed) { }
    function tokenHookManifestUri() external view returns(string memory manifestUri) { }
    function validateHandlerOrder(address, bool, address, address, uint256, uint256, bytes calldata, bytes calldata) external pure { }
}