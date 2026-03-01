//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import "./Constants.sol";
import "./interfaces/IFixedPoolType.sol";
import "./libraries/FixedHelper.sol";

import "@limitbreak/lb-amm-core/src/DataTypes.sol";
import "@limitbreak/lb-amm-hooks-and-handlers/src/hooks/libraries/SqrtPriceCalculator.sol";

import "@limitbreak/tm-core-lib/src/utils/cryptography/EfficientHash.sol";
import "@limitbreak/tm-core-lib/src/utils/misc/StaticDelegateCall.sol";
import "@limitbreak/tm-core-lib/src/licenses/LicenseRef-PolyForm-Strict-1.0.0.sol";

/**
 * @title  FixedPoolType
 * @author Limit Break, Inc.
 * @notice Fixed Pool Type is a pool type for LimitBreakAMM that allows for the creation of
 *         token pools with a price that does not change and liquidity positions can be added
 *         asymmetrically to the pool using a liquidity height system. Position value change 
 *         and fee accrual occurs as swap flow moves through a position's heights.
 *
 * @dev    Handles creation, liquidity management, swaps, and fee collection for fixed price pools.
 */
contract FixedPoolType is IFixedPoolType, StaticDelegateCall {
    /// @dev The address of the AMM contract that manages this pool type.
    address private immutable AMM;

    /// @dev Mapping of pool identifiers to their state.
    /// @dev This stores the current price, liquidity, and other state variables for each fixed pool.
    mapping (bytes32 => FixedPoolState) private pools;

    /// @dev Mapping of position identifiers to their associated fixed position information.
    /// @dev This stores metadata about the position such as height ranges and fee growth checkpoints.
    mapping (bytes32 => FixedPositionInfo) private positions;

    constructor(address _amm) {
        AMM = _amm;
    }

    /**
     * @dev Modifier to restrict access to only the AMM contract.
     *
     * @dev    Throws when the msg.sender is not the AMM address.
     */
    modifier onlyAMM() {
        if (msg.sender != AMM) {
            revert FixedPool__OnlyAMM();
        }
        _;
    }

    /**
     * @notice Creates a new fixed pool with the specified parameters.
     *
     * @dev    Throws when either component of the packed ratio price is zero.
     * @dev    Throws when spacing0 or spacing1 is greater than MAX_HEIGHT_SPACING.
     *
     *         Decodes poolParams as FixedPoolCreationDetails, validates parameters, generates deterministic pool ID,
     *         and initializes pool state. Returns pool ID for AMM to manage corresponding reserves.
     *
     *         <h4>Postconditions</h4>
     *         1. The pool ID is generated using a hash of the provided parameters and storing the fee and spacings in the pool ID.
     *         2. The pool state is initialized: sqrtPriceX96 and packedRatio are set, all other fields are zero-initialized.
     *
     * @param  poolCreationDetails  Pool creation parameters (see FixedPoolCreationDetails).
     * @return poolId               The unique identifier for the created pool.
     */
    function createPool(
        PoolCreationDetails calldata poolCreationDetails
    ) external onlyAMM returns (bytes32 poolId) {
        FixedPoolCreationDetails memory fixedPoolDetails = abi.decode(poolCreationDetails.poolParams, (FixedPoolCreationDetails));

        fixedPoolDetails.packedRatio = FixedHelper.simplifyRatio(
            fixedPoolDetails.packedRatio
        );

        (uint256 ratio0, uint256 ratio1) = FixedHelper.unpackRatio(fixedPoolDetails.packedRatio, false);
        if (ratio0 == 0 || ratio1 == 0) {
            revert FixedPool__InvalidPackedRatio();
        }

        if (fixedPoolDetails.spacing0 > MAX_HEIGHT_SPACING || fixedPoolDetails.spacing1 > MAX_HEIGHT_SPACING) {
            revert FixedPool__InvalidHeightSpacing();
        }

        poolId = _generatePoolId(poolCreationDetails, fixedPoolDetails);

        pools[poolId].sqrtPriceX96 = SqrtPriceCalculator.computeRatioX96(
            ratio1,
            ratio0
        );
        pools[poolId].packedRatio = fixedPoolDetails.packedRatio;
    }

    /**
     * @notice Computes the deterministic pool ID that would be generated for given parameters.
     *
     * @dev    Decodes poolParams as FixedPoolCreationDetails and computes the pool ID using the same logic as createPool.
     *
     * @param  poolCreationDetails  Pool creation parameters (see FixedPoolCreationDetails).
     * @return poolId               Deterministic identifier that would be generated for these parameters.
     */
    function computePoolId(
        PoolCreationDetails calldata poolCreationDetails
    ) external view returns (bytes32 poolId) {
        FixedPoolCreationDetails memory fixedPoolDetails = abi.decode(poolCreationDetails.poolParams, (FixedPoolCreationDetails));

        fixedPoolDetails.packedRatio = FixedHelper.simplifyRatio(
            fixedPoolDetails.packedRatio
        );

        poolId = _generatePoolId(poolCreationDetails, fixedPoolDetails);
    }

    /**
     * @notice Generates deterministic pool ID from creation parameters with bit-packed data.
     *
     * @dev    Expects fixedPoolDetails to be properly decoded from poolCreationDetails.poolParams.
     *         Two-phase generation: First creates a hash from all parameters, then overlays bit-packed data for
     *         efficient parameter extraction.
     *         
     *         Hash includes all pool-defining parameters for uniqueness. Bit-packing enables
     *         parameter extraction without additional storage. Uses POOL_HASH_MASK to clear
     *         reserved bits before overlaying packed parameter data.
     *
     * @param  poolCreationDetails Standard pool creation parameters (tokens, fees, hook).
     * @param  fixedPoolDetails    Fixed-specific parameters (height spacings, initial price).
     * @return poolId              Deterministic pool identifier with extractable data.
     */
    function _generatePoolId(
        PoolCreationDetails calldata poolCreationDetails,
        FixedPoolCreationDetails memory fixedPoolDetails
    ) internal view returns (bytes32 poolId) {
        poolId = EfficientHash.efficientHash(
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(poolCreationDetails.fee)),
            bytes32(uint256(fixedPoolDetails.spacing0)),
            bytes32(uint256(fixedPoolDetails.spacing1)),
            bytes32(fixedPoolDetails.packedRatio),
            bytes32(uint256(uint160(poolCreationDetails.token0))),
            bytes32(uint256(uint160(poolCreationDetails.token1))),
            bytes32(uint256(uint160(poolCreationDetails.poolHook)))
        ) & POOL_HASH_MASK;

        poolId = poolId | 
            bytes32((uint256(uint160(address(this))) << POOL_ID_TYPE_ADDRESS_SHIFT)) |
            bytes32(uint256(poolCreationDetails.fee) << POOL_ID_FEE_SHIFT) | 
            bytes32(uint256(uint24(fixedPoolDetails.spacing0)) << POOL_ID_SPACING_SHIFT_ZERO) | 
            bytes32(uint256(uint24(fixedPoolDetails.spacing1)) << POOL_ID_SPACING_SHIFT_ONE);
    }

    /**
     * @notice Collects accrued fees from a fixed liquidity position without modifying liquidity.
     *
     * @dev    Calculates and collects fees based on position's height range and fee growth since last collection.
     *         Returns collected amounts for AMM to handle actual token transfers.
     *
     *         <h4>Postconditions</h4>
     *         1. The position's fee growth checkpoints are updated to the current pool fee growth.
     *         2. The collected fees are returned for transfer by the AMM.
     *
     * @param  poolId              Pool identifier for fee collection.
     * @param  ammBasePositionId   Base position identifier from AMM contract.
     * @return positionId          Deterministic position identifier.
     * @return fees0               Collected fees in token0.
     * @return fees1               Collected fees in token1.
     */
    function collectFees(
        bytes32 poolId,
        address,
        bytes32 ammBasePositionId,
        bytes calldata
    ) external onlyAMM returns (
        bytes32 positionId,
        uint256 fees0,
        uint256 fees1
    ) {
        positionId = ammBasePositionId;

        FixedPoolState storage ptrPoolState = pools[poolId];
        FixedPositionInfo storage position = positions[positionId];

        (fees0, fees1) = FixedHelper.collectFees(
            ptrPoolState,
            position
        );
    }

    /**
     * @notice Adds fixed liquidity to a position within specified height range.
     *
     * @dev    Decodes poolParams as FixedLiquidityModificationParams.
     *         Calculates required token amounts, updates height structures, collects accrued fees, and modifies 
     *         position state. Returns amounts for AMM to handle actual token transfers.
     *
     *         <h4>Postconditions</h4>
     *         1. The position's height ranges are updated with the new liquidity.
     *         2. The pool's height structures are updated with the new liquidity.
     *         3. A FixedPoolPositionUpdated event is emitted with the pool ID, position ID, and position heights.
     *
     * @param  poolId              Pool identifier for liquidity addition.
     * @param  ammBasePositionId   Base position identifier from AMM contract.
     * @param  poolParams          Encoded FixedLiquidityModificationParams.
     * @return positionId          Deterministic position identifier.
     * @return deposit0            Required amount of token0 for the liquidity addition.
     * @return deposit1            Required amount of token1 for the liquidity addition.
     * @return fees0               Accrued fees in token0 collected during operation.
     * @return fees1               Accrued fees in token1 collected during operation.
     */
    function addLiquidity(
        bytes32 poolId,
        address,
        bytes32 ammBasePositionId,
        bytes calldata poolParams
    ) external onlyAMM returns (
        bytes32 positionId,
        uint256 deposit0,
        uint256 deposit1,
        uint256 fees0,
        uint256 fees1
    ) {
        FixedLiquidityModificationParams memory liquidityParams = abi.decode(poolParams, (FixedLiquidityModificationParams));

        positionId = ammBasePositionId;

        FixedPoolState storage ptrPoolState = pools[poolId];
        FixedPositionInfo storage position = positions[positionId];

        (deposit0, deposit1, fees0, fees1) = FixedHelper.depositLiquidity(
            poolId,
            liquidityParams,
            ptrPoolState,
            position
        );

        emit FixedPoolPositionUpdated(poolId, positionId, position.startHeight0, position.endHeight0, position.startHeight1, position.endHeight1);
    }

    /**
     * @notice Removes fixed liquidity from a position and re-adds the remaining liquidity.
     *
     * @dev    Decodes poolParams as FixedLiquidityWithdrawalParams.
     *         Calculates token amounts to withdraw, updates height structures, collects accrued fees, and modifies 
     *         position state. Returns amounts for AMM to handle actual token transfers.
     *         Dust amounts of reserves will be swept into withdrawals.
     *
     *         <h4>Postconditions</h4>
     *         1. The position's height ranges are updated with the removed liquidity.
     *         2. The pool's height structures are updated with the removed liquidity.
     *         3. A FixedPoolPositionUpdated event is emitted with the pool ID, position ID, and position heights.
     *
     * @param  poolId              Pool identifier for liquidity removal.
     * @param  ammBasePositionId   Base position identifier from AMM contract.
     * @param  poolParams          Encoded FixedLiquidityWithdrawalParams.
     * @return positionId          Deterministic position identifier.
     * @return withdraw0           Amount of token0 to withdraw from the position.
     * @return withdraw1           Amount of token1 to withdraw from the position.
     * @return fees0               Accrued fees in token0 collected during operation.
     * @return fees1               Accrued fees in token1 collected during operation.
     */
    function removeLiquidity(
        bytes32 poolId,
        address,
        bytes32 ammBasePositionId,
        bytes calldata poolParams
    ) external onlyAMM returns (
        bytes32 positionId,
        uint256 withdraw0,
        uint256 withdraw1,
        uint256 fees0,
        uint256 fees1
    ) {
        positionId = ammBasePositionId;

        FixedPoolState storage ptrPoolState = pools[poolId];
        FixedPositionInfo storage position = positions[positionId];

        FixedLiquidityWithdrawalParams memory withdrawalParams = abi.decode(poolParams, (FixedLiquidityWithdrawalParams));
        if (withdrawalParams.withdrawAll) {
            FixedLiquidityWithdrawAllParams memory withdrawAllParams = abi.decode(withdrawalParams.params, (FixedLiquidityWithdrawAllParams));

            (withdraw0, withdraw1, fees0, fees1) = FixedHelper.withdrawAll(
                withdrawAllParams,
                ptrPoolState,
                position
            );
        } else {
            FixedLiquidityModificationParams memory liquidityParams = abi.decode(withdrawalParams.params, (FixedLiquidityModificationParams));

            (withdraw0, withdraw1, fees0, fees1) = FixedHelper.withdrawLiquidity(
                poolId,
                liquidityParams,
                ptrPoolState,
                position
            );
        }

        emit FixedPoolPositionUpdated(poolId, positionId, position.startHeight0, position.endHeight0, position.startHeight1, position.endHeight1);
    }

    /**
     * @notice Executes an input-based swap consuming up to the specified input for the calculated output.
     *
     * @dev    Performs a fixed price swap using current pool price. Returns output amount, total fees, and protocol fees.
     *
     * @dev    Throws when poolFeeBPS > MAX_BPS.
     *         Throws when protocolFeeBPS > MAX_BPS.
     * 
     *         <h4>Postconditions</h4>
     *         1. The pool's height structures are updated with the new price after the swap.
     *         2. The amount of output tokens received from the swap as well as the fees are returned.
     *         3. A FixedPoolHeightConsumed event is emitted with the pool ID, swap direction, and updated heights.
     *
     * @param  poolId              Pool identifier for swap execution.
     * @param  zeroForOne          Swap direction: true for token0→token1, false for token1→token0.
     * @param  amountIn            Input amount to consume during swap.
     * @param  poolFeeBPS          Pool fee rate in basis points.
     * @param  protocolFeeBPS      Protocol fee rate in basis points.
     * 
     * @return actualAmountIn      Input amount adjusted for partial fill.
     * @return amountOut           Output amount received from the swap.
     * @return feeOfAmountIn       Total fees charged on the input amount.
     * @return protocolFees        Protocol fees collected during the swap.
     */
    function swapByInput(
        SwapContext calldata,
        bytes32 poolId,
        bool zeroForOne,
        uint256 amountIn,
        uint256 poolFeeBPS,
        uint256 protocolFeeBPS,
        bytes calldata
    ) external onlyAMM returns (
        uint256 actualAmountIn,
        uint256 amountOut,
        uint256 feeOfAmountIn,
        uint256 protocolFees
    ) {
        if (poolFeeBPS > MAX_BPS || protocolFeeBPS > MAX_BPS) {
            revert FixedPool__InvalidFeeBPS();
        }

        FixedPoolState storage ptrPoolState = pools[poolId];

        FixedSwapCache memory swapCache = FixedSwapCache({
            swapByInput: true,
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOut: 0,
            poolFeeBPS: uint16(poolFeeBPS),
            protocolFeeBPS: uint16(protocolFeeBPS),
            protocolFee: 0,
            lpFeeAmount: 0,
            packedRatio: ptrPoolState.packedRatio,
            inputShareOfExpectedReserve: 0,
            outputShareOfExpectedReserve: 0,
            expectedReserve: 0,
            consumedLiquidityInputHeight: 0,
            consumedLiquidityOutputHeight: 0,
            outputHeightInputShare: 0
        });

        FixedHelper.updateExpectedReserve(ptrPoolState, swapCache);

        FixedHelper.swapByInput(ptrPoolState, swapCache);

        actualAmountIn = swapCache.amountIn;
        amountOut = swapCache.amountOut;
        feeOfAmountIn = swapCache.lpFeeAmount;
        protocolFees = swapCache.protocolFee;

        emit FixedPoolHeightConsumed(poolId, zeroForOne, ptrPoolState.height0.currentHeight, ptrPoolState.height1.currentHeight);
    }

    /**
     * @notice Executes an output-based swap consuming the required input amount for the specified output.
     *
     * @dev    Performs a fixed price swap using current pool price. Returns input amount, total fees, and protocol fees.
     *
     * @dev    Throws when poolFeeBPS >= MAX_BPS.
     * @dev    Throws when protocolFeeBPS > MAX_BPS.
     * 
     *         <h4>Postconditions</h4>
     *         1. The pool's height structures are updated with the new price after the swap.
     *         2. The amount of input tokens required to produce the output as well as the fees are returned.
     *         3. A FixedPoolHeightConsumed event is emitted with the pool ID, swap direction, and updated heights.
     *
     * @param  poolId              Pool identifier for swap execution.
     * @param  zeroForOne          Swap direction: true for token0→token1, false for token1→token0.
     * @param  amountOut           Output amount to produce during swap.
     * @param  poolFeeBPS          Pool fee rate in basis points.
     * @param  protocolFeeBPS      Protocol fee rate in basis points.
     * 
     * @return actualAmountOut     Output amount adjusted for partial fill.
     * @return amountIn            Input amount consumed during the swap.
     * @return feeOfAmountIn       Total fees charged on the input amount.
     * @return protocolFees        Protocol fees collected during the swap.
     */
    function swapByOutput(
        SwapContext calldata,
        bytes32 poolId,
        bool zeroForOne,
        uint256 amountOut,
        uint256 poolFeeBPS,
        uint256 protocolFeeBPS,
        bytes calldata
    ) external onlyAMM returns (
        uint256 actualAmountOut,
        uint256 amountIn,
        uint256 feeOfAmountIn,
        uint256 protocolFees
    ) {
        if (poolFeeBPS >= MAX_BPS || protocolFeeBPS > MAX_BPS) {
            revert FixedPool__InvalidFeeBPS();
        }

        FixedPoolState storage ptrPoolState = pools[poolId];

        FixedSwapCache memory swapCache = FixedSwapCache({
            swapByInput: false,
            zeroForOne: zeroForOne,
            amountIn: 0,
            amountOut: amountOut,
            poolFeeBPS: uint16(poolFeeBPS),
            protocolFeeBPS: uint16(protocolFeeBPS),
            protocolFee: 0,
            lpFeeAmount: 0,
            packedRatio: ptrPoolState.packedRatio,
            inputShareOfExpectedReserve: 0,
            outputShareOfExpectedReserve: 0,
            expectedReserve: 0,
            consumedLiquidityInputHeight: 0,
            consumedLiquidityOutputHeight: 0,
            outputHeightInputShare: 0
        });

        FixedHelper.updateExpectedReserve(ptrPoolState, swapCache);

        FixedHelper.swapByOutput(ptrPoolState, swapCache);

        actualAmountOut = swapCache.amountOut;
        amountIn = swapCache.amountIn;
        feeOfAmountIn = swapCache.lpFeeAmount;
        protocolFees = swapCache.protocolFee;

        emit FixedPoolHeightConsumed(poolId, zeroForOne, ptrPoolState.height0.currentHeight, ptrPoolState.height1.currentHeight);
    }

    /**
     * @notice Returns the current square root price for a specific pool.
     *
     * @dev    View function that retrieves the current sqrtPriceX96 from pool state.
     *         Returns 0 if pool does not exist.
     *
     * @param  poolId              Pool identifier to query.
     * @return sqrtPriceX96        Current square root price in Q64.96 fixed-point format.
     */
    function getCurrentPriceX96(
        address,
        bytes32 poolId
    ) external view returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = pools[poolId].sqrtPriceX96;
    }

    /**
     * @notice Retrieves the current state of a fixed pool.
     *
     * @dev    Returns the complete pool state including reserves, pricing, and position tracking
     *         information for constant product pools.
     *
     * @param  poolId The pool identifier.
     * @return state  The complete fixed pool state.
     */
    function getFixedPoolState(bytes32 poolId) external view returns (FixedPoolStateView memory state) {
        FixedPoolState storage ptrFixedPool = pools[poolId];
        state = FixedPoolStateView({
            sqrtPriceX96: ptrFixedPool.sqrtPriceX96,
            packedRatio: ptrFixedPool.packedRatio,
            position0ShareOf0: ptrFixedPool.position0ShareOf0,
            position1ShareOf1: ptrFixedPool.position1ShareOf1,
            currentHeight0: ptrFixedPool.height0.currentHeight,
            currentHeight1: ptrFixedPool.height1.currentHeight,
            consumedLiquidity0: ptrFixedPool.height0.consumedLiquidity,
            consumedLiquidity1: ptrFixedPool.height1.consumedLiquidity,
            liquidity0: ptrFixedPool.height0.liquidity,
            liquidity1: ptrFixedPool.height1.liquidity,
            remainingAtHeight0: ptrFixedPool.height0.remainingAtHeight,
            remainingAtHeight1: ptrFixedPool.height1.remainingAtHeight,
            dust0: ptrFixedPool.dust0,
            dust1: ptrFixedPool.dust1
        });
    }

    /**
     * @notice Returns the position information for a given position ID.
     *
     * @dev    View function that retrieves the FixedPositionInfo for the specified positionId.
     *         Returns an empty position info if the position does not exist.
     *
     * @param  positionId   Position identifier to query.
     * @return positionInfo The complete position information.
     */
    function getPositionInfo(bytes32 positionId) external view returns (FixedPositionInfo memory positionInfo) {
        positionInfo = positions[positionId];
    }

    /**
     * @notice  Returns the fixed height state for a pool and side.
     * 
     * @dev     View function that retrieves the FixedHeightState for the specified poolId and side.
     * 
     * @param poolId  Pool identifier to query.
     * @param side0   True if getting height state for token0.
     */
    function getFixedHeightState(bytes32 poolId, bool side0) external view returns (FixedHeightState memory heightState) {
        FixedPoolState storage ptrFixedPool = pools[poolId];
        if (side0) {
            heightState = ptrFixedPool.height0;
        } else {
            heightState = ptrFixedPool.height1;
        }
    }

    /**
     * @notice  Returns the manifest URI for the pool type to provide app integrations with
     *          information necessary to process transactions that utilize the pool type.
     * 
     * @dev     Hook developers **MUST** emit a `PoolTypeManifestUriUpdated` event if the URI
     *          changes.
     * 
     * @return  manifestUri  The URI for the hook manifest data. 
     */
    function poolTypeManifestUri() external pure returns(string memory manifestUri) {
        manifestUri = ""; //TODO: Before final deploy, create permalink for FixedPoolType manifest
    }
}
