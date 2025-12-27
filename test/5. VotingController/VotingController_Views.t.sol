// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/**
 * @title VotingController_Views_Test
 * @notice Tests for view functions
 */
contract VotingController_Views_Test is VotingControllerHarness {

    uint128 internal epoch;

    function setUp() public override {
        super.setUp();
        _createPools(3);
        epoch = getCurrentEpochNumber();
    }

    // ═══════════════════════════════════════════════════════════════════
    // viewClaimablePersonalRewards
    // ═══════════════════════════════════════════════════════════════════

    function test_ViewClaimablePersonalRewards_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        (uint128 totalClaimable, uint128[] memory perPoolClaimable) = votingController.viewClaimablePersonalRewards(epoch, voter1, _toArray(1));
        
        assertEq(totalClaimable, 100 ether, "Total claimable should be 100 ether");
        assertEq(perPoolClaimable.length, 1, "Should have 1 pool result");
        assertEq(perPoolClaimable[0], 100 ether, "Pool 1 claimable should be 100 ether");
    }

    function test_ViewClaimablePersonalRewards_MultiplePools() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1, 2), _toArray(600 ether, 400 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 200 ether, 0), _toArray(0, 0, 0));
        
        (uint128 totalClaimable, uint128[] memory perPoolClaimable) = votingController.viewClaimablePersonalRewards(epoch, voter1, _toArray(1, 2));
        
        assertEq(totalClaimable, 300 ether, "Total claimable should be 300 ether");
        assertEq(perPoolClaimable[0], 100 ether, "Pool 1 claimable should be 100 ether");
        assertEq(perPoolClaimable[1], 200 ether, "Pool 2 claimable should be 200 ether");
    }

    function test_ViewClaimablePersonalRewards_AlreadyClaimed() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        // Claim first
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        // View should return 0
        (uint128 totalClaimable, uint128[] memory perPoolClaimable) = votingController.viewClaimablePersonalRewards(epoch, voter1, _toArray(1));
        
        assertEq(totalClaimable, 0, "Already claimed should show 0");
        assertEq(perPoolClaimable[0], 0, "Pool 1 should show 0 after claim");
    }

    function test_ViewClaimablePersonalRewards_NoVotesInPool() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _setupVotingPower(voter2, epoch, 1000 ether, 0);
        
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _vote(voter2, _toArray(2), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 100 ether, 0), _toArray(0, 0, 0));
        
        // Voter1 has no votes in pool 2
        (uint128 totalClaimable, uint128[] memory perPoolClaimable) = votingController.viewClaimablePersonalRewards(epoch, voter1, _toArray(2));
        
        assertEq(totalClaimable, 0, "Should have 0 claimable for pool with no votes");
        assertEq(perPoolClaimable[0], 0, "Pool 2 claimable should be 0");
    }

    function test_RevertWhen_ViewClaimablePersonalRewards_InvalidAddress() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        vm.expectRevert(Errors.InvalidAddress.selector);
        votingController.viewClaimablePersonalRewards(epoch, address(0), _toArray(1));
    }

    function test_RevertWhen_ViewClaimablePersonalRewards_EmptyPoolArray() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        uint128[] memory emptyArray = new uint128[](0);
        
        vm.expectRevert(Errors.InvalidArray.selector);
        votingController.viewClaimablePersonalRewards(epoch, voter1, emptyArray);
    }

    function test_RevertWhen_ViewClaimablePersonalRewards_EpochNotFinalized() public {
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        votingController.viewClaimablePersonalRewards(epoch, voter1, _toArray(1));
    }

    // ═══════════════════════════════════════════════════════════════════
    // viewClaimableDelegationRewards
    // ═══════════════════════════════════════════════════════════════════

    function test_ViewClaimableDelegationRewards_Success() public {
        _registerDelegate(delegate1, 1000); // 10% fee
        
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1000 ether);
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        (uint128 netClaimable, uint128 feeClaimable, uint128[] memory perPoolNet, uint128[] memory perPoolFee) 
            = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1));
        
        assertEq(netClaimable, 90 ether, "Net claimable should be 90 ether");
        assertEq(feeClaimable, 10 ether, "Fee claimable should be 10 ether");
        assertEq(perPoolNet[0], 90 ether, "Pool 1 net should be 90 ether");
        assertEq(perPoolFee[0], 10 ether, "Pool 1 fee should be 10 ether");
    }

    function test_ViewClaimableDelegationRewards_DelegateDidNotVote() public {
        _registerDelegate(delegate1, 1000);
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        // Delegate doesn't vote
        
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 500 ether);
        
        (uint128 netClaimable, uint128 feeClaimable, uint128[] memory perPoolNet, uint128[] memory perPoolFee)
            = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1));
        
        assertEq(netClaimable, 0, "Should return 0 when delegate didn't vote");
        assertEq(feeClaimable, 0, "Fee should be 0");
        assertEq(perPoolNet[0], 0, "Per pool net should be 0");
        assertEq(perPoolFee[0], 0, "Per pool fee should be 0");
    }

    function test_ViewClaimableDelegationRewards_ZeroDelegatedVP() public {
        _registerDelegate(delegate1, 1000);
        
        _setupVotingPower(delegate1, epoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 0); // No delegated VP
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        (uint128 netClaimable, uint128 feeClaimable,,)
            = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1));
        
        assertEq(netClaimable, 0, "Should return 0 for zero delegated VP");
        assertEq(feeClaimable, 0, "Fee should be 0");
    }

    function test_RevertWhen_ViewClaimableDelegationRewards_InvalidUser() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        vm.expectRevert(Errors.InvalidAddress.selector);
        votingController.viewClaimableDelegationRewards(epoch, address(0), delegate1, _toArray(1));
    }

    function test_RevertWhen_ViewClaimableDelegationRewards_InvalidDelegate() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        vm.expectRevert(Errors.InvalidAddress.selector);
        votingController.viewClaimableDelegationRewards(epoch, delegator1, address(0), _toArray(1));
    }

    // ═══════════════════════════════════════════════════════════════════
    // viewClaimableSubsidies
    // ═══════════════════════════════════════════════════════════════════

    function test_ViewClaimableSubsidies_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        (uint128 totalClaimable, uint128[] memory perPoolClaimable) 
            = votingController.viewClaimableSubsidies(epoch, _toArray(1), verifier1, verifier1Asset);
        
        assertEq(totalClaimable, 50 ether, "Total claimable should be 50 ether");
        assertEq(perPoolClaimable[0], 50 ether, "Pool 1 claimable should be 50 ether");
    }

    function test_ViewClaimableSubsidies_BlockedVerifier() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Finalize with verifier blocked
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, _toAddressArray(verifier1));
        
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        mockEsMoca.mintForTesting(votingControllerTreasury, 100 ether);
        
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        vm.prank(cronJob);
        votingController.finalizeEpoch();
        
        (uint128 totalClaimable, uint128[] memory perPoolClaimable)
            = votingController.viewClaimableSubsidies(epoch, _toArray(1), verifier1, verifier1Asset);
        
        assertEq(totalClaimable, 0, "Blocked verifier should have 0 claimable");
        assertEq(perPoolClaimable[0], 0, "Per pool should be 0 for blocked verifier");
    }

    function test_ViewClaimableSubsidies_AlreadyClaimed() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        // Claim first
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
        
        // View should return 0
        (uint128 totalClaimable, uint128[] memory perPoolClaimable)
            = votingController.viewClaimableSubsidies(epoch, _toArray(1), verifier1, verifier1Asset);
        
        assertEq(totalClaimable, 0, "Already claimed should show 0");
        assertEq(perPoolClaimable[0], 0, "Pool 1 should show 0 after claim");
    }

    function test_ViewClaimableSubsidies_NoSubsidiesInPool() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Pool 2 has no subsidies allocated
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 2, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 2, 100e6);
        
        (uint128 totalClaimable, uint128[] memory perPoolClaimable)
            = votingController.viewClaimableSubsidies(epoch, _toArray(2), verifier1, verifier1Asset);
        
        assertEq(totalClaimable, 0, "Pool with no subsidies should return 0");
        assertEq(perPoolClaimable[0], 0, "Per pool should be 0");
    }

    function test_RevertWhen_ViewClaimableSubsidies_InvalidVerifier() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        vm.expectRevert(Errors.InvalidAddress.selector);
        votingController.viewClaimableSubsidies(epoch, _toArray(1), address(0), verifier1Asset);
    }

    function test_RevertWhen_ViewClaimableSubsidies_InvalidAssetManager() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        vm.expectRevert(Errors.InvalidAddress.selector);
        votingController.viewClaimableSubsidies(epoch, _toArray(1), verifier1, address(0));
    }

    function test_RevertWhen_ViewClaimableSubsidies_EmptyPoolArray() public {
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(100 ether, 0, 0));
        
        uint128[] memory emptyArray = new uint128[](0);
        
        vm.expectRevert(Errors.InvalidArray.selector);
        votingController.viewClaimableSubsidies(epoch, emptyArray, verifier1, verifier1Asset);
    }

    // ═══════════════════════════════════════════════════════════════════
    // viewClaimableDelegationRewards: Fee Changes Across Epochs
    // ═══════════════════════════════════════════════════════════════════

    function test_ViewClaimableDelegationRewards_FeeChangeAcrossEpochs() public {
        uint128 epoch1 = epoch;
        
        // Register delegate with 10% fee
        _registerDelegate(delegate1, 1000); // 10%
        
        _setupVotingPower(delegate1, epoch1, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch1, 1000 ether);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        
        // Finalize epoch 1
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        // View epoch1 delegation rewards (10% fee)
        (uint128 net1, uint128 fee1,,) = votingController.viewClaimableDelegationRewards(epoch1, delegator1, delegate1, _toArray(1));
        assertEq(net1, 90 ether, "Epoch1: 100 - 10% = 90 ether net");
        assertEq(fee1, 10 ether, "Epoch1: 10% of 100 = 10 ether fee");
        
        // We're now in epoch2 (after epoch1 finalization)
        uint128 epoch2 = getCurrentEpochNumber();
        
        // Schedule fee increase to 30% (applies after delay from epoch2)
        vm.prank(delegate1);
        votingController.updateDelegateFee(3000);
        
        // Target epoch is epoch2 + feeIncreaseDelayEpochs (when increase applies)
        uint128 targetEpoch = epoch2 + feeIncreaseDelayEpochs;
        
        // Finalize all intermediate epochs (epoch2 through targetEpoch-1)
        for (uint128 i = epoch2; i < targetEpoch; ++i) {
            _forceFinalizeCurrentEpoch();
        }
        
        // Now we should be at targetEpoch
        assertEq(getCurrentEpochNumber(), targetEpoch, "Should be at target epoch");
        
        _setupVotingPower(delegate1, targetEpoch, 0, 1000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, targetEpoch, 1000 ether);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        // View targetEpoch delegation rewards (30% fee should be applied)
        (uint128 net2, uint128 fee2,,) = votingController.viewClaimableDelegationRewards(targetEpoch, delegator1, delegate1, _toArray(1));
        assertEq(net2, 70 ether, "TargetEpoch: 100 - 30% = 70 ether net");
        assertEq(fee2, 30 ether, "TargetEpoch: 30% of 100 = 30 ether fee");
        
        // Verify historical fee storage
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch1), 1000, "Epoch1 historical fee should be 10%");
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, targetEpoch), 3000, "TargetEpoch historical fee should be 30%");
    }

    function test_ViewClaimableDelegationRewards_MultipleDelegatorsProRata() public {
        _registerDelegate(delegate1, 2000); // 20% fee
        
        _setupVotingPower(delegate1, epoch, 0, 3000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 1800 ether); // 60%
        _setupDelegatedVotingPower(delegator2, delegate1, epoch, 1200 ether); // 40%
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(3000 ether));
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 0, 0), _toArray(0, 0, 0));
        
        // Check delegator1 view (60% of gross, minus 20% fee)
        (uint128 net1, uint128 fee1,,) = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1));
        // Gross: 100 * 60% = 60 ether, Net: 60 - 20% = 48 ether, Fee: 12 ether
        assertEq(net1, 48 ether, "Delegator1: 60% of 100 gross - 20% fee = 48 ether");
        assertEq(fee1, 12 ether, "Delegator1: 20% fee on 60 = 12 ether");
        
        // Check delegator2 view (40% of gross, minus 20% fee)
        (uint128 net2, uint128 fee2,,) = votingController.viewClaimableDelegationRewards(epoch, delegator2, delegate1, _toArray(1));
        // Gross: 100 * 40% = 40 ether, Net: 40 - 20% = 32 ether, Fee: 8 ether
        assertEq(net2, 32 ether, "Delegator2: 40% of 100 gross - 20% fee = 32 ether");
        assertEq(fee2, 8 ether, "Delegator2: 20% fee on 40 = 8 ether");
        
        // Total fees should sum to 20% of 100 = 20 ether
        assertEq(fee1 + fee2, 20 ether, "Total fees should be 20 ether");
        
        // Total net should sum to 80% of 100 = 80 ether
        assertEq(net1 + net2, 80 ether, "Total net should be 80 ether");
    }

    function test_ViewClaimableDelegationRewards_MultiplePools() public {
        _registerDelegate(delegate1, 1500); // 15% fee
        
        _setupVotingPower(delegate1, epoch, 0, 2000 ether);
        _setupDelegatedVotingPower(delegator1, delegate1, epoch, 2000 ether);
        
        _voteAsDelegated(delegate1, _toArray(1, 2), _toArray(1200 ether, 800 ether));
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(100 ether, 200 ether, 0), _toArray(0, 0, 0));
        
        // View rewards for both pools
        (uint128 totalNet, uint128 totalFee, uint128[] memory perPoolNet, uint128[] memory perPoolFee) 
            = votingController.viewClaimableDelegationRewards(epoch, delegator1, delegate1, _toArray(1, 2));
        
        // Pool 1: 100 ether gross, delegator gets 100, fee is 15% = 15, net = 85
        assertEq(perPoolNet[0], 85 ether, "Pool 1: 100 - 15% = 85 ether");
        assertEq(perPoolFee[0], 15 ether, "Pool 1: 15% of 100 = 15 ether");
        
        // Pool 2: 200 ether gross, delegator gets 200, fee is 15% = 30, net = 170
        assertEq(perPoolNet[1], 170 ether, "Pool 2: 200 - 15% = 170 ether");
        assertEq(perPoolFee[1], 30 ether, "Pool 2: 15% of 200 = 30 ether");
        
        // Totals
        assertEq(totalNet, 255 ether, "Total net: 85 + 170 = 255 ether");
        assertEq(totalFee, 45 ether, "Total fee: 15 + 30 = 45 ether");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Delegate Historical Fee Tracking
    // ═══════════════════════════════════════════════════════════════════

    function test_DelegateHistoricalFeePcts_RecordedOnRegistration() public {
        _registerDelegate(delegate1, 2500); // 25%
        
        uint128 currentEpoch = getCurrentEpochNumber();
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, currentEpoch), 2500, 
            "Fee should be recorded at registration epoch");
    }

    function test_DelegateHistoricalFeePcts_RecordedOnFeeDecrease() public {
        _registerDelegate(delegate1, 2000); // 20%
        
        uint128 epoch1 = getCurrentEpochNumber();
        
        // Decrease fee
        vm.prank(delegate1);
        votingController.updateDelegateFee(1000); // 10%
        
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch1), 1000, 
            "Historical fee should update immediately on decrease");
    }

    function test_DelegateHistoricalFeePcts_RecordedOnVote() public {
        _registerDelegate(delegate1, 1000); // 10%
        
        // Finalize current epoch to move to next epoch
        _finalizeEpoch(_toArray(1, 2, 3), _toArray(0, 0, 0), _toArray(0, 0, 0));
        
        uint128 epoch2 = getCurrentEpochNumber();
        _setupVotingPower(delegate1, epoch2, 0, 1000 ether);
        
        // Before voting, epoch2 fee should be 0 (not recorded yet)
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch2), 0, 
            "Fee not recorded until vote");
        
        _voteAsDelegated(delegate1, _toArray(1), _toArray(500 ether));
        
        // After voting, epoch2 fee should be recorded
        assertEq(votingController.delegateHistoricalFeePcts(delegate1, epoch2), 1000, 
            "Fee should be recorded on first vote of epoch");
    }
}

