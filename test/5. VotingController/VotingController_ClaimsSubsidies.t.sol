// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/**
 * @title VotingController_ClaimsSubsidies_Test
 * @notice Tests for subsidy claims by verifiers
 */
contract VotingController_ClaimsSubsidies_Test is VotingControllerHarness {

    uint128 internal epoch;

    function setUp() public override {
        super.setUp();
        _createPools(3);
        epoch = getCurrentEpochNumber();
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimSubsidies: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_ClaimSubsidies_SinglePool() public {
        // Setup votes
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Finalize with subsidies
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        // Setup mocked accrued subsidies
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);  // 50 in 6dp
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);  // 100 in 6dp
        
        // ---- CAPTURE BEFORE STATE ----
        uint256 verifierBalanceBefore = mockEsMoca.balanceOf(verifier1Asset);
        uint256 contractBalanceBefore = mockEsMoca.balanceOf(address(votingController));
        GlobalCountersSnapshot memory globalBefore = captureGlobalCounters();
        EpochSnapshot memory epochBefore = captureEpochState(epoch);
        PoolEpochSnapshot memory poolBefore = capturePoolEpochState(epoch, 1);
        uint256 verifierTotalBefore = votingController.verifierSubsidies(verifier1);
        
        // Check verifier epoch data (isBlocked, totalSubsidiesClaimed)
        (bool blockedBefore, uint128 epochSubsidiesBefore) = votingController.verifierEpochData(epoch, verifier1);
        assertFalse(blockedBefore, "Verifier should not be blocked");
        assertEq(epochSubsidiesBefore, 0, "Epoch subsidies should be 0 initially");
        
        // Check verifier-pool specific subsidies
        uint128 poolSubsidiesBefore = votingController.verifierEpochPoolSubsidies(epoch, 1, verifier1);
        assertEq(poolSubsidiesBefore, 0, "Pool subsidies should be 0 initially");
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.SubsidiesClaimed(epoch, verifier1, _toArray(1), 50 ether);
        
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
        
        // ---- CAPTURE AFTER STATE ----
        uint256 verifierBalanceAfter = mockEsMoca.balanceOf(verifier1Asset);
        uint256 contractBalanceAfter = mockEsMoca.balanceOf(address(votingController));
        GlobalCountersSnapshot memory globalAfter = captureGlobalCounters();
        EpochSnapshot memory epochAfter = captureEpochState(epoch);
        PoolEpochSnapshot memory poolAfter = capturePoolEpochState(epoch, 1);
        uint256 verifierTotalAfter = votingController.verifierSubsidies(verifier1);
        
        (bool blockedAfter, uint128 epochSubsidiesAfter) = votingController.verifierEpochData(epoch, verifier1);
        uint128 poolSubsidiesAfter = votingController.verifierEpochPoolSubsidies(epoch, 1, verifier1);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Token balances (verifier gets 50% of 100 = 50, tokens come from contract)
        assertEq(verifierBalanceAfter, verifierBalanceBefore + 50 ether, "Verifier: +50 ether (50% of 100)");
        assertEq(contractBalanceAfter, contractBalanceBefore - 50 ether, "Contract: -50 ether");
        
        // Verifier epoch data
        assertFalse(blockedAfter, "Verifier remains unblocked");
        assertEq(epochSubsidiesAfter, 50 ether, "Epoch subsidies claimed: 50 ether");
        
        // Verifier pool data (prevents double claim)
        assertEq(poolSubsidiesAfter, 50 ether, "Pool subsidies recorded: 50 ether");
        
        // Global counters
        assertEq(globalAfter.totalSubsidiesClaimed, globalBefore.totalSubsidiesClaimed + 50 ether, 
            "Global totalSubsidiesClaimed: +50 ether");
        
        // Epoch counters
        assertEq(epochAfter.totalSubsidiesClaimed, epochBefore.totalSubsidiesClaimed + 50 ether, 
            "Epoch totalSubsidiesClaimed: +50 ether");
        
        // Pool epoch counters
        assertEq(poolAfter.totalSubsidiesClaimed, poolBefore.totalSubsidiesClaimed + 50 ether, 
            "Pool totalSubsidiesClaimed: +50 ether");
        
        // Verifier lifetime tracking
        assertEq(verifierTotalAfter, verifierTotalBefore + 50 ether, "Verifier lifetime: +50 ether");
    }

    function test_ClaimSubsidies_MultiplePools() public {
        _setupVotingPower(voter1, epoch, 2000 ether, 0);
        _vote(voter1, _toArray(1, 2), _toArray(1000 ether, 1000 ether));
        
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 200 ether));
        
        // Setup mocked subsidies
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 60e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 2, verifier1, 80e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 2, 100e6);
        
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1, 2));
        
        // Pool 1: 60% of 100 = 60 ether
        // Pool 2: 80% of 200 = 160 ether
        // Total: 220 ether
        assertEq(mockEsMoca.balanceOf(verifier1Asset), 220 ether, "Verifier should receive subsidies from both pools");
    }

    function test_ClaimSubsidies_MultipleVerifiers() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        // Setup mocked subsidies for multiple verifiers
        // verifier1 accrued 30%, verifier2 accrued 50% of pool total
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 30e6);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier2, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        // ---- VERIFY INITIAL STATE ----
        PoolEpochSnapshot memory poolBefore = capturePoolEpochState(epoch, 1);
        assertEq(poolBefore.totalSubsidiesAllocated, 100 ether, "Pool subsidies allocated: 100 ether");
        assertEq(poolBefore.totalSubsidiesClaimed, 0, "Pool subsidies claimed: 0 initially");
        
        // ---- VERIFIER 1 CLAIMS (30%) ----
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
        
        PoolEpochSnapshot memory poolAfterV1 = capturePoolEpochState(epoch, 1);
        assertEq(poolAfterV1.totalSubsidiesClaimed, 30 ether, "Pool claimed after V1: 30 ether");
        
        // Safety invariant: claimed <= allocated
        assertTrue(poolAfterV1.totalSubsidiesClaimed <= poolAfterV1.totalSubsidiesAllocated, 
            "Invariant: subsidies claimed <= allocated after V1");
        
        // ---- VERIFIER 2 CLAIMS (50%) ----
        vm.prank(verifier2Asset);
        votingController.claimSubsidies(epoch, verifier2, _toArray(1));
        
        PoolEpochSnapshot memory poolAfterV2 = capturePoolEpochState(epoch, 1);
        assertEq(poolAfterV2.totalSubsidiesClaimed, 80 ether, "Pool claimed after V2: 30 + 50 = 80 ether");
        
        // Safety invariant: claimed <= allocated (20% of subsidies remain unclaimed)
        assertTrue(poolAfterV2.totalSubsidiesClaimed <= poolAfterV2.totalSubsidiesAllocated, 
            "Invariant: subsidies claimed <= allocated after V2");
        
        // Token balance verification
        assertEq(mockEsMoca.balanceOf(verifier1Asset), 30 ether, "Verifier1 should get 30%");
        assertEq(mockEsMoca.balanceOf(verifier2Asset), 50 ether, "Verifier2 should get 50%");
    }

    function test_ClaimSubsidies_UpdatesCounters() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 100e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        GlobalCountersSnapshot memory before = captureGlobalCounters();
        EpochSnapshot memory epochBefore = captureEpochState(epoch);
        
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
        
        GlobalCountersSnapshot memory after_ = captureGlobalCounters();
        EpochSnapshot memory epochAfter = captureEpochState(epoch);
        
        assertEq(after_.totalSubsidiesClaimed, before.totalSubsidiesClaimed + 100 ether, "Global subsidies claimed should increase");
        assertEq(epochAfter.totalSubsidiesClaimed, epochBefore.totalSubsidiesClaimed + 100 ether, "Epoch subsidies claimed should increase");
        
        // Check verifier subsidies tracking
        assertEq(votingController.verifierSubsidies(verifier1), 100 ether, "Verifier subsidies should be tracked");
    }

    // ═══════════════════════════════════════════════════════════════════
    // claimSubsidies: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ClaimSubsidies_InvalidVerifier() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, address(0), _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_EmptyPoolArray() public {
        uint128[] memory emptyArray = new uint128[](0);
        
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, emptyArray);
    }

    function test_RevertWhen_ClaimSubsidies_EpochNotFinalized() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        // Don't finalize
        
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_NoSubsidiesAllocated() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // Finalize with ZERO subsidies (not force finalize which blocks claims entirely)
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(0));
        
        vm.expectRevert(Errors.NoSubsidiesToClaim.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_VerifierBlocked() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        // End epoch and block verifier
        _warpToEpochEnd();
        vm.prank(cronJob);
        votingController.endEpoch();
        
        address[] memory verifiersToBlock = _toAddressArray(verifier1);
        vm.prank(cronJob);
        votingController.processVerifierChecks(false, verifiersToBlock);
        
        // Complete verifier checks
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, new address[](0));
        
        mockEsMoca.mintForTesting(votingControllerTreasury, 100 ether);
        
        // Process ALL active pools (not just pool 1)
        uint128 totalActivePools = votingController.TOTAL_ACTIVE_POOLS();
        uint128[] memory allPoolIds = new uint128[](totalActivePools);
        uint128[] memory allRewards = new uint128[](totalActivePools);
        uint128[] memory allSubsidies = new uint128[](totalActivePools);
        for (uint128 i = 0; i < totalActivePools; ++i) {
            allPoolIds[i] = i + 1;
            allRewards[i] = 0;
            allSubsidies[i] = (i == 0) ? 100 ether : 0; // Only pool 1 gets subsidies
        }
        
        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(allPoolIds, allRewards, allSubsidies);
        
        vm.prank(cronJob);
        votingController.finalizeEpoch();
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        vm.expectRevert(Errors.ClaimsBlocked.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_PoolHasNoSubsidies() public {
        _setupVotingPower(voter1, epoch, 2000 ether, 0);
        _vote(voter1, _toArray(1, 2), _toArray(1000 ether, 1000 ether));
        
        // Finalize with subsidies only for pool 1
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 0));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 2, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 2, 100e6);
        
        vm.expectRevert(Errors.PoolHasNoSubsidies.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(2));
    }

    function test_RevertWhen_ClaimSubsidies_DoubleClaim() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        // First claim succeeds
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
        
        // Second claim fails
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_WrongCaller() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        // Wrong caller (not verifier1Asset)
        vm.expectRevert("Caller is not verifier's asset manager");
        vm.prank(verifier2Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_ZeroPoolAccruedSubsidies() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        // Pool has allocated subsidies but no accrued subsidies from payments
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 0); // Zero accrued
        
        vm.expectRevert(Errors.NoSubsidiesToClaim.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    function test_RevertWhen_ClaimSubsidies_VerifierAccruedGreaterThanPool() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        // Verifier accrued > pool accrued (invalid state)
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 150e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        vm.expectRevert(Errors.VerifierAccruedSubsidiesGreaterThanPool.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Subsidies Already Withdrawn
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_ClaimSubsidies_SubsidiesWithdrawn() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1), _toArray(0), _toArray(100 ether));
        
        // Warp past unclaimed delay
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        // Withdraw unclaimed subsidies
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch);
        
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 50e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        vm.expectRevert(Errors.SubsidiesAlreadyWithdrawn.selector);
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
    }
}

