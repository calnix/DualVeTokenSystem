// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

// External: OZ
import {AccessControl} from "./../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {IAccessControl} from "./../lib/openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "./../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

// import contracts
import {AccessController, IAddressBook} from "./../src/AccessController.sol";
import {AddressBook} from "./../src/AddressBook.sol";

// import libraries
import {Events} from "./../src/libraries/Events.sol";
import {Errors} from "./../src/libraries/Errors.sol";


abstract contract State_DeployAccessController is Test {
    using stdStorage for StdStorage;

// ------------ Contracts ------------
    
    AddressBook public addressBook;
    AccessController public accessController;

// ------------ Actors ------------
    
    address public userA = makeAddr("userA");
    address public globalAdmin = makeAddr("globalAdmin");
    address public newGlobalAdmin = makeAddr("newGlobalAdmin");

    address public monitorAdmin = makeAddr("monitorAdmin");
    address public cronJobAdmin = makeAddr("cronJobAdmin");

    address public monitor = makeAddr("monitor");
    address public cronJob = makeAddr("cronJob");

    address public paymentsControllerAdmin = makeAddr("paymentsControllerAdmin");
    address public votingControllerAdmin = makeAddr("votingControllerAdmin");
    address public votingEscrowMocaAdmin = makeAddr("votingEscrowMocaAdmin");
    address public escrowedMocaAdmin = makeAddr("escrowedMocaAdmin");
    address public assetManager = makeAddr("assetManager");
    address public emergencyExitHandler = makeAddr("emergencyExitHandler");

    function setUp() public virtual {
        addressBook = new AddressBook(globalAdmin);
        accessController = new AccessController(address(addressBook));
    }
}


contract State_DeployAccessController_Test is State_DeployAccessController {

    // constructor test: AccessController gets global admin from address book
    function test_Constructor_SetsGlobalAdmin() public {
        // check address book
        assertTrue(accessController.getAddressBook() == address(addressBook));      
        // check global admin
        assertTrue(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), globalAdmin));

        // globalAdmin has DEFAULT_ADMIN_ROLE
        assertTrue(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), globalAdmin));
        
        // Operational role administrators managed by global admin
        assertEq(accessController.getRoleAdmin(accessController.MONITOR_ADMIN_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.CRON_JOB_ADMIN_ROLE()), accessController.DEFAULT_ADMIN_ROLE());

        // High-frequency roles managed by their dedicated admins
        assertEq(accessController.getRoleAdmin(accessController.MONITOR_ROLE()), accessController.MONITOR_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.CRON_JOB_ROLE()), accessController.CRON_JOB_ADMIN_ROLE());

        // Low-frequency roles managed directly by global admin
        assertEq(accessController.getRoleAdmin(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.VOTING_CONTROLLER_ADMIN_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.ESCROWED_MOCA_ADMIN_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.ASSET_MANAGER_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
        assertEq(accessController.getRoleAdmin(accessController.EMERGENCY_EXIT_HANDLER_ROLE()), accessController.DEFAULT_ADMIN_ROLE());
    }


    // ------ negative tests: setRoleAdmin ------
        //note: foundry bug, when using expectRevert, the call doesn't revert.
        // but when removing vm.expectRevert, the call reverts as expected.
        // so we use try/catch to verify the call reverted.
        function testRevert_OnlyGlobalAdminCanCallSetRoleAdmin_InvalidCaller() public {
            // Verify userA doesn't have the role
            assertFalse(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), userA));
            
            // Test that the call reverts
            bool success = true;
            
            // Set up the prank first
            vm.prank(userA);
            
            // Then try the function call
            try accessController.setRoleAdmin(accessController.MONITOR_ADMIN_ROLE(), accessController.DEFAULT_ADMIN_ROLE()) {
                // If we get here, the call succeeded (unexpected)
                success = true;
            } catch {
                // If we get here, the call reverted (expected)
                success = false;
            }
            
            // Assert that the call failed
            assertFalse(success, "Call should have reverted but didn't");
        }
    
    // ------ positive tests: setRoleAdmin ------
        function test_SetRoleAdmin_GlobalAdminCanCall_SetsRoleAdmin() public {
            bytes32 role = bytes32("TEST");
            bytes32 adminRole = bytes32("TEST_ADMIN_ROLE");

            // Check initial state - role admin should be DEFAULT_ADMIN_ROLE by default
            assertEq(accessController.getRoleAdmin(role), accessController.DEFAULT_ADMIN_ROLE());
            
            // Set new role admin
            vm.prank(globalAdmin);
            accessController.setRoleAdmin(role, adminRole);

            // Verify the role admin was changed
            assertEq(accessController.getRoleAdmin(role), adminRole);
        }
    
    // --- state transition: setRoleAdmin ------
        
        // userA cannot grant monitor admin role
        function test_UserA_CannotGrantMonitorAdminRole() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addMonitorAdmin(monitorAdmin);
        }

        // global admin can grant monitor admin role
        function test_GlobalAdmin_GrantsMonitorAdminRole() public {

            // Verify the address doesn't have the role initially
            assertFalse(accessController.hasRole(accessController.MONITOR_ADMIN_ROLE(), monitorAdmin));
            
            // Global admin grants MONITOR_ADMIN_ROLE to the address
            vm.prank(globalAdmin);
            accessController.addMonitorAdmin(monitorAdmin);
            
            // Verify the address now has the role
            assertTrue(accessController.hasRole(accessController.MONITOR_ADMIN_ROLE(), monitorAdmin));
            assertTrue(accessController.isMonitorAdmin(monitorAdmin));
        }
}

abstract contract State_MonitorAdminSet is State_DeployAccessController {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addMonitorAdmin(monitorAdmin);
    }
}

contract State_MonitorAdminSet_Test is State_MonitorAdminSet {

    // ------ addMonitor ------
        
        // monitor admin can add monitor
        function test_MonitorAdmin_CanAddMonitor() public {
            assertTrue(accessController.hasRole(accessController.MONITOR_ADMIN_ROLE(), monitorAdmin));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.MonitorAdded(monitor, monitorAdmin);

            vm.prank(monitorAdmin);
            accessController.addMonitor(monitor);

            assertTrue(accessController.hasRole(accessController.MONITOR_ROLE(), monitor));

            // check view
            assertTrue(accessController.isMonitor(monitor));
        }

        // global admin cannot add monitor
        function test_GlobalAdmin_CannotAddMonitor() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, globalAdmin, accessController.MONITOR_ADMIN_ROLE()));
            vm.prank(globalAdmin);
            accessController.addMonitor(monitor);
        }

    // ------ removeMonitor ------
        
        // monitor admin can remove monitor
        function test_MonitorAdmin_CanRemoveMonitor() public {
            test_MonitorAdmin_CanAddMonitor();

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.MonitorRemoved(monitor, monitorAdmin);

            vm.prank(monitorAdmin);
            accessController.removeMonitor(monitor);

            assertFalse(accessController.hasRole(accessController.MONITOR_ROLE(), monitor));

            // check view
            assertFalse(accessController.isMonitor(monitor));
        }

        // global admin cannot remove monitor
        function test_GlobalAdmin_CannotRemoveMonitor() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, globalAdmin, accessController.MONITOR_ADMIN_ROLE()));
            vm.prank(globalAdmin);
            accessController.removeMonitor(monitor);
        }
    
    // ------ removeMonitorAdmin ------

        // monitor cannot remove monitor admin
        function test_Monitor_CannotRemoveMonitorAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, monitor, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(monitor);
            accessController.removeMonitorAdmin(monitorAdmin);
        }
        
        // global admin can remove monitor admin
        function test_GlobalAdmin_CanRemoveMonitorAdmin() public {
            
            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.MonitorAdminRemoved(monitorAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeMonitorAdmin(monitorAdmin);

            assertFalse(accessController.hasRole(accessController.MONITOR_ADMIN_ROLE(), monitorAdmin));
            assertFalse(accessController.isMonitorAdmin(monitorAdmin));
        }
    
    // ------ state transition: cronJobAdminSet ------
        function test_GlobalAdmin_GrantsCronJobAdminRole() public {

            // Verify the address doesn't have the role initially
            assertFalse(accessController.hasRole(accessController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin));
            
            // Global admin grants CRON_JOB_ADMIN_ROLE
            vm.prank(globalAdmin);
            accessController.addCronJobAdmin(cronJobAdmin);
            
            // Verify the address now has the role
            assertTrue(accessController.hasRole(accessController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin));
            assertTrue(accessController.isCronJobAdmin(cronJobAdmin));
        }
}

abstract contract State_CronJobAdminSet is State_MonitorAdminSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addCronJobAdmin(cronJobAdmin);
    }
}

contract State_CronJobAdminSet_Test is State_CronJobAdminSet {

    // ------ addCronJob ------
        
        // cronjob admin can add cronjob
        function test_CronJobAdmin_CanAddCronJob() public {
            assertTrue(accessController.hasRole(accessController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.CronJobAdded(cronJob, cronJobAdmin);

            vm.prank(cronJobAdmin);
            accessController.addCronJob(cronJob);

            assertTrue(accessController.hasRole(accessController.CRON_JOB_ROLE(), cronJob));

            // check view
            assertTrue(accessController.isCronJob(cronJob));
        }

        // global admin cannot add cronjob
        function test_GlobalAdmin_CannotAddCronJob() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, globalAdmin, accessController.CRON_JOB_ADMIN_ROLE()));
            vm.prank(globalAdmin);
            accessController.addCronJob(cronJob);
        }

    // ------ removeCronJob ------
        
        // cronjob admin can remove cronjob
        function test_CronJobAdmin_CanRemoveCronJob() public {
            test_CronJobAdmin_CanAddCronJob();

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.CronJobRemoved(cronJob, cronJobAdmin);

            vm.prank(cronJobAdmin);
            accessController.removeCronJob(cronJob);

            assertFalse(accessController.hasRole(accessController.CRON_JOB_ROLE(), cronJob));

            // check view
            assertFalse(accessController.isCronJob(cronJob));
        }

        // global admin cannot remove cronjob
        function test_GlobalAdmin_CannotRemoveCronJob() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, globalAdmin, accessController.CRON_JOB_ADMIN_ROLE()));
            vm.prank(globalAdmin);
            accessController.removeCronJob(cronJob);
        }
    
    // ------ removeCronJobAdmin ------

        // cronjob cannot remove cronjob admin
        function test_CronJob_CannotRemoveCronJobAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, cronJob, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(cronJob);
            accessController.removeCronJobAdmin(cronJobAdmin);
        }
        
        // global admin can remove cronjob admin
        function test_GlobalAdmin_CanRemoveCronJobAdmin() public {
            
            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.CronJobAdminRemoved(cronJobAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeCronJobAdmin(cronJobAdmin);

            assertFalse(accessController.hasRole(accessController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin));
            assertFalse(accessController.isCronJobAdmin(cronJobAdmin));
        }
    
    // ------ state transition: paymentsControllerAdminSet ------

        function test_UserA_CannotGrantPaymentsControllerAdminRole() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addPaymentsControllerAdmin(paymentsControllerAdmin);
        }

        function test_GlobalAdmin_GrantsPaymentsControllerAdminRole() public {
            assertFalse(accessController.hasRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.PaymentsControllerAdminAdded(paymentsControllerAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.addPaymentsControllerAdmin(paymentsControllerAdmin);

            assertTrue(accessController.hasRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin));
            assertTrue(accessController.isPaymentsControllerAdmin(paymentsControllerAdmin));
        }
}

abstract contract State_PaymentsControllerAdminSet is State_CronJobAdminSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addPaymentsControllerAdmin(paymentsControllerAdmin);
    }
}

contract State_PaymentsControllerAdminSet_Test is State_PaymentsControllerAdminSet {
    
    // payments controller admin has role
    function test_PaymentsControllerAdmin() public {
        assertTrue(accessController.hasRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin));
    }

    // ------ removePaymentsControllerAdmin ------
        
        // payments controller admin cannot remove payments controller admin
        function test_PaymentsControllerAdmin_CannotRemovePaymentsControllerAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, paymentsControllerAdmin, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(paymentsControllerAdmin);
            accessController.removePaymentsControllerAdmin(paymentsControllerAdmin);
        }

        // global admin can remove payments controller admin
        function test_GlobalAdmin_CanRemovePaymentsControllerAdmin() public {

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.PaymentsControllerAdminRemoved(paymentsControllerAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removePaymentsControllerAdmin(paymentsControllerAdmin);

            assertFalse(accessController.hasRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin));
            assertFalse(accessController.isPaymentsControllerAdmin(paymentsControllerAdmin));
        }

    // ------ state transition: addVotingControllerAdmin ------
        
        // userA cannot add voting controller admin
        function test_UserA_CannotAddVotingControllerAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addVotingControllerAdmin(votingControllerAdmin);
        }

        // global admin can add voting controller admin
        function test_GlobalAdmin_CanAddVotingControllerAdmin() public {
            assertFalse(accessController.hasRole(accessController.VOTING_CONTROLLER_ADMIN_ROLE(), votingControllerAdmin));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.VotingControllerAdminAdded(votingControllerAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.addVotingControllerAdmin(votingControllerAdmin);

            assertTrue(accessController.hasRole(accessController.VOTING_CONTROLLER_ADMIN_ROLE(), votingControllerAdmin));
            assertTrue(accessController.isVotingControllerAdmin(votingControllerAdmin));
        }
}

abstract contract State_VotingControllerAdminSet is State_PaymentsControllerAdminSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addVotingControllerAdmin(votingControllerAdmin);
    }
}

contract State_VotingControllerAdminSet_Test is State_VotingControllerAdminSet {
    
    // voting controller admin has role
    function test_VotingControllerAdmin() public {
        assertTrue(accessController.hasRole(accessController.VOTING_CONTROLLER_ADMIN_ROLE(), votingControllerAdmin));
    }

    // ------ removeVotingControllerAdmin ------
        
        // voting controller admin cannot remove voting controller admin
        function test_VotingControllerAdmin_CannotRemoveVotingControllerAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, votingControllerAdmin, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(votingControllerAdmin);
            accessController.removeVotingControllerAdmin(votingControllerAdmin);
        }

        // global admin can remove voting controller admin
        function test_GlobalAdmin_CanRemoveVotingControllerAdmin() public {

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.VotingControllerAdminRemoved(votingControllerAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeVotingControllerAdmin(votingControllerAdmin);

            assertFalse(accessController.hasRole(accessController.VOTING_CONTROLLER_ADMIN_ROLE(), votingControllerAdmin));
            assertFalse(accessController.isVotingControllerAdmin(votingControllerAdmin));
        }

    // ------ state transition: addVotingEscrowMocaAdmin ------
        
        // userA cannot add voting escrow moca admin
        function test_UserA_CannotAddVotingEscrowMocaAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addVotingEscrowMocaAdmin(votingEscrowMocaAdmin);
        }

        // global admin can add voting escrow moca admin
        function test_GlobalAdmin_CanAddVotingEscrowMocaAdmin() public {
            assertFalse(accessController.hasRole(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE(), votingEscrowMocaAdmin));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.VotingEscrowMocaAdminAdded(votingEscrowMocaAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.addVotingEscrowMocaAdmin(votingEscrowMocaAdmin);

            assertTrue(accessController.hasRole(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE(), votingEscrowMocaAdmin));
            assertTrue(accessController.isVotingEscrowMocaAdmin(votingEscrowMocaAdmin));
        }
}

abstract contract State_VotingEscrowMocaAdminSet is State_VotingControllerAdminSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addVotingEscrowMocaAdmin(votingEscrowMocaAdmin);
    }
}

contract State_VotingEscrowMocaAdminSet_Test is State_VotingEscrowMocaAdminSet {
    
    // voting escrow moca admin has role
    function test_VotingEscrowMocaAdmin() public {
        assertTrue(accessController.hasRole(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE(), votingEscrowMocaAdmin));
    }

    // ------ removeVotingEscrowMocaAdmin ------
        
        // voting escrow moca admin cannot remove voting escrow moca admin
        function test_VotingEscrowMocaAdmin_CannotRemoveVotingEscrowMocaAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, votingEscrowMocaAdmin, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(votingEscrowMocaAdmin);
            accessController.removeVotingEscrowMocaAdmin(votingEscrowMocaAdmin);
        }

        // global admin can remove voting escrow moca admin
        function test_GlobalAdmin_CanRemoveVotingEscrowMocaAdmin() public {

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.VotingEscrowMocaAdminRemoved(votingEscrowMocaAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeVotingEscrowMocaAdmin(votingEscrowMocaAdmin);

            assertFalse(accessController.hasRole(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE(), votingEscrowMocaAdmin));
            assertFalse(accessController.isVotingEscrowMocaAdmin(votingEscrowMocaAdmin));
        }

    // ------ state transition: addEscrowedMocaAdmin ------
        
        // userA cannot add escrowed moca admin
        function test_UserA_CannotAddEscrowedMocaAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addEscrowedMocaAdmin(escrowedMocaAdmin);
        }

        // global admin can add escrowed moca admin
        function test_GlobalAdmin_CanAddEscrowedMocaAdmin() public {
            assertFalse(accessController.hasRole(accessController.ESCROWED_MOCA_ADMIN_ROLE(), escrowedMocaAdmin));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.EscrowedMocaAdminAdded(escrowedMocaAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.addEscrowedMocaAdmin(escrowedMocaAdmin);

            assertTrue(accessController.hasRole(accessController.ESCROWED_MOCA_ADMIN_ROLE(), escrowedMocaAdmin));
            assertTrue(accessController.isEscrowedMocaAdmin(escrowedMocaAdmin));
        }
}

abstract contract State_EscrowedMocaAdminSet is State_VotingEscrowMocaAdminSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addEscrowedMocaAdmin(escrowedMocaAdmin);
    }
}

contract State_EscrowedMocaAdminSet_Test is State_EscrowedMocaAdminSet {
    
    // escrowed moca admin has role
    function test_EscrowedMocaAdmin() public {
        assertTrue(accessController.hasRole(accessController.ESCROWED_MOCA_ADMIN_ROLE(), escrowedMocaAdmin));
    }

    // ------ removeEscrowedMocaAdmin ------
        
        // escrowed moca admin cannot remove escrowed moca admin
        function test_EscrowedMocaAdmin_CannotRemoveEscrowedMocaAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, escrowedMocaAdmin, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(escrowedMocaAdmin);
            accessController.removeEscrowedMocaAdmin(escrowedMocaAdmin);
        }

        // global admin can remove escrowed moca admin
        function test_GlobalAdmin_CanRemoveEscrowedMocaAdmin() public {

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.EscrowedMocaAdminRemoved(escrowedMocaAdmin, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeEscrowedMocaAdmin(escrowedMocaAdmin);

            assertFalse(accessController.hasRole(accessController.ESCROWED_MOCA_ADMIN_ROLE(), escrowedMocaAdmin));
            assertFalse(accessController.isEscrowedMocaAdmin(escrowedMocaAdmin));
        }

    // ------ state transition: addAssetManager ------
        
        // userA cannot add asset manager
        function test_UserA_CannotAddAssetManager() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addAssetManager(assetManager);
        }

        // global admin can add asset manager
        function test_GlobalAdmin_CanAddAssetManager() public {
            assertFalse(accessController.hasRole(accessController.ASSET_MANAGER_ROLE(), assetManager));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.AssetManagerAdded(assetManager, globalAdmin);

            vm.prank(globalAdmin);
            accessController.addAssetManager(assetManager);

            assertTrue(accessController.hasRole(accessController.ASSET_MANAGER_ROLE(), assetManager));
            assertTrue(accessController.isAssetManager(assetManager));
        }
}

abstract contract State_AssetManagerSet is State_EscrowedMocaAdminSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addAssetManager(assetManager);
    }
}

contract State_AssetManagerSet_Test is State_AssetManagerSet {
    
    // asset manager has role
    function test_AssetManager() public {
        assertTrue(accessController.hasRole(accessController.ASSET_MANAGER_ROLE(), assetManager));
    }

    // ------ removeAssetManager ------
        
        // asset manager cannot remove asset manager
        function test_AssetManager_CannotRemoveAssetManager() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, assetManager, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(assetManager);
            accessController.removeAssetManager(assetManager);
        }

        // global admin can remove asset manager
        function test_GlobalAdmin_CanRemoveAssetManager() public {

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.AssetManagerRemoved(assetManager, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeAssetManager(assetManager);

            assertFalse(accessController.hasRole(accessController.ASSET_MANAGER_ROLE(), assetManager));
            assertFalse(accessController.isAssetManager(assetManager));
        }

    // ------ state transition: addEmergencyExitHandler ------
        
        // userA cannot add emergency exit handler
        function test_UserA_CannotAddEmergencyExitHandler() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, userA, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(userA);
            accessController.addEmergencyExitHandler(emergencyExitHandler);
        }

        // global admin can add emergency exit handler
        function test_GlobalAdmin_CanAddEmergencyExitHandler() public {
            assertFalse(accessController.hasRole(accessController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler));

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.EmergencyExitHandlerAdded(emergencyExitHandler, globalAdmin);

            vm.prank(globalAdmin);
            accessController.addEmergencyExitHandler(emergencyExitHandler);

            assertTrue(accessController.hasRole(accessController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler));
            assertTrue(accessController.isEmergencyExitHandler(emergencyExitHandler));
        }
}

abstract contract State_EmergencyExitHandlerSet is State_AssetManagerSet {
    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        accessController.addEmergencyExitHandler(emergencyExitHandler);
    }
}

contract State_EmergencyExitHandlerSet_Test is State_EmergencyExitHandlerSet {
    
    // emergency exit handler has role
    function test_EmergencyExitHandler() public {
        assertTrue(accessController.hasRole(accessController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler));
    }

    // ------ removeEmergencyExitHandler ------
        
        // emergency exit handler cannot remove emergency exit handler
        function test_EmergencyExitHandler_CannotRemoveEmergencyExitHandler() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, emergencyExitHandler, accessController.DEFAULT_ADMIN_ROLE()));
            vm.prank(emergencyExitHandler);
            accessController.removeEmergencyExitHandler(emergencyExitHandler);
        }

        // global admin can remove emergency exit handler
        function test_GlobalAdmin_CanRemoveEmergencyExitHandler() public {

            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.EmergencyExitHandlerRemoved(emergencyExitHandler, globalAdmin);

            vm.prank(globalAdmin);
            accessController.removeEmergencyExitHandler(emergencyExitHandler);

            assertFalse(accessController.hasRole(accessController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler));
            assertFalse(accessController.isEmergencyExitHandler(emergencyExitHandler));
        }

    // ------ isGlobalAdmin ------
        
        function test_isGlobalAdmin() public {
            assertTrue(accessController.isGlobalAdmin(globalAdmin));
            assertFalse(accessController.isGlobalAdmin(userA));
            assertFalse(accessController.isGlobalAdmin(address(0)));
        }

    // ------ transferGlobalAdminFromAddressBook ------
        
        // only address book can call transferGlobalAdminFromAddressBook
        function test_OnlyAddressBook_CanTransferGlobalAdmin() public {
            vm.expectRevert(Errors.OnlyCallableByAddressBook.selector);
            vm.prank(globalAdmin);
            accessController.transferGlobalAdminFromAddressBook(globalAdmin, newGlobalAdmin);
        }

        // address book can transfer global admin
        function test_AddressBook_CanTransferGlobalAdmin() public {
            // expect event emission
            vm.expectEmit(true, true, false, true, address(accessController));
            emit Events.GlobalAdminTransferred(globalAdmin, newGlobalAdmin);

            vm.prank(address(addressBook));
            accessController.transferGlobalAdminFromAddressBook(globalAdmin, newGlobalAdmin);

            // verify the transfer
            assertTrue(accessController.isGlobalAdmin(newGlobalAdmin));
            assertFalse(accessController.isGlobalAdmin(globalAdmin));
        }

        // cannot transfer from non-admin: old admin does not have role
        function test_transferGlobalAdminFromAddressBook_CannotTransferFromNonAdmin() public {
            vm.expectRevert(Errors.OldAdminDoesNotHaveRole.selector);
            vm.prank(address(addressBook));
            accessController.transferGlobalAdminFromAddressBook(userA, newGlobalAdmin);
        }

        // cannot transfer to zero address
        function test_transferGlobalAdminFromAddressBook_CannotTransferToZeroAddress() public {
            vm.expectRevert(Errors.InvalidAddress.selector);
            vm.prank(address(addressBook));
            accessController.transferGlobalAdminFromAddressBook(globalAdmin, address(0));
        }

    // ------ getAddressBook ------
        
        function test_getAddressBook() public {
            assertEq(accessController.getAddressBook(), address(addressBook));
        }

    // ------ noZeroAddress modifier tests ------
        
        function test_CannotAddZeroAddress() public {
            // Test all add functions with zero address
            vm.startPrank(globalAdmin);
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addMonitorAdmin(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addCronJobAdmin(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addPaymentsControllerAdmin(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addVotingControllerAdmin(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addVotingEscrowMocaAdmin(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addEscrowedMocaAdmin(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addAssetManager(address(0));
            
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addEmergencyExitHandler(address(0));
            
            vm.stopPrank();

            // Test monitor and cron job functions
            vm.prank(monitorAdmin);
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addMonitor(address(0));

            vm.prank(cronJobAdmin);
            vm.expectRevert(Errors.InvalidAddress.selector);
            accessController.addCronJob(address(0));
        }
}
