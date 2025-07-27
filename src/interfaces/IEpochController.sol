// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IEpochController
 * @author Calnix
 * @notice Defines the basic interface for EpochController.sol
 */

interface IEpochController {
    
    // get current epoch: caller might need to update epoch
    function getCurrentEpoch() external returns (uint256);

    // get next epoch: caller might need to update epoch
    function getNextEpoch() external returns (uint256);

    // get current epoch start timestamp
    function getCurrentEpochStartTimestamp() external view returns (uint256);

    // get next epoch start timestamp
    function getNextEpochStartTimestamp() external view returns (uint256);

    // get epoch zero timestamp
    function getEpochZeroTimestamp() external view returns (uint256);

    // get epoch duration
    function getEpochDuration() external view returns (uint256);
}
