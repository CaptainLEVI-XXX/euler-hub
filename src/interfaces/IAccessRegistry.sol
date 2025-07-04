// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IAccessRegistry
/// @notice Interface for the AccessRegistry contract
/// @dev Provides role-based access control functionality
interface IAccessRegistry {
    /// @notice Get the ADMIN_ROLE identifier
    /// @return The admin role identifier
    function ADMIN_ROLE() external view returns (bytes32);

    /// @notice Get the GUARDIAN_ROLE identifier
    /// @return The guardian role identifier
    function GUARDIAN_ROLE() external view returns (bytes32);

    /// @notice Get the STRATEGIST_ROLE identifier
    /// @return The strategist role identifier
    function STRATEGIST_ROLE() external view returns (bytes32);

    /// @notice Get the KEEPER_ROLE identifier
    /// @return The keeper role identifier
    function KEEPER_ROLE() external view returns (bytes32);

    /// @notice Get the VAULT_ROLE identifier
    /// @return The vault role identifier
    function VAULT_ROLE() external view returns (bytes32);

    /// @notice Check if an account has a specific role
    /// @param role The role to check
    /// @param account The account to check
    /// @return Whether the account has the role
    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice Grant a role to an account
    /// @param role The role to grant
    /// @param account The account to grant the role to
    function grantRole(bytes32 role, address account) external;

    /// @notice Revoke a role from an account
    /// @param role The role to revoke
    /// @param account The account to revoke the role from
    function revokeRole(bytes32 role, address account) external;

    /// @notice Get the number of members with a specific role
    /// @param role The role to check
    /// @return The number of members with the role
    function getRoleMemberCount(bytes32 role) external view returns (uint256);

    /// @notice Get a specific role member
    /// @param role The role to check
    /// @param index The index of the member to get
    /// @return The address of the member
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
}
