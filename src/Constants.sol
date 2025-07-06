// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Constants {

    // PERIODICITY:  does not account for leap year or leap seconds
    uint128 public constant WEEK = 7 days;              
    uint256 public constant MIN_LOCK_DURATION = 1 weeks;
    uint256 public constant MAX_LOCK_DURATION = 104 weeks; // ~2 years

    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");   // only pause
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // admin fns to update params
    bytes32 public constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE"); // stakeOnBehalf

}