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
contract AccessController is AccessControl {

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
    bytes32 private constant MONITOR_ROLE = keccak256("MONITOR_ROLE");   // only pause
    bytes32 private constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE"); // createLockFor
    
    bytes32 private constant GLOBAL_ADMIN = 'GLOBAL_ADMIN';   // DEFAULT_ADMIN_ROLE

    //bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // admin fns to update params
    //bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256('EMERGENCY_ADMIN');


    /**
     * @dev Constructor
     * @param addressBook_ The address of the AddressBook
    */
    constructor(address addressBook_) {

        // address book
        _addressBook = IAddressBook(addressBook_);

        // global admin: DEFAULT_ADMIN_ROLE
        address globalAdmin = _addressBook.getGlobalAdmin();
        require(globalAdmin != address(0), Errors.GlobalAdminCannotBeZero());

        _setupRole(DEFAULT_ADMIN_ROLE, globalAdmin);
    }

// ----- external -----

    /**
     * @notice Sets the admin role for a specific role
     * @dev By default the admin role for all roles is `DEFAULT_ADMIN_ROLE`.
     * @param role The role whose administrator is being updated
     * @param adminRole The new administrator role for the specified role
    */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

// ----- GLOBAL_ADMIN ROLE -----

    /** note
        do you want to have a separate global admin tt is not DEFAULT_ADMIN_ROLE[0x00]?
        - how would it be useful?
     */


    function addGlobalAdmin(address addr) external {
        grantRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function removeGlobalAdmin(address addr) external {
        revokeRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function isGlobalAdmin(address addr) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }

// ----- MONITOR ROLE -----

    //note: should probably set the roleAdmin for Monitors to be a different role [not 0x00]
    //      so that we can manage the pause bots easily w/o GLOBAL_ADMIN
    //      MONITOR_ROLE_ADMIN can be a 2/2 multisig, within just the engineers

    function addMonitor(address addr) external {
        grantRole(MONITOR_ROLE, addr);
    }

    function removeMonitor(address addr) external {
        revokeRole(MONITOR_ROLE, addr);
    }

    function isMonitor(address addr) external view returns (bool) {
        return hasRole(MONITOR_ROLE, addr);
    }

// ----- CRON_JOB ROLE -----

    function addCronJob(address addr) external {
        grantRole(CRON_JOB_ROLE, addr);
    }

    function removeCronJob(address addr) external {
        revokeRole(CRON_JOB_ROLE, addr);
    }

    function isCronJob(address addr) external view returns (bool) {
        return hasRole(CRON_JOB_ROLE, addr);
    }


// ----- PaymentsController Admin: PaymentsAdmin -----

    function addPaymentsAdmin(address addr) external {
        grantRole(PAYMENTS_ADMIN_ROLE, addr);
    }

    function removePaymentsAdmin(address addr) external {
        revokeRole(PAYMENTS_ADMIN_ROLE, addr);
    }

    function isPaymentsAdmin(address addr) external view returns (bool) {
        return hasRole(PAYMENTS_ADMIN_ROLE, addr);
    }

// ----- OPERATOR ROLE -----

    function addOperator(address addr) external {
        grantRole(OPERATOR_ROLE, addr);
    }

    function removeOperator(address addr) external {
        revokeRole(OPERATOR_ROLE, addr);
    }

    function isOperator(address addr) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, addr);
    }

// ----- CRON JOB ROLE -----




}

// https://aave.com/docs/developers/smart-contracts/acl-manager
// https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/configuration/ACLManager.sol