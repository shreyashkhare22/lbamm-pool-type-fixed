pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../../src/libraries/FixedHelper.sol";

contract FixedHelperTest is Test {
    function test_calculateInputOutputLpFees() public pure {
        // Test that _calculateInputLPAndProtocolFee correctly returns the expected values.
        uint256 amountIn = 1000e18; // Example input amount
        uint16 poolFeeBPS = 1000; // 10%
        uint16 lpFeeBPS = 5000; // 50%

        (uint256 amountInAfterFees, uint256 lpFeeAmount, uint256 protocolFeeAmount) =
            FixedHelper._calculateInputLPAndProtocolFee(amountIn, poolFeeBPS, lpFeeBPS);
        
        {
            uint256 expectedAmountInAfterFees = 900e18; // 90% of the input amount after pool fee
            uint256 expectedLpFeeAmount = 50e18; // 5% of the input amount
            uint256 expectedProtocolFeeAmount = 50e18; // 5% of the input amount
            assertEq(amountInAfterFees, expectedAmountInAfterFees);
            assertEq(lpFeeAmount, expectedLpFeeAmount);
            assertEq(protocolFeeAmount, expectedProtocolFeeAmount);
        }

        uint160 sqrtPriceX96 = 79228162514264337593543950336; // Example square root price 1:1

        // Test that calculateFixedInput correctly returns the expected values.
        uint256 amountOut = FixedHelper.calculateFixedSwap(amountInAfterFees, sqrtPriceX96, false);
        
        {
         uint256 expectedAmountOut = amountInAfterFees; // In a 1:1 price, output should equal input after fees
            assertEq(amountOut, expectedAmountOut);   
        }
    }
}
