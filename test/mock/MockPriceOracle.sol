// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// Mock contracts for testing
contract MockPriceOracle {
    mapping(address => uint256) public prices;
    mapping(address => bool) public manipulated;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        return prices[token];
    }

    function isManipulated(address token) external view returns (bool) {
        return manipulated[token];
    }

    function setManipulated(address token, bool _manipulated) external {
        manipulated[token] = _manipulated;
    }
}
