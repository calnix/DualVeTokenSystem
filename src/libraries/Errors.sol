// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Errors {

    error IsFrozen();

    // Access control
    error CallerNotRiskOrPoolAdmin();
}