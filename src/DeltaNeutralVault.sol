// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IERC20Metadata} from "openzeppelin-contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IEVC} from "evc/interfaces/IEthereumVaultConnector.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IRiskManager} from "./interfaces/IRiskManager.sol";
import {IStrategyEngine} from "./interfaces/IStrategyEngine.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";

/// @title Delta-Neutral Pooled Vault
/// @notice ERC4626 vault that maintains delta-neutral LP positions across multiple pairs
/// @dev Integrates with EulerSwap and Euler lending markets for automated hedging
contract DeltaNeutralVault is ERC20, ERC4626, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using CustomRevert for bytes4;
    using Math for uint256;

    // ═══════════════════════════════════════════════════════════════
    // CONSTANTS & IMMUTABLES
    // ═══════════════════════════════════════════════════════════════

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    uint256 public constant MAX_PERFORMANCE_FEE = 3000; // 30%
    uint256 public constant MAX_MANAGEMENT_FEE = 200; // 2%
    uint256 public constant FEE_DENOMINATOR = 10000;
    uint256 public constant WITHDRAWAL_DELAY = 24 hours;

    IEVC public immutable evc;
    address public immutable eulerAccount;

    // ═══════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════

    // Core components
    IStrategyEngine public strategyEngine;
    IPositionManager public positionManager;
    IRiskManager public riskManager;

    // Fee structure
    uint256 public performanceFee = 1500; // 15%
    uint256 public managementFee = 50; // 0.5%
    uint256 public lastManagementFeeCollection;

    // Withdrawal queue
    struct WithdrawalRequest {
        uint256 shares;
        uint256 requestTime;
        bool processed;
    }

    mapping(address => WithdrawalRequest[]) public withdrawalQueue;
    mapping(address => uint256) public pendingWithdrawals;

    // Performance tracking
    uint256 public lastHarvestTime;
    uint256 public lastTotalAssets;
    uint256 public totalPerformanceFees;
    uint256 public totalManagementFees;

    // Epoch management for rebalancing
    uint256 public currentEpoch;
    mapping(uint256 => uint256) public epochReturns;

    address public owner;

    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════

    event StrategyUpdated(address indexed oldStrategy, address indexed newStrategy);
    event Rebalanced(uint256 indexed epoch, int256 deltaBefore, int256 deltaAfter);
    event FeesHarvested(uint256 performanceFees, uint256 managementFees);
    event WithdrawalQueued(address indexed user, uint256 shares, uint256 requestId);
    event WithdrawalProcessed(address indexed user, uint256 shares, uint256 assets);
    event EmergencyWithdraw(address indexed user, uint256 assets);

    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════

    error InvalidConfiguration();
    error WithdrawalTooEarly();
    error InsufficientLiquidity();
    error HealthCheckFailed();
    error RebalanceNotNeeded();
    error StrategyExecutionFailed();

    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    constructor(IERC20 _asset, string memory _name, string memory _symbol, address _evc, address _eulerAccount)
        ERC4626(_asset)
        ERC20(_name, _symbol)
    {
        evc = IEVC(_evc);
        eulerAccount = _eulerAccount;

        // _setRoleAdmin(DEFAULT_ADMIN_ROLE, msg.sender);
        // _grantRole(GUARDIAN_ROLE, msg.sender);

        lastManagementFeeCollection = block.timestamp;
        lastHarvestTime = block.timestamp;

        // Approve EVC for operations
        _asset.forceApprove(_evc, type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - USER INTERACTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Deposit assets and receive vault shares
    /// @param assets Amount of assets to deposit
    /// @param receiver Address to receive shares
    /// @return shares Amount of shares minted
    function deposit(uint256 assets, address receiver) public override whenNotPaused returns (uint256 shares) {
        // Collect management fees before deposit to ensure fair share price
        _collectManagementFees();

        shares = super.deposit(assets, receiver);

        // Deploy capital immediately if strategy is set
        if (address(positionManager) != address(0)) {
            _deployCapital();
        }
    }

    /// @notice Request withdrawal of shares
    /// @param shares Amount of shares to withdraw
    function requestWithdrawal(uint256 shares) external {
        if (shares > balanceOf(msg.sender) - pendingWithdrawals[msg.sender]) {
            revert InsufficientLiquidity();
        }

        withdrawalQueue[msg.sender].push(
            WithdrawalRequest({shares: shares, requestTime: block.timestamp, processed: false})
        );

        pendingWithdrawals[msg.sender] += shares;

        emit WithdrawalQueued(msg.sender, shares, withdrawalQueue[msg.sender].length - 1);
    }

    /// @notice Process matured withdrawal requests
    function processWithdrawals() external {
        WithdrawalRequest[] storage requests = withdrawalQueue[msg.sender];
        uint256 totalShares;
        uint256 totalAssets;

        for (uint256 i = 0; i < requests.length; i++) {
            if (!requests[i].processed && block.timestamp >= requests[i].requestTime + WITHDRAWAL_DELAY) {
                uint256 assets = convertToAssets(requests[i].shares);
                totalShares += requests[i].shares;
                totalAssets += assets;
                requests[i].processed = true;
            }
        }

        if (totalShares == 0) revert WithdrawalTooEarly();

        pendingWithdrawals[msg.sender] -= totalShares;

        // Burn shares and transfer assets
        _burn(msg.sender, totalShares);
        IERC20(asset()).safeTransfer(msg.sender, totalAssets);

        emit WithdrawalProcessed(msg.sender, totalShares, totalAssets);
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - KEEPER OPERATIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Harvest yields from all positions
    function harvest() external onlyRole(KEEPER_ROLE) {
        uint256 rewards = positionManager.claimRewards();

        if (rewards > 0) {
            uint256 perfFee = (rewards * performanceFee) / FEE_DENOMINATOR;
            totalPerformanceFees += perfFee;

            emit FeesHarvested(perfFee, 0);
        }

        lastHarvestTime = block.timestamp;
    }

    /// @notice Rebalance positions to maintain delta neutrality
    function rebalance() external onlyRole(STRATEGIST_ROLE) {
        if (!strategyEngine.shouldRebalance()) revert RebalanceNotNeeded();

        // Check health before rebalancing
        if (!riskManager.checkHealthFactors()) revert HealthCheckFailed();

        int256 deltaBefore = strategyEngine.getDeltaExposure();

        // Calculate and execute new allocations
        bytes memory strategyData = strategyEngine.calculateOptimalAllocations();

        // Verify rebalance safety
        if (!riskManager.isRebalanceSafe(strategyData)) revert HealthCheckFailed();

        // Execute through position manager
        positionManager.executeStrategy(strategyData);

        int256 deltaAfter = strategyEngine.getDeltaExposure();

        currentEpoch++;
        emit Rebalanced(currentEpoch, deltaBefore, deltaAfter);
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - ADMIN
    // ═══════════════════════════════════════════════════════════════

    /// @notice Update strategy engine
    function setStrategyEngine(address _strategyEngine) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit StrategyUpdated(address(strategyEngine), _strategyEngine);
        strategyEngine = IStrategyEngine(_strategyEngine);
    }

    /// @notice Update position manager
    function setPositionManager(address _positionManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        positionManager = IPositionManager(_positionManager);

        // Grant necessary permissions through EVC
        evc.setAccountOperator(eulerAccount, _positionManager, true);
    }

    /// @notice Update risk manager
    function setRiskManager(address _riskManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        riskManager = IRiskManager(_riskManager);
    }

    /// @notice Update fee structure
    function setFees(uint256 _performanceFee, uint256 _managementFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_performanceFee > MAX_PERFORMANCE_FEE || _managementFee > MAX_MANAGEMENT_FEE) {
            revert InvalidConfiguration();
        }

        // Collect existing fees before update
        _collectManagementFees();

        performanceFee = _performanceFee;
        managementFee = _managementFee;
    }

    /// @notice Emergency pause
    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @notice Unpause
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════
    // PUBLIC VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get total assets under management
    function totalAssets() public view override returns (uint256) {
        if (address(positionManager) == address(0)) {
            return IERC20(asset()).balanceOf(address(this));
        }

        return IERC20(asset()).balanceOf(address(this)) + positionManager.getTotalValue();
    }

    /// @notice Get user's total balance including pending withdrawals
    function getTotalUserBalance(address user) external view returns (uint256) {
        return balanceOf(user) + pendingWithdrawals[user];
    }

    /// @notice Get current delta exposure
    function getCurrentDelta() external view returns (int256) {
        if (address(strategyEngine) == address(0)) return 0;
        return strategyEngine.getDeltaExposure();
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Deploy idle capital according to strategy
    function _deployCapital() internal {
        uint256 idleBalance = IERC20(asset()).balanceOf(address(this));

        // Keep some buffer for withdrawals
        uint256 buffer = totalAssets() / 20; // 5% buffer

        if (idleBalance > buffer) {
            uint256 toDeploy = idleBalance - buffer;
            IERC20(asset()).safeTransfer(address(positionManager), toDeploy);

            // Execute deployment through position manager
            bytes memory strategyData = strategyEngine.calculateOptimalAllocations();
            positionManager.executeStrategy(strategyData);
        }
    }

    /// @dev Collect management fees
    function _collectManagementFees() internal {
        uint256 timePassed = block.timestamp - lastManagementFeeCollection;
        uint256 feeAmount = (totalAssets() * managementFee * timePassed) / (FEE_DENOMINATOR * 365 days);

        if (feeAmount > 0) {
            totalManagementFees += feeAmount;
            // Mint fee shares to treasury
            _mint(owner, convertToShares(feeAmount));
        }

        lastManagementFeeCollection = block.timestamp;
    }
    // function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /// @dev Override transfer to handle pending withdrawals
    function _beforeTokenTransfer(address from, address, uint256 amount) internal virtual {
        // super._beforeTokenTransfer(from, to, amount);

        // Ensure user can't transfer shares that are pending withdrawal
        if (from != address(0)) {
            // Not minting
            require(balanceOf(from) - pendingWithdrawals[from] >= amount, "Shares locked in withdrawal");
        }
    }

    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return IERC20Metadata(asset()).decimals();
    }
}
