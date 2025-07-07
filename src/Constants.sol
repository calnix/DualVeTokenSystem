// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Constants {

    // PERIODICITY:  does not account for leap year or leap seconds
    uint128 public constant WEEK = 7 days;   // note: remove this after confirmation to 4 week epoch
    uint128 public constant EPOCH_DURATION = 4 weeks;      // 28 days           
    uint256 public constant MIN_LOCK_DURATION = EPOCH_DURATION;
    uint256 public constant MAX_LOCK_DURATION = 104 weeks; // ~2 years

    // ROLES
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");   // only pause
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // admin fns to update params
    bytes32 public constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE"); // stakeOnBehalf

    
    // veMoca: early redemption penalty
    uint256 public constant MAX_PENALTY_PCT = 50; // Default 50% maximum penalty
    uint256 public constant PRECISION_BASE = 100; // 100%: 100, 1%: 1 | no decimal places
    
    // votingController
    //uint256 public constant MAX_COMMISSION_BPS = 5000; // 50% maximum commission in basis points

}