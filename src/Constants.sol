// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Constants {

    // EpochMath: does not account for leap year or leap seconds
    uint128 internal constant EPOCH_DURATION = 28 days;                    // ~ 1 month            
    uint256 internal constant MIN_LOCK_DURATION = 28 days;
    uint256 internal constant MAX_LOCK_DURATION = 672 days;                // ~2 years= 28 days * 24 months
    
    // veMoca: early redemption penalty
    uint256 public constant MAX_PENALTY_PCT = 50;      // Default 50% maximum penalty
    uint256 public constant PRECISION_BASE = 10_000;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

}