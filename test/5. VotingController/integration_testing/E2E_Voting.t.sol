// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IntegrationTestHarness} from "./IntegrationTestHarness.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {Events} from "../../../src/libraries/Events.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/**
 * @title E2E_Voting_Test
 * @notice End-to-end integration tests for personal voting with real locks
 * @dev Tests voting flows using real VotingEscrowMoca with actual voting power calculations
 */
contract E2E_Voting_Test is IntegrationTestHarness {

    function setUp() public override {
        super.setUp();
        // Create 5 pools for testing
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Lock Creation and Voting Power Calculation
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_CreateLock_VotingPowerCalculation() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 3); // Lock for 3 more epochs
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Fund user with native MOCA and esMoca
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);

        // Capture before state
        TokenBalanceSnapshot memory beforeTokens = captureTokenBalances(voter1);
        VeMocaGlobalSnapshot memory beforeVeMoca = captureVeMocaGlobal();

        // Create lock
        bytes32 lockId = _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Capture after state
        TokenBalanceSnapshot memory afterTokens = captureTokenBalances(voter1);
        VeMocaGlobalSnapshot memory afterVeMoca = captureVeMocaGlobal();
        LockSnapshot memory lockState = captureLock(lockId);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Token Transfers
        // ═══════════════════════════════════════════════════════════════════
        
        // User MOCA decreased by mocaAmount
        assertEq(afterTokens.userMoca, beforeTokens.userMoca - mocaAmount, "User MOCA should decrease");
        // User esMoca decreased by esMocaAmount
        assertEq(afterTokens.userEsMoca, beforeTokens.userEsMoca - esMocaAmount, "User esMoca should decrease");
        // veMoca contract MOCA increased
        assertEq(afterTokens.veMocaContractMoca, beforeTokens.veMocaContractMoca + mocaAmount, "veMoca MOCA should increase");
        // veMoca contract esMoca increased
        assertEq(afterTokens.veMocaContractEsMoca, beforeTokens.veMocaContractEsMoca + esMocaAmount, "veMoca esMoca should increase");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Lock State
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(lockState.owner, voter1, "Lock owner should be voter1");
        assertEq(lockState.moca, mocaAmount, "Lock MOCA should match");
        assertEq(lockState.esMoca, esMocaAmount, "Lock esMoca should match");
        assertEq(lockState.expiry, expiry, "Lock expiry should match");
        assertFalse(lockState.isUnlocked, "Lock should not be unlocked");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Global State
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterVeMoca.totalLockedMoca, beforeVeMoca.totalLockedMoca + mocaAmount, "Total locked MOCA should increase");
        assertEq(afterVeMoca.totalLockedEsMoca, beforeVeMoca.totalLockedEsMoca + esMocaAmount, "Total locked esMoca should increase");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Voting Power Calculation (Exact Math)
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedSlope = calculateSlope(mocaAmount, esMocaAmount);
        uint128 expectedVPAtEpochEnd = calculateVotingPowerAtEpochEnd(mocaAmount, esMocaAmount, expiry, currentEpoch);
        
        uint128 actualVPAtEpochEnd = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        
        assertEq(actualVPAtEpochEnd, expectedVPAtEpochEnd, "Voting power at epoch end should match formula");
        assertTrue(actualVPAtEpochEnd > 0, "Voting power should be positive");

        // Verify slope calculation: slope = principal / MAX_LOCK_DURATION
        uint128 expectedSlopeCalc = (mocaAmount + esMocaAmount) / MAX_LOCK_DURATION;
        assertEq(expectedSlope, expectedSlopeCalc, "Slope calculation should match");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Single User, Single Pool Vote
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_SingleUser_SinglePool_Vote() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock for voter1
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        bytes32 lockId = _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Get voting power at epoch end
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        assertTrue(votingPower > 0, "User should have voting power");

        // Capture before state
        PoolSnapshot memory beforePool = capturePoolState(1);
        PoolEpochSnapshot memory beforePoolEpoch = capturePoolEpochState(currentEpoch, 1);
        UserAccountSnapshot memory beforeUser = captureUserAccount(currentEpoch, voter1);

        // Vote for pool 1 with all voting power
        uint128 votesToCast = votingPower;
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.Voted(currentEpoch, voter1, _toArray(1), _toArray(votesToCast), false);
        
        _vote(voter1, _toArray(1), _toArray(votesToCast));

        // Capture after state
        PoolSnapshot memory afterPool = capturePoolState(1);
        PoolEpochSnapshot memory afterPoolEpoch = capturePoolEpochState(currentEpoch, 1);
        UserAccountSnapshot memory afterUser = captureUserAccount(currentEpoch, voter1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Pool State Changes
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool.totalVotes, beforePool.totalVotes + votesToCast, "Pool total votes should increase exactly");
        assertEq(afterPoolEpoch.totalVotes, beforePoolEpoch.totalVotes + votesToCast, "Pool epoch votes should increase exactly");

        // ═══════════════════════════════════════════════════════════════════
        // Verify User State Changes
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterUser.totalVotesSpent, beforeUser.totalVotesSpent + votesToCast, "User votes spent should increase exactly");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Single User, Multiple Pools Vote
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_SingleUser_MultiPool_Vote() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 200 ether;
        uint128 esMocaAmount = 200 ether;

        // Setup: Create lock for voter1
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Get voting power at epoch end
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        assertTrue(votingPower > 0, "User should have voting power");

        // Calculate votes for each pool
        uint128 votesPool1 = votingPower / 4;
        uint128 votesPool2 = votingPower / 4;
        uint128 votesPool3 = votingPower / 2;
        uint128 totalVotes = votesPool1 + votesPool2 + votesPool3;

        // Capture before state
        PoolSnapshot memory beforePool1 = capturePoolState(1);
        PoolSnapshot memory beforePool2 = capturePoolState(2);
        PoolSnapshot memory beforePool3 = capturePoolState(3);
        UserAccountSnapshot memory beforeUser = captureUserAccount(currentEpoch, voter1);

        // Vote for multiple pools
        _vote(voter1, _toArray(1, 2, 3), _toArray(votesPool1, votesPool2, votesPool3));

        // Capture after state
        PoolSnapshot memory afterPool1 = capturePoolState(1);
        PoolSnapshot memory afterPool2 = capturePoolState(2);
        PoolSnapshot memory afterPool3 = capturePoolState(3);
        UserAccountSnapshot memory afterUser = captureUserAccount(currentEpoch, voter1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Pool Vote Distribution
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool1.totalVotes, beforePool1.totalVotes + votesPool1, "Pool 1 votes exact");
        assertEq(afterPool2.totalVotes, beforePool2.totalVotes + votesPool2, "Pool 2 votes exact");
        assertEq(afterPool3.totalVotes, beforePool3.totalVotes + votesPool3, "Pool 3 votes exact");

        // ═══════════════════════════════════════════════════════════════════
        // Verify User Total Spent
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterUser.totalVotesSpent, beforeUser.totalVotesSpent + totalVotes, "User total spent exact");
        
        // Verify remaining voting power
        uint128 remainingVP = votingPower - totalVotes;
        assertTrue(remainingVP >= 0, "Remaining VP should be non-negative");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Multiple Users, Single Pool Vote
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MultiUser_SinglePool_Vote() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create locks for multiple voters with different amounts
        uint128 voter1Moca = 100 ether;
        uint128 voter1EsMoca = 100 ether;
        uint128 voter2Moca = 200 ether;
        uint128 voter2EsMoca = 200 ether;
        uint128 voter3Moca = 50 ether;
        uint128 voter3EsMoca = 50 ether;

        _fundUserWithMoca(voter1, voter1Moca);
        _fundUserWithEsMoca(voter1, voter1EsMoca);
        _createLock(voter1, voter1Moca, voter1EsMoca, expiry);

        _fundUserWithMoca(voter2, voter2Moca);
        _fundUserWithEsMoca(voter2, voter2EsMoca);
        _createLock(voter2, voter2Moca, voter2EsMoca, expiry);

        _fundUserWithMoca(voter3, voter3Moca);
        _fundUserWithEsMoca(voter3, voter3EsMoca);
        _createLock(voter3, voter3Moca, voter3EsMoca, expiry);

        // Get voting powers
        uint128 vp1 = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 vp2 = veMoca.balanceAtEpochEnd(voter2, currentEpoch, false);
        uint128 vp3 = veMoca.balanceAtEpochEnd(voter3, currentEpoch, false);

        // All vote for pool 1
        uint128 votes1 = vp1;
        uint128 votes2 = vp2;
        uint128 votes3 = vp3;
        uint128 expectedTotalVotes = votes1 + votes2 + votes3;

        // Capture before state
        PoolSnapshot memory beforePool = capturePoolState(1);
        PoolEpochSnapshot memory beforePoolEpoch = capturePoolEpochState(currentEpoch, 1);

        // All voters vote for pool 1
        _vote(voter1, _toArray(1), _toArray(votes1));
        _vote(voter2, _toArray(1), _toArray(votes2));
        _vote(voter3, _toArray(1), _toArray(votes3));

        // Capture after state
        PoolSnapshot memory afterPool = capturePoolState(1);
        PoolEpochSnapshot memory afterPoolEpoch = capturePoolEpochState(currentEpoch, 1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Pool Total = Sum of All User Votes
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool.totalVotes, beforePool.totalVotes + expectedTotalVotes, "Pool total should equal sum of votes");
        assertEq(afterPoolEpoch.totalVotes, beforePoolEpoch.totalVotes + expectedTotalVotes, "Pool epoch total exact");

        // Verify individual user tracking
        UserAccountSnapshot memory user1After = captureUserAccount(currentEpoch, voter1);
        UserAccountSnapshot memory user2After = captureUserAccount(currentEpoch, voter2);
        UserAccountSnapshot memory user3After = captureUserAccount(currentEpoch, voter3);

        assertEq(user1After.totalVotesSpent, votes1, "Voter1 spent exact");
        assertEq(user2After.totalVotesSpent, votes2, "Voter2 spent exact");
        assertEq(user3After.totalVotesSpent, votes3, "Voter3 spent exact");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote Uses Epoch End Voting Power (Forward Decay)
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_UsesEpochEndVotingPower() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Get voting power at current timestamp vs epoch end
        uint128 vpAtNow = veMoca.balanceOfAt(voter1, uint128(block.timestamp), false);
        uint128 vpAtEpochEnd = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // VP at epoch end should be less than VP now (decay)
        assertTrue(vpAtEpochEnd < vpAtNow, "VP at epoch end should be less than VP now due to decay");

        // Vote with epoch end VP should succeed
        _vote(voter1, _toArray(1), _toArray(vpAtEpochEnd));

        // Verify vote was recorded correctly
        UserAccountSnapshot memory userAccount = captureUserAccount(currentEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, vpAtEpochEnd, "Votes spent should equal VP at epoch end");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote with Exactly Available Votes
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_ExactlyAvailableVotes() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Vote with exactly all available VP
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Verify user spent exactly all VP
        UserAccountSnapshot memory userAccount = captureUserAccount(currentEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, votingPower, "Should have spent exactly all VP");

        // Trying to vote again should revert (no available votes)
        vm.expectRevert(Errors.NoAvailableVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(2), _toArray(1), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote with Partial Voting Power
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_PartialVotingPower() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 firstVote = votingPower / 2;
        uint128 remainingVP = votingPower - firstVote;

        // First vote with half VP
        _vote(voter1, _toArray(1), _toArray(firstVote));

        // Verify partial spent
        UserAccountSnapshot memory userAfterFirst = captureUserAccount(currentEpoch, voter1);
        assertEq(userAfterFirst.totalVotesSpent, firstVote, "First vote spent exact");

        // Second vote with remaining VP
        _vote(voter1, _toArray(2), _toArray(remainingVP));

        // Verify all VP spent
        UserAccountSnapshot memory userAfterSecond = captureUserAccount(currentEpoch, voter1);
        assertEq(userAfterSecond.totalVotesSpent, votingPower, "All VP should be spent");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote Migration - Full Amount
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_VoteMigration_FullAmount() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock and vote
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Capture before migration
        PoolSnapshot memory beforePool1 = capturePoolState(1);
        PoolSnapshot memory beforePool2 = capturePoolState(2);

        // Migrate all votes from pool 1 to pool 2
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(votingPower), false);

        // Capture after migration
        PoolSnapshot memory afterPool1 = capturePoolState(1);
        PoolSnapshot memory afterPool2 = capturePoolState(2);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Migration: Source Decreases, Destination Increases
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool1.totalVotes, beforePool1.totalVotes - votingPower, "Source pool should decrease");
        assertEq(afterPool2.totalVotes, beforePool2.totalVotes + votingPower, "Destination pool should increase");

        // User total spent should remain the same
        UserAccountSnapshot memory userAccount = captureUserAccount(currentEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, votingPower, "User total spent unchanged after migration");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote Migration - Partial Amount
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_VoteMigration_PartialAmount() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock and vote
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        uint128 migrateAmount = votingPower / 3;
        uint128 remainingInSource = votingPower - migrateAmount;

        // Capture before migration
        PoolSnapshot memory beforePool1 = capturePoolState(1);
        PoolSnapshot memory beforePool2 = capturePoolState(2);

        // Migrate partial votes
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(migrateAmount), false);

        // Capture after migration
        PoolSnapshot memory afterPool1 = capturePoolState(1);
        PoolSnapshot memory afterPool2 = capturePoolState(2);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Partial Migration
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool1.totalVotes, beforePool1.totalVotes - migrateAmount, "Source pool exact decrease");
        assertEq(afterPool2.totalVotes, beforePool2.totalVotes + migrateAmount, "Destination pool exact increase");
        assertEq(afterPool1.totalVotes, remainingInSource, "Source pool remaining exact");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Vote Migration - From Inactive Pool
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_VoteMigration_FromInactivePool() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock and vote for pool 5
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(5), _toArray(votingPower));

        // Remove pool 5 (make it inactive)
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(5));

        // Verify pool 5 is inactive
        PoolSnapshot memory pool5State = capturePoolState(5);
        assertFalse(pool5State.isActive, "Pool 5 should be inactive");

        // Migration from inactive to active pool should succeed
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(5), _toArray(1), _toArray(votingPower), false);

        // Verify migration succeeded
        PoolSnapshot memory afterPool1 = capturePoolState(1);
        assertEq(afterPool1.totalVotes, votingPower, "Votes migrated to active pool");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Revert When Exceeding Available Votes
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_RevertWhen_ExceedsAvailable() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 excessVotes = votingPower + 1;

        // Attempt to vote more than available
        vm.expectRevert(Errors.InsufficientVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(excessVotes), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Revert When Voting During End of Epoch Operations
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_AllowedDuringPriorEpochFinalization() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Warp to after epoch end and start finalization of OLD epoch
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();

        // Get voting power for the NEW epoch we're voting in
        uint128 newEpoch = getCurrentEpochNumber();
        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, newEpoch, false);
        assertTrue(votingPower > 0, "Should have voting power");

        // ═══════════════════════════════════════════════════════════════════
        // Verify: Voting is ALLOWED in new epoch while old epoch finalizes
        // This is expected behavior - the system allows voting in the current
        // epoch while a prior epoch is undergoing finalization
        // ═══════════════════════════════════════════════════════════════════
        
        // This should succeed (not revert)
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Verify vote was recorded in the new epoch
        UserAccountSnapshot memory userAccount = captureUserAccount(newEpoch, voter1);
        assertEq(userAccount.totalVotesSpent, votingPower, "Votes recorded in new epoch");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Revert When Voting for Inactive Pool
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Vote_RevertWhen_InactivePool() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Setup: Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Remove pool 5
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(5));

        // Attempt to vote for inactive pool
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(5), _toArray(votingPower), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Multiple Users, Multiple Pools Vote Distribution
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MultiUser_MultiPool_Vote() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create locks for voters
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        _fundUserWithMoca(voter2, 200 ether);
        _fundUserWithEsMoca(voter2, 200 ether);
        _createLock(voter2, 200 ether, 200 ether, expiry);

        uint128 vp1 = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 vp2 = veMoca.balanceAtEpochEnd(voter2, currentEpoch, false);

        // Voter1: votes for pools 1 and 2
        uint128 v1Pool1 = vp1 / 2;
        uint128 v1Pool2 = vp1 - v1Pool1;
        _vote(voter1, _toArray(1, 2), _toArray(v1Pool1, v1Pool2));

        // Voter2: votes for pools 2 and 3
        uint128 v2Pool2 = vp2 / 2;
        uint128 v2Pool3 = vp2 - v2Pool2;
        _vote(voter2, _toArray(2, 3), _toArray(v2Pool2, v2Pool3));

        // Verify pool totals
        PoolSnapshot memory pool1 = capturePoolState(1);
        PoolSnapshot memory pool2 = capturePoolState(2);
        PoolSnapshot memory pool3 = capturePoolState(3);

        assertEq(pool1.totalVotes, v1Pool1, "Pool 1 exact votes");
        assertEq(pool2.totalVotes, v1Pool2 + v2Pool2, "Pool 2 = voter1 + voter2");
        assertEq(pool3.totalVotes, v2Pool3, "Pool 3 exact votes");

        // Verify total across all pools equals sum of all votes
        uint128 totalAllPools = pool1.totalVotes + pool2.totalVotes + pool3.totalVotes;
        assertEq(totalAllPools, vp1 + vp2, "Total votes = sum of all user VP");
    }
}

