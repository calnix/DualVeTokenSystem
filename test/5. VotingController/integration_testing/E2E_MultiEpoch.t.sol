// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IntegrationTestHarness} from "./IntegrationTestHarness.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {Events} from "../../../src/libraries/Events.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/**
 * @title E2E_MultiEpoch_Test
 * @notice End-to-end integration tests for multi-epoch scenarios
 * @dev Tests voting power decay, lock expiry, fee changes across epochs
 */
contract E2E_MultiEpoch_Test is IntegrationTestHarness {

    function setUp() public override {
        super.setUp();
        // Create 5 pools for testing
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Voting Power Decays Across Epochs
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_VotingPower_DecaysAcrossEpochs() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5); // Lock expires at end of epoch 15
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Get VP at epoch 10 end
        uint128 vpEpoch10 = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Warp to epoch 11 and get VP at epoch 11 end
        _warpToEpoch(currentEpoch + 1);
        uint128 vpEpoch11 = veMoca.balanceAtEpochEnd(voter1, currentEpoch + 1, false);

        // Warp to epoch 12 and get VP at epoch 12 end
        _warpToEpoch(currentEpoch + 2);
        uint128 vpEpoch12 = veMoca.balanceAtEpochEnd(voter1, currentEpoch + 2, false);

        // Warp to epoch 13 and get VP at epoch 13 end
        _warpToEpoch(currentEpoch + 3);
        uint128 vpEpoch13 = veMoca.balanceAtEpochEnd(voter1, currentEpoch + 3, false);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Monotonic Decay
        // ═══════════════════════════════════════════════════════════════════
        
        assertTrue(vpEpoch10 > vpEpoch11, "VP epoch 10 > VP epoch 11");
        assertTrue(vpEpoch11 > vpEpoch12, "VP epoch 11 > VP epoch 12");
        assertTrue(vpEpoch12 > vpEpoch13, "VP epoch 12 > VP epoch 13");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Decay Matches Formula
        // decay per epoch = slope * EPOCH_DURATION
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 slope = calculateSlope(mocaAmount, esMocaAmount);
        uint128 decayPerEpoch = slope * EPOCH_DURATION;

        assertEq(vpEpoch10 - vpEpoch11, decayPerEpoch, "Decay 10->11 matches formula");
        assertEq(vpEpoch11 - vpEpoch12, decayPerEpoch, "Decay 11->12 matches formula");
        assertEq(vpEpoch12 - vpEpoch13, decayPerEpoch, "Decay 12->13 matches formula");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Lock Expiry - Voting Power Zero
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_LockExpiry_VotingPowerZero() public {
        uint128 startEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(startEpoch + 2); // Expires at end of epoch startEpoch+2
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // VP at start epoch (before expiry)
        uint128 vpEpoch0 = veMoca.balanceAtEpochEnd(voter1, startEpoch, false);
        assertTrue(vpEpoch0 > 0, "VP before expiry should be positive");

        // Warp to next epoch
        _warpToEpoch(startEpoch + 1);
        uint128 vpEpoch1 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 1, false);
        assertTrue(vpEpoch1 > 0, "VP one epoch before expiry should be positive");
        assertTrue(vpEpoch1 < vpEpoch0, "VP should decay");

        // Warp to expiry epoch
        _warpToEpoch(startEpoch + 2);
        uint128 vpEpoch2 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 2, false);

        // ═══════════════════════════════════════════════════════════════════
        // Verify VP is Zero at Expiry
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(vpEpoch2, 0, "VP at expiry epoch should be 0");

        // Warp past expiry
        _warpToEpoch(startEpoch + 3);
        uint128 vpEpoch3 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 3, false);
        assertEq(vpEpoch3, 0, "VP after expiry should be 0");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Fee Increase Applies After Delay
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegateFeeIncrease_AppliesAfterDelay() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 10);
        uint128 initialFee = 1000; // 10%
        uint128 newFee = 2000; // 20%

        // Register delegate
        _registerDelegate(delegate1, initialFee);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Request fee increase
        vm.prank(delegate1);
        votingController.updateDelegateFee(newFee);

        // Verify scheduled for delay epochs
        DelegateSnapshot memory stateAfterRequest = captureDelegateState(delegate1);
        assertEq(stateAfterRequest.currentFeePct, initialFee, "Current fee unchanged");
        assertEq(stateAfterRequest.nextFeePct, newFee, "Next fee scheduled");
        assertEq(stateAfterRequest.nextFeePctEpoch, currentEpoch + feeIncreaseDelayEpochs, "Scheduled epoch");

        // Finalize current epoch (epoch 10) first with no votes
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now at epoch 11 - vote with delegated power
        uint128 voteEpoch = getCurrentEpochNumber();
        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        // Finalize epoch 11 and verify fee used is still old fee
        uint128 pool1Rewards = 100 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // Historical fee should be the initial fee
        uint128 historicalFee = votingController.delegateHistoricalFeePcts(delegate1, voteEpoch);
        assertEq(historicalFee, initialFee, "Fee used should be initial fee");

        // Calculate rewards with old fee
        uint128 expectedOldFee = (pool1Rewards * initialFee) / PRECISION_BASE;

        // Claim fees
        TokenBalanceSnapshot memory beforeDelegate = captureTokenBalances(delegate1);
        vm.prank(delegate1);
        votingController.claimDelegationFees(voteEpoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
        TokenBalanceSnapshot memory afterDelegate = captureTokenBalances(delegate1);

        assertEq(afterDelegate.userEsMoca, beforeDelegate.userEsMoca + expectedOldFee, "Fee should use old rate");

        // ═══════════════════════════════════════════════════════════════════
        // Warp to After Delay and Verify New Fee Applies
        // ═══════════════════════════════════════════════════════════════════
        
        // Finalize any intermediate epochs until we reach the delay epoch
        uint128 epochsToFinalize = feeIncreaseDelayEpochs - 2; // We're at epoch 12 now
        for (uint128 i = 0; i < epochsToFinalize; ++i) {
            _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));
        }
        
        uint128 newFeeEpoch = getCurrentEpochNumber();

        // Vote in new epoch with new fee
        uint128 newDelegateVP = veMoca.balanceAtEpochEnd(delegate1, newFeeEpoch, true);
        _voteAsDelegated(delegate1, _toArray(2), _toArray(newDelegateVP));

        // Finalize
        _finalizeEpoch(
            _toArray(2),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // Historical fee should be the new fee now
        uint128 newHistoricalFee = votingController.delegateHistoricalFeePcts(delegate1, newFeeEpoch);
        assertEq(newHistoricalFee, newFee, "New fee should be applied");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Multi-Epoch - Claim From Prior Epochs
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MultiEpoch_ClaimFromPriorEpochs() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 10);

        // Setup: Create lock
        _fundUserWithMoca(voter1, 200 ether);
        _fundUserWithEsMoca(voter1, 200 ether);
        _createLock(voter1, 200 ether, 200 ether, expiry);

        // ═══════════════════════════════════════════════════════════════════
        // Epoch 10: Vote and finalize
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 epoch10VP = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(epoch10VP));

        uint128 epoch10Rewards = 100 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(epoch10Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Epoch 11: Vote and finalize (don't claim epoch 10 yet)
        // ═══════════════════════════════════════════════════════════════════
        
        _warpToEpoch(currentEpoch + 1);
        uint128 epoch11 = getCurrentEpochNumber();
        uint128 epoch11VP = veMoca.balanceAtEpochEnd(voter1, epoch11, false);
        _vote(voter1, _toArray(2), _toArray(epoch11VP));

        uint128 epoch11Rewards = 150 ether;
        _finalizeEpoch(
            _toArray(2),
            _toArray(epoch11Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Now claim from both prior epochs
        // ═══════════════════════════════════════════════════════════════════
        
        TokenBalanceSnapshot memory beforeClaim = captureTokenBalances(voter1);

        // Claim from epoch 10
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));

        // Claim from epoch 11
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch11, _toArray(2));

        TokenBalanceSnapshot memory afterClaim = captureTokenBalances(voter1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Total Claimed from Both Epochs
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedTotal = epoch10Rewards + epoch11Rewards;
        assertEq(afterClaim.userEsMoca, beforeClaim.userEsMoca + expectedTotal, "Total from both epochs");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Multi-Epoch - Accumulated Rewards Tracked Independently
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MultiEpoch_AccumulatedRewards() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 10);

        // Setup
        _fundUserWithMoca(voter1, 200 ether);
        _fundUserWithEsMoca(voter1, 200 ether);
        _createLock(voter1, 200 ether, 200 ether, expiry);

        // Epoch 10: Vote pool 1
        uint128 epoch10VP = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(epoch10VP));
        _finalizeEpoch(_toArray(1), _toArray(100 ether), _toArray(uint128(0)));

        // Epoch 11: Vote pool 1 again
        _warpToEpoch(currentEpoch + 1);
        uint128 epoch11 = getCurrentEpochNumber();
        uint128 epoch11VP = veMoca.balanceAtEpochEnd(voter1, epoch11, false);
        _vote(voter1, _toArray(1), _toArray(epoch11VP));
        _finalizeEpoch(_toArray(1), _toArray(200 ether), _toArray(uint128(0)));

        // Epoch 12: Vote pool 1 once more
        _warpToEpoch(currentEpoch + 2);
        uint128 epoch12 = getCurrentEpochNumber();
        uint128 epoch12VP = veMoca.balanceAtEpochEnd(voter1, epoch12, false);
        _vote(voter1, _toArray(1), _toArray(epoch12VP));
        _finalizeEpoch(_toArray(1), _toArray(300 ether), _toArray(uint128(0)));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Each Epoch Tracked Independently
        // ═══════════════════════════════════════════════════════════════════
        
        PoolEpochSnapshot memory pool10 = capturePoolEpochState(currentEpoch, 1);
        PoolEpochSnapshot memory pool11 = capturePoolEpochState(epoch11, 1);
        PoolEpochSnapshot memory pool12 = capturePoolEpochState(epoch12, 1);

        assertEq(pool10.totalRewardsAllocated, 100 ether, "Epoch 10 rewards");
        assertEq(pool11.totalRewardsAllocated, 200 ether, "Epoch 11 rewards");
        assertEq(pool12.totalRewardsAllocated, 300 ether, "Epoch 12 rewards");

        // Claim from all three epochs
        TokenBalanceSnapshot memory before = captureTokenBalances(voter1);
        
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch11, _toArray(1));
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch12, _toArray(1));

        TokenBalanceSnapshot memory after_ = captureTokenBalances(voter1);
        
        assertEq(after_.userEsMoca, before.userEsMoca + 600 ether, "Total = 100 + 200 + 300");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegation Change Mid-Epoch
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegationChange_MidEpoch() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 10);

        // Register both delegates
        _registerDelegate(delegate1, 1000);
        _registerDelegate(delegate2, 1500);

        // Create lock delegated to delegate1
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        bytes32 lockId = _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Warp to next epoch where delegation is effective
        _warpToEpoch(currentEpoch + 1);
        uint128 delegatedEpoch = getCurrentEpochNumber();

        // Delegate1 has VP for this epoch
        uint128 d1VPBefore = veMoca.balanceAtEpochEnd(delegate1, delegatedEpoch, true);
        assertTrue(d1VPBefore > 0, "Delegate1 should have VP");

        // Delegate1 votes mid-epoch
        _voteAsDelegated(delegate1, _toArray(1), _toArray(d1VPBefore / 2));

        // Now switch delegate mid-epoch
        vm.prank(delegator1);
        veMoca.delegationAction(lockId, delegate2, DataTypes.DelegationType.Switch);

        // ═══════════════════════════════════════════════════════════════════
        // Verify: Current Epoch - Delegate1 Still Has Power
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 d1VPAfterSwitch = veMoca.balanceAtEpochEnd(delegate1, delegatedEpoch, true);
        assertEq(d1VPAfterSwitch, d1VPBefore, "Delegate1 current epoch VP unchanged");

        // Delegate1 can vote with remaining power
        _voteAsDelegated(delegate1, _toArray(2), _toArray(d1VPBefore / 2));

        // ═══════════════════════════════════════════════════════════════════
        // Warp to Next Epoch and Verify Delegate2 Has Power
        // ═══════════════════════════════════════════════════════════════════
        
        _warpToEpoch(delegatedEpoch + 1);
        uint128 nextEpoch = getCurrentEpochNumber();
        
        uint128 d1VPNextEpoch = veMoca.balanceAtEpochEnd(delegate1, nextEpoch, true);
        uint128 d2VPNextEpoch = veMoca.balanceAtEpochEnd(delegate2, nextEpoch, true);

        assertEq(d1VPNextEpoch, 0, "Delegate1 next epoch VP should be 0");
        assertTrue(d2VPNextEpoch > 0, "Delegate2 next epoch VP should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Increase Duration Extends Voting Power
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_IncreaseDuration_ExtendsVotingPower() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 initialExpiry = getEpochEndTimestamp(currentEpoch + 3);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Create lock with short duration
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        bytes32 lockId = _createLock(voter1, mocaAmount, esMocaAmount, initialExpiry);

        // Get initial VP
        uint128 vpBefore = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Calculate duration to add (7 more epochs)
        uint128 newExpiry = getEpochEndTimestamp(currentEpoch + 10);
        uint128 durationIncrease = newExpiry - initialExpiry;
        
        vm.prank(voter1);
        veMoca.increaseDuration(lockId, durationIncrease);

        // Get VP after extension
        uint128 vpAfter = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // ═══════════════════════════════════════════════════════════════════
        // Verify VP Increased
        // ═══════════════════════════════════════════════════════════════════
        
        assertTrue(vpAfter > vpBefore, "VP should increase after duration extension");

        // Verify new decay slope
        LockSnapshot memory lockState = captureLock(lockId);
        assertEq(lockState.expiry, newExpiry, "Expiry should be updated");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Increase Amount Increases Voting Power
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_IncreaseAmount_IncreasesVotingPower() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 initialMoca = 100 ether;
        uint128 initialEsMoca = 100 ether;
        uint128 additionalMoca = 50 ether;
        uint128 additionalEsMoca = 50 ether;

        // Create lock
        _fundUserWithMoca(voter1, initialMoca + additionalMoca);
        _fundUserWithEsMoca(voter1, initialEsMoca + additionalEsMoca);
        bytes32 lockId = _createLock(voter1, initialMoca, initialEsMoca, expiry);

        // Get initial VP
        uint128 vpBefore = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // Increase amount
        _approveVeMoca(voter1, additionalEsMoca);
        vm.prank(voter1);
        veMoca.increaseAmount{value: additionalMoca}(lockId, additionalEsMoca);

        // Get VP after increase
        uint128 vpAfter = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);

        // ═══════════════════════════════════════════════════════════════════
        // Verify VP Increased Proportionally
        // ═══════════════════════════════════════════════════════════════════
        
        assertTrue(vpAfter > vpBefore, "VP should increase after amount increase");

        // Verify lock amounts updated
        LockSnapshot memory lockState = captureLock(lockId);
        assertEq(lockState.moca, initialMoca + additionalMoca, "MOCA should increase");
        assertEq(lockState.esMoca, initialEsMoca + additionalEsMoca, "esMOCA should increase");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Unlock After Expiry
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_Unlock_AfterExpiry() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 2);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        bytes32 lockId = _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Capture balances before
        TokenBalanceSnapshot memory beforeUnlock = captureTokenBalances(voter1);

        // Warp past expiry
        _warpToEpoch(currentEpoch + 3);

        // Verify VP is 0
        uint128 vpAfterExpiry = veMoca.balanceOfAt(voter1, uint128(block.timestamp), false);
        assertEq(vpAfterExpiry, 0, "VP should be 0 after expiry");

        // Unlock
        vm.prank(voter1);
        veMoca.unlock(lockId);

        // Capture balances after
        TokenBalanceSnapshot memory afterUnlock = captureTokenBalances(voter1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Principals Returned
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterUnlock.userMoca, beforeUnlock.userMoca + mocaAmount, "MOCA returned");
        assertEq(afterUnlock.userEsMoca, beforeUnlock.userEsMoca + esMocaAmount, "esMOCA returned");
        assertEq(afterUnlock.veMocaContractMoca, beforeUnlock.veMocaContractMoca - mocaAmount, "veMoca MOCA decreased");
        assertEq(afterUnlock.veMocaContractEsMoca, beforeUnlock.veMocaContractEsMoca - esMocaAmount, "veMoca esMOCA decreased");

        // Verify lock state
        LockSnapshot memory lockState = captureLock(lockId);
        assertTrue(lockState.isUnlocked, "Lock should be unlocked");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Force Finalize Skips Rewards
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ForceFinalize_SkipsRewards() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Create lock and vote
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Force finalize (no rewards)
        _forceFinalizeCurrentEpoch();

        // ═══════════════════════════════════════════════════════════════════
        // Verify No Rewards Allocated
        // ═══════════════════════════════════════════════════════════════════
        
        EpochSnapshot memory epochState = captureEpochState(currentEpoch);
        assertEq(epochState.totalRewardsAllocated, 0, "No rewards allocated");
        assertEq(epochState.totalSubsidiesAllocated, 0, "No subsidies allocated");
        // ForceFinalized is different from Finalized
        assertTrue(epochState.state == DataTypes.EpochState.ForceFinalized, "Epoch should be force finalized");

        // ═══════════════════════════════════════════════════════════════════
        // Verify Claims Revert (epoch is ForceFinalized, not claimable)
        // ═══════════════════════════════════════════════════════════════════
        
        // ForceFinalized epochs have no rewards - claims will revert with EpochNotFinalized
        // because only Finalized state allows claims
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Decay Verification with Exact Math
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DecayVerification_ExactMath() public {
        uint128 startEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(startEpoch + 4);
        uint128 mocaAmount = 200 ether;
        uint128 esMocaAmount = 200 ether;

        // Create lock
        _fundUserWithMoca(voter1, mocaAmount);
        _fundUserWithEsMoca(voter1, esMocaAmount);
        _createLock(voter1, mocaAmount, esMocaAmount, expiry);

        // Calculate expected values using formula
        uint128 lockPrincipal = mocaAmount + esMocaAmount;
        uint128 slope = lockPrincipal / MAX_LOCK_DURATION;

        // ═══════════════════════════════════════════════════════════════════
        // Verify Decay by Warping Through Epochs
        // ═══════════════════════════════════════════════════════════════════
        
        // Epoch 10 (start)
        uint128 epochEnd10 = getEpochEndTimestamp(startEpoch);
        uint128 expectedVP10 = slope * (expiry - epochEnd10);
        uint128 actualVP10 = veMoca.balanceAtEpochEnd(voter1, startEpoch, false);
        assertEq(actualVP10, expectedVP10, "VP epoch 10 exact");

        // Warp to epoch 11
        _warpToEpoch(startEpoch + 1);
        uint128 epochEnd11 = getEpochEndTimestamp(startEpoch + 1);
        uint128 expectedVP11 = slope * (expiry - epochEnd11);
        uint128 actualVP11 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 1, false);
        assertEq(actualVP11, expectedVP11, "VP epoch 11 exact");
        assertTrue(actualVP11 < actualVP10, "VP should decay");

        // Warp to epoch 12
        _warpToEpoch(startEpoch + 2);
        uint128 epochEnd12 = getEpochEndTimestamp(startEpoch + 2);
        uint128 expectedVP12 = slope * (expiry - epochEnd12);
        uint128 actualVP12 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 2, false);
        assertEq(actualVP12, expectedVP12, "VP epoch 12 exact");

        // Warp to epoch 13
        _warpToEpoch(startEpoch + 3);
        uint128 epochEnd13 = getEpochEndTimestamp(startEpoch + 3);
        uint128 expectedVP13 = slope * (expiry - epochEnd13);
        uint128 actualVP13 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 3, false);
        assertEq(actualVP13, expectedVP13, "VP epoch 13 exact");

        // Warp to epoch 14 (at expiry)
        _warpToEpoch(startEpoch + 4);
        uint128 actualVP14 = veMoca.balanceAtEpochEnd(voter1, startEpoch + 4, false);
        assertEq(actualVP14, 0, "VP epoch 14 (expiry) = 0");
    }
}

