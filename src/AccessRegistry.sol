// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title AccessRegistry
contract AccessRegistry is AccessControl {
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant STRATEGIST_ROLE = keccak256("STRATEGIST_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    constructor(address admin) {
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(GUARDIAN_ROLE, admin);
        _grantRole(STRATEGIST_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
        _grantRole(VAULT_ROLE, admin);

        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(GUARDIAN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(STRATEGIST_ROLE, ADMIN_ROLE);
        _setRoleAdmin(KEEPER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(VAULT_ROLE, ADMIN_ROLE);
    }

    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }
}
