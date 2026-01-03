// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IntegrationTestHarness} from "./IntegrationTestHarness.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {Events} from "../../../src/libraries/Events.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/**
 * @title E2E_EdgeCases_Test
 * @notice End-to-end integration tests for boundary conditions and edge cases
 * @dev Tests epoch boundaries, minimum/maximum values, concurrent operations
 */
contract E2E_EdgeCases_Test is IntegrationTestHarness {

    function setUp() public override {
        super.setUp();
        // Create 5 pools for testing
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Epoch Boundary - Vote 1 Second Before Epoch End
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_EpochBoundary_VoteAtEdge() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Warp to 1 second before epoch end
        uint128 epochEnd = getCurrentEpochEnd();
        vm.warp(epochEnd - 1);

        // Vote should still use current epoch
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Vote Recorded in Current Epoch
        // ═══════════════════════════════════════════════════════════════════
        
        UserAccountSnapshot memory userAccount = captureUserAccount(currentEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, votingPower, "Votes recorded in current epoch");

        PoolEpochSnapshot memory poolEpoch = capturePoolEpochState(currentEpoch, 1);
        assertEq(poolEpoch.totalVotes, votingPower, "Pool epoch votes recorded");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Epoch Boundary - Vote Just After Transition
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_EpochBoundary_VoteJustAfter() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        // Finalize current epoch
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now we're in next epoch
        uint128 nextEpoch = getCurrentEpochNumber();
        assertTrue(nextEpoch == currentEpoch + 1, "Should be next epoch");

        // Vote in new epoch
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, nextEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Vote Recorded in New Epoch
        // ═══════════════════════════════════════════════════════════════════
        
        UserAccountSnapshot memory userAccount = captureUserAccount(nextEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, votingPower, "Votes recorded in new epoch");

        // Old epoch should have no votes from this user
        UserAccountSnapshot memory oldAccount = captureUserAccount(currentEpoch, voter1);
        assertEq(oldAccount.totalVotesSpent, 0, "No votes in old epoch");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Minimum Lock Amount
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MinimumLockAmount() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        
        // Get minimum lock amount from Constants
        uint128 minLockAmount = Constants.MIN_LOCK_AMOUNT;

        // Fund user with minimum amount
        _fundUserWithMoca(voter1, minLockAmount);

        // Create lock with minimum MOCA only
        vm.prank(voter1);
        bytes32 lockId = veMoca.createLock{value: minLockAmount}(expiry, 0);

        // Verify lock created successfully
        LockSnapshot memory lock = captureLock(lockId);
        assertEq(lock.owner, voter1, "Lock owner correct");
        assertEq(lock.moca, minLockAmount, "Lock amount = minimum");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Voting Power Works with Minimum
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        assertTrue(votingPower > 0, "Minimum lock should have voting power");

        // Should be able to vote
        _vote(voter1, _toArray(1), _toArray(votingPower));

        UserAccountSnapshot memory userAccount = captureUserAccount(currentEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, votingPower, "Votes recorded with minimum");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Minimum Lock Duration
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MinimumLockDuration() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // Minimum duration = 2 epochs ahead (MIN_LOCK_DURATION)
        // MIN_LOCK_DURATION = 28 days = 2 epochs
        uint128 minExpiry = getEpochEndTimestamp(currentEpoch + 2);

        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);

        // Create lock with minimum duration
        bytes32 lockId = _createLock(voter1, 100 ether, 100 ether, minExpiry);

        // Verify lock created
        LockSnapshot memory lock = captureLock(lockId);
        assertEq(lock.expiry, minExpiry, "Expiry = minimum duration");

        // ═══════════════════════════════════════════════════════════════════
        // Verify VP Calculated Correctly for Minimum Duration
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 vpNow = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 expectedVP = calculateVotingPowerAtEpochEnd(100 ether, 100 ether, minExpiry, currentEpoch);
        
        assertEq(vpNow, expectedVP, "VP matches formula for minimum duration");
        assertTrue(vpNow > 0, "Should have VP with minimum duration");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Maximum Lock Duration
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MaximumLockDuration() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // Maximum duration = MAX_LOCK_DURATION from now
        // We need the last epoch end that fits within block.timestamp + MAX_LOCK_DURATION
        uint128 maxTimestamp = uint128(block.timestamp) + MAX_LOCK_DURATION;
        // Get epoch start and add duration to get epoch end, but ensure it doesn't exceed max
        uint128 epochStart = (maxTimestamp / EPOCH_DURATION) * EPOCH_DURATION;
        uint128 maxExpiry = epochStart; // Use epoch start (which is a valid epoch boundary)
        
        // Ensure expiry doesn't exceed max lock duration
        if (maxExpiry > uint128(block.timestamp) + MAX_LOCK_DURATION) {
            maxExpiry = epochStart - EPOCH_DURATION; // Go back one epoch
        }

        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);

        // Create lock with maximum duration
        bytes32 lockId = _createLock(voter1, 100 ether, 100 ether, maxExpiry);

        // Verify lock created
        LockSnapshot memory lock = captureLock(lockId);
        assertEq(lock.expiry, maxExpiry, "Expiry = maximum duration");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Maximum VP Achieved
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 vpNow = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        assertTrue(vpNow > 0, "Should have maximum VP");

        // VP should be close to principal (slope * time remaining ≈ principal)
        uint128 principal = 200 ether;
        // At max lock, VP at epoch end should be significant portion of principal
        assertTrue(vpNow > principal / 2, "VP should be significant for max lock");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Concurrent Voters Same Pool
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ConcurrentVoters_SamePool() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create many voters
        address[] memory voters = new address[](10);
        uint128[] memory vps = new uint128[](10);

        for (uint256 i = 0; i < 10; ++i) {
            voters[i] = makeAddr(string(abi.encodePacked("voter_", i)));
            _fundUserWithMoca(voters[i], 50 ether);
            _fundUserWithEsMoca(voters[i], 50 ether);
            _createLock(voters[i], 50 ether, 50 ether, expiry);
            vps[i] = veMoca.balanceAtEpochEnd(voters[i], currentEpoch, false);
        }

        // Capture pool state before
        PoolSnapshot memory beforePool = capturePoolState(1);

        // All voters vote for same pool
        uint128 expectedTotal = 0;
        for (uint256 i = 0; i < 10; ++i) {
            _vote(voters[i], _toArray(1), _toArray(vps[i]));
            expectedTotal += vps[i];
        }

        // Capture pool state after
        PoolSnapshot memory afterPool = capturePoolState(1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify No Race Conditions - Totals Match Exactly
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool.totalVotes, beforePool.totalVotes + expectedTotal, "Pool total = sum of all votes");

        // Verify each user's votes recorded correctly
        for (uint256 i = 0; i < 10; ++i) {
            UserAccountSnapshot memory userAccount = captureUserAccount(currentEpoch, voters[i]);
            assertEq(userAccount.totalVotesSpent, vps[i], string(abi.encodePacked("Voter ", i, " votes exact")));
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Pool Removal Mid-Epoch
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_PoolRemoval_MidEpoch() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock and vote for pool 5
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(5), _toArray(votingPower));

        // Capture pool state with votes
        PoolEpochSnapshot memory poolBefore = capturePoolEpochState(currentEpoch, 5);
        assertEq(poolBefore.totalVotes, votingPower, "Votes recorded");

        // Remove pool mid-epoch
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(5));

        // ═══════════════════════════════════════════════════════════════════
        // Verify: Votes Stay, Migration Out Allowed
        // ═══════════════════════════════════════════════════════════════════
        
        PoolSnapshot memory poolStateAfterRemoval = capturePoolState(5);
        assertFalse(poolStateAfterRemoval.isActive, "Pool should be inactive");
        assertEq(poolStateAfterRemoval.totalVotes, votingPower, "Votes remain in pool");

        // Migration from removed pool to active pool should work
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(5), _toArray(1), _toArray(votingPower), false);

        // Verify migration
        PoolSnapshot memory pool1After = capturePoolState(1);
        PoolSnapshot memory pool5After = capturePoolState(5);
        assertEq(pool1After.totalVotes, votingPower, "Votes migrated to active pool");
        assertEq(pool5After.totalVotes, 0, "No votes in removed pool");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Unregister then Re-register
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegateUnregister_ReRegister() public {
        uint128 initialFee = 1000; // 10%
        uint128 newFee = 2000; // 20%

        // Register delegate
        _registerDelegate(delegate1, initialFee);

        // Verify registered
        DelegateSnapshot memory state1 = captureDelegateState(delegate1);
        assertTrue(state1.isRegistered, "Should be registered");
        assertEq(state1.currentFeePct, initialFee, "Initial fee set");

        // Unregister
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();

        // Verify unregistered
        DelegateSnapshot memory state2 = captureDelegateState(delegate1);
        assertFalse(state2.isRegistered, "Should be unregistered");
        assertEq(state2.currentFeePct, 0, "Fee cleared");

        // Re-register with new fee
        _registerDelegate(delegate1, newFee);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Fresh State with New Fee
        // ═══════════════════════════════════════════════════════════════════
        
        DelegateSnapshot memory state3 = captureDelegateState(delegate1);
        assertTrue(state3.isRegistered, "Should be re-registered");
        assertEq(state3.currentFeePct, newFee, "New fee set");
        assertEq(state3.nextFeePct, 0, "No pending fee");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Zero Delegated VP Claim Reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ZeroDelegatedVP_ClaimReverts() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Register delegate but no one delegates to them
        _registerDelegate(delegate1, 1000);

        // Create personal lock (not delegated)
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        // Vote personally
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Finalize
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(uint128(0)));

        // ═══════════════════════════════════════════════════════════════════
        // Verify: Claim with Delegate Who Didn't Vote Reverts
        // ═══════════════════════════════════════════════════════════════════
        
        // delegate1 never voted (no one delegated to them)
        // The first check is if the delegate has voted, so we get ZeroVotes error
        vm.expectRevert(Errors.ZeroVotes.selector);
        vm.prank(voter1);
        votingController.claimDelegatedRewards(currentEpoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Partial Pool Processing
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_PartialPoolProcessing() public {
        // Create more pools
        _createPools(10); // Now total 15 pools

        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock and vote for multiple pools
        _fundUserWithMoca(voter1, 1500 ether);
        _fundUserWithEsMoca(voter1, 1500 ether);
        _createLock(voter1, 1500 ether, 1500 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 votesPerPool = votingPower / 15;

        // Vote for all 15 pools
        for (uint128 i = 1; i <= 15; ++i) {
            _vote(voter1, _toArray(i), _toArray(votesPerPool));
        }

        // Warp past epoch end
        _warpToEpochEnd();

        // End epoch
        vm.prank(cronJob);
        votingController.endEpoch();

        // Process verifier checks
        address[] memory emptyVerifiers = new address[](0);
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, emptyVerifiers);

        // Process pools in batches
        uint128[] memory batch1Pools = new uint128[](5);
        uint128[] memory batch1Rewards = new uint128[](5);
        uint128[] memory batch1Subsidies = new uint128[](5);
        for (uint128 i = 0; i < 5; ++i) {
            batch1Pools[i] = i + 1;
            batch1Rewards[i] = 10 ether;
            batch1Subsidies[i] = 0;
        }

        // Mint esMoca for rewards
        vm.deal(votingControllerTreasury, 150 ether);
        vm.prank(votingControllerTreasury);
        esMoca.escrowMoca{value: 150 ether}();

        // Process first batch
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(batch1Pools, batch1Rewards, batch1Subsidies);

        // Verify partial processing
        EpochSnapshot memory epochMid = captureEpochState(currentEpoch);
        assertEq(epochMid.poolsProcessed, 5, "5 pools processed");
        assertTrue(epochMid.state == DataTypes.EpochState.Verified, "Still in Verified state");

        // Process remaining pools
        uint128[] memory batch2Pools = new uint128[](10);
        uint128[] memory batch2Rewards = new uint128[](10);
        uint128[] memory batch2Subsidies = new uint128[](10);
        for (uint128 i = 0; i < 10; ++i) {
            batch2Pools[i] = i + 6;
            batch2Rewards[i] = 10 ether;
            batch2Subsidies[i] = 0;
        }

        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(batch2Pools, batch2Rewards, batch2Subsidies);

        // ═══════════════════════════════════════════════════════════════════
        // Verify State Consistent After Batched Processing
        // ═══════════════════════════════════════════════════════════════════
        
        EpochSnapshot memory epochAfter = captureEpochState(currentEpoch);
        assertEq(epochAfter.poolsProcessed, 15, "All 15 pools processed");

        // Finalize
        vm.prank(cronJob);
        votingController.finalizeEpoch();

        // Verify can claim from all pools
        for (uint128 i = 1; i <= 15; ++i) {
            vm.prank(voter1);
            votingController.claimPersonalRewards(currentEpoch, _toArray(i));
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Unclaimed Withdrawal After Delay
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_UnclaimedWithdrawal_AfterDelay() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 10);

        // Create lock and vote
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        uint128 rewardsAllocated = 100 ether;
        _finalizeEpoch(_toArray(1), _toArray(rewardsAllocated), _toArray(uint128(0)));

        // User doesn't claim - warp past UNCLAIMED_DELAY_EPOCHS
        for (uint128 i = 0; i < unclaimedDelayEpochs + 1; ++i) {
            _warpToEpoch(currentEpoch + i + 1);
            if (i < unclaimedDelayEpochs) {
                // Finalize each epoch with no rewards to advance
                _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));
            }
        }

        // Now unclaimed can be withdrawn
        uint128 epochToWithdraw = currentEpoch;
        EpochSnapshot memory epochBeforeWithdraw = captureEpochState(epochToWithdraw);

        // Capture treasury balance before
        uint256 treasuryBefore = esMoca.balanceOf(votingControllerTreasury);

        // Withdraw unclaimed rewards
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epochToWithdraw);

        // Capture after
        uint256 treasuryAfter = esMoca.balanceOf(votingControllerTreasury);
        EpochSnapshot memory epochAfterWithdraw = captureEpochState(epochToWithdraw);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Unclaimed Amount Sent to Treasury
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 unclaimedAmount = rewardsAllocated - epochBeforeWithdraw.totalRewardsClaimed;
        assertEq(treasuryAfter, treasuryBefore + unclaimedAmount, "Treasury received unclaimed");
        assertEq(epochAfterWithdraw.totalRewardsWithdrawn, unclaimedAmount, "Withdrawn counter updated");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote for Non-existent Pool Reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_NonExistentPool_Reverts() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Pool 999 doesn't exist
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(999), _toArray(votingPower), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote with Zero Amount Reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_ZeroAmount_Reverts() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        // Vote with zero amount
        vm.expectRevert(Errors.ZeroVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(0), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: User Without Lock Has No Voting Power
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_UserWithoutLock_NoVotingPower() public {
        uint128 currentEpoch = getCurrentEpochNumber();

        // User has no lock
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        assertEq(votingPower, 0, "User without lock has no VP");

        // Attempt to vote should revert
        vm.expectRevert(Errors.NoAvailableVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(1), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Claim Before Epoch Finalized Reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimBeforeFinalized_Reverts() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock and vote
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Attempt to claim before finalization
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));
    }
}

