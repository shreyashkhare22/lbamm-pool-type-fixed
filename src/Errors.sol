//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

/// @dev throws when an input swap executes as an output swap due to reserve constraints and input exceeds the original amount.
error FixedPool__ActualAmountCannotExceedInitialAmount();

/// @dev throws when the provided amount exceeds the system's maximum supported fee size.
error FixedPool__AmountExceedsMaximumFeeSize();

/// @dev throws when the provided amount exceeds the system's maximum supported reserve size.
error FixedPool__AmountExceedsMaximumReserveSize();

/// @dev throws when a deposit occurs with minimal value and results in both token amounts calculating to zero.
error FixedPool__BothTokenAmountsZeroOnDeposit();

/// @dev throws when a swap occurs with minimal value and results in both token amounts calculating to zero.
error FixedPool__BothTokenAmountsZeroOnSwap();

/// @dev throws when rounding causes an input amount validation error.
error FixedPool__InputValidationFailed();

/// @dev throws when a swap occurs in a direction where the expected reserve of output tokens is zero.
error FixedPool__InsufficientExpectedReserve();

/// @dev throws when a provided fee rate exceeds the maximum allowed for the operation.
error FixedPool__InvalidFeeBPS();

/// @dev throws when a fixed liquidity position is being added in-range and there is not enough of the other side added for depth required.
error FixedPool__InsufficientLiquidityForInRangeDepth();

/// @dev throws when the provided amount is insufficient for a liquidity removal.
error FixedPool__InsufficientLiquidityForRemoval();

/// @dev throws when the height spacing is set above the maximum height spacing.
error FixedPool__InvalidHeightSpacing();

/// @dev throws when input dust could yield a non-zero output amount.
error FixedPool__InvalidInputDust();

/// @dev throws when output dust could yield a non-zero input amount.
error FixedPool__InvalidOutputDust();

/// @dev throws when the packed ratio is invalid during pool creation.
error FixedPool__InvalidPackedRatio();

/// @dev throws when a precision adjustment to the amount being added when combined with the existing position value would result in a withdrawal.
error FixedPool__LiquidityAddInsufficientForPrecision();

/// @dev throws when a precision adjustment to the amount remaining during a partial withdrawal results in no liquidity being redeposited.
error FixedPool__LiquidityPartialWithdrawClearsPosition();

/// @dev throws when an operation is attempted by someone other than the designated AMM.
error FixedPool__OnlyAMM();

/// @dev throws when rounding causes an output amount validation error.
error FixedPool__OutputValidationFailed();

/// @dev throws when a calculation results in overflow.
error FixedPool__Overflow();

/// @dev throws when a liquidity add results in a start height that exceeds a user's specified maximum.
error FixedPool__StartHeightExceedsMaximum();

/// @dev throws when underflow is detected while decrementing the current liquidity height.
error FixedPool__UnderflowCurrentHeight();

/// @dev throws when crossing heights and the liquidity adjustment would underflow the liquidity amount.
error FixedPool__UnderflowLiquidity();

/// @dev throws when a swap has zero input or zero output.
error FixedPool__ZeroValueSwap();