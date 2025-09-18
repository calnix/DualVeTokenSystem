// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAccessControlLayer
 * @author Calnix
 * @notice Defines the basic interface for AccessControlLayer.sol
 */

interface IAccessController {
    function isGlobalAdmin(address addr) external view returns (bool);
    
    // Generic
    function isMonitor(address addr) external view returns (bool);
    function isCronJob(address addr) external view returns (bool);
    function isEmergencyExitHandler(address addr) external view returns (bool);
    function isAssetManager(address addr) external view returns (bool);


    // Permissions for PaymentsController
    function isPaymentsControllerAdmin(address addr) external view returns (bool);
    // Used in VotingController modifiers but NOT in IAccessController interface:
    function isVotingControllerAdmin(address addr) external view returns (bool);

}
