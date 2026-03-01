pragma solidity ^0.8.24;

import "@limitbreak/lb-amm-core/test/LBAMMCorePoolBase.t.sol";

import {MAX_HEIGHT_SPACING} from "../src/Constants.sol";

import "../src/DataTypes.sol";
import "../src/Errors.sol";
import {FixedPoolType} from "../src/FixedPoolType.sol";
import {FixedHelper} from "../src/libraries/FixedHelper.sol";
import {FixedPoolQuoter} from "../src/FixedPoolQuoter.sol";
import {FixedPoolDecoder} from "../src/libraries/FixedPoolDecoder.sol";
import "@limitbreak/lb-amm-core/src/DataTypes.sol";
import "./mocks/MockHookWithLiquidityFees.t.sol";

contract FixedPoolLiquidityHookFeesTest is LBAMMCorePoolBaseTest {
    FixedPoolType public fixedPool;
    FixedPoolQuoter public fixedPoolQuoter;
    MockHookWithLiquidityFees public hook0;
    MockHookWithLiquidityFees public hook1;

    uint256 public daveKey;
    address public dave;

    function setUp() public virtual override {
        super.setUp();

        address fixedPoolAddress = address(1112);

        fixedPool = FixedPoolType(address(new FixedPoolType(address(amm))));
        vm.etch(fixedPoolAddress, address(fixedPool).code);
        fixedPool = FixedPoolType(fixedPoolAddress);
        fixedPoolQuoter = new FixedPoolQuoter(address(amm), address(fixedPool));
        hook0 = new MockHookWithLiquidityFees();
        hook1 = new MockHookWithLiquidityFees();

        (dave, daveKey) = makeAddrAndKey("dave");

        _setTokenHookSettings(true);

        vm.label(address(fixedPool), "Fixed Pool");
        vm.label(address(fixedPoolQuoter), "Fixed Quotor");
        vm.label(address(hook0), "Liquidity Fee Hook 0");
        vm.label(address(hook1), "Liquidity Fee Hook 1");
    }

    function test_liquidityHookFees() public {
        bytes32 poolId = _createFixedPool();

        _mintAndApprove(address(currency3), alice, address(amm), 1_000_000 ether);
        _mintAndApprove(address(currency4), alice, address(amm), 1_000_000 ether);

        _mintAndApprove(address(currency3), bob, address(amm), 1_000_000 ether);
        _mintAndApprove(address(currency4), bob, address(amm), 1_000_000 ether);

        FeeAmounts memory hook0Fees;
        hook0Fees.amm = address(amm);
        hook0Fees.token0 = address(currency3);
        hook0Fees.token1 = address(currency4);
        FeeAmounts memory hook1Fees;
        hook1Fees.amm = address(amm);
        hook1Fees.token0 = address(currency3);
        hook1Fees.token1 = address(currency4);

        {
            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(hook0),
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
                amount0: 100_000 ether,
                amount1: 100_000 ether,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            uint256 snapshotId = vm.snapshot();

            // Add without fees
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            uint256 aliceWithoutFee0 = currency3.balanceOf(alice);
            uint256 aliceWithoutFee1 = currency4.balanceOf(alice);

            // Add with position fee on token0, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0.setFeeAmounts(hook0Fees);
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            uint256 aliceWithFee0 = currency3.balanceOf(alice);
            uint256 aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionAdd0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionAdd1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionAdd0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionAdd1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionAdd0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1);

            // Add with position fee on token0, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1);

            // Add with position fee on token1, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 0;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionAdd0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionAdd1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionAdd0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionAdd1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1);

            // Add with position fee on token1, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1);

            // Add with position fee on both tokens, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionAdd0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionAdd1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionAdd0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionAdd1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionAdd0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1);

            // Add with position fee on both tokens, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1);

            // Reverts with excessive fees on token0
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = 1 ether - 1;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, LBAMM__ExcessiveHookFees.selector);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), 0);
            assertEq(currency4.balanceOf(carol), 0);

            // Reverts with excessive fees on token1
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = 2 ether - 1;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, LBAMM__ExcessiveHookFees.selector);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), 0);
            assertEq(currency4.balanceOf(carol), 0);

            // Add position with position and pool fees
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.poolAdd0 = 3 ether;
            hook0Fees.poolAdd1 = 4 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionAdd0 - hook0Fees.poolAdd0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionAdd1 - hook0Fees.poolAdd1, aliceWithFee1);
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionAdd0 + hook0Fees.poolAdd0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionAdd1 + hook0Fees.poolAdd1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionAdd0 + hook0Fees.poolAdd0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionAdd1 + hook0Fees.poolAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0 + hook0Fees.poolAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1 + hook0Fees.poolAdd1);

            // Add position with position, pool and token0 fees
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.poolAdd0 = 3 ether;
            hook0Fees.poolAdd1 = 4 ether;
            hook0Fees.tokenAdd0 = 5 ether;
            hook0Fees.tokenAdd1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionAdd0 - hook0Fees.poolAdd0 - hook0Fees.tokenAdd0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionAdd1 - hook0Fees.poolAdd1 - hook0Fees.tokenAdd1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionAdd0 + hook0Fees.poolAdd0 + hook0Fees.tokenAdd0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionAdd1 + hook0Fees.poolAdd1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)),
                hook0Fees.tokenAdd1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionAdd0 + hook0Fees.poolAdd0 + hook0Fees.tokenAdd0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionAdd1 + hook0Fees.poolAdd1);
            amm.collectHookFeesByHook(address(currency3), address(currency4), carol, hook0Fees.tokenAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0 + hook0Fees.poolAdd0 + hook0Fees.tokenAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1 + hook0Fees.poolAdd1 + hook0Fees.tokenAdd1);

            // Add position with position, pool and token0 fees, token fees managed by token
            vm.revertTo(snapshotId);
            _setTokenHookSettings(false);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.poolAdd0 = 3 ether;
            hook0Fees.poolAdd1 = 4 ether;
            hook0Fees.tokenAdd0 = 5 ether;
            hook0Fees.tokenAdd1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionAdd0 - hook0Fees.poolAdd0 - hook0Fees.tokenAdd0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionAdd1 - hook0Fees.poolAdd1 - hook0Fees.tokenAdd1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionAdd0 + hook0Fees.poolAdd0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionAdd1 + hook0Fees.poolAdd1
            );
            assertEq(
                amm.getHookFeesOwedByToken(address(currency3), address(currency3)),
                hook0Fees.tokenAdd0
            );
            assertEq(
                amm.getHookFeesOwedByToken(address(currency3), address(currency4)),
                hook0Fees.tokenAdd1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionAdd0 + hook0Fees.poolAdd0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionAdd1 + hook0Fees.poolAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0 + hook0Fees.poolAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1 + hook0Fees.poolAdd1);

            // Add position with position, pool and token0 fees
            vm.revertTo(snapshotId);
            hook0Fees.positionAdd0 = 1 ether;
            hook0Fees.positionAdd1 = 2 ether;
            hook0Fees.poolAdd0 = 3 ether;
            hook0Fees.poolAdd1 = 4 ether;
            hook0Fees.tokenAdd0 = 5 ether;
            hook0Fees.tokenAdd1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            hook1Fees.tokenAdd0 = 7 ether;
            hook1Fees.tokenAdd1 = 8 ether;
            hook1.setFeeAmounts(hook1Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionAdd0 - hook0Fees.poolAdd0 - 
                hook0Fees.tokenAdd0 - hook1Fees.tokenAdd0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionAdd1 - hook0Fees.poolAdd1 - 
                hook0Fees.tokenAdd1 - hook1Fees.tokenAdd1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionAdd0 + hook0Fees.poolAdd0 + hook0Fees.tokenAdd0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionAdd1 + hook0Fees.poolAdd1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)),
                hook0Fees.tokenAdd1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency3)),
                hook1Fees.tokenAdd0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency4)),
                hook1Fees.tokenAdd1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionAdd0 + hook0Fees.poolAdd0 + hook0Fees.tokenAdd0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionAdd1 + hook0Fees.poolAdd1);
            amm.collectHookFeesByHook(address(currency3), address(currency4), carol, hook0Fees.tokenAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionAdd0 + hook0Fees.poolAdd0 + hook0Fees.tokenAdd0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionAdd1 + hook0Fees.poolAdd1 + hook0Fees.tokenAdd1);
            changePrank(address(hook1));
            amm.collectHookFeesByHook(address(currency4), address(currency3), dave, hook1Fees.tokenAdd0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), dave, hook1Fees.tokenAdd1);
            assertEq(amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(dave), hook1Fees.tokenAdd0);
            assertEq(currency4.balanceOf(dave), hook1Fees.tokenAdd1);

            // Clean add for next tests
            vm.revertTo(snapshotId);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _addFixedLiquidityNoHookData(fixedParams, liquidityParams, alice, bytes4(0));
        }

        {
            BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({BPS: 0, recipient: address(0)});
            FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({amount: 0, recipient: address(0)});

            _swapByInputFixedPoolNoExtraData(bob, poolId, exchangeFee, feeOnTop, bytes4(0));
            _swapByInputOneForZeroFixedPoolNoExtraData(bob, poolId, exchangeFee, feeOnTop, bytes4(0));
        }

        {
            LiquidityCollectFeesParams memory collectParams =
                LiquidityCollectFeesParams({
                    poolId: poolId,
                    liquidityHook: address(hook0),
                    maxHookFee0: type(uint256).max,
                    maxHookFee1: type(uint256).max,
                    poolParams: bytes("")
                });
            
            uint256 snapshotId = vm.snapshot();

            // Collect without fees
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            uint256 aliceWithoutFee0 = currency3.balanceOf(alice);
            uint256 aliceWithoutFee1 = currency4.balanceOf(alice);

            // Collect with position fee on token0, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0.setFeeAmounts(hook0Fees);
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            uint256 aliceWithFee0 = currency3.balanceOf(alice);
            uint256 aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionCollect0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionCollect1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionCollect0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionCollect1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionCollect0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1);

            // Collect with position fee on token0, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1);

            // Collect with position fee on token1, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 0;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionCollect0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionCollect1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionCollect0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionCollect1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1);

            // Collect with position fee on token1, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1);

            // Collect with position fee on both tokens, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionCollect0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionCollect1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionCollect0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionCollect1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionCollect0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1);

            // Collect with position fee on both tokens, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1);

            // Reverts with excessive fees on token0
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            collectParams.maxHookFee0 = 1 ether - 1;
            _collectFixedPoolLPFees(collectParams, alice, LBAMM__ExcessiveHookFees.selector);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), 0);
            assertEq(currency4.balanceOf(carol), 0);

            // Reverts with excessive fees on token1
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            collectParams.maxHookFee0 = type(uint256).max;
            collectParams.maxHookFee1 = 2 ether - 1;
            _collectFixedPoolLPFees(collectParams, alice, LBAMM__ExcessiveHookFees.selector);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), 0);
            assertEq(currency4.balanceOf(carol), 0);

            // Collect position with position and pool fees
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.poolCollect0 = 3 ether;
            hook0Fees.poolCollect1 = 4 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            collectParams.maxHookFee0 = type(uint256).max;
            collectParams.maxHookFee1 = type(uint256).max;
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionCollect0 - hook0Fees.poolCollect0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionCollect1 - hook0Fees.poolCollect1, aliceWithFee1);
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionCollect0 + hook0Fees.poolCollect0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionCollect1 + hook0Fees.poolCollect1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionCollect0 + hook0Fees.poolCollect0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionCollect1 + hook0Fees.poolCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0 + hook0Fees.poolCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1 + hook0Fees.poolCollect1);

            // Collect position with position, pool and token0 fees
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.poolCollect0 = 3 ether;
            hook0Fees.poolCollect1 = 4 ether;
            hook0Fees.tokenCollect0 = 5 ether;
            hook0Fees.tokenCollect1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            collectParams.maxHookFee0 = type(uint256).max;
            collectParams.maxHookFee1 = type(uint256).max;
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionCollect0 - hook0Fees.poolCollect0 - hook0Fees.tokenCollect0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionCollect1 - hook0Fees.poolCollect1 - hook0Fees.tokenCollect1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionCollect0 + hook0Fees.poolCollect0 + hook0Fees.tokenCollect0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionCollect1 + hook0Fees.poolCollect1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)),
                hook0Fees.tokenCollect1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionCollect0 + hook0Fees.poolCollect0 + hook0Fees.tokenCollect0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionCollect1 + hook0Fees.poolCollect1);
            amm.collectHookFeesByHook(address(currency3), address(currency4), carol, hook0Fees.tokenCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0 + hook0Fees.poolCollect0 + hook0Fees.tokenCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1 + hook0Fees.poolCollect1 + hook0Fees.tokenCollect1);

            // Collect position with position, pool and token0 fees, token fees managed by token
            vm.revertTo(snapshotId);
            _setTokenHookSettings(false);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.poolCollect0 = 3 ether;
            hook0Fees.poolCollect1 = 4 ether;
            hook0Fees.tokenCollect0 = 5 ether;
            hook0Fees.tokenCollect1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            collectParams.maxHookFee0 = type(uint256).max;
            collectParams.maxHookFee1 = type(uint256).max;
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionCollect0 - hook0Fees.poolCollect0 - hook0Fees.tokenCollect0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionCollect1 - hook0Fees.poolCollect1 - hook0Fees.tokenCollect1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionCollect0 + hook0Fees.poolCollect0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionCollect1 + hook0Fees.poolCollect1
            );
            assertEq(
                amm.getHookFeesOwedByToken(address(currency3), address(currency3)),
                hook0Fees.tokenCollect0
            );
            assertEq(
                amm.getHookFeesOwedByToken(address(currency3), address(currency4)),
                hook0Fees.tokenCollect1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionCollect0 + hook0Fees.poolCollect0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionCollect1 + hook0Fees.poolCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0 + hook0Fees.poolCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1 + hook0Fees.poolCollect1);

            // Collect position with position, pool and token0 fees
            vm.revertTo(snapshotId);
            hook0Fees.positionCollect0 = 1 ether;
            hook0Fees.positionCollect1 = 2 ether;
            hook0Fees.poolCollect0 = 3 ether;
            hook0Fees.poolCollect1 = 4 ether;
            hook0Fees.tokenCollect0 = 5 ether;
            hook0Fees.tokenCollect1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            hook1Fees.tokenCollect0 = 7 ether;
            hook1Fees.tokenCollect1 = 8 ether;
            hook1.setFeeAmounts(hook1Fees);
            collectParams.maxHookFee0 = type(uint256).max;
            collectParams.maxHookFee1 = type(uint256).max;
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionCollect0 - hook0Fees.poolCollect0 - 
                hook0Fees.tokenCollect0 - hook1Fees.tokenCollect0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionCollect1 - hook0Fees.poolCollect1 - 
                hook0Fees.tokenCollect1 - hook1Fees.tokenCollect1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionCollect0 + hook0Fees.poolCollect0 + hook0Fees.tokenCollect0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionCollect1 + hook0Fees.poolCollect1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)),
                hook0Fees.tokenCollect1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency3)),
                hook1Fees.tokenCollect0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency4)),
                hook1Fees.tokenCollect1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionCollect0 + hook0Fees.poolCollect0 + hook0Fees.tokenCollect0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionCollect1 + hook0Fees.poolCollect1);
            amm.collectHookFeesByHook(address(currency3), address(currency4), carol, hook0Fees.tokenCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionCollect0 + hook0Fees.poolCollect0 + hook0Fees.tokenCollect0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionCollect1 + hook0Fees.poolCollect1 + hook0Fees.tokenCollect1);
            changePrank(address(hook1));
            amm.collectHookFeesByHook(address(currency4), address(currency3), dave, hook1Fees.tokenCollect0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), dave, hook1Fees.tokenCollect1);
            assertEq(amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(dave), hook1Fees.tokenCollect0);
            assertEq(currency4.balanceOf(dave), hook1Fees.tokenCollect1);

            // Clean collect for next tests
            vm.revertTo(snapshotId);
            collectParams.maxHookFee0 = type(uint256).max;
            collectParams.maxHookFee1 = type(uint256).max;
            _collectFixedPoolLPFees(collectParams, alice, bytes4(0));
        }

        {
            LiquidityModificationParams memory liquidityParams = LiquidityModificationParams({
                liquidityHook: address(hook0),
                poolId: poolId,
                minLiquidityAmount0: 0,
                minLiquidityAmount1: 0,
                maxLiquidityAmount0: type(uint256).max,
                maxLiquidityAmount1: type(uint256).max,
                maxHookFee0: type(uint256).max,
                maxHookFee1: type(uint256).max,
                poolParams: bytes("")
            });

            FixedLiquidityWithdrawAllParams memory fixedParams = FixedLiquidityWithdrawAllParams({
                minAmount0: 1 ether,
                minAmount1: 1 ether
            });
            
            uint256 snapshotId = vm.snapshot();

            // Remove without fees
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            uint256 aliceWithoutFee0 = currency3.balanceOf(alice);
            uint256 aliceWithoutFee1 = currency4.balanceOf(alice);

            // Remove with position fee on token0, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0.setFeeAmounts(hook0Fees);
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            uint256 aliceWithFee0 = currency3.balanceOf(alice);
            uint256 aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionRemove0, aliceWithFee0, "huh?");
            assertEq(aliceWithoutFee1 - hook0Fees.positionRemove1, aliceWithFee1, "huh2?");
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionRemove0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionRemove1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionRemove0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1);

            // Remove with position fee on token0, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1);

            // Remove with position fee on token1, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 0;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionRemove0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionRemove1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionRemove0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionRemove1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1);

            // Remove with position fee on token1, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1);

            // Remove with position fee on both tokens, claim after
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionRemove0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionRemove1, aliceWithFee1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), hook0Fees.positionRemove0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), hook0Fees.positionRemove1);
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionRemove0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1);

            // Remove with position fee on both tokens, queue claim
            vm.revertTo(snapshotId);
            hook0Fees.collectDuring = true;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1);

            // Reverts with excessive fees on token0
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = 1 ether - 1;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, LBAMM__ExcessiveHookFees.selector);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), 0);
            assertEq(currency4.balanceOf(carol), 0);

            // Reverts with excessive fees on token1
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = 2 ether - 1;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, LBAMM__ExcessiveHookFees.selector);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), 0);
            assertEq(currency4.balanceOf(carol), 0);

            // Remove position with position and pool fees
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.poolRemove0 = 3 ether;
            hook0Fees.poolRemove1 = 4 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(aliceWithoutFee0 - hook0Fees.positionRemove0 - hook0Fees.poolRemove0, aliceWithFee0);
            assertEq(aliceWithoutFee1 - hook0Fees.positionRemove1 - hook0Fees.poolRemove1, aliceWithFee1);
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionRemove0 + hook0Fees.poolRemove0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionRemove1 + hook0Fees.poolRemove1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionRemove0 + hook0Fees.poolRemove0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionRemove1 + hook0Fees.poolRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0 + hook0Fees.poolRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1 + hook0Fees.poolRemove1);

            // Remove position with position, pool and token0 fees
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.poolRemove0 = 3 ether;
            hook0Fees.poolRemove1 = 4 ether;
            hook0Fees.tokenRemove0 = 5 ether;
            hook0Fees.tokenRemove1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionRemove0 - hook0Fees.poolRemove0 - hook0Fees.tokenRemove0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionRemove1 - hook0Fees.poolRemove1 - hook0Fees.tokenRemove1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionRemove0 + hook0Fees.poolRemove0 + hook0Fees.tokenRemove0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionRemove1 + hook0Fees.poolRemove1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)),
                hook0Fees.tokenRemove1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionRemove0 + hook0Fees.poolRemove0 + hook0Fees.tokenRemove0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionRemove1 + hook0Fees.poolRemove1);
            amm.collectHookFeesByHook(address(currency3), address(currency4), carol, hook0Fees.tokenRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0 + hook0Fees.poolRemove0 + hook0Fees.tokenRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1 + hook0Fees.poolRemove1 + hook0Fees.tokenRemove1);

            // Remove position with position, pool and token0 fees, token fees managed by token
            vm.revertTo(snapshotId);
            _setTokenHookSettings(false);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.poolRemove0 = 3 ether;
            hook0Fees.poolRemove1 = 4 ether;
            hook0Fees.tokenRemove0 = 5 ether;
            hook0Fees.tokenRemove1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionRemove0 - hook0Fees.poolRemove0 - hook0Fees.tokenRemove0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionRemove1 - hook0Fees.poolRemove1 - hook0Fees.tokenRemove1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionRemove0 + hook0Fees.poolRemove0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionRemove1 + hook0Fees.poolRemove1
            );
            assertEq(
                amm.getHookFeesOwedByToken(address(currency3), address(currency3)),
                hook0Fees.tokenRemove0
            );
            assertEq(
                amm.getHookFeesOwedByToken(address(currency3), address(currency4)),
                hook0Fees.tokenRemove1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionRemove0 + hook0Fees.poolRemove0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionRemove1 + hook0Fees.poolRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0 + hook0Fees.poolRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1 + hook0Fees.poolRemove1);

            // Remove position with position, pool and token0 fees
            vm.revertTo(snapshotId);
            hook0Fees.positionRemove0 = 1 ether;
            hook0Fees.positionRemove1 = 2 ether;
            hook0Fees.poolRemove0 = 3 ether;
            hook0Fees.poolRemove1 = 4 ether;
            hook0Fees.tokenRemove0 = 5 ether;
            hook0Fees.tokenRemove1 = 6 ether;
            hook0Fees.collectDuring = false;
            hook0Fees.collectTo = carol;
            hook0.setFeeAmounts(hook0Fees);
            hook1Fees.tokenRemove0 = 7 ether;
            hook1Fees.tokenRemove1 = 8 ether;
            hook1.setFeeAmounts(hook1Fees);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
            aliceWithFee0 = currency3.balanceOf(alice);
            aliceWithFee1 = currency4.balanceOf(alice);
            assertEq(
                aliceWithoutFee0 - hook0Fees.positionRemove0 - hook0Fees.poolRemove0 - 
                hook0Fees.tokenRemove0 - hook1Fees.tokenRemove0,
                aliceWithFee0
            );
            assertEq(
                aliceWithoutFee1 - hook0Fees.positionRemove1 - hook0Fees.poolRemove1 - 
                hook0Fees.tokenRemove1 - hook1Fees.tokenRemove1,
                aliceWithFee1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)),
                hook0Fees.positionRemove0 + hook0Fees.poolRemove0 + hook0Fees.tokenRemove0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)),
                hook0Fees.positionRemove1 + hook0Fees.poolRemove1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency4)),
                hook0Fees.tokenRemove1
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency3)),
                hook1Fees.tokenRemove0
            );
            assertEq(
                amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency4)),
                hook1Fees.tokenRemove1
            );
            changePrank(address(hook0));
            amm.collectHookFeesByHook(address(currency3), address(currency3), carol, hook0Fees.positionRemove0 + hook0Fees.poolRemove0 + hook0Fees.tokenRemove0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), carol, hook0Fees.positionRemove1 + hook0Fees.poolRemove1);
            amm.collectHookFeesByHook(address(currency3), address(currency4), carol, hook0Fees.tokenRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency3), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook0), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(carol), hook0Fees.positionRemove0 + hook0Fees.poolRemove0 + hook0Fees.tokenRemove0);
            assertEq(currency4.balanceOf(carol), hook0Fees.positionRemove1 + hook0Fees.poolRemove1 + hook0Fees.tokenRemove1);
            changePrank(address(hook1));
            amm.collectHookFeesByHook(address(currency4), address(currency3), dave, hook1Fees.tokenRemove0);
            amm.collectHookFeesByHook(address(currency4), address(currency4), dave, hook1Fees.tokenRemove1);
            assertEq(amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency3)), 0);
            assertEq(amm.getHookFeesOwedByHook(address(hook1), address(currency4), address(currency4)), 0);
            assertEq(currency3.balanceOf(dave), hook1Fees.tokenRemove0);
            assertEq(currency4.balanceOf(dave), hook1Fees.tokenRemove1);

            // Clean collect for next tests
            vm.revertTo(snapshotId);
            liquidityParams.maxHookFee0 = type(uint256).max;
            liquidityParams.maxHookFee1 = type(uint256).max;
            _removeAllFixedLiquidity(fixedParams, liquidityParams, alice, bytes4(0));
        }
    }

    ///////////////////////
    /// Fixed Swap Helpers
    ///////////////////////

    function _createFixedPool() internal returns (bytes32 poolId) {
        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(currency3),
            token1: address(currency4),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(hook0),
            poolParams: bytes("")
        });

        poolId = _createFixedPoolNoHookData(details, 1, 1, 2**96, bytes4(0));
    }

    function _collectFixedPoolLPFees(
        LiquidityCollectFeesParams memory liquidityParams,
        address provider,
        bytes4 errorSelector
    ) internal {
        changePrank(provider);
        _executeCollectFeesWithoutBalanceChecks(liquidityParams, _emptyLiquidityHooksExtraData(), errorSelector);
    }

    function _executeCollectFeesWithoutBalanceChecks(
        LiquidityCollectFeesParams memory liquidityParams,
        LiquidityHooksExtraData memory liquidityHooksExtraData,
        bytes4 errorSelector
    ) internal returns (uint256 fees0, uint256 fees1) {
        PoolState memory poolState = amm.getPoolState(liquidityParams.poolId);

        (, address msgSender,) = vm.readCallers();

        if (errorSelector != bytes4(0)) {
            _handleExpectRevert(errorSelector);
        } else {
            vm.expectEmit(true, true, false, false);
            emit FeesCollected(liquidityParams.poolId, msgSender, 0, 0);
        }

        (fees0, fees1) = amm.collectFees(liquidityParams, liquidityHooksExtraData);
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

    function _setTokenHookSettings(bool hookManagesFees) internal {
        changePrank(currency3.owner());
        amm.setTokenSettings(
            address(currency3),
            address(hook0),
            (
                TOKEN_SETTINGS_ADD_LIQUIDITY_HOOK_FLAG | 
                TOKEN_SETTINGS_REMOVE_LIQUIDITY_HOOK_FLAG |
                TOKEN_SETTINGS_COLLECT_FEES_HOOK_FLAG |
                (hookManagesFees ? TOKEN_SETTINGS_HOOK_MANAGES_FEES_FLAG : 0)
            )
        );
        changePrank(currency4.owner());
        amm.setTokenSettings(
            address(currency4),
            address(hook1),
            (
                TOKEN_SETTINGS_ADD_LIQUIDITY_HOOK_FLAG | 
                TOKEN_SETTINGS_REMOVE_LIQUIDITY_HOOK_FLAG |
                TOKEN_SETTINGS_COLLECT_FEES_HOOK_FLAG |
                (hookManagesFees ? TOKEN_SETTINGS_HOOK_MANAGES_FEES_FLAG : 0)
            )
        );
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
        (deposit0, deposit1, fee0, fee1) = _executeAddLiquidityWithoutBalanceChecks(liquidityParams, liquidityHooksExtraData, errorSelector);
    }

    function _executeAddLiquidityWithoutBalanceChecks(
        LiquidityModificationParams memory liquidityParams,
        LiquidityHooksExtraData memory liquidityHooksExtraData,
        bytes4 errorSelector
    ) internal returns (uint256 deposit0, uint256 deposit1, uint256 fee0, uint256 fee1) {
        (, address msgSender,) = vm.readCallers();

        PoolState memory state = amm.getPoolState(liquidityParams.poolId);

        if (errorSelector != bytes4(0)) {
            _handleExpectRevert(errorSelector);
        } else {
            vm.expectEmit(true, true, false, false);
            emit LiquidityAdded(liquidityParams.poolId, msgSender, 0, 0, 0, 0);
        }

        (deposit0, deposit1, fee0, fee1) = amm.addLiquidity{gas: 100_000_000}(liquidityParams, liquidityHooksExtraData);
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

    function _executeRemoveLiquidityWithoutBalanceChecks(
        LiquidityModificationParams memory liquidityParams,
        LiquidityHooksExtraData memory liquidityHooksExtraData,
        bytes4 errorSelector
    ) internal returns (uint256 withdraw0, uint256 withdraw1, uint256 fee0, uint256 fee1) {
        PoolState memory poolState = amm.getPoolState(liquidityParams.poolId);

        (, address msgSender,) = vm.readCallers();

        _handleExpectRevert(errorSelector);

        (withdraw0, withdraw1, fee0, fee1) = amm.removeLiquidity(liquidityParams, liquidityHooksExtraData);
    }

    function _removeAllFixedLiquidity(
        FixedLiquidityWithdrawAllParams memory fixedParams,
        LiquidityModificationParams memory liquidityParams,
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
            _executeRemoveLiquidityWithoutBalanceChecks(liquidityParams, _emptyLiquidityHooksExtraData(), errorSelector);
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
            amountSpecified: 1 ether,
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(currency3),
            tokenOut: address(currency4)
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
            amountSpecified: 1 ether,
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(currency4),
            tokenOut: address(currency3)
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
            tokenIn: address(currency3),
            tokenOut: address(currency4)
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
            tokenIn: address(currency4),
            tokenOut: address(currency3)
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

    function _executeFixedPoolSingleSwap(
        SwapOrder memory swapOrder,
        bytes32 poolId,
        BPSFeeWithRecipient memory exchangeFee,
        FlatFeeWithRecipient memory feeOnTop,
        SwapHooksExtraData memory swapHooksExtraData,
        bytes memory transferData,
        bytes4 errorSelector
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        {
            changePrank(swapOrder.recipient);
            (amountIn, amountOut) = _executeSingleSwap(
                swapOrder, poolId, exchangeFee, feeOnTop, swapHooksExtraData, transferData, errorSelector
            );
        }
    }

    function _calculateSwapByInputSwap(SwapTestCache memory cache, ProtocolFeeStructure memory protocolFeeStructure)
        internal
        view
    {
        uint256 amountIn = cache.amountSpecifiedAbs;
        _applyLPFeesSwapByInput(cache, protocolFeeStructure);
        _calculateFixedDeltaY(cache);
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
        _applyLPFeesSwapByOutput(cache, protocolFeeStructure);
        console2.log("amountUnspecifiedExpected after fees: ", cache.amountUnspecifiedExpected);
    }

    function _calculateFixedDeltaY(SwapTestCache memory cache) internal view {
        FixedPoolStateView memory state = fixedPool.getFixedPoolState(cache.poolId);
        uint160 sqrtPriceX96 = state.sqrtPriceX96;
        uint256 amountOut;

        if (cache.zeroForOne) {
            amountOut = FullMath.mulDiv(cache.amountSpecifiedAbs, sqrtPriceX96, Q96);
            cache.amountUnspecifiedExpected = FullMath.mulDiv(amountOut, sqrtPriceX96, Q96);
        } else {
            amountOut = FullMath.mulDiv(cache.amountSpecifiedAbs, Q96, sqrtPriceX96);
            cache.amountUnspecifiedExpected = FullMath.mulDiv(amountOut, Q96, sqrtPriceX96);
        }
    }

    function _calculateFixedDeltaX(SwapTestCache memory cache) internal view {
        FixedPoolStateView memory state = fixedPool.getFixedPoolState(cache.poolId);
        uint160 sqrtPriceX96 = state.sqrtPriceX96;
        uint256 amountIn;

        if (cache.zeroForOne) {
            amountIn = FullMath.mulDivRoundingUp(cache.amountSpecifiedAbs, Q96, sqrtPriceX96);
            cache.amountUnspecifiedExpected = FullMath.mulDivRoundingUp(amountIn, Q96, sqrtPriceX96);
        } else {
            amountIn = FullMath.mulDivRoundingUp(cache.amountSpecifiedAbs, sqrtPriceX96, Q96);
            cache.amountUnspecifiedExpected = FullMath.mulDivRoundingUp(amountIn, sqrtPriceX96, Q96);
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
            bytes32(uint256(fixedPoolDetails.packedRatio)),
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
}
