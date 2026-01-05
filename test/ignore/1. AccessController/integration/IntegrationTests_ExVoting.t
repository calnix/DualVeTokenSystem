// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

import "../utils/TestingHarness.sol";

/**
    Note:
    - this test is for the integration of the following contracts:
        - AddressBook
        - AccessController
        - PaymentsController
        - IssuerStakingController
        
    They will operate on with dummy tokens, and the focus is on role changes and permissions.
 */

abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}