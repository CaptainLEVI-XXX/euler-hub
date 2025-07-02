// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

interface IHubController {
    function poolInfo(address token) external view returns (
        address,
        address vault,
        address pool,
        uint256 volume24h,
        uint256 lastVolumeUpdate,
        uint256 virtualReserveAllocation,
        uint256 targetConcentration
    );
    function hubAsset() external view returns (address);
    function isTokenSupported(address token) external view returns (bool);
    function getSupportedTokens() external view returns (address[] memory);
}