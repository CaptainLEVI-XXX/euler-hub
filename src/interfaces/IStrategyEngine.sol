// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IStrategyEngine {
    function calculateOptimalAllocations() external view returns (bytes memory);
    function shouldRebalance() external view returns (bool);
    function getDeltaExposure() external view returns (int256);
}