// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title VotingController_Pools_Test
 * @notice Tests for pool creation and removal functionality
 */
contract VotingController_Pools_Test is VotingControllerHarness {

    // ═══════════════════════════════════════════════════════════════════
    // createPools: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_CreatePools_SinglePool() public {
        GlobalCountersSnapshot memory before = captureGlobalCounters();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.PoolsCreated(getCurrentEpochNumber(), 1, 1, 1);
        
        _createPools(1);
        
        GlobalCountersSnapshot memory after_ = captureGlobalCounters();
        
        assertEq(after_.totalPoolsCreated, before.totalPoolsCreated + 1, "TOTAL_POOLS_CREATED should increment by 1");
        assertEq(after_.totalActivePools, before.totalActivePools + 1, "TOTAL_ACTIVE_POOLS should increment by 1");
        
        PoolSnapshot memory pool = capturePoolState(1);
        assertTrue(pool.isActive, "Pool 1 should be active");
    }

    function test_CreatePools_MultiplePools() public {
        GlobalCountersSnapshot memory before = captureGlobalCounters();
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.PoolsCreated(getCurrentEpochNumber(), 1, 5, 5);
        
        _createPools(5);
        
        GlobalCountersSnapshot memory after_ = captureGlobalCounters();
        
        assertEq(after_.totalPoolsCreated, before.totalPoolsCreated + 5, "TOTAL_POOLS_CREATED should increment by 5");
        assertEq(after_.totalActivePools, before.totalActivePools + 5, "TOTAL_ACTIVE_POOLS should increment by 5");
        
        for (uint128 i = 1; i <= 5; ++i) {
            PoolSnapshot memory pool = capturePoolState(i);
            assertTrue(pool.isActive, "Pool should be active");
        }
    }

    function test_CreatePools_MaxCount() public {
        _createPools(10);
        
        assertEq(votingController.TOTAL_POOLS_CREATED(), 10, "Should create 10 pools");
        assertEq(votingController.TOTAL_ACTIVE_POOLS(), 10, "All 10 pools should be active");
    }

    function test_CreatePools_SequentialCreation() public {
        _createPools(3);
        _createPools(2);
        
        assertEq(votingController.TOTAL_POOLS_CREATED(), 5, "Total pools should be 5");
        assertEq(votingController.TOTAL_ACTIVE_POOLS(), 5, "All 5 pools should be active");
        
        // Check pool IDs are sequential
        for (uint128 i = 1; i <= 5; ++i) {
            assertTrue(capturePoolState(i).isActive, "Pool should be active");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // createPools: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_CreatePools_ZeroCount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(votingControllerAdmin);
        votingController.createPools(0);
    }

    function test_RevertWhen_CreatePools_ExceedsMaxCount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(votingControllerAdmin);
        votingController.createPools(11);
    }

    function test_RevertWhen_CreatePools_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.createPools(1);
    }

    function test_RevertWhen_CreatePools_Paused() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(votingControllerAdmin);
        votingController.createPools(1);
    }

    function test_RevertWhen_CreatePools_DuringEndOfEpochOps() public {
        _createPools(1);
        
        // Set up votes so epoch can be ended
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(100 ether));
        
        // Move to epoch end and trigger endEpoch
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        // After endEpoch, we're past epoch end so getCurrentEpochNumber() returns next epoch.
        // The next epoch is in Voting state, but the *previous* epoch (just ended) is not finalized.
        // Contract checks previous epoch finalization first, so it throws EpochNotFinalized
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(votingControllerAdmin);
        votingController.createPools(1);
    }

    function test_RevertWhen_CreatePools_PreviousEpochNotFinalized() public {
        // Warp to next epoch without finalizing current
        uint128 epoch = getCurrentEpochNumber();
        _warpToEpoch(epoch + 2);
        
        // Previous epoch (epoch+1) is not finalized
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(votingControllerAdmin);
        votingController.createPools(1);
    }

    // ═══════════════════════════════════════════════════════════════════
    // removePools: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RemovePools_SinglePool() public {
        _createPools(3);
        
        GlobalCountersSnapshot memory before = captureGlobalCounters();
        
        uint128[] memory poolsToRemove = _toArray(2);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.PoolsRemoved(getCurrentEpochNumber(), poolsToRemove);
        
        vm.prank(votingControllerAdmin);
        votingController.removePools(poolsToRemove);
        
        GlobalCountersSnapshot memory after_ = captureGlobalCounters();
        
        assertEq(after_.totalPoolsCreated, before.totalPoolsCreated, "TOTAL_POOLS_CREATED should not change");
        assertEq(after_.totalActivePools, before.totalActivePools - 1, "TOTAL_ACTIVE_POOLS should decrement by 1");
        
        assertFalse(capturePoolState(2).isActive, "Pool 2 should be inactive");
        assertTrue(capturePoolState(1).isActive, "Pool 1 should still be active");
        assertTrue(capturePoolState(3).isActive, "Pool 3 should still be active");
    }

    function test_RemovePools_MultiplePools() public {
        _createPools(5);
        
        uint128[] memory poolsToRemove = new uint128[](3);
        poolsToRemove[0] = 1;
        poolsToRemove[1] = 3;
        poolsToRemove[2] = 5;
        
        vm.prank(votingControllerAdmin);
        votingController.removePools(poolsToRemove);
        
        assertEq(votingController.TOTAL_ACTIVE_POOLS(), 2, "Should have 2 active pools remaining");
        
        assertFalse(capturePoolState(1).isActive, "Pool 1 should be inactive");
        assertTrue(capturePoolState(2).isActive, "Pool 2 should still be active");
        assertFalse(capturePoolState(3).isActive, "Pool 3 should be inactive");
        assertTrue(capturePoolState(4).isActive, "Pool 4 should still be active");
        assertFalse(capturePoolState(5).isActive, "Pool 5 should be inactive");
    }

    // ═══════════════════════════════════════════════════════════════════
    // removePools: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_RemovePools_EmptyArray() public {
        uint128[] memory emptyArray = new uint128[](0);
        
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(votingControllerAdmin);
        votingController.removePools(emptyArray);
    }

    function test_RevertWhen_RemovePools_PoolNotActive() public {
        _createPools(2);
        
        // Remove pool 1
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
        
        // Try to remove pool 1 again
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
    }

    function test_RevertWhen_RemovePools_PoolDoesNotExist() public {
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(999));
    }

    function test_RevertWhen_RemovePools_Unauthorized() public {
        _createPools(1);
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.removePools(_toArray(1));
    }

    function test_RevertWhen_RemovePools_Paused() public {
        _createPools(1);
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
    }

    function test_RevertWhen_RemovePools_DuringEndOfEpochOps() public {
        _createPools(2);
        
        // Set up votes so epoch can be ended
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(100 ether));
        
        // Move to epoch end and trigger endEpoch
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        // After endEpoch, we're past epoch end so getCurrentEpochNumber() returns next epoch.
        // The next epoch is in Voting state, but the *previous* epoch (just ended) is not finalized.
        // Contract checks previous epoch finalization first, so it throws EpochNotFinalized
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
    }

    function test_RevertWhen_RemovePools_PreviousEpochNotFinalized() public {
        _createPools(1);
        
        // Warp to next epoch without finalizing current
        uint128 epoch = getCurrentEpochNumber();
        _warpToEpoch(epoch + 2);
        
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Pool State Persistence
    // ═══════════════════════════════════════════════════════════════════

    function test_Pool_RetainsVotesAfterRemoval() public {
        _createPools(1);
        uint128 epoch = getCurrentEpochNumber();
        
        // Set up votes
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        PoolSnapshot memory beforeRemoval = capturePoolState(1);
        assertEq(beforeRemoval.totalVotes, 500 ether, "Pool should have votes");
        
        // Remove pool
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
        
        // Pool state should retain votes even when inactive
        PoolSnapshot memory afterRemoval = capturePoolState(1);
        assertFalse(afterRemoval.isActive, "Pool should be inactive");
        assertEq(afterRemoval.totalVotes, 500 ether, "Pool should retain votes");
    }
}

