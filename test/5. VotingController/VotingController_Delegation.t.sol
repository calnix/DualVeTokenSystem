// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title VotingController_Delegation_Test
 * @notice Tests for delegate registration, fee updates, and unregistration
 */
contract VotingController_Delegation_Test is VotingControllerHarness {

    function setUp() public override {
        super.setUp();
        _createPools(3);
    }

    // ═══════════════════════════════════════════════════════════════════
    // registerAsDelegate: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RegisterAsDelegate_Success() public {
        uint128 epoch = getCurrentEpochNumber();
        uint128 feePct = 1000; // 10%
        
        vm.deal(delegate1, delegateRegistrationFee);
        
        // ---- CAPTURE BEFORE STATE ----
        GlobalCountersSnapshot memory globalBefore = captureGlobalCounters();
        DelegateSnapshot memory delegateBefore = captureDelegateState(delegate1);
        uint256 contractBalanceBefore = address(votingController).balance;
        
        // Verify initial state
        assertFalse(delegateBefore.isRegistered, "Delegate should not be registered initially");
        assertEq(delegateBefore.currentFeePct, 0, "Fee should be 0 initially");
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateRegistered(delegate1, feePct);
        
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(feePct);
        
        // ---- CAPTURE AFTER STATE ----
        GlobalCountersSnapshot memory globalAfter = captureGlobalCounters();
        DelegateSnapshot memory delegateAfter = captureDelegateState(delegate1);
        uint256 contractBalanceAfter = address(votingController).balance;
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Delegate state
        assertTrue(delegateAfter.isRegistered, "Delegate should be registered");
        assertEq(delegateAfter.currentFeePct, feePct, "Fee percentage: exactly 1000 (10%)");
        assertEq(delegateAfter.nextFeePct, 0, "Next fee should remain 0");
        assertEq(delegateAfter.nextFeePctEpoch, 0, "Next fee epoch should remain 0");
        
        // Historical fee recorded
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch), feePct, "Historical fee recorded for current epoch");
        
        // Global counters
        assertEq(globalAfter.totalRegistrationFeesCollected, globalBefore.totalRegistrationFeesCollected + delegateRegistrationFee, 
            "Registration fees increased by exact fee amount");
        
        // Contract balance
        assertEq(contractBalanceAfter, contractBalanceBefore + delegateRegistrationFee, 
            "Contract balance increased by registration fee");
    }

    function test_RegisterAsDelegate_ZeroFeePct() public {
        vm.deal(delegate1, delegateRegistrationFee);
        
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(0);
        
        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertTrue(snapshot.isRegistered, "Delegate should be registered");
        assertEq(snapshot.currentFeePct, 0, "Zero fee should be allowed");
    }

    function test_RegisterAsDelegate_MaxFeePct() public {
        vm.deal(delegate1, delegateRegistrationFee);
        
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(maxDelegateFeePct);
        
        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertEq(snapshot.currentFeePct, maxDelegateFeePct, "Max fee should be allowed");
    }

    function test_RegisterAsDelegate_RecordsHistoricalFee() public {
        uint128 epoch = getCurrentEpochNumber();
        uint128 feePct = 2000;
        
        _registerDelegate(delegate1, feePct);
        
        uint128 historicalFee = votingController.delegateHistoricalFeePcts(delegate1, epoch);
        assertEq(historicalFee, feePct, "Historical fee should be recorded");
    }

    // ═══════════════════════════════════════════════════════════════════
    // registerAsDelegate: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_RegisterAsDelegate_WrongFee() public {
        vm.deal(delegate1, delegateRegistrationFee + 1);
        
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee + 1}(1000);
    }

    function test_RevertWhen_RegisterAsDelegate_InsufficientFee() public {
        vm.deal(delegate1, delegateRegistrationFee - 1);
        
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee - 1}(1000);
    }

    function test_RevertWhen_RegisterAsDelegate_FeePctExceedsMax() public {
        vm.deal(delegate1, delegateRegistrationFee);
        
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(maxDelegateFeePct + 1);
    }

    function test_RevertWhen_RegisterAsDelegate_AlreadyRegistered() public {
        _registerDelegate(delegate1, 1000);
        
        vm.deal(delegate1, delegateRegistrationFee);
        
        vm.expectRevert(Errors.DelegateAlreadyRegistered.selector);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(1000);
    }

    function test_RevertWhen_RegisterAsDelegate_Paused() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.deal(delegate1, delegateRegistrationFee);
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(1000);
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateDelegateFee: Fee Decrease (Immediate)
    // ═══════════════════════════════════════════════════════════════════

    function test_UpdateDelegateFee_DecreaseImmediate() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 2000); // 20%
        
        // ---- CAPTURE BEFORE STATE ----
        DelegateSnapshot memory before = captureDelegateState(delegate1);
        uint128 historicalFeeBefore = votingController.delegateHistoricalFeePcts(delegate1, epoch);
        
        // Verify initial state
        assertEq(before.currentFeePct, 2000, "Initial fee should be 20%");
        assertEq(historicalFeeBefore, 2000, "Historical fee should be 20%");
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateFeeDecreased(delegate1, 2000, 1000);
        
        vm.prank(delegate1);
        votingController.updateDelegateFee(1000); // 10%
        
        // ---- CAPTURE AFTER STATE ----
        DelegateSnapshot memory after_ = captureDelegateState(delegate1);
        uint128 historicalFeeAfter = votingController.delegateHistoricalFeePcts(delegate1, epoch);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Current fee changed immediately
        assertEq(after_.currentFeePct, 1000, "Fee decreased: 2000 -> 1000");
        
        // No pending fee scheduled
        assertEq(after_.nextFeePct, 0, "Next fee should be 0 (immediate decrease)");
        assertEq(after_.nextFeePctEpoch, 0, "Next fee epoch should be 0");
        
        // Historical fee updated immediately
        assertEq(historicalFeeAfter, 1000, "Historical fee updated: 2000 -> 1000");
        
        // Registration status unchanged
        assertEq(after_.isRegistered, before.isRegistered, "Registration status unchanged");
    }

    function test_UpdateDelegateFee_DecreaseToZero() public {
        _registerDelegate(delegate1, 2000);
        
        vm.prank(delegate1);
        votingController.updateDelegateFee(0);
        
        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertEq(snapshot.currentFeePct, 0, "Fee should decrease to zero");
    }

    function test_UpdateDelegateFee_DecreaseOverwritesPendingIncrease() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 2000);
        
        // Schedule fee increase
        vm.prank(delegate1);
        votingController.updateDelegateFee(3000);
        
        DelegateSnapshot memory afterIncrease = captureDelegateState(delegate1);
        assertEq(afterIncrease.nextFeePct, 3000, "Increase should be scheduled");
        assertEq(afterIncrease.nextFeePctEpoch, epoch + feeIncreaseDelayEpochs, "Increase epoch should be set");
        
        // Decrease immediately
        vm.prank(delegate1);
        votingController.updateDelegateFee(1000);
        
        DelegateSnapshot memory afterDecrease = captureDelegateState(delegate1);
        assertEq(afterDecrease.currentFeePct, 1000, "Fee should decrease immediately");
        assertEq(afterDecrease.nextFeePct, 0, "Pending increase should be cleared");
        assertEq(afterDecrease.nextFeePctEpoch, 0, "Pending epoch should be cleared");
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateDelegateFee: Fee Increase (Delayed)
    // ═══════════════════════════════════════════════════════════════════

    function test_UpdateDelegateFee_IncreaseScheduled() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 1000); // 10%
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateFeeIncreased(delegate1, 1000, 2000, epoch + feeIncreaseDelayEpochs);
        
        vm.prank(delegate1);
        votingController.updateDelegateFee(2000); // 20%
        
        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertEq(snapshot.currentFeePct, 1000, "Current fee should not change");
        assertEq(snapshot.nextFeePct, 2000, "Next fee should be set");
        assertEq(snapshot.nextFeePctEpoch, epoch + feeIncreaseDelayEpochs, "Next fee epoch should be set");
    }

    function test_UpdateDelegateFee_IncreaseAppliedOnVote() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 1000);
        
        // Schedule fee increase
        vm.prank(delegate1);
        votingController.updateDelegateFee(2000);
        
        // Warp to delayed epoch
        _warpToEpoch(epoch + feeIncreaseDelayEpochs);
        uint128 newEpoch = getCurrentEpochNumber();
        
        // Setup voting power and vote
        _setupVotingPower(delegate1, newEpoch, 0, 1000 ether);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateFeeApplied(delegate1, 1000, 2000, newEpoch);
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(100 ether));
        
        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertEq(snapshot.currentFeePct, 2000, "Fee should be applied");
        assertEq(snapshot.nextFeePct, 0, "Next fee should be cleared");
        assertEq(snapshot.nextFeePctEpoch, 0, "Next fee epoch should be cleared");
    }

    // ═══════════════════════════════════════════════════════════════════
    // updateDelegateFee: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_UpdateDelegateFee_NotRegistered() public {
        vm.expectRevert(Errors.NotRegisteredAsDelegate.selector);
        vm.prank(delegate1);
        votingController.updateDelegateFee(1000);
    }

    function test_RevertWhen_UpdateDelegateFee_ExceedsMax() public {
        _registerDelegate(delegate1, 1000);
        
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(delegate1);
        votingController.updateDelegateFee(maxDelegateFeePct + 1);
    }

    function test_RevertWhen_UpdateDelegateFee_SameAsCurrent() public {
        _registerDelegate(delegate1, 1000);
        
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(delegate1);
        votingController.updateDelegateFee(1000);
    }

    function test_RevertWhen_UpdateDelegateFee_Paused() public {
        _registerDelegate(delegate1, 1000);
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(delegate1);
        votingController.updateDelegateFee(500);
    }

    // ═══════════════════════════════════════════════════════════════════
    // unregisterAsDelegate: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_UnregisterAsDelegate_Success() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 1000);
        
        // ---- CAPTURE BEFORE STATE ----
        DelegateSnapshot memory before = captureDelegateState(delegate1);
        uint128 historicalFeeBefore = votingController.delegateHistoricalFeePcts(delegate1, epoch);
        
        // Verify initial registered state
        assertTrue(before.isRegistered, "Delegate should be registered initially");
        assertEq(before.currentFeePct, 1000, "Fee should be 10%");
        assertEq(historicalFeeBefore, 1000, "Historical fee should be recorded");
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateUnregistered(delegate1);
        
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
        
        // ---- CAPTURE AFTER STATE ----
        DelegateSnapshot memory after_ = captureDelegateState(delegate1);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Registration cleared
        assertFalse(after_.isRegistered, "isRegistered: true -> false");
        
        // Fee data cleared
        assertEq(after_.currentFeePct, 0, "currentFeePct: 1000 -> 0");
        assertEq(after_.nextFeePct, 0, "nextFeePct should be 0");
        assertEq(after_.nextFeePctEpoch, 0, "nextFeePctEpoch should be 0");
        
        // Note: Historical fee for past epochs is NOT cleared (immutable history)
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch), historicalFeeBefore, 
            "Historical fee for past epoch should be preserved");
    }

    function test_UnregisterAsDelegate_ClearsPendingFeeIncrease() public {
        _registerDelegate(delegate1, 1000);
        
        // Schedule fee increase
        vm.prank(delegate1);
        votingController.updateDelegateFee(2000);
        
        DelegateSnapshot memory beforeUnreg = captureDelegateState(delegate1);
        assertEq(beforeUnreg.nextFeePct, 2000, "Should have pending increase");
        
        // Unregister
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
        
        DelegateSnapshot memory afterUnreg = captureDelegateState(delegate1);
        assertFalse(afterUnreg.isRegistered, "Should not be registered");
        assertEq(afterUnreg.nextFeePct, 0, "Pending increase should be cleared");
    }

    // ═══════════════════════════════════════════════════════════════════
    // unregisterAsDelegate: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_UnregisterAsDelegate_NotRegistered() public {
        vm.expectRevert(Errors.NotRegisteredAsDelegate.selector);
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
    }

    function test_RevertWhen_UnregisterAsDelegate_HasActiveVotes() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 1000);
        
        // Setup voting power and vote
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(500 ether));
        
        vm.expectRevert(Errors.CannotUnregisterWithActiveVotes.selector);
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
    }

    function test_UnregisterAsDelegate_CanUnregisterAfterEpochChange() public {
        uint128 epoch = getCurrentEpochNumber();
        _registerDelegate(delegate1, 1000);
        
        // Vote in current epoch
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(500 ether));
        
        // End and finalize current epoch
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(50 ether));
        
        // In new epoch, no votes spent yet
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
        
        assertFalse(captureDelegateState(delegate1).isRegistered, "Should be unregistered");
    }

    function test_RevertWhen_UnregisterAsDelegate_Paused() public {
        _registerDelegate(delegate1, 1000);
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Re-registration After Unregistration
    // ═══════════════════════════════════════════════════════════════════

    function test_CanReregisterAfterUnregistration() public {
        _registerDelegate(delegate1, 1000);
        
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
        
        // Re-register with different fee
        vm.deal(delegate1, delegateRegistrationFee);
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(2000);
        
        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertTrue(snapshot.isRegistered, "Should be re-registered");
        assertEq(snapshot.currentFeePct, 2000, "New fee should be set");
    }
}

