// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Constants {


    // ROLES
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");   // only pause
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); // admin fns to update params
    bytes32 public constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE"); // stakeOnBehalf

    
    // veMoca: early redemption penalty
    uint256 public constant MAX_PENALTY_PCT = 50;      // Default 50% maximum penalty
    uint256 public constant PRECISION_BASE = 10_000;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

}