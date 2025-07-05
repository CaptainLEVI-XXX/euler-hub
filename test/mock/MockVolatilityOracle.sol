// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

contract MockVolatilityOracle {
    mapping(address => uint256) public volatilities;

    function setVolatility(address token, uint256 volatility) external {
        volatilities[token] = volatility;
    }

    function getVolatility(address token, uint256) external view returns (uint256) {
        return volatilities[token];
    }
}
