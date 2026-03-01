//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity ^0.8.24;

/// @dev Max BPS value used in BIPS and fee calculations.
uint256 constant MAX_BPS = 100_00;

/// @dev Q128 fixed-point arithmetic constant (2^128) for high-precision calculations.
uint256 constant Q128 = 2 ** 128;

/// @dev Q96 fixed-point arithmetic constant (2^96) for sqrt price representations.
uint256 constant Q96 = 2 ** 96;

/// @dev Base ratio for fixed price conversion to ratios.
uint128 constant RATIO_BASE = 10**38;

/// @dev Mask for extracting spacing precision values from packed data.
uint24 constant SPACING_PRECISION_BIT_MASK = 0xFF;

/// @dev Bit shift position for extracting token0 spacing precision from packed data.
uint8 constant SPACING_PRECISION_SHIFT_FOR_ZERO = 8;

/// @dev Height spacing is capped at a maximum of 24 to avoid excessive height jumps before liquidity becomes active.
uint8 constant MAX_HEIGHT_SPACING = 24;

/// @dev Bit shift position for pool type address in poolId.
uint8 constant POOL_ID_TYPE_ADDRESS_SHIFT = 144;

/// @dev Bit mask for the creation details hash in poolId.
bytes32 constant POOL_HASH_MASK = 0x0000000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF000000000000;

/// @dev Bit shift position for packing pool fee rate in poolId.
uint8 constant POOL_ID_FEE_SHIFT = 0;

/// @dev Bit shift position for packing token0 height spacing in poolId.
uint8 constant POOL_ID_SPACING_SHIFT_ZERO = 24;

/// @dev Bit shift position for packing token1 height spacing in poolId.
uint8 constant POOL_ID_SPACING_SHIFT_ONE = 16;