// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault, IBorrowing, IERC4626} from "evk/EVault/IEVault.sol";
import {IEulerSwap} from "./interfaces/IEulerSwap.sol";
import {IEulerSwapFactory} from "./interfaces/IEulerSwapFactory.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";
import {Roles} from "./abstract/Roles.sol";
import {console} from "forge-std/console.sol";
import {IPriceOracle} from "./interfaces/IOracle.sol";

/// @title Position Manager for Delta-Neutral Vaults
contract PositionManager is Roles {
    using SafeERC20 for IERC20;
    using CustomRevert for bytes4;

    // CONSTANTS & IMMUTABLES

    uint256 private constant MAX_SLIPPAGE = 200; // 2%
    uint256 private constant SLIPPAGE_DENOMINATOR = 10000;

    IEVC public immutable evc;
    IEulerSwapFactory public immutable eulerSwapFactory;
    address public immutable eulerAccount;
    address public immutable vault;
    address public immutable usdc; // Base asset
    address public immutable priceOracle;

    // STRUCTS

    struct AllocationInstruction {
        address pair;
        uint256 targetAllocation;
        bool shouldRebalance;
    }

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

    // EVENTS

    event PositionOpened(
        address indexed pool, address indexed token0, uint256 amount0, uint256 amount1, uint256 borrowed
    );

    event PositionClosed(address indexed pool, uint256 amount0Withdrawn, uint256 amount1Withdrawn, uint256 debtRepaid);

    event PositionRebalanced(address indexed pool, int256 delta0Change, int256 delta1Change);

    event FeesCollected(address indexed pool, uint256 amount);
    event VaultRegistered(address indexed token, address indexed vault);

    // ERRORS

    error InvalidPool();
    error InsufficientLiquidity();
    error BorrowingFailed();
    error SlippageExceeded();
    error PositionNotFound();
    error VaultNotRegistered();

    // CONSTRUCTOR

    constructor(
        address _vault,
        address _evc,
        address _eulerSwapFactory,
        address _eulerAccount,
        address _usdc,
        address _accessRegistry,
        address _priceOracle
    ) Roles(_accessRegistry) {
        vault = _vault;
        priceOracle = _priceOracle;
        evc = IEVC(_evc);
        eulerSwapFactory = IEulerSwapFactory(_eulerSwapFactory);
        eulerAccount = _eulerAccount;
        usdc = _usdc;
    }

    function executeStrategy(bytes calldata strategyData) external onlyVault {
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

    function openPosition(address pool, uint256 usdcAmount) external onlyStrategist {
        IEulerSwap eulerSwap = IEulerSwap(pool);
        (address asset0, address asset1) = eulerSwap.getAssets();

        bool isToken0USDC = asset0 == usdc;
        address borrowToken = isToken0USDC ? asset1 : asset0;

        address usdcVault = tokenVaults[usdc];
        require(usdcVault != address(0), "USDC vault not registered");

        // Approve and deposit USDC to Euler
        IERC20(usdc).forceApprove(usdcVault, usdcAmount);
        IEVault(usdcVault).deposit(usdcAmount, eulerAccount);

        // Enable USDC vault as collateral
        evc.enableCollateral(eulerAccount, usdcVault);

        // Calculate amount to borrow
        uint256 borrowAmount = _calculateBorrowAmount(borrowToken, usdcAmount, pool);

        // Enable the borrow vault as controller
        address borrowVault = tokenVaults[borrowToken];
        evc.enableController(eulerAccount, borrowVault);

        // Now borrow 
        bytes memory borrowData = abi.encodeWithSelector(IBorrowing.borrow.selector, borrowAmount, address(this));
        evc.call(borrowVault, eulerAccount, 0, borrowData);


        // Record position
        positions[pool] = Position({
            pool: pool,
            token0: asset0,
            token1: asset1,
            amount0: isToken0USDC ? usdcAmount : borrowAmount,
            amount1: isToken0USDC ? borrowAmount : usdcAmount,
            borrowed0: isToken0USDC ? 0 : borrowAmount,
            borrowed1: isToken0USDC ? borrowAmount : 0,
            lastUpdate: block.timestamp
        });

        if (!isActivePosition[pool]) {
            activePositions.push(pool);
            isActivePosition[pool] = true;
        }

        emit PositionOpened(pool, borrowToken, usdcAmount, borrowAmount, borrowAmount);
    }

    function closePosition(address pool) external onlyStrategist {
        Position memory pos = positions[pool];
        if (pos.pool == address(0)) revert PositionNotFound();

        // 1. Repay borrowed amounts first
        if (pos.borrowed0 > 0) {
            _repayAsset(pos.token0, pos.borrowed0);
        }
        if (pos.borrowed1 > 0) {
            _repayAsset(pos.token1, pos.borrowed1);
        }

        // 2. Withdraw USDC collateral from Euler
        address usdcVault = tokenVaults[usdc];
        uint256 shares = IEVault(usdcVault).balanceOf(eulerAccount);
        if (shares > 0) {
            uint256 assets = IEVault(usdcVault).convertToAssets(shares);

            // Withdraw through EVC
            bytes memory withdrawData =
                abi.encodeWithSelector(IERC4626.withdraw.selector, assets, address(this), eulerAccount);
            evc.call(usdcVault, eulerAccount, 0, withdrawData);
        }

        // 3. Transfer all USDC back to vault
        uint256 usdcBalance = IERC20(usdc).balanceOf(address(this));
        if (usdcBalance > 0) {
            IERC20(usdc).safeTransfer(vault, usdcBalance);
        }

        // 4. Handle any remaining borrowed assets (profit/loss from price movements)
        if (pos.token1 != usdc) {
            uint256 token1Balance = IERC20(pos.token1).balanceOf(address(this));
            if (token1Balance > 0) {
                // Could swap to USDC here, or just transfer to vault
                IERC20(pos.token1).safeTransfer(vault, token1Balance);
            }
        }

        // Clean up position
        delete positions[pool];
        _removeFromActivePositions(pool);

        emit PositionClosed(pool, pos.amount0, pos.amount1, pos.borrowed0 + pos.borrowed1);
    }

    function claimRewards() external onlyVault returns (uint256 totalRewards) {
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
            IERC20(usdc).approve(vault, totalRewards);
        }
    }

    function registerVault(address token, address vault) external onlyAdmin {
        tokenVaults[token] = vault;

        // Approve vault for operations
        IERC20(token).forceApprove(vault, type(uint256).max);

        // Enable as collateral through EVC
        evc.enableCollateral(eulerAccount, vault);

        emit VaultRegistered(token, vault);
    }

    // Fix getTotalValue to properly calculate net position value:
    function getTotalValue() public view returns (uint256 totalValue) {
        // Add idle USDC first
        totalValue = IERC20(usdc).balanceOf(address(this));

        // For each position, calculate net value
        for (uint256 i = 0; i < activePositions.length; i++) {
            Position memory pos = positions[activePositions[i]];

            // Get collateral value (USDC deposited with interest)
            address usdcVault = tokenVaults[usdc];
            // Note: This gets ALL shares, so divide by number of positions if needed
            uint256 shares = IEVault(usdcVault).balanceOf(eulerAccount);
            uint256 collateralValue = 0;
            if (shares > 0 && activePositions.length > 0) {
                collateralValue = IEVault(usdcVault).convertToAssets(shares) / activePositions.length;
            }

            // Get debt value
            address borrowVault = tokenVaults[pos.borrowed1 > 0 ? pos.token1 : pos.token0];
            uint256 debtAmount = 0;
            if (borrowVault != address(0)) {
                // Similar issue - total debt divided by positions
                uint256 totalDebt = IEVault(borrowVault).debtOf(eulerAccount);
                if (activePositions.length > 0) {
                    debtAmount = totalDebt / activePositions.length;
                }
            }

            // Convert debt to USDC value
            address borrowedToken = pos.borrowed1 > 0 ? pos.token1 : pos.token0;
            uint256 debtInUsdc = 0;
            if (debtAmount > 0 && borrowedToken != usdc) {
                uint256 tokenPrice = IPriceOracle(address(priceOracle)).getPrice(borrowedToken);
                debtInUsdc = (debtAmount * tokenPrice) / 1e18;
            }

            // Add net value (collateral - debt)
            if (collateralValue > debtInUsdc) {
                totalValue += collateralValue - debtInUsdc;
            }
        }

        return totalValue;
    }

    function getPosition(address pool) external view returns (Position memory) {
        return positions[pool];
    }

    function getActivePositions() external view returns (address[] memory) {
        return activePositions;
    }

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

    function _rebalancePosition(AllocationInstruction memory instruction) internal {
        Position storage pos = positions[instruction.pair];
        if (pos.pool == address(0)) return;

        // Calculate current delta
        (int256 currentDelta,) = _calculatePositionDelta(pos);

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

    function _borrowAsset(address token, uint256 amount) internal {
        address vault = tokenVaults[token];
        if (vault == address(0)) revert VaultNotRegistered();

        // Enable controller for borrowing
        evc.enableController(eulerAccount, vault);
        console.log("controller enabled");

        // Execute borrow through EVC
        bytes memory data = abi.encodeWithSelector(IBorrowing.borrow.selector, amount, address(this));

        evc.call(vault, eulerAccount, 0, data);
        console.log("borrowed");
    }

    function _repayAsset(address token, uint256 amount) internal {
        address vault = tokenVaults[token];
        if (vault == address(0)) revert VaultNotRegistered();

        // Approve vault for repayment
        IERC20(token).forceApprove(vault, amount);

        // Repay through vault
        IEVault(vault).repay(amount, eulerAccount);

        // Disable controller if no debt remains
        if (IEVault(vault).debtOf(eulerAccount) == 0) {
            evc.disableController(eulerAccount);
        }
    }

    //  _calculateBorrowAmount to use oracle prices :
    function _calculateBorrowAmount(address borrowToken, uint256 usdcAmount, address) internal view returns (uint256) {
        // Get price from oracle (not from pool)
        uint256 tokenPrice = IPriceOracle(address(priceOracle)).getPrice(borrowToken);

        // For delta neutral, borrow equal USD value
        // tokenPrice is in USDC terms with 18 decimals
        // So if ETH = $2000, tokenPrice = 2000e18
        return (usdcAmount * 1e18) / tokenPrice;
    }

    function _calculatePositionDelta(Position memory pos) internal view returns (int256 delta, uint256 targetBorrow) {
        // Get current LP value
        uint256 lpValue = _getLPValue(pos);

        // Calculate current exposure
        uint256 token0Exposure = (lpValue * pos.amount0) / (pos.amount0 + pos.amount1);

        // Delta = exposure - borrowed
        delta = int256(token0Exposure) - int256(pos.borrowed0);

        // Target is to have borrowed = exposure for neutrality
        targetBorrow = token0Exposure;
    }

    function _getLPValue(Position memory pos) internal view returns (uint256) {
        IEulerSwap eulerSwap = IEulerSwap(pos.pool);
        (uint112 reserve0, uint112 reserve1,) = eulerSwap.getReserves();

        // Get the total LP token supply (this represents total liquidity)
        // For Euler pools, the LP value is proportional to reserves

        // Calculate our share of the pool
        // Our LP tokens = amount0 + amount1 we provided
        uint256 totalLiquidity = uint256(reserve0) + uint256(reserve1);
        uint256 ourLiquidity = pos.amount0 + pos.amount1;

        // Calculate our share of each reserve
        uint256 ourReserve0 = (uint256(reserve0) * ourLiquidity) / totalLiquidity;
        uint256 ourReserve1 = (uint256(reserve1) * ourLiquidity) / totalLiquidity;

        // Convert to USDC value
        uint256 value0InUsdc;
        uint256 value1InUsdc;

        if (pos.token0 == usdc) {
            value0InUsdc = ourReserve0;
            // Need to convert token1 to USDC using pool price
            value1InUsdc = eulerSwap.computeQuote(pos.token1, usdc, ourReserve1, true);
        } else {
            // token1 is USDC
            value1InUsdc = ourReserve1;
            // Convert token0 to USDC
            value0InUsdc = eulerSwap.computeQuote(pos.token0, usdc, ourReserve0, true);
        }

        return value0InUsdc + value1InUsdc;
    }

    function _getDebtValue(Position memory pos) internal view returns (uint256) {
        uint256 debtValue;

        if (pos.borrowed0 > 0) {
            if (pos.token0 == usdc) {
                debtValue += pos.borrowed0;
            } else {
                // Convert token0 debt to USDC value
                IEulerSwap eulerSwap = IEulerSwap(pos.pool);
                debtValue += eulerSwap.computeQuote(pos.token0, usdc, pos.borrowed0, true);
            }
        }

        if (pos.borrowed1 > 0) {
            if (pos.token1 == usdc) {
                debtValue += pos.borrowed1;
            } else {
                // Convert token1 debt to USDC value
                IEulerSwap eulerSwap = IEulerSwap(pos.pool);
                debtValue += eulerSwap.computeQuote(pos.token1, usdc, pos.borrowed1, true);
            }
        }

        // Add interest accrued on borrowed amounts
        // This would need to query the actual debt from Euler vaults
        // For now, we'll add a small buffer
        return debtValue * 101 / 100; // 1% buffer for interest
    }

    function _checkBorrowHealth(address token, uint256 borrowed) internal view returns (bool) {
        address vault = tokenVaults[token];
        if (vault == address(0)) return false;

        // Check health factor
        uint256 collateral = IEVault(vault).convertToAssets(IEVault(vault).balanceOf(eulerAccount));

        // Require at least 1.5x collateral
        return collateral >= (borrowed * 150) / 100;
    }

    function _collectPoolFees(address) internal returns (uint256) {
        // Implementation depends on EulerSwap fee collection mechanism
        // This is a placeholder
        return 0;
    }

    function _updateTVL() internal {
        totalValueLocked = getTotalValue();
    }

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
}
