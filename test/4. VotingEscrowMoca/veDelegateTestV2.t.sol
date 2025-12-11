// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage, Vm} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import {Constants} from "../../src/libraries/Constants.sol";

import "./delegateHelper.sol";

// ================= PHASE 1: SETUP (E1) =================

abstract contract StateE1_Deploy is TestingHarness, DelegateHelper {    

    function setUp() public virtual override {
        super.setUp();

        vm.warp(EPOCH_DURATION);
        assertTrue(getCurrentEpochStart() > 0, "Current epoch start time is greater than 0");
    }
}

contract StateE1_Deploy_Test is StateE1_Deploy {

    function test_User1_CreateLock_T1() public {
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        uint128 expiry = uint128(getEpochEndTimestamp(3)); 
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;
        
        vm.prank(user1);
        veMoca.createLock{value: mocaAmount}(expiry, esMocaAmount);
    }
}

// note: lock1 expires at end of epoch 3
// note: cronJob is set to allow ad-hoc updates to state
abstract contract StateE1_User1_CreateLock1 is StateE1_Deploy {

    bytes32 public lock1_Id;
    uint128 public lock1_Expiry;
    uint128 public lock1_MocaAmount;
    uint128 public lock1_EsMocaAmount;
    DataTypes.VeBalance public lock1_VeBalance;

    UnifiedStateSnapshot public epoch1_BeforeLock1Creation;
    UnifiedStateSnapshot public epoch1_AfterLock1Creation;

    function setUp() public virtual override {
        super.setUp();

        assertEq(block.timestamp, uint128(getEpochStartTimestamp(1)), "Current timestamp is at start of epoch 1");
        assertEq(getCurrentEpochNumber(), 1, "Current epoch number is 1");

        lock1_Expiry = uint128(getEpochEndTimestamp(3)); 
        lock1_MocaAmount = 100 ether;
        lock1_EsMocaAmount = 100 ether;
        lock1_Id = generateLockId(block.number, user1);

        // Capture state
        epoch1_BeforeLock1Creation = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);

        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: lock1_MocaAmount}();
            esMoca.approve(address(veMoca), lock1_MocaAmount);
            lock1_Id = veMoca.createLock{value: lock1_MocaAmount}(lock1_Expiry, lock1_EsMocaAmount);
        vm.stopPrank();

        epoch1_AfterLock1Creation = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);
        lock1_VeBalance = veMoca.getLockVeBalance(lock1_Id);

        // Set cronJob
        vm.startPrank(cronJobAdmin);
            veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();
    }
}

contract StateE1_User1_CreateLock1_Test is StateE1_User1_CreateLock1 {

    function test_User1_balanceAtEpochEnd_Epoch1() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 user1Balance = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);

        // get lock's veBalance
        uint128 lockVotingPowerAtEpochEnd = veMoca.getLockVotingPowerAt(lock1_Id, getCurrentEpochEnd());

        // verify user1 balance
        assertGt(user1Balance, 0, "User1 balance > 0");
        assertEq(user1Balance, lockVotingPowerAtEpochEnd, "User1 balance = lock voting power at epoch end");
    }
}

abstract contract StateE1_RegisterDelegate_User3 is StateE1_User1_CreateLock1 {
    address public constant MOCK_VC = address(0x999); 

    function setUp() public virtual override {
        super.setUp();

        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(MOCK_VC);

        // Register user3
        vm.startPrank(MOCK_VC);
            veMoca.delegateRegistrationStatus(user3, true);
        vm.stopPrank();
    }
}

contract StateE1_RegisterDelegate_User3_Test is StateE1_RegisterDelegate_User3 {

    function testRevert_RegisterDelegate_Unauthorized() public {
        vm.expectRevert(Errors.OnlyCallableByVotingControllerContract.selector);
        vm.prank(user1);
        veMoca.delegateRegistrationStatus(user1, true);
    }

    function test_RegisterDelegate_Success() public {
        assertTrue(veMoca.isRegisteredDelegate(user3), "User3 registered");
    }

    // state transition: User1 delegates lock1 to User3
    // note: lock1 is in pending delegation state
    function test_User1_DelegatesLock1_ToUser3() public {
        UnifiedStateSnapshot memory state = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        vm.expectEmit(true, true, true, true);
        emit Events.DelegateUpdated(user3, 0, 0);
        emit Events.DelegatedAggregationUpdated(user1, user3, 0, 0);
        emit Events.LockDelegated(lock1_Id, user1, user3);

        vm.prank(user1);
        veMoca.delegationAction(lock1_Id, user3, DataTypes.DelegationType.Delegate);

        // Verify delegation
        verifyDelegateLock(state, user3);

        // Additional checks for PENDING state
        DataTypes.Lock memory lock = getLock(lock1_Id);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        assertEq(lock.delegate, user3, "Lock1 delegate is user3");
        assertGt(lock.delegationEpoch, currentEpochStart, "Delegation is pending (epoch > current)");
        
        // User1 still has VP (pending)
        uint128 user1VP = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        assertGt(user1VP, 0, "User1 still has VP (pending)");
        
        // User3 has 0 delegated VP (pending)
        uint128 user3VP = veMoca.balanceOfAt(user3, uint128(block.timestamp), true);
        assertEq(user3VP, 0, "User3 has 0 delegated VP (pending)");
    }
}

// Transition: User1 delegates lock1 to User3 in E1
// note: lock1 is in pending delegation state
abstract contract StateE1_User1_DelegateLock1_ToUser3 is StateE1_RegisterDelegate_User3 {

    UnifiedStateSnapshot public epoch1_BeforeDelegateLock1;
    UnifiedStateSnapshot public epoch1_AfterDelegateLock1;

    function setUp() public virtual override {
        super.setUp();

        epoch1_BeforeDelegateLock1 = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        vm.prank(user1);
        veMoca.delegationAction(lock1_Id, user3, DataTypes.DelegationType.Delegate);

        epoch1_AfterDelegateLock1 = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));
    }
}

contract StateE1_User1_DelegateLock1_ToUser3_Test is StateE1_User1_DelegateLock1_ToUser3 {
 
    /** Checks:
        - user3 is set as lock.delegate
        - numOfDelegateActionsPerEpoch incremented by 1
        - timestamps updated to currentEpochStart: global, user, delegate, user-delegate pair
        
        - slopeChanges: removed from user's slopeChanges[expiry] and added to delegate's slopeChanges[expiry]
        - userPendingDeltas: has subtraction booked for user
        - userVP unchanged in current epoch
        
        - delegatePendingDeltas: has addition booked for delegate [nextEpoch]
        - delegateVP unchanged in current epoch
        
        - user-delegate pair state: has addition booked for user-delegate pair [nextEpoch]
        - user-delegate pair VP unchanged in current epoch
        - delegatedAggregationHistory unchanged in current epoch

        - global state: no change.
     */
    function test_VerifyDelegateLock1_ToUser3() public {
        verifyDelegateLock(epoch1_BeforeDelegateLock1, user3);
    }
}


// ================= PHASE 2: E2 - ACTIVE DELEGATION =================

// advance to E2
// note: update state via cronjob: updateAccountsAndPendingDeltas() and updateDelegatePairs()
abstract contract StateE2_Lock1DelegationTakesEffect is StateE1_User1_DelegateLock1_ToUser3 {

    UnifiedStateSnapshot public epoch2_AfterDelegationTakesEffect;

    function setUp() public virtual override {
        super.setUp();

        // warp to be within E2
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // Cronjob updates
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](2);
            accounts[0] = user1;
            accounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
            veMoca.updateAccountsAndPendingDeltas(accounts, true);

            address[] memory users = new address[](1);
            address[] memory delegates = new address[](1);
            users[0] = user1;
            delegates[0] = user3;
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();

        // capture state
        epoch2_AfterDelegationTakesEffect = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));
    }
}

// note: lock1 is in active delegation state
contract StateE2_Lock1DelegationTakesEffect_Test is StateE2_Lock1DelegationTakesEffect {

    function test_DelegationImpact_User1_User3_VP() public {
        verifyDelegationTakesEffect(epoch1_AfterDelegateLock1, epoch2_AfterDelegationTakesEffect, lock1_Id);
    }

    // cannot switch delegate if lock expires too soon
    function testRevert_SwitchDelegate_MinimumDurationCheck() public {
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock1_Id, user3, DataTypes.DelegationType.Switch); 
    }

    // cannot undelegate if lock expires too soon
    function testRevert_Undelegate_MinimumDurationCheck() public {
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock1_Id, address(0), DataTypes.DelegationType.Undelegate);
    }

    // cannot increase amount if lock expires too soon
    function testRevert_IncreaseAmount_MinimumDurationCheck() public {
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.increaseAmount(lock1_Id, 10 ether);
    }

    // cannot increase duration if lock expires too soon
    function testRevert_IncreaseDuration_MinimumDurationCheck() public {
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock1_Id, EPOCH_DURATION);
    }

    function test_totalSupplyAt_CrossEpochBoundary_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // capture global state
        GlobalStateSnapshot memory globalState = captureGlobalState(lock1_Expiry, 0);

        // verify totalSupplyAt has been updated for current epoch start (Epoch 2 start)
        uint128 epoch2Start = getCurrentEpochStart();
        assertEq(veMoca.totalSupplyAt(epoch2Start), globalState.totalSupplyAt, "totalSupplyAt at Epoch2 start matches");
        
        // verify finalized totalSupplyAt for Epoch 1 end
        // Epoch 1 end timestamp = Epoch 2 start timestamp
        uint128 epoch1End = uint128(getEpochEndTimestamp(1));
        assertEq(epoch1End, epoch2Start, "Epoch 1 end equals Epoch 2 start");
        
        // The finalized totalSupplyAt[Epoch1End] should reflect the total voting power at that moment
        // This is calculated by applying decay to the veGlobal from its last update to epoch1End
        uint128 totalSupplyAtEpoch1End = veMoca.totalSupplyAt(epoch1End);
        assertGt(totalSupplyAtEpoch1End, 0, "totalSupplyAt at Epoch1 end should be > 0");
        
        // Verify the value matches what we'd expect from the global state
        assertEq(totalSupplyAtEpoch1End, globalState.totalSupplyAt, "totalSupplyAt at Epoch1 end matches global state snapshot");
        
        // Also verify via totalSupplyAtTimestamp for consistency
        assertEq(veMoca.totalSupplyAtTimestamp(epoch1End), totalSupplyAtEpoch1End, "totalSupplyAtTimestamp matches totalSupplyAt");
        
        // Verify totalSupplyAt value is the result of lock1's voting power
        // Since lock1 is the only lock in the system, totalSupplyAt should equal lock1's VP at epoch1End
        uint128 lock1VPAtEpoch1End = veMoca.getLockVotingPowerAt(lock1_Id, epoch1End);
        assertEq(totalSupplyAtEpoch1End, lock1VPAtEpoch1End, "totalSupplyAt equals lock1 VP at Epoch1 end");
        
        // Also verify using the captured veBalance
        uint128 expectedLock1VP = getValueAt(lock1_VeBalance, epoch1End);
        assertEq(totalSupplyAtEpoch1End, expectedLock1VP, "totalSupplyAt equals calculated lock1 VP at Epoch1 end");
    }

}

// User1 creates Lock2 & delegates to User3 (Pending Delegation)
abstract contract StateE2_User1_CreatesLock2 is StateE2_Lock1DelegationTakesEffect {

    bytes32 public lock2_Id;
    uint128 public lock2_Expiry;
    uint128 public lock2_MocaAmount;
    uint128 public lock2_EsMocaAmount;

    UnifiedStateSnapshot public epoch2_BeforeLock2Delegation;
    UnifiedStateSnapshot public epoch2_AfterLock2Delegation;

    function setUp() public virtual override {
        super.setUp();

        lock2_Expiry = uint128(getEpochEndTimestamp(10));
        lock2_MocaAmount = 200 ether;
        lock2_EsMocaAmount = 200 ether;

        vm.startPrank(user1);
            vm.deal(user1, 400 ether);
            esMoca.escrowMoca{value: lock2_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock2_EsMocaAmount);

            // Create and delegate
            lock2_Id = veMoca.createLock{value: lock2_MocaAmount}(lock2_Expiry, lock2_EsMocaAmount);
            
            // capture state before lock2 delegation
            epoch2_BeforeLock2Delegation = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user3, address(0));
            veMoca.delegationAction(lock2_Id, user3, DataTypes.DelegationType.Delegate);

        vm.stopPrank();

        // capture state after lock2 delegation
        epoch2_AfterLock2Delegation = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user3, address(0));
    }
}

// note: lock2 is in pending delegation state
contract StateE2_User1_CreatesLock2_Test is StateE2_User1_CreatesLock2 {

    function test_VerifyLock2Delegation() public {
        verifyDelegateLock(epoch2_BeforeLock2Delegation, user3);
    }

    function test_VerifyComprehensiveState_Lock2PendingDelegation() public {

        // ============ 1. User1 has personal voting power from Lock2 ============

            // Lock2 delegation is PENDING (will take effect in E3), so user1 still has Lock2's VP
            uint128 user1PersonalVP = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
            uint128 lock2VPNow = veMoca.getLockVotingPowerAt(lock2_Id, uint128(block.timestamp));
            
            assertGt(user1PersonalVP, 0, "User1 has personal VP");
            assertEq(user1PersonalVP, lock2VPNow, "User1 personal VP equals Lock2 VP (Lock2 pending delegation)");

        // ============ 2. User3 has delegated voting power from Lock1 ============

            // Lock1 delegation is ACTIVE (took effect when we entered E2)
            uint128 user3DelegatedVP = veMoca.balanceOfAt(user3, uint128(block.timestamp), true);
            uint128 lock1VPNow = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
            
            assertGt(user3DelegatedVP, 0, "User3 has delegated VP");
            assertEq(user3DelegatedVP, lock1VPNow, "User3 delegated VP equals Lock1 VP (Lock1 active delegation)");

        // ============ 3. Pending deltas for user1 to shift Lock2 VP to user3 in nextEpoch ============

            uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
            
            // Calculate lock2's veBalance
            DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
            
            // 3.1 User1 has pending SUBTRACTION for Lock2
            (bool user1HasAdd, bool user1HasSub, DataTypes.VeBalance memory user1Additions, DataTypes.VeBalance memory user1Subtractions) 
                = veMoca.userPendingDeltas(user1, nextEpochStart);
            
            assertTrue(user1HasSub, "User1 has pending subtraction for Lock2");
            assertEq(user1Subtractions.bias, lock2VeBalance.bias, "User1 pending sub bias equals Lock2 bias");
            assertEq(user1Subtractions.slope, lock2VeBalance.slope, "User1 pending sub slope equals Lock2 slope");

            // 3.2 User3 (delegate) has pending ADDITION for Lock2
            (bool user3HasAdd, bool user3HasSub, DataTypes.VeBalance memory user3Additions, DataTypes.VeBalance memory user3Subtractions) 
                = veMoca.delegatePendingDeltas(user3, nextEpochStart);
            
            assertTrue(user3HasAdd, "User3 has pending addition for Lock2");
            assertEq(user3Additions.bias, lock2VeBalance.bias, "User3 pending add bias equals Lock2 bias");
            assertEq(user3Additions.slope, lock2VeBalance.slope, "User3 pending add slope equals Lock2 slope");

            // 3.3 User1-User3 pair has pending ADDITION
            (bool pairHasAdd, bool pairHasSub, DataTypes.VeBalance memory pairAdditions, DataTypes.VeBalance memory pairSubtractions) 
                = veMoca.userPendingDeltasForDelegate(user1, user3, nextEpochStart);
            
            assertTrue(pairHasAdd, "User1-User3 pair has pending addition for Lock2");
            assertEq(pairAdditions.bias, lock2VeBalance.bias, "Pair pending add bias equals Lock2 bias");
            assertEq(pairAdditions.slope, lock2VeBalance.slope, "Pair pending add slope equals Lock2 slope");

        // ============ 4. Global state reflects new lock creation (Lock1 + Lock2) ============

            assertEq(veMoca.TOTAL_LOCKED_MOCA(), lock1_MocaAmount + lock2_MocaAmount, "Total Locked MOCA = Lock1 + Lock2");
            assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), lock1_EsMocaAmount + lock2_EsMocaAmount, "Total Locked esMOCA = Lock1 + Lock2");
            
            // Global veBalance should reflect both locks
            (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
            
            DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(getLock(lock1_Id));
            uint128 expectedGlobalSlope = lock1VeBalance.slope + lock2VeBalance.slope;
            uint128 expectedGlobalBias = lock1VeBalance.bias + lock2VeBalance.bias;
            
            assertEq(globalSlope, expectedGlobalSlope, "Global slope = Lock1 slope + Lock2 slope");
            assertEq(globalBias, expectedGlobalBias, "Global bias = Lock1 bias + Lock2 bias");
            
            // Global slopeChanges at expiries
            assertEq(veMoca.slopeChanges(lock1_Expiry), lock1VeBalance.slope, "SlopeChange at Lock1 expiry");
            assertEq(veMoca.slopeChanges(lock2_Expiry), lock2VeBalance.slope, "SlopeChange at Lock2 expiry");

        // ============ 5. TotalSupplyAt[Epoch1] finalized with correct value ============

            // When we entered E2 and updated state, totalSupplyAt[E1Start] should have been finalized
            // It should reflect only Lock1 (Lock2 was created in E2)
            uint128 epoch1Start = getEpochStartTimestamp(1);
            uint128 epoch1End = getEpochEndTimestamp(1); // same as epoch2Start
            
            // The totalSupplyAt is stored at epoch boundaries after the epoch ends
            // totalSupplyAt[epoch2Start] = value at epoch2Start (which is epoch1 end value)
            uint128 totalSupplyAtEpoch2Start = veMoca.totalSupplyAt(epoch1End);
            
            // Calculate expected: Lock1's VP at epoch2Start (epoch1 end)
            // Only Lock1 existed at epoch1 end; Lock2 was created in E2
            uint128 lock1VPAtEpoch1End = getValueAt(lock1VeBalance, epoch1End);
            
            assertGt(totalSupplyAtEpoch2Start, 0, "TotalSupplyAt epoch1End is finalized");
            assertEq(totalSupplyAtEpoch2Start, lock1VPAtEpoch1End, "TotalSupplyAt epoch1End = Lock1 VP at that time");
            
            // Verify totalSupplyAtTimestamp view function for CURRENT timestamp (includes both locks)
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 totalSupplyViewNow = veMoca.totalSupplyAtTimestamp(currentTimestamp);
            uint128 expectedTotalSupplyNow = lock1VPNow + lock2VPNow;
            assertEq(totalSupplyViewNow, expectedTotalSupplyNow, "TotalSupplyAtTimestamp(now) = Lock1 + Lock2 VP");
            
            // Verify totalSupplyAtTimestamp at E2 end (projected future)
            uint128 epoch2End = getEpochEndTimestamp(2);
            uint128 totalSupplyAtEpoch2End = veMoca.totalSupplyAtTimestamp(epoch2End);
            uint128 lock1VPAtEpoch2End = getValueAt(lock1VeBalance, epoch2End);
            uint128 lock2VPAtEpoch2End = getValueAt(lock2VeBalance, epoch2End);
            uint128 expectedTotalSupplyAtEpoch2End = lock1VPAtEpoch2End + lock2VPAtEpoch2End;
            assertEq(totalSupplyAtEpoch2End, expectedTotalSupplyAtEpoch2End, "TotalSupplyAtTimestamp(epoch2End) projected correctly");
    } 

    //user1 increaseDuration on lock2 [increaseDuration on delegated lock]
    // lock is in pending delegation state
    function test_User1_IncreaseDuration_Lock2() public {
        
        uint128 newExpiry = uint128(getEpochEndTimestamp(12));
        UnifiedStateSnapshot memory epoch2_BeforeIncreaseDuration = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, newExpiry, user3, address(0));

        // Calculate expected values for event emission
        // For pending delegation: currentAccount = user1 (owner), so UserUpdated is emitted
        DataTypes.Lock memory lockBefore = getLock(lock2_Id);
        
        // Calculate increase in veBalance from duration increase
        uint128 totalAmount = lockBefore.moca + lockBefore.esMoca;
        uint128 oldSlope = totalAmount / MAX_LOCK_DURATION;
        uint128 newSlope = oldSlope; // slope unchanged for duration increase
        uint128 oldBias = oldSlope * lockBefore.expiry;
        uint128 newBias = newSlope * newExpiry;
        uint128 biasDelta = newBias - oldBias;

        // Expected global state after update
        uint128 expectedGlobalBias = epoch2_BeforeIncreaseDuration.globalState.veGlobal.bias + biasDelta;
        uint128 expectedGlobalSlope = epoch2_BeforeIncreaseDuration.globalState.veGlobal.slope; // slope unchanged

        // Expected user state after update (for pending delegation, user is currentAccount)
        uint128 expectedUserBias = epoch2_BeforeIncreaseDuration.userState.userHistory.bias + biasDelta;
        uint128 expectedUserSlope = epoch2_BeforeIncreaseDuration.userState.userHistory.slope; // slope unchanged

        // Expect events in order
        vm.expectEmit(true, true, true, true);
        emit Events.GlobalUpdated(expectedGlobalBias, expectedGlobalSlope);

        vm.expectEmit(true, true, true, true);
        emit Events.UserUpdated(user1, expectedUserBias, expectedUserSlope);

        vm.expectEmit(true, true, true, true);
        emit Events.LockDurationIncreased(lock2_Id, user1, user3, lock2_Expiry, newExpiry);

        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, 2 * EPOCH_DURATION);
        lock2_Expiry = newExpiry;

        // verify state changes
        verifyIncreaseDurationPendingDelegation(epoch2_BeforeIncreaseDuration, newExpiry);
    }
}

// User1 increaseDuration on Lock2 (Pending): from E10 to E12
// note: Lock2 is still in pending delegation state
abstract contract StateE2_User1_IncreaseDuration_Lock2 is StateE2_User1_CreatesLock2 {


    UnifiedStateSnapshot public epoch2_BeforeIncreaseDuration;

    function setUp() public virtual override {
        super.setUp();

        // capture state before increase duration
        uint128 newExpiry = uint128(getEpochEndTimestamp(12));
        epoch2_BeforeIncreaseDuration = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, newExpiry, user3, address(0));

        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, 2 * EPOCH_DURATION);
        lock2_Expiry = newExpiry;
    }
}

// note: Lock2 is still in pending delegation state
contract StateE2_User1_IncreaseDuration_Lock2_Test is StateE2_User1_IncreaseDuration_Lock2 {

    function test_VerifyIncreaseDuration_PendingDelegation() public {
        verifyIncreaseDurationPendingDelegation(epoch2_BeforeIncreaseDuration, lock2_Expiry);
    }

    function testRevert_IncreaseDuration_Lock1_TooShort() public {
        // Lock1 expires at end of E3 (= start of E4)
        // We're in E2, so currentEpochStart = E2 start
        // _minimumDurationCheck requires: expiry >= currentEpochStart + 3 epochs = E5 start
        // Lock1 expiry = E4 start, which is < E5 start → LockExpiresTooSoon
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock1_Id, EPOCH_DURATION);
    }

    function testRevert_IncreaseDuration_ZeroDuration() public {
        // Cannot increase duration by 0
        vm.expectRevert(Errors.InvalidLockDuration.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, 0);
    }

    function testRevert_IncreaseDuration_NotOwner() public {
        // user2 is not the owner of lock2
        vm.expectRevert(Errors.InvalidLockId.selector);
        vm.prank(user2);
        veMoca.increaseDuration(lock2_Id, EPOCH_DURATION);
    }

    function testRevert_IncreaseDuration_InvalidEpochTime() public {
        // New expiry must be epoch-aligned (multiple of EPOCH_DURATION)
        // Adding a non-epoch-aligned duration will result in non-aligned expiry
        uint128 nonAlignedDuration = EPOCH_DURATION + 1 days; // Not a multiple of EPOCH_DURATION
        
        vm.expectRevert(Errors.InvalidEpochTime.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, nonAlignedDuration);
    }

    function testRevert_IncreaseDuration_ExceedsMaxLockDuration() public {
        // MAX_LOCK_DURATION = 728 days
        // New expiry must be <= block.timestamp + MAX_LOCK_DURATION
        // Lock2 expires at E12 end. If we try to extend beyond max, should revert.
        
        // Calculate duration that would exceed max
        // Lock2 current expiry = E12 end (after setUp)
        // We need: newExpiry > block.timestamp + MAX_LOCK_DURATION
        // Current timestamp is within E2
        uint128 excessiveDuration = MAX_LOCK_DURATION; // Adding full MAX_LOCK_DURATION to already extended lock
        
        vm.expectRevert(Errors.InvalidExpiry.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, excessiveDuration);
    }

    function testRevert_IncreaseDuration_NonExistentLock() public {
        // Try to increase duration on a lock that doesn't exist
        bytes32 fakeLockId = keccak256(abi.encodePacked("fake_lock"));
        
        vm.expectRevert(Errors.InvalidLockId.selector);
        vm.prank(user1);
        veMoca.increaseDuration(fakeLockId, EPOCH_DURATION);
    }

    // state transition: user1 increaseAmount on Lock2 (Pending)
    function test_User1_IncreaseAmount_Lock2_Pending() public {
        uint128 mocaAdded = 50 ether;
        uint128 esMocaAdded = 50 ether;
        vm.deal(user1, mocaAdded + esMocaAdded);

        vm.startPrank(user1);
            // escrow esMOCA
            esMoca.escrowMoca{value: esMocaAdded}();
            esMoca.approve(address(veMoca), esMocaAdded);

            // capture state before increase amount
            UnifiedStateSnapshot memory epoch2_BeforeIncreaseAmount = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user3, address(0));

            vm.expectEmit(true, true, true, true);
            emit Events.LockAmountIncreased(lock2_Id, user1, user3, mocaAdded, esMocaAdded);

            veMoca.increaseAmount{value: mocaAdded}(lock2_Id, esMocaAdded);
        vm.stopPrank();

        // verify state changes 
        verifyIncreaseAmountPendingDelegation(epoch2_BeforeIncreaseAmount, mocaAdded, esMocaAdded);
    }
}

// User1 increaseAmount on Lock2 (Pending)
abstract contract StateE2_User1_IncreaseAmount_Lock2 is StateE2_User1_IncreaseDuration_Lock2 {

    UnifiedStateSnapshot public epoch2_BeforeIncreaseAmount;
    
    uint128 public mocaAdded = 50 ether;
    uint128 public esMocaAdded = 50 ether;

    function setUp() public virtual override {
        super.setUp();


        vm.startPrank(user1);
            vm.deal(user1, 100 ether);
            esMoca.escrowMoca{value: esMocaAdded}();
            esMoca.approve(address(veMoca), esMocaAdded);

            epoch2_BeforeIncreaseAmount = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user3, address(0));

            veMoca.increaseAmount{value: mocaAdded}(lock2_Id, esMocaAdded);
        vm.stopPrank();
        
        lock2_MocaAmount += mocaAdded;
        lock2_EsMocaAmount += esMocaAdded;
    }
}

contract StateE2_User1_IncreaseAmount_Lock2_Test is StateE2_User1_IncreaseAmount_Lock2 {

    function test_VerifyIncreaseAmount_PendingDelegation() public {
        verifyIncreaseAmountPendingDelegation(epoch2_BeforeIncreaseAmount, mocaAdded, esMocaAdded);
    }

    function test_VerifyTotalSupplyAt_PendingDelegation() public {
        uint128 epoch2Start = getCurrentEpochStart();
        
        // ============ 1. Verify finalized totalSupplyAt[E2Start] ============
        // This was written when cronjob ran at E1->E2 transition, before Lock2 existed
        
        uint128 totalSupplyAtE2Start = veMoca.totalSupplyAt(epoch2Start);
        
        // Calculate expected: Only Lock1's VP at E2 start (Lock2 didn't exist yet at that moment)
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(getLock(lock1_Id));
        uint128 expectedTotalSupplyAtE2Start = getValueAt(lock1VeBalance, epoch2Start);
        
        assertGt(totalSupplyAtE2Start, 0, "TotalSupplyAt E2Start is finalized");
        assertEq(totalSupplyAtE2Start, expectedTotalSupplyAtE2Start, "TotalSupplyAt E2Start = Lock1 VP only");
        
        // ============ 2. Verify totalSupplyAt unchanged by Lock2 operations ============
        // increaseAmount on Lock2 should NOT affect the finalized totalSupplyAt[E2Start]
        
        assertEq(
            veMoca.totalSupplyAt(epoch2Start),
            epoch2_BeforeIncreaseAmount.globalState.totalSupplyAt,
            "TotalSupplyAt E2Start unchanged by increaseAmount"
        );
        
        // ============ 3. Verify current projected total supply includes both locks ============
        // totalSupplyAtTimestamp projects from current veGlobal (includes both Lock1 + Lock2)
        
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 totalSupplyNow = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        // Calculate expected: Lock1 + Lock2 VP at current timestamp
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        uint128 lock1VPNow = getValueAt(lock1VeBalance, currentTimestamp);
        uint128 lock2VPNow = getValueAt(lock2VeBalance, currentTimestamp);
        uint128 expectedTotalSupplyNow = lock1VPNow + lock2VPNow;
        
        assertEq(totalSupplyNow, expectedTotalSupplyNow, "TotalSupplyAtTimestamp(now) = Lock1 + Lock2");
        
        // ============ 4. Verify global veBalance consistency ============
        // Global veBalance should equal sum of lock veBalances
        
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        assertEq(globalBias, lock1VeBalance.bias + lock2VeBalance.bias, "Global bias = sum of locks");
        assertEq(globalSlope, lock1VeBalance.slope + lock2VeBalance.slope, "Global slope = sum of locks");
    }


    function test_User1_SwitchDelegate_Lock2_Pending_ToUser2() public {
        // register user2
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user2, true);

        // capture state before switch
        UnifiedStateSnapshot memory epoch2_BeforeSwitch = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user2, user3);

        // Calculate expected values for event emission
        DataTypes.Lock memory lockBefore = getLock(lock2_Id);
        DataTypes.VeBalance memory lockVeBalance = convertToVeBalance(lockBefore);

        // Expected global state - unchanged for delegation switch
        uint128 expectedGlobalBias = epoch2_BeforeSwitch.globalState.veGlobal.bias;
        uint128 expectedGlobalSlope = epoch2_BeforeSwitch.globalState.veGlobal.slope;

        // Expect events in order (NO UserUpdated for pending delegation switch!)
        vm.expectEmit(true, true, true, true);
        emit Events.GlobalUpdated(expectedGlobalBias, expectedGlobalSlope);

        // Old delegate (user3) state updated
        vm.expectEmit(true, true, true, true);
        emit Events.DelegateUpdated(user3, epoch2_BeforeSwitch.oldDelegateState.delegateHistory.bias, epoch2_BeforeSwitch.oldDelegateState.delegateHistory.slope);

        // New delegate (user2) state updated
        vm.expectEmit(true, true, true, true);
        emit Events.DelegateUpdated(user2, epoch2_BeforeSwitch.targetDelegateState.delegateHistory.bias, epoch2_BeforeSwitch.targetDelegateState.delegateHistory.slope);

        // Old pair (user1-user3) state updated
        vm.expectEmit(true, true, true, true);
        emit Events.DelegatedAggregationUpdated(user1, user3, epoch2_BeforeSwitch.oldPairState.delegatedAggregationHistory.bias, epoch2_BeforeSwitch.oldPairState.delegatedAggregationHistory.slope);

        // New pair (user1-user2) state updated
        vm.expectEmit(true, true, true, true);
        emit Events.DelegatedAggregationUpdated(user1, user2, epoch2_BeforeSwitch.targetPairState.delegatedAggregationHistory.bias, epoch2_BeforeSwitch.targetPairState.delegatedAggregationHistory.slope);

        // Final event
        vm.expectEmit(true, true, true, true);
        emit Events.LockDelegateSwitched(lock2_Id, user1, user3, user2);

        // switch delegate from user3 to user2
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user2, DataTypes.DelegationType.Switch);

        // verify state changes
        verifySwitchDelegate(epoch2_BeforeSwitch, user2);
    }
}


// User1 switches delegate for Lock2 from user3 to user2
abstract contract StateE2_User1_SwitchDelegate_Lock2 is StateE2_User1_IncreaseAmount_Lock2 {
    UnifiedStateSnapshot public epoch2_BeforeSwitch;

    function setUp() public virtual override {
        super.setUp();

        // Register user2
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user2, true);

        epoch2_BeforeSwitch = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, user2, user3);

        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user2, DataTypes.DelegationType.Switch);
    }
}

//lock2 is in pending delegation state: frm user3 to user2
contract StateE2_User1_SwitchDelegate_Lock2_Test is StateE2_User1_SwitchDelegate_Lock2 {
   
    function test_VerifySwitchDelegate() public {
        verifySwitchDelegate(epoch2_BeforeSwitch, user2);
    }

 // ============ Negative Tests for switchDelegate ============

    function testRevert_SwitchDelegate_NotOwner() public {
        // user2 is not the owner of lock2
        vm.expectRevert(Errors.InvalidOwner.selector);
        vm.prank(user2);
        veMoca.delegationAction(lock2_Id, user1, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_LockNotDelegated() public {
        // Create a non-delegated lock and try to switch
        vm.startPrank(user1);
            vm.deal(user1, 100 ether);
            bytes32 nonDelegatedLock = veMoca.createLock{value: 100 ether}(uint128(getEpochEndTimestamp(10)), 0);
            
            // Try to switch a non-delegated lock
            vm.expectRevert(Errors.LockNotDelegated.selector);
            veMoca.delegationAction(nonDelegatedLock, user2, DataTypes.DelegationType.Switch);
        vm.stopPrank();
    }

    function testRevert_SwitchDelegate_SameDelegate() public {
        // Try to switch to the same delegate (user2 is already the delegate)
        vm.expectRevert(Errors.InvalidDelegate.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user2, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_ToOwner() public {
        // Cannot switch delegate to the owner
        vm.expectRevert(Errors.InvalidDelegate.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, user1, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_DelegateNotRegistered() public {
        // Try to switch to an unregistered delegate
        address unregisteredDelegate = address(0x123);
        
        vm.expectRevert(Errors.DelegateNotRegistered.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, unregisteredDelegate, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_NonExistentLock() public {
        // Try to switch delegate on a lock that doesn't exist
        bytes32 fakeLockId = keccak256(abi.encodePacked("fake_lock"));
        
        vm.expectRevert(Errors.InvalidOwner.selector);
        vm.prank(user1);
        veMoca.delegationAction(fakeLockId, user2, DataTypes.DelegationType.Switch);
    }

    function testRevert_SwitchDelegate_LockExpiresTooSoon() public {
        // Lock1 expires at end of E3 (= start of E4)
        // We're in E2, so currentEpochStart = E2 start
        // _minimumDurationCheck requires: expiry >= currentEpochStart + 3 epochs = E5 start
        // Lock1 expiry = E4 start, which is < E5 start → LockExpiresTooSoon
        
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.delegationAction(lock1_Id, user3, DataTypes.DelegationType.Switch);
    }

    // state transition: user 1 undelegates lock2 from user3 
    function test_User1_UndelegatesLock2_FromUser3() public {
        // capture state before undelegation
        // Lock2 is currently delegated to USER2 (after switch), not user3
        UnifiedStateSnapshot memory epoch2_BeforeUndelegation = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, address(0), user2);

        // Get expected values for event emissions
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Calculate lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = convertToVeBalance(epoch2_BeforeUndelegation.lockState.lock);
        
        // Expected user VP after undelegation
        // Since Lock2's delegation to user2 was PENDING (not active), user1 ALREADY has Lock2's VP in userHistory
        // The undelegation just cancels the pending subtract - userHistory stays the same
        uint128 expectedUserBias = epoch2_BeforeUndelegation.userState.userHistory.bias;
        uint128 expectedUserSlope = epoch2_BeforeUndelegation.userState.userHistory.slope;
        
        // Expected delegate (user2) VP after undelegation
        // NOTE: user2's delegateHistory is 0 (pending delegation never activated)
        // So after undelegation, it remains 0
        uint128 expectedDelegateBias = epoch2_BeforeUndelegation.oldDelegateState.delegateHistory.bias;
        uint128 expectedDelegateSlope = epoch2_BeforeUndelegation.oldDelegateState.delegateHistory.slope;

        vm.prank(user1);
            
            vm.expectEmit(true, true, true, true);
            emit Events.GlobalUpdated(epoch2_BeforeUndelegation.globalState.veGlobal.bias, epoch2_BeforeUndelegation.globalState.veGlobal.slope);
            
            vm.expectEmit(true, true, true, true);
            emit Events.UserUpdated(user1, expectedUserBias, expectedUserSlope);
            
            vm.expectEmit(true, true, true, true);
            emit Events.DelegateUpdated(user2, expectedDelegateBias, expectedDelegateSlope);
            
            vm.expectEmit(true, true, true, true);
            emit Events.DelegatedAggregationUpdated(user1, user2, 0, 0);
            
            // LockUndelegated has delegate = address(0), not user2
            vm.expectEmit(true, true, true, true);
            emit Events.LockUndelegated(lock2_Id, user1, address(0));
        
        veMoca.delegationAction(lock2_Id, address(0), DataTypes.DelegationType.Undelegate);

        // verify state changes
        verifyUndelegateLock(epoch2_BeforeUndelegation);
    }

}


//note: User1 undelegates Lock2 from user2; lock2 still in pending state (was switched from user3 to user2)
abstract contract StateE2_User1_Undelegates_Lock2 is StateE2_User1_SwitchDelegate_Lock2 {
    UnifiedStateSnapshot public epoch2_BeforeUndelegate;

    function setUp() public virtual override {
        super.setUp();

        epoch2_BeforeUndelegate = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, 0, address(0), user2);

        vm.prank(user1);
        veMoca.delegationAction(lock2_Id, address(0), DataTypes.DelegationType.Undelegate);
    }
}

contract StateE2_User1_Undelegates_Lock2_Test is StateE2_User1_Undelegates_Lock2 {

    function test_VerifyUndelegate() public {
        verifyUndelegateLock(epoch2_BeforeUndelegate);
    }

    function test_GlobalState() public {
        // ============ Total Locked Amounts ============
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), lock1_MocaAmount + lock2_MocaAmount, "Total MOCA = Lock1 + Lock2");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), lock1_EsMocaAmount + lock2_EsMocaAmount, "Total esMOCA = Lock1 + Lock2");
        
        // ============ Global veBalance ============
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(getLock(lock1_Id));
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        assertEq(globalBias, lock1VeBalance.bias + lock2VeBalance.bias, "Global bias = Lock1 + Lock2");
        assertEq(globalSlope, lock1VeBalance.slope + lock2VeBalance.slope, "Global slope = Lock1 + Lock2");
        
        // ============ Global Slope Changes ============
        assertEq(veMoca.slopeChanges(lock1_Expiry), lock1VeBalance.slope, "SlopeChange at Lock1 expiry");
        assertEq(veMoca.slopeChanges(lock2_Expiry), lock2VeBalance.slope, "SlopeChange at Lock2 expiry");
        
        // ============ Total Supply ============
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        uint128 lock1VP = getValueAt(lock1VeBalance, currentTimestamp);
        uint128 lock2VP = getValueAt(lock2VeBalance, currentTimestamp);
        assertEq(totalSupply, lock1VP + lock2VP, "TotalSupply = Lock1 VP + Lock2 VP");
    }


    function test_User1_State() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // ============ Lock Ownership ============
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        
        assertEq(lock1.owner, user1, "User1 owns Lock1");
        assertEq(lock2.owner, user1, "User1 owns Lock2");
        
        // ============ Personal VP ============
        // User1 has Lock2's VP as personal VP because:
        // - Lock1: delegated to user3 (ACTIVE) - user1 has 0 VP from it
        // - Lock2: switched to user2 (PENDING) - user1 still holds VP until E3
        
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);
        uint128 lock2VPNow = getValueAt(lock2VeBalance, currentTimestamp);
        
        uint128 user1PersonalVP = veMoca.balanceOfAt(user1, currentTimestamp, false);
        assertEq(user1PersonalVP, lock2VPNow, "User1 personal VP = Lock2 VP (pending switch)");
        
        // User1 history has Lock2 (pending delegation not yet active)
        (uint128 user1HistoryBias, uint128 user1HistorySlope) = veMoca.userHistory(user1, currentEpochStart);
        assertEq(user1HistoryBias, lock2VeBalance.bias, "User1 history has Lock2 bias");
        assertEq(user1HistorySlope, lock2VeBalance.slope, "User1 history has Lock2 slope");
        
        // ============ Delegated VP ============
        // User1 has no delegated VP (not a delegate)
        uint128 user1DelegatedVP = veMoca.balanceOfAt(user1, currentTimestamp, true);
        assertEq(user1DelegatedVP, 0, "User1 has 0 delegated VP (not a delegate)");
        
        // ============ Pending Deltas ============
        // User1 has pending subtraction for nextEpoch (Lock2 will be removed)
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        (bool hasAdd, bool hasSub, , DataTypes.VeBalance memory subs) = veMoca.userPendingDeltas(user1, nextEpochStart);
        assertTrue(hasSub, "User1 has pending subtraction");
        assertEq(subs.bias, lock2VeBalance.bias, "User1 pending sub = Lock2");
        assertEq(subs.slope, lock2VeBalance.slope, "User1 pending sub slope = Lock2");
        
        // ============ Slope Changes ============
        // User1 HAS slope changes after undelegation (regained from delegate)
        assertEq(veMoca.userSlopeChanges(user1, lock1_Expiry), 0, "User1 no slope change at Lock1 expiry (still delegated)");
        assertEq(veMoca.userSlopeChanges(user1, lock2_Expiry), lock2VeBalance.slope, "User1 HAS slope change at Lock2 expiry (undelegated)");
        
        // ============ VP at Epoch End ============
        uint128 user1VPAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        uint128 lock2VPAtEpochEnd = getValueAt(lock2VeBalance, getEpochEndTimestamp(currentEpoch));
        assertEq(user1VPAtEpochEnd, lock2VPAtEpochEnd, "User1 VP at E2 end = Lock2 VP");
    }


    function test_User2_State() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // ============ Personal VP ============
        // User2 has no personal locks
        uint128 user2PersonalVP = veMoca.balanceOfAt(user2, currentTimestamp, false);
        assertEq(user2PersonalVP, 0, "User2 has 0 personal VP (no locks)");
        
        (uint128 user2HistoryBias, uint128 user2HistorySlope) = veMoca.userHistory(user2, currentEpochStart);
        assertEq(user2HistoryBias, 0, "User2 user history bias = 0");
        assertEq(user2HistorySlope, 0, "User2 user history slope = 0");
        
        // ============ Delegated VP ============
        // User2 has 0 delegated VP (Lock2 switch is PENDING until E3)
        uint128 user2DelegatedVP = veMoca.balanceOfAt(user2, currentTimestamp, true);
        assertEq(user2DelegatedVP, 0, "User2 has 0 delegated VP (Lock2 switch pending)");
        
        (uint128 user2DelegateHistoryBias, uint128 user2DelegateHistorySlope) = veMoca.delegateHistory(user2, currentEpochStart);
        assertEq(user2DelegateHistoryBias, 0, "User2 delegate history bias = 0");
        assertEq(user2DelegateHistorySlope, 0, "User2 delegate history slope = 0");
        
        // ============ Pending Deltas ============
        // User2 has pending addition for nextEpoch (Lock2 will be added)
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        
        (bool hasAdd, bool hasSub, DataTypes.VeBalance memory adds, ) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
        assertTrue(hasAdd, "User2 has pending addition for Lock2");
        assertEq(adds.bias, lock2VeBalance.bias, "User2 pending add = Lock2");
        assertEq(adds.slope, lock2VeBalance.slope, "User2 pending add slope = Lock2");
                
        // ============ Slope Changes ============
        // User2 has NO slope change (removed by undelegation)
        assertEq(veMoca.delegateSlopeChanges(user2, lock2_Expiry), 0, "User2 NO slope change at Lock2 expiry (undelegated)");
        
        // ============ VP at Epoch End ============
        uint128 user2VPAtEpochEnd = veMoca.balanceAtEpochEnd(user2, currentEpoch, true);
        assertEq(user2VPAtEpochEnd, 0, "User2 VP at E2 end = 0 (switch pending)");
    }

    function test_User3_State() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // ============ Personal VP ============
        // User3 has no personal locks
        uint128 user3PersonalVP = veMoca.balanceOfAt(user3, currentTimestamp, false);
        assertEq(user3PersonalVP, 0, "User3 has 0 personal VP (no locks)");
        
        // ============ Delegated VP ============
        // User3 has delegated VP from Lock1 (ACTIVE)
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(getLock(lock1_Id));
        uint128 user3DelegatedVP = veMoca.balanceOfAt(user3, currentTimestamp, true);
        uint128 lock1VPNow = getValueAt(lock1VeBalance, currentTimestamp);
        assertEq(user3DelegatedVP, lock1VPNow, "User3 delegated VP = Lock1 VP");
        
        // User3 delegate history has Lock1
        (uint128 user3DelegateHistoryBias, uint128 user3DelegateHistorySlope) = veMoca.delegateHistory(user3, currentEpochStart);
        assertEq(user3DelegateHistoryBias, lock1VeBalance.bias, "User3 delegate history bias = Lock1");
        assertEq(user3DelegateHistorySlope, lock1VeBalance.slope, "User3 delegate history slope = Lock1");
        
        // ============ Pending Deltas ============
        // User3 has pending subtraction for nextEpoch (Lock2 will be removed by switch)
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        
        (bool hasAdd, bool hasSub, , DataTypes.VeBalance memory subs) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(hasSub, "User3 has pending subtraction for Lock2");
        assertEq(subs.bias, lock2VeBalance.bias, "User3 pending sub = Lock2");
        assertEq(subs.slope, lock2VeBalance.slope, "User3 pending sub slope = Lock2");
        
        // ============ Slope Changes ============
        // User3 has slope change at Lock1 expiry (active delegation)
        assertEq(veMoca.delegateSlopeChanges(user3, lock1_Expiry), lock1VeBalance.slope, "User3 slope change at Lock1 expiry");
        
        // User3 has NO slope change at Lock2 expiry (removed by switch)
        assertEq(veMoca.delegateSlopeChanges(user3, lock2_Expiry), 0, "User3 slope change at Lock2 expiry removed");
        
        // ============ VP at Epoch End ============
        uint128 user3VPAtEpochEnd = veMoca.balanceAtEpochEnd(user3, currentEpoch, true);
        uint128 lock1VPAtEpochEnd = getValueAt(lock1VeBalance, getEpochEndTimestamp(currentEpoch));
        assertEq(user3VPAtEpochEnd, lock1VPAtEpochEnd, "User3 VP at E2 end = Lock1 VP");
    }

    function test_UserDelegatePairStates() public {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 currentEpoch = getCurrentEpochNumber();
        
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(getLock(lock1_Id));
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        
        // ============ User1-User2 Pair (NEW, from switch) ============
        (uint128 pair12_bias, uint128 pair12_slope) = veMoca.delegatedAggregationHistory(user1, user2, currentEpochStart);
        assertEq(pair12_bias, 0, "User1-User2 pair history bias = 0 (pending)");
        assertEq(pair12_slope, 0, "User1-User2 pair history slope = 0 (pending)");
        
        // Pending addition for Lock2
        (bool hasAdd, , DataTypes.VeBalance memory adds, ) = veMoca.userPendingDeltasForDelegate(user1, user2, nextEpochStart);
        assertTrue(hasAdd, "User1-User2 pair has pending addition");
        assertEq(adds.bias, lock2VeBalance.bias, "User1-User2 pair pending add = Lock2");
        assertEq(adds.slope, lock2VeBalance.slope, "User1-User2 pair pending add slope = Lock2");
                
        // User1-User2 slope change should be 0 (removed by undelegation)
        assertEq(veMoca.userDelegatedSlopeChanges(user1, user2, lock2_Expiry), 0, "User1-User2 NO slope at Lock2 expiry (undelegated)");
        
        // VP = 0 (pending)
        uint128 pair12VP = veMoca.getSpecificDelegatedBalanceAtEpochEnd(user1, user2, currentEpoch);
        assertEq(pair12VP, 0, "User1-User2 VP at E2 end = 0 (pending)");
        
        // ============ User1-User3 Pair (OLD, has Lock1 ACTIVE) ============
        (uint128 pair13_bias, uint128 pair13_slope) = veMoca.delegatedAggregationHistory(user1, user3, currentEpochStart);
        assertEq(pair13_bias, lock1VeBalance.bias, "User1-User3 pair history bias = Lock1");
        assertEq(pair13_slope, lock1VeBalance.slope, "User1-User3 pair history slope = Lock1");
        
        // Pending subtraction for Lock2 (removed by switch)
        (, bool hasSub, , DataTypes.VeBalance memory subs) = veMoca.userPendingDeltasForDelegate(user1, user3, nextEpochStart);
        assertTrue(hasSub, "User1-User3 pair has pending subtraction");
        assertEq(subs.bias, lock2VeBalance.bias, "User1-User3 pair pending sub = Lock2");
        assertEq(subs.slope, lock2VeBalance.slope, "User1-User3 pair pending sub slope = Lock2");
        
        // Slope changes: Lock1 at its expiry, Lock2 removed
        assertEq(veMoca.userDelegatedSlopeChanges(user1, user3, lock1_Expiry), lock1VeBalance.slope, "User1-User3 slope at Lock1 expiry");
        assertEq(veMoca.userDelegatedSlopeChanges(user1, user3, lock2_Expiry), 0, "User1-User3 slope at Lock2 expiry removed");
        
        // VP = Lock1 VP (active)
        uint128 pair13VPNow = getValueAt(lock1VeBalance, uint128(block.timestamp));
        uint128 pair13VPActual = veMoca.getSpecificDelegatedBalanceAtEpochEnd(user1, user3, currentEpoch);
        uint128 lock1VPAtEpochEnd = getValueAt(lock1VeBalance, getEpochEndTimestamp(currentEpoch));
        assertEq(pair13VPActual, lock1VPAtEpochEnd, "User1-User3 VP at E2 end = Lock1 VP");
    }

    function test_VotingPowerConservation() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // ============ Individual VP Checks ============
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(getLock(lock1_Id));
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        uint128 lock1VP = getValueAt(lock1VeBalance, currentTimestamp);
        uint128 lock2VP = getValueAt(lock2VeBalance, currentTimestamp);
        
        // User1: has Lock2 VP (pending switch)
        uint128 user1PersonalVP = veMoca.balanceOfAt(user1, currentTimestamp, false);
        assertEq(user1PersonalVP, lock2VP, "User1 personal VP = Lock2 VP");
        
        // User2: has 0 delegated VP (switch pending)
        uint128 user2DelegatedVP = veMoca.balanceOfAt(user2, currentTimestamp, true);
        assertEq(user2DelegatedVP, 0, "User2 delegated VP = 0 (pending)");
        
        // User3: has Lock1 delegated VP (active)
        uint128 user3DelegatedVP = veMoca.balanceOfAt(user3, currentTimestamp, true);
        assertEq(user3DelegatedVP, lock1VP, "User3 delegated VP = Lock1 VP");
        
        // ============ Total Supply Conservation ============
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        assertEq(totalSupply, lock1VP + lock2VP, "TotalSupply = Lock1 VP + Lock2 VP");
        
        // ============ VP Distribution ============
        // Personal VP: user1 (Lock2)
        // Delegated VP: user3 (Lock1)
        // Total accounted: Lock1 + Lock2 = totalSupply ✓
        assertEq(user1PersonalVP + user3DelegatedVP, totalSupply, "All VP accounted for");
    }

    // state transition: user1 unlocks lock1 in E4 (after it expires)
    function test_User1_UnlocksLock1_InEpoch4() public {
        // ============ Setup: Warp to E4 ============
        uint128 epoch4Start = uint128(getEpochStartTimestamp(4));
        vm.warp(epoch4Start + 1);
        assertEq(getCurrentEpochNumber(), 4, "Current epoch is 4");
        
        // ============ Pre-Unlock Checks ============
        DataTypes.Lock memory lock1Before = getLock(lock1_Id);
        
        // Lock1 should be expired
        assertTrue(lock1Before.expiry <= block.timestamp, "Lock1 has expired");
        assertFalse(lock1Before.isUnlocked, "Lock1 not yet unlocked");
        assertEq(lock1Before.delegate, user3, "Lock1 still delegated to user3");
        
        // Even though delegated, owner can unlock if expired
        assertEq(lock1Before.owner, user1, "Lock1 owner is user1");
        
        // Cache amounts for event verification
        uint128 cachedMoca = lock1Before.moca;
        uint128 cachedEsMoca = lock1Before.esMoca;
        
        // ============ Capture State Before Unlock ============
        uint128 user1MocaBefore = uint128(user1.balance);
        uint128 user1EsMocaBefore = uint128(esMoca.balanceOf(user1));
        uint128 contractMocaBefore = uint128(address(veMoca).balance);
        uint128 contractEsMocaBefore = uint128(esMoca.balanceOf(address(veMoca)));
        
        uint128 totalLockedMocaBefore = veMoca.TOTAL_LOCKED_MOCA();
        uint128 totalLockedEsMocaBefore = veMoca.TOTAL_LOCKED_ESMOCA();
        
        // ============ Expect Event ============
        vm.expectEmit(true, true, true, true);
        emit Events.LockUnlocked(lock1_Id, user1, cachedMoca, cachedEsMoca);
        
        // ============ Execute Unlock ============
        vm.prank(user1);
        veMoca.unlock(lock1_Id);
        
        // ============ Verify Lock State After Unlock ============
        DataTypes.Lock memory lock1After = getLock(lock1_Id);
        
        assertTrue(lock1After.isUnlocked, "Lock1 is unlocked");
        assertEq(lock1After.moca, 0, "Lock1 MOCA cleared");
        assertEq(lock1After.esMoca, 0, "Lock1 esMOCA cleared");
        assertEq(lock1After.owner, user1, "Lock1 owner unchanged");
        assertEq(lock1After.delegate, user3, "Lock1 delegate unchanged (informational only)");
        assertEq(lock1After.expiry, lock1Before.expiry, "Lock1 expiry unchanged");
        
        // ============ Verify Token Transfers ============
        assertEq(uint128(user1.balance), user1MocaBefore + cachedMoca, "User1 MOCA received");
        assertEq(uint128(esMoca.balanceOf(user1)), user1EsMocaBefore + cachedEsMoca, "User1 esMOCA received");
        assertEq(uint128(address(veMoca).balance), contractMocaBefore - cachedMoca, "Contract MOCA decreased");
        assertEq(uint128(esMoca.balanceOf(address(veMoca))), contractEsMocaBefore - cachedEsMoca, "Contract esMOCA decreased");
        
        // ============ Verify Global State ============
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), totalLockedMocaBefore - cachedMoca, "Total Locked MOCA decreased");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), totalLockedEsMocaBefore - cachedEsMoca, "Total Locked esMOCA decreased");
        
        // Total locked should now only include Lock2
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), lock2_MocaAmount, "Total MOCA = Lock2 only");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), lock2_EsMocaAmount, "Total esMOCA = Lock2 only");
        
        // ============ Verify Lock History Updated ============
        uint256 historyLength = veMoca.getLockHistoryLength(lock1_Id);
        assertGt(historyLength, 0, "Lock history exists");
        
        // Latest checkpoint stores the veBalance at the time of last update
        DataTypes.Checkpoint memory latestCheckpoint = getLockHistory(lock1_Id, historyLength - 1);
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1Before);

        assertEq(latestCheckpoint.lastUpdatedAt, getCurrentEpochStart(), "Latest checkpoint at E4 start");
        assertEq(latestCheckpoint.veBalance.bias, lock1VeBalance.bias, "Latest checkpoint bias = Lock1");
        assertEq(latestCheckpoint.veBalance.slope, lock1VeBalance.slope, "Latest checkpoint slope = Lock1");
        
        // ============ Verify Lock VP is 0 ============
        uint128 lock1VPNow = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        assertEq(lock1VPNow, 0, "Lock1 VP = 0 after unlock");
        
        // ============ Verify User3 Delegated VP ============
        // User3 should have 0 delegated VP now (Lock1 unlocked, Lock2 was undelegated)
        uint128 user3DelegatedVP = veMoca.balanceOfAt(user3, uint128(block.timestamp), true);
        assertEq(user3DelegatedVP, 0, "User3 delegated VP = 0 (Lock1 unlocked)");
        
        // ============ Verify User1 Personal VP ============
        // User1 should still have Lock2's VP
        uint128 user1PersonalVP = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        uint128 currentTimestamp = uint128(block.timestamp);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        uint128 lock2VP = getValueAt(lock2VeBalance, currentTimestamp);
        assertEq(user1PersonalVP, lock2VP, "User1 personal VP = Lock2 VP");
        
        // ============ Verify Cannot Re-unlock ============
        vm.expectRevert(Errors.InvalidLockState.selector);
        vm.prank(user1);
        veMoca.unlock(lock1_Id);
    }

}


// ================= PHASE 4: UNLOCK EXPIRED LOCK (E4) =================

abstract contract StateE4_User1_Unlocks_Lock1 is StateE2_User1_Undelegates_Lock2 {
    
    UnifiedStateSnapshot public epoch4_BeforeUnlock;

    function setUp() public virtual override {
        super.setUp();

        // Warp to E4
        uint128 epoch4Start = uint128(getEpochStartTimestamp(4));
        vm.warp(epoch4Start + 1);
        assertEq(getCurrentEpochNumber(), 4, "Epoch 4");

        // capture state before unlock
        epoch4_BeforeUnlock = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        // Unlock Lock1 (Delegated to User3 but Expired)
        // Even though delegated, owner can unlock if expired
        vm.prank(user1);
        veMoca.unlock(lock1_Id);
    }
}

contract StateE4_User1_Unlocks_Lock1_Test is StateE4_User1_Unlocks_Lock1 {

    function test_GlobalState_MatchesLock2Only() public {
        // ============ Total Locked Amounts ============
        // Only Lock2 remains in the system
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), lock2_MocaAmount, "Total MOCA = Lock2 only");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), lock2_EsMocaAmount, "Total esMOCA = Lock2 only");
        
        // ============ Total Supply = Lock2 VP ============
        // totalSupplyAtTimestamp correctly applies slope changes and decay
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        // Lock2's VP at current timestamp
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        uint128 lock2VP = getValueAt(lock2VeBalance, currentTimestamp);
        assertEq(totalSupply, lock2VP, "Total supply = Lock2 VP");
        
        // ============ Global Slope Changes ============
        // Lock2's slope should be scheduled at its expiry
        uint128 lock2Expiry = getLock(lock2_Id).expiry;
        uint128 slopeChange = veMoca.slopeChanges(lock2Expiry);
        assertEq(slopeChange, uint128(lock2VeBalance.slope), "Global slope change at Lock2 expiry");
        
        // Lock1's slope change at its expiry should still be present (not yet processed by cronjob)
        // but Lock1 expired at E3 end = E4 start, so it's effectively 0 contribution now
        
        // ============ veGlobal is stale but totalSupply is correct ============
        // Note: veGlobal hasn't been updated to E4, but the view function 
        // totalSupplyAtTimestamp() correctly projects the value
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        uint128 lastUpdated = veMoca.lastUpdatedTimestamp();
        
        // veGlobal is stale (from E2), but projected value should match Lock2 VP
        // The stale veGlobal includes Lock1's expired contribution in bias/slope
        // which gets zeroed out when projecting to current time
        assertTrue(lastUpdated < currentTimestamp, "veGlobal is stale");
    }

    function test_Lock1_RemovedFromSystem() public {
        // ============ Lock1 State ============
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        
        assertTrue(lock1.isUnlocked, "Lock1 is unlocked");
        assertEq(lock1.moca, 0, "Lock1 MOCA = 0");
        assertEq(lock1.esMoca, 0, "Lock1 esMOCA = 0");
        assertEq(lock1.owner, user1, "Lock1 owner unchanged");
        assertEq(lock1.delegate, user3, "Lock1 delegate unchanged (informational)");
        
        // ============ Lock1 VP = 0 ============
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        assertEq(lock1VP, 0, "Lock1 VP = 0");
        
        // ============ User1 Received Principals ============
        // User1 should have received 100 ether MOCA and 100 ether esMOCA
        assertEq(user1.balance, lock1_MocaAmount, "User1 received Lock1 MOCA");
        assertEq(esMoca.balanceOf(user1), lock1_EsMocaAmount, "User1 received Lock1 esMOCA");
        
        // ============ Contract Balance Decreased ============
        // Contract should only hold Lock2's amounts now
        assertEq(address(veMoca).balance, lock2_MocaAmount, "Contract MOCA = Lock2 only");
        assertEq(esMoca.balanceOf(address(veMoca)), lock2_EsMocaAmount, "Contract esMOCA = Lock2 only");
    }

    function test_User1_HasLock2PersonalVP() public {
        // User1 owns Lock2 (undelegated), should have personal VP
        uint128 currentTimestamp = uint128(block.timestamp);
        
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
        uint128 expectedVP = getValueAt(lock2VeBalance, currentTimestamp);
        
        uint128 user1PersonalVP = veMoca.balanceOfAt(user1, currentTimestamp, false);
        assertEq(user1PersonalVP, expectedVP, "User1 personal VP = Lock2 VP");
        
        // User1 has 0 delegated VP (no one delegating to user1)
        uint128 user1DelegatedVP = veMoca.balanceOfAt(user1, currentTimestamp, true);
        assertEq(user1DelegatedVP, 0, "User1 delegated VP = 0");
    }

    function test_User3_HasZeroDelegations() public {
        // Lock1 expired and unlocked.
        // Lock2 undelegated.
        // User3 should have 0 delegated VP.
        uint128 vp = veMoca.balanceOfAt(user3, uint128(block.timestamp), true);
        assertEq(vp, 0, "User3 has 0 delegated VP");
        
        // User3 has no personal VP (no locks)
        uint128 user3PersonalVP = veMoca.balanceOfAt(user3, uint128(block.timestamp), false);
        assertEq(user3PersonalVP, 0, "User3 has 0 personal VP");
        
        // Verify delegate history is 0
        (uint128 delegateBias, uint128 delegateSlope) = veMoca.delegateHistory(user3, getCurrentEpochStart());
        assertEq(delegateBias, 0, "User3 delegate history bias = 0");
        assertEq(delegateSlope, 0, "User3 delegate history slope = 0");
    }

    function test_User2_HasNoDelegations() public {
        // Lock2 was never actually delegated to user2 (was pending, then undelegated)
        uint128 user2DelegatedVP = veMoca.balanceOfAt(user2, uint128(block.timestamp), true);
        assertEq(user2DelegatedVP, 0, "User2 has 0 delegated VP");
    }
}


// ================= PHASE 5: MULTI-USER SCENARIOS =================

// note: User3 creates Lock3 and delegates to User2
// note: user2 has multiple delegations
abstract contract StateE4_User3_DelegateLock3_ToUser2 is StateE4_User1_Unlocks_Lock1 {

    bytes32 public lock3_Id;
    bytes32 public lock4_Id;
    bytes32 public lock5_Id;

    function setUp() public virtual override {
        super.setUp();

        // User3 creates Lock3 and delegates to User2
        uint128 expiry = uint128(getEpochEndTimestamp(15));
        vm.startPrank(user3);
            vm.deal(user3, 100 ether);
            lock3_Id = veMoca.createLock{value: 100 ether}(expiry, 0);
            veMoca.delegationAction(lock3_Id, user2, DataTypes.DelegationType.Delegate);
        vm.stopPrank();
    }
}

//user1: lock 2 undelegated (belongs to itself)
//user2: lock3 delegated to user2
contract StateE4_User3_DelegateLock3_ToUser2_Test is StateE4_User3_DelegateLock3_ToUser2 {

    function test_MultiUser_User2_CreatesLock4() public {
        // ============ SETUP: Create Lock4 and Lock5 ============

        uint128 lock4_Expiry = uint128(getEpochEndTimestamp(16));
        uint128 lock5_Expiry = uint128(getEpochEndTimestamp(16));
        uint128 lock4_MocaAmount = 100 ether;
        uint128 lock5_MocaAmount = 100 ether;

        // Register user1 as delegate (for Lock5 delegation)
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user1, true);

        // User2 creates personal Lock4
        vm.startPrank(user2);
            vm.deal(user2, lock4_MocaAmount);
            lock4_Id = veMoca.createLock{value: lock4_MocaAmount}(lock4_Expiry, 0);
        vm.stopPrank();

        // User2 creates Lock5 delegated to User1
        vm.startPrank(user2);
            vm.deal(user2, lock5_MocaAmount);
            lock5_Id = veMoca.createLock{value: lock5_MocaAmount}(lock5_Expiry, 0);
            veMoca.delegationAction(lock5_Id, user1, DataTypes.DelegationType.Delegate);
        vm.stopPrank();

        // ============ CURRENT STATE SUMMARY ============
        // E4: Epoch 4
        // Lock1: UNLOCKED (user1's, was delegated to user3, expired at E3)
        // Lock2: user1's, UNDELEGATED
        // Lock3: user3's, delegated to user2 (PENDING until E5)
        // Lock4: user2's PERSONAL lock (no delegation)
        // Lock5: user2's, delegated to user1 (PENDING until E5)

        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;

        // ============ 1. VERIFY GLOBAL STATE ============

            // 1.1 Total Locked Amounts: Lock2 + Lock3 + Lock4 + Lock5 (Lock1 is unlocked)
            assertEq(veMoca.TOTAL_LOCKED_MOCA(), lock2_MocaAmount + 100 ether + lock4_MocaAmount + lock5_MocaAmount, "Total MOCA = Lock2 + Lock3 + Lock4 + Lock5");
            assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), lock2_EsMocaAmount, "Total esMOCA = Lock2 only (others have 0 esMOCA)");
            
            // 1.2 Global veBalance reflects all active locks
            DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(getLock(lock2_Id));
            DataTypes.VeBalance memory lock3VeBalance = convertToVeBalance(getLock(lock3_Id));
            DataTypes.VeBalance memory lock4VeBalance = convertToVeBalance(getLock(lock4_Id));
            DataTypes.VeBalance memory lock5VeBalance = convertToVeBalance(getLock(lock5_Id));
            
            (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
            uint128 expectedGlobalSlope = lock2VeBalance.slope + lock3VeBalance.slope + lock4VeBalance.slope + lock5VeBalance.slope;
            uint128 expectedGlobalBias = lock2VeBalance.bias + lock3VeBalance.bias + lock4VeBalance.bias + lock5VeBalance.bias;
            
            assertEq(globalSlope, expectedGlobalSlope, "Global slope = sum of all active locks");
            assertEq(globalBias, expectedGlobalBias, "Global bias = sum of all active locks");
            
            // 1.3 Global Slope Changes at expiries
            assertEq(veMoca.slopeChanges(lock2_Expiry), lock2VeBalance.slope, "SlopeChange at Lock2 expiry");
            assertEq(veMoca.slopeChanges(getLock(lock3_Id).expiry), lock3VeBalance.slope, "SlopeChange at Lock3 expiry");
            assertEq(veMoca.slopeChanges(lock4_Expiry), lock4VeBalance.slope + lock5VeBalance.slope, "SlopeChange at Lock4/5 expiry (same expiry)");
            
            // 1.4 Total Supply = sum of all lock VPs
            uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
            uint128 lock2VP = getValueAt(lock2VeBalance, currentTimestamp);
            uint128 lock3VP = getValueAt(lock3VeBalance, currentTimestamp);
            uint128 lock4VP = getValueAt(lock4VeBalance, currentTimestamp);
            uint128 lock5VP = getValueAt(lock5VeBalance, currentTimestamp);
            assertEq(totalSupply, lock2VP + lock3VP + lock4VP + lock5VP, "TotalSupply = sum of all lock VPs");

        // ============ 2. VERIFY USER1 STATE ============
            // User1: Owns Lock2 (undelegated), receives Lock5 delegation (PENDING)

            // 2.1 Personal VP = Lock2 VP
            uint128 user1PersonalVP = veMoca.balanceOfAt(user1, currentTimestamp, false);
            assertEq(user1PersonalVP, lock2VP, "User1 personal VP = Lock2 VP");
            
            // 2.2 Delegated VP = 0 (Lock5 delegation is PENDING)
            uint128 user1DelegatedVP = veMoca.balanceOfAt(user1, currentTimestamp, true);
            assertEq(user1DelegatedVP, 0, "User1 delegated VP = 0 (Lock5 pending)");
            
            // 2.3 User1 has pending ADDITION for Lock5 as delegate
            (bool u1HasAdd, , DataTypes.VeBalance memory u1Adds, ) = veMoca.delegatePendingDeltas(user1, nextEpochStart);
            assertTrue(u1HasAdd, "User1 has pending addition (Lock5)");
            assertEq(u1Adds.bias, lock5VeBalance.bias, "User1 pending add bias = Lock5 bias");
            assertEq(u1Adds.slope, lock5VeBalance.slope, "User1 pending add slope = Lock5 slope");
            
            // 2.4 User1 delegate slope change at Lock5 expiry
            assertEq(veMoca.delegateSlopeChanges(user1, lock5_Expiry), lock5VeBalance.slope, "User1 delegate slopeChange at Lock5 expiry");
            
            // 2.5 User1 VP at epoch end
            uint128 user1VPAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
            uint128 lock2VPAtEpochEnd = getValueAt(lock2VeBalance, getEpochEndTimestamp(currentEpoch));
            assertEq(user1VPAtEpochEnd, lock2VPAtEpochEnd, "User1 VP at E4 end = Lock2 VP");

        // ============ 3. VERIFY USER2 STATE ============
            // User2: Owns Lock4 (personal), Lock5 (delegated to user1), receives Lock3 (PENDING)

            // 3.1 Personal VP = Lock4 VP (Lock5 is still pending delegation, so user2 has Lock5 VP too)
            uint128 user2PersonalVP = veMoca.balanceOfAt(user2, currentTimestamp, false);
            assertEq(user2PersonalVP, lock4VP + lock5VP, "User2 personal VP = Lock4 + Lock5 (pending delegation)");
            
            // 3.2 Delegated VP = 0 (Lock3 delegation is PENDING)
            uint128 user2DelegatedVP = veMoca.balanceOfAt(user2, currentTimestamp, true);
            assertEq(user2DelegatedVP, 0, "User2 delegated VP = 0 (Lock3 pending)");
            
            // 3.3 User2 has pending ADDITION for Lock3 as delegate
            (bool u2HasAdd, , DataTypes.VeBalance memory u2Adds, ) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
            assertTrue(u2HasAdd, "User2 has pending addition (Lock3)");
            assertEq(u2Adds.bias, lock3VeBalance.bias, "User2 pending add bias = Lock3 bias");
            assertEq(u2Adds.slope, lock3VeBalance.slope, "User2 pending add slope = Lock3 slope");
            
            // 3.4 User2 has pending SUBTRACTION for Lock5 as owner
            (, bool u2HasSub, , DataTypes.VeBalance memory u2Subs) = veMoca.userPendingDeltas(user2, nextEpochStart);
            assertTrue(u2HasSub, "User2 has pending subtraction (Lock5)");
            assertEq(u2Subs.bias, lock5VeBalance.bias, "User2 pending sub bias = Lock5 bias");
            assertEq(u2Subs.slope, lock5VeBalance.slope, "User2 pending sub slope = Lock5 slope");
            
            // 3.5 User2 delegate slope change at Lock3 expiry
            assertEq(veMoca.delegateSlopeChanges(user2, getLock(lock3_Id).expiry), lock3VeBalance.slope, "User2 delegate slopeChange at Lock3 expiry");
            
            // 3.6 User2 user slope changes
            assertEq(veMoca.userSlopeChanges(user2, lock4_Expiry), lock4VeBalance.slope, "User2 user slopeChange at Lock4 expiry");
            // Lock5 slope is NOT in userSlopeChanges (moved to delegate)
            // Lock4 and Lock5 have same expiry, so we check just Lock4's contribution
            
            // 3.7 User2 VP at epoch end
            uint128 user2VPAtEpochEnd = veMoca.balanceAtEpochEnd(user2, currentEpoch, false);
            uint128 lock4VPAtEpochEnd = getValueAt(lock4VeBalance, getEpochEndTimestamp(currentEpoch));
            uint128 lock5VPAtEpochEnd = getValueAt(lock5VeBalance, getEpochEndTimestamp(currentEpoch));
            assertEq(user2VPAtEpochEnd, lock4VPAtEpochEnd + lock5VPAtEpochEnd, "User2 VP at E4 end = Lock4 + Lock5 (pending)");

        // ============ 4. VERIFY USER3 STATE ============
            // User3: Owns Lock3 (delegated to user2, PENDING), no delegations received

            // 4.1 Personal VP = Lock3 VP (delegation is PENDING)
            uint128 user3PersonalVP = veMoca.balanceOfAt(user3, currentTimestamp, false);
            assertEq(user3PersonalVP, lock3VP, "User3 personal VP = Lock3 VP (pending delegation)");
            
            // 4.2 Delegated VP = 0 (no one delegating to user3, Lock1 was unlocked)
            uint128 user3DelegatedVP = veMoca.balanceOfAt(user3, currentTimestamp, true);
            assertEq(user3DelegatedVP, 0, "User3 delegated VP = 0 (Lock1 unlocked, no active delegations)");
            
            // 4.3 User3 has pending SUBTRACTION for Lock3 as owner
            (, bool u3HasSub, , DataTypes.VeBalance memory u3Subs) = veMoca.userPendingDeltas(user3, nextEpochStart);
            assertTrue(u3HasSub, "User3 has pending subtraction (Lock3)");
            assertEq(u3Subs.bias, lock3VeBalance.bias, "User3 pending sub bias = Lock3 bias");
            assertEq(u3Subs.slope, lock3VeBalance.slope, "User3 pending sub slope = Lock3 slope");
            
            // 4.4 User3 user slope changes: Lock3 is NOT in userSlopeChanges (moved to delegate)
            assertEq(veMoca.userSlopeChanges(user3, getLock(lock3_Id).expiry), 0, "User3 user slopeChange at Lock3 expiry = 0 (moved to delegate)");
            
            // 4.5 User3 VP at epoch end
            uint128 user3VPAtEpochEnd = veMoca.balanceAtEpochEnd(user3, currentEpoch, false);
            uint128 lock3VPAtEpochEnd = getValueAt(lock3VeBalance, getEpochEndTimestamp(currentEpoch));
            assertEq(user3VPAtEpochEnd, lock3VPAtEpochEnd, "User3 VP at E4 end = Lock3 VP");

        // ============ 5. VERIFY LOCK1 STATE (UNLOCKED) ============

            DataTypes.Lock memory lock1 = getLock(lock1_Id);
            assertTrue(lock1.isUnlocked, "Lock1 is unlocked");
            assertEq(lock1.moca, 0, "Lock1 MOCA = 0");
            assertEq(lock1.esMoca, 0, "Lock1 esMOCA = 0");
            assertEq(lock1.owner, user1, "Lock1 owner = user1");
            assertEq(lock1.delegate, user3, "Lock1 delegate = user3 (informational only)");
            
            // Lock1 VP = 0
            uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
            assertEq(lock1VP, 0, "Lock1 VP = 0 (unlocked)");

        // ============ 6. VERIFY LOCK3 STATE (PENDING DELEGATION) ============

            DataTypes.Lock memory lock3 = getLock(lock3_Id);
            assertFalse(lock3.isUnlocked, "Lock3 is not unlocked");
            assertEq(lock3.moca, 100 ether, "Lock3 MOCA = 100 ether");
            assertEq(lock3.esMoca, 0, "Lock3 esMOCA = 0");
            assertEq(lock3.owner, user3, "Lock3 owner = user3");
            assertEq(lock3.delegate, user2, "Lock3 delegate = user2");
            
            // Lock3 delegation is PENDING (delegationEpoch > currentEpochStart)
            assertGt(lock3.delegationEpoch, currentEpochStart, "Lock3 delegation is pending");
            
            // Lock3 VP
            uint128 lock3VPActual = veMoca.getLockVotingPowerAt(lock3_Id, currentTimestamp);
            assertEq(lock3VPActual, lock3VP, "Lock3 VP matches calculated");

        // ============ 7. VERIFY USER-DELEGATE PAIR STATES ============

            // 7.1 User2-User1 pair (Lock5 PENDING)
            (uint128 pair21_bias, uint128 pair21_slope) = veMoca.delegatedAggregationHistory(user2, user1, currentEpochStart);
            assertEq(pair21_bias, 0, "User2-User1 pair history bias = 0 (pending)");
            assertEq(pair21_slope, 0, "User2-User1 pair history slope = 0 (pending)");
            
            (bool p21HasAdd, , DataTypes.VeBalance memory p21Adds, ) = veMoca.userPendingDeltasForDelegate(user2, user1, nextEpochStart);
            assertTrue(p21HasAdd, "User2-User1 pair has pending addition (Lock5)");
            assertEq(p21Adds.bias, lock5VeBalance.bias, "User2-User1 pending add bias = Lock5");
            assertEq(p21Adds.slope, lock5VeBalance.slope, "User2-User1 pending add slope = Lock5");
            
            // 7.2 User3-User2 pair (Lock3 PENDING)
            (uint128 pair32_bias, uint128 pair32_slope) = veMoca.delegatedAggregationHistory(user3, user2, currentEpochStart);
            assertEq(pair32_bias, 0, "User3-User2 pair history bias = 0 (pending)");
            assertEq(pair32_slope, 0, "User3-User2 pair history slope = 0 (pending)");
            
            (bool p32HasAdd, , DataTypes.VeBalance memory p32Adds, ) = veMoca.userPendingDeltasForDelegate(user3, user2, nextEpochStart);
            assertTrue(p32HasAdd, "User3-User2 pair has pending addition (Lock3)");
            assertEq(p32Adds.bias, lock3VeBalance.bias, "User3-User2 pending add bias = Lock3");
            assertEq(p32Adds.slope, lock3VeBalance.slope, "User3-User2 pending add slope = Lock3");

        // ============ 8. VOTING POWER CONSERVATION ============

            // All VP must be accounted for across the system
            // Personal VP: user1 (Lock2), user2 (Lock4 + Lock5 pending), user3 (Lock3 pending)
            // Delegated VP: user1 (Lock5 pending = 0), user2 (Lock3 pending = 0), user3 (0)
            
            uint128 totalPersonalVP = user1PersonalVP + user2PersonalVP + user3PersonalVP;
            uint128 totalDelegatedVP = user1DelegatedVP + user2DelegatedVP + user3DelegatedVP;
            
            // In E4, all delegations are PENDING, so personal VP = total lock VPs
            assertEq(totalPersonalVP, lock2VP + lock3VP + lock4VP + lock5VP, "Total personal VP = all lock VPs");
            assertEq(totalDelegatedVP, 0, "Total delegated VP = 0 (all pending)");
            assertEq(totalSupply, totalPersonalVP, "TotalSupply = total personal VP (no active delegations)");
    }

    function testRevert_EmergencyExit_NotFrozen() public {
        // Contract is not frozen, emergencyExit should revert
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = lock2_Id;

        vm.expectRevert(Errors.NotFrozen.selector);
        vm.prank(emergencyExitHandler);
        veMoca.emergencyExit(ids);
    }
}

// ================= PHASE 6: EMERGENCY EXIT =================

abstract contract StateEmergencyExit is StateE4_User3_DelegateLock3_ToUser2 {
    function setUp() public virtual override {
        super.setUp();

        // Freeze
        vm.startPrank(monitor);
            veMoca.pause();
        vm.stopPrank();
        vm.startPrank(globalAdmin);
            veMoca.freeze();
        vm.stopPrank();
    }
}

contract StateEmergencyExit_Test is StateEmergencyExit {

    function test_EmergencyExit_AllLocksProcessed() public {
        // ============ STATE SUMMARY ============
        // Lock1: UNLOCKED (already processed in E4)
        // Lock2: user1's, UNDELEGATED (250 MOCA + 250 esMOCA after increaseAmount)
        // Lock3: user3's, delegated to user2 (PENDING) (100 MOCA, 0 esMOCA)

        // ============ 1. CAPTURE PRE-STATE ============

        // Lock2 state
        DataTypes.Lock memory lock2Before = getLock(lock2_Id);
        uint128 lock2Moca = lock2Before.moca;
        uint128 lock2EsMoca = lock2Before.esMoca;
        assertEq(lock2Moca, lock2_MocaAmount, "Lock2 MOCA matches expected");
        assertEq(lock2EsMoca, lock2_EsMocaAmount, "Lock2 esMOCA matches expected");
        assertFalse(lock2Before.isUnlocked, "Lock2 not yet unlocked");
        assertEq(lock2Before.delegate, address(0), "Lock2 is undelegated");

        // Lock3 state
        DataTypes.Lock memory lock3Before = getLock(lock3_Id);
        uint128 lock3Moca = lock3Before.moca;
        uint128 lock3EsMoca = lock3Before.esMoca;
        assertEq(lock3Moca, 100 ether, "Lock3 MOCA = 100 ether");
        assertEq(lock3EsMoca, 0, "Lock3 esMOCA = 0");
        assertFalse(lock3Before.isUnlocked, "Lock3 not yet unlocked");
        assertEq(lock3Before.delegate, user2, "Lock3 is delegated to user2");

        // Lock1 state (already unlocked)
        DataTypes.Lock memory lock1Before = getLock(lock1_Id);
        assertTrue(lock1Before.isUnlocked, "Lock1 already unlocked");

        // User balances before
        uint256 user1MocaBefore = user1.balance;
        uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
        uint256 user3MocaBefore = user3.balance;
        uint256 user3EsMocaBefore = esMoca.balanceOf(user3);

        // Contract balances before
        uint256 contractMocaBefore = address(veMoca).balance;
        uint256 contractEsMocaBefore = esMoca.balanceOf(address(veMoca));

        // Global state before
        uint128 totalLockedMocaBefore = veMoca.TOTAL_LOCKED_MOCA();
        uint128 totalLockedEsMocaBefore = veMoca.TOTAL_LOCKED_ESMOCA();

        // ============ 2. PREPARE EMERGENCY EXIT ============

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = lock2_Id; // user1's undelegated lock
        ids[1] = lock3_Id; // user3's delegated lock (pending)
        ids[2] = lock1_Id; // Already unlocked - should be skipped

        // Calculate expected totals
        uint128 expectedTotalMoca = lock2Moca + lock3Moca;
        uint128 expectedTotalEsMoca = lock2EsMoca + lock3EsMoca;
        uint128 expectedValidLocks = 2; // Lock1 is already unlocked, so only 2 valid

        // ============ 3. EXECUTE WITH EVENT VERIFICATION ============

        vm.expectEmit(true, true, true, true);
        emit Events.EmergencyExit(ids, expectedValidLocks, expectedTotalMoca, expectedTotalEsMoca);

        vm.prank(emergencyExitHandler);
        (uint256 processedCount, uint256 mocaReturned, uint256 esMocaReturned) = veMoca.emergencyExit(ids);

        // ============ 4. VERIFY RETURN VALUES ============

        assertEq(processedCount, expectedValidLocks, "Processed count = 2 (Lock1 skipped)");
        assertEq(mocaReturned, expectedTotalMoca, "MOCA returned matches");
        assertEq(esMocaReturned, expectedTotalEsMoca, "esMOCA returned matches");

        // ============ 5. VERIFY LOCK STATES ============

        // Lock2: Unlocked, amounts cleared
        DataTypes.Lock memory lock2After = getLock(lock2_Id);
        assertTrue(lock2After.isUnlocked, "Lock2 is unlocked");
        assertEq(lock2After.moca, 0, "Lock2 MOCA cleared");
        assertEq(lock2After.esMoca, 0, "Lock2 esMOCA cleared");
        assertEq(lock2After.owner, user1, "Lock2 owner preserved");
        assertEq(lock2After.expiry, lock2Before.expiry, "Lock2 expiry preserved");
        assertEq(lock2After.delegate, lock2Before.delegate, "Lock2 delegate preserved");

        // Lock3: Unlocked, amounts cleared (even though delegated)
        DataTypes.Lock memory lock3After = getLock(lock3_Id);
        assertTrue(lock3After.isUnlocked, "Lock3 is unlocked");
        assertEq(lock3After.moca, 0, "Lock3 MOCA cleared");
        assertEq(lock3After.esMoca, 0, "Lock3 esMOCA cleared");
        assertEq(lock3After.owner, user3, "Lock3 owner preserved");
        assertEq(lock3After.expiry, lock3Before.expiry, "Lock3 expiry preserved");
        assertEq(lock3After.delegate, lock3Before.delegate, "Lock3 delegate preserved (informational)");

        // Lock1: Still unlocked (was skipped)
        DataTypes.Lock memory lock1After = getLock(lock1_Id);
        assertTrue(lock1After.isUnlocked, "Lock1 still unlocked");

        // ============ 6. VERIFY TOKEN TRANSFERS ============

        // User1 received Lock2's tokens
        assertEq(user1.balance, user1MocaBefore + lock2Moca, "User1 received Lock2 MOCA");
        assertEq(esMoca.balanceOf(user1), user1EsMocaBefore + lock2EsMoca, "User1 received Lock2 esMOCA");

        // User3 received Lock3's tokens (owner, not delegate)
        assertEq(user3.balance, user3MocaBefore + lock3Moca, "User3 received Lock3 MOCA");
        assertEq(esMoca.balanceOf(user3), user3EsMocaBefore + lock3EsMoca, "User3 received Lock3 esMOCA (0)");

        // Contract balances decreased
        assertEq(address(veMoca).balance, contractMocaBefore - expectedTotalMoca, "Contract MOCA decreased");
        assertEq(esMoca.balanceOf(address(veMoca)), contractEsMocaBefore - expectedTotalEsMoca, "Contract esMOCA decreased");

        // ============ 7. VERIFY GLOBAL STATE ============

        assertEq(veMoca.TOTAL_LOCKED_MOCA(), totalLockedMocaBefore - expectedTotalMoca, "TOTAL_LOCKED_MOCA decreased");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), totalLockedEsMocaBefore - expectedTotalEsMoca, "TOTAL_LOCKED_ESMOCA decreased");

        // All locks processed, totals should be 0
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), 0, "TOTAL_LOCKED_MOCA = 0");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), 0, "TOTAL_LOCKED_ESMOCA = 0");
        assertEq(address(veMoca).balance, 0, "Contract MOCA balance = 0");
        assertEq(esMoca.balanceOf(address(veMoca)), 0, "Contract esMOCA balance = 0");
    }

    // Note: testRevert_EmergencyExit_NotFrozen cannot be tested here because
    // freeze is a one-way action. This is tested in StateE4_User3_DelegateLock3_ToUser2_Test
    // where the contract is not yet frozen.

    function testRevert_EmergencyExit_Unauthorized() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = lock2_Id;

        // user1 is not emergencyExitHandler
        vm.expectRevert();
        vm.prank(user1);
        veMoca.emergencyExit(ids);
    }

    function testRevert_EmergencyExit_EmptyArray() public {
        bytes32[] memory ids = new bytes32[](0);

        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(emergencyExitHandler);
        veMoca.emergencyExit(ids);
    }

    function test_EmergencyExit_SkipsInvalidLocks() public {
        // Create array with invalid lock IDs
        bytes32[] memory ids = new bytes32[](3);
        ids[0] = lock2_Id;                                    // Valid
        ids[1] = keccak256(abi.encodePacked("nonexistent"));  // Invalid (owner = address(0))
        ids[2] = lock1_Id;                                    // Invalid (already unlocked)

        // Capture pre-state
        DataTypes.Lock memory lock2Before = getLock(lock2_Id);
        uint256 user1MocaBefore = user1.balance;
        uint256 user1EsMocaBefore = esMoca.balanceOf(user1);

        // Only Lock2 should be processed
        vm.prank(emergencyExitHandler);
        (uint256 processedCount, uint256 mocaReturned, uint256 esMocaReturned) = veMoca.emergencyExit(ids);

        assertEq(processedCount, 1, "Only 1 lock processed");
        assertEq(mocaReturned, lock2Before.moca, "Only Lock2 MOCA returned");
        assertEq(esMocaReturned, lock2Before.esMoca, "Only Lock2 esMOCA returned");

        // User1 received tokens
        assertEq(user1.balance, user1MocaBefore + lock2Before.moca, "User1 received MOCA");
        assertEq(esMoca.balanceOf(user1), user1EsMocaBefore + lock2Before.esMoca, "User1 received esMOCA");

        // Lock2 is now unlocked
        assertTrue(getLock(lock2_Id).isUnlocked, "Lock2 unlocked");
    }

    function test_EmergencyExit_DelegatedLockReturnsToOwner() public {
        // Verify Lock3 is delegated to user2 but owned by user3
        DataTypes.Lock memory lock3Before = getLock(lock3_Id);
        assertEq(lock3Before.owner, user3, "Lock3 owner is user3");
        assertEq(lock3Before.delegate, user2, "Lock3 delegated to user2");

        uint256 user2MocaBefore = user2.balance;
        uint256 user3MocaBefore = user3.balance;

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = lock3_Id;

        vm.prank(emergencyExitHandler);
        veMoca.emergencyExit(ids);

        // Tokens go to OWNER (user3), NOT delegate (user2)
        assertEq(user3.balance, user3MocaBefore + lock3Before.moca, "Owner (user3) received MOCA");
        assertEq(user2.balance, user2MocaBefore, "Delegate (user2) received nothing");

        // Lock3 is unlocked
        assertTrue(getLock(lock3_Id).isUnlocked, "Lock3 unlocked");
    }

    function test_EmergencyExit_NoEventIfNoValidLocks() public {
        // All locks in array are already unlocked or invalid
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = lock1_Id;                                    // Already unlocked
        ids[1] = keccak256(abi.encodePacked("nonexistent"));  // Invalid

        // No event should be emitted (processedCount = 0)
        vm.recordLogs();
        
        vm.prank(emergencyExitHandler);
        (uint256 processedCount, uint256 mocaReturned, uint256 esMocaReturned) = veMoca.emergencyExit(ids);

        assertEq(processedCount, 0, "No locks processed");
        assertEq(mocaReturned, 0, "No MOCA returned");
        assertEq(esMocaReturned, 0, "No esMOCA returned");

        // Verify no EmergencyExit event emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 emergencyExitSig = keccak256("EmergencyExit(bytes32[],uint256,uint256,uint256)");
        bool foundEvent = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == emergencyExitSig) {
                foundEvent = true;
                break;
            }
        }
        assertFalse(foundEvent, "No EmergencyExit event emitted");
    }

    function test_EmergencyExit_MocaOnlyLock() public {
        // Lock3 has only MOCA (no esMOCA)
        DataTypes.Lock memory lock3Before = getLock(lock3_Id);
        assertGt(lock3Before.moca, 0, "Lock3 has MOCA");
        assertEq(lock3Before.esMoca, 0, "Lock3 has no esMOCA");

        uint256 user3MocaBefore = user3.balance;
        uint256 user3EsMocaBefore = esMoca.balanceOf(user3);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = lock3_Id;

        vm.prank(emergencyExitHandler);
        (uint256 processedCount, uint256 mocaReturned, uint256 esMocaReturned) = veMoca.emergencyExit(ids);

        assertEq(processedCount, 1, "1 lock processed");
        assertEq(mocaReturned, lock3Before.moca, "MOCA returned");
        assertEq(esMocaReturned, 0, "No esMOCA returned");

        assertEq(user3.balance, user3MocaBefore + lock3Before.moca, "User3 received MOCA");
        assertEq(esMoca.balanceOf(user3), user3EsMocaBefore, "User3 esMOCA unchanged");
    }
}
