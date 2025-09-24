// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAccessControlLayer
 * @author Calnix
 * @notice Defines the basic interface for AccessControlLayer.sol
 */

interface IAccessController {

    // admin roles
    function isGlobalAdmin(address addr) external view returns (bool);
    function isMonitorAdmin(address addr) external view returns (bool);
    function isCronJobAdmin(address addr) external view returns (bool);

    // Operational roles [high frequency]
    function isMonitor(address addr) external view returns (bool);
    function isCronJob(address addr) external view returns (bool);
    
    // Asset manager roles [Medium frequency]
    function isAssetManager(address addr) external view returns (bool);

    // Contract admins [low frequency]
    function isPaymentsControllerAdmin(address addr) external view returns (bool);
    function isVotingControllerAdmin(address addr) external view returns (bool);
    function isEscrowedMocaAdmin(address addr) external view returns (bool);

    // Emergency exit handler role [very low frequency]
    function isEmergencyExitHandler(address addr) external view returns (bool);


}
