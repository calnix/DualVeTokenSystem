// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IntegrationTestHarness} from "./IntegrationTestHarness.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {Events} from "../../../src/libraries/Events.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/**
 * @title E2E_Delegation_Test
 * @notice End-to-end integration tests for delegation flow
 * @dev Tests delegate registration via VC, lock delegation via veMoca, and delegated voting
 */
contract E2E_Delegation_Test is IntegrationTestHarness {

    function setUp() public override {
        super.setUp();
        // Create 5 pools for testing
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Registration Syncs with VotingEscrowMoca
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_RegisterDelegate_SyncsWithVeMoca() public {
        uint128 feePct = 1000; // 10%

        // Capture before state
        bool isRegisteredBefore = veMoca.isRegisteredDelegate(delegate1);
        DelegateSnapshot memory delegateBefore = captureDelegateState(delegate1);

        assertFalse(isRegisteredBefore, "Should not be registered before");
        assertFalse(delegateBefore.isRegistered, "VC should not have delegate registered");

        // Register delegate via VotingController
        vm.deal(delegate1, delegateRegistrationFee);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateRegistered(delegate1, feePct);
        
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(feePct);

        // Capture after state
        bool isRegisteredAfter = veMoca.isRegisteredDelegate(delegate1);
        DelegateSnapshot memory delegateAfter = captureDelegateState(delegate1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Sync Between VC and veMoca
        // ═══════════════════════════════════════════════════════════════════
        
        assertTrue(isRegisteredAfter, "veMoca should show delegate as registered");
        assertTrue(delegateAfter.isRegistered, "VC should have delegate registered");
        assertEq(delegateAfter.currentFeePct, feePct, "Fee percentage should match");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Registration Pays Fee
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_RegisterDelegate_PaysFee() public {
        uint128 feePct = 1500; // 15%

        // Capture before state
        GlobalCountersSnapshot memory globalBefore = captureGlobalCounters();
        uint256 vcBalanceBefore = address(votingController).balance;
        
        vm.deal(delegate1, delegateRegistrationFee);
        uint256 delegateBalanceBefore = delegate1.balance;

        // Register delegate
        vm.prank(delegate1);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(feePct);

        // Capture after state
        GlobalCountersSnapshot memory globalAfter = captureGlobalCounters();
        uint256 vcBalanceAfter = address(votingController).balance;
        uint256 delegateBalanceAfter = delegate1.balance;

        // ═══════════════════════════════════════════════════════════════════
        // Verify Fee Collection
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(vcBalanceAfter, vcBalanceBefore + delegateRegistrationFee, "VC should receive fee");
        assertEq(delegateBalanceAfter, delegateBalanceBefore - delegateRegistrationFee, "Delegate should pay fee");
        assertEq(globalAfter.totalRegistrationFeesCollected, globalBefore.totalRegistrationFeesCollected + uint128(delegateRegistrationFee), "Global counter should increase");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Lock - Next Epoch Effect
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegateLock_NextEpochEffect() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Register delegate first
        _registerDelegate(delegate1, 1000);

        // Create lock for delegator
        _fundUserWithMoca(delegator1, mocaAmount);
        _fundUserWithEsMoca(delegator1, esMocaAmount);
        bytes32 lockId = _createLock(delegator1, mocaAmount, esMocaAmount, expiry);

        // Capture voting power before delegation (current epoch only - can't query future)
        uint128 userVPCurrentBefore = veMoca.balanceAtEpochEnd(delegator1, currentEpoch, false);
        uint128 delegateVPCurrentBefore = veMoca.balanceAtEpochEnd(delegate1, currentEpoch, true);

        assertTrue(userVPCurrentBefore > 0, "User should have VP before delegation");
        assertEq(delegateVPCurrentBefore, 0, "Delegate should have no VP before");

        // Delegate the lock
        _delegateLock(delegator1, lockId, delegate1);

        // Capture voting power after delegation (current epoch should be unchanged)
        uint128 userVPCurrentAfter = veMoca.balanceAtEpochEnd(delegator1, currentEpoch, false);
        uint128 delegateVPCurrentAfter = veMoca.balanceAtEpochEnd(delegate1, currentEpoch, true);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Current Epoch Unchanged
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(userVPCurrentAfter, userVPCurrentBefore, "User current epoch VP unchanged");
        assertEq(delegateVPCurrentAfter, 0, "Delegate current epoch VP still 0");

        // ═══════════════════════════════════════════════════════════════════
        // Warp to Next Epoch to Verify Delegation Takes Effect
        // ═══════════════════════════════════════════════════════════════════
        
        _warpToEpoch(currentEpoch + 1);
        uint128 nextEpoch = getCurrentEpochNumber();

        uint128 userVPNextAfter = veMoca.balanceAtEpochEnd(delegator1, nextEpoch, false);
        uint128 delegateVPNextAfter = veMoca.balanceAtEpochEnd(delegate1, nextEpoch, true);

        // Next epoch: user loses VP, delegate gains VP
        assertEq(userVPNextAfter, 0, "User next epoch VP should be 0");
        assertTrue(delegateVPNextAfter > 0, "Delegate next epoch VP should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegated Voting Uses Correct Power
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegatedVoting_UsesCorrectPower() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Create lock with delegation
        _fundUserWithMoca(delegator1, mocaAmount);
        _fundUserWithEsMoca(delegator1, esMocaAmount);
        _createLockWithDelegation(delegator1, delegate1, mocaAmount, esMocaAmount, expiry);

        // Warp to next epoch where delegation is effective
        _warpToEpoch(currentEpoch + 1);
        uint128 voteEpoch = getCurrentEpochNumber();

        // Get delegate's delegated VP
        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        assertTrue(delegateVP > 0, "Delegate should have delegated VP");

        // Capture before state
        PoolSnapshot memory beforePool = capturePoolState(1);

        // Delegate votes with delegated power
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        // Capture after state
        PoolSnapshot memory afterPool = capturePoolState(1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Vote Uses Delegated VP
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool.totalVotes, beforePool.totalVotes + delegateVP, "Pool should have delegate's VP");

        // Verify delegate epoch data tracking
        (uint128 delegateVotesSpent,) = votingController.delegateEpochData(voteEpoch, delegate1);
        assertEq(delegateVotesSpent, delegateVP, "Delegate votes spent should match VP");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Multiple Delegators to Single Delegate
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_MultiDelegator_SingleDelegate() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Create locks for multiple delegators with different amounts
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        _fundUserWithMoca(delegator2, 200 ether);
        _fundUserWithEsMoca(delegator2, 200 ether);
        _createLockWithDelegation(delegator2, delegate1, 200 ether, 200 ether, expiry);

        _fundUserWithMoca(delegator3, 50 ether);
        _fundUserWithEsMoca(delegator3, 50 ether);
        _createLockWithDelegation(delegator3, delegate1, 50 ether, 50 ether, expiry);

        // Warp to next epoch
        _warpToEpoch(currentEpoch + 1);
        uint128 voteEpoch = getCurrentEpochNumber();

        // Get individual specific delegated balances
        uint128 d1Specific = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator1, delegate1, voteEpoch);
        uint128 d2Specific = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator2, delegate1, voteEpoch);
        uint128 d3Specific = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator3, delegate1, voteEpoch);

        // Get delegate's total delegated VP
        uint128 delegateTotalVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Delegate VP = Sum of All Delegated Locks
        // ═══════════════════════════════════════════════════════════════════
        
        assertTrue(d1Specific > 0, "Delegator1 specific balance should be positive");
        assertTrue(d2Specific > 0, "Delegator2 specific balance should be positive");
        assertTrue(d3Specific > 0, "Delegator3 specific balance should be positive");

        // Delegate total should equal sum of specific balances
        assertEq(delegateTotalVP, d1Specific + d2Specific + d3Specific, "Delegate total = sum of specific");

        // Delegate can vote with full delegated VP
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateTotalVP));

        PoolSnapshot memory pool = capturePoolState(1);
        assertEq(pool.totalVotes, delegateTotalVP, "Pool votes = delegate total VP");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Specific Delegated Balance Tracking
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_SpecificDelegatedBalance() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Create lock with delegation
        _fundUserWithMoca(delegator1, mocaAmount);
        _fundUserWithEsMoca(delegator1, esMocaAmount);
        _createLockWithDelegation(delegator1, delegate1, mocaAmount, esMocaAmount, expiry);

        // Warp to next epoch
        _warpToEpoch(currentEpoch + 1);
        uint128 voteEpoch = getCurrentEpochNumber();

        // Get specific delegated balance
        uint128 specificBalance = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator1, delegate1, voteEpoch);

        // Calculate expected VP
        uint128 expectedVP = calculateVotingPowerAtEpochEnd(mocaAmount, esMocaAmount, expiry, voteEpoch);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Exact Specific Delegated Balance
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(specificBalance, expectedVP, "Specific delegated balance should match expected VP");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Undelegate Lock - Next Epoch Effect
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_UndelegateLock_NextEpochEffect() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Register delegate and create delegated lock
        _registerDelegate(delegate1, 1000);
        _fundUserWithMoca(delegator1, mocaAmount);
        _fundUserWithEsMoca(delegator1, esMocaAmount);
        bytes32 lockId = _createLockWithDelegation(delegator1, delegate1, mocaAmount, esMocaAmount, expiry);

        // Warp to next epoch where delegation is effective
        _warpToEpoch(currentEpoch + 1);
        uint128 delegatedEpoch = getCurrentEpochNumber();

        // Verify delegation is effective
        uint128 delegateVPBefore = veMoca.balanceAtEpochEnd(delegate1, delegatedEpoch, true);
        assertTrue(delegateVPBefore > 0, "Delegate should have VP");

        // Undelegate the lock
        _undelegateLock(delegator1, lockId);

        // Check current epoch (delegation still effective for current epoch)
        uint128 delegateVPCurrentAfter = veMoca.balanceAtEpochEnd(delegate1, delegatedEpoch, true);
        assertEq(delegateVPCurrentAfter, delegateVPBefore, "Current epoch VP unchanged");

        // ═══════════════════════════════════════════════════════════════════
        // Warp to Next Epoch to Verify Undelegation Takes Effect
        // ═══════════════════════════════════════════════════════════════════
        
        _warpToEpoch(delegatedEpoch + 1);
        uint128 nextEpoch = getCurrentEpochNumber();
        
        uint128 delegateVPNextAfter = veMoca.balanceAtEpochEnd(delegate1, nextEpoch, true);
        uint128 userVPNextAfter = veMoca.balanceAtEpochEnd(delegator1, nextEpoch, false);

        assertEq(delegateVPNextAfter, 0, "Delegate next epoch VP should be 0");
        assertTrue(userVPNextAfter > 0, "User next epoch VP should be restored");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Switch Delegate
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_SwitchDelegate() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Register both delegates
        _registerDelegate(delegate1, 1000);
        _registerDelegate(delegate2, 1500);

        // Create lock delegated to delegate1
        _fundUserWithMoca(delegator1, mocaAmount);
        _fundUserWithEsMoca(delegator1, esMocaAmount);
        bytes32 lockId = _createLockWithDelegation(delegator1, delegate1, mocaAmount, esMocaAmount, expiry);

        // Warp to next epoch where delegation takes effect
        _warpToEpoch(currentEpoch + 1);
        uint128 delegatedEpoch = getCurrentEpochNumber();

        // Verify delegate1 has power
        uint128 d1VPBefore = veMoca.balanceAtEpochEnd(delegate1, delegatedEpoch, true);
        assertTrue(d1VPBefore > 0, "Delegate1 should have VP");

        // Switch to delegate2
        vm.prank(delegator1);
        veMoca.delegationAction(lockId, delegate2, DataTypes.DelegationType.Switch);

        // Current epoch: delegate1 still has power
        uint128 d1VPCurrentAfter = veMoca.balanceAtEpochEnd(delegate1, delegatedEpoch, true);
        assertEq(d1VPCurrentAfter, d1VPBefore, "Delegate1 current epoch unchanged");

        // ═══════════════════════════════════════════════════════════════════
        // Warp to Next Epoch to Verify Switch Takes Effect
        // ═══════════════════════════════════════════════════════════════════
        
        _warpToEpoch(delegatedEpoch + 1);
        uint128 nextEpoch = getCurrentEpochNumber();
        
        uint128 d1VPNextAfter = veMoca.balanceAtEpochEnd(delegate1, nextEpoch, true);
        uint128 d2VPNextAfter = veMoca.balanceAtEpochEnd(delegate2, nextEpoch, true);

        assertEq(d1VPNextAfter, 0, "Delegate1 next epoch VP should be 0");
        assertTrue(d2VPNextAfter > 0, "Delegate2 next epoch VP should be positive");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Unregister Delegate Blocked with Active Votes
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_UnregisterDelegate_BlockedWithVotes() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;

        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Create delegated lock and warp to next epoch
        _fundUserWithMoca(delegator1, mocaAmount);
        _fundUserWithEsMoca(delegator1, esMocaAmount);
        _createLockWithDelegation(delegator1, delegate1, mocaAmount, esMocaAmount, expiry);

        _warpToEpoch(currentEpoch + 1);

        // Vote with delegated power
        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, getCurrentEpochNumber(), true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Cannot Unregister with Active Votes
        // ═══════════════════════════════════════════════════════════════════
        
        vm.expectRevert(Errors.CannotUnregisterWithActiveVotes.selector);
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Unregister Delegate Succeeds with No Votes
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_UnregisterDelegate_Succeeds() public {
        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Verify registered in both VC and veMoca
        assertTrue(veMoca.isRegisteredDelegate(delegate1), "Should be registered in veMoca");
        DelegateSnapshot memory beforeState = captureDelegateState(delegate1);
        assertTrue(beforeState.isRegistered, "Should be registered in VC");

        // Unregister
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateUnregistered(delegate1);
        
        vm.prank(delegate1);
        votingController.unregisterAsDelegate();

        // ═══════════════════════════════════════════════════════════════════
        // Verify Unregistration Syncs with veMoca
        // ═══════════════════════════════════════════════════════════════════
        
        assertFalse(veMoca.isRegisteredDelegate(delegate1), "Should be unregistered in veMoca");
        DelegateSnapshot memory afterState = captureDelegateState(delegate1);
        assertFalse(afterState.isRegistered, "Should be unregistered in VC");
        assertEq(afterState.currentFeePct, 0, "Fee should be cleared");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Fee Immediate Decrease
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegateFee_ImmediateDecrease() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 initialFee = 2000; // 20%
        uint128 newFee = 1000; // 10%

        // Register delegate with initial fee
        _registerDelegate(delegate1, initialFee);

        // Verify initial fee
        DelegateSnapshot memory beforeState = captureDelegateState(delegate1);
        assertEq(beforeState.currentFeePct, initialFee, "Initial fee should be set");

        // Decrease fee
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateFeeDecreased(delegate1, initialFee, newFee);
        
        vm.prank(delegate1);
        votingController.updateDelegateFee(newFee);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Immediate Effect
        // ═══════════════════════════════════════════════════════════════════
        
        DelegateSnapshot memory afterState = captureDelegateState(delegate1);
        assertEq(afterState.currentFeePct, newFee, "New fee should be immediate");
        assertEq(afterState.nextFeePct, 0, "No pending fee");
        assertEq(afterState.nextFeePctEpoch, 0, "No pending epoch");

        // Historical fee for current epoch should be new fee
        uint128 historicalFee = votingController.delegateHistoricalFeePcts(delegate1, currentEpoch);
        assertEq(historicalFee, newFee, "Historical fee should be updated immediately");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Fee Delayed Increase
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegateFee_DelayedIncrease() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 initialFee = 1000; // 10%
        uint128 newFee = 2000; // 20%

        // Register delegate with initial fee
        _registerDelegate(delegate1, initialFee);

        // Increase fee (should be delayed)
        vm.prank(delegate1);
        votingController.updateDelegateFee(newFee);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Delayed Effect
        // ═══════════════════════════════════════════════════════════════════
        
        DelegateSnapshot memory afterState = captureDelegateState(delegate1);
        assertEq(afterState.currentFeePct, initialFee, "Current fee unchanged");
        assertEq(afterState.nextFeePct, newFee, "Next fee scheduled");
        assertEq(afterState.nextFeePctEpoch, currentEpoch + feeIncreaseDelayEpochs, "Scheduled for delay epochs");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegate Fee Recorded on Vote
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegateFee_RecordedOnVote() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 1500; // 15%

        // Register delegate
        _registerDelegate(delegate1, feePct);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Warp to next epoch
        _warpToEpoch(currentEpoch + 1);
        uint128 voteEpoch = getCurrentEpochNumber();

        // Verify no historical fee recorded yet
        uint128 feeBefore = votingController.delegateHistoricalFeePcts(delegate1, voteEpoch);
        assertEq(feeBefore, 0, "No historical fee before vote");

        // Vote
        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Fee Recorded on Vote
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 feeAfter = votingController.delegateHistoricalFeePcts(delegate1, voteEpoch);
        assertEq(feeAfter, feePct, "Historical fee should be recorded");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegated Vote Migration
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_DelegatedVote_Migration() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Warp to next epoch
        _warpToEpoch(currentEpoch + 1);
        uint128 voteEpoch = getCurrentEpochNumber();

        // Vote for pool 1
        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        // Capture before migration
        PoolSnapshot memory beforePool1 = capturePoolState(1);
        PoolSnapshot memory beforePool2 = capturePoolState(2);

        // Migrate votes as delegate
        vm.prank(delegate1);
        votingController.migrateVotes(_toArray(1), _toArray(2), _toArray(delegateVP), true);

        // Capture after migration
        PoolSnapshot memory afterPool1 = capturePoolState(1);
        PoolSnapshot memory afterPool2 = capturePoolState(2);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Delegated Vote Migration
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterPool1.totalVotes, beforePool1.totalVotes - delegateVP, "Source pool decreased");
        assertEq(afterPool2.totalVotes, beforePool2.totalVotes + delegateVP, "Destination pool increased");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: User with Multiple Locks - Split Delegation
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_SingleDelegator_SplitDelegation() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Register delegate
        _registerDelegate(delegate1, 1000);

        // Create two locks for same user - one delegated, one personal
        _fundUserWithMoca(delegator1, 200 ether);
        _fundUserWithEsMoca(delegator1, 200 ether);

        // Lock 1: Personal (no delegation)
        bytes32 lock1 = _createLock(delegator1, 100 ether, 100 ether, expiry);

        // Lock 2: Delegated to delegate1
        bytes32 lock2 = _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Warp to next epoch
        _warpToEpoch(currentEpoch + 1);
        uint128 voteEpoch = getCurrentEpochNumber();

        // Get VPs
        uint128 userPersonalVP = veMoca.balanceAtEpochEnd(delegator1, voteEpoch, false);
        uint128 delegateTotalVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Personal and Delegated VP Tracked Separately
        // ═══════════════════════════════════════════════════════════════════
        
        assertTrue(userPersonalVP > 0, "User should have personal VP from lock1");
        assertTrue(delegateTotalVP > 0, "Delegate should have VP from lock2");

        // User can vote with personal VP
        _vote(delegator1, _toArray(1), _toArray(userPersonalVP));

        // Delegate can vote with delegated VP
        _voteAsDelegated(delegate1, _toArray(2), _toArray(delegateTotalVP));

        // Verify both pools have correct votes
        PoolSnapshot memory pool1 = capturePoolState(1);
        PoolSnapshot memory pool2 = capturePoolState(2);
        assertEq(pool1.totalVotes, userPersonalVP, "Pool 1 = personal VP");
        assertEq(pool2.totalVotes, delegateTotalVP, "Pool 2 = delegated VP");
    }
}

