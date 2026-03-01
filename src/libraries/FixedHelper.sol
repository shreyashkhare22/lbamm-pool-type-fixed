//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import "./FixedPoolDecoder.sol";

import "../DataTypes.sol";
import "../Errors.sol";

import "@limitbreak/tm-core-lib/src/utils/misc/SafeCast.sol";
import "@limitbreak/tm-core-lib/src/utils/math/FullMath.sol";

/**
 * @title  FixedHelper
 * @author Limit Break, Inc.
 * @notice Provides utilities for managing fixed liquidity positions, height operations, and position calculations in the LBAMM system.
 *
 * @dev    This library contains the core logic for fixed liquidity management including position modifications,
 *         height operations, fee calculations, and validation functions. It implements the mathematical and storage
 *         operations necessary for fixed liquidity pools within the Limit Break AMM framework.
 */
library FixedHelper {
    using SafeCast for uint256;
    using SafeCast for int256;

    /**
     * @notice Withdraws liquidity from a fixed pool, adjusting and redistributing any remaining tokens.
     *
     * @dev    Throws when requested withdrawal exceeds position value.
     *
     * @dev    Calculates value owed to the position, validates requested withdrawals, and redeposits remaining tokens 
     *         to new height intervals.
     *
     * @param  poolId          The id of the pool liquidity is being added to.
     * @param  liquidityParams Parameters describing withdrawal amounts and pool details.
     * @param  ptrPoolState    The current fixed pool state.
     * @param  position        The liquidity position being modified.
     */
    function withdrawLiquidity(
        bytes32 poolId,
        FixedLiquidityModificationParams memory liquidityParams,
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position
    ) internal returns (uint256 withdraw0, uint256 withdraw1, uint256 fee0, uint256 fee1) {
        uint256 value0;
        uint256 value1;

        (value0, value1, fee0, fee1) = _collectPosition(ptrPoolState, position);

        if (value0 < liquidityParams.amount0 || value1 < liquidityParams.amount1) {
            revert FixedPool__InsufficientLiquidityForRemoval();
        }
        ModifyFixedLiquidityCache memory liquidityCache;
        {
            uint256 redeposit0 = value0 - liquidityParams.amount0;
            uint256 redeposit1 = value1 - liquidityParams.amount1;
            FixedLiquidityModificationParams memory tmpLiquidityParams = liquidityParams;
            _calculateLiquidityStartAndEndHeights(
                liquidityCache,
                poolId,
                ptrPoolState,
                redeposit0,
                redeposit1,
                tmpLiquidityParams.addInRange0,
                tmpLiquidityParams.addInRange1
            );
            uint256 redeposited0 = liquidityCache.amountAddedOf0To0 + liquidityCache.amountAddedOf0To1;
            uint256 redeposited1 = liquidityCache.amountAddedOf1To0 + liquidityCache.amountAddedOf1To1;

            if (redeposited0 | redeposited1 == 0) {
                revert FixedPool__LiquidityPartialWithdrawClearsPosition();
            }

            unchecked {
                withdraw0 = value0 - redeposited0;
                withdraw1 = value1 - redeposited1;
            }

            (withdraw0, withdraw1) = _accumulateDustToWithdrawal(ptrPoolState, withdraw0, withdraw1);
        }

        if (liquidityCache.startHeight0 != liquidityCache.endHeight0) {
            if (liquidityCache.startHeight0 > liquidityParams.maxStartHeight0) {
                revert FixedPool__StartHeightExceedsMaximum();
            }

            _addLiquidity(
                ptrPoolState,
                position,
                liquidityCache.startHeight0,
                liquidityCache.endHeight0,
                liquidityParams.endHeightInsertionHint0,
                true
            );

            ptrPoolState.position0ShareOf0 += liquidityCache.amountAddedOf0To0.toUint128();
        } else {
            position.startHeight0 = 0;
            position.endHeight0 = 0;
            position.feeGrowthInside0Of0LastX128 = 0;
            position.feeGrowthInside1Of0LastX128 = 0;
        }

        if (liquidityCache.startHeight1 != liquidityCache.endHeight1) {
            if (liquidityCache.startHeight1 > liquidityParams.maxStartHeight1) {
                revert FixedPool__StartHeightExceedsMaximum();
            }
            
            _addLiquidity(
                ptrPoolState,
                position,
                liquidityCache.startHeight1,
                liquidityCache.endHeight1,
                liquidityParams.endHeightInsertionHint1,
                false
            );

            ptrPoolState.position1ShareOf1 += liquidityCache.amountAddedOf1To1.toUint128();
        } else {
            position.startHeight1 = 0;
            position.endHeight1 = 0;
            position.feeGrowthInside0Of1LastX128 = 0;
            position.feeGrowthInside1Of1LastX128 = 0;
        }
    }

    /**
     * @notice Withdraws an entire liquidity position from the pool.
     *
     * @dev    Throws when requested withdrawal exceeds position value.
     *
     * @dev    Calculates value owed to the position, validates requested withdrawals.
     *
     * @param  withdrawAllParams Parameters describing withdrawal amounts and pool details.
     * @param  ptrPoolState      The current fixed pool state.
     * @param  position          The liquidity position being modified.
     */
    function withdrawAll(
        FixedLiquidityWithdrawAllParams memory withdrawAllParams,
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position
    ) internal returns (uint256 withdraw0, uint256 withdraw1, uint256 fee0, uint256 fee1) {
        // Revert if position is empty
        if (
            position.startHeight0 == position.endHeight0 &&
            position.startHeight1 == position.endHeight1
        ) {
            revert FixedPool__InsufficientLiquidityForRemoval();
        }

        (withdraw0, withdraw1, fee0, fee1) = _collectPosition(ptrPoolState, position);
        (withdraw0, withdraw1) = _accumulateDustToWithdrawal(ptrPoolState, withdraw0, withdraw1);

        if (withdraw0 < withdrawAllParams.minAmount0 || withdraw1 < withdrawAllParams.minAmount1) {
            revert FixedPool__InsufficientLiquidityForRemoval();
        }

        // Clear position details
        position.startHeight0 = 0;
        position.endHeight0 = 0;
        position.feeGrowthInside0Of0LastX128 = 0;
        position.feeGrowthInside1Of0LastX128 = 0;
        
        position.startHeight1 = 0;
        position.endHeight1 = 0;
        position.feeGrowthInside0Of1LastX128 = 0;
        position.feeGrowthInside1Of1LastX128 = 0;
    }

    /**
     * @notice Deposits new liquidity into a fixed pool, extending existing position or creating a new one.
     *
     * @dev    Throws when precision loss prevents adequate liquidity addition.
     *
     * @dev    Combines existing position value with new amounts, applies to pool state using calculated height intervals.
     *
     * @param  liquidityParams Parameters describing deposit amounts and pool details.
     * @param  ptrPoolState    The current fixed pool state.
     * @param  position        The liquidity position being modified.
     */
    function depositLiquidity(
        bytes32 poolId,
        FixedLiquidityModificationParams memory liquidityParams,
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position
    ) internal returns (uint256 deposit0, uint256 deposit1, uint256 fee0, uint256 fee1) {
        uint256 value0;
        uint256 value1;
        (value0, value1, fee0, fee1) = _collectPosition(ptrPoolState, position);

        ModifyFixedLiquidityCache memory liquidityCache;
        {
            FixedLiquidityModificationParams memory tmpLiquidityParams = liquidityParams;
            _calculateLiquidityStartAndEndHeights(
                liquidityCache,
                poolId,
                ptrPoolState,
                tmpLiquidityParams.amount0 + value0,
                tmpLiquidityParams.amount1 + value1,
                tmpLiquidityParams.addInRange0,
                tmpLiquidityParams.addInRange1
            );
            uint256 amountAdded0 = liquidityCache.amountAddedOf0To0 + liquidityCache.amountAddedOf0To1;
            uint256 amountAdded1 = liquidityCache.amountAddedOf1To0 + liquidityCache.amountAddedOf1To1;

            if (amountAdded0 < value0 || amountAdded1 < value1) {
                revert FixedPool__LiquidityAddInsufficientForPrecision();
            }

            unchecked {
                deposit0 = amountAdded0 - value0;
                deposit1 = amountAdded1 - value1;
            }
        }

        if (deposit0 == 0 && deposit1 == 0) {
            revert FixedPool__BothTokenAmountsZeroOnDeposit();
        }

        if (liquidityCache.startHeight0 != liquidityCache.endHeight0) {
            if (liquidityCache.startHeight0 > liquidityParams.maxStartHeight0) {
                revert FixedPool__StartHeightExceedsMaximum();
            }
            
            _addLiquidity(
                ptrPoolState,
                position,
                liquidityCache.startHeight0,
                liquidityCache.endHeight0,
                liquidityParams.endHeightInsertionHint0,
                true
            );

            ptrPoolState.position0ShareOf0 += liquidityCache.amountAddedOf0To0.toUint128();
        } else {
            position.startHeight0 = 0;
            position.endHeight0 = 0;
            position.feeGrowthInside0Of0LastX128 = 0;
            position.feeGrowthInside1Of0LastX128 = 0;
        }

        if (liquidityCache.startHeight1 != liquidityCache.endHeight1) {
            if (liquidityCache.startHeight1 > liquidityParams.maxStartHeight1) {
                revert FixedPool__StartHeightExceedsMaximum();
            }
            
            _addLiquidity(
                ptrPoolState,
                position,
                liquidityCache.startHeight1,
                liquidityCache.endHeight1,
                liquidityParams.endHeightInsertionHint1,
                false
            );

            ptrPoolState.position1ShareOf1 += liquidityCache.amountAddedOf1To1.toUint128();
        } else {
            position.startHeight1 = 0;
            position.endHeight1 = 0;
            position.feeGrowthInside0Of1LastX128 = 0;
            position.feeGrowthInside1Of1LastX128 = 0;
        }
    }

    /** 
     * @notice  Checks for accumulated dust in token reserves and returns with withdrawal amounts.
     * 
     * @param ptrPoolState  Storage pointer to the fixed pool state.
     * @param withdraw0     Amount of the position being withdrawn in token0.
     * @param withdraw1     Amount of the position being withdrawn in token1.
     */
    function _accumulateDustToWithdrawal(
        FixedPoolState storage ptrPoolState,
        uint256 withdraw0,
        uint256 withdraw1
    ) internal returns (uint256 updatedWithdraw0, uint256 updatedWithdraw1) {
        uint256 dust0 = ptrPoolState.dust0;
        uint256 dust1 = ptrPoolState.dust1;
        if (dust0 > 0) {
            updatedWithdraw0 = withdraw0 + dust0;
            ptrPoolState.dust0 = 0;
        } else {
            updatedWithdraw0 = withdraw0;
        }
        if (dust1 > 0) {
            updatedWithdraw1 = withdraw1 + dust1;
            ptrPoolState.dust1 = 0;
        } else {
            updatedWithdraw1 = withdraw1;
        }
    }

    /**
     * @notice  Calculates the start and end heights of liquidity being added to a pool based on the amount being added,
     *          current pool heights, precision and if the side is to be added in range.
     * 
     * @param liquidityCache  Internal cache of liquidity modification values for stack management.
     * @param poolId          The id of the pool liquidity is being added to.
     * @param ptrPoolState    Storage pointer to the fixed pool state.
     * @param add0            The amount of liquidity to add of token0.
     * @param add1            The amount of liquidity to add of token1.
     * @param addInRange0     True if token0 should be added "in-range" by consuming a portion of `add1`.
     * @param addInRange1     True if token1 should be added "in-range" by consuming a portion of `add0`.
     */
    function _calculateLiquidityStartAndEndHeights(
        ModifyFixedLiquidityCache memory liquidityCache,
        bytes32 poolId,
        FixedPoolState storage ptrPoolState,
        uint256 add0,
        uint256 add1,
        bool addInRange0,
        bool addInRange1
    ) internal view {
        uint256 currentHeight0 = ptrPoolState.height0.currentHeight;
        uint256 precision0 = FixedPoolDecoder.getPoolHeightPrecision(poolId, true);
        uint256 originalAdd0 = add0;
        if (currentHeight0 % precision0 == 0) {
            liquidityCache.startHeight0 = currentHeight0;
        } else {
            liquidityCache.startHeight0 = currentHeight0 / precision0 * precision0;
            if (addInRange0) {
                uint256 depth0 = currentHeight0 - liquidityCache.startHeight0;
                uint256 consumedLiquidity0 = ptrPoolState.height0.consumedLiquidity;
                uint256 depth0ValueOf1 = 
                    calculateFixedSwapByRatioRoundingDown(consumedLiquidity0 + depth0, ptrPoolState.packedRatio, true) - 
                    calculateFixedSwapByRatioRoundingDown(consumedLiquidity0, ptrPoolState.packedRatio, true);
                if (add1 < depth0ValueOf1) {
                    revert FixedPool__InsufficientLiquidityForInRangeDepth();
                }
                add0 += depth0;
                add1 -= depth0ValueOf1;
                liquidityCache.amountAddedOf1To0 = depth0ValueOf1;
            } else {
                liquidityCache.startHeight0 += precision0;
            }
        }

        uint256 currentHeight1 = ptrPoolState.height1.currentHeight;
        uint256 precision1 = FixedPoolDecoder.getPoolHeightPrecision(poolId, false);
        if (currentHeight1 % precision1 == 0) {
            liquidityCache.startHeight1 = currentHeight1;
        } else {
            liquidityCache.startHeight1 = currentHeight1 / precision1 * precision1;
            if (addInRange1) {
                uint256 depth1 = currentHeight1 - liquidityCache.startHeight1;
                uint256 consumedLiquidity1 = ptrPoolState.height1.consumedLiquidity;
                uint256 depth1ValueOf0 = 
                    calculateFixedSwapByRatioRoundingDown(consumedLiquidity1 + depth1, ptrPoolState.packedRatio, false) - 
                    calculateFixedSwapByRatioRoundingDown(consumedLiquidity1, ptrPoolState.packedRatio, false);
                if (originalAdd0 < depth1ValueOf0) {
                    revert FixedPool__InsufficientLiquidityForInRangeDepth();
                }
                add1 += depth1;
                add0 -= depth1ValueOf0;
                liquidityCache.amountAddedOf0To1 = depth1ValueOf0;
            } else {
                liquidityCache.startHeight1 += precision1;
            }
        }

        uint256 precisionAddLoss0 = add0 % precision0;
        if (precisionAddLoss0 != 0) {
            add0 -= precisionAddLoss0;
        }
        liquidityCache.endHeight0 = liquidityCache.startHeight0 + add0;
        if (addInRange0) {
            if (liquidityCache.startHeight0 != liquidityCache.endHeight0) {
                liquidityCache.amountAddedOf0To0 = liquidityCache.endHeight0 - currentHeight0;
            } else {
                add1 += liquidityCache.amountAddedOf1To0;
                liquidityCache.amountAddedOf1To0 = 0;
            }
        } else {
            liquidityCache.amountAddedOf0To0 = liquidityCache.endHeight0 - liquidityCache.startHeight0;
        }

        uint256 precisionAddLoss1 = add1 % precision1;
        if (precisionAddLoss1 != 0) {
            add1 -= precisionAddLoss1;
        }
        liquidityCache.endHeight1 = liquidityCache.startHeight1 + add1;
        if (addInRange1) {
            if (liquidityCache.startHeight1 != liquidityCache.endHeight1) {
                liquidityCache.amountAddedOf1To1 = liquidityCache.endHeight1 - currentHeight1;
            } else {
                liquidityCache.amountAddedOf0To1 = 0;
            }
        } else {
            liquidityCache.amountAddedOf1To1 = liquidityCache.endHeight1 - liquidityCache.startHeight1;
        }
    }

    /**
     * @notice Collects and removes all owed liquidity and fees from a position.
     *
     * @dev    Iterates over both token sides and calculates accrued value and fees using fee growth and height state.
     *
     * @param  ptrPoolState  The current fixed pool state.
     * @param  position      The liquidity position being collected.
     * @return value0        Principal token0 value collected from position.
     * @return value1        Principal token1 value collected from position.
     * @return fee0          Accrued fees in token0.
     * @return fee1          Accrued fees in token1.
     */
    function _collectPosition(
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position
    ) internal returns (uint256 value0, uint256 value1, uint256 fee0, uint256 fee1) {
        // fee0, fee1, value0, value1 capture the side0 values initially
        // then are aggregated with side1 values for gas optimization
        // and stack management
        (
            value0,
            value1,
            fee0,
            fee1
        ) = _collectPositionSide(
            ptrPoolState,
            ptrPoolState.heightInfo0,
            ptrPoolState.height0,
            position.startHeight0,
            position.endHeight0,
            position.feeGrowthInside0Of0LastX128,
            position.feeGrowthInside1Of0LastX128,
            true
        );
        ptrPoolState.position0ShareOf0 -= value0.toUint128();

        {
            FixedPositionInfo storage positionCache = position;
            (
                uint256 side1Value0,
                uint256 side1Value1,
                uint256 side1Fee0,
                uint256 side1Fee1
            ) = _collectPositionSide(
                ptrPoolState,
                ptrPoolState.heightInfo1,
                ptrPoolState.height1,
                positionCache.startHeight1,
                positionCache.endHeight1,
                positionCache.feeGrowthInside0Of1LastX128,
                positionCache.feeGrowthInside1Of1LastX128,
                false
            );
            ptrPoolState.position1ShareOf1 -= side1Value1.toUint128();

            fee0 = fee0 + side1Fee0;
            fee1 = fee1 + side1Fee1;

            value0 = value0 + side1Value0;
            value1 = value1 + side1Value1;
        }
    }

    /**
     * @notice Collects value and fees for one token side of a liquidity position.
     *
     * @dev    Computes consumed and unconsumed liquidity amounts based on current and stored heights.
     *         Accrues fee growth across interval and removes liquidity from pool.
     *
     * @param  ptrPoolState              The current fixed pool state.
     * @param  heightInfo                Height-level metadata storage.
     * @param  height                    Current height state for the side.
     * @param  startHeight               Start of the position range.
     * @param  endHeight                 End of the position range.
     * @param  feeGrowthInside0LastX128  Previous recorded fee growth for token0.
     * @param  feeGrowthInside1LastX128  Previous recorded fee growth for token1.
     * @param  sideZero                  True if this is token0's side.
     * @return value0                    Principal token0 value collected.
     * @return value1                    Principal token1 value collected.
     * @return fee0                      Accrued fee amount in token0.
     * @return fee1                      Accrued fee amount in token1.
     */
    function _collectPositionSide(
        FixedPoolState storage ptrPoolState,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        FixedHeightState storage height,
        uint256 startHeight,
        uint256 endHeight,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        bool sideZero
    ) internal returns (
        uint256 value0,
        uint256 value1,
        uint256 fee0,
        uint256 fee1
    ) {
        if (startHeight != endHeight) {
            unchecked {
                uint256 liquidity = endHeight - startHeight;
                uint256 currentHeight = height.currentHeight;
                {
                    uint256 packedRatio = ptrPoolState.packedRatio;
                    uint256 sideValue;
                    uint256 pairValue;
                    if (currentHeight < startHeight) {
                        sideValue = liquidity;
                    } else {
                        if (currentHeight < endHeight) {
                            sideValue = endHeight - currentHeight;
                            if (height.liquidity != height.remainingAtHeight) {
                                --sideValue;
                            }
                            uint256 consumedLiquidity = height.consumedLiquidity;
                            pairValue = 
                                calculateFixedSwapByRatioRoundingDown(consumedLiquidity, packedRatio, sideZero) - 
                                calculateFixedSwapByRatioRoundingDown(consumedLiquidity - (liquidity - sideValue), packedRatio, sideZero);
                        } else {
                            uint256 consumedLiquidity = height.consumedLiquidity;
                            pairValue = 
                                calculateFixedSwapByRatioRoundingDown(consumedLiquidity, packedRatio, sideZero) - 
                                calculateFixedSwapByRatioRoundingDown(consumedLiquidity - liquidity, packedRatio, sideZero);
                        }
                    }
                    height.consumedLiquidity -= (liquidity - sideValue);
                    if (sideZero) {
                        value0 = sideValue;
                        value1 = pairValue;
                    } else {
                        value0 = pairValue;
                        value1 = sideValue;
                    }
                }
                {
                    (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = getFeeGrowthInside(
                        heightInfo,
                        height,
                        startHeight,
                        endHeight,
                        currentHeight
                    );
                    // Fee liquidity is 1 unit so we do not need to fee growth inside delta
                    fee0 = (feeGrowthInside0X128 - feeGrowthInside0LastX128) / Q128;
                    fee1 = (feeGrowthInside1X128 - feeGrowthInside1LastX128) / Q128;
                }
                _removeLiquidity(ptrPoolState, startHeight, endHeight, currentHeight, sideZero);
            }
        }
    }

    /**
     * @notice Collects accrued fees from a fixed liquidity position without modifying principal amounts.
     *
     * @dev    Calculates fee growth inside position ranges for both token sides, computes fee amounts
     *         based on growth deltas, and updates position's last recorded fee growth values.
     *         Fees are calculated per unit of liquidity using Q128 fixed-point arithmetic.
     *
     * @param  ptrPoolState    Current fixed pool state containing fee growth trackers.
     * @param  position        Liquidity position to collect fees from.
     * @return fee0            Total accrued fees in token0 from both position sides.
     * @return fee1            Total accrued fees in token1 from both position sides.
     */
    function collectFees(
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position
    ) internal returns (
        uint256 fee0,
        uint256 fee1
    ) {
        unchecked {
            (uint256 feeGrowthInside0Of0X128, uint256 feeGrowthInside1Of0X128) = getFeeGrowthInside(
                ptrPoolState.heightInfo0,
                ptrPoolState.height0,
                position.startHeight0,
                position.endHeight0,
                ptrPoolState.height0.currentHeight
            );
            (uint256 feeGrowthInside0Of1X128, uint256 feeGrowthInside1Of1X128) = getFeeGrowthInside(
                ptrPoolState.heightInfo1,
                ptrPoolState.height1,
                position.startHeight1,
                position.endHeight1,
                ptrPoolState.height1.currentHeight
            );

            fee0 = (feeGrowthInside0Of0X128 - position.feeGrowthInside0Of0LastX128) / Q128 +
                   (feeGrowthInside0Of1X128 - position.feeGrowthInside0Of1LastX128) / Q128;
            fee1 = (feeGrowthInside1Of0X128 - position.feeGrowthInside1Of0LastX128) / Q128 + 
                   (feeGrowthInside1Of1X128 - position.feeGrowthInside1Of1LastX128) / Q128;
            
            position.feeGrowthInside0Of0LastX128 = feeGrowthInside0Of0X128;
            position.feeGrowthInside0Of1LastX128 = feeGrowthInside0Of1X128;
            position.feeGrowthInside1Of0LastX128 = feeGrowthInside1Of0X128;
            position.feeGrowthInside1Of1LastX128 = feeGrowthInside1Of1X128;
        }
    }

    /**
     * @notice Updates height structures when a position's liquidity is removed.
     *
     * @dev    Adjusts liquidity counts and linked list of active heights. Only modifies metadata if current height
     *         overlaps the range being removed.
     *
     * @param  ptrPoolState  The fixed pool state.
     * @param  startHeight   Position start height.
     * @param  endHeight     Position end height.
     * @param  currentHeight Pool's current execution height.
     * @param  sideZero      True if operating on token0's side.
     */
    function _removeLiquidity(
        FixedPoolState storage ptrPoolState,
        uint256 startHeight,
        uint256 endHeight,
        uint256 currentHeight,
        bool sideZero
    ) internal {
        FixedHeightState storage height = ptrPoolState.height1;
        mapping (uint256 => FixedHeightMap) storage heightMap = ptrPoolState.heightMap1;
        mapping (uint256 => FixedHeightInfo) storage heightInfo = ptrPoolState.heightInfo1;
        if (sideZero) {
            height = ptrPoolState.height0;
            heightMap = ptrPoolState.heightMap0;
            heightInfo = ptrPoolState.heightInfo0;
        }
        unchecked {
            _removeLiquidityFromHeight(height, startHeight, heightInfo, heightMap, true);
            _removeLiquidityFromHeight(height, endHeight, heightInfo, heightMap, false);
            if (currentHeight >= startHeight && currentHeight < endHeight) {
                uint128 liquidity = height.liquidity;
                uint128 remainingAtHeight = height.remainingAtHeight;
                if (liquidity == remainingAtHeight) {
                    height.remainingAtHeight = remainingAtHeight - 1;
                }
                height.liquidity = liquidity - 1;
            }
        }
    }

    /**
     * @notice Removes one unit of liquidity at a specific height and updates the height map if needed.
     *
     * @dev    Updates the height’s gross and net liquidity. If the height becomes empty, removes it from the
     *         doubly linked list of active heights.
     *
     * @param  height         Current height state.
     * @param  fromHeight     The height being modified.
     * @param  heightInfo     Height metadata storage.
     * @param  heightMap      Linked list mapping of heights.
     * @param  start          True if this is the start height of the position.
     */
    function _removeLiquidityFromHeight(
        FixedHeightState storage height,
        uint256 fromHeight,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        mapping (uint256 => FixedHeightMap) storage heightMap,
        bool start
    ) internal {
        FixedHeightInfo storage fromHeightInfo = heightInfo[fromHeight];
        uint128 liquidityGrossAfter = fromHeightInfo.liquidityGross - 1;
        
        bool flipped = liquidityGrossAfter == 0;
        if (flipped) {
            FixedHeightMap storage mapHeight = heightMap[fromHeight];
            uint256 nextHeightBelow = mapHeight.nextHeightBelow;
            uint256 nextHeightAbove = mapHeight.nextHeightAbove;
            FixedHeightMap storage mapBelow = heightMap[nextHeightBelow];
            FixedHeightMap storage mapAbove = heightMap[nextHeightAbove];

            if (start || fromHeight != nextHeightAbove) {
                mapBelow.nextHeightAbove = nextHeightAbove;
                mapAbove.nextHeightBelow = nextHeightBelow;
            } else {
                // End height is equal to next height above so this is the tail end of positions
                // Update mapping below to reflect tail, move current height down to tail
                mapBelow.nextHeightAbove = nextHeightAbove = nextHeightBelow;
                if (nextHeightBelow < height.currentHeight) {
                    height.currentHeight = nextHeightBelow;
                }
            }

            if (height.nextHeightAbove == fromHeight) {
                height.nextHeightAbove = nextHeightAbove;
            }

            if (height.nextHeightBelow == fromHeight) {
                height.nextHeightBelow = nextHeightBelow;
            }

            if (fromHeight != 0) {
                // Do not clear heights if fromHeight is 0 to preserve linked list from 0 start
                mapHeight.nextHeightBelow = 0;
                mapHeight.nextHeightAbove = 0;
            }
        }

        fromHeightInfo.liquidityGross = liquidityGrossAfter;
        fromHeightInfo.liquidityNet += start ? int8(-1) : int8(1);
    }

    /**
     * @notice Adds new liquidity to a fixed pool, initializing height ranges and metadata.
     *
     * @dev    Aligns deposit amount to height precision, updates linked height maps, and records fee growth baselines 
     *         for future fee calculation.
     *
     * @param  ptrPoolState           Current pool state.
     * @param  position               Position being initialized or extended.
     * @param  startHeight            Height to add liquidity at.
     * @param  endHeight              Height to end the liquidity at.
     * @param  endHeightInsertionHint Upper bound for height map insertion.
     * @param  sideZero               True if for token0 side.
     */
    function _addLiquidity(
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position,
        uint256 startHeight,
        uint256 endHeight,
        uint256 endHeightInsertionHint,
        bool sideZero
    ) internal {
        FixedHeightState storage height = ptrPoolState.height1;
        mapping (uint256 => FixedHeightMap) storage heightMap = ptrPoolState.heightMap1;
        mapping (uint256 => FixedHeightInfo) storage heightInfo = ptrPoolState.heightInfo1;
        if (sideZero) {
            height = ptrPoolState.height0;
            heightMap = ptrPoolState.heightMap0;
            heightInfo = ptrPoolState.heightInfo0;
        }
        uint256 currentHeight = height.currentHeight;

        if (startHeight < currentHeight) {
            height.consumedLiquidity += (currentHeight - startHeight);
        }

        if (startHeight != endHeight) {
            unchecked {
                _addLiquidityToHeight(startHeight, heightInfo, heightMap, height.nextHeightBelow, true);
                _addLiquidityToHeight(endHeight, heightInfo, heightMap, endHeightInsertionHint, false);

                if (currentHeight >= startHeight && currentHeight < endHeight) {
                    ++height.liquidity;
                    ++height.remainingAtHeight;

                    if (height.nextHeightBelow < startHeight) {
                        height.nextHeightBelow = startHeight;
                    }
                
                    if (height.nextHeightAbove == 0 || height.nextHeightAbove > endHeight || height.nextHeightAbove <= currentHeight) {
                        height.nextHeightAbove = endHeight;
                    }
                } else {
                    if (height.nextHeightAbove == 0 || height.nextHeightAbove > startHeight) {
                        height.nextHeightAbove = startHeight;
                    }
                }
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = getFeeGrowthInside(
            heightInfo,
            height,
            startHeight,
            endHeight,
            currentHeight
        );
        if (sideZero) {
            position.startHeight0 = startHeight;
            position.endHeight0 = endHeight;
            position.feeGrowthInside0Of0LastX128 = feeGrowthInside0X128;
            position.feeGrowthInside1Of0LastX128 = feeGrowthInside1X128;
        } else {
            position.startHeight1 = startHeight;
            position.endHeight1 = endHeight;
            position.feeGrowthInside0Of1LastX128 = feeGrowthInside0X128;
            position.feeGrowthInside1Of1LastX128 = feeGrowthInside1X128;
        }
    }

    /**
     * @notice Adds one unit of liquidity to a given height and updates height map accordingly.
     *
     * @dev    Ensures the height is linked into the doubly linked list. If this is the first time the height is
     *         used, updates neighbor pointers to maintain ordering.
     *
     * @param  toHeight          The target height to add liquidity.
     * @param  heightInfo        Metadata mapping for heights.
     * @param  heightMap         Linked list mapping of heights.
     * @param  informationHeight Reference height used for insertion guidance.
     * @param  start             True if height is start of a new range.
     */
    function _addLiquidityToHeight(
        uint256 toHeight,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        mapping (uint256 => FixedHeightMap) storage heightMap,
        uint256 informationHeight,
        bool start
    ) internal {
        FixedHeightInfo storage toHeightInfo = heightInfo[toHeight];
        uint128 liquidityGrossAfter = toHeightInfo.liquidityGross + 1;
        
        bool flipped = liquidityGrossAfter == 1;
        if (flipped) {
            FixedHeightMap storage mapToHeight = heightMap[toHeight];
            FixedHeightMap storage mapInformationHeight = heightMap[informationHeight];
            while (true) {
                uint256 informationNextHeightBelow = mapInformationHeight.nextHeightBelow;
                uint256 informationNextHeightAbove = mapInformationHeight.nextHeightAbove;
                if (informationNextHeightBelow | informationNextHeightAbove == 0) {
                    // Information height is not initialized, determine if list is empty or an empty node was provided.
                    if (informationHeight == 0) {
                        // List is empty
                        if (toHeight != 0) {
                            mapInformationHeight.nextHeightAbove = toHeight;
                            mapToHeight.nextHeightAbove = toHeight;
                        }
                        break;
                    } else {
                        // Empty node, start at root
                        informationHeight = 0;
                        mapInformationHeight = heightMap[informationHeight];
                    }
                } else if (toHeight > informationHeight && toHeight < informationNextHeightAbove) {
                    // Height is between information height and next height above, add node above.
                    mapInformationHeight.nextHeightAbove = toHeight;
                    mapToHeight.nextHeightBelow = informationHeight;
                    mapToHeight.nextHeightAbove = informationNextHeightAbove;
                    heightMap[informationNextHeightAbove].nextHeightBelow = toHeight;
                    break;
                } else if(toHeight < informationHeight && toHeight > informationNextHeightBelow) {
                    // Height is between information height and next height below, add node below.
                    mapInformationHeight.nextHeightBelow = toHeight;
                    mapToHeight.nextHeightBelow = informationNextHeightBelow;
                    mapToHeight.nextHeightAbove = informationHeight;
                    heightMap[informationNextHeightBelow].nextHeightAbove = toHeight;
                    break;
                } else if (toHeight > informationHeight && informationHeight == informationNextHeightAbove) {
                    // Height is new tail height.
                    mapInformationHeight.nextHeightAbove = toHeight;
                    mapToHeight.nextHeightBelow = informationHeight;
                    mapToHeight.nextHeightAbove = toHeight;
                    break;
                } else if (toHeight < informationHeight) {
                    // Walk down linked list to find insertion point.
                    informationHeight = informationNextHeightBelow;
                    mapInformationHeight = heightMap[informationNextHeightBelow];
                } else if (toHeight > informationHeight) {
                    // Walk up linked list to find insertion point.
                    informationHeight = informationNextHeightAbove;
                    mapInformationHeight = heightMap[informationNextHeightAbove];
                } else if (toHeight == informationHeight) {
                    // The node already exists in the linked list.
                    break;
                }
            }
        }

        toHeightInfo.liquidityGross = liquidityGrossAfter;
        toHeightInfo.liquidityNet += start ? int8(1) : int8(-1);
    }

    /**
     * @notice Calculates the cumulative fee growth within a height interval.
     *
     * @dev    Uses outside fee growth values and current height to determine what portion of fee growth lies within
     *         the given interval.
     *
     * @param  heightInfo         Mapping of height metadata.
     * @param  height             Current height state.
     * @param  startHeight        Start of the interval.
     * @param  endHeight          End of the interval.
     * @param  currentHeight      Current execution height of the pool.
     * @return feeGrowthInside0X128 Accumulated fee growth for token0 inside the interval.
     * @return feeGrowthInside1X128 Accumulated fee growth for token1 inside the interval.
     */
    function getFeeGrowthInside(
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        FixedHeightState storage height,
        uint256 startHeight,
        uint256 endHeight,
        uint256 currentHeight
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        unchecked {
            FixedHeightInfo storage lower = heightInfo[startHeight];
            FixedHeightInfo storage upper = heightInfo[endHeight];
            if (currentHeight < startHeight) {
                feeGrowthInside0X128 = lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            } else if (currentHeight >= endHeight) {
                feeGrowthInside0X128 = upper.feeGrowthOutside0X128 - lower.feeGrowthOutside0X128;
                feeGrowthInside1X128 = upper.feeGrowthOutside1X128 - lower.feeGrowthOutside1X128;
            } else {
                feeGrowthInside0X128 = height.feeGrowthGlobalOf0X128 - lower.feeGrowthOutside0X128 - upper.feeGrowthOutside0X128;
                feeGrowthInside1X128 = height.feeGrowthGlobalOf1X128 - lower.feeGrowthOutside1X128 - upper.feeGrowthOutside1X128;
            }
        }
    }

    /**
     * @notice Executes a fixed input swap.
     *
     * @dev    Throws when swap amounts exceed uint128.
     *         Throws when insufficient liquidity to consume.
     *
     * @param  ptrPoolState  Storage pointer for the fixed pool state.
     * @param  swapCache     Swap operation context and state.
     */
    function swapByInput(
        FixedPoolState storage ptrPoolState,
        FixedSwapCache memory swapCache
    ) internal {
        (
            uint256 amountInAfterFees,
            uint256 lpFeeAmount,
            uint256 protocolFeeAmount
        ) = _calculateInputLPAndProtocolFee(swapCache.amountIn, swapCache.poolFeeBPS, swapCache.protocolFeeBPS);
        
        uint256 amountOut = swapCache.amountOut = calculateFixedSwapByRatioRoundingDown(amountInAfterFees, swapCache.packedRatio, swapCache.zeroForOne);

        if (amountOut > swapCache.expectedReserve) {
            //attempt an output-based swap for remaining reserves
            swapCache.swapByInput = false;
            swapCache.amountOut = swapCache.expectedReserve;
            uint256 initialAmountIn = swapCache.amountIn;
            swapByOutput(ptrPoolState, swapCache);

            if (swapCache.amountIn > initialAmountIn) {
                revert FixedPool__ActualAmountCannotExceedInitialAmount(); 
            }
        } else {
            swapCache.lpFeeAmount = lpFeeAmount;
            swapCache.protocolFee = protocolFeeAmount;

            _applySwapToLiquidity(
                ptrPoolState,
                swapCache,
                amountInAfterFees,
                amountOut
            );
        }
    }

    /**
     * @notice Calculates LP and protocol fees for input swaps.
     *
     * @dev    Deducts pool fee from input amount, then calculates protocol fee as percentage of LP fee.
     *         Uses rounding up for LP fee calculation to ensure sufficient fee collection.
     *
     * @param  amountIn            Total input amount before fees.
     * @param  poolFeeBPS          Pool fee rate in basis points.
     * @param  lpFeeBPS            Protocol fee rate as percentage of pool fee in basis points.
     * @return amountInAfterFees   Input amount available for swap after fee deduction.
     * @return lpFeeAmount         Fee amount allocated to liquidity providers.
     * @return protocolFeeAmount   Fee amount allocated to protocol.
     */
    function _calculateInputLPAndProtocolFee(
        uint256 amountIn,
        uint16 poolFeeBPS,
        uint16 lpFeeBPS
    ) internal pure returns (
        uint256 amountInAfterFees,
        uint256 lpFeeAmount,
        uint256 protocolFeeAmount
    ) {
        lpFeeAmount = FullMath.mulDivRoundingUp(amountIn, poolFeeBPS, MAX_BPS);
        unchecked {
            amountInAfterFees = amountIn - lpFeeAmount;
        }
        if (lpFeeBPS > 0) {
            protocolFeeAmount = FullMath.mulDiv(lpFeeAmount, lpFeeBPS, MAX_BPS);
            unchecked {
                lpFeeAmount -= protocolFeeAmount;
            }
        }
        
        if (lpFeeAmount > type(uint128).max) {
            revert FixedPool__AmountExceedsMaximumFeeSize();
        }
    }

    /**
     * @notice Calculates excess LP and protocol fees for input swaps that have excess amount in for the amount out received.
     *
     * @dev    Updates pool fee with excess amount, then calculates protocol fee as percentage of LP fee.
     *
     * @param  excessAmountIn           Excess amount in for the amount out.
     * @param  lpFeeBPS                 Protocol fee rate as percentage of pool fee in basis points.
     * @param  lpFeeAmountBefore        Fee amount allocated to liquidity providers before adjustment.
     * @param  protocolFeeAmountBefore  Fee amount allocated to protocol before adjustment.
     * @return lpFeeAmountAfter         Fee amount allocated to liquidity providers after adjustment.
     * @return protocolFeeAmountAfter  Fee amount allocated to protocol after adjustment.
     */
    function _calculateExcessLPAndProtocolFee(
        uint256 excessAmountIn,
        uint16 lpFeeBPS,
        uint256 lpFeeAmountBefore,
        uint256 protocolFeeAmountBefore
    ) internal pure returns (
        uint256 lpFeeAmountAfter,
        uint256 protocolFeeAmountAfter
    ) {
        uint256 totalFeesBefore = excessAmountIn + lpFeeAmountBefore + protocolFeeAmountBefore;
        lpFeeAmountAfter = totalFeesBefore;
        if (lpFeeBPS > 0) {
            protocolFeeAmountAfter = FullMath.mulDiv(totalFeesBefore, lpFeeBPS, MAX_BPS);
            unchecked {
                lpFeeAmountAfter -= protocolFeeAmountAfter;
            }
        }
        
        if (lpFeeAmountAfter > type(uint128).max) {
            revert FixedPool__AmountExceedsMaximumFeeSize();
        }
    }

    /**
     * @notice Executes a fixed output swap.
     *
     * @dev    Throws when swap amounts exceed uint128.
     *         Throws when insufficient liquidity to consume.
     *
     * @param  ptrPoolState  Storage pointer for the fixed pool state.
     * @param  swapCache     Swap operation context and state.
     */
    function swapByOutput(
        FixedPoolState storage ptrPoolState,
        FixedSwapCache memory swapCache
    ) internal {
        uint256 amountOut = swapCache.amountOut;
        if (amountOut > swapCache.expectedReserve) {
            amountOut = swapCache.amountOut = swapCache.expectedReserve;
        }

        uint256 reserveAmountIn = calculateFixedSwapByRatio(amountOut, swapCache.packedRatio, !swapCache.zeroForOne);

        (
            uint256 swapAmountIn,
            uint256 lpFeeAmount,
            uint256 protocolFeeAmount
        ) = _calculateOutputLPAndProtocolFee(reserveAmountIn, swapCache.poolFeeBPS, swapCache.protocolFeeBPS);

        swapCache.amountIn = swapAmountIn;
        swapCache.lpFeeAmount = lpFeeAmount;
        swapCache.protocolFee = protocolFeeAmount;

        _applySwapToLiquidity(
            ptrPoolState,
            swapCache,
            reserveAmountIn,
            amountOut
        );
    }

    /**
     * @notice Calculates LP and protocol fees for output swaps.
     *
     * @dev    Calculates required fee amount to achieve target reserve input, then splits between LP and protocol.
     *         Uses different calculation method due to output-first fee structure.
     *
     * @param  reserveAmountIn     Amount needed by reserves (before fees).
     * @param  poolFeeBPS          Pool fee rate in basis points.
     * @param  lpFeeBPS            Protocol fee rate as percentage of pool fee in basis points.
     * @return amountInAfterFees   Total input amount including fees.
     * @return lpFeeAmount         Fee amount allocated to liquidity providers.
     * @return protocolFeeAmount   Fee amount allocated to protocol.
     */
    function _calculateOutputLPAndProtocolFee(
        uint256 reserveAmountIn,
        uint16 poolFeeBPS,
        uint16 lpFeeBPS
    ) internal pure returns (
        uint256 amountInAfterFees,
        uint256 lpFeeAmount,
        uint256 protocolFeeAmount
    ) {
        lpFeeAmount = FullMath.mulDivRoundingUp(reserveAmountIn, poolFeeBPS, MAX_BPS - poolFeeBPS);
        unchecked {
            amountInAfterFees = reserveAmountIn + lpFeeAmount;

            if (amountInAfterFees < lpFeeAmount) {
                revert FixedPool__Overflow();
            }
        }
        if (lpFeeBPS > 0) {
            protocolFeeAmount = FullMath.mulDiv(lpFeeAmount, lpFeeBPS, MAX_BPS);
            unchecked {
                lpFeeAmount -= protocolFeeAmount;
            }
        }
        
        if (lpFeeAmount > type(uint128).max) {
            revert FixedPool__AmountExceedsMaximumFeeSize();
        }
    }

    /**
     * @notice  Simplifies a packed ratio by dividing both components by their greatest common divisor.
     * 
     * @param  packedRatio      Packed ratio of token0 to token1 representing price.
     * @return simplifiedRatio  Simplified packed ratio.
     */
    function simplifyRatio(uint256 packedRatio) internal pure returns (uint256 simplifiedRatio) {
        uint256 ratio0 = packedRatio >> 128;
        uint256 ratio1 = uint128(packedRatio);
        {
            (uint256 x, uint256 y) = (ratio0, ratio1);
            while (y != 0) {
                (x, y) = (y, x % y);
            }
            ratio0 = ratio0 / x;
            ratio1 = ratio1 / x;
        }
        simplifiedRatio = ratio0 << 128 | ratio1;
    }

    /**
     * @notice  Converts a sqrt price ratio to a packed price ratio.
     *          When the sqrt price ratio is >1:1, the token1 amount is fixed at RATIO_BASE.
     *          When the sqrt price ratio is <=1:1, the token0 amount is fixed at RATIO_BASE. 
     * 
     * @param  sqrtPriceX96  The sqrt price in Q96 format.
     * @return packedRatio   Normalized ratio packed with token0 amount in the upper 128 bits and token1 in the lower 128 bits. 
     */
    function normalizePriceToRatio(uint160 sqrtPriceX96) internal pure returns (uint256 packedRatio) {
        uint256 ratio0;
        uint256 ratio1;
        if (sqrtPriceX96 > Q96) {
            ratio1 = RATIO_BASE;
            ratio0 = FullMath.mulDiv(ratio1, Q96, sqrtPriceX96);
            ratio0 = FullMath.mulDiv(ratio0, Q96, sqrtPriceX96);
        } else {
            ratio0 = RATIO_BASE;
            ratio1 = FullMath.mulDiv(ratio0, sqrtPriceX96, Q96);
            ratio1 = FullMath.mulDiv(ratio1, sqrtPriceX96, Q96);
        }
        packedRatio = simplifyRatio(ratio0 << 128 | ratio1);
    }

    /**
     * @notice  Helper function to unpack a packed ratio into its numerator and denominator components
     *          based on the swap direction.
     * 
     * @param  packedRatio               Packed ratio of token0 to token1 representing price.
     * @param  zeroForOneEqsSwapByInput  Sets the price direction based on flow and calculation path.
     * @return numerator                 Price numerator to use during calculations.
     * @return denominator               Price denominator to use during calculations.
     */
    function unpackRatio(
        uint256 packedRatio,
        bool zeroForOneEqsSwapByInput
    ) internal pure returns (uint256 numerator, uint256 denominator) {
        if (zeroForOneEqsSwapByInput) {
            denominator = packedRatio >> 128;
            numerator = uint128(packedRatio);
        } else {
            numerator = packedRatio >> 128;
            denominator = uint128(packedRatio);
        }
    }

    /**
     * @notice Calculates the unspecified amount from specified using fixed pool ratio, rounding up.
     *
     * @param  amountSpecified           Specified input or output amount.
     * @param  packedRatio               Packed ratio of token0 to token1 representing price.
     * @param  zeroForOneEqsSwapByInput  Sets the price direction based on flow and calculation path.
     * @return amountUnspecified         Calculated output or input amount.
     */
    function calculateFixedSwapByRatio(
        uint256 amountSpecified,
        uint256 packedRatio,
        bool zeroForOneEqsSwapByInput
    ) internal pure returns (uint256 amountUnspecified) {
        (uint256 numerator, uint256 denominator) = unpackRatio(packedRatio, zeroForOneEqsSwapByInput);
        amountUnspecified = FullMath.mulDivRoundingUp(amountSpecified, numerator, denominator);
    }

    /**
     * @notice Calculates the unspecified amount from specified using fixed pool price, rounding up.
     * 
     * @dev    This is a helper function for applications that have not converted to a normalized price ratio.
     *
     * @param  amountSpecified           Specified input or output amount.
     * @param  sqrtPriceX96              Pool's sqrt price in Q96 format.
     * @param  zeroForOneEqsSwapByInput  Sets the price direction based on flow and calculation path.
     * @return amountUnspecified         Calculated output or input amount.
     */
    function calculateFixedSwap(
        uint256 amountSpecified,
        uint160 sqrtPriceX96,
        bool zeroForOneEqsSwapByInput
    ) internal pure returns (uint256 amountUnspecified) {
        amountUnspecified = calculateFixedSwapByRatio(
            amountSpecified,
            normalizePriceToRatio(sqrtPriceX96),
            zeroForOneEqsSwapByInput
        );
    }

    /**
     * @notice Calculates the unspecified amount from specified using fixed pool ratio, rounding up.
     *
     * @param  amountSpecified           Specified input or output amount.
     * @param  packedRatio               Packed ratio of token0 to token1 representing price.
     * @param  zeroForOneEqsSwapByInput  Sets the price direction based on flow and calculation path.
     * @return amountUnspecified         Calculated output or input amount.
     */
    function calculateFixedSwapByRatioRoundingDown(
        uint256 amountSpecified,
        uint256 packedRatio,
        bool zeroForOneEqsSwapByInput
    ) internal pure returns (uint256 amountUnspecified) {
        (uint256 numerator, uint256 denominator) = unpackRatio(packedRatio, zeroForOneEqsSwapByInput);
        amountUnspecified = FullMath.mulDiv(amountSpecified, numerator, denominator);
    }

    /**
     * @notice Calculates the unspecified amount from specified using fixed pool price, rounding down.
     * 
     * @dev    This is a helper function for applications that have not converted to a normalized price ratio.
     *
     * @param  amountSpecified           Specified input or output amount.
     * @param  sqrtPriceX96              Pool's sqrt price in Q96 format.
     * @param  zeroForOneEqsSwapByInput  Sets the price direction based on flow and calculation path.
     * @return amountUnspecified         Calculated output or input amount.
     */
    function calculateFixedSwapRoundingDown(
        uint256 amountSpecified,
        uint160 sqrtPriceX96,
        bool zeroForOneEqsSwapByInput
    ) internal pure returns (uint256 amountUnspecified) {
        amountUnspecified = calculateFixedSwapByRatioRoundingDown(
            amountSpecified,
            normalizePriceToRatio(sqrtPriceX96),
            zeroForOneEqsSwapByInput
        );
    }

    /**
     * @notice Calculates the share delta and unconsumed liquidity delta created when consuming 
     *         liquidity on the output height (increasing).
     *
     * @param  currentConsumedLiquidity  Amount of consumed liquidity of the output token.
     * @param  currentShare              Output height's share of the input token.
     * @param  shareDelta                Amount of input token to increase the current share by.
     * @param  availableLiquidity        Amount of output token available to consume.
     * @param  packedRatio               Packed ratio of token0 to token1 representing price.
     * @param  zeroForOne                True if swapping token0 for token1, false otherwise.
     * @return consumedLiquidityDelta    Amount of output tokens consumed to generate the input share delta.
     * @return unconsumedShareDelta      Amount of expected input token that could not be turned into output share.
     */
    function calculateShareDeltaForLiquidityConsumption(
        uint256 currentConsumedLiquidity,
        uint256 currentShare,
        uint256 shareDelta,
        uint256 availableLiquidity,
        uint256 packedRatio,
        bool zeroForOne
    ) internal pure returns (uint256 consumedLiquidityDelta, uint256 unconsumedShareDelta) {
        if (shareDelta == 0) {
            return (0, 0);
        }
        (uint256 numerator, uint256 denominator) = unpackRatio(packedRatio, zeroForOne);
        uint256 newShare = currentShare + shareDelta;
        uint256 newShareLiquidity;
        if (denominator > numerator) {
            // Each share represents a partial amount of the paired token
            // Floor the new share amount and calculate liquidity amount where it crosses
            newShareLiquidity = FullMath.mulDiv(newShare, numerator, denominator);
            if (FullMath.mulDiv(newShareLiquidity + 1, denominator, numerator) == newShare) {
                // Expected new share landed exactly on boundary, round up to consume
                ++newShareLiquidity;
            } else {
                // Expected new share was not on boundary, recalculate share rounding down
                newShare = FullMath.mulDiv(newShareLiquidity, denominator, numerator);
            }

            if (newShare <= currentShare) {
                // Share delta insufficient to consume liquidity
                return (0, shareDelta);
            }
        } else {
            // Each share represents a full amount of the paired tokens
            // Calculate new share liquidity rounding up for the point where it crosses
            newShareLiquidity = FullMath.mulDivRoundingUp(newShare, numerator, denominator);
        }

        consumedLiquidityDelta = newShareLiquidity - currentConsumedLiquidity;
        if (consumedLiquidityDelta > availableLiquidity) {
            newShareLiquidity = currentConsumedLiquidity + availableLiquidity;
            newShare = FullMath.mulDiv(newShareLiquidity, denominator, numerator);
            newShareLiquidity = FullMath.mulDivRoundingUp(newShare, numerator, denominator);

            if (newShare <= currentShare) {
                // Share delta insufficient to consume liquidity
                return (0, shareDelta);
            }

            consumedLiquidityDelta = newShareLiquidity - currentConsumedLiquidity;
        }
        unconsumedShareDelta = shareDelta - (newShare - currentShare);
    }

    /**
     * @notice Calculates the share delta and unconsumed liquidity delta created when returning 
     *         liquidity to the input height (decreasing).
     *
     * @param  currentShare               Input height's share of the output token.
     * @param  consumedLiquidity          Amount of consumed liquidity of the input token.
     * @param  consumedLiquidityDelta     Amount of input token to return to the input height.
     * @param  packedRatio                Packed ratio of token0 to token1 representing price.
     * @param  zeroForOne                 True if swapping token0 for token1, false otherwise.
     * @param  allowPartialCross          True if partial returns that do not fully cross share boundaries are allowed.
     * @return shareDelta                 Amount of output tokens generated by returning the input token.
     * @return unreturnedLiquidityDelta   Amount of expected input token that was not returned.
     * @return returnableLiquidityDelta   Amount of input token that can be returned after the calculation without crossing a share boundary.
     */
    function calculateShareDeltaForLiquidityReturn(
        uint256 currentShare,
        uint256 consumedLiquidity,
        uint256 consumedLiquidityDelta,
        uint256 packedRatio,
        bool zeroForOne,
        bool allowPartialCross
    ) internal pure returns (
        uint256 shareDelta,
        uint256 unreturnedLiquidityDelta,
        uint256 returnableLiquidityDelta
    ) {
        if (consumedLiquidityDelta == 0) {
            // No consumed liquidity being returned
            return (0, 0, 0);
        } else if (consumedLiquidityDelta > consumedLiquidity) {
            // Delta greater than current consumed liquidity, share will go to 0
            shareDelta = currentShare;
            unreturnedLiquidityDelta = consumedLiquidityDelta - consumedLiquidity;
        } else {
            uint256 totalConsumedLiquidity = consumedLiquidity - consumedLiquidityDelta;
            (uint256 numerator, uint256 denominator) = unpackRatio(packedRatio, zeroForOne);

            uint256 newShare = FullMath.mulDiv(totalConsumedLiquidity, numerator, denominator);
            if (newShare == currentShare) {
                return (0, consumedLiquidityDelta, 0);
            }
            
            uint256 requiredLiquidity = FullMath.mulDivRoundingUp(newShare, denominator, numerator);
            if (totalConsumedLiquidity != requiredLiquidity) {
                uint256 boundaryShare = newShare + 1;
                uint256 boundaryLiquidity = FullMath.mulDivRoundingUp(boundaryShare, denominator, numerator);
                if (allowPartialCross) {
                    requiredLiquidity = totalConsumedLiquidity;
                    returnableLiquidityDelta = boundaryLiquidity - totalConsumedLiquidity - 1;
                } else {
                    // Move share up and recompute to boundary
                    newShare = boundaryShare;
                    if (newShare == currentShare) {
                        // Share did not move, no liquidity returned
                        return (0, consumedLiquidityDelta, 0);
                    }
                    requiredLiquidity = boundaryLiquidity;
                }
            }

            shareDelta = currentShare - newShare;
            unreturnedLiquidityDelta = consumedLiquidityDelta - (consumedLiquidity - requiredLiquidity);
        }
    }

    /**
     * @notice  Calculates the expected reserve amount and reserve amount attributed to the paired token.
     * 
     * @param  ptrPoolState  Storage pointer for the fixed pool state.
     * @param  swapCache     Swap operation context and state.
     */
    function updateExpectedReserve(
        FixedPoolState storage ptrPoolState,
        FixedSwapCache memory swapCache
    ) internal view {
        uint256 packedRatio = swapCache.packedRatio;
        uint256 outputHeightOutputCapacity;
        uint256 consumedLiquidityInputHeight;
        uint256 consumedLiquidityOutputHeight;
        bool zeroForOne = swapCache.zeroForOne;

        if (zeroForOne) {
            swapCache.outputShareOfExpectedReserve = outputHeightOutputCapacity = ptrPoolState.position1ShareOf1;
            swapCache.consumedLiquidityInputHeight = consumedLiquidityInputHeight = ptrPoolState.height0.consumedLiquidity;
            swapCache.consumedLiquidityOutputHeight = consumedLiquidityOutputHeight = ptrPoolState.height1.consumedLiquidity;
        } else {
            swapCache.outputShareOfExpectedReserve = outputHeightOutputCapacity = ptrPoolState.position0ShareOf0;
            swapCache.consumedLiquidityInputHeight = consumedLiquidityInputHeight = ptrPoolState.height1.consumedLiquidity;
            swapCache.consumedLiquidityOutputHeight = consumedLiquidityOutputHeight = ptrPoolState.height0.consumedLiquidity;
        }

        swapCache.outputHeightInputShare = calculateFixedSwapByRatioRoundingDown(consumedLiquidityOutputHeight, packedRatio, !zeroForOne);
        uint256 inputHeightOutputCapacity = calculateFixedSwapByRatioRoundingDown(consumedLiquidityInputHeight, packedRatio, zeroForOne);
        swapCache.inputShareOfExpectedReserve = inputHeightOutputCapacity;
        swapCache.expectedReserve = outputHeightOutputCapacity + inputHeightOutputCapacity;

        if (swapCache.expectedReserve == 0) {
            revert FixedPool__InsufficientExpectedReserve();
        }
    }

    /**
     * @notice  Calculates the expected reserve amounts for both tokens in the pool.
     * 
     * @param  ptrPoolState      Storage pointer for the fixed pool state.
     * @return expectedReserve0  The amount of expected reserve tokens for token0.
     * @return expectedReserve1  The amount of expected reserve tokens for token1.
     */
    function getExpectedReserves(
        FixedPoolState storage ptrPoolState
    ) internal view returns (uint256 expectedReserve0, uint256 expectedReserve1) {
        uint256 packedRatio = ptrPoolState.packedRatio;

        expectedReserve0 = ptrPoolState.position0ShareOf0 + 
            calculateFixedSwapByRatioRoundingDown(ptrPoolState.height1.consumedLiquidity, packedRatio, false);

        expectedReserve1 = ptrPoolState.position1ShareOf1 + 
            calculateFixedSwapByRatioRoundingDown(ptrPoolState.height0.consumedLiquidity, packedRatio, true);
    }

    /**
     * @notice Applies swap effects to fixed pool liquidity state.
     *
     * @dev    Converts swap amounts to uint128 and delegates to height update logic.
     *         Handles direction-specific amount assignment for token0 and token1.
     *
     * @param  ptrPoolState  Fixed pool state to modify.
     * @param  swapCache     Swap operation context and state.
     * @param  amountIn      Input amount consumed by swap.
     * @param  amountOut     Output amount produced by swap.
     */
    function _applySwapToLiquidity(
        FixedPoolState storage ptrPoolState,
        FixedSwapCache memory swapCache,
        uint256 amountIn,
        uint256 amountOut
    ) internal {
        uint256 amount0;
        uint256 amount1;
        if (swapCache.zeroForOne) {
            amount0 = amountIn.toUint128();
            amount1 = amountOut.toUint128();
        } else {
            amount1 = amountIn.toUint128();
            amount0 = amountOut.toUint128();
        }
        
        _updateFixedPoolHeights(
            ptrPoolState,
            swapCache,
            amount0,
            amount1
        );
    }

    /**
     * @notice Updates liquidity heights and reserves after a fixed price swap.
     *
     * @dev    Throws when swap amounts exceed uint128.
     *         Throws when insufficient liquidity to consume.
     *
     * @dev    Splits each swap into virtual portions impacting each side's attributed liquidity. Adjusts
     *         pool state and reserves accordingly while accruing fees into the appropriate height.
     *
     * @param  ptrPoolState  Fixed pool state.
     * @param  swapCache     Swap operation context and state.
     * @param  amount0       Swap amount for token0.
     * @param  amount1       Swap amount for token1.
     */
    function _updateFixedPoolHeights(
        FixedPoolState storage ptrPoolState,
        FixedSwapCache memory swapCache,
        uint256 amount0,
        uint256 amount1
    ) internal {
        if (amount0 | amount1 > type(uint128).max) {
            revert FixedPool__AmountExceedsMaximumReserveSize();
        }

        uint256 amount0FilledByHeight0;
        uint256 amount1FilledByHeight1;
        uint256 lpFeeAmountFor0;
        uint256 lpFeeAmountFor1;
        if (swapCache.zeroForOne) {
            (
                amount0FilledByHeight0,
                amount1FilledByHeight1,
                lpFeeAmountFor0,
                lpFeeAmountFor1
            ) = _splitAmountsAndFeesByHeight(
                ptrPoolState,
                swapCache,
                true,
                amount1,
                amount0
            );
            _decreaseHeight(
                ptrPoolState.height0,
                ptrPoolState.heightInfo0,
                ptrPoolState.heightMap0,
                amount0FilledByHeight0,
                lpFeeAmountFor0,
                true
            );
            _increaseHeight(
                ptrPoolState.height1,
                ptrPoolState.heightInfo1,
                ptrPoolState.heightMap1,
                amount1FilledByHeight1,
                lpFeeAmountFor1,
                true
            );
            ptrPoolState.position0ShareOf0 += uint128(amount0FilledByHeight0);
            ptrPoolState.position1ShareOf1 -= uint128(amount1FilledByHeight1);
        } else {
            (
                amount1FilledByHeight1,
                amount0FilledByHeight0,
                lpFeeAmountFor1,
                lpFeeAmountFor0
            ) = _splitAmountsAndFeesByHeight(
                ptrPoolState,
                swapCache,
                false,
                amount0,
                amount1
            );
            _increaseHeight(
                ptrPoolState.height0,
                ptrPoolState.heightInfo0,
                ptrPoolState.heightMap0,
                amount0FilledByHeight0,
                lpFeeAmountFor0,
                false
            );
            _decreaseHeight(
                ptrPoolState.height1,
                ptrPoolState.heightInfo1,
                ptrPoolState.heightMap1,
                amount1FilledByHeight1,
                lpFeeAmountFor1,
                false
            );
            ptrPoolState.position0ShareOf0 -= uint128(amount0FilledByHeight0);
            ptrPoolState.position1ShareOf1 += uint128(amount1FilledByHeight1);
        }

        if (amount0FilledByHeight0 == 0 && amount1FilledByHeight1 == 0) {
            revert FixedPool__BothTokenAmountsZeroOnSwap();
        }
    }

    /**
     * @notice Splits the amount in, amount out, and LP fee based on proportional share of the input token's virtual reserves.
     * 
     * @param  ptrPoolState                   Fixed pool state.
     * @param  swapCache                      Swap operation context and state.
     * @param  zeroForOne                     True if swapping token0 for token1, false otherwise.
     * @param  amountOut                      Output amount produced by the swap.
     * @param  amountIn                       Input amount consumed by the swap.
     * @return amountInFilledByInputHeight    Amount of input token to decrease the input height by.
     * @return amountOutFilledByOutputHeight  Amount of output token to increase the output height by.
     * @return lpFeeAmountForInputHeight      LP fee amount to apply to the input token height.
     * @return lpFeeAmountForOutputHeight     LP fee amount to apply to the output token height.
     */
    function _splitAmountsAndFeesByHeight(
        FixedPoolState storage ptrPoolState,
        FixedSwapCache memory swapCache,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountIn
    ) internal returns(
        uint256 amountInFilledByInputHeight,
        uint256 amountOutFilledByOutputHeight,
        uint256 lpFeeAmountForInputHeight,
        uint256 lpFeeAmountForOutputHeight
    ) {
        // Split amounts by heights
        uint256 expectedAmountOutFilledByInputHeight;
        uint256 expectedAmountInFilledByOutputHeight;
        {
            // Compute proportional amount in to be filled by input height
            amountInFilledByInputHeight = FullMath.mulDivRoundingUp(amountIn, swapCache.inputShareOfExpectedReserve, swapCache.expectedReserve);
            uint256 unfilledInput;

            // Consume input by returning to input height
            (expectedAmountOutFilledByInputHeight, unfilledInput,) = calculateShareDeltaForLiquidityReturn(
                swapCache.inputShareOfExpectedReserve,
                swapCache.consumedLiquidityInputHeight,
                amountInFilledByInputHeight,
                swapCache.packedRatio,
                zeroForOne,
                false
            );

            // Remove unfilled input from input height allocation, consume input through output height
            amountInFilledByInputHeight -= unfilledInput;
            expectedAmountInFilledByOutputHeight = amountIn - amountInFilledByInputHeight;
            (amountOutFilledByOutputHeight, unfilledInput) = calculateShareDeltaForLiquidityConsumption(
                swapCache.consumedLiquidityOutputHeight,
                swapCache.outputHeightInputShare,
                expectedAmountInFilledByOutputHeight,
                swapCache.outputShareOfExpectedReserve,
                swapCache.packedRatio,
                zeroForOne
            );

            uint256 returnableInput;
            if (unfilledInput > 0) {
                // Remaining unfilled input from proportional split rounding is consumed by returning to input height,
                // if there is remaining output to fill. Input may cross in between share boundaries and will return
                // the returnableInput as the amount that can be deducted from amountInFilledByInputHeight without
                // reducing the output filled from input height.
                expectedAmountInFilledByOutputHeight -= unfilledInput;
                if (expectedAmountOutFilledByInputHeight + amountOutFilledByOutputHeight < amountOut) {
                    amountInFilledByInputHeight += unfilledInput;
                    (expectedAmountOutFilledByInputHeight, unfilledInput, returnableInput) = calculateShareDeltaForLiquidityReturn(
                        swapCache.inputShareOfExpectedReserve,
                        swapCache.consumedLiquidityInputHeight,
                        amountInFilledByInputHeight,
                        swapCache.packedRatio,
                        zeroForOne,
                        true
                    );
                    amountInFilledByInputHeight -= unfilledInput;
                }
            }

            if (expectedAmountOutFilledByInputHeight + amountOutFilledByOutputHeight < amountOut) {
                // Swap by output must fill the entire amountOut, adjust amountOutFilledByOutputHeight up to cover
                // any remaining unfilled output. If additional input is required, fill from unfilledInput first,
                // then adjust amountInFilledByInputHeight up to cover any remaining delta up to returnableInput.
                amountOutFilledByOutputHeight = amountOut - expectedAmountOutFilledByInputHeight;
                if (amountOutFilledByOutputHeight > swapCache.outputShareOfExpectedReserve) {
                    revert FixedPool__OutputValidationFailed();
                }
                uint256 newOutputHeightInputShare = calculateFixedSwapByRatioRoundingDown(
                    swapCache.consumedLiquidityOutputHeight + amountOutFilledByOutputHeight,
                    swapCache.packedRatio,
                    !zeroForOne
                );
                uint256 actualAmountInFromOutputHeight = newOutputHeightInputShare - swapCache.outputHeightInputShare;
                if (actualAmountInFromOutputHeight > expectedAmountInFilledByOutputHeight) {
                    // Amount in from output height has increased, consume from unfilledInput then returnableInput if needed.
                    uint256 amountInFromOutputHeightDelta = actualAmountInFromOutputHeight - expectedAmountInFilledByOutputHeight;
                    if (amountInFromOutputHeightDelta > unfilledInput) {
                        amountInFromOutputHeightDelta -= unfilledInput;
                        if (amountInFromOutputHeightDelta > returnableInput) {
                            amountInFilledByInputHeight -= returnableInput;
                        } else {
                            amountInFilledByInputHeight -= amountInFromOutputHeightDelta;
                        }
                    }
                    expectedAmountInFilledByOutputHeight = actualAmountInFromOutputHeight;
                }
            }
        }

        // Check totals against swap invariants
        uint256 totalAmountInFilled = amountInFilledByInputHeight + expectedAmountInFilledByOutputHeight;
        {
            uint256 totalAmountOutFilled = expectedAmountOutFilledByInputHeight + amountOutFilledByOutputHeight;
            if (totalAmountInFilled == 0 || totalAmountOutFilled == 0) {
                revert FixedPool__ZeroValueSwap();
            }
            if (swapCache.swapByInput) {
                // Swap by input cannot exceed amountIn, unused input converts to fees
                // and actual output propogates to swap execution
                if (totalAmountInFilled > amountIn) {
                    revert FixedPool__InputValidationFailed();
                }

                if (totalAmountInFilled < amountIn) {
                    uint256 dust = amountIn - totalAmountInFilled;

                    // Validate input dust does not exceed the input of one output unit
                    uint256 potentialDustForOneOutput = calculateFixedSwapByRatio(1, swapCache.packedRatio, !zeroForOne);
                    if (dust > potentialDustForOneOutput) {
                        revert FixedPool__InvalidInputDust();
                    }
                }

                swapCache.amountOut = amountOut = totalAmountOutFilled;
            } else {
                if (totalAmountInFilled > amountIn) {
                    // Allow a maximum of 1 unit of input over the initial amountIn for split rounding
                    if (totalAmountInFilled > amountIn + 1) {
                        revert FixedPool__InputValidationFailed();
                    }

                    // Stack management
                    FixedSwapCache memory tmpSwapCache = swapCache;
                    // Recalculate fees based on actual total input filled
                    (
                        tmpSwapCache.amountIn,
                        tmpSwapCache.lpFeeAmount,
                        tmpSwapCache.protocolFee
                    ) = _calculateOutputLPAndProtocolFee(totalAmountInFilled, tmpSwapCache.poolFeeBPS, tmpSwapCache.protocolFeeBPS);
                }

                // If there is excess output, convert to dust.
                if (totalAmountOutFilled > amountOut) {
                    uint256 dust = totalAmountOutFilled - amountOut;

                    // Validate output dust does not exceed the output of one input unit
                    uint256 potentialDustForOneInput = calculateFixedSwapByRatio(1, swapCache.packedRatio, zeroForOne);
                    if (dust > potentialDustForOneInput) {
                        revert FixedPool__InvalidOutputDust();
                    }

                    amountOut = totalAmountOutFilled;
                    if (zeroForOne) {
                        ptrPoolState.dust1 += dust;
                    } else {
                        ptrPoolState.dust0 += dust;
                    }
                }
            }
        }

        // Handle excess amountIn
        {
            if (totalAmountInFilled < amountIn) {
                // Convert unused input to fees
                unchecked {
                    uint256 excessAmountIn = amountIn - totalAmountInFilled;
                    (swapCache.lpFeeAmount, swapCache.protocolFee) = _calculateExcessLPAndProtocolFee(
                        excessAmountIn,
                        swapCache.protocolFeeBPS,
                        swapCache.lpFeeAmount,
                        swapCache.protocolFee
                    );
                }
            }
        }

        // Compute fee split
        {
            uint256 lpFeeAmount = swapCache.lpFeeAmount;
            lpFeeAmountForOutputHeight = FullMath.mulDiv(lpFeeAmount, amountOutFilledByOutputHeight, amountOut > 0 ? amountOut : 1);
            lpFeeAmountForInputHeight = lpFeeAmount - lpFeeAmountForOutputHeight;
        }
    }

    /**
     * @notice Decreases the height state to reflect consumed liquidity after a swap.
     *
     * @dev    Throws when insufficient liquidity to consume.
     *
     * @dev    Walks down the height range, consuming liquidity in order. Adjusts fee growth globally
     *         based on proportional consumption. Crosses to new height intervals if necessary.
     *
     * @param  height         Mutable height state.
     * @param  heightInfo     Height metadata mapping.
     * @param  heightMap      Linked list of height intervals.
     * @param  amount         Liquidity amount to remove.
     * @param  feeAmount      Total fee to distribute across the removed liquidity.
     * @param  zeroForOne     Direction of the swap.
     */
    function _decreaseHeight(
        FixedHeightState storage height,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        mapping (uint256 => FixedHeightMap) storage heightMap,
        uint256 amount,
        uint256 feeAmount,
        bool zeroForOne
    ) internal {
        if (amount > 0) {
            unchecked {
                uint256 consumedLiquidity = height.consumedLiquidity;
                if (consumedLiquidity < amount) {
                    revert FixedPool__UnderflowCurrentHeight();
                }
                height.consumedLiquidity = consumedLiquidity - amount;
            }
            FixedHeightState memory heightCache = height;
            uint256 remaining = amount;
            bool crossedHeights;
            while (remaining != 0) {
                if (
                    heightCache.currentHeight == heightCache.nextHeightBelow &&
                    heightCache.liquidity == heightCache.remainingAtHeight
                ) {
                    // Cross height if we are at a height boundary
                    _crossHeight(heightCache, heightInfo, heightMap, false);
                    crossedHeights = true;
                }
                uint256 heightConsumedLiquidity = heightCache.liquidity - heightCache.remainingAtHeight;
                uint256 liquidityToNextHeight = 
                    heightConsumedLiquidity +
                    (heightCache.currentHeight - heightCache.nextHeightBelow) * heightCache.liquidity;
                uint256 returnedAtHeight;
                if (remaining >= liquidityToNextHeight) {
                    // Return all liquidity to next height below, will cross height boundary if remaining > 0
                    unchecked {
                        returnedAtHeight = liquidityToNextHeight;
                        remaining -= liquidityToNextHeight;
                        heightCache.currentHeight = heightCache.nextHeightBelow;
                        heightCache.remainingAtHeight = heightCache.liquidity;
                    }
                } else {
                    returnedAtHeight = remaining;
                    if (remaining > heightConsumedLiquidity) {
                        // Return liquidity and move current height
                        remaining -= heightConsumedLiquidity;
                        uint256 heightToMove = remaining / heightCache.liquidity;
                        remaining -= heightToMove * heightCache.liquidity;
                        if (remaining == 0) {
                            // Even height movement after filling current height
                            heightCache.remainingAtHeight = heightCache.liquidity;
                            heightCache.currentHeight -= heightToMove;
                        } else {
                            // Partial remaining, move down one additional height and return remaining
                            heightCache.remainingAtHeight = uint128(remaining);
                            heightCache.currentHeight -= (heightToMove + 1);
                        }
                    } else {
                        // Return liquidity within current height
                        heightCache.remainingAtHeight += uint128(remaining);
                    }
                    remaining = 0;
                }

                // Distribute fees to height liquidity
                unchecked {
                    if (heightCache.liquidity > 0) {
                        uint256 feeDistributedToHeight = FullMath.mulDiv(feeAmount, returnedAtHeight, amount);
                        feeAmount -= feeDistributedToHeight;
                        amount -= returnedAtHeight;
                        uint256 feeGrowthGlobalIncrement = FullMath.mulDiv(
                            feeDistributedToHeight,
                            Q128,
                            heightCache.liquidity
                        );
                        if (zeroForOne) {
                            heightCache.feeGrowthGlobalOf0X128 += feeGrowthGlobalIncrement;
                        } else {
                            heightCache.feeGrowthGlobalOf1X128 += feeGrowthGlobalIncrement;
                        }
                    }
                }
            }

            _updateHeightState(height, heightCache, zeroForOne, crossedHeights);
        }
    }

    /**
     * @notice Increases the height state to reflect added liquidity from swap output.
     *
     * @dev    Throws when insufficient liquidity to consume.
     *
     * @dev    Walks upward through height range, consuming capacity at each step. Distributes fee impact
     *         across intervals proportional to liquidity consumed. Crosses heights as needed.
     *
     * @param  height         Mutable height state.
     * @param  heightInfo     Height metadata mapping.
     * @param  heightMap      Linked list of height intervals.
     * @param  amount         Liquidity amount to add.
     * @param  feeAmount      Total fee to distribute across the added liquidity.
     * @param  zeroForOne     Direction of the swap.
     */
    function _increaseHeight(
        FixedHeightState storage height,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        mapping (uint256 => FixedHeightMap) storage heightMap,
        uint256 amount,
        uint256 feeAmount,
        bool zeroForOne
    ) internal {
        if (amount > 0) {
            unchecked {
                height.consumedLiquidity += amount;
            }
            FixedHeightState memory heightCache = height;
            uint256 remaining = amount;
            bool crossedHeights;
            while (remaining != 0) {
                if (
                    heightCache.currentHeight == heightCache.nextHeightAbove &&
                    heightCache.remainingAtHeight == 0
                ) {
                    // Cross height if we are at a height boundary
                    _crossHeight(heightCache, heightInfo, heightMap, true);
                    crossedHeights = true;
                }

                uint256 heightRemainingLiquidity = heightCache.remainingAtHeight;
                uint256 liquidityToNextHeight = 
                    (heightCache.nextHeightAbove - heightCache.currentHeight) * heightCache.liquidity - 
                    (heightCache.liquidity - heightRemainingLiquidity);
                uint256 consumedAtHeight;
                if (remaining >= liquidityToNextHeight) {
                    // Consume all liquidity to next height above, will cross height boundary
                    unchecked {
                        consumedAtHeight = liquidityToNextHeight;
                        remaining -= liquidityToNextHeight;
                        heightCache.currentHeight = heightCache.nextHeightAbove;
                        heightCache.remainingAtHeight = 0;
                    }
                } else {
                    consumedAtHeight = remaining;
                    if (remaining >= heightRemainingLiquidity) {
                        // Consume liquidity and move current height
                        remaining -= heightRemainingLiquidity;
                        uint256 heightToMove = remaining / heightCache.liquidity;
                        remaining -= heightToMove * heightCache.liquidity;
                        heightCache.remainingAtHeight = heightCache.liquidity - uint128(remaining);
                        heightCache.currentHeight += (heightToMove + 1);
                    } else {
                        // Consume liquidity within current height, remainingAtHeight will be > 0
                        heightCache.remainingAtHeight -= uint128(remaining);
                    }
                    remaining = 0;
                }

                // Distribute fees to height liquidity
                unchecked {
                    if (heightCache.liquidity > 0) {
                        uint256 feeDistributedToHeight = FullMath.mulDiv(feeAmount, consumedAtHeight, amount);
                        feeAmount -= feeDistributedToHeight;
                        amount -= consumedAtHeight;
                        uint256 feeGrowthGlobalIncrement = FullMath.mulDiv(
                            feeDistributedToHeight,
                            Q128,
                            heightCache.liquidity
                        );
                        if (zeroForOne) {
                            heightCache.feeGrowthGlobalOf0X128 += feeGrowthGlobalIncrement;
                        } else {
                            heightCache.feeGrowthGlobalOf1X128 += feeGrowthGlobalIncrement;
                        }
                    }
                }
            }

            if (heightCache.currentHeight == heightCache.nextHeightAbove && heightCache.remainingAtHeight == 0) {
                // Cross height if we are at a height boundary
                _crossHeight(heightCache, heightInfo, heightMap, true);
                crossedHeights = true;
            }

            _updateHeightState(height, heightCache, zeroForOne, crossedHeights);
        }
    }

    /**
     * @notice Updates the on-chain height state from its temporary working copy.
     *
     * @dev    Copies current height, remaining liquidity, fee growth, and optionally liquidity/linked heights
     *         if new height intervals were crossed.
     *
     * @param  height          The height slot to update.
     * @param  heightCache     Temporary height copy used during mutation.
     * @param  zeroForOne      Swap direction for selecting fee variable.
     * @param  crossedHeights  Whether new height intervals were crossed during execution.
     */
    function _updateHeightState(
        FixedHeightState storage height,
        FixedHeightState memory heightCache,
        bool zeroForOne,
        bool crossedHeights
    ) internal {
        height.currentHeight = heightCache.currentHeight;
        height.remainingAtHeight = heightCache.remainingAtHeight;
        if (zeroForOne) {
            height.feeGrowthGlobalOf0X128 = heightCache.feeGrowthGlobalOf0X128;
        } else {
            height.feeGrowthGlobalOf1X128 = heightCache.feeGrowthGlobalOf1X128;
        }
        if (crossedHeights) {
            height.liquidity = heightCache.liquidity;
            height.nextHeightBelow = heightCache.nextHeightBelow;
            height.nextHeightAbove = heightCache.nextHeightAbove;
        }
    }

    /**
     * @notice Transitions to the next active height level when the current one is exhausted.
     *
     * @dev    Throws when increasing is false and current height is 0 (no heights below).
     *
     * @dev    Adjusts the current height, liquidity, and fee growth based on height direction. Also updates
     *         the relevant metadata for tracking fee accumulation outside the active range.
     *
     * @param  heightCache   Mutable working copy of the height state.
     * @param  heightInfo    Mapping of height metadata.
     * @param  heightMap     Linked list of heights.
     * @param  increasing    True if walking upward (adding liquidity), false if downward (removing).
     */
    function _crossHeight(
        FixedHeightState memory heightCache,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        mapping (uint256 => FixedHeightMap) storage heightMap,
        bool increasing
    ) internal {
        unchecked {
            uint256 currentHeight = heightCache.currentHeight;
            if (increasing) {
                int128 newLiquidity = int128(heightCache.liquidity) + heightInfo[currentHeight].liquidityNet;
                if (newLiquidity < 0) {
                    revert FixedPool__UnderflowLiquidity();
                }
                heightCache.liquidity = uint128(newLiquidity);
                heightCache.nextHeightBelow = currentHeight;
                heightCache.nextHeightAbove = heightMap[currentHeight].nextHeightAbove;
                heightCache.remainingAtHeight = heightCache.liquidity;
            } else {
                if (currentHeight == 0) {
                    revert FixedPool__UnderflowCurrentHeight();
                }
                int128 newLiquidity = int128(heightCache.liquidity) - heightInfo[currentHeight].liquidityNet;
                if (newLiquidity < 0) {
                    revert FixedPool__UnderflowLiquidity();
                }
                heightCache.liquidity = uint128(newLiquidity);
                heightCache.nextHeightBelow = heightMap[currentHeight].nextHeightBelow;
                heightCache.nextHeightAbove = currentHeight;
                --heightCache.currentHeight;
                heightCache.remainingAtHeight = 0;
            }
            FixedHeightInfo storage specificHeightInfo = heightInfo[currentHeight];
            specificHeightInfo.feeGrowthOutside0X128 = 
                heightCache.feeGrowthGlobalOf0X128 - specificHeightInfo.feeGrowthOutside0X128;
            specificHeightInfo.feeGrowthOutside1X128 = 
                heightCache.feeGrowthGlobalOf1X128 - specificHeightInfo.feeGrowthOutside1X128;
        }
    }
}
