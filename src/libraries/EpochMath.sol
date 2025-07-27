// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Constants} from "./Constants.sol";

/** On week, days, hours, minutes etc.:
    Take care if you perform calendar calculations using these units, 
    because not every year equals 365 days and not even every day has 24 hours because of leap seconds.
 */

library EpochMath {

    // PERIODICITY:  does not account for leap year or leap seconds
    uint128 public constant EPOCH_DURATION = 28 days;                    // ~ 1 month            
    uint256 public constant MIN_LOCK_DURATION = 28 days;
    uint256 public constant MAX_LOCK_DURATION = 672 days;                // ~2 years= 28 days * 24 months


    // returns epoch number for a given timestamp
    function getEpochNumber(uint256 timestamp, uint256 epochZeroTimestamp) internal view returns (uint256) {
        require(timestamp >= epochZeroTimestamp, "Before epoch 0");
        return (timestamp - epochZeroTimestamp) / EPOCH_DURATION;
    }
    

    // returns start time of specified epoch number
    function getEpochStartTimestamp(uint256 epochNum, uint256 epochZeroTimestamp) internal view returns (uint256) {
        return epochZeroTimestamp + (epochNum * EPOCH_DURATION);
    }

    // returns end time of specified epoch number
    function getEpochEndTimestamp(uint256 epochNum, uint256 epochZeroTimestamp) internal view returns (uint256) {
        return getEpochStartTimestamp(epochNum + 1, epochZeroTimestamp);
    }


    // returns current epoch number
    function getCurrentEpochNumber(uint256 epochZeroTimestamp) internal view returns (uint256) {
        return getEpochNumber(block.timestamp, epochZeroTimestamp);
    }

    //returns current epoch start timestamp
    function getCurrentEpochStartTimestamp(uint256 epochZeroTimestamp) internal view returns (uint256) {
        return getEpochStartTimestamp(getCurrentEpochNumber(epochZeroTimestamp), epochZeroTimestamp);
    }

// ------------ needed?

    function isValidEpochTime(uint256 timestamp) internal pure returns (bool) {
        return timestamp % EPOCH_DURATION == 0;
    }


}

// https://github.com/aerodrome-finance/contracts/blob/main/contracts/libraries/ProtocolTimeLibrary.sol