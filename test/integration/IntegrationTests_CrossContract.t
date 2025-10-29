// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import "../utils/TestingHarness.sol";

/**
 * @title Cross-Contract Integration Tests
 * @notice Tests interactions between AddressBook, AccessController, PaymentsController, and IssuerStakingController
 * @dev Focus on cross-contract flows, role synchronization, and cascade effects
 */

abstract contract StateT0_Deploy is TestingHarness {
    function setUp() public virtual override {
        super.setUp();
    }
}

contract TestCrossContract_OwnershipSync is StateT0_Deploy {
    
    address public newGlobalAdmin = makeAddr("newGlobalAdmin");
    
    // Test: AddressBook ownership transfer syncs global admin in AccessController
    function test_OwnershipTransfer_SyncsGlobalAdmin() public {
        address currentAdmin = addressBook.owner();
        
        // Start ownership transfer
        vm.prank(currentAdmin);
        addressBook.transferOwnership(newGlobalAdmin);
        
        // Accept ownership
        vm.prank(newGlobalAdmin);
        addressBook.acceptOwnership();
        
        // Verify synchronization
        assertEq(addressBook.owner(), newGlobalAdmin);
        assertEq(addressBook.getGlobalAdmin(), newGlobalAdmin);
        assertTrue(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), newGlobalAdmin));
        assertFalse(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), currentAdmin));
    }
    
    // Test: Sync works even when AccessController not yet registered
    function test_OwnershipTransfer_WorksWithoutAccessController() public {
        // Deploy new AddressBook without registered AccessController
        address tempAdmin = makeAddr("tempAdmin");
        AddressBook tempBook = new AddressBook(tempAdmin);
        
        address tempNewAdmin = makeAddr("tempNewAdmin");
        
        vm.prank(tempAdmin);
        tempBook.transferOwnership(tempNewAdmin);
        
        vm.prank(tempNewAdmin);
        tempBook.acceptOwnership();
        
        assertEq(tempBook.owner(), tempNewAdmin);
    }
}

contract TestCrossContract_RoleChangeCascade is StateT0_Deploy {
    
    address public newPaymentsAdmin = makeAddr("newPaymentsAdmin");
    address public newMonitorAdmin = makeAddr("newMonitorAdmin");
    bytes32 public testIssuerId;
    
    function setUp() public override {
        super.setUp();
        
        vm.prank(issuer1);
        testIssuerId = paymentsController.createIssuer(issuer1Asset);
    }
    
    // Test: Removing monitor admin affects pause capabilities
    function test_RoleRevocation_CascadesToContracts() public {
        // Verify monitor admin can add monitors
        address tempMonitor = makeAddr("tempMonitor");
        vm.prank(monitorAdmin);
        accessController.addMonitor(tempMonitor);
        assertTrue(accessController.isMonitor(tempMonitor));
        
        // Revoke monitor admin role
        vm.prank(globalAdmin);
        accessController.removeMonitorAdmin(monitorAdmin);
        
        // Monitor admin can no longer manage monitors
        address newTempMonitor = makeAddr("newTempMonitor");
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.addMonitor(newTempMonitor);
        
        // But existing monitor can still pause
        vm.prank(tempMonitor);
        paymentsController.pause();
        assertTrue(paymentsController.paused());
    }
    
    // Test: Adding new payments admin immediately effective
    function test_RoleGrant_CascadesImmediately() public {
        bytes32 schemaId = paymentsController.createSchema(testIssuerId, 100 * 1e6);
        bytes32 testPoolId = bytes32("TEST_POOL");
        
        // Grant new admin
        vm.prank(globalAdmin);
        accessController.addPaymentsControllerAdmin(newPaymentsAdmin);
        
        // Immediately can use it
        vm.prank(newPaymentsAdmin);
        paymentsController.updatePoolId(schemaId, testPoolId);
        
        assertEq(paymentsController.getSchema(schemaId).poolId, testPoolId);
    }
    
    // Test: Operational role admin change affects child roles
    function test_MonitorAdminChange_AffectsMonitors() public {
        // Current monitor admin can manage monitors
        address existingMonitor = makeAddr("existingMonitor");
        vm.prank(monitorAdmin);
        accessController.addMonitor(existingMonitor);
        
        // Replace monitor admin
        vm.prank(globalAdmin);
        accessController.removeMonitorAdmin(monitorAdmin);
        
        vm.prank(globalAdmin);
        accessController.addMonitorAdmin(newMonitorAdmin);
        
        // New admin can manage monitors
        address newMonitor = makeAddr("newMonitor");
        vm.prank(newMonitorAdmin);
        accessController.addMonitor(newMonitor);
        assertTrue(accessController.isMonitor(newMonitor));
        
        // Old admin cannot
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.addMonitor(makeAddr("anotherMonitor"));
    }
}

contract TestCrossContract_PauseChain is StateT0_Deploy {
    
    bytes32 public testIssuerId;
    bytes32 public testVerifierId;
    
    function setUp() public override {
        super.setUp();
        
        vm.prank(issuer1);
        testIssuerId = paymentsController.createIssuer(issuer1Asset);
        
        vm.prank(verifier1);
        testVerifierId = paymentsController.createVerifier(verifier1Signer, verifier1Asset);
        
        mockUSD8.mint(verifier1Asset, 1000 ether);
        mockMoca.mint(issuer1Asset, 1000 ether);
    }
    
    // Test: Pausing one contract doesn't affect others
    function test_PauseOneContract_DoesntAffectOthers() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        assertTrue(paymentsController.paused());
        assertFalse(issuerStakingController.paused());
        
        // IssuerStakingController still works
        vm.startPrank(issuer1Asset);
        mockMoca.approve(address(issuerStakingController), 100 ether);
        issuerStakingController.stakeMoca(50 ether);
        vm.stopPrank();
        
        assertEq(issuerStakingController.issuers(issuer1Asset), 50 ether);
    }
    
    // Test: Chain pause of multiple contracts
    function test_ChainPause_MultipleContracts() public {
        // Pause payments
        vm.prank(monitor);
        paymentsController.pause();
        
        // Pause issuer staking
        vm.prank(monitor);
        issuerStakingController.pause();
        
        // Both paused
        assertTrue(paymentsController.paused());
        assertTrue(issuerStakingController.paused());
        
        // Both fail on operations
        vm.prank(issuer1);
        vm.expectRevert();
        paymentsController.createSchema(testIssuerId, 100 * 1e6);
        
        vm.startPrank(issuer1Asset);
        mockMoca.approve(address(issuerStakingController), 100 ether);
        vm.expectRevert();
        issuerStakingController.stakeMoca(50 ether);
        vm.stopPrank();
    }
    
    // Test: Chain unpause requires global admin
    function test_ChainUnpause_RequiresGlobalAdmin() public {
        // Set up paused state
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(monitor);
        issuerStakingController.pause();
        
        // Monitor cannot unpause
        vm.prank(monitor);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.unpause();
        
        // Global admin can unpause both
        vm.prank(globalAdmin);
        paymentsController.unpause();
        
        vm.prank(globalAdmin);
        issuerStakingController.unpause();
        
        assertFalse(paymentsController.paused());
        assertFalse(issuerStakingController.paused());
    }
}

contract TestCrossContract_AttackScenarios is StateT0_Deploy {
    
    address public attacker = makeAddr("attacker");
    
    // Test: Compromised monitor admin cannot escalate
    function test_Attack_CompromisedMonitorAdmin_CannotEscalate() public {
        // Attacker becomes monitor admin
        vm.prank(globalAdmin);
        accessController.grantRole(accessController.MONITOR_ADMIN_ROLE(), attacker);
        
        // Attacker adds themselves as monitor
        vm.prank(attacker);
        accessController.addMonitor(attacker);
        
        // Can pause
        vm.prank(attacker);
        paymentsController.pause();
        
        // Cannot unpause or freeze
        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.unpause();
        
        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.freeze();
        
        // Global admin can still recover
        vm.prank(globalAdmin);
        paymentsController.unpause();
    }
    
    // Test: Compromised strategic admin limited damage
    function test_Attack_CompromisedPaymentsAdmin_LimitedDamage() public {
        // Attacker becomes payments admin
        vm.prank(globalAdmin);
        accessController.grantRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), attacker);
        
        // Can change parameters
        vm.prank(attacker);
        paymentsController.updateProtocolFeePercentage(9000); // 90%
        
        // Cannot pause, unpause, freeze, or emergency exit
        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyCallableByMonitor);
        paymentsController.pause();
        
        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
    }
    
    // Test: Defense in depth - multiple compromised roles still contained
    function test_Attack_MultipleCompromisedRoles_StillContained() public {
        address monitorAttacker = makeAddr("monitorAttacker");
        address paymentsAttacker = makeAddr("paymentsAttacker");
        
        // Set up compromised monitor system
        vm.prank(globalAdmin);
        accessController.grantRole(accessController.MONITOR_ADMIN_ROLE(), monitorAttacker);
        
        vm.prank(monitorAttacker);
        accessController.addMonitor(monitorAttacker);
        
        // Set up compromised payments system
        vm.prank(globalAdmin);
        accessController.grantRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsAttacker);
        
        // Both can do their respective actions
        vm.prank(monitorAttacker);
        paymentsController.pause();
        
        vm.prank(paymentsAttacker);
        paymentsController.updateProtocolFeePercentage(8000); // 80%
        
        // Neither can do the other's job
        vm.prank(monitorAttacker);
        vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin);
        paymentsController.updateProtocolFeePercentage(7000);
        
        vm.prank(paymentsAttacker);
        vm.expectRevert(Errors.OnlyCallableByMonitor);
        paymentsController.pause();
        
        // Cannot unpause or freeze
        vm.prank(monitorAttacker);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.unpause();
        
        vm.prank(monitorAttacker);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.freeze();
    }
}

contract TestCrossContract_EmergencyProcedures is StateT0_Deploy {
    
    bytes32 public testIssuerId;
    bytes32 public testVerifierId;
    
    function setUp() public override {
        super.setUp();
        
        vm.prank(issuer1);
        testIssuerId = paymentsController.createIssuer(issuer1Asset);
        
        vm.prank(verifier1);
        testVerifierId = paymentsController.createVerifier(verifier1Signer, verifier1Asset);
        
        // Fund verifier
        mockUSD8.mint(verifier1Asset, 1000 ether);
        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), 1000 ether);
        paymentsController.deposit(testVerifierId, 500 ether);
        vm.stopPrank();
        
        // Fund issuer
        mockMoca.mint(issuer1Asset, 1000 ether);
        vm.startPrank(issuer1Asset);
        mockMoca.approve(address(issuerStakingController), 1000 ether);
        issuerStakingController.stakeMoca(500 ether);
        vm.stopPrank();
    }
    
    // Test: Full emergency procedure chain
    function test_Emergency_FullProcedure() public {
        // Step 1: Pause PaymentsController
        vm.prank(monitor);
        paymentsController.pause();
        
        // Step 2: Pause IssuerStakingController
        vm.prank(monitor);
        issuerStakingController.pause();
        
        // Step 3: Freeze both
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        vm.prank(globalAdmin);
        issuerStakingController.freeze();
        
        // Step 4: Emergency exit
        bytes32[] memory verifiers = new bytes32[](1);
        verifiers[0] = testVerifierId;
        vm.prank(emergencyExitHandler);
        paymentsController.emergencyExitVerifiers(verifiers);
        
        address[] memory issuers = new address[](1);
        issuers[0] = issuer1Asset;
        vm.prank(emergencyExitHandler);
        issuerStakingController.emergencyExit(issuers);
        
        // Verify funds recovered
        assertEq(mockUSD8.balanceOf(verifier1Asset), 500 ether);
        assertEq(mockMoca.balanceOf(issuer1Asset), 500 ether);
    }
    
    // Test: Cannot unpause once frozen
    function test_Emergency_CannotUnpauseWhenFrozen() public {
        // Set up frozen state
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        // Cannot unpause
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen);
        paymentsController.unpause();
    }
    
    // Test: Emergency exit requires frozen state
    function test_Emergency_RequiresFrozen() public {
        // Only pause, don't freeze
        vm.prank(monitor);
        paymentsController.pause();
        
        // Cannot emergency exit
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.NotFrozen);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
        
        // Must freeze first
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        // Now can emergency exit
        bytes32[] memory verifiers = new bytes32[](1);
        verifiers[0] = testVerifierId;
        
        vm.prank(emergencyExitHandler);
        paymentsController.emergencyExitVerifiers(verifiers);
    }
}

contract TestCrossContract_RoleIsolation is StateT0_Deploy {
    
    address public fakeMonitor = makeAddr("fakeMonitor");
    address public fakePaymentsAdmin = makeAddr("fakePaymentsAdmin");
    
    // Test: Operational roles isolated from strategic roles
    function test_RoleIsolation_OperationalVsStrategic() public {
        // Monitor admin can only manage operational roles
        vm.prank(monitorAdmin);
        accessController.addMonitor(fakeMonitor);
        
        // Cannot manage strategic roles
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.addPaymentsControllerAdmin(fakePaymentsAdmin);
        
        // Payments admin can manage payments but not monitors
        vm.startPrank(paymentsControllerAdmin);
        accessController.grantRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), fakePaymentsAdmin);
        vm.stopPrank();
        
        vm.prank(fakePaymentsAdmin);
        vm.expectRevert();
        accessController.addMonitor(fakeMonitor);
    }
    
    // Test: Role hierarchy prevents child from managing parent
    function test_RoleIsolation_ChildCannotManageParent() public {
        // Monitor can pause but not manage monitor admin
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(monitor);
        vm.expectRevert();
        accessController.removeMonitorAdmin(monitorAdmin);
        
        // Monitor admin can manage monitor but not global admin
        vm.prank(monitorAdmin);
        accessController.removeMonitor(monitor);
        
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.removeGlobalAdmin();
    }
}

contract TestCrossContract_NoRoleScenarios is StateT0_Deploy {
    
    bytes32 public testIssuerId;
    
    function setUp() public override {
        super.setUp();
        
        vm.prank(issuer1);
        testIssuerId = paymentsController.createIssuer(issuer1Asset);
    }
    
    // Test: Missing roles don't break system
    function test_NoMonitor_Set_SystemStillFunctional() public {
        // Remove all monitors
        vm.prank(monitorAdmin);
        accessController.removeMonitor(monitor);
        
        // Cannot pause
        vm.prank(monitor);
        vm.expectRevert();
        paymentsController.pause();
        
        // But system still works
        vm.prank(issuer1);
        paymentsController.createSchema(testIssuerId, 100 * 1e6);
    }
    
    // Test: Missing admin role means no updates
    function test_NoPaymentsAdmin_Set_CannotUpdate() public {
        // Revoke payments admin
        vm.prank(globalAdmin);
        accessController.removePaymentsControllerAdmin(paymentsControllerAdmin);
        
        // Cannot update parameters
        vm.prank(paymentsControllerAdmin);
        vm.expectRevert();
        paymentsController.updateProtocolFeePercentage(100);
        
        // But reads still work
        assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), protocolFeePercentage);
    }
}

contract TestCrossContract_AddressBookUpdates is StateT0_Deploy {
    
    address public newAccessController = makeAddr("newAccessController");
    address public newPaymentsController = makeAddr("newPaymentsController");
    
    // Test: Updating address in AddressBook
    function test_AddressUpdate_AllowsUpgrade() public {
        vm.prank(globalAdmin);
        addressBook.setAddress(addressBook.ACCESS_CONTROLLER(), newAccessController);
        
        // New address is returned
        assertEq(addressBook.getAccessController(), newAccessController);
        
        // Old address is no longer returned
        assertNotEq(addressBook.getAccessController(), address(accessController));
    }
    
    // Test: Cannot update global admin through setAddress
    function test_AddressUpdate_CannotChangeGlobalAdmin() public {
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.InvalidId);
        addressBook.setAddress(bytes32(0), makeAddr("newAdmin"));
    }
    
    // Test: Paused AddressBook blocks all access
    function test_AddressBook_PauseBlocksAllAccess() public {
        vm.prank(globalAdmin);
        addressBook.pause();
        
        // Cannot read addresses
        vm.expectRevert();
        addressBook.getMoca();
        
        // Cannot update addresses
        vm.prank(globalAdmin);
        vm.expectRevert();
        addressBook.setAddress(bytes32("TEST"), makeAddr("test"));
    }
    
    // Test: Frozen AddressBook cannot be unpaused
    function test_AddressBook_FreezePermanent() public {
        vm.prank(globalAdmin);
        addressBook.pause();
        
        vm.prank(globalAdmin);
        addressBook.freeze();
        
        // Cannot unpause
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen);
        addressBook.unpause();
    }
}

contract TestCrossContract_StateDependencies is StateT0_Deploy {
    
    // Test: AccessController depends on AddressBook for global admin
    function test_AccessControllerDependsOnAddressBook() public {
        // AccessController should get global admin from AddressBook
        assertTrue(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), globalAdmin));
        
        // This happens via constructor query
        address initialGlobalAdmin = addressBook.getGlobalAdmin();
        assertEq(initialGlobalAdmin, globalAdmin);
    }
    
    // Test: Contract initialization order matters
    function test_DeploymentOrderMatters() public {
        // If AddressBook not set up, AccessController should still work
        // (it stores the address reference)
        assertEq(address(accessController._addressBook()), address(addressBook));
        
        // But calls to _addressBook will fail if AddressBook not initialized
        // This is expected behavior
    }
    
    // Test: PaymentsController and IssuerStakingController independent
    function test_ControllersIndependent() public {
        // Pause payments controller
        vm.prank(monitor);
        paymentsController.pause();
        
        // IssuerStakingController still works
        assertFalse(issuerStakingController.paused());
        
        mockMoca.mint(issuer1Asset, 100 ether);
        vm.startPrank(issuer1Asset);
        mockMoca.approve(address(issuerStakingController), 100 ether);
        issuerStakingController.stakeMoca(50 ether);
        vm.stopPrank();
        
        assertEq(issuerStakingController.issuers(issuer1Asset), 50 ether);
    }
}
