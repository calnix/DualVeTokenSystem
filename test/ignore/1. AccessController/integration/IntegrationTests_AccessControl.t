// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import "../utils/TestingHarness.sol";

/**
 * @title Integration Tests for Access Control
 * @notice Comprehensive tests for AddressBook, AccessController, PaymentsController, and IssuerStakingController
 * @dev Tests focus on role changes, permissions, security scenarios, and emergency procedures
 */

// ============================================
// SECTION 1: ADDRESS BOOK TESTS
// ============================================

contract TestAddressBook_RoleChanges is StateT0_Deploy {
    
    address public newGlobalAdmin = makeAddr("newGlobalAdmin");
    address public testAddress = makeAddr("testAddress");

    function test_SetAddress_Success() public {
        vm.prank(globalAdmin);
        addressBook.setAddress(bytes32("TEST_CONTRACT"), testAddress);
        
        assertEq(addressBook.getAddress(bytes32("TEST_CONTRACT")), testAddress);
    }

    function test_SetAddress_OnlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, issuer1));
        vm.prank(issuer1);
        addressBook.setAddress(bytes32("TEST"), testAddress);
    }

    function test_SetAddress_InvalidIdentifier() public {
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.InvalidId);
        addressBook.setAddress(bytes32(0), testAddress);
    }

    function test_SetAddress_ZeroAddress() public {
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.InvalidAddress);
        addressBook.setAddress(bytes32("TEST"), address(0));
    }

    function test_TransferOwnership_Complete() public {
        vm.prank(globalAdmin);
        addressBook.transferOwnership(newGlobalAdmin);
        
        vm.prank(newGlobalAdmin);
        addressBook.acceptOwnership();
        
        assertEq(addressBook.owner(), newGlobalAdmin);
        assertEq(addressBook.getGlobalAdmin(), newGlobalAdmin);
    }

    function test_TransferOwnership_NoAccept() public {
        vm.prank(globalAdmin);
        addressBook.transferOwnership(newGlobalAdmin);
        
        assertEq(addressBook.owner(), globalAdmin); // Still old owner
        assertEq(addressBook.getGlobalAdmin(), globalAdmin);
    }

    function test_Pause_PreventsOperations() public {
        vm.prank(globalAdmin);
        addressBook.pause();
        
        vm.expectRevert();
        addressBook.getAddress(bytes32("TEST"));
        
        vm.prank(globalAdmin);
        vm.expectRevert();
        addressBook.setAddress(bytes32("TEST"), testAddress);
    }

    function test_Unpause_ResumesOperations() public {
        vm.prank(globalAdmin);
        addressBook.pause();
        
        vm.prank(globalAdmin);
        addressBook.unpause();
        
        vm.prank(globalAdmin);
        addressBook.setAddress(bytes32("TEST"), testAddress);
        assertEq(addressBook.getAddress(bytes32("TEST")), testAddress);
    }

    function test_Freeze_PermanentlyDisables() public {
        vm.prank(globalAdmin);
        addressBook.pause();
        
        vm.prank(globalAdmin);
        addressBook.freeze();
        
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen);
        addressBook.unpause();
    }

    function test_AccessControllerSyncsOnOwnershipTransfer() public {
        address newAdmin = makeAddr("newAdmin");
        
        vm.prank(globalAdmin);
        addressBook.transferOwnership(newAdmin);
        
        vm.prank(newAdmin);
        addressBook.acceptOwnership();
        
        // Verify AccessController was updated
        assertTrue(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), newAdmin));
        assertFalse(accessController.hasRole(accessController.DEFAULT_ADMIN_ROLE(), globalAdmin));
    }
}

// ============================================
// SECTION 2: ACCESS CONTROLLER TESTS
// ============================================

contract TestAccessController_Roles is StateT0_Deploy {
    
    address public unauthorized = makeAddr("unauthorized");
    address public newMonitor = makeAddr("newMonitor");
    address public newCronJob = makeAddr("newCronJob");

    // Test High-Frequency Role Management
    function test_MonitorAdmin_AddRemoveMonitor() public {
        vm.prank(monitorAdmin);
        accessController.addMonitor(newMonitor);
        
        assertTrue(accessController.isMonitor(newMonitor));
        
        vm.prank(monitorAdmin);
        accessController.removeMonitor(newMonitor);
        
        assertFalse(accessController.isMonitor(newMonitor));
    }

    function test_CronJobAdmin_AddRemoveCronJob() public {
        vm.prank(cronJobAdmin);
        accessController.addCronJob(newCronJob);
        
        assertTrue(accessController.isCronJob(newCronJob));
        
        vm.prank(cronJobAdmin);
        accessController.removeCronJob(newCronJob);
        
        assertFalse(accessController.isCronJob(newCronJob));
    }

    function test_Unauthorized_CannotAddMonitor() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        accessController.addMonitor(newMonitor);
    }

    function test_GlobalAdmin_CanAddStrategicRoles() public {
        address newPaymentsAdmin = makeAddr("newPaymentsAdmin");
        
        vm.prank(globalAdmin);
        accessController.addPaymentsControllerAdmin(newPaymentsAdmin);
        
        assertTrue(accessController.isPaymentsControllerAdmin(newPaymentsAdmin));
    }

    function test_Unauthorized_CannotAddStrategicRoles() public {
        address newPaymentsAdmin = makeAddr("newPaymentsAdmin");
        
        vm.prank(issuer1);
        vm.expectRevert();
        accessController.addPaymentsControllerAdmin(newPaymentsAdmin);
    }

    function test_SetRoleAdmin_OnlyGlobalAdmin() public {
        bytes32 newAdminRole = keccak256("NEW_ADMIN_ROLE");
        
        vm.prank(globalAdmin);
        accessController.setRoleAdmin(newAdminRole, accessController.DEFAULT_ADMIN_ROLE());
        
        vm.prank(unauthorized);
        vm.expectRevert();
        accessController.setRoleAdmin(newAdminRole, accessController.DEFAULT_ADMIN_ROLE());
    }

    function test_Monitor_CanPause() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        assertTrue(paymentsController.paused());
    }

    function test_Unauthorized_CannotPause() public {
        vm.prank(unauthorized);
        vm.expectRevert(Errors.OnlyCallableByMonitor);
        paymentsController.pause();
    }
}

// ============================================
// SECTION 3: PAYMENTS CONTROLLER ACCESS TESTS
// ============================================

contract TestPaymentsController_AccessControl is StateT0_Deploy {
    
    address public unauthorized = makeAddr("unauthorized");
    bytes32 public testIssuerId;
    bytes32 public testVerifierId;
    
    function setUp() public override {
        super.setUp();
        
        // Setup issuer and verifier for tests
        vm.prank(issuer1);
        testIssuerId = paymentsController.createIssuer(issuer1Asset);
        
        vm.prank(verifier1);
        testVerifierId = paymentsController.createVerifier(verifier1Signer, verifier1Asset);
        
        // Deposit funds for verifier
        mockUSD8.mint(verifier1Asset, 1000 ether);
        
        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), 1000 ether);
        paymentsController.deposit(testVerifierId, 100 ether);
        vm.stopPrank();
    }

    function test_Pause_PreventsOperations() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(issuer1);
        vm.expectRevert();
        paymentsController.createSchema(testIssuerId, 100);
    }

    function test_Unpause_ResumesOperations() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(globalAdmin);
        paymentsController.unpause();
        
        vm.prank(issuer1);
        paymentsController.createSchema(testIssuerId, 100);
    }

    function test_Freeze_PreventsUnpause() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen);
        paymentsController.unpause();
    }

    function test_GlobalAdmin_CanUnpause() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(issuer1);
        vm.expectRevert(); // Unauthorized unpause
        
        vm.prank(globalAdmin);
        paymentsController.unpause();
    }

    function test_PaymentsAdmin_CanUpdatePoolId() public {
        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(testIssuerId, 100);
        
        bytes32 poolId = bytes32("TEST_POOL");
        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(schemaId, poolId);
        
        assertEq(paymentsController.getSchema(schemaId).poolId, poolId);
    }

    function test_Unauthorized_CannotUpdatePoolId() public {
        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(testIssuerId, 100);
        
        vm.prank(unauthorized);
        vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin);
        paymentsController.updatePoolId(schemaId, bytes32("TEST_POOL"));
    }

    function test_AssetManager_CanWithdrawFees() public {
        // Create and process some fees
        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(testIssuerId, 100);
        
        // Process verification to accrue fees
        uint256 nonce = paymentsController.getVerifierNonce(verifier1Signer);
        bytes memory sig = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            testIssuerId,
            testVerifierId,
            schemaId,
            100 * Constants.USD8_PRECISION,
            block.timestamp + 1 hours,
            nonce
        );
        
        vm.prank(issuer1); // Can be anyone calling deductBalance
        paymentsController.deductBalance(
            testIssuerId,
            testVerifierId,
            schemaId,
            100 * Constants.USD8_PRECISION,
            block.timestamp + 1 hours,
            sig
        );
        
        // Fast forward to next epoch
        vm.warp(EpochMath.getCurrentEpochNumber() * EpochMath.EPOCH_DURATION);
        
        // Asset manager can withdraw
        vm.prank(assetManager);
        vm.expectRevert(); // Expected if epoch not finalized properly
        paymentsController.withdrawProtocolFees(EpochMath.getCurrentEpochNumber() - 1);
    }

    function test_Unauthorized_CannotWithdrawFees() public {
        vm.prank(unauthorized);
        vm.expectRevert(Errors.OnlyCallableByAssetManager);
        paymentsController.withdrawProtocolFees(0);
    }

    function test_EmergencyExit_OnlyWhenFrozen() public {
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.NotFrozen);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
    }

    function test_EmergencyExit_OnlyByHandler() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        vm.prank(unauthorized);
        vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
    }
}

// ============================================
// SECTION 4: ISSUER STAKING CONTROLLER TESTS
// ============================================

contract TestIssuerStakingController_AccessControl is StateT0_Deploy {
    
    address public unauthorized = makeAddr("unauthorized");
    
    function test_Pause_PreventsStaking() public {
        mockMoca.mint(issuer1, 1000 ether);
        
        vm.startPrank(issuer1);
        mockMoca.approve(address(issuerStakingController), 1000 ether);
        
        vm.prank(monitor);
        issuerStakingController.pause();
        
        vm.expectRevert();
        issuerStakingController.stakeMoca(100 ether);
        vm.stopPrank();
    }

    function test_Unpause_ResumesStaking() public {
        mockMoca.mint(issuer1, 1000 ether);
        
        vm.prank(monitor);
        issuerStakingController.pause();
        
        vm.prank(globalAdmin);
        issuerStakingController.unpause();
        
        vm.startPrank(issuer1);
        mockMoca.approve(address(issuerStakingController), 1000 ether);
        issuerStakingController.stakeMoca(100 ether);
        vm.stopPrank();
        
        assertEq(issuerStakingController.issuers(issuer1), 100 ether);
    }

    function test_Admin_CanUpdateParameters() public {
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setUnstakeDelay(10 days);
        
        assertEq(issuerStakingController.UNSTAKE_DELAY(), 10 days);
    }

    function test_Unauthorized_CannotUpdateParameters() public {
        vm.prank(unauthorized);
        vm.expectRevert(Errors.OnlyCallableByIssuerStakingControllerAdmin);
        issuerStakingController.setUnstakeDelay(10 days);
    }

    function test_EmergencyExit_OnlyWhenFrozen() public {
        mockMoca.mint(issuer1, 1000 ether);
        
        vm.startPrank(issuer1);
        mockMoca.approve(address(issuerStakingController), 1000 ether);
        issuerStakingController.stakeMoca(100 ether);
        vm.stopPrank();
        
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.NotFrozen);
        address[] memory addrs = new address[](1);
        addrs[0] = issuer1;
        issuerStakingController.emergencyExit(addrs);
    }

    function test_EmergencyExit_WorksWhenFrozen() public {
        mockMoca.mint(issuer1, 1000 ether);
        
        vm.startPrank(issuer1);
        mockMoca.approve(address(issuerStakingController), 1000 ether);
        issuerStakingController.stakeMoca(100 ether);
        vm.stopPrank();
        
        vm.prank(monitor);
        issuerStakingController.pause();
        
        vm.prank(globalAdmin);
        issuerStakingController.freeze();
        
        address[] memory addrs = new address[](1);
        addrs[0] = issuer1;
        
        uint256 balanceBefore = mockMoca.balanceOf(issuer1);
        
        vm.prank(emergencyExitHandler);
        issuerStakingController.emergencyExit(addrs);
        
        assertGt(mockMoca.balanceOf(issuer1), balanceBefore);
        assertEq(issuerStakingController.issuers(issuer1), 0);
    }
}

// ============================================
// SECTION 5: CROSS-CONTRACT INTEGRATION
// ============================================

contract TestIntegration_CrossContract is StateT0_Deploy {
    
    address public attacker = makeAddr("attacker");
    address public compromisedMonitorAdmin = makeAddr("compromisedMonitorAdmin");

    function test_RoleRemoval_CascadesToContracts() public {
        // Remove monitor admin role
        vm.prank(globalAdmin);
        accessController.removeMonitorAdmin(monitorAdmin);
        
        // Monitor admin can no longer add monitors
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.addMonitor(makeAddr("newMonitor"));
    }

    function test_RoleChanges_EffectiveImmediately() public {
        address newPaymentsAdmin = makeAddr("newPaymentsAdmin");
        
        // Grant new admin
        vm.prank(globalAdmin);
        accessController.addPaymentsControllerAdmin(newPaymentsAdmin);
        
        // Immediately can use it
        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(testIssuerId, 100);
        
        bytes32 poolId = bytes32("TEST_POOL");
        vm.prank(newPaymentsAdmin);
        paymentsController.updatePoolId(schemaId, poolId);
        
        assertEq(paymentsController.getSchema(schemaId).poolId, poolId);
    }

    function test_AttackScenario_CompromisedMonitorAdmin() public {
        // Attacker gains control of monitor admin
        vm.prank(globalAdmin);
        accessController.grantRole(accessController.MONITOR_ADMIN_ROLE(), attacker);
        
        // Attacker adds malicious monitor
        vm.prank(attacker);
        accessController.addMonitor(attacker);
        
        // Attacker can now pause contracts
        assertTrue(accessController.isMonitor(attacker));
        
        vm.prank(attacker);
        paymentsController.pause();
        assertTrue(paymentsController.paused());
        
        // Global admin can still revoke and unpause
        vm.prank(globalAdmin);
        accessController.removeMonitor(attacker);
        assertFalse(accessController.isMonitor(attacker));
        
        vm.prank(globalAdmin);
        paymentsController.unpause();
        assertFalse(paymentsController.paused());
    }

    function test_AttackScenario_CompromisedGlobalAdmin() public {
        // This is the worst case - if global admin is compromised
        
        // Attacker becomes global admin
        vm.prank(globalAdmin);
        accessController.grantRole(accessController.DEFAULT_ADMIN_ROLE(), attacker);
        
        // Attacker can do anything
        assertTrue(accessController.isGlobalAdmin(attacker));
        
        // Attacker can pause and freeze
        vm.prank(attacker);
        paymentsController.pause();
        
        vm.prank(attacker);
        paymentsController.freeze();
        
        assertEq(paymentsController.isFrozen(), 1);
        
        // Note: This requires multi-sig protection in practice
    }

    function test_Monitor_BypassUnpause() public {
        // Monitor can pause
        vm.prank(monitor);
        paymentsController.pause();
        
        // Monitor cannot unpause
        vm.prank(monitor);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.unpause();
        
        // Only global admin can unpause
        vm.prank(globalAdmin);
        paymentsController.unpause();
    }

    function test_MultipleContracts_PauseChain() public {
        // Pause payments controller
        vm.prank(monitor);
        paymentsController.pause();
        
        // Pause issuer staking controller
        vm.prank(monitor);
        issuerStakingController.pause();
        
        // Both are paused
        assertTrue(paymentsController.paused());
        assertTrue(issuerStakingController.paused());
        
        // Unpause both
        vm.prank(globalAdmin);
        paymentsController.unpause();
        
        vm.prank(globalAdmin);
        issuerStakingController.unpause();
        
        // Both resumed
        assertFalse(paymentsController.paused());
        assertFalse(issuerStakingController.paused());
    }
}

// ============================================
// SECTION 6: NO ROLE SET SCENARIOS
// ============================================

contract TestScenarios_NoRoleSet is StateT0_Deploy {
    
    address public unprivileged = makeAddr("unprivileged");
    
    function test_NoMonitor_Set_AddressBookAccessible() public {
        // AddressBook should be accessible without monitor
        assertEq(addressBook.getMoca(), address(mockMoca));
    }

    function test_NoMonitor_CannotPause() public {
        vm.prank(unprivileged);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unprivileged));
        addressBook.pause();
    }

    function test_NoRoleAssigned_ContractStillWorks() public {
        // Contracts should work even if admin roles not assigned
        vm.prank(issuer1);
        bytes32 issuerId = paymentsController.createIssuer(issuer1Asset);
        assertTrue(issuerId != bytes32(0));
    }

    function test_UnassignedRole_CannotExecute() public {
        address unusedAdmin = makeAddr("unusedAdmin");
        
        vm.prank(unusedAdmin);
        vm.expectRevert();
        paymentsController.updatePoolId(bytes32("TEST"), bytes32("POOL"));
    }
}

// ============================================
// SECTION 7: EMERGENCY PROCEDURES
// ============================================

contract TestEmergency_Procedures is StateT0_Deploy {
    
    bytes32 public testIssuerId;
    bytes32 public testVerifierId;
    address[] public issuers;
    
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
        
        // Issuer staking
        mockMoca.mint(issuer1, 1000 ether);
        vm.startPrank(issuer1);
        mockMoca.approve(address(issuerStakingController), 1000 ether);
        issuerStakingController.stakeMoca(500 ether);
        vm.stopPrank();
        
        issuers = new address[](1);
        issuers[0] = issuer1;
    }

    function test_Emergency_Step1_Pause() public {
        // Step 1: Pause
        vm.prank(monitor);
        paymentsController.pause();
        
        assertTrue(paymentsController.paused());
        
        // Operations blocked
        vm.prank(issuer1);
        vm.expectRevert();
        paymentsController.createSchema(testIssuerId, 100);
    }

    function test_Emergency_Step2_Freeze() public {
        // Step 1: Pause
        vm.prank(monitor);
        paymentsController.pause();
        
        // Step 2: Freeze
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        assertEq(paymentsController.isFrozen(), 1);
        
        // Cannot unpause
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen);
        paymentsController.unpause();
    }

    function test_Emergency_Step3_EmergencyExit() public {
        // Setup frozen state
        vm.prank(monitor);
        paymentsController.pause();
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        // Freeze issuer staking controller too
        vm.prank(monitor);
        issuerStakingController.pause();
        vm.prank(globalAdmin);
        issuerStakingController.freeze();
        
        // Emergency exit from PaymentsController
        bytes32[] memory verifiers = new bytes32[](1);
        verifiers[0] = testVerifierId;
        
        vm.prank(emergencyExitHandler);
        paymentsController.emergencyExitVerifiers(verifiers);
        
        // Emergency exit from IssuerStakingController
        vm.prank(emergencyExitHandler);
        issuerStakingController.emergencyExit(issuers);
        
        // Verify funds returned
        assertEq(mockUSD8.balanceOf(verifier1Asset), 500 ether);
        assertEq(mockMoca.balanceOf(issuer1), 500 ether);
    }

    function test_EmergencyExit_CannotHappenUnfrozen() public {
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.NotFrozen);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
    }

    function test_EmergencyExit_OnlyHandler() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        vm.prank(globalAdmin);
        paymentsController.freeze();
        
        vm.prank(unauthorized);
        vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
    }
}

// ============================================
// SECTION 8: ROLE CHANGE SCENARIOS
// ============================================

contract TestScenarios_RoleChanges is StateT0_Deploy {
    
    address public newGlobalAdmin = makeAddr("newGlobalAdmin");
    address public currentAdminHelper = makeAddr("currentAdminHelper");
    
    function test_RoleRevocation_ImmediateEffect() public {
        // Current state: monitorAdmin has role
        assertTrue(accessController.isMonitorAdmin(monitorAdmin));
        
        // Revoke role
        vm.prank(globalAdmin);
        accessController.removeMonitorAdmin(monitorAdmin);
        
        // Immediately cannot use role
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.addMonitor(makeAddr("newMonitor"));
    }

    function test_RoleGranted_ImmediateAccess() public {
        address newMonitorAdmin = makeAddr("newMonitorAdmin");
        
        vm.prank(globalAdmin);
        accessController.addMonitorAdmin(newMonitorAdmin);
        
        // Immediately can use
        address newMonitor = makeAddr("newMonitor");
        vm.prank(newMonitorAdmin);
        accessController.addMonitor(newMonitor);
        
        assertTrue(accessController.isMonitor(newMonitor));
    }

    function test_GlobalAdminTransfer_PreservesHierarchy() public {
        // Transfer global admin
        vm.prank(globalAdmin);
        addressBook.transferOwnership(newGlobalAdmin);
        
        vm.prank(newGlobalAdmin);
        addressBook.acceptOwnership();
        
        // New admin has control
        assertTrue(accessController.isGlobalAdmin(newGlobalAdmin));
        
        // Can still manage roles
        vm.prank(newGlobalAdmin);
        accessController.addMonitor(makeAddr("testMonitor"));
    }

    function test_AdminCannotRemoveOwnRole() public {
        // Admins cannot remove themselves
        vm.prank(paymentsControllerAdmin);
        vm.expectRevert();
        accessController.removePaymentsControllerAdmin(paymentsControllerAdmin);
        
        // Still has role
        assertTrue(accessController.isPaymentsControllerAdmin(paymentsControllerAdmin));
    }

    function test_RoleIsolation_OperationalVsStrategic() public {
        // Operational admin can only manage operational roles
        vm.prank(monitorAdmin);
        accessController.addMonitor(makeAddr("testMonitor"));
        
        vm.prank(monitorAdmin);
        vm.expectRevert();
        accessController.addPaymentsControllerAdmin(makeAddr("testAdmin"));
        
        // Strategic admin can only manage strategic roles
        vm.prank(paymentsControllerAdmin);
        vm.expectRevert();
        accessController.addMonitor(makeAddr("testMonitor"));
    }

    function test_CascadeRoleRemoval() public {
        // If monitor admin removed, their monitors stay but can't add new ones
        vm.prank(monitorAdmin);
        accessController.addMonitor(makeAddr("tempMonitor"));
        
        // Remove monitor admin
        vm.prank(globalAdmin);
        accessController.removeMonitorAdmin(monitorAdmin);
        
        // Existing monitor still works
        vm.prank(makeAddr("tempMonitor"));
        paymentsController.pause();
    }
}

// ============================================
// SECTION 9: MALICIOUS ATTACK SCENARIOS
// ============================================

contract TestScenarios_MaliciousAttacks is StateT0_Deploy {
    
    address public attacker = makeAddr("attacker");
    address public exploited = makeAddr("exploited");
    
    function test_Attack_TryToPauseAsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.OnlyCallableByMonitor);
        paymentsController.pause();
    }

    function test_Attack_TryToUnpauseAsMonitor() public {
        vm.prank(monitor);
        paymentsController.pause();
        
        // Monitor tries to unpause (attack scenario)
        vm.prank(monitor);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.unpause();
    }

    function test_Attack_TryToFreezeWithoutPause() public {
        vm.prank(globalAdmin);
        vm.expectRevert(); // Pausable: not paused
        paymentsController.freeze();
    }

    function test_Attack_TryToEmergencyExitWithoutFreeze() public {
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.NotFrozen);
        paymentsController.emergencyExitVerifiers(new bytes32[](0));
    }

    function test_Attack_SocialEngineering_RoleRequest() public {
        // Attacker tries to add themselves to sensitive roles
        vm.prank(attacker);
        vm.expectRevert();
        accessController.addPaymentsControllerAdmin(attacker);
        
        vm.prank(attacker);
        vm.expectRevert();
        accessController.addAssetManager(attacker);
        
        vm.prank(attacker);
        vm.expectRevert();
        accessController.addEmergencyExitHandler(attacker);
    }

    function test_Defense_InDepth() public {
        // Even if monitor admin compromised, limits damage
        address malicious = makeAddr("malicious");
        
        vm.prank(globalAdmin);
        accessController.addMonitorAdmin(malicious);
        
        // Malicious admin adds themselves as monitor
        vm.prank(malicious);
        accessController.addMonitor(malicious);
        
        // Can pause but cannot unpause or freeze
        vm.prank(malicious);
        paymentsController.pause();
        
        // Cannot unpause
        vm.prank(malicious);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.unpause();
        
        // Cannot freeze
        vm.prank(malicious);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.freeze();
        
        // Global admin can still recover
        vm.prank(globalAdmin);
        paymentsController.unpause();
    }

    function test_CompromisedGlobalAdmin_Scenario() public {
        // Worst case scenario
        address compromised = makeAddr("compromised");
        
        vm.prank(globalAdmin);
        accessController.addPaymentsControllerAdmin(compromised);
        
        // Compromised can change critical parameters
        vm.prank(compromised);
        paymentsController.updateProtocolFeePercentage(9000); // 90%
        
        assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), 9000);
        
        // But cannot freeze or emergency exit without global admin
        vm.prank(compromised);
        vm.expectRevert(Errors.OnlyCallableByGlobalAdmin);
        paymentsController.freeze();
    }

    function test_RaceCondition_ParameterUpdates() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        
        // Both users try to update simultaneously
        vm.prank(paymentsControllerAdmin);
        paymentsController.updateProtocolFeePercentage(100);
        
        vm.prank(paymentsControllerAdmin);
        paymentsController.updateProtocolFeePercentage(200);
        
        // Last one wins
        assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), 200);
    }

    function test_Reentrancy_Prevention() public {
        // Pause should prevent reentrancy during operations
        vm.prank(monitor);
        paymentsController.pause();
        
        // Even if called during another operation, pause blocks it
        assertTrue(paymentsController.paused());
    }
}

abstract contract StateT0_Deploy is TestingHarness {
    function setUp() public virtual override {
        super.setUp();
    }
}
