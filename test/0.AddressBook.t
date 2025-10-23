// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

// External: OZ
import {Ownable2Step, Ownable} from "./../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "./../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

// import contracts
import {AddressBook} from "./../src/AddressBook.sol";

// import libraries
import {Events} from "./../src/libraries/Events.sol";
import {Errors} from "./../src/libraries/Errors.sol";


abstract contract State_DeployAddressBook is Test {
    using stdStorage for StdStorage;

// ------------ Contracts ------------
    
    AddressBook public addressBook;    

// ------------ Actors ------------
    address public userA = makeAddr("userA");
    address public globalAdmin = makeAddr("globalAdmin");
    address public newGlobalAdmin = makeAddr("newGlobalAdmin");

    function setUp() public virtual {
        addressBook = new AddressBook(globalAdmin);
    }

}

contract State_DeployAddressBook_Test is State_DeployAddressBook {

    // constructor test
    function test_Constructor_SetsGlobalAdmin() public {
        assertEq(addressBook.owner(), globalAdmin);
    }

    // ------ negative tests: setAddress ------
        function testRevert_OnlyOwnerCanCallSetAddress_InvalidCaller() public {
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
            vm.prank(userA);
            addressBook.setAddress(bytes32("TEST"), address(this));
        }

        function testRevert_CannotSetZeroIdentifier_InvalidIdentifier() public {
            vm.expectRevert(Errors.InvalidId.selector);
            vm.prank(globalAdmin);
            addressBook.setAddress(bytes32(0), address(this));
        }

        function testRevert_CannotSetZeroAddress_InvalidAddress() public {
            vm.expectRevert(Errors.InvalidAddress.selector);
            vm.prank(globalAdmin);
            addressBook.setAddress(bytes32("TEST"), address(0));
        }

    // ------ positive tests: setAddress ------

        function test_SetAddress_OwnerCanCall_ValidIdentifier_ValidAddress() public {
            bytes32 identifier = bytes32("TEST");
            address newAddress = makeAddr("newAddress");

            assertFalse(addressBook.getAddress(identifier) == newAddress, "Address should not be set");

            // Expect correct event emission
            vm.expectEmit(true, true, false, true, address(addressBook));
            emit Events.AddressSet(identifier, newAddress);

            vm.prank(globalAdmin);
            addressBook.setAddress(identifier, newAddress);

            assertTrue(addressBook.getAddress(identifier) == newAddress, "Address should be set");
        }

        function test_SetAddress_OwnerCanCall_OverwriteAddress() public {
            
            bytes32 accessControllerId = addressBook.ACCESS_CONTROLLER();
            address accessControllerAddress = makeAddr("accessControllerAddress");
            address newAccessControllerAddress = makeAddr("newAccessControllerAddress");
            
            assertEq(addressBook.getAddress(accessControllerId), address(0), "Address should not be set");

            // Expect correct event emission
            vm.expectEmit(true, true, false, true, address(addressBook));
            emit Events.AddressSet(accessControllerId, accessControllerAddress);

            //1. set address
            vm.prank(globalAdmin);
            addressBook.setAddress(accessControllerId, accessControllerAddress);

            assertTrue(addressBook.getAddress(accessControllerId) == accessControllerAddress, "Address should be set");

            //2. overwrite address
            vm.expectEmit(true, true, false, true, address(addressBook));
            emit Events.AddressSet(accessControllerId, newAccessControllerAddress);

            vm.prank(globalAdmin);
            addressBook.setAddress(accessControllerId, newAccessControllerAddress);

            assertTrue(addressBook.getAddress(accessControllerId) == newAccessControllerAddress, "New address should be set");
        }

    // ------ sanity tests: setAddress for all constants ------
        function test_SetAddress_OwnerCanCall_ForAllConstants() public {
            // get all constants
            bytes32 MOCA_NATIVE_ADAPTER = addressBook.MOCA_NATIVE_ADAPTER();
            bytes32 USD8 = addressBook.USD8();
            bytes32 MOCA = addressBook.MOCA();
            bytes32 ES_MOCA = addressBook.ES_MOCA();
            bytes32 VOTING_ESCROW_MOCA = addressBook.VOTING_ESCROW_MOCA();
            bytes32 ACCESS_CONTROLLER = addressBook.ACCESS_CONTROLLER();
            bytes32 VOTING_CONTROLLER = addressBook.VOTING_CONTROLLER();
            bytes32 PAYMENTS_CONTROLLER = addressBook.PAYMENTS_CONTROLLER();
            bytes32 TREASURY = addressBook.TREASURY();
            bytes32 ROUTER = addressBook.ROUTER();
            bytes32 ISSUER_STAKING_CONTROLLER = addressBook.ISSUER_STAKING_CONTROLLER();

            // set addresses
            vm.startPrank(globalAdmin);
                addressBook.setAddress(MOCA_NATIVE_ADAPTER, makeAddr("MOCA_NATIVE_ADAPTER"));
                addressBook.setAddress(USD8, makeAddr("USD8"));
                addressBook.setAddress(MOCA, makeAddr("MOCA"));
                addressBook.setAddress(ES_MOCA, makeAddr("ES_MOCA"));
                addressBook.setAddress(VOTING_ESCROW_MOCA, makeAddr("VOTING_ESCROW_MOCA"));
                addressBook.setAddress(ACCESS_CONTROLLER, makeAddr("ACCESS_CONTROLLER"));
                addressBook.setAddress(VOTING_CONTROLLER, makeAddr("VOTING_CONTROLLER"));
                addressBook.setAddress(PAYMENTS_CONTROLLER, makeAddr("PAYMENTS_CONTROLLER"));
                addressBook.setAddress(TREASURY, makeAddr("TREASURY"));
                addressBook.setAddress(ROUTER, makeAddr("ROUTER"));
                addressBook.setAddress(ISSUER_STAKING_CONTROLLER, makeAddr("ISSUER_STAKING_CONTROLLER"));
            vm.stopPrank();

            // check addresses
            assertEq(addressBook.getAddress(MOCA_NATIVE_ADAPTER), makeAddr("MOCA_NATIVE_ADAPTER"));
            assertEq(addressBook.getAddress(USD8), makeAddr("USD8"));
            assertEq(addressBook.getAddress(MOCA), makeAddr("MOCA"));
            assertEq(addressBook.getAddress(ES_MOCA), makeAddr("ES_MOCA"));
            assertEq(addressBook.getAddress(VOTING_ESCROW_MOCA), makeAddr("VOTING_ESCROW_MOCA"));
            assertEq(addressBook.getAddress(ACCESS_CONTROLLER), makeAddr("ACCESS_CONTROLLER"));
            assertEq(addressBook.getAddress(VOTING_CONTROLLER), makeAddr("VOTING_CONTROLLER"));
            assertEq(addressBook.getAddress(PAYMENTS_CONTROLLER), makeAddr("PAYMENTS_CONTROLLER"));
            assertEq(addressBook.getAddress(ISSUER_STAKING_CONTROLLER), makeAddr("ISSUER_STAKING_CONTROLLER"));
            assertEq(addressBook.getAddress(TREASURY), makeAddr("TREASURY"));
            assertEq(addressBook.getAddress(ROUTER), makeAddr("ROUTER"));

            // check view functions
            assertEq(addressBook.getMocaNativeAdapter(), makeAddr("MOCA_NATIVE_ADAPTER"));
            assertEq(addressBook.getUSD8(), makeAddr("USD8"));
            assertEq(addressBook.getMoca(), makeAddr("MOCA"));
            assertEq(addressBook.getEscrowedMoca(), makeAddr("ES_MOCA"));
            assertEq(addressBook.getVotingEscrowMoca(), makeAddr("VOTING_ESCROW_MOCA"));
            assertEq(addressBook.getAccessController(), makeAddr("ACCESS_CONTROLLER"));
            assertEq(addressBook.getVotingController(), makeAddr("VOTING_CONTROLLER"));
            assertEq(addressBook.getPaymentsController(), makeAddr("PAYMENTS_CONTROLLER"));
            assertEq(addressBook.getIssuerStakingController(), makeAddr("ISSUER_STAKING_CONTROLLER"));
            assertEq(addressBook.getTreasury(), makeAddr("TREASURY"));
            assertEq(addressBook.getGlobalAdmin(), globalAdmin);
            assertEq(addressBook.getRouter(), makeAddr("ROUTER"));
        }
    
    // ------ state transition test: pause ------

        // owner cannot unpause when contract is not paused
        function testRevert_OwnerCallsUnpause_ContractNotPaused() public {
            assertEq(addressBook.paused(), false);

            // Expect revert
            vm.expectRevert(Pausable.ExpectedPause.selector);
            
            vm.prank(globalAdmin);
            addressBook.unpause();
        }

        // user cannot unpause when contract is not paused
        function testRevert_UserCallsUnpause_ContractNotPaused() public {
            assertEq(addressBook.paused(), false);

            // Expect revert
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
            
            vm.prank(userA);
            addressBook.unpause();
        }

        // owner cannot freeze when contract is not paused
        function testRevert_OwnerCallsFreeze_ContractNotPaused() public {
            assertEq(addressBook.paused(), false);
            assertEq(addressBook.isFrozen(), 0);

            vm.expectRevert(Pausable.ExpectedPause.selector);
            vm.prank(globalAdmin);
            addressBook.freeze();
        }

        // user cannot freeze when contract is not paused
        function testRevert_UserCallsFreeze_ContractNotPaused() public {
            assertEq(addressBook.paused(), false);
            assertEq(addressBook.isFrozen(), 0);

            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
            vm.prank(userA);
            addressBook.freeze();
        }

        // owner can pause when contract is not paused
        function test_Pause_OwnerCanCall_PausesContract() public {
            assertEq(addressBook.paused(), false);

            vm.prank(globalAdmin);
            addressBook.pause();

            assertTrue(addressBook.paused());
        }
    
}


abstract contract State_Paused is State_DeployAddressBook {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        addressBook.pause();
    }
}

contract State_Paused_Test is State_Paused {

    // ------ negative tests: pause + unpause ------
        
        // owner cannot pause when contract is paused
        function testRevert_OwnerCallsPause_ContractPaused() public {
            assertEq(addressBook.paused(), true);

            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(globalAdmin);
            addressBook.pause();
        }

        // user cannot unpause when contract is paused
        function testRevert_UserCallsUnpause_ContractPaused() public {
            assertEq(addressBook.paused(), true);

            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
            vm.prank(userA);
            addressBook.unpause();
        }


    // ------ positive tests: unpause ------

        // owner can unpause when contract is paused
        function test_Unpause_OwnerCanCall_UnpausesContract() public {
            assertEq(addressBook.paused(), true);

            vm.prank(globalAdmin);
            addressBook.unpause();

            assertEq(addressBook.paused(), false);
        }

        // owner can freeze when contract is paused
        function test_Freeze_OwnerCanCall_Freeze() public {
            assertEq(addressBook.paused(), true);
            assertEq(addressBook.isFrozen(), 0);

            vm.expectEmit();
            emit Events.ContractFrozen();

            vm.prank(globalAdmin);
            addressBook.freeze();

            assertEq(addressBook.isFrozen(), 1);
        }
    
    
    // ------ negative tests: transfer ownership ------
        function testRevert_UserCallsTransferOwnership_ContractPaused() public {
            assertEq(addressBook.paused(), true);
            assertEq(addressBook.isFrozen(), 0);

            // expect revert
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, userA));
            vm.prank(userA);
            addressBook.transferOwnership(newGlobalAdmin);
        }

    // ------ positive tests: transfer ownership ------

        // owner can transfer ownership
        function test_TransferOwnership_OwnerCanCall_TransfersOwnership() public {
            assertEq(addressBook.paused(), true);
            assertEq(addressBook.isFrozen(), 0);
            
            // no pending owner
            assertTrue(addressBook.pendingOwner() == address(0));

            // transfer ownership
            vm.prank(globalAdmin);
            addressBook.transferOwnership(newGlobalAdmin);

            // pending owner set
            assertTrue(addressBook.pendingOwner() == newGlobalAdmin);
            assertTrue(addressBook.owner() == globalAdmin);

            // accept ownership
            vm.prank(newGlobalAdmin);
            addressBook.acceptOwnership();

            // pending owner cleared
            assertTrue(addressBook.pendingOwner() == address(0));
            assertTrue(addressBook.owner() == newGlobalAdmin);
        }
}

abstract contract State_Frozen is State_Paused {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        addressBook.freeze();
    }
}

contract State_Frozen_Test is State_Frozen {

    // confirm frozen state
    function test_Frozen_OwnerCanCall_Frozen() public {
        assertEq(addressBook.isFrozen(), 1);
    }
   
    // ------ negative tests: pause + unpause ------
        
    function testRevert_OwnerCallsPause_ContractFrozen() public {
        assertEq(addressBook.isFrozen(), 1);
        assertEq(addressBook.paused(), true);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(globalAdmin);
        addressBook.pause();
    }

    function testRevert_OwnerCallsUnpause_ContractFrozen() public {

        assertEq(addressBook.isFrozen(), 1);
        assertEq(addressBook.paused(), true);

        vm.expectRevert(Errors.IsFrozen.selector);
        vm.prank(globalAdmin);
        addressBook.unpause();
    }
}


/**
    Ownership can be transferred when contract is paused.
    Why?

    Consider the standard execution flow when pause might be triggered:
    1. something awry/malicious happens in the protocol
    2. owner pauses the contract
    3. owner assesses the severity of the issue and decides whether to freeze the contract
    4. if critical, owner freezes the contract

    Considering its the owner who is the only one allowed to call pause, seems immaterial whether transferring ownership should be blocked during paused state.
 */