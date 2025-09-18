// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {AccessControl} from "./../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

// libraries
import {Errors} from "./libraries/Errors.sol";

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

    // retrieved from AddressBook: DEFAULT_ADMIN_ROLE
    bytes32 internal GLOBAL_ADMIN = keccak256("GLOBAL_ADMIN"); 

   
    // ----- Lowest privilege, automated/operational functions ----- 
    // Operational roles - no admin privileges [attached to scripts]
    bytes32 private constant MONITOR_ROLE = keccak256("MONITOR_ROLE");    // Pause only
    bytes32 private constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE");  // Automated tasks: createLockFor
    bytes32 private constant EMERGENCY_EXIT_HANDLER_ROLE = keccak256('EMERGENCY_EXIT_HANDLER_ROLE'); // Emergency only
    
    // ----- Contract-specific admin roles -----
    // Roles for making changes to contract parameters + configuration [multi-sig]
    bytes32 private constant PAYMENTS_CONTROLLER_ADMIN_ROLE = keccak256('PAYMENTS_CONTROLLER_ADMIN_ROLE'); 
    bytes32 private constant VOTING_CONTROLLER_ADMIN_ROLE = keccak256('VOTING_CONTROLLER_ADMIN_ROLE');    
    
    // ----- Asset management roles [for multiple contracts] -----
    // for depositing/withdrawing/converting assets across contracts: [PaymentsController, VotingController, esMoca]
    bytes32 private constant ASSET_MANAGER_ROLE = keccak256('ASSET_MANAGER_ROLE'); //withdrawUnclaimedX, finalizeEpoch, depositSubsidies

//-------------------------------constructor-----------------------------------------

    /**
     * @dev Constructor
     * @param addressBook_ The address of the AddressBook
    */
    constructor(address addressBook) {

        // address book
        _addressBook = IAddressBook(addressBook);

        // get global admin from AddressBook: DEFAULT_ADMIN_ROLE
        address globalAdmin = _addressBook.addresses(bytes32(0));
        require(globalAdmin != address(0), Errors.InvalidAddress());

        // set DEFAULT_ADMIN_ROLE to global admin address
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);
    }

// ----- external functions -----

    /**
     * @notice Sets the admin role for a specific role
     * @dev By default the admin role for all roles is `DEFAULT_ADMIN_ROLE`.
     * @param role The role whose administrator is being updated
     * @param adminRole The new administrator role for the specified role
    */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

// ----- GLOBAL_ADMIN ROLE -----

    /** note
        do you want to have a separate global admin tt is not DEFAULT_ADMIN_ROLE[0x00]?
        - how would it be useful?
     */


    function addGlobalAdmin(address addr) external noZeroAddress(addr) {
        grantRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function removeGlobalAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(DEFAULT_ADMIN_ROLE, addr);
    }

    function isGlobalAdmin(address addr) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }

// ----- MONITOR ROLE -----

    //note: should probably set the roleAdmin for Monitors to be a different role [not 0x00]
    //      so that we can manage the pause bots easily w/o GLOBAL_ADMIN
    //      MONITOR_ROLE_ADMIN can be a 2/2 multisig, within just the engineers

    function addMonitor(address addr) external noZeroAddress(addr) {
        grantRole(MONITOR_ROLE, addr);
        emit MonitorAdded(addr, msg.sender);
    }

    function removeMonitor(address addr) external noZeroAddress(addr) {
        revokeRole(MONITOR_ROLE, addr);
        emit MonitorRemoved(addr, msg.sender);
    }

    function isMonitor(address addr) external view returns (bool) {
        return hasRole(MONITOR_ROLE, addr);
    }

// ----- CRON_JOB ROLE -----

    function addCronJob(address addr) external noZeroAddress(addr) {
        grantRole(CRON_JOB_ROLE, addr);
        emit CronJobAdded(addr, msg.sender);
    }

    function removeCronJob(address addr) external noZeroAddress(addr) {
        revokeRole(CRON_JOB_ROLE, addr);
        emit CronJobRemoved(addr, msg.sender);
    }

    function isCronJob(address addr) external view returns (bool) {
        return hasRole(CRON_JOB_ROLE, addr);
    }


// ----- EMERGENCY_EXIT ROLE -----

    function addEmergencyExitHandler(address addr) external noZeroAddress(addr) {
        grantRole(EMERGENCY_EXIT_HANDLER_ROLE, addr);
        emit EmergencyExitHandlerAdded(addr, msg.sender);
    }

    function removeEmergencyExitHandler(address addr) external noZeroAddress(addr) {
        revokeRole(EMERGENCY_EXIT_HANDLER_ROLE, addr);
        emit EmergencyExitHandlerRemoved(addr, msg.sender);
    }

    function isEmergencyExitHandler(address addr) external view returns (bool) {
        return hasRole(EMERGENCY_EXIT_HANDLER_ROLE, addr);
    }


// ----- PaymentsController Admin -----

    function addPaymentsControllerAdmin(address addr) external noZeroAddress(addr) {
        grantRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, addr);
        emit PaymentsControllerAdminAdded(addr, msg.sender);
    }

    function removePaymentsControllerAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, addr);
        emit PaymentsControllerAdminRemoved(addr, msg.sender);
    }

    function isPaymentsControllerAdmin(address addr) external view returns (bool) {
        return hasRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, addr);
    }

// ----- VotingController Admin -----

    function addVotingControllerAdmin(address addr) external noZeroAddress(addr) {
        grantRole(VOTING_CONTROLLER_ADMIN_ROLE, addr);
        emit VotingControllerAdminAdded(addr, msg.sender);
    }

    function removeVotingControllerAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(VOTING_CONTROLLER_ADMIN_ROLE, addr);
        emit VotingControllerAdminRemoved(addr, msg.sender);
    }

    function isVotingControllerAdmin(address addr) external view returns (bool) {
        return hasRole(VOTING_CONTROLLER_ADMIN_ROLE, addr);
    }


// ----- ASSET_MANAGER ROLE -----

    function addAssetManager(address addr) external noZeroAddress(addr) {
        grantRole(ASSET_MANAGER_ROLE, addr);
        emit AssetManagerAdded(addr, msg.sender);
    }
    
    function removeAssetManager(address addr) external noZeroAddress(addr) {
        revokeRole(ASSET_MANAGER_ROLE, addr);
        emit AssetManagerRemoved(addr, msg.sender);
    }

    function isAssetManager(address addr) external view returns (bool) {
        return hasRole(ASSET_MANAGER_ROLE, addr);
    }


// ----- modifiers -----

    modifier noZeroAddress(address addr) {
        require(addr != address(0), Errors.InvalidAddress());
        _;
    }
}

// https://aave.com/docs/developers/smart-contracts/acl-manager
// https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/configuration/ACLManager.sol


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