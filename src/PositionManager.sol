// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IEulerSwap} from "./interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "./interfaces/IEulerSwapFactory.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";

/// @title Position Manager for Delta-Neutral Vaults
/// @notice Manages EulerSwap positions and borrowing operations
contract PositionManager is AccessControl {
    using SafeERC20 for IERC20;
    using CustomRevert for bytes4;

    // ═══════════════════════════════════════════════════════════════
    // CONSTANTS & IMMUTABLES
    // ═══════════════════════════════════════════════════════════════

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    uint256 private constant MAX_SLIPPAGE = 200; // 2%
    uint256 private constant SLIPPAGE_DENOMINATOR = 10000;

    IEVC public immutable evc;
    IEulerSwapFactory public immutable eulerSwapFactory;
    address public immutable eulerAccount;
    address public immutable vault;
    address public immutable usdc; // Base asset

    // ═══════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════

    // Position tracking
    struct Position {
        address pool; // EulerSwap pool address
        address token0; // First token (non-USDC)
        address token1; // Second token (usually USDC)
        uint256 amount0; // LP amount of token0
        uint256 amount1; // LP amount of token1
        uint256 borrowed0; // Borrowed amount of token0
        uint256 borrowed1; // Borrowed amount of token1
        uint256 lastUpdate; // Last update timestamp
    }

    mapping(address => Position) public positions; // pool => Position
    address[] public activePositions;
    mapping(address => bool) public isActivePosition;

    // Vault addresses for borrowing
    mapping(address => address) public tokenVaults; // token => Euler vault

    // Performance tracking
    uint256 public totalValueLocked;
    uint256 public totalFeesEarned;
    mapping(address => uint256) public poolFeesEarned;

    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════

    event PositionOpened(
        address indexed pool, address indexed token0, uint256 amount0, uint256 amount1, uint256 borrowed
    );

    event PositionClosed(address indexed pool, uint256 amount0Withdrawn, uint256 amount1Withdrawn, uint256 debtRepaid);

    event PositionRebalanced(address indexed pool, int256 delta0Change, int256 delta1Change);

    event FeesCollected(address indexed pool, uint256 amount);
    event VaultRegistered(address indexed token, address indexed vault);

    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════

    error InvalidPool();
    error InsufficientLiquidity();
    error BorrowingFailed();
    error SlippageExceeded();
    error PositionNotFound();
    error VaultNotRegistered();

    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    constructor(address _vault, address _evc, address _eulerSwapFactory, address _eulerAccount, address _usdc) {
        vault = _vault;
        evc = IEVC(_evc);
        eulerSwapFactory = IEulerSwapFactory(_eulerSwapFactory);
        eulerAccount = _eulerAccount;
        usdc = _usdc;

        _setRoleAdmin(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VAULT_ROLE, _vault);
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - POSITION MANAGEMENT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Execute strategy allocations
    /// @param strategyData Encoded allocation instructions from StrategyEngine
    function executeStrategy(bytes calldata strategyData) external onlyRole(VAULT_ROLE) {
        AllocationInstruction[] memory allocations = abi.decode(strategyData, (AllocationInstruction[]));

        // Process each allocation instruction
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].shouldRebalance) {
                _rebalancePosition(allocations[i]);
            }
        }

        // Update total value locked
        _updateTVL();
    }

    /// @notice Open a new delta-neutral position
    /// @param pool EulerSwap pool address
    /// @param usdcAmount Amount of USDC to allocate
    function openPosition(address pool, uint256 usdcAmount) external onlyRole(STRATEGIST_ROLE) {
        if (!eulerSwapFactory.isValidPool(pool)) revert InvalidPool();

        IEulerSwap eulerSwap = IEulerSwap(pool);
        (address asset0, address asset1) = eulerSwap.getAssets();

        // Determine which is USDC and which needs borrowing
        bool isToken0USDC = asset0 == usdc;
        address borrowToken = isToken0USDC ? asset1 : asset0;

        // Calculate amount to borrow for delta-neutral position
        uint256 borrowAmount = _calculateBorrowAmount(borrowToken, usdcAmount, pool);

        // Execute borrow through EVC
        _borrowAsset(borrowToken, borrowAmount);

        // Add liquidity to EulerSwap
        uint256 amount0 = isToken0USDC ? usdcAmount : borrowAmount;
        uint256 amount1 = isToken0USDC ? borrowAmount : usdcAmount;

        _addLiquidity(pool, asset0, asset1, amount0, amount1);

        // Record position
        positions[pool] = Position({
            pool: pool,
            token0: asset0,
            token1: asset1,
            amount0: amount0,
            amount1: amount1,
            borrowed0: isToken0USDC ? 0 : borrowAmount,
            borrowed1: isToken0USDC ? borrowAmount : 0,
            lastUpdate: block.timestamp
        });

        if (!isActivePosition[pool]) {
            activePositions.push(pool);
            isActivePosition[pool] = true;
        }

        emit PositionOpened(pool, borrowToken, amount0, amount1, borrowAmount);
    }

    /// @notice Close a position and repay debt
    /// @param pool EulerSwap pool address
    function closePosition(address pool) external onlyRole(STRATEGIST_ROLE) {
        Position memory pos = positions[pool];
        if (pos.pool == address(0)) revert PositionNotFound();

        // Remove liquidity
        (uint256 amount0, uint256 amount1) = _removeLiquidity(pool, pos.amount0, pos.amount1);

        // Repay borrowed amounts
        if (pos.borrowed0 > 0) {
            _repayAsset(pos.token0, pos.borrowed0);
        }
        if (pos.borrowed1 > 0) {
            _repayAsset(pos.token1, pos.borrowed1);
        }

        // Clean up position
        delete positions[pool];
        _removeFromActivePositions(pool);

        emit PositionClosed(pool, amount0, amount1, pos.borrowed0 + pos.borrowed1);
    }

    /// @notice Claim all available rewards
    function claimRewards() external onlyRole(VAULT_ROLE) returns (uint256 totalRewards) {
        for (uint256 i = 0; i < activePositions.length; i++) {
            address pool = activePositions[i];
            uint256 rewards = _collectPoolFees(pool);

            if (rewards > 0) {
                poolFeesEarned[pool] += rewards;
                totalRewards += rewards;
                emit FeesCollected(pool, rewards);
            }
        }

        totalFeesEarned += totalRewards;

        // Transfer all collected rewards to vault
        if (totalRewards > 0) {
            IERC20(usdc).safeTransfer(vault, totalRewards);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - ADMIN
    // ═══════════════════════════════════════════════════════════════

    /// @notice Register an Euler vault for a token
    function registerVault(address token, address vault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenVaults[token] = vault;

        // Approve vault for operations
        IERC20(token).safeApprove(vault, type(uint256).max);

        // Enable as collateral through EVC
        evc.enableCollateral(eulerAccount, vault);

        emit VaultRegistered(token, vault);
    }

    // ═══════════════════════════════════════════════════════════════
    // PUBLIC VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get total value of all positions in USDC
    function getTotalValue() public view returns (uint256 totalValue) {
        for (uint256 i = 0; i < activePositions.length; i++) {
            Position memory pos = positions[activePositions[i]];

            // Value = LP value - borrowed value
            uint256 lpValue = _getLPValue(pos.pool);
            uint256 debtValue = _getDebtValue(pos);

            totalValue += lpValue > debtValue ? lpValue - debtValue : 0;
        }
    }

    /// @notice Get specific position details
    function getPosition(address pool) external view returns (Position memory) {
        return positions[pool];
    }

    /// @notice Get all active position addresses
    function getActivePositions() external view returns (address[] memory) {
        return activePositions;
    }

    /// @notice Check if position is healthy
    function isPositionHealthy(address pool) external view returns (bool) {
        Position memory pos = positions[pool];
        if (pos.pool == address(0)) return false;

        // Check collateral ratios for borrowed positions
        if (pos.borrowed0 > 0) {
            if (!_checkBorrowHealth(pos.token0, pos.borrowed0)) return false;
        }
        if (pos.borrowed1 > 0) {
            if (!_checkBorrowHealth(pos.token1, pos.borrowed1)) return false;
        }

        return true;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - POSITION OPERATIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Rebalance a position to maintain delta neutrality
    function _rebalancePosition(AllocationInstruction memory instruction) internal {
        Position storage pos = positions[instruction.pair];
        if (pos.pool == address(0)) return;

        // Calculate current delta
        (int256 currentDelta, uint256 targetBorrow) = _calculatePositionDelta(pos);

        // Determine rebalancing action
        if (currentDelta > 0) {
            // Too much exposure - need to borrow more
            uint256 additionalBorrow = uint256(currentDelta);
            _borrowAsset(pos.token0, additionalBorrow);
            pos.borrowed0 += additionalBorrow;
        } else if (currentDelta < 0) {
            // Too little exposure - need to repay some
            uint256 repayAmount = uint256(-currentDelta);
            _repayAsset(pos.token0, repayAmount);
            pos.borrowed0 -= repayAmount;
        }

        pos.lastUpdate = block.timestamp;

        emit PositionRebalanced(instruction.pair, currentDelta, 0);
    }

    /// @dev Add liquidity to EulerSwap pool
    function _addLiquidity(address pool, address token0, address token1, uint256 amount0, uint256 amount1) internal {
        // Transfer tokens to pool
        IERC20(token0).safeTransfer(pool, amount0);
        IERC20(token1).safeTransfer(pool, amount1);

        // Execute swap with empty data to add liquidity
        IEulerSwap(pool).swap(0, 0, address(this), "");
    }

    /// @dev Remove liquidity from pool
    function _removeLiquidity(address pool, uint256 amount0, uint256 amount1) internal returns (uint256, uint256) {
        IEulerSwap eulerSwap = IEulerSwap(pool);

        // Calculate amounts to withdraw
        (uint112 reserve0, uint112 reserve1,) = eulerSwap.getReserves();

        uint256 withdraw0 = (amount0 * reserve0) / (amount0 + amount1);
        uint256 withdraw1 = (amount1 * reserve1) / (amount0 + amount1);

        // Execute withdrawal
        eulerSwap.swap(withdraw0, withdraw1, address(this), "");

        return (withdraw0, withdraw1);
    }

    /// @dev Borrow asset through Euler vault
    function _borrowAsset(address token, uint256 amount) internal {
        address vault = tokenVaults[token];
        if (vault == address(0)) revert VaultNotRegistered();

        // Enable controller for borrowing
        evc.enableController(eulerAccount, vault);

        // Execute borrow through EVC
        bytes memory data = abi.encodeCall(IEVault.borrow, (amount, address(this)));

        evc.call(vault, eulerAccount, 0, data);
    }

    /// @dev Repay borrowed asset
    function _repayAsset(address token, uint256 amount) internal {
        address vault = tokenVaults[token];
        if (vault == address(0)) revert VaultNotRegistered();

        // Approve vault for repayment
        IERC20(token).safeApprove(vault, amount);

        // Repay through vault
        IEVault(vault).repay(amount, eulerAccount);

        // Disable controller if no debt remains
        if (IEVault(vault).debtOf(eulerAccount) == 0) {
            evc.disableController(eulerAccount);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - CALCULATIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Calculate borrow amount for delta-neutral position
    function _calculateBorrowAmount(address borrowToken, uint256 usdcAmount, address pool)
        internal
        view
        returns (uint256)
    {
        // Get current price from pool
        IEulerSwap eulerSwap = IEulerSwap(pool);
        uint256 price = eulerSwap.computeQuote(usdc, borrowToken, usdcAmount, true);

        // For delta-neutral, borrow half the value in the other token
        return price / 2;
    }

    /// @dev Calculate position delta and target borrow amount
    function _calculatePositionDelta(Position memory pos) internal view returns (int256 delta, uint256 targetBorrow) {
        // Get current LP value
        uint256 lpValue = _getLPValue(pos.pool);

        // Calculate current exposure
        uint256 token0Exposure = (lpValue * pos.amount0) / (pos.amount0 + pos.amount1);

        // Delta = exposure - borrowed
        delta = int256(token0Exposure) - int256(pos.borrowed0);

        // Target is to have borrowed = exposure for neutrality
        targetBorrow = token0Exposure;
    }

    /// @dev Get LP position value in USDC
    function _getLPValue(address pool) internal view returns (uint256) {
        IEulerSwap eulerSwap = IEulerSwap(pool);
        (uint112 reserve0, uint112 reserve1,) = eulerSwap.getReserves();

        // Simplified: assume reserve1 is USDC
        return uint256(reserve1) * 2; // Total value is 2x USDC reserves
    }

    /// @dev Get debt value in USDC
    function _getDebtValue(Position memory pos) internal view returns (uint256) {
        uint256 debtValue;

        if (pos.borrowed0 > 0) {
            // Convert token0 debt to USDC value
            IEulerSwap eulerSwap = IEulerSwap(pos.pool);
            debtValue += eulerSwap.computeQuote(pos.token0, usdc, pos.borrowed0, true);
        }

        if (pos.borrowed1 > 0) {
            debtValue += pos.borrowed1; // Already in USDC
        }

        return debtValue;
    }

    /// @dev Check if borrow position is healthy
    function _checkBorrowHealth(address token, uint256 borrowed) internal view returns (bool) {
        address vault = tokenVaults[token];
        if (vault == address(0)) return false;

        // Check health factor
        uint256 collateral = IEVault(vault).convertToAssets(IEVault(vault).balanceOf(eulerAccount));

        // Require at least 1.5x collateral
        return collateral >= (borrowed * 150) / 100;
    }

    /// @dev Collect fees from a pool
    function _collectPoolFees(address pool) internal returns (uint256) {
        // Implementation depends on EulerSwap fee collection mechanism
        // This is a placeholder
        return 0;
    }

    /// @dev Update total value locked
    function _updateTVL() internal {
        totalValueLocked = getTotalValue();
    }

    /// @dev Remove pool from active positions array
    function _removeFromActivePositions(address pool) internal {
        for (uint256 i = 0; i < activePositions.length; i++) {
            if (activePositions[i] == pool) {
                activePositions[i] = activePositions[activePositions.length - 1];
                activePositions.pop();
                isActivePosition[pool] = false;
                break;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════

    struct AllocationInstruction {
        address pair;
        uint256 targetAllocation;
        bool shouldRebalance;
    }
}
