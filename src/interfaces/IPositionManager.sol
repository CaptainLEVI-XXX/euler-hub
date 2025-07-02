// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IPositionManager {
    struct Position {
        address pool;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 borrowed0;
        uint256 borrowed1;
        uint256 lastUpdate;
    }

    struct AllocationInstruction {
        address pair;
        uint256 targetAllocation;
        bool shouldRebalance;
    }

    function executeStrategy(bytes calldata strategyData) external;
    function getTotalValue() external view returns (uint256);
    function claimRewards() external returns (uint256);
    function getPosition(address pool) external view returns (Position memory);
    function getActivePositions() external view returns (address[] memory);
}
