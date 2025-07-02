// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
    function isManipulated(address token) external view returns (bool);
    function getTwapPrice(address token, uint256 period) external view returns (uint256);
}

interface IVolatilityOracle {
    function getVolatility(address token, uint256 period) external view returns (uint256);
}