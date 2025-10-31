// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAccessController
 * @author Calnix
 * @notice Interface for AccessController, managing all system roles and permissions.
 */
interface IAccessController {
    // ---- RISK MANAGEMENT ----

    function isFrozen() external view returns (uint256);
    

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

// -------------------- HIGH-FREQUENCY ROLES --------------------

    /**
     * @notice Returns true if the address has the Monitor role.
     * @param addr The address to check.
     */
    function isMonitor(address addr) external view returns (bool);

    /**
     * @notice Returns true if the address has the CronJob role.
     * @param addr The address to check.
     */
    function isCronJob(address addr) external view returns (bool);

    /**
     * @notice Adds an address as Monitor.
     * @param addr The address to add.
     */
    function addMonitor(address addr) external;

    /**
     * @notice Removes an address from Monitor role.
     * @param addr The address to remove.
     */
    function removeMonitor(address addr) external;

    /**
     * @notice Adds an address as CronJob.
     * @param addr The address to add.
     */
    function addCronJob(address addr) external;

    /**
     * @notice Removes an address from CronJob role.
     * @param addr The address to remove.
     */
    function removeCronJob(address addr) external;

    // -------------------- OPERATIONAL ADMIN ROLES --------------------

    /**
     * @notice Returns true if the address has the MonitorAdmin role.
     * @param addr The address to check.
     */
    function isMonitorAdmin(address addr) external view returns (bool);

    /**
     * @notice Returns true if the address has the CronJobAdmin role.
     * @param addr The address to check.
     */
    function isCronJobAdmin(address addr) external view returns (bool);

    /**
     * @notice Adds an address as MonitorAdmin.
     * @param addr The address to add.
     */
    function addMonitorAdmin(address addr) external;

    /**
     * @notice Removes an address from MonitorAdmin role.
     * @param addr The address to remove.
     */
    function removeMonitorAdmin(address addr) external;

    /**
     * @notice Adds an address as CronJobAdmin.
     * @param addr The address to add.
     */
    function addCronJobAdmin(address addr) external;

    /**
     * @notice Removes an address from CronJobAdmin role.
     * @param addr The address to remove.
     */
    function removeCronJobAdmin(address addr) external;

// -------------------- LOW-FREQUENCY STRATEGIC ROLES --------------------

    /**
     * @notice Returns true if the address has the IssuerStakingControllerAdmin role.
     * @param addr The address to check.
     */
    function isIssuerStakingControllerAdmin(address addr) external view returns (bool);

    /**
     * @notice Returns true if the address has the PaymentsControllerAdmin role.
     * @param addr The address to check.
     */
    function isPaymentsControllerAdmin(address addr) external view returns (bool);

    /**
     * @notice Returns true if the address has the VotingControllerAdmin role.
     * @param addr The address to check.
     */
    function isVotingControllerAdmin(address addr) external view returns (bool);

    /**
     * @notice Returns true if the address has the EscrowedMocaAdmin role.
     * @param addr The address to check.
     */
    function isEscrowedMocaAdmin(address addr) external view returns (bool);

    /**
     * @notice Adds an address as PaymentsControllerAdmin.
     * @param addr The address to add.
     */
    function addPaymentsControllerAdmin(address addr) external;

    /**
     * @notice Removes an address from PaymentsControllerAdmin role.
     * @param addr The address to remove.
     */
    function removePaymentsControllerAdmin(address addr) external;

    /**
     * @notice Adds an address as VotingControllerAdmin.
     * @param addr The address to add.
     */
    function addVotingControllerAdmin(address addr) external;

    /**
     * @notice Removes an address from VotingControllerAdmin role.
     * @param addr The address to remove.
     */
    function removeVotingControllerAdmin(address addr) external;

    /**
     * @notice Adds an address as EscrowedMocaAdmin.
     * @param addr The address to add.
     */
    function addEscrowedMocaAdmin(address addr) external;

    /**
     * @notice Removes an address from EscrowedMocaAdmin role.
     * @param addr The address to remove.
     */
    function removeEscrowedMocaAdmin(address addr) external;

    // -------------------- ASSET MANAGER ROLE --------------------

    /**
     * @notice Returns true if the address has the AssetManager role.
     * @param addr The address to check.
     */
    function isAssetManager(address addr) external view returns (bool);

    /**
     * @notice Adds an address as AssetManager.
     * @param addr The address to add.
     */
    function addAssetManager(address addr) external;

    /**
     * @notice Removes an address from AssetManager role.
     * @param addr The address to remove.
     */
    function removeAssetManager(address addr) external;

    // -------------------- EMERGENCY EXIT HANDLER ROLE --------------------

    /**
     * @notice Returns true if the address has the EmergencyExitHandler role.
     * @param addr The address to check.
     */
    function isEmergencyExitHandler(address addr) external view returns (bool);

    /**
     * @notice Adds an address as EmergencyExitHandler.
     * @param addr The address to add.
     */
    function addEmergencyExitHandler(address addr) external;

    /**
     * @notice Removes an address from EmergencyExitHandler role.
     * @param addr The address to remove.
     */
    function removeEmergencyExitHandler(address addr) external;

    // -------------------- GLOBAL ADMIN ROLE --------------------

    /**
     * @notice Returns true if the address has the GlobalAdmin (DEFAULT_ADMIN_ROLE).
     * @param addr The address to check.
     */
    function isGlobalAdmin(address addr) external view returns (bool);

}