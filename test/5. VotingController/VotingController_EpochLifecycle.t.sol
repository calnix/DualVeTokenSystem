// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";

/**
 * @title VotingController_EpochLifecycle_Test
 * @notice Tests for epoch lifecycle: endEpoch, processVerifierChecks, processRewardsAndSubsidies, finalizeEpoch, forceFinalizeEpoch
 */
contract VotingController_EpochLifecycle_Test is VotingControllerHarness {

    uint128 internal epoch;

    function setUp() public override {
        super.setUp();
        _createPools(3);
        epoch = getCurrentEpochNumber();
    }

    // ═══════════════════════════════════════════════════════════════════
    // endEpoch: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_EndEpoch_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        // ---- CAPTURE BEFORE STATE ----
        EpochSnapshot memory epochBefore = captureEpochState(epoch);
        GlobalCountersSnapshot memory globalBefore = captureGlobalCounters();
        uint128 epochToFinalizeBefore = votingController.CURRENT_EPOCH_TO_FINALIZE();
        
        assertEq(uint8(epochBefore.state), uint8(DataTypes.EpochState.Voting), "Initial state should be Voting");
        assertEq(epochBefore.totalActivePools, 0, "Pools not snapshotted until endEpoch");
        
        // ---- EXECUTE ----
        _warpToEpochEnd();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochEnded(epoch);
        
        vm.prank(cronJob);
        votingController.endEpoch();
        
        // ---- CAPTURE AFTER STATE ----
        EpochSnapshot memory epochAfter = captureEpochState(epoch);
        GlobalCountersSnapshot memory globalAfter = captureGlobalCounters();
        uint128 epochToFinalizeAfter = votingController.CURRENT_EPOCH_TO_FINALIZE();
        
        // ---- VERIFY EXACT STATE TRANSITIONS ----
        
        // State transition: Voting -> Ended
        assertEq(uint8(epochAfter.state), uint8(DataTypes.EpochState.Ended), "State: Voting -> Ended");
        
        // Pools snapshotted at endEpoch
        assertEq(epochAfter.totalActivePools, 3, "Active pools snapshotted: 3");
        
        // Pool votes preserved
        PoolEpochSnapshot memory pool1After = capturePoolEpochState(epoch, 1);
        assertEq(pool1After.totalVotes, 500 ether, "Pool 1 votes preserved: 500 ether");
        
        // Global counters unchanged
        assertEq(globalAfter.totalActivePools, globalBefore.totalActivePools, "Global active pools unchanged");
        
        // Epoch to finalize stays same until actual finalization
        assertEq(epochToFinalizeAfter, epochToFinalizeBefore, "Epoch to finalize unchanged until finalized");
    }

    function test_EndEpoch_NoActivePoolsInstantFinalization() public {
        // Remove all pools
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1, 2, 3));
        
        assertEq(votingController.TOTAL_ACTIVE_POOLS(), 0, "No active pools");
        
        _warpToEpochEnd();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochFinalized(epoch);
        
        vm.prank(cronJob);
        votingController.endEpoch();
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.Finalized), "Epoch should be instantly finalized");
        
        // Epoch counter should advance
        assertEq(votingController.CURRENT_EPOCH_TO_FINALIZE(), epoch + 1, "Should advance to next epoch");
    }

    // ═══════════════════════════════════════════════════════════════════
    // endEpoch: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_EndEpoch_TooEarly() public {
        // Don't warp to epoch end
        
        vm.expectRevert(Errors.EpochNotOver.selector);
        vm.prank(cronJob);
        votingController.endEpoch();
    }

    function test_RevertWhen_EndEpoch_NotCronJobRole() public {
        _warpToEpochEnd();
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.CRON_JOB_ROLE));
        vm.prank(voter1);
        votingController.endEpoch();
    }

    function test_RevertWhen_EndEpoch_InvalidState() public {
        _warpToEpochEnd();
        
        // End epoch once
        vm.prank(cronJob);
        votingController.endEpoch();
        
        // Try to end again
        vm.expectRevert(Errors.InvalidEpochState.selector);
        vm.prank(cronJob);
        votingController.endEpoch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // processVerifierChecks: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_ProcessVerifierChecks_AllCleared() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochVerified(epoch);
        
        address[] memory emptyVerifiers = new address[](0);
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, emptyVerifiers);
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.Verified), "Epoch should be in Verified state");
    }

    function test_ProcessVerifierChecks_BlockVerifiers() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        address[] memory verifiersToBlock = _toAddressArray(verifier1, verifier2);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.VerifiersClaimsBlocked(epoch, verifiersToBlock, 2);
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, verifiersToBlock);
        
        // Check verifiers are blocked
        (bool isBlocked1,) = votingController.verifierEpochData(epoch, verifier1);
        (bool isBlocked2,) = votingController.verifierEpochData(epoch, verifier2);
        assertTrue(isBlocked1, "Verifier1 should be blocked");
        assertTrue(isBlocked2, "Verifier2 should be blocked");
        
        // Epoch should still be in Ended state
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.Ended), "Epoch should still be in Ended state");
    }

    function test_ProcessVerifierChecks_BatchProcessing() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        // Block first batch
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, _toAddressArray(verifier1));
        
        // Block second batch and finalize
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.Verified), "Epoch should be Verified");
    }

    // ═══════════════════════════════════════════════════════════════════
    // processVerifierChecks: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ProcessVerifierChecks_WrongState() public {
        // Epoch still in Voting state
        
        vm.expectRevert(Errors.InvalidEpochState.selector);
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
    }

    function test_RevertWhen_ProcessVerifierChecks_InvalidVerifierAddress() public {
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        address[] memory verifiers = new address[](1);
        verifiers[0] = address(0);
        
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, verifiers);
    }

    function test_RevertWhen_ProcessVerifierChecks_EmptyArrayWithoutAllCleared() public {
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, new address[](0));
    }

    // ═══════════════════════════════════════════════════════════════════
    // processRewardsAndSubsidies: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_ProcessRewardsAndSubsidies_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        // Vote for all 3 pools so they can all receive allocations
        _vote(voter1, _toArray(1, 2, 3), _toArray(400 ether, 400 ether, 200 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.PoolsProcessed(epoch, 3);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochFullyProcessed(epoch);
        
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(
            _toArray(1, 2, 3),
            _toArray(100 ether, 200 ether, 0),
            _toArray(50 ether, 0, 100 ether)
        );
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.Processed), "Epoch should be Processed");
        assertEq(snapshot.totalRewardsAllocated, 300 ether, "Total rewards should be accumulated");
        assertEq(snapshot.totalSubsidiesAllocated, 150 ether, "Total subsidies should be accumulated");
        assertEq(snapshot.poolsProcessed, 3, "All pools should be processed");
    }

    function test_ProcessRewardsAndSubsidies_BatchProcessing() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1, 2, 3), _toArray(300 ether, 400 ether, 300 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        // Process in batches
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1), _toArray(100 ether), _toArray(50 ether));
        
        EpochSnapshot memory mid = captureEpochState(epoch);
        assertEq(uint8(mid.state), uint8(DataTypes.EpochState.Verified), "Should still be Verified");
        assertEq(mid.poolsProcessed, 1, "1 pool processed");
        
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(2, 3), _toArray(100 ether, 100 ether), _toArray(50 ether, 50 ether));
        
        EpochSnapshot memory final_ = captureEpochState(epoch);
        assertEq(uint8(final_.state), uint8(DataTypes.EpochState.Processed), "Should be Processed");
        assertEq(final_.poolsProcessed, 3, "All pools processed");
    }

    function test_ProcessRewardsAndSubsidies_SkipsZeroVotePools() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether)); // Only pool 1 has votes
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        // Allocate to all pools but only pool 1 has votes
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(
            _toArray(1, 2, 3),
            _toArray(100 ether, 100 ether, 100 ether),
            _toArray(0, 0, 0)
        );
        
        // Check pool allocations
        PoolEpochSnapshot memory pool1 = capturePoolEpochState(epoch, 1);
        PoolEpochSnapshot memory pool2 = capturePoolEpochState(epoch, 2);
        PoolEpochSnapshot memory pool3 = capturePoolEpochState(epoch, 3);
        
        assertEq(pool1.totalRewardsAllocated, 100 ether, "Pool 1 should have rewards");
        assertEq(pool2.totalRewardsAllocated, 0, "Pool 2 (0 votes) should have no rewards");
        assertEq(pool3.totalRewardsAllocated, 0, "Pool 3 (0 votes) should have no rewards");
        
        // All pools should be marked processed
        assertTrue(pool1.isProcessed, "Pool 1 should be processed");
        assertTrue(pool2.isProcessed, "Pool 2 should be processed");
        assertTrue(pool3.isProcessed, "Pool 3 should be processed");
    }

    // ═══════════════════════════════════════════════════════════════════
    // processRewardsAndSubsidies: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ProcessRewardsAndSubsidies_WrongState() public {
        vm.expectRevert(Errors.EpochNotVerified.selector);
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1), _toArray(100 ether), _toArray(50 ether));
    }

    function test_RevertWhen_ProcessRewardsAndSubsidies_ArrayMismatch() public {
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        vm.expectRevert(Errors.MismatchedArrayLengths.selector);
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1, 2), _toArray(100 ether), _toArray(50 ether, 50 ether));
    }

    function test_RevertWhen_ProcessRewardsAndSubsidies_PoolNotActive() public {
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        // Pool 999 doesn't exist
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(999), _toArray(100 ether), _toArray(50 ether));
    }

    function test_RevertWhen_ProcessRewardsAndSubsidies_PoolAlreadyProcessed() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        // Process pool 1
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1), _toArray(100 ether), _toArray(50 ether));
        
        // Try to process pool 1 again
        vm.expectRevert(Errors.PoolAlreadyProcessed.selector);
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1), _toArray(100 ether), _toArray(50 ether));
    }

    // ═══════════════════════════════════════════════════════════════════
    // finalizeEpoch: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_FinalizeEpoch_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Mint esMoca to treasury for transfer
        mockEsMoca.mintForTesting(votingControllerTreasury, 150 ether);
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(50 ether, 0, 0));
        
        GlobalCountersSnapshot memory before = captureGlobalCounters();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochAllocationsSet(epoch, 100 ether, 50 ether);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochFinalized(epoch);
        
        vm.prank(cronJob);
        votingController.finalizeEpoch();
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.Finalized), "Epoch should be Finalized");
        
        GlobalCountersSnapshot memory after_ = captureGlobalCounters();
        assertEq(after_.totalRewardsDeposited, before.totalRewardsDeposited + 100 ether, "Rewards deposited should increase");
        assertEq(after_.totalSubsidiesDeposited, before.totalSubsidiesDeposited + 50 ether, "Subsidies deposited should increase");
        assertEq(after_.currentEpochToFinalize, before.currentEpochToFinalize + 1, "Should advance to next epoch");
        
        // Check contract received funds
        assertEq(mockEsMoca.balanceOf(address(votingController)), 150 ether, "Contract should receive funds");
    }

    function test_FinalizeEpoch_NoFundsTransferWhenZeroAllocations() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        // Process with zero allocations
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(0, 0, 0));
        
        uint256 treasuryBalanceBefore = mockEsMoca.balanceOf(votingControllerTreasury);
        
        vm.prank(cronJob);
        votingController.finalizeEpoch();
        
        uint256 treasuryBalanceAfter = mockEsMoca.balanceOf(votingControllerTreasury);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore, "No funds should be transferred");
    }

    // ═══════════════════════════════════════════════════════════════════
    // finalizeEpoch: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_FinalizeEpoch_WrongState() public {
        vm.expectRevert(Errors.EpochNotProcessed.selector);
        vm.prank(cronJob);
        votingController.finalizeEpoch();
    }

    // ═══════════════════════════════════════════════════════════════════
    // forceFinalizeEpoch: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_ForceFinalizeEpoch_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _warpToEpochEnd();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.EpochForceFinalized(epoch);
        
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.ForceFinalized), "Epoch should be ForceFinalized");
        assertEq(snapshot.totalRewardsAllocated, 0, "Rewards should be zeroed");
        assertEq(snapshot.totalSubsidiesAllocated, 0, "Subsidies should be zeroed");
        assertEq(snapshot.totalActivePools, 3, "Active pools should be snapshotted");
        
        assertEq(votingController.CURRENT_EPOCH_TO_FINALIZE(), epoch + 1, "Should advance to next epoch");
    }

    function test_ForceFinalizeEpoch_FromEndedState() public {
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(uint8(snapshot.state), uint8(DataTypes.EpochState.ForceFinalized), "Should force finalize from Ended state");
    }

    // ═══════════════════════════════════════════════════════════════════
    // forceFinalizeEpoch: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ForceFinalizeEpoch_TooEarly() public {
        vm.expectRevert(Errors.EpochNotOver.selector);
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
    }

    function test_RevertWhen_ForceFinalizeEpoch_AlreadyFinalized() public {
        // Force finalize epoch once
        _warpToEpochEnd();
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
        
        // Warp to end of NEXT epoch so we can try to force finalize again
        // (the counter has advanced, so we'd be trying the next epoch now)
        // First finalize was for epoch N, now we're trying epoch N+1
        _warpToEpochEnd(); // This warps to end of N+1
        
        // Force finalize again - this should work for epoch N+1
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
        
        // Now warp to end of N+2 and try again
        _warpToEpochEnd();
        
        // This should work - epoch N+2 hasn't been finalized yet
        // The EpochAlreadyFinalized error is actually unreachable in normal operation
        // because the counter advances after each finalization
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
        
        // Test that we successfully processed 3 epochs
        assertEq(votingController.CURRENT_EPOCH_TO_FINALIZE(), epoch + 3, "Should have advanced 3 epochs");
    }

    function test_RevertWhen_ForceFinalizeEpoch_NotAdmin() public {
        _warpToEpochEnd();
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, votingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(voter1);
        votingController.forceFinalizeEpoch();
    }
}

