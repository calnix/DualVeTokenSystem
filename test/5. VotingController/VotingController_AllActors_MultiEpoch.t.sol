// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Events} from "../../src/libraries/Events.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";

/**
 * @title VotingController_AllActors_MultiEpoch_Test
 * @notice Comprehensive integration tests involving all actors across multiple epochs
 * @dev Tests verifiers, personal voters, delegators, and delegates with mixed reward/subsidy scenarios
 */
contract VotingController_AllActors_MultiEpoch_Test is VotingControllerHarness {

    // Additional actors for complex scenarios
    address public voter4 = makeAddr("voter4");
    address public voter5 = makeAddr("voter5");
    address public delegator4 = makeAddr("delegator4");
    address public delegator5 = makeAddr("delegator5");

    function setUp() public override {
        super.setUp();
        // Create 5 pools for diverse scenarios
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 1: Basic Multi-Actor Single Epoch
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_BasicMultiActor_SingleEpoch() public {
        uint128 epoch = getCurrentEpochNumber();

        // ---- SETUP PHASE ----
        
        // Personal voters
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _setupVotingPower(voter2, epoch, 2000 ether, 0);
        _setupVotingPower(voter3, epoch, 500 ether, 0);

        // Register delegates with different fees
        _registerDelegate(delegate1, 1000);  // 10% fee
        _registerDelegate(delegate2, 2000);  // 20% fee

        // Setup delegated voting power
        _setupVotingPower(delegate1, epoch, 0, 3000 ether);
        _setupVotingPower(delegate2, epoch, 0, 2000 ether);

        // Setup specific delegated amounts
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1500 ether);
        _setupDelegatedVotingPower(delegator2, delegate1, epoch, 1500 ether);
        _setupDelegatedVotingPower(delegator3, delegate2, epoch, 2000 ether);

        // ---- VOTING PHASE ----

        // Personal voters vote for different pools
        _vote(voter1, _toArray(1, 2), _toArray(500 ether, 500 ether));
        _vote(voter2, _toArray(2, 3), _toArray(1000 ether, 1000 ether));
        _vote(voter3, _toArray(1), _toArray(500 ether));

        // Delegates vote
        _voteAsDelegated(delegate1, _toArray(1, 3), _toArray(1500 ether, 1500 ether));
        _voteAsDelegated(delegate2, _toArray(2, 4), _toArray(1000 ether, 1000 ether));

        // ---- FINALIZATION PHASE ----

        // Setup subsidies in PaymentsController mock
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 60e6);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier2, 40e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);

        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 2, verifier1, 100e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 2, 100e6);

        // Pool rewards/subsidies allocation
        // Pool 1: Has votes from voter1, voter3, delegate1 - rewards + subsidies
        // Pool 2: Has votes from voter1, voter2, delegate2 - rewards only
        // Pool 3: Has votes from voter2, delegate1 - subsidies only  
        // Pool 4: Has votes from delegate2 - rewards + subsidies
        // Pool 5: No votes - no allocations

        _finalizeEpoch(
            _toArray(1, 2, 3, 4, 5),
            _toArray(100 ether, 200 ether, 0, 50 ether, 0),       // rewards
            _toArray(80 ether, 0, 120 ether, 40 ether, 0)          // subsidies
        );

        // ---- CLAIMS PHASE ----

        // Personal voters claim
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1, 2));

        vm.prank(voter2);
        votingController.claimPersonalRewards(epoch, _toArray(2));

        vm.prank(voter3);
        votingController.claimPersonalRewards(epoch, _toArray(1));

        // Delegators claim from their delegates
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));

        vm.prank(delegator2);
        votingController.claimDelegatedRewards(epoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));

        // Delegate claims fees
        vm.prank(delegate1);
        votingController.claimDelegationFees(epoch, _toAddressArray(delegator1, delegator2), _toNestedArray(_toArray(1), _toArray(1)));

        // Verifiers claim subsidies
        // Pool 1 has 80 ether subsidies, Pool 2 has 0 subsidies
        // Pool 3 has 120 ether subsidies, Pool 4 has 40 ether subsidies
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));

        vm.prank(verifier2Asset);
        votingController.claimSubsidies(epoch, verifier2, _toArray(1));

        // ---- VERIFICATION WITH EXACT AMOUNTS ----
        
        // Calculate expected amounts based on voting distribution:
        // Pool 1: 100 ether rewards, 80 ether subsidies
        //   - Total votes: voter1(500) + voter3(500) + delegate1(1500) = 2500 ether
        //   - voter1: 500/2500 * 100 = 20 ether
        //   - voter3: 500/2500 * 100 = 20 ether
        //   - delegate1 portion: 1500/2500 * 100 = 60 ether
        //     - delegator1: 1500/3000 * 60 = 30 ether gross, 30 - 10% fee = 27 ether net
        //     - delegator2: 1500/3000 * 60 = 30 ether gross, 30 - 10% fee = 27 ether net
        //     - delegate1 fees: 3 + 3 = 6 ether
        //
        // Pool 2: 200 ether rewards
        //   - Total votes: voter1(500) + voter2(1000) + delegate2(1000) = 2500 ether
        //   - voter1: 500/2500 * 200 = 40 ether
        //   - voter2: 1000/2500 * 200 = 80 ether
        //
        // Subsidies Pool 1 (80 ether):
        //   - verifier1: 60% of 80 = 48 ether
        //   - verifier2: 40% of 80 = 32 ether
        
        // Verify EXACT personal voter rewards
        assertEq(mockEsMoca.balanceOf(voter1), 60 ether, "Voter1: 20 (pool1) + 40 (pool2) = 60 ether");
        assertEq(mockEsMoca.balanceOf(voter2), 80 ether, "Voter2: 80 (pool2) = 80 ether");
        assertEq(mockEsMoca.balanceOf(voter3), 20 ether, "Voter3: 20 (pool1) = 20 ether");
        
        // Verify EXACT delegator net rewards (after 10% delegate fee)
        assertEq(mockEsMoca.balanceOf(delegator1), 27 ether, "Delegator1: 30 gross - 10% = 27 ether net");
        assertEq(mockEsMoca.balanceOf(delegator2), 27 ether, "Delegator2: 30 gross - 10% = 27 ether net");
        
        // Verify EXACT delegate fees
        assertEq(mockEsMoca.balanceOf(delegate1), 6 ether, "Delegate1: 3 + 3 = 6 ether fees");
        
        // Verify EXACT subsidy claims
        assertEq(mockEsMoca.balanceOf(verifier1Asset), 48 ether, "Verifier1: 60% of 80 = 48 ether");
        assertEq(mockEsMoca.balanceOf(verifier2Asset), 32 ether, "Verifier2: 40% of 80 = 32 ether");

        // Verify epoch counters match claimed totals
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        
        // Total personal rewards claimed: 60 + 80 + 20 = 160 ether
        // Total delegated rewards claimed: 27 + 27 = 54 ether
        // Total delegate fees claimed: 6 ether
        // Grand total rewards claimed: 160 + 54 + 6 = 220 ether
        assertEq(snapshot.totalRewardsClaimed, 220 ether, "Total rewards claimed should be 220 ether");
        
        // Total subsidies claimed: 48 + 32 = 80 ether
        assertEq(snapshot.totalSubsidiesClaimed, 80 ether, "Total subsidies claimed should be 80 ether");
        
        // Verify global counters
        GlobalCountersSnapshot memory globalCounters = captureGlobalCounters();
        assertEq(globalCounters.totalRewardsClaimed, 220 ether, "Global rewards claimed should match");
        assertEq(globalCounters.totalSubsidiesClaimed, 80 ether, "Global subsidies claimed should match");
        
        // Verify pool-level allocations
        PoolEpochSnapshot memory pool1Epoch = capturePoolEpochState(epoch, 1);
        assertEq(pool1Epoch.totalRewardsAllocated, 100 ether, "Pool 1 rewards allocated");
        assertEq(pool1Epoch.totalSubsidiesAllocated, 80 ether, "Pool 1 subsidies allocated");
        
        PoolEpochSnapshot memory pool2Epoch = capturePoolEpochState(epoch, 2);
        assertEq(pool2Epoch.totalRewardsAllocated, 200 ether, "Pool 2 rewards allocated");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 2: Multi-Epoch with Delegate Fee Changes
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_MultiEpoch_DelegateFeeChanges() public {
        uint128 epoch1 = getCurrentEpochNumber();

        // ---- EPOCH 1 ----

        // Register delegate with 10% fee
        _registerDelegate(delegate1, 1000);

        _setupVotingPower(delegate1, epoch1, 0, 2000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch1, 2000 ether);

        _voteAsDelegated(delegate1, _toArray(1), _toArray(2000 ether));

        // Schedule fee increase (will apply in epoch1 + feeIncreaseDelayEpochs)
        vm.prank(delegate1);
        votingController.updateDelegateFee(3000); // Increase to 30%

        // Finalize epoch 1
        _finalizeEpoch(_toArray(1, 2, 3, 4, 5), _toArray(100 ether, 0, 0, 0, 0), _toArray(0, 0, 0, 0, 0));

        // ---- EPOCH 2 ----

        uint128 epoch2 = getCurrentEpochNumber();

        _setupVotingPower(delegate1, epoch2, 0, 2000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch2, 2000 ether);

        // Vote in epoch 2 - fee should still be 10% (increase not applied yet)
        _voteAsDelegated(delegate1, _toArray(1), _toArray(2000 ether));

        uint128 feeEpoch2 = votingController.delegateHistoricalFeePcts(delegate1, epoch2);
        assertEq(feeEpoch2, 1000, "Fee should still be 10% in epoch 2");

        _finalizeEpoch(_toArray(1, 2, 3, 4, 5), _toArray(100 ether, 0, 0, 0, 0), _toArray(0, 0, 0, 0, 0));

        // ---- EPOCH 3+ (After delay) ----

        // Warp to when fee increase should apply
        uint128 targetEpoch = epoch1 + feeIncreaseDelayEpochs;
        _warpToEpoch(targetEpoch);

        _setupVotingPower(delegate1, targetEpoch, 0, 2000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, targetEpoch, 2000 ether);

        // Vote should trigger fee application
        _voteAsDelegated(delegate1, _toArray(1), _toArray(2000 ether));

        DelegateSnapshot memory snapshot = captureDelegateState(delegate1);
        assertEq(snapshot.currentFeePct, 3000, "Fee should now be 30%");

        uint128 feeAfterDelay = votingController.delegateHistoricalFeePcts(delegate1, targetEpoch);
        assertEq(feeAfterDelay, 3000, "Historical fee should be 30%");

        // ---- FINALIZE TARGET EPOCH WITH REWARDS ----
        _finalizeEpoch(_toArray(1, 2, 3, 4, 5), _toArray(100 ether, 0, 0, 0, 0), _toArray(0, 0, 0, 0, 0));

        // ---- VERIFY CLAIMS IN EPOCH 1 (10% fee) ----

        // Delegator claims from epoch 1 with 10% fee
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch1, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));

        // Should receive 90 ether (100 - 10% fee)
        assertEq(mockEsMoca.balanceOf(delegator1), 90 ether, "Epoch1: Delegator should receive 90% (10% fee)");

        // ---- VERIFY CLAIMS IN TARGET EPOCH (30% fee applied to payouts) ----
        
        // Delegator claims from targetEpoch with 30% fee applied
        uint256 delegatorBalanceBefore = mockEsMoca.balanceOf(delegator1);
        
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(targetEpoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        
        uint256 delegatorBalanceAfter = mockEsMoca.balanceOf(delegator1);
        uint256 delegatorNetReward = delegatorBalanceAfter - delegatorBalanceBefore;
        
        // With 30% fee: 100 ether gross - 30% = 70 ether net
        assertEq(delegatorNetReward, 70 ether, "TargetEpoch: Delegator should receive 70% (30% fee applied)");
        
        // Delegate claims fees from targetEpoch
        uint256 delegateBalanceBefore = mockEsMoca.balanceOf(delegate1);
        
        vm.prank(delegate1);
        votingController.claimDelegationFees(targetEpoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
        
        uint256 delegateBalanceAfter = mockEsMoca.balanceOf(delegate1);
        uint256 delegateFees = delegateBalanceAfter - delegateBalanceBefore;
        
        // Delegate should get 30% of 100 ether = 30 ether
        assertEq(delegateFees, 30 ether, "TargetEpoch: Delegate should receive 30 ether in fees");
        
        // Verify the math: gross (100) = net (70) + fees (30)
        assertEq(delegatorNetReward + delegateFees, 100 ether, "Total should equal pool rewards");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 3: Pools with Zero Rewards/Subsidies
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_ZeroRewardsSubsidies_Combinations() public {
        uint128 epoch = getCurrentEpochNumber();

        // Setup voters for all pools
        _setupVotingPower(voter1, epoch, 5000 ether, 0);
        _vote(voter1, _toArray(1, 2, 3, 4, 5), _toArray(1000 ether, 1000 ether, 1000 ether, 1000 ether, 1000 ether));

        // Finalize with mixed allocations:
        // Pool 1: rewards only
        // Pool 2: subsidies only
        // Pool 3: both rewards and subsidies
        // Pool 4: neither (but has votes)
        // Pool 5: both

        _finalizeEpoch(
            _toArray(1, 2, 3, 4, 5),
            _toArray(100 ether, 0, 50 ether, 0, 75 ether),        // rewards
            _toArray(0, 80 ether, 60 ether, 0, 45 ether)           // subsidies
        );

        // Setup subsidy claims
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 2, verifier1, 100e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 2, 100e6);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 3, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 3, 100e6);

        // Claim rewards from pools with rewards
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1, 3, 5));

        assertEq(mockEsMoca.balanceOf(voter1), 225 ether, "Voter1 should get rewards from pools 1, 3, 5");

        // Claim subsidies
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(2, 3));

        // Pool 2: 100% of 80 = 80 ether
        // Pool 3: 50% of 60 = 30 ether
        assertEq(mockEsMoca.balanceOf(verifier1Asset), 110 ether, "Verifier1 should get subsidies");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 4: Blocked Verifiers in Mixed Pool Scenario
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_BlockedVerifiers_MixedPools() public {
        uint128 epoch = getCurrentEpochNumber();

        _setupVotingPower(voter1, epoch, 3000 ether, 0);
        _vote(voter1, _toArray(1, 2, 3), _toArray(1000 ether, 1000 ether, 1000 ether));

        // End epoch and block verifier1
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();

        // Block verifier1
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, _toAddressArray(verifier1));

        // Clear with verifier2 not blocked
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));

        // Mint tokens for rewards/subsidies
        mockEsMoca.mintForTesting(votingControllerTreasury, 300 ether);

        // Process allocations
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(
            _toArray(1, 2, 3, 4, 5),
            _toArray(100 ether, 0, 0, 0, 0),
            _toArray(100 ether, 100 ether, 0, 0, 0)
        );

        vm.prank(cronJob);
        votingController.finalizeEpoch();

        // Setup subsidies
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier2, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 2, verifier2, 100e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 2, 100e6);

        // Verifier1 is blocked, cannot claim
        (bool isBlocked,) = votingController.verifierEpochData(epoch, verifier1);
        assertTrue(isBlocked, "Verifier1 should be blocked");

        // Verifier2 can claim from both pools
        vm.prank(verifier2Asset);
        votingController.claimSubsidies(epoch, verifier2, _toArray(1, 2));

        assertEq(mockEsMoca.balanceOf(verifier2Asset), 150 ether, "Verifier2 should claim from both pools");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 5: Full Lifecycle Across 3 Epochs
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_FullLifecycle_ThreeEpochs() public {
        // ════════════════════════════════════════════════════════════════
        // EPOCH 1: All actors participate
        // ════════════════════════════════════════════════════════════════

        uint128 epoch1 = getCurrentEpochNumber();

        // Setup all actors
        _setupVotingPower(voter1, epoch1, 2000 ether, 0);
        _setupVotingPower(voter2, epoch1, 1000 ether, 0);

        _registerDelegate(delegate1, 1500); // 15%
        _registerDelegate(delegate2, 500);  // 5%

        _setupVotingPower(delegate1, epoch1, 0, 3000 ether);
        _setupVotingPower(delegate2, epoch1, 0, 2000 ether);

        _setupDelegatedVotingPower(delegator1, delegate1, epoch1, 2000 ether);
        _setupDelegatedVotingPower(delegator2, delegate1, epoch1, 1000 ether);
        _setupDelegatedVotingPower(delegator3, delegate2, epoch1, 2000 ether);

        // Voting
        _vote(voter1, _toArray(1, 2), _toArray(1000 ether, 1000 ether));
        _vote(voter2, _toArray(2), _toArray(1000 ether));
        _voteAsDelegated(delegate1, _toArray(1, 3), _toArray(1500 ether, 1500 ether));
        _voteAsDelegated(delegate2, _toArray(2, 3), _toArray(1000 ether, 1000 ether));

        // Setup subsidies
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch1, 1, verifier1, 100e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch1, 1, 100e6);

        // Finalize epoch 1
        _finalizeEpoch(
            _toArray(1, 2, 3, 4, 5),
            _toArray(100 ether, 150 ether, 75 ether, 0, 0),
            _toArray(50 ether, 0, 0, 0, 0)
        );

        // ════════════════════════════════════════════════════════════════
        // EPOCH 2: Different participation, delegate unregisters
        // ════════════════════════════════════════════════════════════════

        uint128 epoch2 = getCurrentEpochNumber();

        // Delegate2 unregisters (no active votes in new epoch)
        vm.prank(delegate2);
        votingController.unregisterAsDelegate();

        assertFalse(captureDelegateState(delegate2).isRegistered, "Delegate2 should be unregistered");

        // Only delegate1 votes this epoch
        _setupVotingPower(delegate1, epoch2, 0, 2000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch2, 1500 ether);
        _setupDelegatedVotingPower(delegator2, delegate1, epoch2, 500 ether);

        _voteAsDelegated(delegate1, _toArray(1), _toArray(2000 ether));

        // Personal voter also participates
        _setupVotingPower(voter1, epoch2, 1000 ether, 0);
        _vote(voter1, _toArray(2), _toArray(1000 ether));

        _finalizeEpoch(
            _toArray(1, 2, 3, 4, 5),
            _toArray(80 ether, 40 ether, 0, 0, 0),
            _toArray(0, 0, 0, 0, 0)
        );

        // ════════════════════════════════════════════════════════════════
        // EPOCH 3: Force finalization scenario
        // ════════════════════════════════════════════════════════════════

        uint128 epoch3 = getCurrentEpochNumber();

        _setupVotingPower(voter1, epoch3, 500 ether, 0);
        _vote(voter1, _toArray(1), _toArray(500 ether));

        // Force finalize epoch 3
        _warpToEpochEnd();
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();

        EpochSnapshot memory epoch3Snapshot = captureEpochState(epoch3);
        assertEq(uint8(epoch3Snapshot.state), uint8(DataTypes.EpochState.ForceFinalized), "Epoch 3 should be force finalized");

        // ════════════════════════════════════════════════════════════════
        // CLAIMS: All actors claim from epochs 1 and 2
        // ════════════════════════════════════════════════════════════════

        // Epoch 1 claims
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch1, _toArray(1, 2));

        vm.prank(voter2);
        votingController.claimPersonalRewards(epoch1, _toArray(2));

        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch1, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));

        vm.prank(delegate1);
        votingController.claimDelegationFees(epoch1, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));

        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch1, verifier1, _toArray(1));

        // Epoch 2 claims
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch2, _toArray(2));

        vm.prank(delegator1);
        votingController.claimDelegatedRewards(epoch2, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));

        // ════════════════════════════════════════════════════════════════
        // FINAL VERIFICATION
        // ════════════════════════════════════════════════════════════════

        assertTrue(mockEsMoca.balanceOf(voter1) > 0, "Voter1 should have rewards from both epochs");
        assertTrue(mockEsMoca.balanceOf(voter2) > 0, "Voter2 should have rewards from epoch 1");
        assertTrue(mockEsMoca.balanceOf(delegator1) > 0, "Delegator1 should have rewards from both epochs");
        assertTrue(mockEsMoca.balanceOf(delegate1) > 0, "Delegate1 should have fees");
        assertTrue(mockEsMoca.balanceOf(verifier1Asset) > 0, "Verifier1 should have subsidies");

        // Verify global counters
        GlobalCountersSnapshot memory globalState = captureGlobalCounters();
        assertTrue(globalState.totalRewardsClaimed > 0, "Total rewards should be claimed");
        assertTrue(globalState.totalSubsidiesClaimed > 0, "Total subsidies should be claimed");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 6: Vote Migration Mid-Epoch
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_VoteMigration_MultipleActors() public {
        uint128 epoch = getCurrentEpochNumber();

        // Setup
        _setupVotingPower(voter1, epoch, 2000 ether, 0);
        _setupVotingPower(voter2, epoch, 1000 ether, 0);

        _registerDelegate(delegate1, 1000);
        _setupVotingPower(delegate1, epoch, 0, 3000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 3000 ether);

        // Initial votes
        _vote(voter1, _toArray(1), _toArray(2000 ether));
        _vote(voter2, _toArray(2), _toArray(1000 ether));
        _voteAsDelegated(delegate1, _toArray(1, 3), _toArray(1500 ether, 1500 ether));

        // Migrate votes
        vm.prank(voter1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(1000 ether), false);

        vm.prank(delegate1);
        votingController.migrateVotes(_toArray(1), _toArray(4), _toArray(500 ether), true);

        // Verify vote distribution after migration
        PoolEpochSnapshot memory pool1 = capturePoolEpochState(epoch, 1);
        PoolEpochSnapshot memory pool2 = capturePoolEpochState(epoch, 2);
        PoolEpochSnapshot memory pool3 = capturePoolEpochState(epoch, 3);
        PoolEpochSnapshot memory pool4 = capturePoolEpochState(epoch, 4);

        assertEq(pool1.totalVotes, 2000 ether, "Pool 1 should have 2000 ether (voter1: 1000, delegate1: 1000)");
        assertEq(pool2.totalVotes, 2000 ether, "Pool 2 should have 2000 ether (voter2: 1000, voter1 migrated: 1000)");
        assertEq(pool3.totalVotes, 1500 ether, "Pool 3 should have 1500 ether");
        assertEq(pool4.totalVotes, 500 ether, "Pool 4 should have 500 ether from migration");

        // Finalize and claim
        _finalizeEpoch(
            _toArray(1, 2, 3, 4, 5),
            _toArray(50 ether, 100 ether, 75 ether, 25 ether, 0),
            _toArray(0, 0, 0, 0, 0)
        );

        // Claims should reflect migrated positions
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1, 2));

        // Voter1 has 1000 in pool1 (50% of 50) + 1000 in pool2 (50% of 100) = 25 + 50 = 75
        assertEq(mockEsMoca.balanceOf(voter1), 75 ether, "Voter1 rewards should reflect migrated votes");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Scenario 7: Unclaimed Withdrawals After Delay
    // ═══════════════════════════════════════════════════════════════════

    function test_Scenario_UnclaimedWithdrawals_AfterDelay() public {
        uint128 epoch1 = getCurrentEpochNumber();

        // Setup and finalize epoch with claims
        _setupVotingPower(voter1, epoch1, 1000 ether, 0);
        _setupVotingPower(voter2, epoch1, 1000 ether, 0);

        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _vote(voter2, _toArray(2), _toArray(1000 ether));

        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch1, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch1, 1, 100e6);

        _finalizeEpoch(
            _toArray(1, 2, 3, 4, 5),
            _toArray(100 ether, 100 ether, 0, 0, 0),
            _toArray(80 ether, 0, 0, 0, 0)
        );

        // Only voter1 claims, voter2 doesn't claim
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch1, _toArray(1));

        // Only verifier1 claims partial
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch1, verifier1, _toArray(1));

        // Advance past unclaimed delay
        _warpToEpoch(epoch1 + unclaimedDelayEpochs + 1);

        uint256 treasuryBefore = mockEsMoca.balanceOf(votingControllerTreasury);

        // Withdraw unclaimed rewards
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch1);

        // Withdraw unclaimed subsidies
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch1);

        uint256 treasuryAfter = mockEsMoca.balanceOf(votingControllerTreasury);

        // Treasury should receive: voter2's 100 ether + remaining subsidies (80 - 40 = 40)
        assertEq(treasuryAfter - treasuryBefore, 140 ether, "Treasury should receive unclaimed funds");

        // Verify epoch tracking
        EpochSnapshot memory snapshot = captureEpochState(epoch1);
        assertEq(snapshot.totalRewardsWithdrawn, 100 ether, "Unclaimed rewards should be tracked");
        assertEq(snapshot.totalSubsidiesWithdrawn, 40 ether, "Unclaimed subsidies should be tracked");
    }
}

