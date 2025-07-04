// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IAccessRegistry} from "../interfaces/IAccessRegistry.sol";
import {CustomRevert} from "../libraries/CustomRevert.sol";

/// @title Roles
/// @notice Base contract for role-based access control
/// @dev Provides modifiers for role-based access control using AccessRegistry
abstract contract Roles {
    using CustomRevert for bytes4;

    /// @dev Role identifier for admin users
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    /// @dev Access registry instance
    IAccessRegistry internal accessRegistry;

    /// @dev Custom error for unauthorized access
    error NotAuthorized();

    /// @notice Constructor to disable initializers
    constructor(address _accessRegistry) {
        accessRegistry = IAccessRegistry(_accessRegistry);
    }

    /// @dev Modifier to restrict access to admin role
    modifier onlyAdmin() {
        if (!accessRegistry.hasRole(ADMIN_ROLE, msg.sender)) NotAuthorized.selector.revertWith();
        _;
    }

    /// @dev Modifier to restrict access to guardian
    modifier onlyGuardian() {
        if (!accessRegistry.hasRole(GUARDIAN_ROLE, msg.sender)) NotAuthorized.selector.revertWith();
        _;
    }

    /// @dev Modifier to restrict access to strategist
    modifier onlyStrategist() {
        if (!accessRegistry.hasRole(STRATEGIST_ROLE, msg.sender)) NotAuthorized.selector.revertWith();
        _;
    }

    /// @dev Modifier to restrict access to keeper
    modifier onlyKeeper() {
        if (!accessRegistry.hasRole(KEEPER_ROLE, msg.sender)) NotAuthorized.selector.revertWith();
        _;
    }

    /// @dev Modifier to restrict access to vault
    modifier onlyVault() {
        if (!accessRegistry.hasRole(VAULT_ROLE, msg.sender)) NotAuthorized.selector.revertWith();
        _;
    }
}
