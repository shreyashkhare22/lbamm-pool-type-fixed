//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import "./Constants.sol";
import "./libraries/FixedHelper.sol";
import "./libraries/FixedPoolDecoder.sol";

import "@limitbreak/lb-amm-core/src/DataTypes.sol";
import "@limitbreak/lb-amm-core/src/interfaces/ILimitBreakAMM.sol";

import "@limitbreak/tm-core-lib/src/utils/cryptography/EfficientHash.sol";
import "@limitbreak/tm-core-lib/src/utils/misc/StaticDelegateCall.sol";
import "@limitbreak/tm-core-lib/src/licenses/LicenseRef-PolyForm-Strict-1.0.0.sol";

/**
 * @title  FixedPoolQuoter
 * @author Limit Break, Inc.
 * @notice Fixed Pool Quoter utilizes static delegate calls through FixedPoolType to perform calculations
 *         using state data from the FixedPoolType contract.
 */
contract FixedPoolQuoter {
    /// @dev The address of the AMM contract that manages this pool type.
    address private immutable AMM;

    /// @dev The address of the fixed pool type contract that quotes will be calculated from.
    address private immutable FIXED_POOL_TYPE;

    // Match storage layout with FixedPoolType for static delegatecalls.

    /// @dev Mapping of pool identifiers to their state.
    /// @dev This stores the current price, liquidity, and other state variables for each fixed pool.
    mapping (bytes32 => FixedPoolState) private pools;

    /// @dev Mapping of position identifiers to their associated fixed position information.
    /// @dev This stores metadata about the position such as height ranges and fee growth checkpoints.
    mapping (bytes32 => FixedPositionInfo) private positions;

    constructor(address _amm, address _fixedPoolType) {
        AMM = _amm;
        FIXED_POOL_TYPE = _fixedPoolType;
    }

    ///////////////////////////////////////////////////////
    //                  QUOTING FUNCTIONS                //
    ///////////////////////////////////////////////////////

    /**
     * @notice  Calculates the amount of tokens to add liquidity in range.
     * 
     * @param  poolId   Pool identifier for liquidity addition.
     * 
     * @return amount0  Amount of token0 required to add token1 liquidity in range.
     * @return amount1  Amount of token1 required to add token0 liquidity in range.
     */
    function quoteValueRequiredForInRangeAdd(bytes32 poolId) external view returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = abi.decode(
            StaticDelegateCall(FIXED_POOL_TYPE).initiateStaticDelegateCall(
                address(this),
                abi.encodeWithSelector(
                    this.processQuoteValueRequiredForInRangeAdd.selector,
                    poolId
                )
            ),
            (uint256, uint256)
        );
    }

    /**
     * @notice  Calculates the current value and fee accrual for a position.
     * 
     * @param  poolId      Pool identifier for liquidity addition.
     * @param  positionId  Position identifier for the position to get the value of.
     * 
     * @return value0  Principal token0 value of the position.
     * @return value1  Principal token1 value of the position.
     * @return fee0    Accrued fees in token0.
     * @return fee1    Accrued fees in token1.
     */
    function quotePositionValue(
        bytes32 poolId,
        bytes32 positionId
    ) external view returns (uint256 value0, uint256 value1, uint256 fee0, uint256 fee1) {
        (value0, value1, fee0, fee1) = abi.decode(
            StaticDelegateCall(FIXED_POOL_TYPE).initiateStaticDelegateCall(
                address(this),
                abi.encodeWithSelector(
                    this.processQuotePositionValue.selector,
                    poolId,
                    positionId
                )
            ),
            (uint256, uint256, uint256, uint256)
        );
    }

    ///////////////////////////////////////////////////////
    //                PROCESSING FUNCTIONS               //
    ///////////////////////////////////////////////////////

    /**
     * @notice  This function is to be delegate called by the FixedPoolType contract. Use `quoteValueRequiredForInRangeAdd`
     *          for external calls to the quoter contract.
     * 
     * @param  poolId   Pool identifier for liquidity addition.
     * 
     * @return amount0  Amount of token0 required to add token1 liquidity in range.
     * @return amount1  Amount of token1 required to add token0 liquidity in range.
     */
    function processQuoteValueRequiredForInRangeAdd(bytes32 poolId) external view returns (uint256 amount0, uint256 amount1) {
        FixedPoolState storage ptrPoolState = pools[poolId];

        uint256 precision0 = FixedPoolDecoder.getPoolHeightPrecision(poolId, true);
        uint256 inRangeDepth0 = ptrPoolState.height0.currentHeight % precision0;
        if (inRangeDepth0 != 0) {
            uint256 consumedLiquidity0 = ptrPoolState.height0.consumedLiquidity;
            amount0 = precision0 - inRangeDepth0;
            amount1 = 
                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity0 + inRangeDepth0, ptrPoolState.packedRatio, true) - 
                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity0, ptrPoolState.packedRatio, true);
        }

        uint256 precision1 = FixedPoolDecoder.getPoolHeightPrecision(poolId, false);
        uint256 inRangeDepth1 = ptrPoolState.height1.currentHeight % precision1;
        if (inRangeDepth1 != 0) {
            uint256 consumedLiquidity1 = ptrPoolState.height1.consumedLiquidity;
            amount1 += precision1 - inRangeDepth1;
            amount0 += 
                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity1 + inRangeDepth1, ptrPoolState.packedRatio, false) - 
                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity1, ptrPoolState.packedRatio, false);
        }
    }

    /**
     * @notice  This function is to be delegate called by the FixedPoolType contract. Use `quotePositionValue`
     *          for external calls to the quoter contract.
     * 
     * @param  poolId      Pool identifier for liquidity addition.
     * @param  positionId  Position identifier for the position to get the value of.
     * 
     * @return value0  Principal token0 value of the position.
     * @return value1  Principal token1 value of the position.
     * @return fee0    Accrued fees in token0.
     * @return fee1    Accrued fees in token1.
     */
    function processQuotePositionValue(
        bytes32 poolId,
        bytes32 positionId
    ) external view returns (uint256 value0, uint256 value1, uint256 fee0, uint256 fee1) {
        FixedPoolState storage ptrPoolState = pools[poolId];
        FixedPositionInfo storage position = positions[positionId];

        (value0, value1, fee0, fee1) = _calculatePosition(ptrPoolState, position);
    }

    ///////////////////////////////////////////////////////
    //                 INTERNAL FUNCTIONS                //
    ///////////////////////////////////////////////////////

    /**
     * @notice Calculates the value of liquidity and fees in a position.
     *
     * @dev    Iterates over both token sides and calculates accrued value and fees using fee growth and height state.
     * @dev    Mirrors logic of FixedHelper `_collectPosition` without state changes.
     * 
     * @param  ptrPoolState  The current fixed pool state.
     * @param  position      The liquidity position being calculated.
     * @return value0        Principal token0 value of the position.
     * @return value1        Principal token1 value of the position.
     * @return fee0          Accrued fees in token0.
     * @return fee1          Accrued fees in token1.
     */
    function _calculatePosition(
        FixedPoolState storage ptrPoolState,
        FixedPositionInfo storage position
    ) internal view returns (uint256 value0, uint256 value1, uint256 fee0, uint256 fee1) {
        // fee0, fee1, value0, value1 capture the side0 values initially
        // then are aggregated with side1 values for gas optimization
        // and stack management
        (
            value0,
            value1,
            fee0,
            fee1
        ) = _calculatePositionSide(
            ptrPoolState,
            ptrPoolState.heightInfo0,
            ptrPoolState.height0,
            position.startHeight0,
            position.endHeight0,
            position.feeGrowthInside0Of0LastX128,
            position.feeGrowthInside1Of0LastX128,
            true
        );

        {
            FixedPositionInfo storage positionCache = position;
            (
                uint256 side1Value0,
                uint256 side1Value1,
                uint256 side1Fee0,
                uint256 side1Fee1
            ) = _calculatePositionSide(
                ptrPoolState,
                ptrPoolState.heightInfo1,
                ptrPoolState.height1,
                positionCache.startHeight1,
                positionCache.endHeight1,
                positionCache.feeGrowthInside0Of1LastX128,
                positionCache.feeGrowthInside1Of1LastX128,
                false
            );

            fee0 = fee0 + side1Fee0;
            fee1 = fee1 + side1Fee1;

            value0 = value0 + side1Value0;
            value1 = value1 + side1Value1;
        }
    }

    /**
     * @notice Calculates the value and fees for one token side of a liquidity position.
     *
     * @dev    Computes consumed and unconsumed liquidity amounts based on current and stored heights 
     *         to calculate value and fee growth for one side of a position.
     * @dev    Mirrors logic of FixedHelper `_collectPositionSide` without state changes.
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
    function _calculatePositionSide(
        FixedPoolState storage ptrPoolState,
        mapping (uint256 => FixedHeightInfo) storage heightInfo,
        FixedHeightState storage height,
        uint256 startHeight,
        uint256 endHeight,
        uint256 feeGrowthInside0LastX128,
        uint256 feeGrowthInside1LastX128,
        bool sideZero
    ) internal view returns (
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
                                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity, packedRatio, sideZero) - 
                                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity - (liquidity - sideValue), packedRatio, sideZero);
                        } else {
                            uint256 consumedLiquidity = height.consumedLiquidity;
                            pairValue = 
                                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity, packedRatio, sideZero) - 
                                FixedHelper.calculateFixedSwapByRatioRoundingDown(consumedLiquidity - liquidity, packedRatio, sideZero);
                        }
                    }

                    if (sideZero) {
                        value0 = sideValue;
                        value1 = pairValue;
                    } else {
                        value0 = pairValue;
                        value1 = sideValue;
                    }
                }
                {
                    (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = FixedHelper.getFeeGrowthInside(
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
            }
        }
    }
}