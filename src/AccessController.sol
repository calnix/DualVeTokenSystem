// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {AccessControl} from "./../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

// libraries
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";

/**
 * @title AccessControlLayer
 * @author Calnix [@cal_nix]
 * @notice Centralized access control layer managing all system roles and permissions.
 */

//note: get addresses from address book
contract AccessController is AccessControl {

    IAddressBook internal immutable _addressBook;
  
    // ______ HIGH-FREQUENCY ROLES [AUTOMATED OPERATIONAL FUNCTIONS] ______
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");      // Pause only
    bytes32 public constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE");    // Automated tasks: createLockFor, finalizeEpoch, depositSubsidies
    
    // Role admins for operational roles [Dedicated role admins for operational efficiency]
    bytes32 public constant MONITOR_ADMIN_ROLE = keccak256("MONITOR_ADMIN_ROLE"); 
    bytes32 public constant CRON_JOB_ADMIN_ROLE = keccak256("CRON_JOB_ADMIN_ROLE");

    // ______ LOW-FREQUENCY STRATEGIC ROLES: NO DEDICATED ADMINS [MANAGED BY GLOBAL ADMIN] ______
    // Roles for making changes to contract parameters + configuration [multi-sig]
    bytes32 public constant PAYMENTS_CONTROLLER_ADMIN_ROLE = keccak256("PAYMENTS_CONTROLLER_ADMIN_ROLE");
    bytes32 public constant VOTING_CONTROLLER_ADMIN_ROLE = keccak256("VOTING_CONTROLLER_ADMIN_ROLE");
    bytes32 public constant ESCROWED_MOCA_ADMIN_ROLE = keccak256("ESCROWED_MOCA_ADMIN_ROLE");
    // [for multiple contracts]: depositing/withdrawing/converting assets [PaymentsController, VotingController, esMoca]
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE"); // withdraw fns on PaymentsController, VotingController
    bytes32 public constant EMERGENCY_EXIT_HANDLER_ROLE = keccak256("EMERGENCY_EXIT_HANDLER_ROLE"); 

//-------------------------------constructor-----------------------------------------

    /**
     * @dev Constructor
     * @param addressBook The address of the AddressBook
    */
    constructor(address addressBook) {
        _addressBook = IAddressBook(addressBook);
        
        // Get global admin from AddressBook
        address globalAdmin = _addressBook.getGlobalAdmin();
        require(globalAdmin != address(0), Errors.InvalidAddress());

        // Grant supreme admin role
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);
        
        // Operational role administrators managed by global admin
        _setRoleAdmin(MONITOR_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CRON_JOB_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        
        // High-frequency roles managed by their dedicated admins
        _setRoleAdmin(MONITOR_ROLE, MONITOR_ADMIN_ROLE);
        _setRoleAdmin(CRON_JOB_ROLE, CRON_JOB_ADMIN_ROLE);
        
        // Low-frequency roles managed directly by global admin
        _setRoleAdmin(PAYMENTS_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(VOTING_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ASSET_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EMERGENCY_EXIT_HANDLER_ROLE, DEFAULT_ADMIN_ROLE);
    }

// ----- generic setRoleAdmin function -----

    /**
     * @notice Sets the admin role for a specific role
     * @dev By default the admin role for all roles is `DEFAULT_ADMIN_ROLE`.
     * @param role The role whose administrator is being updated
     * @param adminRole The new administrator role for the specified role
    */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }


// -------------------- HIGH-FREQUENCY ROLE MANAGEMENT --------------------

    // Monitor role functions
    function addMonitor(address addr) external noZeroAddress(addr) {
        grantRole(MONITOR_ROLE, addr);
        emit Events.MonitorAdded(addr, msg.sender);
    }

    function removeMonitor(address addr) external noZeroAddress(addr) {
        revokeRole(MONITOR_ROLE, addr);
        emit Events.MonitorRemoved(addr, msg.sender);
    }

    function isMonitor(address addr) external view returns (bool) {
        return hasRole(MONITOR_ROLE, addr);
    }

    // CronJob role functions
    function addCronJob(address addr) external noZeroAddress(addr) {
        grantRole(CRON_JOB_ROLE, addr);
        emit Events.CronJobAdded(addr, msg.sender);
    }

    function removeCronJob(address addr) external noZeroAddress(addr) {
        revokeRole(CRON_JOB_ROLE, addr);
        emit Events.CronJobRemoved(addr, msg.sender);
    }

    function isCronJob(address addr) external view returns (bool) {
        return hasRole(CRON_JOB_ROLE, addr);
    }
    
    // --------------- OPERATIONAL ADMIN ROLE MANAGEMENT ---------------
    
    // Monitor admin functions
    function addMonitorAdmin(address addr) external noZeroAddress(addr) {
        grantRole(MONITOR_ADMIN_ROLE, addr);
        emit Events.MonitorAdminAdded(addr, msg.sender);
    }

    function removeMonitorAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(MONITOR_ADMIN_ROLE, addr);
        emit Events.MonitorAdminRemoved(addr, msg.sender);
    }

    function isMonitorAdmin(address addr) external view returns (bool) {
        return hasRole(MONITOR_ADMIN_ROLE, addr);
    }

    // CronJob admin functions
    function addCronJobAdmin(address addr) external noZeroAddress(addr) {
        grantRole(CRON_JOB_ADMIN_ROLE, addr);
        emit Events.CronJobAdminAdded(addr, msg.sender);
    }

    function removeCronJobAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(CRON_JOB_ADMIN_ROLE, addr);
        emit Events.CronJobAdminRemoved(addr, msg.sender);
    }

    function isCronJobAdmin(address addr) external view returns (bool) {
        return hasRole(CRON_JOB_ADMIN_ROLE, addr);
    }

// -------------------- LOW-FREQUENCY STRATEGIC ROLES (managed by DEFAULT_ADMIN_ROLE) --------------------

    // PaymentsControllerAdmin role functions
    function addPaymentsControllerAdmin(address addr) external noZeroAddress(addr) {
        grantRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, addr);
        emit Events.PaymentsControllerAdminAdded(addr, msg.sender);
    }

    function removePaymentsControllerAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, addr);
        emit Events.PaymentsControllerAdminRemoved(addr, msg.sender);
    }

    function isPaymentsControllerAdmin(address addr) external view returns (bool) {
        return hasRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, addr);
    }


    // VotingControllerAdmin role functions
    function addVotingControllerAdmin(address addr) external noZeroAddress(addr) {
        grantRole(VOTING_CONTROLLER_ADMIN_ROLE, addr);
        emit Events.VotingControllerAdminAdded(addr, msg.sender);
    }

    function removeVotingControllerAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(VOTING_CONTROLLER_ADMIN_ROLE, addr);
        emit Events.VotingControllerAdminRemoved(addr, msg.sender);
    }

    function isVotingControllerAdmin(address addr) external view returns (bool) {
        return hasRole(VOTING_CONTROLLER_ADMIN_ROLE, addr);
    }


    // EscrowedMocaAdmin role functions
    function addEscrowedMocaAdmin(address addr) external noZeroAddress(addr) {
        grantRole(ESCROWED_MOCA_ADMIN_ROLE, addr);
        emit Events.EscrowedMocaAdminAdded(addr, msg.sender);
    }
    
    function removeEscrowedMocaAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(ESCROWED_MOCA_ADMIN_ROLE, addr);
        emit Events.EscrowedMocaAdminRemoved(addr, msg.sender);
    }

    function isEscrowedMocaAdmin(address addr) external view returns (bool) {
        return hasRole(ESCROWED_MOCA_ADMIN_ROLE, addr);
    }


    // AssetManager role functions
    function addAssetManager(address addr) external noZeroAddress(addr) {
        grantRole(ASSET_MANAGER_ROLE, addr);
        emit Events.AssetManagerAdded(addr, msg.sender);
    }

    function removeAssetManager(address addr) external noZeroAddress(addr) {
        revokeRole(ASSET_MANAGER_ROLE, addr);
        emit Events.AssetManagerRemoved(addr, msg.sender);
    }

    function isAssetManager(address addr) external view returns (bool) {
        return hasRole(ASSET_MANAGER_ROLE, addr);
    }


    // EmergencyExitHandler role functions
    function addEmergencyExitHandler(address addr) external noZeroAddress(addr) {
        grantRole(EMERGENCY_EXIT_HANDLER_ROLE, addr);
        emit Events.EmergencyExitHandlerAdded(addr, msg.sender);
    }
    
    function removeEmergencyExitHandler(address addr) external noZeroAddress(addr) {
        revokeRole(EMERGENCY_EXIT_HANDLER_ROLE, addr);
        emit Events.EmergencyExitHandlerRemoved(addr, msg.sender);
    }

    function isEmergencyExitHandler(address addr) external view returns (bool) {
        return hasRole(EMERGENCY_EXIT_HANDLER_ROLE, addr);
    }

// -------------------- GLOBAL ADMIN FUNCTIONS --------------------

    function addGlobalAdmin(address addr) external noZeroAddress(addr) {
        grantRole(DEFAULT_ADMIN_ROLE, addr);
        emit Events.GlobalAdminAdded(addr, msg.sender);
    }

    function removeGlobalAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(DEFAULT_ADMIN_ROLE, addr);
        emit Events.GlobalAdminRemoved(addr, msg.sender);
    }

    function isGlobalAdmin(address addr) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }


// -------------------- MODIFIERS --------------------------------

    modifier noZeroAddress(address addr) {
        require(addr != address(0), Errors.InvalidAddress());
        _;
    }
}