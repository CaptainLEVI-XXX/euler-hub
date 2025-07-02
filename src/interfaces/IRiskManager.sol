// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IRiskManager {
    function checkHealthFactors() external view returns (bool);
    function isRebalanceSafe(bytes calldata rebalanceData) external view returns (bool);
}
