// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAccessControlLayer
 * @author Calnix
 * @notice Defines the basic interface for AccessControlLayer.sol
 */

interface IAccessController {

    function isMonitor(address addr) external view returns (bool);
    function isOperator(address addr) external view returns (bool);
    function isCronJob(address addr) external view returns (bool);
    function isEmergencyExitHandler(address addr) external view returns (bool);
    function isGlobalAdmin(address addr) external view returns (bool);

    //function isTreasury(address addr) external view returns (bool);

    //function isVerifier(address user) external view returns (bool);
    //function isIssuer(address user) external view returns (bool);


}
