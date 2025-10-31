// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {AccessControl} from "./../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

// libraries
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

/**
 * @title AccessController
 * @author Calnix [@cal_nix]
 * @notice Centralized access control layer managing all system roles and permissions.
 * @dev No pausable functionality as it is not needed for this contract.
 *      All role management functions are inherently protected by multi-sig requirements:
 *      - Strategic roles (PAYMENTS_CONTROLLER_ADMIN, ASSET_MANAGER, etc.) are managed directly by DEFAULT_ADMIN_ROLE (multi-sig)
 *      - Operational roles (MONITOR, CRON_JOB) are managed by their respective admin roles (MONITOR_ADMIN, CRON_JOB_ADMIN) which are also multi-sigs
 *      - Making AccessController pausable would prevent emergency response (unable to revoke compromised roles when most needed)
 *      - Role permission checks must remain functional during protocol emergencies to allow unpause/freeze operations
 *      The protocol's security model relies on fast emergency response via monitor pause capabilities on operational contracts,
 *      while role management remains deliberately slow and secure through multi-sig coordination.
 */

contract AccessController is AccessControl {
 
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
    bytes32 public constant VOTING_ESCROW_MOCA_ADMIN_ROLE = keccak256("VOTING_ESCROW_MOCA_ADMIN_ROLE");
    bytes32 public constant ESCROWED_MOCA_ADMIN_ROLE = keccak256("ESCROWED_MOCA_ADMIN_ROLE");
    bytes32 public constant ISSUER_STAKING_CONTROLLER_ADMIN_ROLE = keccak256("ISSUER_STAKING_CONTROLLER_ADMIN_ROLE");

    // For multiple contracts: depositing/withdrawing/converting assets [PaymentsController, VotingController, esMoca]
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");                   // withdraw fns on PaymentsController, VotingController
    bytes32 public constant EMERGENCY_EXIT_HANDLER_ROLE = keccak256("EMERGENCY_EXIT_HANDLER_ROLE"); 

    // Treasury address for respective contracts
    address public PAYMENTS_CONTROLLER_TREASURY;
    address public VOTING_CONTROLLER_TREASURY;
    address public ESCROWED_MOCA_TREASURY;

    // Risk
    uint256 public isFrozen;

//-------------------------------Constructor-------------------------------------------------------

    /**
     * @dev Constructor
     * @param globalAdmin The address of the global admin
     * @param paymentsTreasury The address of the payments controller treasury
     * @param votingTreasury The address of the voting controller treasury
     * @param esMocaTreasury The address of the es moca treasury
    */
    constructor(address globalAdmin, address paymentsTreasury, address votingTreasury, address esMocaTreasury) {
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(paymentsTreasury != address(0), Errors.InvalidAddress());
        require(votingTreasury != address(0), Errors.InvalidAddress());
        require(esMocaTreasury != address(0), Errors.InvalidAddress());

        // set treasury addresses
        PAYMENTS_CONTROLLER_TREASURY = paymentsTreasury;
        VOTING_CONTROLLER_TREASURY = votingTreasury;
        ESCROWED_MOCA_TREASURY = esMocaTreasury;

        // Grant supreme admin role
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);
        
        // Operational role administrators managed by global admin
        _setRoleAdmin(MONITOR_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CRON_JOB_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        
        // High-frequency roles managed by their dedicated admins
        _setRoleAdmin(MONITOR_ROLE, MONITOR_ADMIN_ROLE);
        _setRoleAdmin(CRON_JOB_ROLE, CRON_JOB_ADMIN_ROLE);
        
        // Low-frequency roles managed directly by global admin
        _setRoleAdmin(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAYMENTS_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(VOTING_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(VOTING_ESCROW_MOCA_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ESCROWED_MOCA_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(ASSET_MANAGER_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EMERGENCY_EXIT_HANDLER_ROLE, DEFAULT_ADMIN_ROLE);
    }

// -------------------- Generic setRoleAdmin function ----------------------------------------

    /**
     * @notice Sets the admin role for a specific role
     * @dev By default the admin role for all roles is `DEFAULT_ADMIN_ROLE`.
     * @param role The role whose administrator is being updated
     * @param adminRole The new administrator role for the specified role
     * Emits a {RoleAdminChanged} event
    */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

    /**
     * @notice Sets the payments controller treasury address
     * @dev Only callable by the DEFAULT_ADMIN_ROLE
     * @param newPaymentsControllerTreasury The new payments controller treasury address
    */
    function setPaymentsControllerTreasury(address newPaymentsControllerTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) noZeroAddress(newPaymentsControllerTreasury) {
        require(newPaymentsControllerTreasury != PAYMENTS_CONTROLLER_TREASURY, Errors.InvalidAddress());
        PAYMENTS_CONTROLLER_TREASURY = newPaymentsControllerTreasury;
        emit Events.PaymentsControllerTreasuryUpdated(PAYMENTS_CONTROLLER_TREASURY, newPaymentsControllerTreasury);
    }

    /**
     * @notice Sets the voting controller treasury address
     * @dev Only callable by the DEFAULT_ADMIN_ROLE
     * @param newVotingControllerTreasury The new voting controller treasury address
    */
    function setVotingControllerTreasury(address newVotingControllerTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) noZeroAddress(newVotingControllerTreasury) {
        require(newVotingControllerTreasury != VOTING_CONTROLLER_TREASURY, Errors.InvalidAddress());
        VOTING_CONTROLLER_TREASURY = newVotingControllerTreasury;
        emit Events.VotingControllerTreasuryUpdated(VOTING_CONTROLLER_TREASURY, newVotingControllerTreasury);
    }

    /**
     * @notice Sets the es moca treasury address
     * @dev Only callable by the DEFAULT_ADMIN_ROLE
     * @param newEsMocaTreasury The new es moca treasury address
    */
    function setEsMocaTreasury(address newEsMocaTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) noZeroAddress(newEsMocaTreasury) {
        require(newEsMocaTreasury != ESCROWED_MOCA_TREASURY, Errors.InvalidAddress());
        ESCROWED_MOCA_TREASURY = newEsMocaTreasury; 

        emit Events.EsMocaTreasuryUpdated(ESCROWED_MOCA_TREASURY, newEsMocaTreasury);
    }



// -------------------- HIGH-FREQUENCY ROLE MANAGEMENT ----------------------------------------

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

    // ------- IssuerStakingControllerAdmin role functions -------
    function addIssuerStakingControllerAdmin(address addr) external noZeroAddress(addr) {
        grantRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE, addr);
        emit Events.IssuerStakingControllerAdminAdded(addr, msg.sender);
    }

    function removeIssuerStakingControllerAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE, addr);
        emit Events.IssuerStakingControllerAdminRemoved(addr, msg.sender);
    }

    function isIssuerStakingControllerAdmin(address addr) external view returns (bool) {
        return hasRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE, addr);
    }



    // ------- PaymentsControllerAdmin role functions -------
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



    // ------- VotingControllerAdmin role functions -------
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



    // ------- VotingEscrowMocaAdmin role functions -------
    function addVotingEscrowMocaAdmin(address addr) external noZeroAddress(addr) {
        grantRole(VOTING_ESCROW_MOCA_ADMIN_ROLE, addr);
        emit Events.VotingEscrowMocaAdminAdded(addr, msg.sender);
    }

    function removeVotingEscrowMocaAdmin(address addr) external noZeroAddress(addr) {
        revokeRole(VOTING_ESCROW_MOCA_ADMIN_ROLE, addr);
        emit Events.VotingEscrowMocaAdminRemoved(addr, msg.sender);
    }

    function isVotingEscrowMocaAdmin(address addr) external view returns (bool) {
        return hasRole(VOTING_ESCROW_MOCA_ADMIN_ROLE, addr);
    }


    // ------- EscrowedMocaAdmin role functions -------
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


    // ------- AssetManager role functions ------- | [can only be added by global admin]
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


    // ------- EmergencyExitHandler role functions -------
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

// -------------------- GLOBAL ADMIN FUNCTIONS ------------------------------------------------------------

    function isGlobalAdmin(address addr) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, addr);
    }

// -------------------- MODIFIERS --------------------------------

    modifier noZeroAddress(address addr) {
        require(addr != address(0), Errors.InvalidAddress());
        _;
    }

}