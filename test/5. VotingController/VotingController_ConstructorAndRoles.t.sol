// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {VotingController} from "../../src/VotingController.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";

/**
 * @title VotingController_ConstructorAndRoles_Test
 * @notice Tests for VotingController constructor and role setup
 */
contract VotingController_ConstructorAndRoles_Test is VotingControllerHarness {

    // ═══════════════════════════════════════════════════════════════════
    // Constructor: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_Constructor_SetsImmutables() public view {
        assertEq(votingController.WMOCA(), address(mockWMoca), "WMOCA not set correctly");
        assertEq(address(votingController.ESMOCA()), address(mockEsMoca), "ESMOCA not set correctly");
        assertEq(address(votingController.VEMOCA()), address(mockVeMoca), "VEMOCA not set correctly");
        assertEq(address(votingController.PAYMENTS_CONTROLLER()), address(mockPaymentsController), "PAYMENTS_CONTROLLER not set correctly");
    }

    function test_Constructor_SetsMutableAddresses() public view {
        assertEq(votingController.VOTING_CONTROLLER_TREASURY(), votingControllerTreasury, "Treasury not set correctly");
    }

    function test_Constructor_SetsParameters() public view {
        assertEq(votingController.DELEGATE_REGISTRATION_FEE(), delegateRegistrationFee, "Delegate registration fee not set correctly");
        assertEq(votingController.MAX_DELEGATE_FEE_PCT(), maxDelegateFeePct, "Max delegate fee pct not set correctly");
        assertEq(votingController.FEE_INCREASE_DELAY_EPOCHS(), feeIncreaseDelayEpochs, "Fee increase delay epochs not set correctly");
        assertEq(votingController.UNCLAIMED_DELAY_EPOCHS(), unclaimedDelayEpochs, "Unclaimed delay epochs not set correctly");
        assertEq(votingController.MOCA_TRANSFER_GAS_LIMIT(), MOCA_TRANSFER_GAS_LIMIT, "Moca transfer gas limit not set correctly");
    }

    function test_Constructor_SetsInitialEpochState() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // Current epoch should be in Voting state
        EpochSnapshot memory current = captureEpochState(currentEpoch);
        assertEq(uint8(current.state), uint8(DataTypes.EpochState.Voting), "Current epoch should be in Voting state");
        
        // Previous epoch should be finalized
        EpochSnapshot memory previous = captureEpochState(currentEpoch - 1);
        assertEq(uint8(previous.state), uint8(DataTypes.EpochState.Finalized), "Previous epoch should be Finalized");
        
        // CURRENT_EPOCH_TO_FINALIZE should be current epoch
        assertEq(votingController.CURRENT_EPOCH_TO_FINALIZE(), currentEpoch, "CURRENT_EPOCH_TO_FINALIZE should be current epoch");
    }

    function test_Constructor_InitialCountersAreZero() public view {
        assertEq(votingController.TOTAL_POOLS_CREATED(), 0, "TOTAL_POOLS_CREATED should be 0");
        assertEq(votingController.TOTAL_ACTIVE_POOLS(), 0, "TOTAL_ACTIVE_POOLS should be 0");
        assertEq(votingController.TOTAL_SUBSIDIES_DEPOSITED(), 0, "TOTAL_SUBSIDIES_DEPOSITED should be 0");
        assertEq(votingController.TOTAL_SUBSIDIES_CLAIMED(), 0, "TOTAL_SUBSIDIES_CLAIMED should be 0");
        assertEq(votingController.TOTAL_REWARDS_DEPOSITED(), 0, "TOTAL_REWARDS_DEPOSITED should be 0");
        assertEq(votingController.TOTAL_REWARDS_CLAIMED(), 0, "TOTAL_REWARDS_CLAIMED should be 0");
        assertEq(votingController.TOTAL_REGISTRATION_FEES_COLLECTED(), 0, "TOTAL_REGISTRATION_FEES_COLLECTED should be 0");
        assertEq(votingController.TOTAL_REGISTRATION_FEES_CLAIMED(), 0, "TOTAL_REGISTRATION_FEES_CLAIMED should be 0");
        assertEq(votingController.isFrozen(), 0, "isFrozen should be 0");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Constructor: Revert Cases - Invalid Addresses
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_Constructor_ZeroWMoca() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingController(
            address(0), // wMoca
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_ZeroEsMoca() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingController(
            address(mockWMoca),
            address(0), // esMoca
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_ZeroVeMoca() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(0), // veMoca
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_ZeroPaymentsController() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(0), // paymentsController
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_ZeroTreasury() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            address(0), // treasury
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_ZeroGlobalAdmin() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            address(0), // globalAdmin
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Constructor: Revert Cases - Invalid Parameters
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_Constructor_ZeroFeeDelayEpochs() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            0, // feeDelayEpochs = 0
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_ZeroUnclaimedDelayEpochs() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            0, // unclaimedDelayEpochs = 0
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_MaxDelegateFeePctZero() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            0, // maxDelegateFeePct = 0
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_MaxDelegateFeePctTooHigh() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            10_000, // maxDelegateFeePct = 100% (PRECISION_BASE)
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
    }

    function test_RevertWhen_Constructor_GasLimitTooLow() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            2299 // less than 2300
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Roles: Setup Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_Roles_GlobalAdminHasDefaultAdminRole() public view {
        assertTrue(votingController.hasRole(votingController.DEFAULT_ADMIN_ROLE(), globalAdmin), "Global admin should have DEFAULT_ADMIN_ROLE");
    }

    function test_Roles_VotingControllerAdminRole() public view {
        assertTrue(votingController.hasRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE, votingControllerAdmin), "VotingController admin should have VOTING_CONTROLLER_ADMIN_ROLE");
    }

    function test_Roles_MonitorAdminRole() public view {
        assertTrue(votingController.hasRole(Constants.MONITOR_ADMIN_ROLE, monitorAdmin), "Monitor admin should have MONITOR_ADMIN_ROLE");
    }

    function test_Roles_CronJobAdminRole() public view {
        assertTrue(votingController.hasRole(Constants.CRON_JOB_ADMIN_ROLE, cronJobAdmin), "CronJob admin should have CRON_JOB_ADMIN_ROLE");
    }

    function test_Roles_MonitorRole() public view {
        assertTrue(votingController.hasRole(Constants.MONITOR_ROLE, monitor), "Monitor should have MONITOR_ROLE");
    }

    function test_Roles_EmergencyExitHandlerRole() public view {
        assertTrue(votingController.hasRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler), "Emergency exit handler should have EMERGENCY_EXIT_HANDLER_ROLE");
    }

    function test_Roles_AssetManagerRole() public view {
        assertTrue(votingController.hasRole(Constants.ASSET_MANAGER_ROLE, assetManager), "Asset manager should have ASSET_MANAGER_ROLE");
    }

    function test_Roles_CronJobRole() public view {
        // Granted in setUp
        assertTrue(votingController.hasRole(Constants.CRON_JOB_ROLE, cronJob), "CronJob should have CRON_JOB_ROLE");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Roles: Admin Hierarchy
    // ═══════════════════════════════════════════════════════════════════

    function test_Roles_MonitorRoleAdminIsMonitorAdmin() public view {
        assertEq(votingController.getRoleAdmin(Constants.MONITOR_ROLE), Constants.MONITOR_ADMIN_ROLE, "MONITOR_ROLE admin should be MONITOR_ADMIN_ROLE");
    }

    function test_Roles_CronJobRoleAdminIsCronJobAdmin() public view {
        assertEq(votingController.getRoleAdmin(Constants.CRON_JOB_ROLE), Constants.CRON_JOB_ADMIN_ROLE, "CRON_JOB_ROLE admin should be CRON_JOB_ADMIN_ROLE");
    }

    function test_Roles_VotingControllerAdminRoleAdminIsDefaultAdmin() public view {
        assertEq(votingController.getRoleAdmin(Constants.VOTING_CONTROLLER_ADMIN_ROLE), votingController.DEFAULT_ADMIN_ROLE(), "VOTING_CONTROLLER_ADMIN_ROLE admin should be DEFAULT_ADMIN_ROLE");
    }

    function test_Roles_EmergencyExitHandlerRoleAdminIsDefaultAdmin() public view {
        assertEq(votingController.getRoleAdmin(Constants.EMERGENCY_EXIT_HANDLER_ROLE), votingController.DEFAULT_ADMIN_ROLE(), "EMERGENCY_EXIT_HANDLER_ROLE admin should be DEFAULT_ADMIN_ROLE");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Roles: Access Control
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_UnauthorizedGrantsRole() public {
        address randomUser = makeAddr("randomUser");
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, randomUser, votingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(randomUser);
        votingController.grantRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE, randomUser);
    }

    function test_Can_GlobalAdminGrantRole() public {
        address newAdmin = makeAddr("newAdmin");
        
        vm.prank(globalAdmin);
        votingController.grantRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE, newAdmin);
        
        assertTrue(votingController.hasRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE, newAdmin), "New admin should have role");
    }

    function test_Can_MonitorAdminGrantMonitorRole() public {
        address newMonitor = makeAddr("newMonitor");
        
        vm.prank(monitorAdmin);
        votingController.grantRole(Constants.MONITOR_ROLE, newMonitor);
        
        assertTrue(votingController.hasRole(Constants.MONITOR_ROLE, newMonitor), "New monitor should have role");
    }

    function test_Can_CronJobAdminGrantCronJobRole() public {
        address newCronJob = makeAddr("newCronJob");
        
        vm.prank(cronJobAdmin);
        votingController.grantRole(Constants.CRON_JOB_ROLE, newCronJob);
        
        assertTrue(votingController.hasRole(Constants.CRON_JOB_ROLE, newCronJob), "New cronJob should have role");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Zero Registration Fee Allowed
    // ═══════════════════════════════════════════════════════════════════

    function test_Constructor_ZeroRegistrationFeeAllowed() public {
        VotingController vc = new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            0, // zero registration fee allowed
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );
        
        assertEq(vc.DELEGATE_REGISTRATION_FEE(), 0, "Zero registration fee should be allowed");
    }
}

