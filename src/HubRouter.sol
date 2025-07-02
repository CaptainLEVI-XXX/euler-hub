// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IEulerSwap} from "./interfaces/IEulerSwap.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IEulerSwapPeriphery} from "./interfaces/IEulerSwapPeriphery.sol";

interface IHubController {
    function poolInfo(address token) external view returns (
        address token,
        address vault,
        address pool,
        uint256 volume24h,
        uint256 lastVolumeUpdate,
        uint256 virtualReserveAllocation,
        uint256 targetConcentration
    );
    function hubAsset() external view returns (address);
    function isTokenSupported(address token) external view returns (bool);
    function getSupportedTokens() external view returns (address[] memory);
}

contract HubRouter {
    using SafeERC20 for IERC20;
    
    IHubController public immutable hubController;
    IEulerSwapPeriphery public immutable periphery;
    address public immutable hubAsset;
    
    error UnsupportedToken();
    error InsufficientOutput();
    error DeadlineExpired();
    error InvalidPath();
    
    struct SwapParams {
        address[] path;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        uint256 deadline;
    }
    
    struct QuoteResult {
        uint256 amountOut;
        uint256[] amounts;
        address[] pools;
        uint256 priceImpact;
    }
    
    modifier checkDeadline(uint256 deadline) {
        require(deadline == 0 || deadline >= block.timestamp, DeadlineExpired());
        _;
    }
    
    constructor(address _hubController, address _periphery) {
        hubController = IHubController(_hubController);
        periphery = IEulerSwapPeriphery(_periphery);
        hubAsset = hubController.hubAsset();
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Main Swap Functions
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Swap exact input amount through the hub
    /// @param params Swap parameters including path, amounts, and deadline
    /// @return amountOut The amount of output tokens received
    function swapExactIn(SwapParams calldata params) 
        external 
        checkDeadline(params.deadline)
        returns (uint256 amountOut) 
    {
        require(params.path.length >= 2, InvalidPath());
        
        // Get quote first
        QuoteResult memory quote = getQuote(params.path, params.amountIn, true);
        require(quote.amountOut >= params.minAmountOut, InsufficientOutput());
        
        // Pull input tokens
        IERC20(params.path[0]).safeTransferFrom(
            msg.sender,
            address(this),
            params.amountIn
        );
        
        // Execute swaps
        amountOut = _executeSwaps(params.path, quote.amounts, quote.pools, params.recipient);
    }
    
    /// @notice Swap to get exact output amount through the hub
    /// @param params Swap parameters including path, amounts, and deadline
    /// @return amountIn The amount of input tokens required
    function swapExactOut(SwapParams calldata params)
        external
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        require(params.path.length >= 2, InvalidPath());
        
        // Get quote for exact output
        QuoteResult memory quote = getQuote(params.path, params.amountIn, false);
        require(quote.amountOut <= params.minAmountOut, InsufficientOutput());
        
        // Pull exact input amount needed
        IERC20(params.path[0]).safeTransferFrom(
            msg.sender,
            address(this),
            quote.amountOut
        );
        
        // Execute swaps
        _executeSwaps(params.path, quote.amounts, quote.pools, params.recipient);
        amountIn = quote.amountOut;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Multi-Path Swaps
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Execute multiple swaps in a single transaction
    /// @dev Useful for arbitrage or complex routing
    function multiSwap(SwapParams[] calldata swaps) external {
        for (uint256 i = 0; i < swaps.length; i++) {
            swapExactIn(swaps[i]);
        }
    }
    
    /// @notice Find best path between two tokens
    /// @dev Checks direct path and paths through hub
    function findBestPath(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (address[] memory path, uint256 amountOut) {
        // Check if direct pair exists
        (, , address directPool, , , ,) = hubController.poolInfo(tokenIn);
        
        if (directPool != address(0)) {
            // Try direct swap
            try IEulerSwap(directPool).computeQuote(tokenIn, tokenOut, amountIn, true) 
            returns (uint256 directAmount) {
                if (directAmount > 0) {
                    path = new address[](2);
                    path[0] = tokenIn;
                    path[1] = tokenOut;
                    return (path, directAmount);
                }
            } catch {}
        }
        
        // Use hub path
        path = new address[](3);
        path[0] = tokenIn;
        path[1] = hubAsset;
        path[2] = tokenOut;
        
        QuoteResult memory quote = getQuote(path, amountIn, true);
        return (path, quote.amountOut);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Quote Functions
    // ═══════════════════════════════════════════════════════════════
    
    /// @notice Get quote for a swap path
    /// @param path Array of token addresses representing the swap path
    /// @param amount Input amount (if exactIn) or output amount (if !exactIn)
    /// @param exactIn Whether this is exact input or exact output
    /// @return result Quote details including amounts and price impact
    function getQuote(
        address[] memory path,
        uint256 amount,
        bool exactIn
    ) public view returns (QuoteResult memory result) {
        require(path.length >= 2, InvalidPath());
        
        result.amounts = new uint256[](path.length);
        result.pools = new address[](path.length - 1);
        
        if (exactIn) {
            result.amounts[0] = amount;
            
            for (uint256 i = 0; i < path.length - 1; i++) {
                (address pool, uint256 output) = _getPoolAndQuote(
                    path[i],
                    path[i + 1],
                    result.amounts[i],
                    true
                );
                result.pools[i] = pool;
                result.amounts[i + 1] = output;
            }
            
            result.amountOut = result.amounts[path.length - 1];
        } else {
            result.amounts[path.length - 1] = amount;
            
            for (uint256 i = path.length - 1; i > 0; i--) {
                (address pool, uint256 input) = _getPoolAndQuote(
                    path[i - 1],
                    path[i],
                    result.amounts[i],
                    false
                );
                result.pools[i - 1] = pool;
                result.amounts[i - 1] = input;
            }
            
            result.amountOut = result.amounts[0];
        }
        
        // Calculate price impact
        result.priceImpact = _calculatePriceImpact(path, result.amounts);
    }
    
    /// @notice Get all supported tokens with their liquidity info
    function getHubInfo() external view returns (
        address[] memory tokens,
        uint256[] memory reserves,
        uint256[] memory volumes
    ) {
        tokens = hubController.getSupportedTokens();
        reserves = new uint256[](tokens.length);
        volumes = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            (, , address pool, uint256 volume, , uint256 allocation,) = 
                hubController.poolInfo(tokens[i]);
            
            reserves[i] = allocation;
            volumes[i] = volume;
        }
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Internal Functions
    // ═══════════════════════════════════════════════════════════════
    
    function _executeSwaps(
        address[] memory path,
        uint256[] memory amounts,
        address[] memory pools,
        address recipient
    ) internal returns (uint256) {
        for (uint256 i = 0; i < pools.length; i++) {
            address tokenIn = path[i];
            address tokenOut = path[i + 1];
            address pool = pools[i];
            uint256 amountIn = amounts[i];
            uint256 amountOut = amounts[i + 1];
            
            // Determine recipient for this swap
            address swapRecipient = (i == pools.length - 1) ? recipient : address(this);
            
            // Approve and execute swap
            IERC20(tokenIn).safeIncreaseAllowance(address(periphery), amountIn);
            periphery.swapExactIn(
                pool,
                tokenIn,
                tokenOut,
                amountIn,
                swapRecipient,
                amountOut,
                0 // No deadline, already checked
            );
        }
        
        return amounts[amounts.length - 1];
    }
    
    function _getPoolAndQuote(
        address tokenIn,
        address tokenOut,
        uint256 amount,
        bool exactIn
    ) internal view returns (address pool, uint256 quotedAmount) {
        // Check if it's a hub pair
        if (tokenIn == hubAsset) {
            (, , pool, , , ,) = hubController.poolInfo(tokenOut);
        } else if (tokenOut == hubAsset) {
            (, , pool, , , ,) = hubController.poolInfo(tokenIn);
        } else {
            // Check for direct pair (would need additional registry)
            revert UnsupportedToken();
        }
        
        require(pool != address(0), UnsupportedToken());
        
        quotedAmount = exactIn
            ? IEulerSwap(pool).computeQuote(tokenIn, tokenOut, amount, true)
            : IEulerSwap(pool).computeQuote(tokenIn, tokenOut, amount, false);
    }
    
    function _calculatePriceImpact(
        address[] memory path,
        uint256[] memory amounts
    ) internal view returns (uint256) {
        // Simplified price impact calculation
        // In production, would compare against spot prices
        uint256 inputValue = amounts[0];
        uint256 outputValue = amounts[amounts.length - 1];
        
        // Calculate expected output without slippage
        uint256 expectedOutput = inputValue; // Simplified
        
        if (outputValue >= expectedOutput) return 0;
        
        return ((expectedOutput - outputValue) * 10000) / expectedOutput; // Basis points
    }
}