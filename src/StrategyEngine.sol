// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {IPriceOracle} from "./interfaces/IOracle.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
import {CustomRevert} from "./libraries/CustomRevert.sol";
import {Lock} from "./libraries/Lock.sol";

/// @title Strategy Engine for Delta-Neutral Vaults
/// @notice Calculates optimal allocations and monitors delta exposure
contract StrategyEngine is AccessControl {
    using Math for uint256;
    using CustomRevert for bytes4;

    // ═══════════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");

    uint256 public constant DELTA_PRECISION = 1e18;
    uint256 public constant MAX_DELTA_DEVIATION = 5e16; // 5%
    uint256 public constant MIN_REBALANCE_INTERVAL = 1 hours;
    uint256 public constant CORRELATION_WINDOW = 7 days;

    // ═══════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════

    // Core contracts
    IPositionManager public positionManager;
    IPriceOracle public priceOracle;
    address public vault;

    // Strategy parameters
    struct StrategyParams {
        uint256 maxAllocationPerPair; // Max % allocated to single pair
        uint256 minVolumeThreshold; // Min 24h volume for pair inclusion
        uint256 targetDelta; // Usually 0 for neutral
        uint256 rebalanceThreshold; // Delta deviation to trigger rebalance
        uint256 gasThreshold; // Max gas price for rebalances
        RiskLevel riskLevel; // Conservative, Balanced, Aggressive
    }

    enum RiskLevel {
        CONSERVATIVE,
        BALANCED,
        AGGRESSIVE
    }

    StrategyParams public params;

    // Pair whitelist and metadata
    mapping(address => bool) public whitelistedPairs;
    mapping(address => PairMetadata) public pairMetadata;

    struct PairMetadata {
        uint256 volume24h;
        uint256 volatility30d;
        uint256 correlation;
        uint256 lastUpdate;
        bool isActive;
    }

    // Rebalancing state
    uint256 public lastRebalanceTime;
    uint256 public totalRebalances;
    mapping(uint256 => RebalanceRecord) public rebalanceHistory;

    struct RebalanceRecord {
        uint256 timestamp;
        int256 deltaBefore;
        int256 deltaAfter;
        uint256 gasUsed;
        bool successful;
    }

    // ═══════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════

    event PairWhitelisted(address indexed pair, bool status);
    event StrategyParamsUpdated(StrategyParams params);
    event RebalanceTriggered(int256 currentDelta, uint256 deviation);
    event AllocationCalculated(address indexed pair, uint256 allocation);

    // ═══════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    constructor(address _vault, address _positionManager, address _priceOracle) {
        vault = _vault;
        positionManager = IPositionManager(_positionManager);
        priceOracle = IPriceOracle(_priceOracle);

        // _setRoleAdmin(DEFAULT_ADMIN_ROLE, msg.sender);
        // _grantRole(VAULT_ROLE, _vault);

        // Default parameters - Conservative
        params = StrategyParams({
            maxAllocationPerPair: 30e16, // 30%
            minVolumeThreshold: 100_000e6, // $100k daily volume
            targetDelta: 0,
            rebalanceThreshold: 5e16, // 5%
            gasThreshold: 200 gwei,
            riskLevel: RiskLevel.CONSERVATIVE
        });
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - STRATEGY INTERFACE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Calculate optimal allocations across pairs
    /// @return strategyData Encoded allocation instructions
    function calculateOptimalAllocations() external onlyRole(VAULT_ROLE) returns (bytes memory strategyData) {
        address[] memory activePairs = positionManager.getActivePositions();
        AllocationInstruction[] memory allocations = new AllocationInstruction[](activePairs.length);

        uint256 totalScore;
        uint256[] memory scores = new uint256[](activePairs.length);

        // Calculate scores for each pair
        for (uint256 i = 0; i < activePairs.length; i++) {
            scores[i] = _calculatePairScore(activePairs[i]);
            totalScore += scores[i];
        }

        // Determine allocations based on scores
        for (uint256 i = 0; i < activePairs.length; i++) {
            uint256 allocation = totalScore > 0 ? (scores[i] * 1e18) / totalScore : 1e18 / activePairs.length;

            // Apply max allocation cap
            if (allocation > params.maxAllocationPerPair) {
                allocation = params.maxAllocationPerPair;
            }

            allocations[i] = AllocationInstruction({
                pair: activePairs[i],
                targetAllocation: allocation,
                shouldRebalance: _shouldRebalancePair(activePairs[i])
            });

            emit AllocationCalculated(activePairs[i], allocation);
        }

        return abi.encode(allocations);
    }

    /// @notice Check if rebalancing is needed
    function shouldRebalance() external view returns (bool) {
        // Check time constraint
        if (block.timestamp < lastRebalanceTime + MIN_REBALANCE_INTERVAL) {
            return false;
        }

        // Check gas price
        if (tx.gasprice > params.gasThreshold) {
            return false;
        }

        // Check delta deviation
        int256 currentDelta = getDeltaExposure();
        uint256 deviation = _abs(currentDelta - int256(params.targetDelta));

        return deviation > params.rebalanceThreshold;
    }

    /// @notice Calculate current portfolio delta exposure
    function getDeltaExposure() public view returns (int256) {
        address[] memory positions = positionManager.getActivePositions();
        int256 totalDelta;

        for (uint256 i = 0; i < positions.length; i++) {
            IPositionManager.Position memory pos = positionManager.getPosition(positions[i]);

            // Calculate delta for this position
            // Delta = Value of non-stable token exposure
            // For borrowed positions, delta is negative

            uint256 token0Price = priceOracle.getPrice(pos.token0);
            uint256 token1Price = priceOracle.getPrice(pos.token1);

            // Assuming token1 is always USDC (stable)
            int256 token0ValueInPool = int256(pos.amount0 * token0Price / 1e18);
            int256 token0ValueBorrowed = int256(pos.borrowed0 * token0Price / 1e18);

            int256 positionDelta = token0ValueInPool - token0ValueBorrowed;
            totalDelta += positionDelta;
        }

        return totalDelta;
    }

    // ═══════════════════════════════════════════════════════════════
    // EXTERNAL FUNCTIONS - ADMIN
    // ═══════════════════════════════════════════════════════════════

    /// @notice Update strategy parameters
    function updateStrategyParams(StrategyParams calldata newParams) external onlyRole(STRATEGIST_ROLE) {
        params = newParams;
        emit StrategyParamsUpdated(newParams);
    }

    /// @notice Whitelist a trading pair
    function whitelistPair(address pair, bool status) external onlyRole(STRATEGIST_ROLE) {
        whitelistedPairs[pair] = status;
        emit PairWhitelisted(pair, status);
    }

    /// @notice Update pair metadata (called by keeper)
    function updatePairMetadata(address pair, uint256 volume24h, uint256 volatility30d)
        external
        onlyRole(STRATEGIST_ROLE)
    {
        pairMetadata[pair] = PairMetadata({
            volume24h: volume24h,
            volatility30d: volatility30d,
            correlation: _calculateCorrelation(pair),
            lastUpdate: block.timestamp,
            isActive: volume24h >= params.minVolumeThreshold
        });
    }

    // ═══════════════════════════════════════════════════════════════
    // PUBLIC VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Get allocation for risk level
    function getAllocationForRiskLevel(RiskLevel level)
        public
        pure
        returns (uint256 maxAllocation, uint256 maxVolatility)
    {
        if (level == RiskLevel.CONSERVATIVE) {
            return (30e16, 50e16); // 30% max, 50% volatility
        } else if (level == RiskLevel.BALANCED) {
            return (40e16, 100e16); // 40% max, 100% volatility
        } else {
            return (50e16, 200e16); // 50% max, 200% volatility
        }
    }

    /// @notice Get current strategy health metrics
    function getStrategyHealth()
        external
        view
        returns (int256 currentDelta, uint256 deltaDeviation, uint256 timeSinceRebalance, bool needsRebalance)
    {
        currentDelta = getDeltaExposure();
        deltaDeviation = _abs(currentDelta - int256(params.targetDelta));
        timeSinceRebalance = block.timestamp - lastRebalanceTime;
        needsRebalance = this.shouldRebalance();
    }

    // ═══════════════════════════════════════════════════════════════
    // INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Calculate score for a pair based on multiple factors
    function _calculatePairScore(address pair) internal view returns (uint256) {
        PairMetadata memory meta = pairMetadata[pair];

        if (!meta.isActive || !whitelistedPairs[pair]) {
            return 0;
        }

        // Score based on:
        // 1. Volume (40% weight)
        // 2. Volatility (30% weight) - inverse relationship
        // 3. Correlation (30% weight) - prefer low correlation

        uint256 volumeScore = Math.min(meta.volume24h / 1e6, 100) * 40;
        uint256 volatilityScore = (100 - Math.min(meta.volatility30d / 1e16, 100)) * 30;
        uint256 correlationScore = (100 - Math.min(meta.correlation / 1e16, 100)) * 30;

        return volumeScore + volatilityScore + correlationScore;
    }

    /// @dev Check if specific pair needs rebalancing
    function _shouldRebalancePair(address pair) internal view returns (bool) {
        IPositionManager.Position memory pos = positionManager.getPosition(pair);

        // Calculate pair-specific delta
        uint256 token0Price = priceOracle.getPrice(pos.token0);
        int256 pairDelta = int256(pos.amount0 * token0Price / 1e18) - int256(pos.borrowed0 * token0Price / 1e18);

        // Check if pair delta deviates significantly
        return _abs(pairDelta) > (params.rebalanceThreshold);
    }

    /// @dev Calculate correlation coefficient for a pair
    function _calculateCorrelation(address pair) internal view returns (uint256) {
        // Simplified correlation calculation
        // In production, would use historical price data
        return 20e16; // 20% correlation placeholder
    }

    /// @dev Absolute value for int256
    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
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
