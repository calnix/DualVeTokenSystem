// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title VotingController_RiskAndPause_Test
 * @notice Tests for pause, unpause, freeze, and emergencyExit functionality
 */
contract VotingController_RiskAndPause_Test is VotingControllerHarness {

    function setUp() public override {
        super.setUp();
        _createPools(2);
    }

    // ═══════════════════════════════════════════════════════════════════
    // pause: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_Pause_Success() public {
        assertFalse(votingController.paused(), "Should not be paused initially");
        
        vm.prank(monitor);
        votingController.pause();
        
        assertTrue(votingController.paused(), "Should be paused");
    }

    function test_Pause_BlocksFunctions() public {
        vm.prank(monitor);
        votingController.pause();
        
        // vote() should be blocked
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), false);
        
        // registerAsDelegate() should be blocked
        vm.deal(delegate1, delegateRegistrationFee);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(1000);
        
        // createPools() should be blocked
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(votingControllerAdmin);
        votingController.createPools(1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // pause: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_Pause_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.MONITOR_ROLE));
        vm.prank(voter1);
        votingController.pause();
    }

    function test_RevertWhen_Pause_AlreadyPaused() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(monitor);
        votingController.pause();
    }

    // ═══════════════════════════════════════════════════════════════════
    // unpause: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_Unpause_Success() public {
        vm.prank(monitor);
        votingController.pause();
        assertTrue(votingController.paused(), "Should be paused");
        
        vm.prank(globalAdmin);
        votingController.unpause();
        
        assertFalse(votingController.paused(), "Should be unpaused");
    }

    function test_Unpause_RestoresFunctionality() public {
        uint128 epoch = getCurrentEpochNumber();
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.prank(globalAdmin);
        votingController.unpause();
        
        // vote() should work
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(100 ether));
        
        (uint128 votesSpent,) = votingController.usersEpochData(epoch, voter1);
        assertEq(votesSpent, 100 ether, "Vote should succeed after unpause");
    }

    // ═══════════════════════════════════════════════════════════════════
    // unpause: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_Unpause_NotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(globalAdmin);
        votingController.unpause();
    }

    function test_RevertWhen_Unpause_Unauthorized() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, votingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(voter1);
        votingController.unpause();
    }

    function test_RevertWhen_Unpause_Frozen() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.prank(globalAdmin);
        votingController.freeze();
        
        vm.expectRevert(Errors.IsFrozen.selector);
        vm.prank(globalAdmin);
        votingController.unpause();
    }

    // ═══════════════════════════════════════════════════════════════════
    // freeze: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_Freeze_Success() public {
        assertEq(votingController.isFrozen(), 0, "Should not be frozen initially");
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.ContractFrozen();
        
        vm.prank(globalAdmin);
        votingController.freeze();
        
        assertEq(votingController.isFrozen(), 1, "Should be frozen");
    }

    function test_Freeze_PreventsUnpause() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.prank(globalAdmin);
        votingController.freeze();
        
        vm.expectRevert(Errors.IsFrozen.selector);
        vm.prank(globalAdmin);
        votingController.unpause();
    }

    // ═══════════════════════════════════════════════════════════════════
    // freeze: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_Freeze_NotPaused() public {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(globalAdmin);
        votingController.freeze();
    }

    function test_RevertWhen_Freeze_AlreadyFrozen() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.prank(globalAdmin);
        votingController.freeze();
        
        vm.expectRevert(Errors.IsFrozen.selector);
        vm.prank(globalAdmin);
        votingController.freeze();
    }

    function test_RevertWhen_Freeze_Unauthorized() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, votingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(voter1);
        votingController.freeze();
    }

    // ═══════════════════════════════════════════════════════════════════
    // emergencyExit: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_EmergencyExit_Success() public {
        uint128 epoch = getCurrentEpochNumber();
        
        // Setup some state
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(50 ether, 0));
        
        // Register delegates to add registration fees
        _registerDelegate(delegate1, 1000);
        
        uint256 contractEsMocaBalance = mockEsMoca.balanceOf(address(votingController));
        uint256 contractMocaBalance = address(votingController).balance;
        
        // Freeze the contract
        vm.prank(monitor);
        votingController.pause();
        
        vm.prank(globalAdmin);
        votingController.freeze();
        
        uint256 treasuryEsMocaBefore = mockEsMoca.balanceOf(votingControllerTreasury);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EmergencyExit(votingControllerTreasury);
        
        vm.prank(emergencyExitHandler);
        votingController.emergencyExit();
        
        uint256 treasuryEsMocaAfter = mockEsMoca.balanceOf(votingControllerTreasury);
        
        assertEq(treasuryEsMocaAfter - treasuryEsMocaBefore, contractEsMocaBalance, "Treasury should receive all esMoca");
        assertEq(mockEsMoca.balanceOf(address(votingController)), 0, "Contract should have 0 esMoca");
        
        // Check Moca was transferred (native or wrapped)
        uint256 treasuryMocaAfter = votingControllerTreasury.balance;
        uint256 treasuryWMocaAfter = mockWMoca.balanceOf(votingControllerTreasury);
        assertTrue(treasuryMocaAfter >= contractMocaBalance || treasuryWMocaAfter >= contractMocaBalance, "Treasury should receive Moca");
    }

    // ═══════════════════════════════════════════════════════════════════
    // emergencyExit: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_EmergencyExit_NotFrozen() public {
        vm.expectRevert(Errors.NotFrozen.selector);
        vm.prank(emergencyExitHandler);
        votingController.emergencyExit();
    }

    function test_RevertWhen_EmergencyExit_OnlyPaused() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Errors.NotFrozen.selector);
        vm.prank(emergencyExitHandler);
        votingController.emergencyExit();
    }

    function test_RevertWhen_EmergencyExit_Unauthorized() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.prank(globalAdmin);
        votingController.freeze();
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.EMERGENCY_EXIT_HANDLER_ROLE));
        vm.prank(voter1);
        votingController.emergencyExit();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Paused State Impact on Core Functions
    // ═══════════════════════════════════════════════════════════════════

    function test_Paused_BlocksVote() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), false);
    }

    function test_Paused_BlocksMigrateVotes() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(100 ether), false);
    }

    function test_Paused_BlocksClaimPersonalRewards() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
    }

    function test_Paused_BlocksClaimSubsidies() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 0));
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_Paused_BlocksEndEpoch() public {
        _warpToEpochEnd();
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(cronJob);
        votingController.endEpoch();
    }

    function test_Paused_BlocksForceFinalizeEpoch() public {
        _warpToEpochEnd();
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
    }
}

