pragma solidity ^0.8.24;

import "../FixedPool.t.sol";

contract FixedPoolFuzzTest is FixedPoolTest {
    function setUp() public override {
        super.setUp();
    }

    function test_fuzz_singleSwap_verifyInputAndOutputBasedFeesIdentical(uint256 amountSpecified) public {
        amountSpecified = bound(amountSpecified, 1000, 1_000_000e6);

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

        _addStandardFixedLiquidity(poolId);

        _mintAndApprove(address(usdc), alice, address(amm), type(uint128).max);
        _mintAndApprove(address(weth), alice, address(amm), type(uint128).max);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({recipient: exchangeFeeRecipient, BPS: 100});
        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({recipient: feeOnTopRecipient, amount: 10});

        uint256 snapshot = vm.snapshotState();

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(amountSpecified),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(usdc),
            tokenOut: address(weth)
        });

        changePrank(swapOrder.recipient);
        (uint256 amountInDeltaSwapByIn, uint256 amountOutDeltaSwapByIn) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        vm.revertToState(snapshot);

        swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: -int256(amountOutDeltaSwapByIn),
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(usdc),
            tokenOut: address(weth)
        });

        changePrank(swapOrder.recipient);
        (uint256 amountInDeltaSwapByOut, uint256 amountOutDeltaSwapByOut) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        assertApproxEqAbs(amountInDeltaSwapByIn, amountInDeltaSwapByOut, 1, "FixedPool: Amount in deltas should be equal");
        assertApproxEqAbs(
            amountOutDeltaSwapByIn, amountOutDeltaSwapByOut, 1, "FixedPool: Amount out deltas should be equal"
        );
    }

    function test_fuzz_singleSwap_oneForZeroVerifyInputAndOutputBasedFeesIdentical(uint256 amountSpecified) public {
        amountSpecified = bound(amountSpecified, 1000, 1_000_000e6);

        PoolCreationDetails memory details = PoolCreationDetails({
            token0: address(usdc),
            token1: address(weth),
            fee: 500,
            poolType: address(fixedPool),
            poolHook: address(0),
            poolParams: bytes("")
        });

        bytes32 poolId = _createFixedPoolNoHookData(details, 1, 1, 2 ** 96, bytes4(0));

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
                amount0: 100_000 ether,
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

        _mintAndApprove(address(usdc), alice, address(amm), type(uint128).max);
        _mintAndApprove(address(weth), alice, address(amm), type(uint128).max);

        BPSFeeWithRecipient memory exchangeFee = BPSFeeWithRecipient({recipient: exchangeFeeRecipient, BPS: 10});
        FlatFeeWithRecipient memory feeOnTop = FlatFeeWithRecipient({recipient: feeOnTopRecipient, amount: 10});

        uint256 snapshot = vm.snapshotState();

        SwapOrder memory swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: int256(amountSpecified),
            minAmountSpecified: 0,
            limitAmount: 0,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        changePrank(swapOrder.recipient);
        (uint256 amountInDeltaSwapByIn, uint256 amountOutDeltaSwapByIn) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        vm.revertToState(snapshot);

        swapOrder = SwapOrder({
            deadline: block.timestamp + 1000,
            recipient: alice,
            amountSpecified: -int256(amountOutDeltaSwapByIn),
            minAmountSpecified: 0,
            limitAmount: type(uint256).max,
            tokenIn: address(weth),
            tokenOut: address(usdc)
        });

        changePrank(swapOrder.recipient);
        (uint256 amountInDeltaSwapByOut, uint256 amountOutDeltaSwapByOut) = _executeFixedPoolSingleSwap(
            swapOrder, poolId, exchangeFee, feeOnTop, _emptySwapHooksExtraData(), bytes(""), bytes4(0)
        );

        assertApproxEqAbs(amountInDeltaSwapByIn, amountInDeltaSwapByOut, 1, "FixedPool: Amount in deltas should be equal");
        assertApproxEqAbs(
            amountOutDeltaSwapByIn, amountOutDeltaSwapByOut, 1, "FixedPool: Amount out deltas should be equal"
        );
    }
}
