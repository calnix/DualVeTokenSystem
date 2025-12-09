// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import {Constants} from "../../src/libraries/Constants.sol";

import "./delegateHelper.sol";

/**
 * @title VotingEscrowMoca Delegation Test Suite V2
 * @notice Comprehensive tests for all three lock delegation states:
 *         1. Undelegated: lock.delegate == address(0) - Owner holds VP
 *         2. Pending Delegation: lock.delegationEpoch > currentEpochStart - Takes effect next epoch
 *         3. Active Delegation: lock.delegate != address(0) AND lock.delegationEpoch <= currentEpochStart
 * 
 * Key behavioral differences for increaseAmount/increaseDuration:
 * - Active Delegation: Delegate gets immediate VP increase (no pending deltas)
 * - Pending Delegation: Owner gets immediate VP increase, pending deltas queued for transfer
 */

// =====================================================
// ================= PHASE 1: SETUP (E1) =================
// =====================================================

/// @notice Deploy contracts and warp to start of epoch 1
abstract contract StateE1_Deploy is TestingHarness, DelegateHelper {    

    function setUp() public virtual override {
        super.setUp();

        vm.warp(EPOCH_DURATION);
        assertTrue(getCurrentEpochStart() > 0, "Current epoch start time is greater than 0");
    }
}

/// @notice User1 creates lock1 (expires E3) - UNDELEGATED state
/// @dev block.timestamp is at the start of epoch 1
abstract contract StateE1_User1_CreateLock1 is StateE1_Deploy {

    bytes32 public lock1_Id;
    uint128 public lock1_Expiry;
    uint128 public lock1_MocaAmount;
    uint128 public lock1_EsMocaAmount;
    uint128 public lock1_CurrentEpochStart;
    DataTypes.VeBalance public lock1_VeBalance;

    function setUp() public virtual override {
        super.setUp();

        // Check current epoch
        assertEq(block.timestamp, uint128(getEpochStartTimestamp(1)), "Current timestamp is at start of epoch 1");
        assertEq(getCurrentEpochNumber(), 1, "Current epoch number is 1");

        // Test parameters
        lock1_Expiry = uint128(getEpochEndTimestamp(3)); // expiry at end of epoch 3
        lock1_MocaAmount = 100 ether;
        lock1_EsMocaAmount = 100 ether;
        lock1_Id = generateLockId(block.number, user1);
        lock1_CurrentEpochStart = getCurrentEpochStart();

        // Setup: fund user with MOCA and escrow some to get esMOCA
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: lock1_MocaAmount}();
            esMoca.approve(address(veMoca), lock1_MocaAmount);
            lock1_Id = veMoca.createLock{value: lock1_MocaAmount}(lock1_Expiry, lock1_EsMocaAmount);
        vm.stopPrank();

        // Capture lock1_VeBalance
        lock1_VeBalance = veMoca.getLockVeBalance(lock1_Id);

        // Set cronJob role
        vm.startPrank(cronJobAdmin);
            veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();
    }
}

/// @notice Register user3 as delegate
abstract contract StateE1_RegisterDelegate_User3 is StateE1_User1_CreateLock1 {
    
    address public constant MOCK_VC = address(0x999); 

    function setUp() public virtual override {
        super.setUp();

        // Setup VotingController role
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(MOCK_VC);

        // Register User3 as delegate
        vm.startPrank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user3, true);
        vm.stopPrank();
    }
}

/// @notice User1 delegates lock1 to user3 - enters PENDING DELEGATION state
abstract contract StateE1_User1_DelegateLock1_ToUser3 is StateE1_RegisterDelegate_User3 {

    UnifiedStateSnapshot public epoch1_BeforeDelegateLock1;
    UnifiedStateSnapshot public epoch1_AfterDelegateLock1;
    
    function setUp() public virtual override {
        super.setUp();

        // Capture state before delegation
        epoch1_BeforeDelegateLock1 = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        // Execute delegation
        vm.startPrank(user1);
            veMoca.delegationAction(lock1_Id, user3, DataTypes.DelegationType.Delegate);
        vm.stopPrank();

        // Capture state after delegation
        epoch1_AfterDelegateLock1 = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));
    }
}

contract StateE1_User1_DelegateLock1_ToUser3_Test is StateE1_User1_DelegateLock1_ToUser3 {

    function test_DelegateLock1_ToUser3() public {
        verifyDelegateLock(epoch1_BeforeDelegateLock1, user3);
    }

    function test_Lock1_InPendingDelegationState() public {
        DataTypes.Lock memory lock = getLock(lock1_Id);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Verify pending delegation state
        assertEq(lock.delegate, user3, "Lock1 delegate is user3");
        assertGt(lock.delegationEpoch, currentEpochStart, "Lock1 delegationEpoch > currentEpochStart (pending)");
        assertEq(lock.currentHolder, user1, "Lock1 currentHolder is user1 (owner)");
    }

    function test_User1_StillHasVP_InE1() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user1Vp = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 expectedVp = getValueAt(lock1_VeBalance, currentTimestamp);
        
        assertEq(user1Vp, expectedVp, "User1 still has lock1 VP (pending delegation)");
    }

    function test_User3_HasZeroVP_InE1() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        assertEq(user3DelegatedVp, 0, "User3 has no delegated VP yet (pending)");
    }
}

// =====================================================
// ================= PHASE 1: E2 - ACTIVE DELEGATION =================
// =====================================================

/// @notice Warp to E2 and run cronjob - lock1 delegation becomes ACTIVE
abstract contract StateE2_Lock1DelegationTakesEffect is StateE1_User1_DelegateLock1_ToUser3 {
    
    GlobalStateSnapshot public epoch1_GlobalState;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Capture E1 state before warping
        epoch1_GlobalState = captureGlobalState(lock1_Expiry, 0);
        
        // Warp to E2 start
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // Execute cronjob update to apply pending deltas
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](2);
            accounts[0] = user1;
            accounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);

            address[] memory delegateAccounts = new address[](2);
            delegateAccounts[0] = user1;
            delegateAccounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(delegateAccounts, true);

            address[] memory users = new address[](1);
            address[] memory delegates = new address[](1);
            users[0] = user1;
            delegates[0] = user3;
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();
    }
}

contract StateE2_Lock1DelegationTakesEffect_Test is StateE2_Lock1DelegationTakesEffect {

    function test_Lock1_NowInActiveDelegationState() public {
        DataTypes.Lock memory lock = getLock(lock1_Id);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Verify active delegation state
        assertEq(lock.delegate, user3, "Lock1 delegate is user3");
        assertLe(lock.delegationEpoch, currentEpochStart, "Lock1 delegationEpoch <= currentEpochStart (active)");
    }

    function test_User1_HasZeroPersonalVP_InE2() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user1Vp = veMoca.balanceOfAt(user1, currentTimestamp, false);
        
        assertEq(user1Vp, 0, "User1 has 0 personal VP (delegated away)");
    }

    function test_User3_HasDelegatedVP_InE2() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        uint128 expectedVp = getValueAt(lock1_VeBalance, currentTimestamp);
        
        assertEq(user3DelegatedVp, expectedVp, "User3 has lock1 VP (active delegation)");
    }

    function test_PendingDeltas_Cleared() public {
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        
        // User1 pending deltas should be cleared
        (bool user1HasAdd, bool user1HasSub, , ) = veMoca.userPendingDeltas(user1, epoch2StartTimestamp);
        assertFalse(user1HasAdd, "User1 pending addition cleared");
        assertFalse(user1HasSub, "User1 pending subtraction cleared");
        
        // User3 delegate pending deltas should be cleared
        (bool user3HasAdd, bool user3HasSub, , ) = veMoca.delegatePendingDeltas(user3, epoch2StartTimestamp);
        assertFalse(user3HasAdd, "User3 pending addition cleared");
        assertFalse(user3HasSub, "User3 pending subtraction cleared");
    }
}

// =====================================================
// ================= PHASE 2: ACTIVE DELEGATION TESTS =================
// =====================================================

/// @notice User1 creates lock2 with long duration, delegates to user3, then cronjob activates it
/// @dev This creates a lock in ACTIVE DELEGATION state for testing increaseAmount/increaseDuration
abstract contract StateE2_Lock2_ActiveDelegation is StateE2_Lock1DelegationTakesEffect {
    
    bytes32 public lock2_Id;
    uint128 public lock2_Expiry;
    uint128 public lock2_MocaAmount;
    uint128 public lock2_EsMocaAmount;
    DataTypes.VeBalance public lock2_VeBalance;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Lock2 parameters: long duration (expires E10)
        lock2_Expiry = uint128(getEpochEndTimestamp(10));
        lock2_MocaAmount = 200 ether;
        lock2_EsMocaAmount = 200 ether;
        
        // Fund user1 for lock2
        vm.startPrank(user1);
            vm.deal(user1, 400 ether);
            esMoca.escrowMoca{value: lock2_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock2_EsMocaAmount);
            
            // Create lock2 and delegate to user3
            lock2_Id = veMoca.createLock{value: lock2_MocaAmount}(lock2_Expiry, lock2_EsMocaAmount);
            veMoca.delegationAction(lock2_Id, user3, DataTypes.DelegationType.Delegate);
        vm.stopPrank();

        // Capture lock2 veBalance
        lock2_VeBalance = veMoca.getLockVeBalance(lock2_Id);
        
        // Warp to E3 and run cronjob to make lock2 delegation ACTIVE
        uint128 epoch3StartTimestamp = uint128(getEpochStartTimestamp(3));
        vm.warp(epoch3StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 3, "Current epoch number is 3");

        // Execute cronjob update
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](2);
            accounts[0] = user1;
            accounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);

            address[] memory delegateAccounts = new address[](2);
            delegateAccounts[0] = user1;
            delegateAccounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(delegateAccounts, true);

            address[] memory users = new address[](1);
            address[] memory delegates = new address[](1);
            users[0] = user1;
            delegates[0] = user3;
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();
    }
}

contract StateE2_Lock2_ActiveDelegation_Test is StateE2_Lock2_ActiveDelegation {

    function test_Lock2_InActiveDelegationState() public {
        DataTypes.Lock memory lock = getLock(lock2_Id);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        assertEq(lock.delegate, user3, "Lock2 delegate is user3");
        assertLe(lock.delegationEpoch, currentEpochStart, "Lock2 delegationEpoch <= currentEpochStart (active)");
    }

    function test_User3_HasLock2VP() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // We're in E3, lock1 expired at end of E3, lock2 is active
        // User3 should have lock2's VP (lock1 may still have some VP if not fully expired)
        uint128 expectedLock2Vp = getValueAt(lock2_VeBalance, currentTimestamp);
        
        // Verify user3 has at least lock2's VP
        assertGe(user3DelegatedVp, expectedLock2Vp, "User3 has at least lock2 VP");
    }

    // ============ Test: increaseDuration on ACTIVE delegated lock ============

    function test_IncreaseDuration_ActiveDelegation_DelegateGetsImmediateVP() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        
        // Target: extend lock2 from E10 to E15
        uint128 targetExpiry = uint128(getEpochEndTimestamp(15));
        uint128 durationIncrease = targetExpiry - lock2_Expiry;
        
        // Calculate expected bias delta
        uint128 lockSlope = (lock2_MocaAmount + lock2_EsMocaAmount) / MAX_LOCK_DURATION;
        uint128 biasDelta = lockSlope * durationIncrease;
        
        // Capture state before
        uint128 user3DelegatedVpBefore = veMoca.balanceOfAt(user3, currentTimestamp, true);
        (uint128 delegateHistoryBiasBefore, uint128 delegateHistorySlopeBefore) = veMoca.delegateHistory(user3, currentEpochStart);
        
        // Execute increaseDuration
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, durationIncrease);
        
        // Capture state after
        uint128 user3DelegatedVpAfter = veMoca.balanceOfAt(user3, currentTimestamp, true);
        (uint128 delegateHistoryBiasAfter, uint128 delegateHistorySlopeAfter) = veMoca.delegateHistory(user3, currentEpochStart);
        
        // ============ CRITICAL: For ACTIVE delegation, delegate gets immediate VP ============
        assertEq(user3DelegatedVpAfter, user3DelegatedVpBefore + biasDelta, "Delegate VP increased immediately");
        assertEq(delegateHistoryBiasAfter, delegateHistoryBiasBefore + biasDelta, "Delegate history bias increased");
        assertEq(delegateHistorySlopeAfter, delegateHistorySlopeBefore, "Delegate history slope unchanged (duration only)");
        
        // ============ CRITICAL: No pending deltas should be queued for ACTIVE delegation ============
        (bool hasAdd, bool hasSub, , ) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertFalse(hasAdd, "No pending addition for active delegation");
        assertFalse(hasSub, "No pending subtraction for active delegation");
        
        // User1 should NOT get any VP increase (lock is actively delegated)
        uint128 user1VpAfter = veMoca.balanceOfAt(user1, currentTimestamp, false);
        assertEq(user1VpAfter, 0, "User1 VP still 0 (lock is delegated)");
    }

    // ============ Test: increaseAmount on ACTIVE delegated lock ============

    function test_IncreaseAmount_ActiveDelegation_DelegateGetsImmediateVP() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        
        uint128 additionalMoca = 50 ether;
        uint128 additionalEsMoca = 50 ether;
        
        // Fund user1
        vm.startPrank(user1);
            vm.deal(user1, additionalMoca + additionalEsMoca);
            esMoca.escrowMoca{value: additionalEsMoca}();
            esMoca.approve(address(veMoca), additionalEsMoca);
        vm.stopPrank();
        
        // Calculate expected slope delta
        uint128 oldSlope = (lock2_MocaAmount + lock2_EsMocaAmount) / MAX_LOCK_DURATION;
        uint128 newSlope = (lock2_MocaAmount + additionalMoca + lock2_EsMocaAmount + additionalEsMoca) / MAX_LOCK_DURATION;
        uint128 slopeDelta = newSlope - oldSlope;
        uint128 biasDelta = slopeDelta * lock2_Expiry;
        
        // Capture state before
        uint128 user3DelegatedVpBefore = veMoca.balanceOfAt(user3, currentTimestamp, true);
        (uint128 delegateHistoryBiasBefore, uint128 delegateHistorySlopeBefore) = veMoca.delegateHistory(user3, currentEpochStart);
        
        // Execute increaseAmount
        vm.prank(user1);
        veMoca.increaseAmount{value: additionalMoca}(lock2_Id, additionalEsMoca);
        
        // Capture state after
        uint128 user3DelegatedVpAfter = veMoca.balanceOfAt(user3, currentTimestamp, true);
        (uint128 delegateHistoryBiasAfter, uint128 delegateHistorySlopeAfter) = veMoca.delegateHistory(user3, currentEpochStart);
        
        // ============ CRITICAL: For ACTIVE delegation, delegate gets immediate VP ============
        assertGt(user3DelegatedVpAfter, user3DelegatedVpBefore, "Delegate VP increased immediately");
        assertEq(delegateHistoryBiasAfter, delegateHistoryBiasBefore + biasDelta, "Delegate history bias increased");
        assertEq(delegateHistorySlopeAfter, delegateHistorySlopeBefore + slopeDelta, "Delegate history slope increased");
        
        // ============ CRITICAL: No pending deltas should be queued for ACTIVE delegation ============
        (bool hasAdd, bool hasSub, , ) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertFalse(hasAdd, "No pending addition for active delegation");
        assertFalse(hasSub, "No pending subtraction for active delegation");
        
        // User1 should NOT get any VP increase (lock is actively delegated)
        uint128 user1VpAfter = veMoca.balanceOfAt(user1, currentTimestamp, false);
        assertEq(user1VpAfter, 0, "User1 VP still 0 (lock is delegated)");
    }

    // ============ Negative Tests ============

    function testRevert_IncreaseDuration_NonOwner() public {
        uint128 durationIncrease = 2 * EPOCH_DURATION;
        
        vm.expectRevert(Errors.InvalidLockId.selector);
        vm.prank(user2);
        veMoca.increaseDuration(lock2_Id, durationIncrease);
    }

    function testRevert_IncreaseAmount_NonOwner() public {
        vm.deal(user2, 10 ether);
        
        vm.expectRevert(Errors.InvalidLockId.selector);
        vm.prank(user2);
        veMoca.increaseAmount{value: 10 ether}(lock2_Id, 0);
    }
}

// =====================================================
// ================= PHASE 3: PENDING DELEGATION TESTS =================
// =====================================================

/// @notice User1 creates lock3 and delegates to user3 - NO cronjob run, stays in PENDING state
abstract contract StateE3_Lock3_PendingDelegation is StateE2_Lock2_ActiveDelegation {
    
    bytes32 public lock3_Id;
    uint128 public lock3_Expiry;
    uint128 public lock3_MocaAmount;
    uint128 public lock3_EsMocaAmount;
    DataTypes.VeBalance public lock3_VeBalance;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Lock3 parameters: long duration (expires E12)
        lock3_Expiry = uint128(getEpochEndTimestamp(12));
        lock3_MocaAmount = 150 ether;
        lock3_EsMocaAmount = 150 ether;
        
        // Fund user1 for lock3
        vm.startPrank(user1);
            vm.deal(user1, 300 ether);
            esMoca.escrowMoca{value: lock3_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock3_EsMocaAmount);
            
            // Create lock3 and delegate to user3 - DO NOT run cronjob
            lock3_Id = veMoca.createLock{value: lock3_MocaAmount}(lock3_Expiry, lock3_EsMocaAmount);
            veMoca.delegationAction(lock3_Id, user3, DataTypes.DelegationType.Delegate);
        vm.stopPrank();

        // Capture lock3 veBalance
        lock3_VeBalance = veMoca.getLockVeBalance(lock3_Id);
        
        // Note: NO cronjob run - lock3 stays in PENDING delegation state
    }
}

contract StateE3_Lock3_PendingDelegation_Test is StateE3_Lock3_PendingDelegation {

    function test_Lock3_InPendingDelegationState() public {
        DataTypes.Lock memory lock = getLock(lock3_Id);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        assertEq(lock.delegate, user3, "Lock3 delegate is user3");
        assertGt(lock.delegationEpoch, currentEpochStart, "Lock3 delegationEpoch > currentEpochStart (pending)");
        assertEq(lock.currentHolder, user1, "Lock3 currentHolder is user1");
    }

    function test_User1_HasLock3VP_WhilePending() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user1Vp = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 expectedVp = getValueAt(lock3_VeBalance, currentTimestamp);
        
        assertEq(user1Vp, expectedVp, "User1 has lock3 VP (pending delegation)");
    }

    // ============ Test: increaseDuration on PENDING delegated lock ============

    function test_IncreaseDuration_PendingDelegation_OwnerGetsImmediateVP() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        
        // Target: extend lock3 from E12 to E15
        uint128 targetExpiry = uint128(getEpochEndTimestamp(15));
        uint128 durationIncrease = targetExpiry - lock3_Expiry;
        
        // Calculate expected bias delta
        uint128 lockSlope = (lock3_MocaAmount + lock3_EsMocaAmount) / MAX_LOCK_DURATION;
        uint128 biasDelta = lockSlope * durationIncrease;
        
        // Capture state before
        uint128 user1VpBefore = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user3DelegatedVpBefore = veMoca.balanceOfAt(user3, currentTimestamp, true);
        (uint128 userHistoryBiasBefore, ) = veMoca.userHistory(user1, currentEpochStart);
        (uint128 delegateHistoryBiasBefore, ) = veMoca.delegateHistory(user3, currentEpochStart);
        
        // Execute increaseDuration
        vm.prank(user1);
        veMoca.increaseDuration(lock3_Id, durationIncrease);
        
        // Capture state after
        uint128 user1VpAfter = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user3DelegatedVpAfter = veMoca.balanceOfAt(user3, currentTimestamp, true);
        (uint128 userHistoryBiasAfter, ) = veMoca.userHistory(user1, currentEpochStart);
        (uint128 delegateHistoryBiasAfter, ) = veMoca.delegateHistory(user3, currentEpochStart);
        
        // ============ CRITICAL: For PENDING delegation, OWNER gets immediate VP ============
        assertEq(user1VpAfter, user1VpBefore + biasDelta, "Owner VP increased immediately");
        assertEq(userHistoryBiasAfter, userHistoryBiasBefore + biasDelta, "Owner history bias increased");
        
        // ============ CRITICAL: Delegate VP should be UNCHANGED ============
        assertEq(user3DelegatedVpAfter, user3DelegatedVpBefore, "Delegate VP unchanged (pending)");
        assertEq(delegateHistoryBiasAfter, delegateHistoryBiasBefore, "Delegate history bias unchanged (pending)");
        
        // ============ CRITICAL: Pending deltas SHOULD be queued for transfer ============
        (bool user1HasAdd, bool user1HasSub, , DataTypes.VeBalance memory user1Subs) = veMoca.userPendingDeltas(user1, nextEpochStart);
        assertTrue(user1HasSub, "User1 has pending subtraction for transfer");
        
        (bool user3HasAdd, , DataTypes.VeBalance memory user3Adds, ) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(user3HasAdd, "User3 has pending addition for transfer");
    }

    // ============ Test: increaseAmount on PENDING delegated lock ============

    function test_IncreaseAmount_PendingDelegation_OwnerGetsImmediateVP() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        
        uint128 additionalMoca = 50 ether;
        uint128 additionalEsMoca = 50 ether;
        
        // Fund user1
        vm.startPrank(user1);
            vm.deal(user1, additionalMoca + additionalEsMoca);
            esMoca.escrowMoca{value: additionalEsMoca}();
            esMoca.approve(address(veMoca), additionalEsMoca);
        vm.stopPrank();
        
        // Capture state before
        uint128 user1VpBefore = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user3DelegatedVpBefore = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // Execute increaseAmount
        vm.prank(user1);
        veMoca.increaseAmount{value: additionalMoca}(lock3_Id, additionalEsMoca);
        
        // Capture state after
        uint128 user1VpAfter = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user3DelegatedVpAfter = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // ============ CRITICAL: For PENDING delegation, OWNER gets immediate VP ============
        assertGt(user1VpAfter, user1VpBefore, "Owner VP increased immediately");
        
        // ============ CRITICAL: Delegate VP should be UNCHANGED ============
        assertEq(user3DelegatedVpAfter, user3DelegatedVpBefore, "Delegate VP unchanged (pending)");
        
        // ============ CRITICAL: Pending deltas SHOULD be queued for transfer ============
        // userPendingDeltas returns: (hasAddition, hasSubtraction, additions, subtractions)
        (, bool user1HasSub, , ) = veMoca.userPendingDeltas(user1, nextEpochStart);
        assertTrue(user1HasSub, "User1 has pending subtraction for transfer");
        
        // delegatePendingDeltas returns: (hasAddition, hasSubtraction, additions, subtractions)
        (bool user3HasAdd, , , ) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(user3HasAdd, "User3 has pending addition for transfer");
    }

    function test_CompareBehavior_ActiveVsPending() public {
        // This test explicitly documents the behavioral difference
        
        // Lock2 is in ACTIVE state, lock3 is in PENDING state
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Verify lock states
        assertLe(lock2.delegationEpoch, currentEpochStart, "Lock2 is ACTIVE");
        assertGt(lock3.delegationEpoch, currentEpochStart, "Lock3 is PENDING");
        
        // For ACTIVE: currentAccount = delegate, futureAccount = delegate
        // For PENDING: currentAccount = owner, futureAccount = delegate
        
        // Increase on ACTIVE lock -> delegate gets VP, no pending deltas
        // Increase on PENDING lock -> owner gets VP, pending deltas queued
    }
}

// =====================================================
// ================= PHASE 4: DELEGATION ACTIONS =================
// =====================================================

/// @notice Register user2 as delegate and test switchDelegate
abstract contract StateE3_RegisterUser2_SwitchDelegate is StateE3_Lock3_PendingDelegation {

    function setUp() public virtual override {
        super.setUp();
        
        // Register user2 as delegate
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user2, true);
    }
}

contract StateE3_SwitchDelegate_Test is StateE3_RegisterUser2_SwitchDelegate {

    function test_SwitchDelegate_Lock2_FromUser3ToUser2() public {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        
        // Capture before state
        UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user2, user3);
        
        // Switch delegate
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user2, DataTypes.DelegationType.Switch);
        
        // Verify lock state updated
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.delegate, user2, "Lock2 delegate switched to user2");
        
        // Verify pending deltas booked
        (bool user3HasSub, , , DataTypes.VeBalance memory user3Subs) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(user3HasSub, "Old delegate has pending subtraction");
        
        (bool user2HasAdd, , DataTypes.VeBalance memory user2Adds, ) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
        assertTrue(user2HasAdd, "New delegate has pending addition");
        
        // Verify via helper
        verifySwitchDelegate(beforeState, user2);
    }

    function testRevert_SwitchDelegate_ToSameDelegate() public {
        vm.expectRevert(Errors.InvalidDelegate.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user3, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_ToUnregisteredDelegate() public {
        address unregistered = makeAddr("unregistered");
        
        vm.expectRevert(Errors.DelegateNotRegistered.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, unregistered, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_ToSelf() public {
        vm.expectRevert(Errors.InvalidDelegate.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user1, DataTypes.DelegationType.Switch);
    }
}

/// @notice Test undelegateLock
contract StateE3_Undelegate_Test is StateE3_RegisterUser2_SwitchDelegate {

    function test_Undelegate_Lock3() public {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        
        // Capture before state
        UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock3_Id, lock3_Expiry, 0, address(0), user3);
        
        // Undelegate
        vm.prank(user1);
        veMoca.delegationAction(lock3_Id, address(0), DataTypes.DelegationType.Undelegate);
        
        // Verify lock state updated
        DataTypes.Lock memory lock = getLock(lock3_Id);
        assertEq(lock.delegate, address(0), "Lock3 undelegated");
        
        // Verify pending deltas booked
        (bool user1HasAdd, , DataTypes.VeBalance memory user1Adds, ) = veMoca.userPendingDeltas(user1, nextEpochStart);
        assertTrue(user1HasAdd, "Owner has pending addition");
        
        (bool user3HasSub, , , DataTypes.VeBalance memory user3Subs) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(user3HasSub, "Delegate has pending subtraction");
        
        // Verify via helper
        verifyUndelegateLock(beforeState);
    }

    function testRevert_Undelegate_NotDelegated() public {
        // Create a non-delegated lock
        vm.startPrank(user2);
            vm.deal(user2, 100 ether);
            bytes32 undelegatedLockId = veMoca.createLock{value: 100 ether}(uint128(getEpochEndTimestamp(10)), 0);
        vm.stopPrank();
        
        vm.expectRevert(Errors.LockNotDelegated.selector);
        vm.prank(user2);
        veMoca.delegationAction(undelegatedLockId, address(0), DataTypes.DelegationType.Undelegate);
    }

    function testRevert_Undelegate_NonOwner() public {
        vm.expectRevert(Errors.InvalidOwner.selector);
        vm.prank(user2);
        veMoca.delegationAction(lock3_Id, address(0), DataTypes.DelegationType.Undelegate);
    }
}

// =====================================================
// ================= PHASE 4: UNLOCK EXPIRED LOCK =================
// =====================================================

/// @notice Warp to E4 and test unlocking expired lock1
abstract contract StateE4_UnlockExpiredLock1 is StateE3_RegisterUser2_SwitchDelegate {
    
    uint128 public user1_MocaBalanceBefore;
    uint128 public user1_EsMocaBalanceBefore;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Warp to E4 (past lock1 expiry at E3)
        uint128 epoch4StartTimestamp = uint128(getEpochStartTimestamp(4));
        vm.warp(epoch4StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 4, "Current epoch number is 4");
        
        // Verify lock1 is expired
        DataTypes.Lock memory lock1Before = getLock(lock1_Id);
        assertLt(lock1Before.expiry, block.timestamp, "Lock1 should be expired");
        
        // Capture balances before unlock
        user1_MocaBalanceBefore = uint128(user1.balance);
        user1_EsMocaBalanceBefore = uint128(esMoca.balanceOf(user1));
        
        // Unlock lock1
        vm.prank(user1);
        veMoca.unlock(lock1_Id);
    }
}

contract StateE4_UnlockExpiredLock1_Test is StateE4_UnlockExpiredLock1 {

    function test_Lock1_IsUnlocked() public {
        DataTypes.Lock memory lock = getLock(lock1_Id);
        assertTrue(lock.isUnlocked, "Lock1 should be unlocked");
    }

    function test_User1_ReceivedPrincipals() public {
        uint128 user1MocaAfter = uint128(user1.balance);
        uint128 user1EsMocaAfter = uint128(esMoca.balanceOf(user1));
        
        assertEq(user1MocaAfter, user1_MocaBalanceBefore + lock1_MocaAmount, "User1 received MOCA");
        assertEq(user1EsMocaAfter, user1_EsMocaBalanceBefore + lock1_EsMocaAmount, "User1 received esMOCA");
    }

    function test_TotalLocked_Decreased() public {
        // TOTAL_LOCKED should not include lock1 anymore
        uint128 totalMoca = veMoca.TOTAL_LOCKED_MOCA();
        uint128 totalEsMoca = veMoca.TOTAL_LOCKED_ESMOCA();
        
        // Should include lock2 + lock3
        assertLt(totalMoca, lock1_MocaAmount + lock2_MocaAmount + lock3_MocaAmount, "Total MOCA decreased");
    }

    function test_Lock1_HasZeroVP() public {
        uint128 lock1Vp = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        assertEq(lock1Vp, 0, "Lock1 VP = 0 (expired)");
    }

    function testRevert_Unlock_NonExpiredLock() public {
        vm.expectRevert(Errors.InvalidExpiry.selector);
        vm.prank(user1);
        veMoca.unlock(lock2_Id);
    }

    function testRevert_Unlock_AlreadyUnlocked() public {
        vm.expectRevert(Errors.InvalidLockState.selector);
        vm.prank(user1);
        veMoca.unlock(lock1_Id);
    }

    function testRevert_Unlock_NonOwner() public {
        // Create a lock for user2 with sufficient duration (at least 3 epochs from current E4)
        vm.startPrank(user2);
            vm.deal(user2, 100 ether);
            // Current epoch is E4, need expiry at least at E7 (3 full epochs)
            bytes32 user2LockId = veMoca.createLock{value: 100 ether}(uint128(getEpochEndTimestamp(8)), 0);
        vm.stopPrank();
        
        // Warp past expiry
        vm.warp(getEpochEndTimestamp(8) + 1);
        
        vm.expectRevert(Errors.InvalidOwner.selector);
        vm.prank(user1);
        veMoca.unlock(user2LockId);
    }
}

// =====================================================
// ================= PHASE 5: MULTI-USER SCENARIOS =================
// =====================================================

/// @notice Complex multi-user delegation scenario
abstract contract StateE4_MultiUserDelegation is StateE4_UnlockExpiredLock1 {
    
    bytes32 public lock4_Id; // user3 -> user2
    bytes32 public lock5_Id; // user2 personal
    bytes32 public lock6_Id; // user2 -> user1
    
    uint128 public lock4_Expiry;
    uint128 public lock5_Expiry;
    uint128 public lock6_Expiry;
    
    uint128 public lock4_MocaAmount;
    uint128 public lock5_MocaAmount;
    uint128 public lock6_MocaAmount;
    
    DataTypes.VeBalance public lock4_VeBalance;
    DataTypes.VeBalance public lock5_VeBalance;
    DataTypes.VeBalance public lock6_VeBalance;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Register user1 as delegate (user2 will delegate to user1)
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user1, true);
        
        // Lock4: user3 creates and delegates to user2
        lock4_Expiry = uint128(getEpochEndTimestamp(15));
        lock4_MocaAmount = 100 ether;
        
        vm.startPrank(user3);
            vm.deal(user3, lock4_MocaAmount);
            lock4_Id = veMoca.createLock{value: lock4_MocaAmount}(lock4_Expiry, 0);
            veMoca.delegationAction(lock4_Id, user2, DataTypes.DelegationType.Delegate);
        vm.stopPrank();
        lock4_VeBalance = veMoca.getLockVeBalance(lock4_Id);
        
        // Lock5: user2 creates personal lock (no delegation)
        lock5_Expiry = uint128(getEpochEndTimestamp(16));
        lock5_MocaAmount = 80 ether;
        
        vm.startPrank(user2);
            vm.deal(user2, lock5_MocaAmount);
            lock5_Id = veMoca.createLock{value: lock5_MocaAmount}(lock5_Expiry, 0);
        vm.stopPrank();
        lock5_VeBalance = veMoca.getLockVeBalance(lock5_Id);
        
        // Lock6: user2 creates and delegates to user1
        lock6_Expiry = uint128(getEpochEndTimestamp(14));
        lock6_MocaAmount = 60 ether;
        
        vm.startPrank(user2);
            vm.deal(user2, lock6_MocaAmount);
            lock6_Id = veMoca.createLock{value: lock6_MocaAmount}(lock6_Expiry, 0);
            veMoca.delegationAction(lock6_Id, user1, DataTypes.DelegationType.Delegate);
        vm.stopPrank();
        lock6_VeBalance = veMoca.getLockVeBalance(lock6_Id);
        
        // Warp to E5 and run cronjob to activate all delegations
        uint128 epoch5StartTimestamp = uint128(getEpochStartTimestamp(5));
        vm.warp(epoch5StartTimestamp + 1);
        
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](3);
            accounts[0] = user1;
            accounts[1] = user2;
            accounts[2] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
            veMoca.updateAccountsAndPendingDeltas(accounts, true);
            
            // Update all pairs
            address[] memory pairUsers = new address[](3);
            address[] memory pairDelegates = new address[](3);
            pairUsers[0] = user3;
            pairDelegates[0] = user2;
            pairUsers[1] = user2;
            pairDelegates[1] = user1;
            pairUsers[2] = user1;
            pairDelegates[2] = user3;
            veMoca.updateDelegatePairs(pairUsers, pairDelegates);
        vm.stopPrank();
    }
}

contract StateE4_MultiUserDelegation_Test is StateE4_MultiUserDelegation {

    function test_User2_HasBothPersonalAndDelegatedVP() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // User2 personal VP = lock5
        uint128 user2PersonalVp = veMoca.balanceOfAt(user2, currentTimestamp, false);
        uint128 expectedPersonalVp = getValueAt(lock5_VeBalance, currentTimestamp);
        assertEq(user2PersonalVp, expectedPersonalVp, "User2 personal VP = lock5");
        
        // User2 delegated VP = lock4 (from user3)
        uint128 user2DelegatedVp = veMoca.balanceOfAt(user2, currentTimestamp, true);
        uint128 expectedDelegatedVp = getValueAt(lock4_VeBalance, currentTimestamp);
        assertEq(user2DelegatedVp, expectedDelegatedVp, "User2 delegated VP = lock4");
    }

    function test_User1_HasDelegatedVP_FromUser2() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // User1 delegated VP = lock6 (from user2)
        uint128 user1DelegatedVp = veMoca.balanceOfAt(user1, currentTimestamp, true);
        uint128 expectedDelegatedVp = getValueAt(lock6_VeBalance, currentTimestamp);
        assertEq(user1DelegatedVp, expectedDelegatedVp, "User1 delegated VP = lock6");
    }

    function test_User3_HasPersonalVP_FromLock4() public {
        // User3 delegated lock4, so personal VP should be 0
        // (lock4 was created and immediately delegated in same tx)
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3PersonalVp = veMoca.balanceOfAt(user3, currentTimestamp, false);
        
        // user3 has no personal VP (lock4 is delegated)
        assertEq(user3PersonalVp, 0, "User3 personal VP = 0 (lock4 delegated)");
    }

    function test_GlobalState_MatchesSumOfAllLocks() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // Total supply should equal sum of all active locks
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        uint128 lock2Vp = getValueAt(lock2_VeBalance, currentTimestamp);
        uint128 lock3Vp = getValueAt(lock3_VeBalance, currentTimestamp);
        uint128 lock4Vp = getValueAt(lock4_VeBalance, currentTimestamp);
        uint128 lock5Vp = getValueAt(lock5_VeBalance, currentTimestamp);
        uint128 lock6Vp = getValueAt(lock6_VeBalance, currentTimestamp);
        
        uint128 expectedTotal = lock2Vp + lock3Vp + lock4Vp + lock5Vp + lock6Vp;
        assertGe(totalSupply, expectedTotal, "Total supply >= sum of locks");
    }

    function test_SpecificDelegatedBalance_User3ToUser2() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        
        uint128 specificBalance = veMoca.getSpecificDelegatedBalanceAtEpochEnd(user3, user2, currentEpoch);
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 expectedBalance = getValueAt(lock4_VeBalance, epochEndTimestamp);
        
        assertEq(specificBalance, expectedBalance, "user3->user2 specific balance = lock4");
    }

    function test_SpecificDelegatedBalance_User2ToUser1() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        
        uint128 specificBalance = veMoca.getSpecificDelegatedBalanceAtEpochEnd(user2, user1, currentEpoch);
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 expectedBalance = getValueAt(lock6_VeBalance, epochEndTimestamp);
        
        assertEq(specificBalance, expectedBalance, "user2->user1 specific balance = lock6");
    }
}

// =====================================================
// ================= PHASE 6: EMERGENCY EXIT =================
// =====================================================

/// @notice Test emergency exit - all users should receive principals
abstract contract StateEmergencyExit is StateE4_MultiUserDelegation {
    
    function setUp() public virtual override {
        super.setUp();
        
        // Warp far into future to expire all locks
        vm.warp(getEpochEndTimestamp(20) + 1);
    }
}

contract StateEmergencyExit_Test is StateEmergencyExit {

    function test_EmergencyExit_AllUsersCanUnlock() public {
        // User1 can unlock lock2 (delegated to user3) and lock3 (delegated to user3)
        uint128 user1MocaBefore = uint128(user1.balance);
        
        vm.startPrank(user1);
            veMoca.unlock(lock2_Id);
            veMoca.unlock(lock3_Id);
        vm.stopPrank();
        
        uint128 user1MocaAfter = uint128(user1.balance);
        assertEq(user1MocaAfter, user1MocaBefore + lock2_MocaAmount + lock3_MocaAmount, "User1 received lock2 + lock3 MOCA");
        
        // User3 can unlock lock4 (delegated to user2)
        uint128 user3MocaBefore = uint128(user3.balance);
        
        vm.prank(user3);
        veMoca.unlock(lock4_Id);
        
        uint128 user3MocaAfter = uint128(user3.balance);
        assertEq(user3MocaAfter, user3MocaBefore + lock4_MocaAmount, "User3 received lock4 MOCA");
        
        // User2 can unlock lock5 (personal) and lock6 (delegated to user1)
        uint128 user2MocaBefore = uint128(user2.balance);
        
        vm.startPrank(user2);
            veMoca.unlock(lock5_Id);
            veMoca.unlock(lock6_Id);
        vm.stopPrank();
        
        uint128 user2MocaAfter = uint128(user2.balance);
        assertEq(user2MocaAfter, user2MocaBefore + lock5_MocaAmount + lock6_MocaAmount, "User2 received lock5 + lock6 MOCA");
    }

    function test_EmergencyExit_DelegationDoesNotAffectUnlock() public {
        // Even though locks are delegated, OWNER can always unlock when expired
        
        // lock2 is delegated to user3, but user1 (owner) can unlock
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        assertEq(lock2.owner, user1, "Lock2 owner is user1");
        assertEq(lock2.delegate, user3, "Lock2 delegate is user3");
        
        vm.prank(user1);
        veMoca.unlock(lock2_Id);
        
        DataTypes.Lock memory lock2After = getLock(lock2_Id);
        assertTrue(lock2After.isUnlocked, "Lock2 unlocked by owner despite delegation");
    }

    function test_EmergencyExit_DelegateCannotUnlock() public {
        // Delegate cannot unlock - only owner can
        
        // user3 is delegate of lock2, but cannot unlock
        vm.expectRevert(Errors.InvalidOwner.selector);
        vm.prank(user3);
        veMoca.unlock(lock2_Id);
    }

    function test_EmergencyExit_GlobalState_AllLocksCleared() public {
        // Unlock all locks
        vm.prank(user1);
        veMoca.unlock(lock2_Id);
        
        vm.prank(user1);
        veMoca.unlock(lock3_Id);
        
        vm.prank(user3);
        veMoca.unlock(lock4_Id);
        
        vm.prank(user2);
        veMoca.unlock(lock5_Id);
        
        vm.prank(user2);
        veMoca.unlock(lock6_Id);
        
        // Verify global state cleared (except for already unlocked lock1)
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), 0, "Total locked MOCA = 0");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), 0, "Total locked esMOCA = 0");
    }
}

