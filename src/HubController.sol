// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IEulerSwap} from "./interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "./interfaces/IEulerSwapFactory.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";

contract HubController is Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // Core state
    IEVC public immutable evc;
    IEulerSwapFactory public immutable factory;
    address public immutable hubAccount; // The Euler account that owns all pools
    address public immutable hubAsset;   // e.g., USDC
    address public immutable hubVault;   // USDC vault
    
    // Pool management
    EnumerableSet.AddressSet private activePools;
    mapping(address => PoolInfo) public poolInfo;
    
    // Dynamic allocation parameters
    uint256 public rebalanceInterval = 1 hours;
    uint256 public lastRebalance;
    uint256 public minAllocation = 1e6; // Min $1 allocation
    
    struct PoolInfo {
        address token;
        address vault;
        address pool;
        uint256 volume24h;
        uint256 lastVolumeUpdate;
        uint256 virtualReserveAllocation;
        uint256 targetConcentration;
    }
    
    struct SwapRoute {
        address poolA;
        address poolB;
        bool isPool0Input;
        uint256 amountMid;
    }
    
    event PoolAdded(address indexed token, address indexed pool);
    event PoolRemoved(address indexed token, address indexed pool);
    event Rebalanced(uint256 timestamp, uint256 totalVolume);
    event CrossSwapExecuted(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );
    
    constructor(
        address _evc,
        address _factory,
        address _hubAccount,
        address _hubAsset,
        address _hubVault
    ) Ownable(msg.sender) {
        evc = IEVC(_evc);
        factory = IEulerSwapFactory(_factory);
        hubAccount = _hubAccount;
        hubAsset = _hubAsset;
        hubVault = _hubVault;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Pool Management
    // ═══════════════════════════════════════════════════════════════
    
    function addToken(
        address token,
        address tokenVault,
        uint256 initialReserveToken,
        uint256 initialReserveHub,
        IEulerSwap.Params memory params
    ) external onlyOwner returns (address pool) {
        require(token != hubAsset, "Cannot add hub asset");
        require(!isTokenSupported(token), "Token already added");
        
        // Override critical parameters
        params.eulerAccount = hubAccount;
        params.vault0 = token < hubAsset ? tokenVault : hubVault;
        params.vault1 = token < hubAsset ? hubVault : tokenVault;
        
        // Deploy the pool
        IEulerSwap.InitialState memory initialState = IEulerSwap.InitialState({
            currReserve0: token < hubAsset ? uint112(initialReserveToken) : uint112(initialReserveHub),
            currReserve1: token < hubAsset ? uint112(initialReserveHub) : uint112(initialReserveToken)
        });
        
        pool = factory.deployPool(params, initialState, keccak256(abi.encode(token)));
        
        // Store pool info
        poolInfo[token] = PoolInfo({
            token: token,
            vault: tokenVault,
            pool: pool,
            volume24h: 0,
            lastVolumeUpdate: block.timestamp,
            virtualReserveAllocation: initialReserveHub,
            targetConcentration: params.concentrationX
        });
        
        activePools.add(token);
        emit PoolAdded(token, pool);
    }
    
    function removeToken(address token) external onlyOwner {
        require(isTokenSupported(token), "Token not supported");
        
        // Uninstall the pool from factory
        factory.uninstallPool();
        
        activePools.remove(token);
        delete poolInfo[token];
        emit PoolRemoved(token, poolInfo[token].pool);
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Cross-Pair Swapping
    // ═══════════════════════════════════════════════════════════════
    
    function swapCrossPair(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient,
        uint256 minAmountOut
    ) external returns (uint256 amountOut) {
        require(tokenIn != tokenOut, "Same token swap");
        
        SwapRoute memory route = _calculateRoute(tokenIn, tokenOut, amountIn);
        
        // Execute the swap through hub
        if (tokenIn == hubAsset) {
            // Direct swap: HUB -> Token
            amountOut = _executeDirectSwap(route.poolB, true, amountIn, recipient);
        } else if (tokenOut == hubAsset) {
            // Direct swap: Token -> HUB
            amountOut = _executeDirectSwap(route.poolA, false, amountIn, recipient);
        } else {
            // Cross swap: TokenA -> HUB -> TokenB
            amountOut = _executeCrossSwap(route, amountIn, recipient);
        }
        
        require(amountOut >= minAmountOut, "Insufficient output");
        
        // Update volume tracking
        _updateVolume(tokenIn, amountIn);
        if (tokenIn != hubAsset && tokenOut != hubAsset) {
            _updateVolume(tokenOut, amountOut);
        }
        
        emit CrossSwapExecuted(tokenIn, tokenOut, amountIn, amountOut, recipient);
    }
    
    function _calculateRoute(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (SwapRoute memory) {
        SwapRoute memory route;
        
        if (tokenIn != hubAsset && tokenOut != hubAsset) {
            // Need both pools for cross-pair
            route.poolA = poolInfo[tokenIn].pool;
            route.poolB = poolInfo[tokenOut].pool;
            
            // Calculate intermediate amount
            route.amountMid = IEulerSwap(route.poolA).computeQuote(
                tokenIn,
                hubAsset,
                amountIn,
                true
            );
        } else if (tokenIn == hubAsset) {
            route.poolB = poolInfo[tokenOut].pool;
        } else {
            route.poolA = poolInfo[tokenIn].pool;
        }
        
        return route;
    }
    
    function _executeDirectSwap(
        address pool,
        bool hubIsInput,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256) {
        address tokenIn = hubIsInput ? hubAsset : poolInfo[pool].token;
        address tokenOut = hubIsInput ? poolInfo[pool].token : hubAsset;
        
        // Transfer tokens to pool
        IERC20(tokenIn).safeTransferFrom(msg.sender, pool, amountIn);
        
        // Calculate output
        uint256 amountOut = IEulerSwap(pool).computeQuote(tokenIn, tokenOut, amountIn, true);
        
        // Execute swap
        if (hubIsInput) {
            IEulerSwap(pool).swap(amountOut, 0, recipient, "");
        } else {
            IEulerSwap(pool).swap(0, amountOut, recipient, "");
        }
        
        return amountOut;
    }
    
    function _executeCrossSwap(
        SwapRoute memory route,
        uint256 amountIn,
        address recipient
    ) internal returns (uint256) {
        // First leg: TokenA -> Hub
        IERC20(poolInfo[route.poolA].token).safeTransferFrom(msg.sender, route.poolA, amountIn);
        IEulerSwap(route.poolA).swap(0, route.amountMid, address(this), "");
        
        // Second leg: Hub -> TokenB
        IERC20(hubAsset).safeTransfer(route.poolB, route.amountMid);
        uint256 amountOut = IEulerSwap(route.poolB).computeQuote(
            hubAsset,
            poolInfo[route.poolB].token,
            route.amountMid,
            true
        );
        IEulerSwap(route.poolB).swap(amountOut, 0, recipient, "");
        
        return amountOut;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Dynamic Rebalancing
    // ═══════════════════════════════════════════════════════════════
    
    function rebalanceAllocations() external {
        require(block.timestamp >= lastRebalance + rebalanceInterval, "Too soon");
        
        uint256 totalVolume = _calculateTotalVolume();
        uint256 totalHubBalance = _getHubVaultBalance();
        
        address[] memory tokens = activePools.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            PoolInfo storage info = poolInfo[token];
            
            // Calculate new allocation based on volume
            uint256 targetAllocation = totalVolume > 0
                ? (info.volume24h * totalHubBalance) / totalVolume
                : totalHubBalance / tokens.length;
            
            // Apply min/max constraints
            targetAllocation = _constrainAllocation(targetAllocation, totalHubBalance);
            
            // Update pool parameters if needed
            if (_shouldUpdatePool(info, targetAllocation)) {
                _updatePoolParameters(token, targetAllocation);
            }
            
            info.virtualReserveAllocation = targetAllocation;
        }
        
        lastRebalance = block.timestamp;
        emit Rebalanced(block.timestamp, totalVolume);
    }
    
    function _updatePoolParameters(address token, uint256 newAllocation) internal {
        PoolInfo storage info = poolInfo[token];
        
        // Calculate new concentration based on volatility
        uint256 volatility = _estimateVolatility(token);
        uint256 newConcentration = volatility > 50 ? 3e17 : 8e17; // 0.3 or 0.8
        
        // Prepare new parameters
        IEulerSwap.Params memory currentParams = IEulerSwap(info.pool).getParams();
        currentParams.concentrationX = newConcentration;
        currentParams.concentrationY = newConcentration;
        
        // Get current reserves
        (uint112 reserve0, uint112 reserve1,) = IEulerSwap(info.pool).getReserves();
        
        // Redeploy with new parameters
        factory.uninstallPool();
        address newPool = factory.deployPool(
            currentParams,
            IEulerSwap.InitialState(reserve0, reserve1),
            keccak256(abi.encode(token, block.timestamp))
        );
        
        info.pool = newPool;
        info.targetConcentration = newConcentration;
    }
    
    // ═══════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════
    
    function isTokenSupported(address token) public view returns (bool) {
        return activePools.contains(token);
    }
    
    function getSupportedTokens() external view returns (address[] memory) {
        return activePools.values();
    }
    
    function getPoolInfo(address token) external view returns (PoolInfo memory) {
        return poolInfo[token];
    }
    
    function _updateVolume(address token, uint256 amount) internal {
        PoolInfo storage info = poolInfo[token];
        
        // Simple exponential decay for 24h volume
        uint256 timePassed = block.timestamp - info.lastVolumeUpdate;
        if (timePassed >= 24 hours) {
            info.volume24h = amount;
        } else {
            uint256 decay = (info.volume24h * (24 hours - timePassed)) / 24 hours;
            info.volume24h = decay + amount;
        }
        
        info.lastVolumeUpdate = block.timestamp;
    }
    
    function _calculateTotalVolume() internal view returns (uint256 total) {
        address[] memory tokens = activePools.values();
        for (uint256 i = 0; i < tokens.length; i++) {
            total += poolInfo[tokens[i]].volume24h;
        }
    }
    
    function _getHubVaultBalance() internal view returns (uint256) {
        return IEVault(hubVault).convertToAssets(
            IEVault(hubVault).balanceOf(hubAccount)
        );
    }
    
    function _constrainAllocation(uint256 target, uint256 total) internal view returns (uint256) {
        if (target < minAllocation) return minAllocation;
        if (target > total / 2) return total / 2; // Max 50% to any pool
        return target;
    }
    
    function _shouldUpdatePool(PoolInfo memory info, uint256 newAllocation) internal pure returns (bool) {
        uint256 allocationChange = newAllocation > info.virtualReserveAllocation
            ? newAllocation - info.virtualReserveAllocation
            : info.virtualReserveAllocation - newAllocation;
            
        return allocationChange > info.virtualReserveAllocation / 10; // 10% threshold
    }
    
    function _estimateVolatility(address token) internal view returns (uint256) {
        // Simplified volatility estimation
        // In production, would use price oracle data
        return 30; // Placeholder
    }
}