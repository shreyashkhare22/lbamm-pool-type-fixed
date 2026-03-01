//SPDX-License-Identifier: LicenseRef-PolyForm-Strict-1.0.0
pragma solidity 0.8.24;

import "../DataTypes.sol";
import "@limitbreak/lb-amm-core/src/interfaces/ILimitBreakAMMPoolType.sol";

/**
 * @title  IFixedPoolType
 * @author Limit Break, Inc.
 * @notice Interface definition for fixed pool functions and events.
 */
interface IFixedPoolType is ILimitBreakAMMPoolType {
    /// @dev Event emitted when a position is updated in a fixed pool
    event FixedPoolPositionUpdated(
        bytes32 indexed poolId,
        bytes32 indexed positionId,
        uint256 startHeight0,
        uint256 endHeight0,
        uint256 startHeight1,
        uint256 endHeight1
    );

    /// @dev Event emitted when height is consumed in a fixed pool during a swap
    event FixedPoolHeightConsumed(
        bytes32 indexed poolId,
        bool indexed zeroForOne,
        uint256 currentHeight0,
        uint256 currentHeight1
    );

    /**
     * @notice Retrieves the current state of a fixed pool.
     *
     * @dev    Returns the complete pool state including reserves, pricing, and position tracking
     *         information for constant product pools.
     *
     * @param  poolId The pool identifier.
     * @return state  The complete fixed pool state.
     */
    function getFixedPoolState(bytes32 poolId) external view returns (FixedPoolStateView memory state);

    /**
     * @notice Returns the position information for a given position ID.
     *
     * @dev    View function that retrieves the FixedPositionInfo for the specified positionId.
     *         Returns an empty position info if the position does not exist.
     *
     * @param  positionId   Position identifier to query.
     * @return positionInfo The complete position information.
     */
    function getPositionInfo(bytes32 positionId) external view returns (FixedPositionInfo memory positionInfo);

    /**
     * @notice  Returns the fixed height state for a pool and side.
     * 
     * @dev     View function that retrieves the FixedHeightState for the specified poolId and side.
     * 
     * @param poolId  Pool identifier to query.
     * @param side0   True if getting height state for token0.
     */
    function getFixedHeightState(bytes32 poolId, bool side0) external view returns (FixedHeightState memory heightState);
}
