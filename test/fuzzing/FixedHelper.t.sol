pragma solidity 0.8.24;

import "@limitbreak/tm-core-lib/src/utils/cryptography/EfficientHash.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../src/DataTypes.sol";
import "../../src/Errors.sol";
import {FixedHelper} from "../../src/libraries/FixedHelper.sol";
import "@limitbreak/lb-amm-core/src/DataTypes.sol";

contract FixedHelperTest is Test {
    using FixedHelper for *;

    mapping(bytes32 => FixedPoolState) private pools;
    mapping(bytes32 => FixedPositionInfo) private positions;

    mapping(uint256 => FixedHeightMap) private expectedHeightMap0;
    mapping(uint256 => FixedHeightMap) private expectedHeightMap1;

    bytes32[] private trackedPositionKeys;
    mapping(bytes32 => bool) private isPositionSide0Tracked;
    mapping(bytes32 => bool) private isPositionSide1Tracked;

    bytes32 testPoolId0;
    uint160 constant Q96 = 2 ** 96;

    function setUp() public {
        testPoolId0 = _generateMockPoolId(1, 1, Q96);
        FixedPoolState storage pool = pools[testPoolId0];
        pool.sqrtPriceX96 = uint160(Q96);
        pool.packedRatio = FixedHelper.normalizePriceToRatio(Q96);
    }

    ////////////////
    /// Basic Tests
    ////////////////

    function test_depositLiquidity_basic() public {
        // Arrange: Set up liquidity parameters
        FixedLiquidityModificationParams memory liquidityParams = FixedLiquidityModificationParams({
            amount0: 1000,
            amount1: 2000,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position0")];
        ModifyFixedLiquidityCache memory liquidityCache;

        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, liquidityParams, poolState, position);

        _updatedExpectedHeightMaps(liquidityParams, bytes32("position0"), true);

        // Basic assertions
        assertEq(deposit0, 1000, "deposit0 should equal amount0 for new position");
        assertEq(deposit1, 2000, "deposit1 should equal amount1 for new position");

        // Verify pool state was updated
        assertEq(poolState.position0ShareOf0, 1000, "position0ShareOf0 should be updated");
        assertEq(poolState.position1ShareOf1, 2000, "position1ShareOf1 should be updated");

        // Verify position was created with correct height ranges
        assertEq(position.startHeight0, 0, "startHeight0 should be 0 for current height 0");
        assertEq(position.endHeight0, 1000, "endHeight0 should be startHeight0 + amount0");
        assertEq(position.startHeight1, 0, "startHeight1 should be 0 for current height 0");
        assertEq(position.endHeight1, 2000, "endHeight1 should be startHeight1 + amount1");

        // Verify height states were updated
        assertEq(poolState.height0.liquidity, 1, "height0 liquidity should be incremented");
        assertEq(poolState.height0.remainingAtHeight, 1, "height0 remainingAtHeight should be incremented");
        assertEq(poolState.height1.liquidity, 1, "height1 liquidity should be incremented");
        assertEq(poolState.height1.remainingAtHeight, 1, "height1 remainingAtHeight should be incremented");
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositLiquidity_withPrecisionRounding() public {
        // Test with amounts that need precision rounding
        FixedLiquidityModificationParams memory liquidityParams = FixedLiquidityModificationParams({
            amount0: 1005, // Should round down to 1000 with precision 10
            amount1: 2003, // Should round down to 2000 with precision 10
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position0")];
        ModifyFixedLiquidityCache memory liquidityCache;

        // Act
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, liquidityParams, poolState, position);

        _updatedExpectedHeightMaps(liquidityParams, bytes32("position0"), true);

        // Assert: Amounts should be rounded down to precision
        assertEq(deposit0, 1000, "deposit0 should be rounded down to precision");
        assertEq(deposit1, 2000, "deposit1 should be rounded down to precision");

        // Verify position heights reflect the rounded amounts
        assertEq(position.endHeight0, 1000, "endHeight0 should use rounded amount");
        assertEq(position.endHeight1, 2000, "endHeight1 should use rounded amount");

        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositLiquidity_zeroAmounts() public {
        // Test depositing zero amounts
        FixedLiquidityModificationParams memory liquidityParams = FixedLiquidityModificationParams({
            amount0: 0,
            amount1: 0,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position0")];
        ModifyFixedLiquidityCache memory liquidityCache;

        // Act
        vm.expectRevert(FixedPool__BothTokenAmountsZeroOnDeposit.selector);
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, liquidityParams, poolState, position);

        assertEq(deposit0, 0, "deposit0 should be 0");
        assertEq(deposit1, 0, "deposit1 should be 0");

        assertEq(position.startHeight0, position.endHeight0, "No height range should be created for token0");
        assertEq(position.startHeight1, position.endHeight1, "No height range should be created for token1");

        assertEq(poolState.position0ShareOf0, 0, "position0ShareOf0 should remain 0");
        assertEq(poolState.position1ShareOf1, 0, "position1ShareOf1 should remain 0");
    }

    function test_depositLiquidity_addToExistingPosition() public {
        // First, create an initial position
        test_depositLiquidity_basic();

        // Now add more liquidity to the existing position
        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 500,
            amount1: 800,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position0")];
        ModifyFixedLiquidityCache memory liquidityCache;

        // Store initial state for comparison
        uint128 initialPosition0Share = poolState.position0ShareOf0;
        uint128 initialPosition1Share = poolState.position1ShareOf1;

        // Act: Add more liquidity
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position0"), true);

        // Assert: New deposits should equal the additional amounts
        assertEq(deposit0, 500, "Additional deposit0 should equal amount0");
        assertEq(deposit1, 800, "Additional deposit1 should equal amount1");

        // Pool shares should be increased by the new amounts
        assertEq(poolState.position0ShareOf0, initialPosition0Share + 500, "position0ShareOf0 should increase");
        assertEq(poolState.position1ShareOf1, initialPosition1Share + 800, "position1ShareOf1 should increase");

        // Position height ranges should be updated to include new liquidity
        assertEq(position.endHeight0, 1500, "endHeight0 should include new liquidity");
        assertEq(position.endHeight1, 2800, "endHeight1 should include new liquidity");
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositLiquidity_addOnTopOfExistingPositionHeights() public {
        // First, create an initial position
        test_depositLiquidity_basic();

        // Now add more liquidity to the existing position
        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 1000,
            amount1: 2000,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position1")];
        ModifyFixedLiquidityCache memory liquidityCache;

        FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), true);

        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositLiquidity_multiplePositions() public {
        test_depositLiquidity_basic();

        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 500,
            amount1: 800,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position1")];

        uint128 initialPosition0Share = poolState.position0ShareOf0;
        uint128 initialPosition1Share = poolState.position1ShareOf1;

        ModifyFixedLiquidityCache memory liquidityCache;
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), true);

        assertEq(deposit0, 500, "Additional deposit0 should equal amount0");
        assertEq(deposit1, 800, "Additional deposit1 should equal amount1");

        assertEq(poolState.position0ShareOf0, initialPosition0Share + 500, "position0ShareOf0 should increase");
        assertEq(poolState.position1ShareOf1, initialPosition1Share + 800, "position1ShareOf1 should increase");

        assertEq(position.endHeight0, 500, "endHeight0 should include new liquidity");
        assertEq(position.endHeight1, 800, "endHeight1 should include new liquidity");
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositAndWithdrawLiquidity_multiplePositions() public {
        test_depositLiquidity_basic();

        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 500,
            amount1: 800,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position1")];

        uint128 initialPosition0Share = poolState.position0ShareOf0;
        uint128 initialPosition1Share = poolState.position1ShareOf1;

        ModifyFixedLiquidityCache memory liquidityCache;
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), true);

        assertEq(deposit0, 500, "Additional deposit0 should equal amount0");
        assertEq(deposit1, 800, "Additional deposit1 should equal amount1");

        assertEq(poolState.position0ShareOf0, initialPosition0Share + 500, "position0ShareOf0 should increase");
        assertEq(poolState.position1ShareOf1, initialPosition1Share + 800, "position1ShareOf1 should increase");

        assertEq(position.endHeight0, 500, "endHeight0 should include new liquidity");
        assertEq(position.endHeight1, 800, "endHeight1 should include new liquidity");

        console2.log("Withdrawing liquidity...");
        FixedLiquidityWithdrawAllParams memory withdrawAllParams = FixedLiquidityWithdrawAllParams({
            minAmount0: additionalParams.amount0,
            minAmount1: additionalParams.amount1
        });
        FixedHelper.withdrawAll(withdrawAllParams, poolState, position);

        console2.log(position.startHeight0, position.endHeight0);

        console2.log("updating expected height maps");
        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), false);

        console2.log("validating height maps");
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositAndWithdrawPartialLiquidity_multiplePositions() public {
        test_depositLiquidity_basic();

        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 500,
            amount1: 800,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position1")];

        uint128 initialPosition0Share = poolState.position0ShareOf0;
        uint128 initialPosition1Share = poolState.position1ShareOf1;

        ModifyFixedLiquidityCache memory liquidityCache;
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), true);

        assertEq(deposit0, 500, "Additional deposit0 should equal amount0");
        assertEq(deposit1, 800, "Additional deposit1 should equal amount1");

        assertEq(poolState.position0ShareOf0, initialPosition0Share + 500, "position0ShareOf0 should increase");
        assertEq(poolState.position1ShareOf1, initialPosition1Share + 800, "position1ShareOf1 should increase");

        assertEq(position.endHeight0, 500, "endHeight0 should include new liquidity");
        assertEq(position.endHeight1, 800, "endHeight1 should include new liquidity");

        additionalParams.amount0 = 1;
        additionalParams.amount1 = 1;

        FixedHelper.withdrawLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), false);

        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositAndWithdrawOneSideLiquidity_multiplePositions() public {
        test_depositLiquidity_basic();

        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 500,
            amount1: 800,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 0,
            endHeightInsertionHint1: 0,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position1")];

        uint128 initialPosition0Share = poolState.position0ShareOf0;
        uint128 initialPosition1Share = poolState.position1ShareOf1;

        ModifyFixedLiquidityCache memory liquidityCache;
        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), true);

        assertEq(deposit0, 500, "Additional deposit0 should equal amount0");
        assertEq(deposit1, 800, "Additional deposit1 should equal amount1");

        assertEq(poolState.position0ShareOf0, initialPosition0Share + 500, "position0ShareOf0 should increase");
        assertEq(poolState.position1ShareOf1, initialPosition1Share + 800, "position1ShareOf1 should increase");

        assertEq(position.endHeight0, 500, "endHeight0 should include new liquidity");
        assertEq(position.endHeight1, 800, "endHeight1 should include new liquidity");

        additionalParams.amount0 = 500;
        additionalParams.amount1 = 0;

        FixedHelper.withdrawLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), false);

        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_depositLiquidity_multiplePositions_IncorrectHint() public {
        // First, create an initial position
        test_depositLiquidity_basic();

        // Now add more liquidity to the existing position
        FixedLiquidityModificationParams memory additionalParams = FixedLiquidityModificationParams({
            amount0: 500,
            amount1: 800,
            addInRange0: false,
            addInRange1: false,
            endHeightInsertionHint0: 1000,
            endHeightInsertionHint1: 1000,
            maxStartHeight0: type(uint256).max,
            maxStartHeight1: type(uint256).max
        });

        FixedPoolState storage poolState = pools[testPoolId0];
        FixedPositionInfo storage position = positions[bytes32("position1")];

        // Store initial state for comparison
        uint128 initialPosition0Share = poolState.position0ShareOf0;
        uint128 initialPosition1Share = poolState.position1ShareOf1;

        (uint256 deposit0, uint256 deposit1,,) =
            FixedHelper.depositLiquidity(testPoolId0, additionalParams, poolState, position);

        _updatedExpectedHeightMaps(additionalParams, bytes32("position1"), true);

        // Assert: New deposits should equal the additional amounts
        assertEq(deposit0, 500, "Additional deposit0 should equal amount0");
        assertEq(deposit1, 800, "Additional deposit1 should equal amount1");

        // Pool shares should be increased by the new amounts
        assertEq(poolState.position0ShareOf0, initialPosition0Share + 500, "position0ShareOf0 should increase");
        assertEq(poolState.position1ShareOf1, initialPosition1Share + 800, "position1ShareOf1 should increase");

        // Position height ranges should be updated to include new liquidity
        assertEq(position.endHeight0, 500, "endHeight0 should include new liquidity");
        assertEq(position.endHeight1, 800, "endHeight1 should include new liquidity");

        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    ////////////////
    /// Fuzz Tests
    ////////////////

    function test_fuzz_depositLiquidity_validateHeightMaps(bytes32 seed) public {
        uint16 positionsToAdd = uint16(uint256(seed) % 100 + 50);

        for (uint16 i = 0; i < positionsToAdd; i++) {
            uint256 amount0 = uint256(keccak256(abi.encodePacked(seed, i, "amount0"))) % 1000 + 100;
            uint256 amount1 = uint256(keccak256(abi.encodePacked(seed, i, "amount1"))) % 2000 + 200;
            // uint256 endHeightInsertionHint0 = uint256(keccak256(abi.encodePacked(seed, i, "endHeight0"))) % 1000;
            // uint256 endHeightInsertionHint1 = uint256(keccak256(abi.encodePacked(seed, i, "endHeight1"))) % 1000;

            FixedLiquidityModificationParams memory params = FixedLiquidityModificationParams({
                amount0: amount0,
                amount1: amount1,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            bytes32 positionKey = bytes32(keccak256(abi.encodePacked("position", i)));

            FixedPoolState storage poolState = pools[testPoolId0];
            FixedPositionInfo storage position = positions[positionKey];

            FixedHelper.depositLiquidity(testPoolId0, params, poolState, position);

            _updatedExpectedHeightMaps(params, positionKey, true);
        }
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    function test_fuzz_depositAndRemoveLiquidity_validateHeightMaps(bytes32 seed) public {
        uint16 positionsToAdd = uint16(uint256(seed) % 100 + 50);

        for (uint16 i = 0; i < positionsToAdd; i++) {
            uint256 amount0 = uint256(keccak256(abi.encodePacked(seed, i, "amount0"))) % 1000 + 100;
            uint256 amount1 = uint256(keccak256(abi.encodePacked(seed, i, "amount1"))) % 2000 + 200;
            // uint256 endHeightInsertionHint0 = uint256(keccak256(abi.encodePacked(seed, i, "endHeight0"))) % 1000;
            // uint256 endHeightInsertionHint1 = uint256(keccak256(abi.encodePacked(seed, i, "endHeight1"))) % 1000;

            FixedLiquidityModificationParams memory params = FixedLiquidityModificationParams({
                amount0: amount0,
                amount1: amount1,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });

            bytes32 positionKey = bytes32(keccak256(abi.encodePacked("position", i)));

            FixedPoolState storage poolState = pools[testPoolId0];
            FixedPositionInfo storage position = positions[positionKey];

            FixedHelper.depositLiquidity(testPoolId0, params, poolState, position);

            _updatedExpectedHeightMaps(params, positionKey, true);
        }
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
        for (uint16 i = 0; i < positionsToAdd; i++) {
            uint256 amount0 = uint256(keccak256(abi.encodePacked(seed, i, "amount0"))) % 1000 + 100;
            uint256 amount1 = uint256(keccak256(abi.encodePacked(seed, i, "amount1"))) % 2000 + 200;
            // uint256 endHeightInsertionHint0 = uint256(keccak256(abi.encodePacked(seed, i, "endHeight0"))) % 1000;
            // uint256 endHeightInsertionHint1 = uint256(keccak256(abi.encodePacked(seed, i, "endHeight1"))) % 1000;
            amount0 = _roundDownToPrecision(amount0, 10);
            amount1 = _roundDownToPrecision(amount1, 10);

            FixedLiquidityModificationParams memory params = FixedLiquidityModificationParams({
                amount0: amount0,
                amount1: amount1,
                addInRange0: false,
                addInRange1: false,
                endHeightInsertionHint0: 0,
                endHeightInsertionHint1: 0,
                maxStartHeight0: type(uint256).max,
                maxStartHeight1: type(uint256).max
            });
            FixedLiquidityWithdrawAllParams memory withdrawParams = FixedLiquidityWithdrawAllParams({
                minAmount0: amount0,
                minAmount1: amount1
            });

            bytes32 positionKey = bytes32(keccak256(abi.encodePacked("position", i)));

            FixedPoolState storage poolState = pools[testPoolId0];
            FixedPositionInfo storage position = positions[positionKey];
            FixedHelper.withdrawAll(withdrawParams, poolState, position);

            _updatedExpectedHeightMaps(params, positionKey, false);
        }
        _validateHeightMaps(0, pools[testPoolId0].heightMap0, pools[testPoolId0].heightMap1);
    }

    ////////////////
    /// Helpers
    ////////////////

    function _roundDownToPrecision(uint256 amount, uint256 precision) internal pure returns (uint256) {
        if (amount < precision) return 0; // If amount is less than precision, return 0
        return (amount / precision) * precision; // Round down to the nearest multiple of prforgeecision
    }

    function _generateMockPoolId(uint8 spacing0, uint8 spacing1, uint160 sqrtPriceRatioX96)
        internal
        pure
        returns (bytes32 poolId)
    {
        poolId = EfficientHash.efficientHash(
            bytes32(uint256(uint160(address(0)))),
            bytes32(uint256(0)),
            bytes32(uint256(spacing0)),
            bytes32(uint256(spacing1)),
            bytes32(uint256(FixedHelper.normalizePriceToRatio(sqrtPriceRatioX96))),
            bytes32(uint256(uint160(address(0)))),
            bytes32(uint256(uint160(address(0)))),
            bytes32(uint256(uint160(address(0))))
        ) & 0x0000000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF000000000000;

        poolId = poolId | bytes32((uint256(uint160(address(0))) << 144)) | bytes32(uint256(0) << 0)
            | bytes32(uint256(uint24(spacing0)) << 24) | bytes32(uint256(uint24(spacing1)) << 16);
    }

    function _printHeightMap(mapping(uint256 => FixedHeightMap) storage heightMap) internal view {
        bytes memory output = bytes("0");
        uint256 currentHeight;
        uint256 nextHeight;
        uint256 loopCount;
        while (true) {
            if (++loopCount > 500) break;
            nextHeight = heightMap[currentHeight].nextHeightAbove;
            if (currentHeight == nextHeight) break;
            currentHeight = nextHeight;
            output = bytes.concat(output, bytes("->"), bytes(toString(nextHeight)));
        }
        console.log(string(output));
    }

    function toString(uint256 value) internal pure returns (string memory result) {
        /// @solidity memory-safe-assembly
        assembly {
            // The maximum value of a uint256 contains 78 digits (1 byte per digit), but
            // we allocate 0xa0 bytes to keep the free memory pointer 32-byte word aligned.
            // We will need 1 word for the trailing zeros padding, 1 word for the length,
            // and 3 words for a maximum of 78 digits.
            result := add(mload(0x40), 0x80)
            mstore(0x40, add(result, 0x20)) // Allocate memory.
            mstore(result, 0) // Zeroize the slot after the string.

            let end := result // Cache the end of the memory to calculate the length later.
            let w := not(0) // Tsk.
            // We write the string from rightmost digit to leftmost digit.
            // The following is essentially a do-while loop that also handles the zero case.
            for { let temp := value } 1 {} {
                result := add(result, w) // `sub(result, 1)`.
                // Store the character to the pointer.
                // The ASCII index of the '0' character is 48.
                mstore8(result, add(48, mod(temp, 10)))
                temp := div(temp, 10) // Keep dividing `temp` until zero.
                if iszero(temp) { break }
            }
            let n := sub(end, result)
            result := sub(result, 0x20) // Move the pointer 32 bytes back to make room for the length.
            mstore(result, n) // Store the length.
        }
    }

    function _validateHeightMaps(
        uint256 startHeight,
        mapping(uint256 => FixedHeightMap) storage heightMap0,
        mapping(uint256 => FixedHeightMap) storage heightMap1
    ) internal view {
        _validateHeightMapIntegrity(heightMap0, startHeight);
        _validateHeightMapIntegrity(heightMap1, startHeight);
        _validateHeightMapCorrectness(startHeight, heightMap0, expectedHeightMap0);
        _validateHeightMapCorrectness(startHeight, heightMap1, expectedHeightMap1);
    }

    function _validateHeightMapCorrectness(
        uint256 startHeight,
        mapping(uint256 => FixedHeightMap) storage heightMap,
        mapping(uint256 => FixedHeightMap) storage expectedHeightMap
    ) internal view {
        // validate that both height maps have the same structure
        uint256 currentHeight = startHeight;
        uint256 nodeCount = 0;
        while (nodeCount < 500) {
            FixedHeightMap storage currentNode = heightMap[currentHeight];
            FixedHeightMap storage expectedNode = expectedHeightMap[currentHeight];
            if (
                currentNode.nextHeightAbove != expectedNode.nextHeightAbove
                    || currentNode.nextHeightBelow != expectedNode.nextHeightBelow
            ) {
                revert("Height map structure mismatch at height");
            }
            if (currentHeight == currentNode.nextHeightAbove) {
                // Reached the end of the linked list
                break;
            }
            currentHeight = currentNode.nextHeightAbove;
            nodeCount++;
        }
    }

    function _validateHeightMapIntegrity(mapping(uint256 => FixedHeightMap) storage heightMap, uint256 startHeight)
        internal
        view
    {
        uint256 currentHeight = startHeight;
        uint256 nodeCount = 0;

        while (nodeCount < 500) {
            FixedHeightMap storage currentNode = heightMap[currentHeight];
            uint256 nextHeight = currentNode.nextHeightAbove;
            uint256 prevHeight = currentNode.nextHeightBelow;

            // Check termination condition (self-reference)
            if (currentHeight == nextHeight) {
                break;
            }

            // nextHeightAbove must be higher than current
            if (nextHeight <= currentHeight) {
                revert("nextHeightAbove must be greater than current height");
            }

            // If not at start, nextHeightBelow must be lower than current
            if (currentHeight != startHeight && prevHeight >= currentHeight) {
                revert("nextHeightBelow must be less than current height");
            }

            currentHeight = nextHeight;
            nodeCount++;
        }
    }

    function _updatedExpectedHeightMaps(
        FixedLiquidityModificationParams memory /* params */,
        bytes32 positionKey,
        bool /* liquidityAdded */
    ) internal {
        FixedPositionInfo storage position = positions[positionKey];
        console2.log("position.startHeight0:", position.startHeight0);
        console2.log("position.endHeight0:", position.endHeight0);
        console2.log("position.startHeight1:", position.startHeight1);
        console2.log("position.endHeight1:", position.endHeight1);
        uint256 netLiquidity0 = position.endHeight0 - position.startHeight0;
        uint256 netLiquidity1 = position.endHeight1 - position.startHeight1;

        if (netLiquidity0 == 0) {
            isPositionSide0Tracked[positionKey] = false;
        } else {
            isPositionSide0Tracked[positionKey] = true;
        }
        if (netLiquidity1 == 0) {
            isPositionSide1Tracked[positionKey] = false;
        } else {
            isPositionSide1Tracked[positionKey] = true;
        }

        // check if position key is in trackedPositionKeys and add if not
        if (netLiquidity0 == 0 && netLiquidity1 == 0) {
            // If both sides are empty, we can remove the position from tracking
            for (uint256 i = 0; i < trackedPositionKeys.length; i++) {
                if (trackedPositionKeys[i] == positionKey) {
                    trackedPositionKeys[i] = trackedPositionKeys[trackedPositionKeys.length - 1];
                    trackedPositionKeys.pop();
                    break;
                }
            }
        } else {
            // If position is not empty, ensure it's tracked
            bool found = false;
            for (uint256 i = 0; i < trackedPositionKeys.length; i++) {
                if (trackedPositionKeys[i] == positionKey) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                trackedPositionKeys.push(positionKey);
            }
        }
        console2.log("Rebuilding expected height maps...");
        _rebuildHeightMapsFromAllPositions();
    }

    function _rebuildHeightMapsFromAllPositions() internal {
        // Collect all unique heights from all positions
        uint256[] memory heights0 = new uint256[](type(uint16).max);
        uint256[] memory heights1 = new uint256[](type(uint16).max);
        uint256 count0;
        uint256 count1;

        for (uint256 i = 0; i < trackedPositionKeys.length; i++) {
            bytes32 key = trackedPositionKeys[i];
            FixedPositionInfo storage pos = positions[key];

            if (isPositionSide0Tracked[key] && pos.startHeight0 != pos.endHeight0) {
                // Add start height if not already present
                bool foundStart = false;
                for (uint256 j = 0; j < count0; j++) {
                    if (heights0[j] == pos.startHeight0) {
                        foundStart = true;
                        break;
                    }
                }
                if (!foundStart) heights0[count0++] = pos.startHeight0;

                // Add end height if not already present
                bool foundEnd = false;
                for (uint256 j = 0; j < count0; j++) {
                    if (heights0[j] == pos.endHeight0) {
                        foundEnd = true;
                        break;
                    }
                }
                if (!foundEnd) heights0[count0++] = pos.endHeight0;
            }

            // Add token1 heights if position has liquidity
            if (isPositionSide1Tracked[key] && pos.startHeight1 != pos.endHeight1) {
                // Add start height if not already present
                bool foundStart = false;
                for (uint256 j = 0; j < count1; j++) {
                    if (heights1[j] == pos.startHeight1) {
                        foundStart = true;
                        break;
                    }
                }
                if (!foundStart) heights1[count1++] = pos.startHeight1;

                // Add end height if not already present
                bool foundEnd = false;
                for (uint256 j = 0; j < count1; j++) {
                    if (heights1[j] == pos.endHeight1) {
                        foundEnd = true;
                        break;
                    }
                }
                if (!foundEnd) heights1[count1++] = pos.endHeight1;
            }
        }

        // Sort heights
        _sortArray(heights0, count0);
        _sortArray(heights1, count1);

        // Clear existing maps and rebuild
        _clearAndBuildHeightMap(expectedHeightMap0, heights0, count0);
        _clearAndBuildHeightMap(expectedHeightMap1, heights1, count1);
    }

    function _sortArray(uint256[] memory arr, uint256 count) internal pure {
        for (uint256 i = 0; i < count; i++) {
            for (uint256 j = i + 1; j < count; j++) {
                if (arr[i] > arr[j]) {
                    uint256 temp = arr[i];
                    arr[i] = arr[j];
                    arr[j] = temp;
                }
            }
        }
    }

    function _clearAndBuildHeightMap(
        mapping(uint256 => FixedHeightMap) storage heightMap,
        uint256[] memory heights,
        uint256 count
    ) internal {
        // Clear old entries (we'll just overwrite)
        delete heightMap[0];

        if (count == 0) return;

        // Clear all height entries we'll use
        for (uint256 i = 0; i < count; i++) {
            delete heightMap[heights[i]];
        }

        // Build the linked list
        // Link from 0 to first height
        heightMap[0].nextHeightAbove = heights[0];
        heightMap[heights[0]].nextHeightBelow = 0;

        // Link intermediate heights
        for (uint256 i = 0; i < count - 1; i++) {
            heightMap[heights[i]].nextHeightAbove = heights[i + 1];
            heightMap[heights[i + 1]].nextHeightBelow = heights[i];
        }

        // Last height self-references
        heightMap[heights[count - 1]].nextHeightAbove = heights[count - 1];
    }
}
