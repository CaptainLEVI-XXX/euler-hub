// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.27;

import {IPriceOracle} from "../../src/interfaces/IOracle.sol";

contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) public prices;
    mapping(address => bool) public manipulated;

    function setPrice(address token, uint256 price) external {
        prices[token] = price;
    }

    function getPrice(address token) external view returns (uint256) {
        require(prices[token] > 0, "Price not set");
        return prices[token];
    }

    function isManipulated(address token) external view returns (bool) {
        return manipulated[token];
    }

    function getTwapPrice(address token, uint256) external view returns (uint256) {
        return prices[token];
    }
}
