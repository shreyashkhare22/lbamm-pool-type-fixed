//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import "../Constants.sol";

/**
 * @title  FixedPoolDecoder
 * @author Limit Break, Inc.
 * @notice Provides utilities for extracting encoded data from pool identifiers in fixed pool types.
 *
 * @dev    This library decodes fee rate and height precision values that are packed into the 32-byte pool ID.
 */
library FixedPoolDecoder {
    /**
     * @notice Extracts the fee rate from a packed pool identifier.
     *
     * @dev    The fee is stored in the upper bits of the pool ID and is extracted using a right bit shift
     *         operation (POOL_ID_FEE_SHIFT). The fee is encoded as a uint16 value representing 
     *         basis points (BPS) where 10000 BPS equals 100%.
     *
     *         Valid fee range: 0-10000 BPS (0-100%).
     *
     * @param  poolId The 32-byte pool identifier containing the packed fee information.
     * @return fee    The fee rate in basis points extracted from the pool ID.
     */
    function getPoolFee(bytes32 poolId) internal pure returns (uint16 fee) {
        fee = uint16(uint256(poolId) >> POOL_ID_FEE_SHIFT);
    }

    /**
     * @notice Extracts height spacing precision from a packed pool identifier for fixed pools.
     * 
     * @dev    The spacing is stored in the pool ID and is extracted using bit shift and mask operations.
     *         Uses assembly to compute 10^spacing for the specified token side. The precision determines
     *         the granularity of height intervals in fixed liquidity pools and affects how liquidity
     *         ranges are rounded and allocated.
     *
     * @param  poolId    The 32-byte pool identifier containing the packed spacing information.
     * @param  sideZero  True for token0 side precision, false for token1 side precision.
     * @return precision Height spacing precision as 10^spacing used for rounding liquidity ranges.
     */
    function getPoolHeightPrecision(bytes32 poolId, bool sideZero) internal pure returns (uint256 precision) {
        uint256 _spacing = uint256(poolId) >> POOL_ID_SPACING_SHIFT_ONE;
        assembly ("memory-safe") {
            precision := exp(
                10,
                and(
                    SPACING_PRECISION_BIT_MASK, 
                    shr(mul(sideZero, SPACING_PRECISION_SHIFT_FOR_ZERO), _spacing)
                )
            )
        }
    }
}
