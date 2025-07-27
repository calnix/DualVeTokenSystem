// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";

/**
 * @title AccessControlLayer
 * @author Calnix
 * @notice Centralized access control layer managing all system roles and permissions.
 */

//note: get addresses from address book
contract AccessControlLayer is AccessControl {

    IAddressBook internal immutable _addressBook;

    /**
        for privileged calls, other contract would refer to this to check permissioning. 
        
        I.e. Voting.sol has modifier:

            function _onlyRiskOrPoolAdmins() internal view {
                IACLManager aclManager = IACLManager(_addressesProvider.getACLManager());
                require(
                    aclManager.isRiskAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
                    Errors.CallerNotRiskOrPoolAdmin()
            );
    */
    
    // ROLES
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");   // only pause
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // admin fns to update params
    bytes32 public constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE"); // stakeOnBehalf
    bytes32 public constant override EMERGENCY_ADMIN_ROLE = keccak256('EMERGENCY_ADMIN');


    /**
    * @dev Constructor
    * @dev Admin addresses should be initialized at the AddressBook beforehand
    * @param _addressBook The address of the AddressBook
    */
    constructor(address addressBook_) {
        // address book
        _addressBook = IAddressBook(addressBook_);

        // acl admin
        address aclAdmin = _addressBook.getACLAdmin();
        require(aclAdmin != address(0), Errors.AclAdminCannotBeZero());
        _setupRole(DEFAULT_ADMIN_ROLE, aclAdmin);
    }

    /**
     * @notice Set the role as admin of a specific role.
     * @dev By default the admin role for all roles is `DEFAULT_ADMIN_ROLE`.
     * @param role The role to be managed by the admin role
     * @param adminRole The admin role
    */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

// ----- MONITOR ROLE -----
    function addMonitorAdmin(address admin) external {
        grantRole(MONITOR_ROLE, admin);
    }

    function removeMonitorAdmin(address admin) external {
        revokeRole(MONITOR_ROLE, admin);
    }

    function isMonitorAdmin(address admin) external view returns (bool) {
        return hasRole(MONITOR_ROLE, admin);
    }

// ----- OPERATOR ROLE -----

    function addOperatorAdmin(address admin) external {
        grantRole(OPERATOR_ROLE, admin);
    }

    function removeOperatorAdmin(address admin) external {
        revokeRole(OPERATOR_ROLE, admin);
    }

    function isOperatorAdmin(address admin) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, admin);
    }

// ----- CRON JOB ROLE -----




}

// https://aave.com/docs/developers/smart-contracts/acl-manager
// https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/configuration/ACLManager.sol