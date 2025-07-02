// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {IEVault} from "evk/EVault/IEVault.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {IPriceOracle, IVolatilityOracle} from "./interfaces/IOracle.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";

/// @title Risk Manager for Delta-Neutral Vaults
/// @notice Monitors and mitigates various risks including liquidation, oracle, and market risks
contract RiskManager is AccessControl {
    using Math for uint256;
    using CustomRevert for bytes4;

    // ═══════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    uint256 public constant MIN_HEALTH_FACTOR = 150; // 1.5x
    uint256 public constant CRITICAL_HEALTH_FACTOR = 120; // 1.2x
    uint256 public constant MAX_SLIPPAGE = 500; // 5%
    uint256 public constant MAX_SINGLE_POSITION = 30; // 30% of portfolio
    uint256 public constant DENOMINATOR = 100;

    // Circuit breaker thresholds
    uint256 public constant MAX_DAILY_DRAWDOWN = 10; // 10%
    uint256 public constant MAX_HOURLY_VOLATILITY = 5; // 5%
    uint256 public constant ORACLE_DEVIATION_THRESHOLD = 3; // 3%

    // ═══════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════

    // Core contracts
    IPositionManager public positionManager;
    IPriceOracle public priceOracle;
    IVolatilityOracle public volatilityOracle;
    address public vault;

    // Risk parameters
    struct RiskParams {
        uint256 maxLeverage; // Maximum allowed leverage
        uint256 minCollateralRatio; // Minimum collateral ratio
        uint256 maxPositionConcentration; // Max % in single position
        uint256 maxCorrelation; // Max correlation between assets
        uint256 emergencyDeleverageRatio; // Ratio to trigger emergency deleverage
    }

    RiskParams public riskParams;

    // Circuit breaker state
    struct CircuitBreaker {
        bool isTripped;
        uint256 tripTime;
        string reason;
        uint256 cooldownPeriod;
    }

    CircuitBreaker public circuitBreaker;

    // Risk monitoring state
    mapping(address => PositionRisk) public positionRisks;
    mapping(address => uint256) public tokenVolatilities;

    struct PositionRisk {
        uint256 healthFactor;
        uint256 liquidationPrice;
        uint256 exposure;
        uint256 lastCheck;
        bool isHighRisk;
    }

    // Historical tracking for circuit breakers
    uint256 public lastPortfolioValue;
    uint256 public lastHourValue;
    uint256 public lastDayValue;
    mapping(uint256 => uint256) public hourlyValues; // hour => value
    mapping(uint256 => uint256) public dailyValues; // day => value

    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════

    event RiskCheckPerformed(uint256 timestamp, bool passed);
    event HighRiskPositionDetected(address indexed position, uint256 healthFactor);
    event CircuitBreakerTripped(string reason, uint256 duration);
    event CircuitBreakerReset();
    event EmergencyDeleverageTriggered(address indexed position, uint256 amount);
    event RiskParamsUpdated(RiskParams params);

    // ═══════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════

    error CircuitBreakerActive();
    error HealthFactorTooLow();
    error ExcessiveLeverage();
    error PositionTooConcentrated();
    error OracleManipulationDetected();
    error VolatilityTooHigh();

    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    constructor(address _vault, address _positionManager, address _priceOracle, address _volatilityOracle) {
        vault = _vault;
        positionManager = IPositionManager(_positionManager);
        priceOracle = IPriceOracle(_priceOracle);
        volatilityOracle = IVolatilityOracle(_volatilityOracle);

        _setRoleAdmin(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(VAULT_ROLE, _vault);

        // Initialize default risk parameters
        riskParams = RiskParams({
            maxLeverage: 300, // 3x max
            minCollateralRatio: 150, // 150%
            maxPositionConcentration: 30, // 30%
            maxCorrelation: 70, // 70%
            emergencyDeleverageRatio: 120 // 120%
        });

        // Initialize tracking
        lastPortfolioValue = 0;
        lastHourValue = 0;
        lastDayValue = 0;
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - RISK CHECKS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Check health factors for all positions
    function checkHealthFactors() external view onlyRole(VAULT_ROLE) returns (bool allHealthy) {
        if (circuitBreaker.isTripped) revert CircuitBreakerActive();

        address[] memory positions = positionManager.getActivePositions();
        allHealthy = true;

        for (uint256 i = 0; i < positions.length; i++) {
            uint256 healthFactor = _calculateHealthFactor(positions[i]);

            if (healthFactor < MIN_HEALTH_FACTOR) {
                allHealthy = false;
                break;
            }
        }

        return allHealthy;
    }

    /// @notice Check if rebalance operation is safe
    function isRebalanceSafe(bytes calldata rebalanceData) external view onlyRole(VAULT_ROLE) returns (bool) {
        if (circuitBreaker.isTripped) return false;

        // Decode rebalance instructions
        IPositionManager.AllocationInstruction[] memory allocations =
            abi.decode(rebalanceData, (IPositionManager.AllocationInstruction[]));

        // Check each allocation
        for (uint256 i = 0; i < allocations.length; i++) {
            if (!_isAllocationSafe(allocations[i])) {
                return false;
            }
        }

        // Check oracle health
        if (_detectOracleManipulation()) {
            return false;
        }

        // Check market conditions
        if (_isMarketVolatilityExcessive()) {
            return false;
        }

        return true;
    }

    /// @notice Perform comprehensive risk assessment
    function performRiskAssessment() external {
        // Update portfolio tracking
        uint256 currentValue = positionManager.getTotalValue();
        _updatePortfolioTracking(currentValue);

        // Check for circuit breaker conditions
        _checkCircuitBreakerConditions(currentValue);

        // Assess each position
        address[] memory positions = positionManager.getActivePositions();

        for (uint256 i = 0; i < positions.length; i++) {
            _assessPositionRisk(positions[i]);
        }

        emit RiskCheckPerformed(block.timestamp, !circuitBreaker.isTripped);
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - EMERGENCY ACTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Trigger emergency deleverage for critical positions
    function emergencyDeleverage(address position) external onlyRole(GUARDIAN_ROLE) {
        PositionRisk memory risk = positionRisks[position];

        if (risk.healthFactor >= CRITICAL_HEALTH_FACTOR) {
            revert HealthFactorTooLow();
        }

        // Calculate deleverage amount
        uint256 deleverageAmount = _calculateDeleverageAmount(position);

        // Execute emergency deleverage through position manager
        positionManager.emergencyDeleverage(position, deleverageAmount);

        emit EmergencyDeleverageTriggered(position, deleverageAmount);
    }

    /// @notice Trip circuit breaker manually
    function tripCircuitBreaker(string calldata reason) external onlyRole(GUARDIAN_ROLE) {
        circuitBreaker =
            CircuitBreaker({isTripped: true, tripTime: block.timestamp, reason: reason, cooldownPeriod: 4 hours});

        emit CircuitBreakerTripped(reason, 4 hours);
    }

    /// @notice Reset circuit breaker after cooldown
    function resetCircuitBreaker() external onlyRole(GUARDIAN_ROLE) {
        require(block.timestamp >= circuitBreaker.tripTime + circuitBreaker.cooldownPeriod, "Cooldown not complete");

        circuitBreaker.isTripped = false;
        emit CircuitBreakerReset();
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - ADMIN
    // ═══════════════════════════════════════════════════════════════

    /// @notice Update risk parameters
    function updateRiskParams(RiskParams calldata newParams) external onlyRole(DEFAULT_ADMIN_ROLE) {
        riskParams = newParams;
        emit RiskParamsUpdated(newParams);
    }

    // ═══════════════════════════════════════════════════════════════
    // PUBLIC VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get current portfolio risk metrics
    function getPortfolioRiskMetrics()
        external
        view
        returns (uint256 totalLeverage, uint256 avgHealthFactor, uint256 portfolioVolatility, bool hasHighRiskPositions)
    {
        address[] memory positions = positionManager.getActivePositions();
        uint256 totalValue = positionManager.getTotalValue();
        uint256 totalDebt;
        uint256 sumHealthFactors;

        for (uint256 i = 0; i < positions.length; i++) {
            IPositionManager.Position memory pos = positionManager.getPosition(positions[i]);

            // Calculate metrics
            totalDebt += _getPositionDebt(pos);
            sumHealthFactors += _calculateHealthFactor(positions[i]);

            if (positionRisks[positions[i]].isHighRisk) {
                hasHighRiskPositions = true;
            }
        }

        totalLeverage = totalValue > 0 ? (totalDebt * 100) / totalValue : 0;
        avgHealthFactor = positions.length > 0 ? sumHealthFactors / positions.length : 200;
        portfolioVolatility = _calculatePortfolioVolatility();
    }

    /// @notice Check if position is at risk of liquidation
    function isPositionAtRisk(address position) external view returns (bool) {
        uint256 healthFactor = _calculateHealthFactor(position);
        return healthFactor < MIN_HEALTH_FACTOR;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - RISK CALCULATIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Calculate health factor for a position
    function _calculateHealthFactor(address position) internal view returns (uint256) {
        IPositionManager.Position memory pos = positionManager.getPosition(position);

        if (pos.pool == address(0)) return 200; // Default healthy

        // Get collateral value
        uint256 collateralValue = _getPositionCollateralValue(pos);

        // Get debt value
        uint256 debtValue = _getPositionDebt(pos);

        if (debtValue == 0) return 200; // No debt = healthy

        return (collateralValue * 100) / debtValue;
    }

    /// @dev Calculate liquidation price for a position
    function _calculateLiquidationPrice(address position) internal view returns (uint256) {
        IPositionManager.Position memory pos = positionManager.getPosition(position);

        // Simplified: liquidation when value drops 20%
        uint256 currentPrice = priceOracle.getPrice(pos.token0);
        return (currentPrice * 80) / 100;
    }

    /// @dev Check if allocation is safe
    function _isAllocationSafe(IPositionManager.AllocationInstruction memory allocation) internal view returns (bool) {
        // Check concentration
        uint256 totalValue = positionManager.getTotalValue();
        uint256 allocationValue = (totalValue * allocation.targetAllocation) / 1e18;

        if (allocationValue > (totalValue * riskParams.maxPositionConcentration) / 100) {
            return false;
        }

        // Check leverage
        IPositionManager.Position memory pos = positionManager.getPosition(allocation.pair);

        uint256 leverage = _calculatePositionLeverage(pos);
        if (leverage > riskParams.maxLeverage) {
            return false;
        }

        return true;
    }

    /// @dev Detect potential oracle manipulation
    function _detectOracleManipulation() internal view returns (bool) {
        address[] memory positions = positionManager.getActivePositions();

        for (uint256 i = 0; i < positions.length; i++) {
            IPositionManager.Position memory pos = positionManager.getPosition(positions[i]);

            if (priceOracle.isManipulated(pos.token0) || priceOracle.isManipulated(pos.token1)) {
                return true;
            }
        }

        return false;
    }

    /// @dev Check if market volatility is excessive
    function _isMarketVolatilityExcessive() internal view returns (bool) {
        uint256 portfolioVol = _calculatePortfolioVolatility();
        return portfolioVol > MAX_HOURLY_VOLATILITY;
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - TRACKING & MONITORING
    // ═══════════════════════════════════════════════════════════════

    /// @dev Update portfolio value tracking
    function _updatePortfolioTracking(uint256 currentValue) internal {
        uint256 currentHour = block.timestamp / 1 hours;
        uint256 currentDay = block.timestamp / 1 days;

        // Update hourly tracking
        if (hourlyValues[currentHour] == 0) {
            hourlyValues[currentHour] = currentValue;
            lastHourValue = currentValue;
        }

        // Update daily tracking
        if (dailyValues[currentDay] == 0) {
            dailyValues[currentDay] = currentValue;
            lastDayValue = currentValue;
        }

        lastPortfolioValue = currentValue;
    }

    /// @dev Check circuit breaker conditions
    function _checkCircuitBreakerConditions(uint256 currentValue) internal {
        // Check hourly drawdown
        if (lastHourValue > 0) {
            uint256 hourlyDrawdown =
                lastHourValue > currentValue ? ((lastHourValue - currentValue) * 100) / lastHourValue : 0;

            if (hourlyDrawdown > MAX_HOURLY_VOLATILITY) {
                circuitBreaker = CircuitBreaker({
                    isTripped: true,
                    tripTime: block.timestamp,
                    reason: "Excessive hourly volatility",
                    cooldownPeriod: 2 hours
                });

                emit CircuitBreakerTripped("Excessive hourly volatility", 2 hours);
                return;
            }
        }

        // Check daily drawdown
        if (lastDayValue > 0) {
            uint256 dailyDrawdown =
                lastDayValue > currentValue ? ((lastDayValue - currentValue) * 100) / lastDayValue : 0;

            if (dailyDrawdown > MAX_DAILY_DRAWDOWN) {
                circuitBreaker = CircuitBreaker({
                    isTripped: true,
                    tripTime: block.timestamp,
                    reason: "Excessive daily drawdown",
                    cooldownPeriod: 6 hours
                });

                emit CircuitBreakerTripped("Excessive daily drawdown", 6 hours);
            }
        }
    }

    /// @dev Assess individual position risk
    function _assessPositionRisk(address position) internal {
        uint256 healthFactor = _calculateHealthFactor(position);
        uint256 liquidationPrice = _calculateLiquidationPrice(position);
        uint256 exposure = _getPositionExposure(position);

        bool isHighRisk =
            healthFactor < MIN_HEALTH_FACTOR || exposure > (positionManager.getTotalValue() * MAX_SINGLE_POSITION) / 100;

        positionRisks[position] = PositionRisk({
            healthFactor: healthFactor,
            liquidationPrice: liquidationPrice,
            exposure: exposure,
            lastCheck: block.timestamp,
            isHighRisk: isHighRisk
        });

        if (isHighRisk) {
            emit HighRiskPositionDetected(position, healthFactor);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS - HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Get position collateral value
    function _getPositionCollateralValue(IPositionManager.Position memory pos) internal view returns (uint256) {
        uint256 value0 = pos.amount0 * priceOracle.getPrice(pos.token0) / 1e18;
        uint256 value1 = pos.amount1 * priceOracle.getPrice(pos.token1) / 1e18;
        return value0 + value1;
    }

    /// @dev Get position debt value
    function _getPositionDebt(IPositionManager.Position memory pos) internal view returns (uint256) {
        uint256 debt0 = pos.borrowed0 * priceOracle.getPrice(pos.token0) / 1e18;
        uint256 debt1 = pos.borrowed1 * priceOracle.getPrice(pos.token1) / 1e18;
        return debt0 + debt1;
    }

    /// @dev Calculate position leverage
    function _calculatePositionLeverage(IPositionManager.Position memory pos) internal view returns (uint256) {
        uint256 collateral = _getPositionCollateralValue(pos);
        uint256 debt = _getPositionDebt(pos);

        if (collateral == 0) return 0;
        return ((collateral + debt) * 100) / collateral;
    }

    /// @dev Get position exposure
    function _getPositionExposure(address position) internal view returns (uint256) {
        IPositionManager.Position memory pos = positionManager.getPosition(position);

        return _getPositionCollateralValue(pos) - _getPositionDebt(pos);
    }

    /// @dev Calculate portfolio volatility
    function _calculatePortfolioVolatility() internal view returns (uint256) {
        // Simplified: average of token volatilities weighted by exposure
        address[] memory positions = positionManager.getActivePositions();
        uint256 totalVolatility;
        uint256 totalWeight;

        for (uint256 i = 0; i < positions.length; i++) {
            IPositionManager.Position memory pos = positionManager.getPosition(positions[i]);

            uint256 vol0 = volatilityOracle.getVolatility(pos.token0, 24 hours);
            uint256 exposure = _getPositionExposure(positions[i]);

            totalVolatility += vol0 * exposure;
            totalWeight += exposure;
        }

        return totalWeight > 0 ? totalVolatility / totalWeight : 0;
    }

    /// @dev Calculate deleverage amount for emergency
    function _calculateDeleverageAmount(address position) internal view returns (uint256) {
        IPositionManager.Position memory pos = positionManager.getPosition(position);

        uint256 currentDebt = _getPositionDebt(pos);
        uint256 targetDebt = (_getPositionCollateralValue(pos) * 100) / riskParams.emergencyDeleverageRatio;

        return currentDebt > targetDebt ? currentDebt - targetDebt : 0;
    }
}
