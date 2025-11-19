// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "./PaymentsController.t.sol";

abstract contract StateT10_SetPaymentsControllerTreasury is StateT10_Verifier1StakeMOCA {

    function setUp() public virtual override {
        super.setUp();
    }
}

contract StateT10_SetPaymentsControllerTreasury_Test is StateT10_SetPaymentsControllerTreasury {
    
    // only callable by DEFAULT_ADMIN_ROLE
    function testRevert_SetPaymentsControllerTreasury_NotGlobalAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, paymentsControllerAdmin, paymentsController.DEFAULT_ADMIN_ROLE()));
        
        vm.prank(paymentsControllerAdmin);
        paymentsController.setPaymentsControllerTreasury(address(0x1234));
    }

    // new treasury address is not zero address
    function testRevert_SetPaymentsControllerTreasury_NewTreasuryAddressIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(globalAdmin);
        paymentsController.setPaymentsControllerTreasury(address(0));
    }

    // new treasury address is not the same as the current payments controller address
    function testRevert_SetPaymentsControllerTreasury_NewTreasuryAddressIsSameAsPaymentsController() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(globalAdmin);
        paymentsController.setPaymentsControllerTreasury(address(paymentsController));
    }

    // new treasury address is not the same as the current treasury address
    function testRevert_SetPaymentsControllerTreasury_NewTreasuryAddressIsSameAsCurrentTreasury() public {
        address currentTreasury = paymentsController.PAYMENTS_CONTROLLER_TREASURY();
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(globalAdmin);
        paymentsController.setPaymentsControllerTreasury(currentTreasury);
    }

    // update treasury address
    function testCan_SetPaymentsControllerTreasury() public {
        // record state before
        address currentTreasury = paymentsController.PAYMENTS_CONTROLLER_TREASURY();
        address newTreasury = address(0x1234);

        // expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.PaymentsControllerTreasuryUpdated(currentTreasury, newTreasury);

        vm.prank(globalAdmin);
        paymentsController.setPaymentsControllerTreasury(newTreasury);

        // check storage state after
        assertEq(paymentsController.PAYMENTS_CONTROLLER_TREASURY(), newTreasury, "Treasury address should be updated");
    }

}