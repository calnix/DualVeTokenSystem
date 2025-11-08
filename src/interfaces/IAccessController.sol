// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IAccessControl} from "./../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";

/**
 * @title IAccessController
 * @author Calnix
 * @notice Interface for AccessController, managing all system roles and permissions.
 */
interface IAccessController is IAccessControl {

    // ---- TREASURY ADDRESSES ----

    function PAYMENTS_CONTROLLER_TREASURY() external view returns (address);
    function VOTING_CONTROLLER_TREASURY() external view returns (address);
    function ESCROWED_MOCA_TREASURY() external view returns (address);

    function setPaymentsControllerTreasury(address newPaymentsControllerTreasury) external;
    function setVotingControllerTreasury(address newVotingControllerTreasury) external;
    function setEsMocaTreasury(address newEsMocaTreasury) external;

    // ---- GENERIC ROLE ADMIN MANAGEMENT ----

    function setRoleAdmin(bytes32 role, bytes32 adminRole) external;

    // ---- HIGH-FREQUENCY ROLES ----

    // Monitor role
    function isMonitor(address addr) external view returns (bool);
    function addMonitor(address addr) external;
    function removeMonitor(address addr) external;

    // CronJob role
    function isCronJob(address addr) external view returns (bool);
    function addCronJob(address addr) external;
    function removeCronJob(address addr) external;

    // ---- OPERATIONAL ADMIN ROLES ----

    // Monitor Admin role
    function isMonitorAdmin(address addr) external view returns (bool);
    function addMonitorAdmin(address addr) external;
    function removeMonitorAdmin(address addr) external;

    // CronJob Admin role
    function isCronJobAdmin(address addr) external view returns (bool);
    function addCronJobAdmin(address addr) external;
    function removeCronJobAdmin(address addr) external;

    // ---- LOW-FREQUENCY STRATEGIC ROLES (managed by DEFAULT_ADMIN_ROLE) ----

    // IssuerStakingControllerAdmin
    function isIssuerStakingControllerAdmin(address addr) external view returns (bool);
    function addIssuerStakingControllerAdmin(address addr) external;
    function removeIssuerStakingControllerAdmin(address addr) external;

    // PaymentsControllerAdmin
    function isPaymentsControllerAdmin(address addr) external view returns (bool);
    function addPaymentsControllerAdmin(address addr) external;
    function removePaymentsControllerAdmin(address addr) external;

    // VotingControllerAdmin
    function isVotingControllerAdmin(address addr) external view returns (bool);
    function addVotingControllerAdmin(address addr) external;
    function removeVotingControllerAdmin(address addr) external;

    // VotingEscrowMocaAdmin
    function isVotingEscrowMocaAdmin(address addr) external view returns (bool);
    function addVotingEscrowMocaAdmin(address addr) external;
    function removeVotingEscrowMocaAdmin(address addr) external;

    // EscrowedMocaAdmin
    function isEscrowedMocaAdmin(address addr) external view returns (bool);
    function addEscrowedMocaAdmin(address addr) external;
    function removeEscrowedMocaAdmin(address addr) external;

    // ---- ASSET MANAGER ROLE ----

    function isAssetManager(address addr) external view returns (bool);
    function addAssetManager(address addr) external;
    function removeAssetManager(address addr) external;

    // ---- EMERGENCY EXIT HANDLER ROLE ----

    function isEmergencyExitHandler(address addr) external view returns (bool);
    function addEmergencyExitHandler(address addr) external;
    function removeEmergencyExitHandler(address addr) external;

    // ---- GLOBAL ADMIN ROLE ----

    function isGlobalAdmin(address addr) external view returns (bool);
}
