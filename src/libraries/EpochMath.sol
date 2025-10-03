// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;


/**
 * @title EpochMath
 * @author Calnix [@cal_nix]
 * @notice Library for epoch-based time calculations used across the Moca protocol.
 * @dev Provides utilities for epoch number, start/end timestamps, and lock duration constants.
 */


/** On week, days, hours, minutes etc.:
    Take care if you perform calendar calculations using these units, 
    because not every year equals 365 days and not even every day has 24 hours because of leap seconds.
 */

library EpochMath {

    // PERIODICITY:  does not account for leap year or leap seconds
    uint256 internal constant EPOCH_DURATION = 14 days;                    
    uint256 internal constant MIN_LOCK_DURATION = 28 days;            // double the epoch duration for minimum lock duration: for forward decay liveliness
    uint256 internal constant MAX_LOCK_DURATION = 728 days;               


    ///@dev returns epoch number for a given timestamp
    function getEpochNumber(uint256 timestamp) internal pure returns (uint256) {
        return timestamp / EPOCH_DURATION;
    }

    ///@dev returns current epoch number
    function getCurrentEpochNumber() internal view returns (uint256) {
        return getEpochNumber(block.timestamp);
    }

    ///@dev returns epoch start time for a given timestamp
    function getEpochStartForTimestamp(uint256 timestamp) internal pure returns (uint256) {
        // intentionally divide first to "discard" remainder
        return (timestamp / EPOCH_DURATION) * EPOCH_DURATION;   // forge-lint: disable-line(divide-before-multiply)
    }

    ///@dev returns epoch end time for a given timestamp
    function getEpochEndForTimestamp(uint256 timestamp) internal pure returns (uint256) {
        return getEpochStartForTimestamp(timestamp) + EPOCH_DURATION;
    }
    

    ///@dev returns current epoch start time | uint128: Checkpoint{veBla, uint128 lastUpdatedAt}
    function getCurrentEpochStart() internal view returns (uint128) {
        return uint128(getEpochStartForTimestamp(block.timestamp));
    }

    ///@dev returns current epoch end time
    function getCurrentEpochEnd() internal view returns (uint256) {
        return getEpochEndTimestamp(getCurrentEpochNumber());
    }

    function getEpochStartTimestamp(uint256 epoch) internal pure returns (uint256) {
        return epoch * EPOCH_DURATION;
    }

    ///@dev returns epoch end time for a given epoch number
    function getEpochEndTimestamp(uint256 epoch) internal pure returns (uint256) {
        // end of epoch:N is the start of epoch:N+1
        return (epoch + 1) * EPOCH_DURATION;
    }

    // used in _createLockFor()
    function isValidEpochTime(uint256 timestamp) internal pure returns (bool) {
        return timestamp % EPOCH_DURATION == 0;
    }

}