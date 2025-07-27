// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "./libraries/EpochMath.sol";


/**
    Epoch starts from 0
    Epoch 0 is the first epoch
    Epoch 1 is the second epoch
    ...
    epochZeroTimestamp is the startTime of Epoch 0
    - allows us to let Epoch 0 start in some future time if needed
    - epochZeroTimestamp is the anchor for all other epochs

    by having this contract as a standalone epoch tracker,
    we can plug in other contracts as needed and upgrade them,
    while keeping epoch alignment.

    i don't expect the need to redeploy this contract, 
    so other contracts call on this contract for their queries, instead of going thru AddressBook

 */

contract EpochController {
    
    // epoch anchor
    uint128 public immutable EPOCH_ZERO_TIMESTAMP;
    
    uint256 public CURRENT_EPOCH_START_TIME;
    uint256 public CURRENT_EPOCH;       // epoch number

    uint256 public NEXT_EPOCH_START_TIME;
    uint256 public NEXT_EPOCH;


    constructor(uint256 epochZeroTimestamp) {

        EPOCH_ZERO_TIMESTAMP = CURRENT_EPOCH_START_TIME = epochZeroTimestamp;

        NEXT_EPOCH_START_TIME = epochZeroTimestamp + EpochMath.EPOCH_DURATION;
        NEXT_EPOCH = 1;
    }


    function getCurrentEpoch() external returns (uint256) {
        _updateEpoch();
        return CURRENT_EPOCH;
    }

    function _updateEpoch() internal {
        if(block.timestamp >= NEXT_EPOCH_START_TIME) {

            // update current
            CURRENT_EPOCH_START_TIME = NEXT_EPOCH_START_TIME;
            CURRENT_EPOCH = NEXT_EPOCH;

            // update next
            NEXT_EPOCH_START_TIME = CURRENT_EPOCH_START_TIME + EpochMath.EPOCH_DURATION;
            ++NEXT_EPOCH;

            //emit EpochUpdated(CURRENT_EPOCH_START_TIME, CURRENT_EPOCH, NEXT_EPOCH_START_TIME, NEXT_EPOCH);
        }
    }

}