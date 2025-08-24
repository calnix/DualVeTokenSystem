// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Errors {

    // --------- Generic ---------
    error InvalidUser(); 
    error InvalidAmount();
    error InvalidExpiry();
    error InvalidLockDuration();


    error IsFrozen();

    // Access control
    error CallerNotRiskOrPoolAdmin();
}