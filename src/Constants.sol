// SPDX-License-Identifier: MIT

pragma solidity 0.8.27;

library Constants {

    // PERIODICITY:  does not account for leap year or leap seconds
    uint128 public constant WEEK = 7 days;              
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;
    uint256 public constant MAX_LOCK_DURATION = 104 weeks; // ~2 years


}