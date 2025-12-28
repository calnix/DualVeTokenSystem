// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/**
 * @title VotingController_ClaimsRewards_Test
 * @notice Tests for personal and delegated reward claims
 */
contract VotingController_ClaimsRewards_Test is VotingControllerHarness {

    uint128 internal epoch;

    function setUp() public override {
        super.setUp();
        _createPools(3);
        epoch = getCurrentEpochNumber();
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimPersonalRewards: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_ClaimPersonalRewards_SinglePool() public {
        // Setup: voter votes for pool 1
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Finalize epoch with rewards
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // ---- CAPTURE BEFORE STATE ----
        uint256 voterBalanceBefore = mockEsMoca.balanceOf(voter1);
        uint256 contractBalanceBefore = mockEsMoca.balanceOf(address(votingController));
        uint128 globalRewardsClaimedBefore = captureGlobalCounters().totalRewardsClaimed;
        uint128 epochRewardsClaimedBefore = captureEpochState(epoch).totalRewardsClaimed;
        uint128 poolRewardsClaimedBefore = capturePoolEpochState(epoch, 1).totalRewardsClaimed;
        
        // Account has votesSpent and totalRewards - totalRewards is 0 before claiming
        {
            (uint128 votesBefore, uint128 rewardsBefore) = votingController.usersEpochPoolData(epoch, 1, voter1);
            assertEq(rewardsBefore, 0, "Rewards should be 0 before claim");
            assertEq(votesBefore, 1000 ether, "Votes should be recorded");
        }
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.RewardsClaimed(epoch, voter1, _toArray(1), 100 ether);
        
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        // ---- VERIFY STATE CHANGES ----
        
        // Token balances (tokens move from contract to voter)
        assertEq(mockEsMoca.balanceOf(voter1), voterBalanceBefore + 100 ether, "Voter balance: +100 ether");
        assertEq(mockEsMoca.balanceOf(address(votingController)), contractBalanceBefore - 100 ether, "Contract balance: -100 ether");
        
        // User pool account - rewards now tracked (prevents double claim)
        {
            (uint128 votesAfter, uint128 rewardsAfter) = votingController.usersEpochPoolData(epoch, 1, voter1);
            assertEq(rewardsAfter, 100 ether, "User pool rewards recorded: 100 ether");
            assertEq(votesAfter, 1000 ether, "Votes unchanged");
        }
        
        // Global counters
        assertEq(captureGlobalCounters().totalRewardsClaimed, globalRewardsClaimedBefore + 100 ether, 
            "Global totalRewardsClaimed: +100 ether");
        
        // Epoch counters
        assertEq(captureEpochState(epoch).totalRewardsClaimed, epochRewardsClaimedBefore + 100 ether, 
            "Epoch totalRewardsClaimed: +100 ether");
        
        // Pool epoch counters
        assertEq(capturePoolEpochState(epoch, 1).totalRewardsClaimed, poolRewardsClaimedBefore + 100 ether, 
            "Pool totalRewardsClaimed: +100 ether");
    }

    function test_ClaimPersonalRewards_MultiplePools() public {
        // Setup: voter votes for multiple pools
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1, 2), _toArray(600 ether, 400 ether));
        
        // Finalize with rewards for both pools
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 200 ether), _toArray(0, 0));
        
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1, 2));
        
        // Should receive full rewards from both pools
        assertEq(mockEsMoca.balanceOf(voter1), 300 ether, "Voter should receive rewards from both pools");
    }

    function test_ClaimPersonalRewards_ProRataDistribution() public {
        // Setup: two voters with different vote amounts
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _setupVotingPower(voter2, epoch, 1000 ether, 0);
        
        _vote(voter1, _toArray(1), _toArray(300 ether)); // 30%
        _vote(voter2, _toArray(1), _toArray(700 ether)); // 70%
        
        // Finalize with 100 ether rewards
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // ---- VERIFY INITIAL STATE ----
        PoolEpochSnapshot memory poolBefore = capturePoolEpochState(epoch, 1);
        assertEq(poolBefore.totalRewardsAllocated, 100 ether, "Pool allocated: 100 ether");
        assertEq(poolBefore.totalRewardsClaimed, 0, "Pool claimed: 0 initially");
        
        // ---- VOTER 1 CLAIMS (30%) ----
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        PoolEpochSnapshot memory poolAfterVoter1 = capturePoolEpochState(epoch, 1);
        assertEq(poolAfterVoter1.totalRewardsClaimed, 30 ether, "Pool claimed after voter1: 30 ether");
        
        // Safety invariant: claimed <= allocated
        assertTrue(poolAfterVoter1.totalRewardsClaimed <= poolAfterVoter1.totalRewardsAllocated, 
            "Invariant: claimed <= allocated after voter1");
        
        // ---- VOTER 2 CLAIMS (70%) ----
        vm.prank(voter2);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        PoolEpochSnapshot memory poolAfterVoter2 = capturePoolEpochState(epoch, 1);
        assertEq(poolAfterVoter2.totalRewardsClaimed, 100 ether, "Pool claimed after voter2: 30 + 70 = 100 ether");
        
        // Safety invariant: claimed <= allocated (should be exactly equal now)
        assertEq(poolAfterVoter2.totalRewardsClaimed, poolAfterVoter2.totalRewardsAllocated, 
            "Invariant: claimed == allocated after all claims");
        
        // Check pro-rata distribution
        assertEq(mockEsMoca.balanceOf(voter1), 30 ether, "Voter1 should get 30%");
        assertEq(mockEsMoca.balanceOf(voter2), 70 ether, "Voter2 should get 70%");
    }

    function test_ClaimPersonalRewards_UpdatesCounters() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        GlobalCountersSnapshot memory before = captureGlobalCounters();
        EpochSnapshot memory epochBefore = captureEpochState(epoch);
        
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        GlobalCountersSnapshot memory after_ = captureGlobalCounters();
        EpochSnapshot memory epochAfter = captureEpochState(epoch);
        
        assertEq(after_.totalRewardsClaimed, before.totalRewardsClaimed + 100 ether, "Global claimed should increase");
        assertEq(epochAfter.totalRewardsClaimed, epochBefore.totalRewardsClaimed + 100 ether, "Epoch claimed should increase");
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimPersonalRewards: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ClaimPersonalRewards_EmptyArray() public {
        uint128[] memory emptyArray = new uint128[](0);
        
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, emptyArray);
    }

    function test_RevertWhen_ClaimPersonalRewards_EpochNotFinalized() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Don't finalize
        
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
    }

    function test_RevertWhen_ClaimPersonalRewards_NoRewardsAllocated() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Finalize with ZERO rewards (not force finalize which blocks claims entirely)
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(0));
        
        vm.expectRevert(Errors.NoRewardsToClaim.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
    }

    function test_RevertWhen_ClaimPersonalRewards_DoubleClaim() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // First claim succeeds
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        // Second claim fails
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
    }

    function test_RevertWhen_ClaimPersonalRewards_NoVotesInPool() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _setupVotingPower(voter2, epoch, 1000 ether, 0);
        
        // Voter1 votes for pool 1, voter2 votes for pool 2
        _vote(voter1, _toArray(1), _toArray(500 ether));
        _vote(voter2, _toArray(2), _toArray(500 ether));
        
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 100 ether), _toArray(0, 0));
        
        // Voter1 tries to claim from pool 2 (no votes)
        vm.expectRevert(Errors.NoRewardsToClaim.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(2));
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimDelegatedRewards: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_ClaimDelegatedRewards_SingleDelegate() public {
        // Register delegate
        _registerDelegate(delegate1, 1000); // 10% fee
        
        // Setup delegated voting power
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1000 ether);
        
        // Delegate votes
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        
        // Finalize
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // ---- CAPTURE BEFORE STATE ----
        uint256 delegatorBalanceBefore = mockEsMoca.balanceOf(delegator1);
        uint256 contractBalanceBefore = mockEsMoca.balanceOf(address(votingController));
        GlobalCountersSnapshot memory globalBefore = captureGlobalCounters();
        EpochSnapshot memory epochBefore = captureEpochState(epoch);
        
        // Verify view function matches expected
        (uint128 previewNet, uint128 previewFee,,) = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1));
        assertEq(previewNet, 90 ether, "Preview net: 100 - 10% = 90 ether");
        assertEq(previewFee, 10 ether, "Preview fee: 10% of 100 = 10 ether");
        
        // ---- EXECUTE ----
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        
        // ---- CAPTURE AFTER STATE ----
        uint256 delegatorBalanceAfter = mockEsMoca.balanceOf(delegator1);
        uint256 contractBalanceAfter = mockEsMoca.balanceOf(address(votingController));
        GlobalCountersSnapshot memory globalAfter = captureGlobalCounters();
        EpochSnapshot memory epochAfter = captureEpochState(epoch);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Delegator receives net (gross - fee)
        assertEq(delegatorBalanceAfter, delegatorBalanceBefore + 90 ether, "Delegator: +90 ether (100 - 10% fee)");
        
        // Contract balance decreases by net amount only (fee stays for delegate to claim)
        assertEq(contractBalanceAfter, contractBalanceBefore - 90 ether, "Contract: -90 ether");
        
        // Global counters - net rewards claimed
        assertEq(globalAfter.totalRewardsClaimed, globalBefore.totalRewardsClaimed + 90 ether, 
            "Global totalRewardsClaimed: +90 ether");
        
        // Epoch counters
        assertEq(epochAfter.totalRewardsClaimed, epochBefore.totalRewardsClaimed + 90 ether, 
            "Epoch totalRewardsClaimed: +90 ether");
        
        // After claim, view should return 0
        (uint128 postClaimNet,,,) = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1));
        assertEq(postClaimNet, 0, "Post-claim view should return 0");
    }

    function test_ClaimDelegatedRewards_DelegateGetsFees() public {
        _registerDelegate(delegate1, 2000); // 20% fee
        
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1000 ether);
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // Delegator claims first (processes the rewards)
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        
        uint256 delegateBalanceBefore = mockEsMoca.balanceOf(delegate1);
        
        // Delegate claims fees
        vm.prank(delegate1);
        votingController.claimDelegationFees(epoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
        
        uint256 delegateBalanceAfter = mockEsMoca.balanceOf(delegate1);
        
        // Delegate should get 20% fee
        assertEq(delegateBalanceAfter - delegateBalanceBefore, 20 ether, "Delegate should receive fees");
    }

    function test_ClaimDelegatedRewards_MultipleDelegators() public {
        _registerDelegate(delegate1, 1000); // 10% fee
        
        // Setup: delegate has VP from two delegators
        _setupVotingPower(delegate1, epoch, 0, 2000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1200 ether); // 60%
        _setupDelegatedVotingPower(delegator2, delegate1, epoch, 800 ether);  // 40%
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(2000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // ---- VERIFY INITIAL STATE ----
        PoolEpochSnapshot memory poolBefore = capturePoolEpochState(epoch, 1);
        assertEq(poolBefore.totalRewardsAllocated, 100 ether, "Pool allocated: 100 ether");
        assertEq(poolBefore.totalRewardsClaimed, 0, "Pool claimed: 0 initially");
        
        // ---- DELEGATOR 1 CLAIMS (60% gross, 54 net) ----
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        
        PoolEpochSnapshot memory poolAfterD1 = capturePoolEpochState(epoch, 1);
        // Gross rewards = 60 ether claimed, net paid = 54 ether (60 - 10% fee)
        assertEq(poolAfterD1.totalRewardsClaimed, 60 ether, "Pool claimed after D1: 60 ether (gross)");
        
        // Safety invariant: claimed <= allocated
        assertTrue(poolAfterD1.totalRewardsClaimed <= poolAfterD1.totalRewardsAllocated, 
            "Invariant: claimed <= allocated after D1");
        
        // ---- DELEGATOR 2 CLAIMS (40% gross, 36 net) ----
        vm.prank(delegator2);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        
        PoolEpochSnapshot memory poolAfterD2 = capturePoolEpochState(epoch, 1);
        // Total gross rewards claimed = 60 + 40 = 100 ether
        assertEq(poolAfterD2.totalRewardsClaimed, 100 ether, "Pool claimed after D2: 60 + 40 = 100 ether (gross)");
        
        // Safety invariant: claimed == allocated (all rewards claimed)
        assertEq(poolAfterD2.totalRewardsClaimed, poolAfterD2.totalRewardsAllocated, 
            "Invariant: claimed == allocated after all claims");
        
        // Token balance verification (net amounts after 10% fee)
        // Delegator1: 60% of 100 = 60, minus 10% fee = 54
        // Delegator2: 40% of 100 = 40, minus 10% fee = 36
        assertEq(mockEsMoca.balanceOf(delegator1), 54 ether, "Delegator1 should get proportional net rewards");
        assertEq(mockEsMoca.balanceOf(delegator2), 36 ether, "Delegator2 should get proportional net rewards");
    }

    function test_ClaimDelegatedRewards_ZeroFeePct() public {
        _registerDelegate(delegate1, 0); // 0% fee
        
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1000 ether);
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        
        // Should receive full 100 ether (0% fee)
        assertEq(mockEsMoca.balanceOf(delegator1), 100 ether, "Delegator should receive full rewards with 0% fee");
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimDelegatedRewards: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ClaimDelegatedRewards_ArrayMismatch() public {
        address[] memory delegates = new address[](2);
        delegates[0] = delegate1;
        delegates[1] = delegate2;
        
        uint128[][] memory poolIds = new uint128[][](1);
        poolIds[0] = _toArray(1);
        
        vm.expectRevert(Errors.MismatchedArrayLengths.selector);
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, delegates, poolIds);
    }

    function test_RevertWhen_ClaimDelegatedRewards_DelegateDidNotVote() public {
        _registerDelegate(delegate1, 1000);
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        // Delegate doesn't vote
        
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 500 ether);
        
        vm.expectRevert(Errors.ZeroVotes.selector);
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
    }

    function test_RevertWhen_ClaimDelegatedRewards_ZeroDelegatedVP() public {
        _registerDelegate(delegate1, 1000);
        
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 0); // No delegated VP
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        vm.expectRevert(Errors.ZeroDelegatedVP.selector);
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimDelegationFees: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ClaimDelegationFees_DelegateDidNotVote() public {
        _registerDelegate(delegate1, 1000);
        // Delegate doesn't vote
        
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        vm.expectRevert(Errors.ZeroVotes.selector);
        vm.prank(delegate1);
        votingController.claimDelegationFees(epoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
    }

    function test_RevertWhen_ClaimDelegationFees_NoFeesToClaim() public {
        _registerDelegate(delegate1, 1000);
        
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1000 ether);
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(0));
        
        // Delegate tries to claim without delegator processing first
        // This should work because _claimRewardsInternal processes if needed
        // But if no rewards were captured, it fails
        
        // Actually, delegate trying to claim fees from delegator2 who has no VP
        _setupDelegatedVotingPower(delegator2, delegate1, epoch, 0);
        
        vm.expectRevert(Errors.ZeroDelegatedVP.selector);
        vm.prank(delegate1);
        votingController.claimDelegationFees(epoch, _toAddressArray(delegator2), _toNestedArray(_toArray(1)));
    }
}

