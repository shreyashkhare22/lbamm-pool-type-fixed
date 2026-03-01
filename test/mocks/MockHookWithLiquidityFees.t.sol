pragma solidity 0.8.24;

import "@limitbreak/lb-amm-core/src/interfaces/hooks/ILimitBreakAMMLiquidityHook.sol";
import "@limitbreak/lb-amm-core/src/interfaces/hooks/ILimitBreakAMMPoolHook.sol";
import "@limitbreak/lb-amm-core/src/interfaces/hooks/ILimitBreakAMMTokenHook.sol";
import "@limitbreak/lb-amm-core/src/interfaces/ILimitBreakAMM.sol";
import "@limitbreak/lb-amm-core/src/Constants.sol";

struct FeeAmounts {
    uint256 positionCollect0;
    uint256 positionCollect1;
    uint256 positionAdd0;
    uint256 positionAdd1;
    uint256 positionRemove0;
    uint256 positionRemove1;
    uint256 poolCollect0;
    uint256 poolCollect1;
    uint256 poolAdd0;
    uint256 poolAdd1;
    uint256 poolRemove0;
    uint256 poolRemove1;
    uint256 tokenCollect0;
    uint256 tokenCollect1;
    uint256 tokenAdd0;
    uint256 tokenAdd1;
    uint256 tokenRemove0;
    uint256 tokenRemove1;
    address amm;
    bool collectDuring;
    address collectTo;
    address token0;
    address token1;
}

contract MockHookWithLiquidityFees is ILimitBreakAMMLiquidityHook, ILimitBreakAMMPoolHook, ILimitBreakAMMTokenHook {
    FeeAmounts private feeAmounts;

    function setFeeAmounts(FeeAmounts memory _feeAmounts) external {
        feeAmounts = _feeAmounts;
    }

    function _handleFees(uint256 hookFee0, uint256 hookFee1) internal {
        if (feeAmounts.collectDuring) {
            if (hookFee0 > 0) {
                address token0 = feeAmounts.token0;
                ILimitBreakAMM(feeAmounts.amm).collectHookFeesByHook(token0, token0, feeAmounts.collectTo, hookFee0);
            }
            if (hookFee1 > 0) {
                address token1 = feeAmounts.token1;
                ILimitBreakAMM(feeAmounts.amm).collectHookFeesByHook(token1, token1, feeAmounts.collectTo, hookFee1);
            }
        }
    }

    function validatePositionCollectFees(
        LiquidityContext calldata,
        LiquidityCollectFeesParams calldata,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.positionCollect0, feeAmounts.positionCollect1);
        _handleFees(hookFee0, hookFee1);
    }

    function validatePositionAddLiquidity(
        LiquidityContext calldata,
        LiquidityModificationParams calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.positionAdd0, feeAmounts.positionAdd1);
        _handleFees(hookFee0, hookFee1);
    }

    function validatePositionRemoveLiquidity(
        LiquidityContext calldata,
        LiquidityModificationParams calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.positionRemove0, feeAmounts.positionRemove1);
        _handleFees(hookFee0, hookFee1);
    }

    function liquidityHookManifestUri() external view returns(string memory manifestUri) { }


    function validatePoolCreation(
        bytes32,
        address,
        PoolCreationDetails calldata,
        bytes calldata
    ) external { }
    
    function getPoolFeeForSwap(
        SwapContext calldata,
        HookPoolFeeParams calldata,
        bytes calldata
    ) external returns (uint256 poolFeeBPS) { }
    
    function validatePoolCollectFees(
        LiquidityContext calldata,
        LiquidityCollectFeesParams calldata,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.poolCollect0, feeAmounts.poolCollect1);
        _handleFees(hookFee0, hookFee1);
    }
    
    function validatePoolAddLiquidity(
        LiquidityContext calldata,
        LiquidityModificationParams calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.poolAdd0, feeAmounts.poolAdd1);
        _handleFees(hookFee0, hookFee1);
    }
    
    function validatePoolRemoveLiquidity(
        LiquidityContext calldata,
        LiquidityModificationParams calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.poolRemove0, feeAmounts.poolRemove1);
        _handleFees(hookFee0, hookFee1);
    }
    
    function poolHookManifestUri() external view returns(string memory) { }
    


    function hookFlags() external pure returns (uint32 requiredFlags, uint32 supportedFlags) {
        requiredFlags = 0;
        supportedFlags = TOKEN_SETTINGS_ADD_LIQUIDITY_HOOK_FLAG | TOKEN_SETTINGS_REMOVE_LIQUIDITY_HOOK_FLAG | TOKEN_SETTINGS_COLLECT_FEES_HOOK_FLAG | TOKEN_SETTINGS_HOOK_MANAGES_FEES_FLAG;
    }
    
    function validatePoolCreation(
        bytes32,
        address,
        bool,
        PoolCreationDetails calldata,
        bytes calldata
    ) external { }
    
    function beforeSwap(
        SwapContext calldata,
        HookSwapParams calldata,
        bytes calldata
    ) external returns (uint256 fee) { }
    
    function afterSwap(
        SwapContext calldata,
        HookSwapParams calldata,
        bytes calldata
    ) external returns (uint256 fee) { }
    
    function validateCollectFees(
        bool,
        LiquidityContext calldata,
        LiquidityCollectFeesParams calldata,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.tokenCollect0, feeAmounts.tokenCollect1);
        _handleFees(hookFee0, hookFee1);
    }
    
    function validateAddLiquidity(
        bool,
        LiquidityContext calldata,
        LiquidityModificationParams calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.tokenAdd0, feeAmounts.tokenAdd1);
        _handleFees(hookFee0, hookFee1);
    }
    
    function validateRemoveLiquidity(
        bool,
        LiquidityContext calldata,
        LiquidityModificationParams calldata,
        uint256,
        uint256,
        uint256,
        uint256,
        bytes calldata
    ) external returns (uint256 hookFee0, uint256 hookFee1) {
        (hookFee0, hookFee1) = (feeAmounts.tokenRemove0, feeAmounts.tokenRemove1);
        _handleFees(hookFee0, hookFee1);
    }
    
    function beforeFlashloan(
        address,
        address,
        uint256,
        address,
        bytes calldata
    ) external returns (address, uint256) { }
    
    function validateFlashloanFee(
        address,
        address,
        uint256,
        address,
        uint256,
        address,
        bytes calldata
    ) external returns (bool) { }
    
    function tokenHookManifestUri() external view returns(string memory) { }

    function validateHandlerOrder(address, bool, address, address, uint256, uint256, bytes calldata, bytes calldata) external pure { }
}