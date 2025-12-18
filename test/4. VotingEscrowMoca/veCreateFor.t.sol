// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage, Vm} from "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import "./delegateHelper.sol";

// ================= PHASE 1: Setup (E1) - 4 locks =================
abstract contract StateE1_Setup is TestingHarness, DelegateHelper {

    bytes32 public lock1_Id; // user1 self
    bytes32 public lock2_Id; // user1 -> user2
    bytes32 public lock3_Id; // user2 self
    bytes32 public lock4_Id; // user2 -> user1

    uint128 public constant LOCK_AMOUNT = 100 ether;
    uint128 public expiry;

    function setUp() public virtual override {
        super.setUp();

        vm.warp(EPOCH_DURATION); // Start at E1
        expiry = uint128(getEpochEndTimestamp(10));

        // Mock VC to allow delegation registration
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(address(this)); 
        
        // Register delegates
        veMoca.delegateRegistrationStatus(user1, true);
        veMoca.delegateRegistrationStatus(user2, true);

        // Fund users
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);

        // Setup User1
        vm.startPrank(user1);
            esMoca.escrowMoca{value: LOCK_AMOUNT * 4}();
            esMoca.approve(address(veMoca), type(uint256).max);
            
            // Lock 1: User1 self
            lock1_Id = veMoca.createLock{value: LOCK_AMOUNT}(expiry, LOCK_AMOUNT);
            
            // Lock 2: User1 -> User2
            lock2_Id = veMoca.createLock{value: LOCK_AMOUNT}(expiry, LOCK_AMOUNT);
            veMoca.delegationAction(lock2_Id, user2, DataTypes.DelegationType.Delegate);
        vm.stopPrank();

        // Setup User2
        vm.startPrank(user2);
            esMoca.escrowMoca{value: LOCK_AMOUNT * 4}();
            esMoca.approve(address(veMoca), type(uint256).max);

            // Lock 3: User2 self
            lock3_Id = veMoca.createLock{value: LOCK_AMOUNT}(expiry, LOCK_AMOUNT);

            // Lock 4: User2 -> User1
            lock4_Id = veMoca.createLock{value: LOCK_AMOUNT}(expiry, LOCK_AMOUNT);
            veMoca.delegationAction(lock4_Id, user1, DataTypes.DelegationType.Delegate);
        vm.stopPrank();
        
        // Setup CronJob Role
        vm.prank(cronJobAdmin);
        veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        
        // Grant CronJob enough MOCA/esMOCA to create locks for users
        vm.deal(cronJob, 10000 ether);
        vm.startPrank(cronJob);
            esMoca.escrowMoca{value: 1000 ether}();
            esMoca.approve(address(veMoca), type(uint256).max);
        vm.stopPrank();
    }

    // ================= HELPER FUNCTIONS =================

    function _verifyLock(bytes32 lockId, address owner, address delegate, uint128 moca, uint128 esMoca, uint128 lockExpiry) internal view {
        DataTypes.Lock memory l = getLock(lockId);
        assertEq(l.owner, owner, "Owner mismatch");
        assertEq(l.delegate, delegate, "Delegate mismatch");
        assertEq(l.moca, moca, "Moca mismatch");
        assertEq(l.esMoca, esMoca, "EsMoca mismatch");
        assertEq(l.expiry, lockExpiry, "Expiry mismatch");
        assertFalse(l.isUnlocked, "Should not be unlocked");
    }

    function _verifyEventsEmitted(Vm.Log[] memory logs) internal pure {
        bool foundGlobalUpdated = false;
        bool foundLocksCreatedFor = false;
        
        bytes32 sigGlobalUpdated = keccak256("GlobalUpdated(uint128,uint128)");
        bytes32 sigLocksCreatedFor = keccak256("LocksCreatedFor(address[],bytes32[],uint256,uint256)");
        bytes32 sigLockCreated = keccak256("LockCreated(bytes32,address,uint256,uint256,uint256)");
        bytes32 sigUserUpdated = keccak256("UserUpdated(address,uint128,uint128)");

        uint256 lockCreatedCount = 0;
        uint256 userUpdatedCount = 0;

        for (uint i; i < logs.length; ++i) {
            bytes32 sig = logs[i].topics[0];
            if (sig == sigGlobalUpdated) foundGlobalUpdated = true;
            if (sig == sigLocksCreatedFor) foundLocksCreatedFor = true;
            if (sig == sigLockCreated) lockCreatedCount++;
            if (sig == sigUserUpdated) userUpdatedCount++;
        }
        
        assertTrue(foundGlobalUpdated, "GlobalUpdated event missing");
        assertTrue(foundLocksCreatedFor, "LocksCreatedFor event missing");
        assertGe(lockCreatedCount, 2, "Should have at least 2 LockCreated events");
        assertGe(userUpdatedCount, 2, "Should have at least 2 UserUpdated events");
    }
}

// ================= PHASE 2: Advance to E2 =================
abstract contract StateE2_AdvanceEpoch is StateE1_Setup {

    function setUp() public virtual override {
        super.setUp();
        
        // Warp to E2 start + 1 second
        vm.warp(getEpochStartTimestamp(2) + 1); 
        
        // Cronjob update to finalize E1->E2 transitions
        vm.startPrank(cronJob);
            address[] memory accs = new address[](2);
            accs[0] = user1; accs[1] = user2;
            veMoca.updateAccountsAndPendingDeltas(accs, false); // users
            veMoca.updateAccountsAndPendingDeltas(accs, true);  // delegates
            
            address[] memory users = new address[](2);
            address[] memory delegates = new address[](2);
            users[0] = user1; delegates[0] = user2; // user1 delegated to user2
            users[1] = user2; delegates[1] = user1; // user2 delegated to user1
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();
    }
}

// ================= PHASE 2 TESTS: Initial State After E2 =================
contract StateE2_AdvanceEpoch_Test is StateE2_AdvanceEpoch {

    function test_InitialState_E2() public view {
        // 1. Check all four locks
        _verifyLock(lock1_Id, user1, address(0), LOCK_AMOUNT, LOCK_AMOUNT, expiry);
        _verifyLock(lock2_Id, user1, user2, LOCK_AMOUNT, LOCK_AMOUNT, expiry);
        _verifyLock(lock3_Id, user2, address(0), LOCK_AMOUNT, LOCK_AMOUNT, expiry);
        _verifyLock(lock4_Id, user2, user1, LOCK_AMOUNT, LOCK_AMOUNT, expiry);

        // 2. Check Users
        // User1 has:
        // - Personal: lock1 (active)
        // - Delegated: lock4 (from user2, active)
        // - Delegated Out: lock2 (to user2)
        uint128 user1VP = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        uint128 user1DelegatedVP = veMoca.balanceOfAt(user1, uint128(block.timestamp), true);
        
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        uint128 lock4VP = veMoca.getLockVotingPowerAt(lock4_Id, uint128(block.timestamp));
        
        assertEq(user1VP, lock1VP, "User1 Personal VP should be Lock1 VP");
        assertEq(user1DelegatedVP, lock4VP, "User1 Delegated VP should be Lock4 VP");

        // User2 has:
        // - Personal: lock3 (active)
        // - Delegated: lock2 (from user1, active)
        uint128 user2VP = veMoca.balanceOfAt(user2, uint128(block.timestamp), false);
        uint128 user2DelegatedVP = veMoca.balanceOfAt(user2, uint128(block.timestamp), true);
        
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, uint128(block.timestamp));
        uint128 lock2VP = veMoca.getLockVotingPowerAt(lock2_Id, uint128(block.timestamp));
        
        assertEq(user2VP, lock3VP, "User2 Personal VP should be Lock3 VP");
        assertEq(user2DelegatedVP, lock2VP, "User2 Delegated VP should be Lock2 VP");

        // 3. Global State
        // Total Locked: 4 locks * 200 total tokens each
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), LOCK_AMOUNT * 4);
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), LOCK_AMOUNT * 4);
        
        // Total Supply should match sum of all lock VPs
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(uint128(block.timestamp));
        assertEq(totalSupply, lock1VP + lock2VP + lock3VP + lock4VP, "Total Supply mismatch");
    }
}

// ================= PHASE 3: CreateLockFor with SAME amounts =================
abstract contract StateE2_CreateLockFor_SameAmounts is StateE2_AdvanceEpoch {
    
    // New lock IDs
    bytes32 public lock5_Id;  // Created for user1
    bytes32 public lock6_Id;  // Created for user2
    
    // Logs from createLockFor call
    Vm.Log[] public recordedLogs;
    
    // State snapshots BEFORE createLockFor
    UnifiedStateSnapshot public beforeStateUser1;
    UnifiedStateSnapshot public beforeStateUser2;
    
    // State snapshots AFTER createLockFor
    UnifiedStateSnapshot public afterStateUser1;
    UnifiedStateSnapshot public afterStateUser2;
    
    // Parameters for this phase
    uint128 public constant SAME_MOCA_AMT = 50 ether;
    uint128 public constant SAME_ESMOCA_AMT = 50 ether;
    uint128 public lockExpirySame;
    
    function setUp() public virtual override {
        super.setUp();
        
        lockExpirySame = uint128(getEpochEndTimestamp(12));
        
        // ============ Capture BEFORE states ============
        // Use existing locks for context (lock1 for user1, lock3 for user2)
        beforeStateUser1 = captureAllStatesPlusDelegates(user1, lock1_Id, expiry, 0, user2, user1);
        beforeStateUser2 = captureAllStatesPlusDelegates(user2, lock3_Id, expiry, 0, user1, user2);
        
        // ============ Prepare arrays ============
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        
        uint128[] memory mocaAmounts = new uint128[](2);
        mocaAmounts[0] = SAME_MOCA_AMT;
        mocaAmounts[1] = SAME_MOCA_AMT;
        
        uint128[] memory esMocaAmounts = new uint128[](2);
        esMocaAmounts[0] = SAME_ESMOCA_AMT;
        esMocaAmounts[1] = SAME_ESMOCA_AMT;
        
        uint128 totalMoca = SAME_MOCA_AMT * 2;
        
        // ============ Execute createLockFor ============
        vm.prank(cronJob);
        vm.recordLogs();
        bytes32[] memory newLockIds = veMoca.createLockFor{value: totalMoca}(users, esMocaAmounts, mocaAmounts, lockExpirySame);
        
        // Store logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i; i < logs.length; ++i) {
            recordedLogs.push(logs[i]);
        }
        
        // Store new lock IDs
        lock5_Id = newLockIds[0];
        lock6_Id = newLockIds[1];
        
        // ============ Capture AFTER states ============
        // Use newly created locks for context (lock5 for user1, lock6 for user2)
        afterStateUser1 = captureAllStatesPlusDelegates(user1, lock5_Id, lockExpirySame, 0, user2, user1);
        afterStateUser2 = captureAllStatesPlusDelegates(user2, lock6_Id, lockExpirySame, 0, user1, user2);
    }
}

// ================= PHASE 3 TESTS: Verify Same Amounts CreateLockFor =================
contract StateE2_CreateLockFor_SameAmounts_Test is StateE2_CreateLockFor_SameAmounts {
    
    function test_NewLocks_SameAmounts() public view {
        // Verify lock5 created for user1
        _verifyLock(lock5_Id, user1, address(0), SAME_MOCA_AMT, SAME_ESMOCA_AMT, lockExpirySame);
        
        // Verify lock6 created for user2
        _verifyLock(lock6_Id, user2, address(0), SAME_MOCA_AMT, SAME_ESMOCA_AMT, lockExpirySame);
    }
    
    function test_User1StateChange_SameAmounts() public view {
        // User1 Personal VP should increase by lock5's VP
        uint128 lock5VP = veMoca.getLockVotingPowerAt(lock5_Id, uint128(block.timestamp));
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        
        // After state user VP should equal lock1 + lock5
        assertEq(afterStateUser1.userState.userCurrentVotingPower, lock1VP + lock5VP, "User1 VP should include lock5");
        
        // User1 total MOCA locked increased
        assertGt(afterStateUser1.globalState.TOTAL_LOCKED_MOCA, beforeStateUser1.globalState.TOTAL_LOCKED_MOCA, "Total MOCA should increase");
        
        // User1 lock count (new lock created)
        assertEq(afterStateUser1.lockState.lock.owner, user1, "Lock5 owner should be user1");
        assertEq(afterStateUser1.lockState.lock.moca, SAME_MOCA_AMT, "Lock5 moca amount");
        assertEq(afterStateUser1.lockState.lock.esMoca, SAME_ESMOCA_AMT, "Lock5 esMoca amount");
    }
    
    function test_User2StateChange_SameAmounts() public view {
        // User2 Personal VP should increase by lock6's VP
        uint128 lock6VP = veMoca.getLockVotingPowerAt(lock6_Id, uint128(block.timestamp));
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, uint128(block.timestamp));
        
        // After state user VP should equal lock3 + lock6
        assertEq(afterStateUser2.userState.userCurrentVotingPower, lock3VP + lock6VP, "User2 VP should include lock6");
        
        // User2 lock state (new lock created)
        assertEq(afterStateUser2.lockState.lock.owner, user2, "Lock6 owner should be user2");
        assertEq(afterStateUser2.lockState.lock.moca, SAME_MOCA_AMT, "Lock6 moca amount");
        assertEq(afterStateUser2.lockState.lock.esMoca, SAME_ESMOCA_AMT, "Lock6 esMoca amount");
    }
    
    function test_GlobalStateChange_SameAmounts() public view {
        uint128 totalMoca = SAME_MOCA_AMT * 2;
        uint128 totalEsMoca = SAME_ESMOCA_AMT * 2;
        
        // Global MOCA locked increased
        assertEq(
            afterStateUser1.globalState.TOTAL_LOCKED_MOCA, 
            beforeStateUser1.globalState.TOTAL_LOCKED_MOCA + totalMoca,
            "TOTAL_LOCKED_MOCA should increase by 100 ether"
        );
        
        // Global esMOCA locked increased
        assertEq(
            afterStateUser1.globalState.TOTAL_LOCKED_ESMOCA, 
            beforeStateUser1.globalState.TOTAL_LOCKED_ESMOCA + totalEsMoca,
            "TOTAL_LOCKED_ESMOCA should increase by 100 ether"
        );
        
        // Verify slope changes at new expiry
        DataTypes.VeBalance memory lock5Ve = convertToVeBalance(getLock(lock5_Id));
        DataTypes.VeBalance memory lock6Ve = convertToVeBalance(getLock(lock6_Id));
        uint128 expectedSlopeChange = lock5Ve.slope + lock6Ve.slope;
        
        assertEq(veMoca.slopeChanges(lockExpirySame), expectedSlopeChange, "Slope changes at new expiry");
        
        // Total supply increased
        assertGt(
            afterStateUser1.globalState.totalSupplyAtTimestamp,
            beforeStateUser1.globalState.totalSupplyAtTimestamp,
            "Total supply should increase"
        );
    }
    
    function test_Events_SameAmounts() public view {
        _verifyEventsEmitted(recordedLogs);
    }
}

// ================= PHASE 4: CreateLockFor with DIFFERENT amounts =================
abstract contract StateE2_CreateLockFor_DifferentAmounts is StateE2_CreateLockFor_SameAmounts {
    
    // New lock IDs
    bytes32 public lock7_Id;  // Created for user1
    bytes32 public lock8_Id;  // Created for user2
    
    // Logs from createLockFor call
    Vm.Log[] public recordedLogsDiff;
    
    // State snapshots BEFORE createLockFor (different amounts)
    UnifiedStateSnapshot public beforeStateUser1Diff;
    UnifiedStateSnapshot public beforeStateUser2Diff;
    
    // State snapshots AFTER createLockFor (different amounts)
    UnifiedStateSnapshot public afterStateUser1Diff;
    UnifiedStateSnapshot public afterStateUser2Diff;
    
    // Parameters for this phase (DIFFERENT amounts)
    uint128 public constant DIFF_MOCA_AMT_1 = 10 ether;    // user1
    uint128 public constant DIFF_ESMOCA_AMT_1 = 20 ether;  // user1
    uint128 public constant DIFF_MOCA_AMT_2 = 30 ether;    // user2
    uint128 public constant DIFF_ESMOCA_AMT_2 = 40 ether;  // user2
    uint128 public lockExpiryDiff;
    
    function setUp() public virtual override {
        super.setUp();
        
        lockExpiryDiff = uint128(getEpochEndTimestamp(14));
        
        // ============ Capture BEFORE states ============
        // Use locks from previous phase (lock5 for user1, lock6 for user2)
        beforeStateUser1Diff = captureAllStatesPlusDelegates(user1, lock5_Id, lockExpirySame, 0, user2, user1);
        beforeStateUser2Diff = captureAllStatesPlusDelegates(user2, lock6_Id, lockExpirySame, 0, user1, user2);
        
        // ============ Prepare arrays ============
        address[] memory users = new address[](2);
        users[0] = user1;
        users[1] = user2;
        
        uint128[] memory mocaAmounts = new uint128[](2);
        mocaAmounts[0] = DIFF_MOCA_AMT_1;
        mocaAmounts[1] = DIFF_MOCA_AMT_2;
        
        uint128[] memory esMocaAmounts = new uint128[](2);
        esMocaAmounts[0] = DIFF_ESMOCA_AMT_1;
        esMocaAmounts[1] = DIFF_ESMOCA_AMT_2;
        
        uint128 totalMoca = DIFF_MOCA_AMT_1 + DIFF_MOCA_AMT_2;
        
        // ============ Execute createLockFor ============
        vm.prank(cronJob);
        vm.recordLogs();
        bytes32[] memory newLockIds = veMoca.createLockFor{value: totalMoca}(users, esMocaAmounts, mocaAmounts, lockExpiryDiff);
        
        // Store logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint i; i < logs.length; ++i) {
            recordedLogsDiff.push(logs[i]);
        }
        
        // Store new lock IDs
        lock7_Id = newLockIds[0];
        lock8_Id = newLockIds[1];
        
        // ============ Capture AFTER states ============
        // Use newly created locks for context (lock7 for user1, lock8 for user2)
        afterStateUser1Diff = captureAllStatesPlusDelegates(user1, lock7_Id, lockExpiryDiff, 0, user2, user1);
        afterStateUser2Diff = captureAllStatesPlusDelegates(user2, lock8_Id, lockExpiryDiff, 0, user1, user2);
    }
}

// ================= PHASE 4 TESTS: Verify Different Amounts CreateLockFor =================
contract StateE2_CreateLockFor_DifferentAmounts_Test is StateE2_CreateLockFor_DifferentAmounts {
    
    function test_NewLocks_DifferentAmounts() public view {
        // Verify lock7 created for user1 with different amounts
        _verifyLock(lock7_Id, user1, address(0), DIFF_MOCA_AMT_1, DIFF_ESMOCA_AMT_1, lockExpiryDiff);
        
        // Verify lock8 created for user2 with different amounts
        _verifyLock(lock8_Id, user2, address(0), DIFF_MOCA_AMT_2, DIFF_ESMOCA_AMT_2, lockExpiryDiff);
    }
    
    function test_User1StateChange_DifferentAmounts() public view {
        // User1 now has lock1, lock5, lock7
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        uint128 lock5VP = veMoca.getLockVotingPowerAt(lock5_Id, uint128(block.timestamp));
        uint128 lock7VP = veMoca.getLockVotingPowerAt(lock7_Id, uint128(block.timestamp));
        
        // After state user VP should equal lock1 + lock5 + lock7
        assertEq(afterStateUser1Diff.userState.userCurrentVotingPower, lock1VP + lock5VP + lock7VP, "User1 VP should include all personal locks");
        
        // User1 lock7 state
        assertEq(afterStateUser1Diff.lockState.lock.owner, user1, "Lock7 owner should be user1");
        assertEq(afterStateUser1Diff.lockState.lock.moca, DIFF_MOCA_AMT_1, "Lock7 moca amount");
        assertEq(afterStateUser1Diff.lockState.lock.esMoca, DIFF_ESMOCA_AMT_1, "Lock7 esMoca amount");
    }
    
    function test_User2StateChange_DifferentAmounts() public view {
        // User2 now has lock3, lock6, lock8
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, uint128(block.timestamp));
        uint128 lock6VP = veMoca.getLockVotingPowerAt(lock6_Id, uint128(block.timestamp));
        uint128 lock8VP = veMoca.getLockVotingPowerAt(lock8_Id, uint128(block.timestamp));
        
        // After state user VP should equal lock3 + lock6 + lock8
        assertEq(afterStateUser2Diff.userState.userCurrentVotingPower, lock3VP + lock6VP + lock8VP, "User2 VP should include all personal locks");
        
        // User2 lock8 state
        assertEq(afterStateUser2Diff.lockState.lock.owner, user2, "Lock8 owner should be user2");
        assertEq(afterStateUser2Diff.lockState.lock.moca, DIFF_MOCA_AMT_2, "Lock8 moca amount");
        assertEq(afterStateUser2Diff.lockState.lock.esMoca, DIFF_ESMOCA_AMT_2, "Lock8 esMoca amount");
    }
    
    function test_GlobalStateChange_DifferentAmounts() public view {
        uint128 totalMocaDiff = DIFF_MOCA_AMT_1 + DIFF_MOCA_AMT_2;
        uint128 totalEsMocaDiff = DIFF_ESMOCA_AMT_1 + DIFF_ESMOCA_AMT_2;
        
        // Global MOCA locked increased from before (phase 3 state)
        assertEq(
            afterStateUser1Diff.globalState.TOTAL_LOCKED_MOCA, 
            beforeStateUser1Diff.globalState.TOTAL_LOCKED_MOCA + totalMocaDiff,
            "TOTAL_LOCKED_MOCA should increase by 40 ether"
        );
        
        // Global esMOCA locked increased
        assertEq(
            afterStateUser1Diff.globalState.TOTAL_LOCKED_ESMOCA, 
            beforeStateUser1Diff.globalState.TOTAL_LOCKED_ESMOCA + totalEsMocaDiff,
            "TOTAL_LOCKED_ESMOCA should increase by 60 ether"
        );
        
        // Final total should include all locks: 4 original + 2 same + 2 different
        uint128 expectedTotalMoca = (LOCK_AMOUNT * 4) + (SAME_MOCA_AMT * 2) + totalMocaDiff;
        uint128 expectedTotalEsMoca = (LOCK_AMOUNT * 4) + (SAME_ESMOCA_AMT * 2) + totalEsMocaDiff;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalMoca, "Final TOTAL_LOCKED_MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalEsMoca, "Final TOTAL_LOCKED_ESMOCA");
        
        // Verify slope changes at new expiry (lockExpiryDiff)
        DataTypes.VeBalance memory lock7Ve = convertToVeBalance(getLock(lock7_Id));
        DataTypes.VeBalance memory lock8Ve = convertToVeBalance(getLock(lock8_Id));
        uint128 expectedSlopeChange = lock7Ve.slope + lock8Ve.slope;
        
        assertEq(veMoca.slopeChanges(lockExpiryDiff), expectedSlopeChange, "Slope changes at diff expiry");
        
        // Total supply increased
        assertGt(
            afterStateUser1Diff.globalState.totalSupplyAtTimestamp,
            beforeStateUser1Diff.globalState.totalSupplyAtTimestamp,
            "Total supply should increase"
        );
    }
    
    function test_Events_DifferentAmounts() public view {
        _verifyEventsEmitted(recordedLogsDiff);
    }
    
    function test_VotingPowerComparison_DifferentAmounts() public view {
        // Lock7 (user1) should have less VP than Lock8 (user2) due to smaller amounts
        uint128 lock7VP = veMoca.getLockVotingPowerAt(lock7_Id, uint128(block.timestamp));
        uint128 lock8VP = veMoca.getLockVotingPowerAt(lock8_Id, uint128(block.timestamp));
        
        // Lock7: 10 + 20 = 30 ether total
        // Lock8: 30 + 40 = 70 ether total
        // Lock8 should have more VP (same expiry)
        assertGt(lock8VP, lock7VP, "Lock8 should have more VP than Lock7");
        
        // Verify the ratio approximately matches the amount ratio (30:70)
        // VP is proportional to (moca + esMoca) / MAX_LOCK_DURATION * timeRemaining
        uint128 lock7Amount = DIFF_MOCA_AMT_1 + DIFF_ESMOCA_AMT_1; // 30 ether
        uint128 lock8Amount = DIFF_MOCA_AMT_2 + DIFF_ESMOCA_AMT_2; // 70 ether
        
        // Due to same expiry, VP ratio should match amount ratio
        // Allow for small rounding differences
        uint256 vpRatioLock7 = uint256(lock7VP) * 100 / uint256(lock8VP);
        uint256 amountRatio = uint256(lock7Amount) * 100 / uint256(lock8Amount);
        
        // Should be approximately equal (within 1%)
        assertApproxEqAbs(vpRatioLock7, amountRatio, 1, "VP ratio should match amount ratio");
    }
}
