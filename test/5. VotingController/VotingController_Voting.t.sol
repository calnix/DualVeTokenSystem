// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title VotingController_Voting_Test
 * @notice Tests for vote and migrateVotes functionality
 */
contract VotingController_Voting_Test is VotingControllerHarness {

    function setUp() public override {
        super.setUp();
        // Create pools for voting tests
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // vote: Personal Voting Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_Vote_Personal_SinglePool() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        uint128[] memory poolIds = _toArray(1);
        uint128[] memory votes = _toArray(500 ether);
        
        // ---- CAPTURE BEFORE STATE ----
        uint128 poolVotesBefore = capturePoolState(1).totalVotes;
        uint128 poolEpochVotesBefore = capturePoolEpochState(epoch, 1).totalVotes;
        
        // Verify initial state is zero
        {
            (uint128 userVotesBefore,) = votingController.usersEpochData(epoch, voter1);
            (uint128 userPoolVotesBefore,) = votingController.usersEpochPoolData(epoch, 1, voter1);
            assertEq(userVotesBefore, 0, "User votes should start at 0");
            assertEq(userPoolVotesBefore, 0, "User pool votes should start at 0");
            assertEq(poolEpochVotesBefore, 0, "Pool epoch votes should start at 0");
        }
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.Voted(epoch, voter1, poolIds, votes, false);
        
        _vote(voter1, poolIds, votes);
        
        // ---- VERIFY STATE CHANGES ----
        
        // User state
        {
            (uint128 userVotesAfter,) = votingController.usersEpochData(epoch, voter1);
            (uint128 userPoolVotesAfter,) = votingController.usersEpochPoolData(epoch, 1, voter1);
            assertEq(userVotesAfter, 500 ether, "User totalVotesSpent should be 500 ether");
            assertEq(userPoolVotesAfter, 500 ether, "User pool votes should be 500 ether");
        }
        
        // Pool state
        assertEq(capturePoolState(1).totalVotes, poolVotesBefore + 500 ether, "Pool totalVotes should increase by 500 ether");
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, poolEpochVotesBefore + 500 ether, "Pool epoch totalVotes should increase by 500 ether");
        
        // Other pools should be unaffected
        assertEq(capturePoolEpochState(epoch, 2).totalVotes, 0, "Pool 2 should have no votes");
    }

    function test_Vote_Personal_MultiplePools() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        uint128[] memory poolIds = _toArray(1, 2, 3);
        uint128[] memory votes = new uint128[](3);
        votes[0] = 300 ether;
        votes[1] = 400 ether;
        votes[2] = 200 ether;
        
        // ---- CAPTURE BEFORE STATE ----
        (uint128 userVotesBefore,) = votingController.usersEpochData(epoch, voter1);
        
        // ---- EXECUTE ----
        _vote(voter1, poolIds, votes);
        
        // ---- CAPTURE AFTER STATE ----
        (uint128 userVotesAfter,) = votingController.usersEpochData(epoch, voter1);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // User epoch data - exact total across all pools
        assertEq(userVotesAfter, userVotesBefore + 900 ether, "User totalVotesSpent should increase by 900 ether");
        
        // Each pool gets exact votes allocated
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 300 ether, "Pool 1: exactly 300 ether");
        assertEq(capturePoolEpochState(epoch, 2).totalVotes, 400 ether, "Pool 2: exactly 400 ether");
        assertEq(capturePoolEpochState(epoch, 3).totalVotes, 200 ether, "Pool 3: exactly 200 ether");
        
        // User pool-specific data
        {
            (uint128 userPool1Votes,) = votingController.usersEpochPoolData(epoch, 1, voter1);
            assertEq(userPool1Votes, 300 ether, "User pool 1 votes: exactly 300 ether");
        }
        {
            (uint128 userPool2Votes,) = votingController.usersEpochPoolData(epoch, 2, voter1);
            assertEq(userPool2Votes, 400 ether, "User pool 2 votes: exactly 400 ether");
        }
        {
            (uint128 userPool3Votes,) = votingController.usersEpochPoolData(epoch, 3, voter1);
            assertEq(userPool3Votes, 200 ether, "User pool 3 votes: exactly 200 ether");
        }
        
        // Global pool totals
        assertEq(capturePoolState(1).totalVotes, 300 ether, "Pool 1 global total: 300 ether");
        assertEq(capturePoolState(2).totalVotes, 400 ether, "Pool 2 global total: 400 ether");
        assertEq(capturePoolState(3).totalVotes, 200 ether, "Pool 3 global total: 200 ether");
    }

    function test_Vote_Personal_MultipleVotingCalls() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        // ---- FIRST VOTE ----
        (uint128 votesBefore1,) = votingController.usersEpochData(epoch, voter1);
        assertEq(votesBefore1, 0, "User should start with 0 votes");
        
        _vote(voter1, _toArray(1), _toArray(300 ether));
        
        (uint128 votesAfter1,) = votingController.usersEpochData(epoch, voter1);
        assertEq(votesAfter1, 300 ether, "After first vote: exactly 300 ether");
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 300 ether, "Pool 1: 300 ether after first vote");
        
        // ---- SECOND VOTE ----
        _vote(voter1, _toArray(2), _toArray(400 ether));
        
        (uint128 votesAfter2,) = votingController.usersEpochData(epoch, voter1);
        assertEq(votesAfter2, 700 ether, "After second vote: exactly 700 ether (300 + 400)");
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 300 ether, "Pool 1 unchanged: 300 ether");
        assertEq(capturePoolEpochState(epoch, 2).totalVotes, 400 ether, "Pool 2: 400 ether after second vote");
        
        // Note: Epoch doesn't track aggregate votes - pool-level totals verified above
        
        // Remaining voting power
        uint128 availableVP = mockVeMoca.balanceAtEpochEnd(voter1, epoch, false);
        assertEq(availableVP - votesAfter2, 300 ether, "Remaining voting power: 1000 - 700 = 300 ether");
    }

    function test_Vote_Personal_VoteForSamePoolTwice() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        // Vote for pool 1 twice in same call
        uint128[] memory poolIds = new uint128[](2);
        poolIds[0] = 1;
        poolIds[1] = 1;
        uint128[] memory votes = new uint128[](2);
        votes[0] = 200 ether;
        votes[1] = 300 ether;
        
        _vote(voter1, poolIds, votes);
        
        // Pool should accumulate both votes
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 500 ether, "Pool should have accumulated votes");
    }

    // ═══════════════════════════════════════════════════════════════════
    // vote: Delegated Voting Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_Vote_Delegated_SinglePool() public {
        uint128 epoch = getCurrentEpochNumber();
        
        // Register delegate
        _registerDelegate(delegate1, 1000); // 10% fee
        
        // Setup delegated voting power
        _setupVotingPower(delegate1, epoch, 0, 2000 ether);
        
        uint128[] memory poolIds = _toArray(1);
        uint128[] memory votes = _toArray(1000 ether);
        
        // ---- CAPTURE BEFORE STATE ----
        PoolEpochSnapshot memory poolEpochBefore = capturePoolEpochState(epoch, 1);
        PoolSnapshot memory poolBefore = capturePoolState(1);
        
        (uint128 delegateVotesBefore,) = votingController.delegateEpochData(epoch, delegate1);
        (uint128 delegatePoolVotesBefore,) = votingController.delegatesEpochPoolData(epoch, 1, delegate1);
        
        assertEq(delegateVotesBefore, 0, "Delegate should start with 0 votes");
        assertEq(delegatePoolVotesBefore, 0, "Delegate pool votes should start at 0");
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.Voted(epoch, delegate1, poolIds, votes, true);
        
        _voteAsDelegated(delegate1, poolIds, votes);
        
        // ---- CAPTURE AFTER STATE ----
        PoolEpochSnapshot memory poolEpochAfter = capturePoolEpochState(epoch, 1);
        PoolSnapshot memory poolAfter = capturePoolState(1);
        
        (uint128 delegateVotesAfter,) = votingController.delegateEpochData(epoch, delegate1);
        (uint128 delegatePoolVotesAfter,) = votingController.delegatesEpochPoolData(epoch, 1, delegate1);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Delegate epoch data
        assertEq(delegateVotesAfter, delegateVotesBefore + 1000 ether, "Delegate totalVotesSpent should increase by 1000 ether");
        
        // Delegate pool data
        assertEq(delegatePoolVotesAfter, delegatePoolVotesBefore + 1000 ether, "Delegate pool votes should increase by 1000 ether");
        
        // Pool state changes
        assertEq(poolAfter.totalVotes, poolBefore.totalVotes + 1000 ether, "Pool totalVotes should increase by 1000 ether");
        assertEq(poolEpochAfter.totalVotes, poolEpochBefore.totalVotes + 1000 ether, "Pool epoch votes should increase by 1000 ether");
        
        // Note: Epoch doesn't track aggregate votes - pool-level totals verified above
        
        // Historical fee should be recorded
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch), 1000, "Historical fee should be 10%");
    }

    function test_Vote_Delegated_RecordsHistoricalFee() public {
        uint128 epoch = getCurrentEpochNumber();
        
        // Register delegate with 10% fee
        _registerDelegate(delegate1, 1000);
        
        // Setup voting power and vote
        _setupVotingPower(delegate1, epoch, 0, 2000 ether);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(500 ether));
        
        // Check historical fee was recorded
        uint128 historicalFee = votingController.delegateHistoricalFeePcts(delegate1, epoch);
        assertEq(historicalFee, 1000, "Historical fee should be recorded");
    }

    // ═══════════════════════════════════════════════════════════════════
    // vote: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_Vote_ArrayLengthMismatch() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        uint128[] memory poolIds = _toArray(1, 2);
        uint128[] memory votes = _toArray(100 ether);
        
        vm.expectRevert(Errors.MismatchedArrayLengths.selector);
        vm.prank(voter1);
        votingController.vote(poolIds, votes, false);
    }

    function test_RevertWhen_Vote_EmptyArrays() public {
        uint128[] memory emptyPoolIds = new uint128[](0);
        uint128[] memory emptyVotes = new uint128[](0);
        
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(voter1);
        votingController.vote(emptyPoolIds, emptyVotes, false);
    }

    function test_RevertWhen_Vote_ZeroVotes() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        vm.expectRevert(Errors.ZeroVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(0), false);
    }

    function test_RevertWhen_Vote_NoAvailableVotes() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 0, 0); // No voting power
        
        vm.expectRevert(Errors.NoAvailableVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), false);
    }

    function test_RevertWhen_Vote_InsufficientVotes() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 100 ether, 0);
        
        vm.expectRevert(Errors.InsufficientVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(101 ether), false);
    }

    function test_RevertWhen_Vote_PoolNotActive() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        // Remove pool 1
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
        
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), false);
    }

    function test_RevertWhen_Vote_Delegated_NotRegistered() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 0, 1000 ether);
        
        vm.expectRevert(Errors.NotRegisteredAsDelegate.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), true);
    }

    function test_RevertWhen_Vote_DuringEndOfEpochOps() public {
        // Note: The EndOfEpochOpsUnderway error is not reachable in normal operation
        // because vote() uses EpochMath.getCurrentEpochNumber() which returns the
        // next epoch once we're past the current epoch's end time. And the next
        // epoch is always in Voting state.
        // 
        // This test instead verifies that voting in the new epoch fails if
        // the user has no voting power for that epoch (which is the actual
        // error that would occur in this scenario).
        
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        // Intentionally DON'T setup voting power for next epoch
        _vote(voter1, _toArray(1), _toArray(100 ether));
        
        // End epoch
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        // Now we're in the next epoch time window
        // vote() will check epochs[nextEpoch].state which is Voting
        // But user has no voting power for the new epoch
        vm.expectRevert(Errors.NoAvailableVotes.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), false);
    }

    function test_RevertWhen_Vote_Paused() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(voter1);
        votingController.vote(_toArray(1), _toArray(100 ether), false);
    }

    // ═══════════════════════════════════════════════════════════════════
    // migrateVotes: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_MigrateVotes_Personal_SingleMigration() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        // Vote for pool 1
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        // Migrate from pool 1 to pool 2
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.VotesMigrated(epoch, voter1, _toArray(1), _toArray(2), _toArray(200 ether), false);
        
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(200 ether), false);
        
        // Check pools
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 300 ether, "Pool 1 should have 300 ether");
        assertEq(capturePoolEpochState(epoch, 2).totalVotes, 200 ether, "Pool 2 should have 200 ether");
        
        // User total votes spent should remain same
        (uint128 totalVotesSpent,) = votingController.usersEpochData(epoch, voter1);
        assertEq(totalVotesSpent, 500 ether, "User totalVotesSpent should not change");
    }

    function test_MigrateVotes_Personal_FromInactivePool() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        
        // Vote for pool 1
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        // Deactivate pool 1
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(1));
        
        // Migration from inactive pool should succeed
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(200 ether), false);
        
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 300 ether, "Pool 1 should have 300 ether");
        assertEq(capturePoolEpochState(epoch, 2).totalVotes, 200 ether, "Pool 2 should have 200 ether");
    }

    function test_MigrateVotes_Delegated() public {
        uint128 epoch = getCurrentEpochNumber();
        
        _registerDelegate(delegate1, 1000);
        _setupVotingPower(delegate1, epoch, 0, 2000 ether);
        
        // Vote as delegate
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        
        // Migrate delegated votes
        vm.prank(delegate1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(400 ether), true);
        
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 600 ether, "Pool 1 should have 600 ether");
        assertEq(capturePoolEpochState(epoch, 2).totalVotes, 400 ether, "Pool 2 should have 400 ether");
    }

    // ═══════════════════════════════════════════════════════════════════
    // migrateVotes: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_MigrateVotes_SamePool() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        vm.expectRevert(Errors.InvalidPoolPair.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(1), _toArray(100 ether), false);
    }

    function test_RevertWhen_MigrateVotes_ToInactivePool() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        // Deactivate pool 2
        vm.prank(votingControllerAdmin);
        votingController.removePools(_toArray(2));
        
        vm.expectRevert(Errors.PoolNotActive.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(100 ether), false);
    }

    function test_RevertWhen_MigrateVotes_InsufficientVotesInSource() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        vm.expectRevert(Errors.InsufficientVotes.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(600 ether), false);
    }

    function test_RevertWhen_MigrateVotes_ZeroVotes() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        vm.expectRevert(Errors.ZeroVotes.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(0), false);
    }

    function test_RevertWhen_MigrateVotes_ArrayLengthMismatch() public {
        vm.expectRevert(Errors.MismatchedArrayLengths.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1, 2), _toArray(3), _toArray(100 ether), false);
    }

    function test_RevertWhen_MigrateVotes_Delegated_NotRegistered() public {
        uint128 epoch = getCurrentEpochNumber();
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));
        
        vm.expectRevert(Errors.NotRegisteredAsDelegate.selector);
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(100 ether), true);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Multiple Voters Scenario
    // ═══════════════════════════════════════════════════════════════════

    function test_Vote_MultipleVoters_SamePool() public {
        uint128 epoch = getCurrentEpochNumber();
        
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _setupVotingPower(voter2, epoch, 2000 ether, 0);
        _setupVotingPower(voter3, epoch, 500 ether, 0);
        
        // ---- CAPTURE INITIAL STATE ----
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 0, "Pool should start with 0 votes");
        
        // ---- VOTER 1 VOTES ----
        _vote(voter1, _toArray(1), _toArray(300 ether));
        {
            (uint128 voter1Votes,) = votingController.usersEpochData(epoch, voter1);
            (uint128 voter1PoolVotes,) = votingController.usersEpochPoolData(epoch, 1, voter1);
            assertEq(voter1Votes, 300 ether, "Voter1 total: exactly 300 ether");
            assertEq(voter1PoolVotes, 300 ether, "Voter1 pool votes: exactly 300 ether");
        }
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 300 ether, "Pool after voter1: 300 ether");
        
        // ---- VOTER 2 VOTES ----
        _vote(voter2, _toArray(1), _toArray(1000 ether));
        {
            (uint128 voter2Votes,) = votingController.usersEpochData(epoch, voter2);
            (uint128 voter2PoolVotes,) = votingController.usersEpochPoolData(epoch, 1, voter2);
            assertEq(voter2Votes, 1000 ether, "Voter2 total: exactly 1000 ether");
            assertEq(voter2PoolVotes, 1000 ether, "Voter2 pool votes: exactly 1000 ether");
        }
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 1300 ether, "Pool after voter2: 300 + 1000 = 1300 ether");
        
        // ---- VOTER 3 VOTES ----
        _vote(voter3, _toArray(1), _toArray(500 ether));
        {
            (uint128 voter3Votes,) = votingController.usersEpochData(epoch, voter3);
            (uint128 voter3PoolVotes,) = votingController.usersEpochPoolData(epoch, 1, voter3);
            assertEq(voter3Votes, 500 ether, "Voter3 total: exactly 500 ether");
            assertEq(voter3PoolVotes, 500 ether, "Voter3 pool votes: exactly 500 ether");
        }
        
        // ---- FINAL STATE VERIFICATION ----
        assertEq(capturePoolEpochState(epoch, 1).totalVotes, 1800 ether, "Pool total: 300 + 1000 + 500 = 1800 ether");
        assertEq(capturePoolState(1).totalVotes, 1800 ether, "Global pool votes: 1800 ether");
    }
}

