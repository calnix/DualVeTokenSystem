// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import {Constants} from "../../src/libraries/Constants.sol";

import "./delegateHelper.sol";

//note: vm.warp(EPOCH_DURATION);
abstract contract StateE1_Deploy is TestingHarness, DelegateHelper {    

    function setUp() public virtual override {
        super.setUp();

        vm.warp(EPOCH_DURATION);
        assertTrue(getCurrentEpochStart() > 0, "Current epoch start time is greater than 0");
    }
}


contract StateE1_Deploy_Test is StateE1_Deploy {
    using stdStorage for StdStorage;
    

    function test_User1_CreateLock_T1() public {

        // 1) Setup: fund user
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // 2) Test parameters
        uint128 expiry = uint128(getEpochEndTimestamp(3)); 
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;
        bytes32 expectedLockId = generateLockId(block.number, user1);
        
        uint128 expectedSlope = (mocaAmount + esMocaAmount) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        // 3) Capture State
        UnifiedStateSnapshot memory beforeState = captureAllStates(user1, expectedLockId, expiry, 0);
            TokensSnapshot memory beforeTokens = beforeState.tokensState;
            GlobalStateSnapshot memory beforeGlobal = beforeState.globalState;
            UserStateSnapshot memory beforeUser = beforeState.userState;
            LockStateSnapshot memory beforeLock = beforeState.lockState;

        // 4) Execute
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockCreated(expectedLockId, user1, mocaAmount, esMocaAmount, expiry);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.GlobalUpdated(beforeGlobal.veGlobal.bias + expectedBias, beforeGlobal.veGlobal.slope + expectedSlope);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.UserUpdated(user1, beforeUser.userHistory.bias + expectedBias, beforeUser.userHistory.slope + expectedSlope);

        vm.prank(user1);
        bytes32 actualLockId = veMoca.createLock{value: mocaAmount}(expiry, esMocaAmount);

        // 5) Verify
        assertEq(actualLockId, expectedLockId, "Lock ID Match");
        verifyCreateLock(beforeState, user1, actualLockId, mocaAmount, esMocaAmount, expiry);
        
        // Extra check: voting power
        uint128 userVotingPower = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        uint128 expectedPower = expectedSlope * (expiry - uint128(block.timestamp));
        assertEq(userVotingPower, expectedPower, "Voting Power");
    }   
}

// note: block.timestamp is at the start of epoch 1
// note: lock1 expires at end of epoch 3
abstract contract StateE1_User1_CreateLock1 is StateE1_Deploy {

    bytes32 public lock1_Id;
    uint128 public lock1_Expiry;
    uint128 public lock1_MocaAmount;
    uint128 public lock1_EsMocaAmount;
    uint128 public lock1_CurrentEpochStart;
    DataTypes.VeBalance public lock1_VeBalance;

    function setUp() public virtual override {
        super.setUp();

        // 1) Check current epoch
        assertEq(block.timestamp, uint128(getEpochStartTimestamp(1)), "Current timestamp is at start of epoch 1");
        assertEq(getCurrentEpochNumber(), 1, "Current epoch number is 1");


        // 2) Test parameters
        lock1_Expiry = uint128(getEpochEndTimestamp(3)); // expiry at end of epoch 3
        lock1_MocaAmount = 100 ether;
        lock1_EsMocaAmount = 100 ether;
        lock1_Id = generateLockId(block.number, user1);
        lock1_CurrentEpochStart = getCurrentEpochStart();

        // 3) Setup: fund user with MOCA and escrow some to get esMOCA
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: lock1_MocaAmount}();
            esMoca.approve(address(veMoca), lock1_MocaAmount);
            lock1_Id = veMoca.createLock{value: lock1_MocaAmount}(lock1_Expiry, lock1_EsMocaAmount);
        vm.stopPrank();

        // 4) Capture lock1_VeBalance
        lock1_VeBalance = veMoca.getLockVeBalance(lock1_Id);

        // Set cronJob: to allow ad-hoc updates to state
        vm.startPrank(cronJobAdmin);
            veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();
    }
}


contract StateE1_User1_CreateLock1_Test is StateE1_User1_CreateLock1 {

    function test_User1_balanceAtEpochEnd_Epoch1() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        
        // User1's balance at end of current epoch
        uint128 user1BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        
        // Calculate expected: VP at epoch end timestamp
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 expectedBalance = getValueAt(lock1_VeBalance, epochEndTimestamp);
        
        assertEq(user1BalanceAtEpochEnd, expectedBalance, "balanceAtEpochEnd must match calculated VP at epoch end");
        assertGt(user1BalanceAtEpochEnd, 0, "User must have balance at epoch end");
        
        // Verify for delegate (should be 0, no delegation)
        uint128 delegateBalance = veMoca.balanceAtEpochEnd(user1, currentEpoch, true);
        assertEq(delegateBalance, 0, "Delegated balance should be 0");
    }

    // ---- state_transition: register delegate ----

    function test_RegisterDelegate_User3() public {
        // need to act as the VotingController to register delegates
        address MOCK_VC = address(0x999); 

        // 1. Setup VotingController role
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(MOCK_VC);

        // 2. Register User2 and User3 as delegates
        vm.startPrank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user3, true);
        vm.stopPrank();

        // check
        assertTrue(veMoca.isRegisteredDelegate(user3), "User3 must be registered as delegate");
    }    
}

abstract contract StateE1_RegisterDelegate_User3 is StateE1_User1_CreateLock1 {
    
    address public constant MOCK_VC = address(0x999); 

    function setUp() public virtual override {
        super.setUp();

        // 1. Setup VotingController role
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(MOCK_VC);

        // 2. Register User3 as delegates
        vm.startPrank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user3, true);
        vm.stopPrank();

        // 3. Set cronJob: to allow ad-hoc updates to state
        vm.startPrank(cronJobAdmin);
            veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();
    }
}

//note: user 3 is registered as delegate [has no delegated locks]
contract StateE1_RegisterDelegate_User3_Test is StateE1_RegisterDelegate_User3 {

    function test_User3_IsRegisteredDelegate() public {
        assertTrue(veMoca.isRegisteredDelegate(user3), "User3 must be registered as delegate");
    }

    // --- negative tests: register delegate ----

        function testRevert_OnlyVotingControllerCanRegisterDelegate() public {
            vm.expectRevert(Errors.OnlyCallableByVotingControllerContract.selector);
            vm.startPrank(user1);
            veMoca.delegateRegistrationStatus(user3, false);
            vm.stopPrank();
        }

    // --- positive tests: register delegate ----
        
        function test_VotingController_CanUnregisterDelegate() public {
            vm.startPrank(MOCK_VC);
            veMoca.delegateRegistrationStatus(user3, false);
            vm.stopPrank();
            assertFalse(veMoca.isRegisteredDelegate(user3), "User3 must be unregistered as delegate");
        }

    // --- state transition: user1 delegates lock1 to user3 ----
    
        function test_User1_DelegateLock1_ToUser3() public {
            // 1. Capture before state
            UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(
                user1,           // user
                lock1_Id,        // lockId
                lock1_Expiry,    // expiry
                0,               // newExpiry (no change)
                user3,           // targetDelegate
                address(0)       // oldDelegate (not currently delegated)
            );

            // 2. Execute delegation and check for events
            vm.startPrank(user1);
            
                // Event 1: GlobalUpdated(uint128 bias, uint128 slope) - no indexed params
                vm.expectEmit(false, false, false, true);
                emit Events.GlobalUpdated(beforeState.globalState.veGlobal.bias, beforeState.globalState.veGlobal.slope);
                
                // Event 2: UserUpdated(address indexed user, uint128 bias, uint128 slope)
                vm.expectEmit(true, false, false, true);
                emit Events.UserUpdated(user1, beforeState.userState.userHistory.bias, beforeState.userState.userHistory.slope);
                
                // Event 3: DelegateUpdated(address indexed delegate, uint128 bias, uint128 slope)
                vm.expectEmit(true, false, false, true);
                emit Events.DelegateUpdated(user3, beforeState.targetDelegateState.delegateHistory.bias, beforeState.targetDelegateState.delegateHistory.slope);
                
                // Event 4: DelegatedAggregationUpdated(address indexed user, address indexed delegate, uint128 bias, uint128 slope)
                vm.expectEmit(true, true, false, true);
                emit Events.DelegatedAggregationUpdated(user1, user3, beforeState.targetPairState.delegatedAggregationHistory.bias, beforeState.targetPairState.delegatedAggregationHistory.slope);
                
                // Event 5: LockDelegated(bytes32 indexed lockId, address indexed owner, address delegate)
                vm.expectEmit(true, true, false, true);
                emit Events.LockDelegated(lock1_Id, user1, user3);
            
                // delegate
                veMoca.delegateLock(lock1_Id, user3);

            vm.stopPrank();

            // 3. Verify state changes
            verifyDelegateLock(beforeState, user3);
        }
}

//note: user 1 delegates lock1 to user 3, in E1
abstract contract StateE1_User1_DelegateLock1_ToUser3 is StateE1_RegisterDelegate_User3 {

    UnifiedStateSnapshot public epoch1_BeforeDelegateLock1;
    UnifiedStateSnapshot public epoch1_AfterDelegateLock1;
    
    function setUp() public virtual override {
        super.setUp();

        // 1) Capture State
        epoch1_BeforeDelegateLock1 = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        // 2) Execute Delegation
        vm.startPrank(user1);
            veMoca.delegateLock(lock1_Id, user3);
        vm.stopPrank();

        // 3) Capture State
        epoch1_AfterDelegateLock1 = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));
    }
}

contract StateE1_User1_DelegateLock1_ToUser3_Test is StateE1_User1_DelegateLock1_ToUser3 {

    function test_DelegateLock1_ToUser3() public {
        // 1) Verify State Changes
        verifyDelegateLock(epoch1_BeforeDelegateLock1, user3);
    }

    /**
     * Test verifies user1's voting power in E1 after delegating lock1 to user3:
     * 
     * 1. Delegation is pending - takes effect in E2
     * 2. User1 retains full voting power from lock1 in E1
     * 3. User1's personal balance equals lock1's VP at epoch end
     * 4. User1's delegated balance is 0 (delegation not yet active)
     * 5. Lock1's VP calculation is correct and unchanged by delegation
     * 6. User1's total balance (personal + delegated) equals lock1 VP
     */
    function test_User1_VotingPower_AfterDelegation_E1() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        assertEq(currentEpoch, 1, "Current epoch is E1");
        
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        
        // ============ 1. Lock1 Voting Power ============
        uint128 lock1VotingPowerAtEnd = veMoca.getLockVotingPowerAt(lock1_Id, epochEndTimestamp);
        
        // Calculate expected lock1 VP from veBalance
        uint128 expectedLock1VP = getValueAt(lock1_VeBalance, epochEndTimestamp);
        assertEq(lock1VotingPowerAtEnd, expectedLock1VP, "Lock1 VP at epoch end matches expected");
        assertGt(lock1VotingPowerAtEnd, 0, "Lock1 has voting power at E1 end");
        
        // ============ 2. User1 Personal Balance (excludeDelegated = false) ============
        uint128 user1PersonalBalance = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        
        // User1 should still have full voting power from lock1 in E1 (delegation pending)
        assertEq(user1PersonalBalance, lock1VotingPowerAtEnd, "User1 personal balance equals lock1 VP (delegation pending)");
        assertGt(user1PersonalBalance, 0, "User1 has voting power in E1");
        
        // ============ 3. User1 Delegated Balance (excludeDelegated = true) ============
        uint128 user1DelegatedBalance = veMoca.balanceAtEpochEnd(user1, currentEpoch, true);
        
        // User1 has no delegated balance in E1 (no one has delegated to user1)
        assertEq(user1DelegatedBalance, 0, "User1 has no delegated balance in E1");
        
        // ============ 4. Verify Lock State ============
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        assertEq(lock1.delegate, user3, "Lock1 is delegated to user3");
        assertEq(lock1.owner, user1, "Lock1 owner is still user1");
        assertFalse(lock1.isUnlocked, "Lock1 is not unlocked");
        
        // ============ 5. Cross-check with current timestamp ============
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user1BalanceNow = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 lock1VotingPowerNow = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        
        assertEq(user1BalanceNow, lock1VotingPowerNow, "User1 current balance equals lock1 current VP");
        assertGt(user1BalanceNow, 0, "User1 has voting power at current timestamp");
    }

    
    /**
     * Test verifies user3's voting power state in E1 after lock1 delegation:
     * 1. User3 has no delegated voting power in E1 (delegation pending, takes effect in E2)
     * 2. User3 has no personal voting power (no locks owned)
     * 3. User3's total balance is 0 at epoch end
     * 4. User3's current balance is also 0
     * 5. Pending delegation delta is correctly booked for E2
     */
    function test_User3_VotingPower_AfterDelegation_E1() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        assertEq(currentEpoch, 1, "Current epoch is E1");
        
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // ============ 1. User3 Delegated Balance (excludeDelegated = true) ============
        uint128 user3DelegatedBalance = veMoca.balanceAtEpochEnd(user3, currentEpoch, true);
        assertEq(user3DelegatedBalance, 0, "User3 has no delegated balance in E1 (delegation pending)");
        
        // ============ 2. User3 Personal Balance (excludeDelegated = false) ============
        uint128 user3PersonalBalance = veMoca.balanceAtEpochEnd(user3, currentEpoch, false);
        assertEq(user3PersonalBalance, 0, "User3 has no personal balance in E1 (no locks owned)");
        
        // ============ 3. User3 Current Balance ============
        uint128 user3BalanceNow = veMoca.balanceOfAt(user3, currentTimestamp, false);
        assertEq(user3BalanceNow, 0, "User3 has no voting power at current timestamp");
        
        uint128 user3DelegatedNow = veMoca.balanceOfAt(user3, currentTimestamp, true);
        assertEq(user3DelegatedNow, 0, "User3 has no delegated voting power at current timestamp");
        
        // ============ 4. Verify Pending Delegation Delta for E2 ============
        uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
        (bool hasAdd, , DataTypes.VeBalance memory additions, ) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        
        assertTrue(hasAdd, "User3 has pending addition for E2");
        assertEq(additions.bias, lock1_VeBalance.bias, "Pending addition bias matches lock1");
        assertEq(additions.slope, lock1_VeBalance.slope, "Pending addition slope matches lock1");
        
        // ============ 5. Verify User3 is Registered Delegate ============
        assertTrue(veMoca.isRegisteredDelegate(user3), "User3 is registered as delegate");
    }

    // ---- state_transition to E2: cross an epoch boundary; to check totalSupplyAt and pending deltas  ----
    function test_CronJob_UpdateAccountsAndPendingDeltas_E2() public {
        
        // ============ 1. Capture State Before Update ============
        UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        // ============ 2. Warp to E2 start ============
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // ============ 3. Execute Cronjob Update ============
        vm.startPrank(cronJob);
            // update users' personal accounts
            address[] memory accounts = new address[](2);
            accounts[0] = user1;
            accounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);

            // update users' delegate accounts
            address[] memory delegateAccounts = new address[](2);
            delegateAccounts[0] = user1;
            delegateAccounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(delegateAccounts, true);

            // update user1->user3 delegate pair
            address[] memory users = new address[](1);
            address[] memory delegates = new address[](1);
            users[0] = user1;
            delegates[0] = user3;
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();
        
        // ============ 4. Capture State After Update ============
        UnifiedStateSnapshot memory afterState = captureAllStatesPlusDelegates(user1, lock1_Id, lock1_Expiry, 0, user3, address(0));

        // ============ 5. Verify Lock State Changes ============
            uint128 epoch2EndTimestamp = uint128(getEpochEndTimestamp(2));
            // Calculate expected lock1 VP at current timestamp
            uint128 expectedLock1CurrentVp = getValueAt(lock1_VeBalance, uint128(block.timestamp));
            uint128 expectedLock1VpAtEpochEnd = getValueAt(lock1_VeBalance, epoch2EndTimestamp);
            assertEq(afterState.lockState.lockCurrentVotingPower, expectedLock1CurrentVp, "Lock1 VP = lock1 VP");          
            assertEq(afterState.lockState.lockVotingPowerAtEpochEnd, expectedLock1VpAtEpochEnd, "Lock1 VP at epoch end = lock1 VP at epoch end");

        // ============ 6. Verify User1 State Changes ============
            // User1's personal VP should be 0 after delegation takes effect
            assertEq(afterState.userState.userCurrentVotingPower, 0, "User1 personal VP after = 0 (delegated away)");
            assertEq(afterState.userState.userDelegatedVotingPower, 0, "User1 delegated VP after = 0");
        
        // ============ 7. Verify User3 State Changes ============
            
            // User3's delegated VP should equal lock1's VP after delegation takes effect
            assertEq(afterState.targetDelegateState.delegateCurrentVotingPower, expectedLock1CurrentVp, "User3 delegated VP = lock1 VP");
            assertEq(afterState.targetDelegateState.delegateVotingPowerAtEpochEnd, expectedLock1VpAtEpochEnd, "User3 delegated VP at epoch end = lock1 VP at epoch end");
            
            // User3's personal VP should be 0 
            assertEq(afterState.userState.userCurrentVotingPower, 0, "User3 personal VP = 0");
        
        // ============ 8. Verify Pending Deltas Cleared ============
        
            // User1: pending subtraction should be cleared
            (bool user1HasSub, bool user1HasAdd, DataTypes.VeBalance memory user1Additions, DataTypes.VeBalance memory user1Subtractions) = veMoca.userPendingDeltas(user1, epoch2StartTimestamp);
            assertFalse(user1HasSub, "User1 pending subtraction cleared");
            assertFalse(user1HasAdd, "User1 has no pending addition");
            assertEq(user1Additions.bias, 0, "User1 additions bias = 0");
            assertEq(user1Additions.slope, 0, "User1 additions slope = 0");
            assertEq(user1Subtractions.bias, 0, "User1 subtractions bias = 0");
            assertEq(user1Subtractions.slope, 0, "User1 subtractions slope = 0");
            
            // User3: pending addition should be cleared
            (bool user3HasSub, bool user3HasAdd, DataTypes.VeBalance memory user3Additions, DataTypes.VeBalance memory user3Subtractions) = veMoca.delegatePendingDeltas(user3, epoch2StartTimestamp);
            assertFalse(user3HasSub, "User3 has no pending subtraction");
            assertFalse(user3HasAdd, "User3 pending addition cleared");
            assertEq(user3Additions.bias, 0, "User3 additions bias = 0");
            assertEq(user3Additions.slope, 0, "User3 additions slope = 0");
            assertEq(user3Subtractions.bias, 0, "User3 subtractions bias = 0");
            assertEq(user3Subtractions.slope, 0, "User3 subtractions slope = 0");

        // ============ 9. Verify: Bias & slope would not change [since no new locks created] ============
            assertEq(afterState.globalState.veGlobal.bias, beforeState.globalState.veGlobal.bias, "veGlobal bias");
            assertEq(afterState.globalState.veGlobal.slope, beforeState.globalState.veGlobal.slope, "veGlobal slope");
        
        // ============ 10. Verify: totalSupplyAt is > 0 after epoch boundary (calculated) & (veMoca.totalSupplyAtTimestamp()) ============
            uint128 Lock1VpAtE2Start = getValueAt(lock1_VeBalance, epoch2StartTimestamp);

            assertEq(afterState.globalState.totalSupplyAt, beforeState.globalState.totalSupplyAt + Lock1VpAtE2Start, "totalSupplyAt is > 0 after epoch boundary (calculated)");
            assertEq(afterState.globalState.totalSupplyAt, veMoca.totalSupplyAtTimestamp(epoch2StartTimestamp), "totalSupplyAt is > 0 after epoch boundary (veMoca.totalSupplyAtTimestamp())");
    }
}


// =====================================================
// ================= EPOCH 2 - DELEGATION TAKES EFFECT =================
// =====================================================

// note: warp to E2; check that delegation pending deltas take effect
abstract contract StateE2_Lock1DelegationTakesEffect is StateE1_User1_DelegateLock1_ToUser3 {
    
    // Saved state snapshots for verification
    GlobalStateSnapshot public epoch1_GlobalState;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Capture E1 state before warping
        epoch1_GlobalState = captureGlobalState(lock1_Expiry, 0);
        
        // Warp to E2 start
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // ============ Execute Cronjob Update ============
        vm.startPrank(cronJob);
            // update users' personal accounts
            address[] memory accounts = new address[](2);
            accounts[0] = user1;
            accounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);

            // update users' delegate accounts
            address[] memory delegateAccounts = new address[](2);
            delegateAccounts[0] = user1;
            delegateAccounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(delegateAccounts, true);

            // update user1->user3 delegate pair
            address[] memory users = new address[](1);
            address[] memory delegates = new address[](1);
            users[0] = user1;
            delegates[0] = user3;
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();
        
    }
}

contract StateE2_Lock1DelegationTakesEffect_Test is StateE2_Lock1DelegationTakesEffect {

    // Verify state AFTER cronjob has run (delegation takes effect)
    function test_CronJob_UpdateAccountsAndPendingDeltas() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));

        // ============ 1. Calculate Expected Lock1 VP at current time ============
        uint128 expectedLock1Vp = getValueAt(lock1_VeBalance, currentTimestamp);

        // ============ 2. Verify User1 State (Delegation subtracted from personal) ============
        uint128 user1PersonalVp = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user1DelegatedVp = veMoca.balanceOfAt(user1, currentTimestamp, true);
        
        // User1 personal VP = 0 (lock1 was delegated away)
        assertEq(user1PersonalVp, 0, "User1 personal VP = 0 (delegated away)");
        // User1 delegated VP = 0 (user1 is not a delegate)
        assertEq(user1DelegatedVp, 0, "User1 delegated VP = 0");

        // ============ 3. Verify User3 State (Delegation added to delegated) ============
        uint128 user3PersonalVp = veMoca.balanceOfAt(user3, currentTimestamp, false);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // User3 personal VP = 0 (no personal locks)
        assertEq(user3PersonalVp, 0, "User3 personal VP = 0");
        // User3 delegated VP = lock1 VP (received delegation)
        assertEq(user3DelegatedVp, expectedLock1Vp, "User3 delegated VP = lock1 VP");

        // ============ 4. Verify Pending Deltas are Cleared ============
        
        // User1: pending subtraction should be cleared (applied during cronjob)
        (bool user1HasAdd, bool user1HasSub, DataTypes.VeBalance memory user1Additions, DataTypes.VeBalance memory user1Subtractions) = veMoca.userPendingDeltas(user1, epoch2StartTimestamp);
        assertFalse(user1HasAdd, "User1 has no pending addition");
        assertFalse(user1HasSub, "User1 pending subtraction cleared");
        assertEq(user1Additions.bias, 0, "User1 additions bias = 0");
        assertEq(user1Additions.slope, 0, "User1 additions slope = 0");
        assertEq(user1Subtractions.bias, 0, "User1 subtractions bias = 0");
        assertEq(user1Subtractions.slope, 0, "User1 subtractions slope = 0");
        
        // User3 (as delegate): pending addition should be cleared
        (bool user3HasAdd, bool user3HasSub, DataTypes.VeBalance memory user3Additions, DataTypes.VeBalance memory user3Subtractions) = veMoca.delegatePendingDeltas(user3, epoch2StartTimestamp);
        assertFalse(user3HasAdd, "User3 pending addition cleared");
        assertFalse(user3HasSub, "User3 has no pending subtraction");
        assertEq(user3Additions.bias, 0, "User3 additions bias = 0");
        assertEq(user3Additions.slope, 0, "User3 additions slope = 0");
        assertEq(user3Subtractions.bias, 0, "User3 subtractions bias = 0");
        assertEq(user3Subtractions.slope, 0, "User3 subtractions slope = 0");

        // ============ 5. Verify User-Delegate Pair Pending Deltas Cleared ============
        (bool pairHasAdd, bool pairHasSub, DataTypes.VeBalance memory pairAdditions, DataTypes.VeBalance memory pairSubtractions) = veMoca.userPendingDeltasForDelegate(user1, user3, epoch2StartTimestamp);
        assertFalse(pairHasAdd, "User1-User3 pair pending addition cleared");
        assertFalse(pairHasSub, "User1-User3 pair has no pending subtraction");
        assertEq(pairAdditions.bias, 0, "Pair additions bias = 0");
        assertEq(pairAdditions.slope, 0, "Pair additions slope = 0");
        assertEq(pairSubtractions.bias, 0, "Pair subtractions bias = 0");
        assertEq(pairSubtractions.slope, 0, "Pair subtractions slope = 0");
    }

    function test_TotalSupplyAt_E1_Finalized() public {
        // After crossing epoch boundary and updating (done in setUp), 
        // totalSupplyAt[E1End] should be finalized (E1->E2 boundary crossed)
        uint128 epoch2Start = uint128(getEpochStartTimestamp(2));
        uint128 totalSupplyAtE2 = veMoca.totalSupplyAt(epoch2Start);
        uint128 expectedTotalSupply = getValueAt(epoch1_GlobalState.veGlobal, epoch2Start);
        assertEq(totalSupplyAtE2, expectedTotalSupply, "totalSupplyAt[E1End] should be finalized");
    }

    // ============ View Function Tests ============

        function test_BalanceOfAt_AfterDelegationTakesEffect() public {
            // user1 personal VP = 0 (delegated away)
            uint128 user1PersonalVp = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
            assertEq(user1PersonalVp, 0, "User1 personal VP should be 0");
            
            // user3 delegated VP = lock1 VP
            uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, uint128(block.timestamp), true);
            uint128 expectedVp = getValueAt(lock1_VeBalance, uint128(block.timestamp));
            assertEq(user3DelegatedVp, expectedVp, "User3 delegated VP should equal lock1 VP");
            
            // user3 personal VP = 0 (has no personal locks)
            uint128 user3PersonalVp = veMoca.balanceOfAt(user3, uint128(block.timestamp), false);
            assertEq(user3PersonalVp, 0, "User3 personal VP should be 0");
        }

        function test_BalanceAtEpochEnd_E2() public {
            uint128 currentEpoch = getCurrentEpochNumber();
            uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
            
            // user1 balanceAtEpochEnd (personal) = 0
            uint128 user1BalanceAtEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
            assertEq(user1BalanceAtEnd, 0, "User1 balanceAtEpochEnd should be 0");
            
            // user3 balanceAtEpochEnd (delegated) = lock1 VP at epoch end
            uint128 user3DelegatedAtEnd = veMoca.balanceAtEpochEnd(user3, currentEpoch, true);
            uint128 expectedVpAtEnd = getValueAt(lock1_VeBalance, epochEndTimestamp);
            assertEq(user3DelegatedAtEnd, expectedVpAtEnd, "User3 delegated balanceAtEpochEnd should equal lock1 VP at epoch end");
        }

        function test_GetSpecificDelegatedBalanceAtEpochEnd() public {
            uint128 currentEpoch = getCurrentEpochNumber();
            uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
            
            // user1->user3 specific delegated balance at epoch end
            uint128 specificDelegatedBalance = veMoca.getSpecificDelegatedBalanceAtEpochEnd(user1, user3, currentEpoch);
            uint128 expectedVp = getValueAt(lock1_VeBalance, epochEndTimestamp);
            assertEq(specificDelegatedBalance, expectedVp, "Specific delegated balance should equal lock1 VP");
        }

        function test_GetLockVotingPowerAt() public {
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 lockVp = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
            uint128 expectedVp = getValueAt(lock1_VeBalance, currentTimestamp);
            assertEq(lockVp, expectedVp, "Lock VP should match calculated value");
        }

    // ============ Negative Tests ============

        function testRevert_NonCronJobCannotUpdateAccounts() public {
            address[] memory accounts = new address[](1);
            accounts[0] = user1;
            
            vm.expectRevert();
            vm.prank(user1);
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
        }

        function testRevert_NonCronJobCannotUpdateDelegatePairs() public {
            address[] memory users = new address[](1);
            users[0] = user1;
            address[] memory delegates = new address[](1);
            delegates[0] = user3;
            
            vm.expectRevert();
            vm.prank(user1);
            veMoca.updateDelegatePairs(users, delegates);
        }

        function testRevert_User1_CannotSwitchDelegate_Lock1() public {
            // lock1 expires at E3, currently in E2
            // After delegating in E1, user1 has used 1 delegate action
            // Cannot switchDelegate as only 1 action allowed per epoch remaining
            
            // First register user2 as delegate
            vm.prank(MOCK_VC);
            veMoca.delegateRegistrationStatus(user2, true);
            
            vm.expectRevert(Errors.LockExpiresTooSoon.selector);
            vm.prank(user1);
            veMoca.switchDelegate(lock1_Id, user2);
        }

        function testRevert_User1_CannotUndelegate_Lock1() public {
            // Same reason as above - action limit in final epoch before expiry
            vm.expectRevert(Errors.LockExpiresTooSoon.selector);
            vm.prank(user1);
            veMoca.undelegateLock(lock1_Id);
        }

    // ============ State Transition Test ============

        function test_StateTransition_User1_CreatesLock2() public {
            
            // Setup: fund user1 for lock2
            vm.startPrank(user1);
                vm.deal(user1, 400 ether);
                esMoca.escrowMoca{value: 200 ether}();
                esMoca.approve(address(veMoca), 200 ether);
            vm.stopPrank();
            
            // Lock2 parameters: long duration (expires E10)
            uint128 lock2Expiry = uint128(getEpochEndTimestamp(10));
            uint128 lock2MocaAmount = 200 ether;
            uint128 lock2EsMocaAmount = 200 ether;
            bytes32 expectedLock2Id = generateLockId(block.number, user1);
            
            // Capture state before
            UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, expectedLock2Id, lock2Expiry, 0, user3, address(0));
            
            // Execute: create lock2 and delegate to user3
            vm.startPrank(user1);
                bytes32 lock2Id = veMoca.createLock{value: lock2MocaAmount}(lock2Expiry, lock2EsMocaAmount);
                veMoca.delegateLock(lock2Id, user3);
            vm.stopPrank();
            
            // Verify lock created
            DataTypes.Lock memory lock2 = getLock(lock2Id);
            assertEq(lock2.owner, user1, "Lock2 owner");
            assertEq(lock2.delegate, user3, "Lock2 delegate");
            assertEq(lock2.moca, lock2MocaAmount, "Lock2 moca");
            assertEq(lock2.esMoca, lock2EsMocaAmount, "Lock2 esMoca");
            assertEq(lock2.expiry, lock2Expiry, "Lock2 expiry");
        }

}

/*
// =====================================================
// ================= EPOCH 2 - USER1 CREATES LOCK2 =================
// =====================================================

// note: user1 creates lock2 with long duration, delegates to user3
// lock1: expires E3, delegated to user3
// lock2: expires E10, delegated to user3
abstract contract StateE2_User1_CreatesLock2 is StateE2_Lock1DelegationTakesEffect {
    
    bytes32 public lock2_Id;
    uint128 public lock2_Expiry;
    uint128 public lock2_MocaAmount;
    uint128 public lock2_EsMocaAmount;
    DataTypes.VeBalance public lock2_VeBalance;
    
    // Captured state before lock2 creation (for verification)
    UnifiedStateSnapshot public stateBeforeLock2Creation;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Apply E1 delegation (bring state up to date before new actions)
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](2);
            accounts[0] = user1;
            accounts[1] = user3;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
            
            address[] memory users = new address[](1);
            users[0] = user1;
            address[] memory delegates = new address[](1);
            delegates[0] = user3;
            veMoca.updateDelegatePairs(users, delegates);
        vm.stopPrank();
        
        // Lock2 parameters: long duration (expires E10)
        lock2_Expiry = uint128(getEpochEndTimestamp(10));
        lock2_MocaAmount = 200 ether;
        lock2_EsMocaAmount = 200 ether;
        
        // Fund user1 for lock2
        vm.startPrank(user1);
            vm.deal(user1, 400 ether);
            esMoca.escrowMoca{value: lock2_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock2_EsMocaAmount);
        vm.stopPrank();
        
        // Capture state before lock2 creation
        bytes32 expectedLock2Id = generateLockId(block.number, user1);
        stateBeforeLock2Creation = captureAllStatesPlusDelegates(user1, expectedLock2Id, lock2_Expiry, 0, user3, address(0));
        
        // Create lock2 and delegate to user3
        vm.startPrank(user1);
            lock2_Id = veMoca.createLock{value: lock2_MocaAmount}(lock2_Expiry, lock2_EsMocaAmount);
            veMoca.delegateLock(lock2_Id, user3);
        vm.stopPrank();
        
        // Capture lock2 veBalance
        lock2_VeBalance = veMoca.getLockVeBalance(lock2_Id);
    }
}

contract StateE2_User1_CreatesLock2_Test is StateE2_User1_CreatesLock2 {

    // ============ Lock Creation State Tests ============

    function test_Lock2_Created() public {
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.owner, user1, "Lock2 owner");
        assertEq(lock.delegate, user3, "Lock2 delegate");
        assertEq(lock.moca, lock2_MocaAmount, "Lock2 moca");
        assertEq(lock.esMoca, lock2_EsMocaAmount, "Lock2 esMoca");
        assertEq(lock.expiry, lock2_Expiry, "Lock2 expiry");
        assertFalse(lock.isUnlocked, "Lock2 not unlocked");
    }

    function test_GlobalState_TwoLocks() public {
        // Verify TOTAL_LOCKED reflects both locks
        uint128 expectedTotalMoca = lock1_MocaAmount + lock2_MocaAmount;
        uint128 expectedTotalEsMoca = lock1_EsMocaAmount + lock2_EsMocaAmount;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalMoca, "Total locked MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalEsMoca, "Total locked esMOCA");
        
        // Verify veGlobal reflects both locks
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        uint128 expectedSlope = lock1_VeBalance.slope + lock2_VeBalance.slope;
        assertEq(globalSlope, expectedSlope, "Global slope should be sum of both locks");
    }

    function test_Lock2_DelegationPendingDeltas_Booked() public {
        // Verify pending deltas are booked for next epoch (delegation takes effect next epoch)
        uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
        
        // User pending subtraction should be booked
        (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) 
            = veMoca.userPendingDeltas(user1, nextEpochStart);
        assertTrue(hasSub, "User pending subtraction booked");
        assertEq(subtractions.slope, lock2_VeBalance.slope, "User pending sub slope = lock2 slope");
        
        // Delegate pending addition should be booked
        (hasAdd, hasSub, additions, subtractions) = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(hasAdd, "Delegate pending addition booked");
        assertEq(additions.slope, lock2_VeBalance.slope, "Delegate pending add slope = lock2 slope");
    }

    function test_BothLocks_VpAtEpochEnd() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        
        // Lock1 VP at epoch end
        uint128 lock1VpAtEnd = veMoca.getLockVotingPowerAt(lock1_Id, epochEndTimestamp);
        uint128 expectedLock1Vp = getValueAt(lock1_VeBalance, epochEndTimestamp);
        assertEq(lock1VpAtEnd, expectedLock1Vp, "Lock1 VP at epoch end");
        
        // Lock2 VP at epoch end  
        uint128 lock2VpAtEnd = veMoca.getLockVotingPowerAt(lock2_Id, epochEndTimestamp);
        uint128 expectedLock2Vp = getValueAt(lock2_VeBalance, epochEndTimestamp);
        assertEq(lock2VpAtEnd, expectedLock2Vp, "Lock2 VP at epoch end");
    }

    function test_User1_PersonalVp_ReflectsLock2() public {
        // In E2, user1 still has lock2's personal VP (delegation pending, takes effect next epoch)
        // Lock1 delegation already took effect (applied in parent state)
        uint128 user1PersonalVp = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        
        // After lock2 creation and delegation in same epoch, user1's VP includes lock2
        // (pending subtraction will apply next epoch)
        uint128 expectedVp = getValueAt(lock2_VeBalance, uint128(block.timestamp));
        assertEq(user1PersonalVp, expectedVp, "User1 personal VP = lock2 (pending delegation)");
    }

    // ============ State Transition Test ============

    function test_StateTransition_IncreaseDuration_Lock2() public {
        // lock2 can have duration increased (far from expiry)
        uint128 targetExpiry = uint128(getEpochEndTimestamp(12)); // extend to E12
        uint128 durationIncrease = targetExpiry - lock2_Expiry;
        
        // Capture state before
        UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_Expiry, targetExpiry, user3, address(0));
        
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, durationIncrease);
        
        // Verify expiry updated
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.expiry, targetExpiry, "Lock2 expiry should be updated");
        
        // Verify via helper (IMMEDIATE effect on delegated lock)
        verifyIncreaseDurationDelegated(beforeState, targetExpiry);
    }
}

// =====================================================
// ================= EPOCH 2 - INCREASE DURATION LOCK2 =================
// =====================================================

// note: user1 increases duration on lock2 (delegated lock)
abstract contract StateE2_User1_IncreaseDuration_Lock2 is StateE2_User1_CreatesLock2 {
    
    uint128 public lock2_NewExpiry;
    uint128 public lock2_DurationIncrease;
    DataTypes.VeBalance public lock2_VeBalance_AfterIncreaseDuration;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Calculate duration to add: extend from E10 to E12
        uint128 targetExpiry = uint128(getEpochEndTimestamp(12));
        lock2_DurationIncrease = targetExpiry - lock2_Expiry;
        lock2_NewExpiry = targetExpiry;
        
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, lock2_DurationIncrease);
        
        // Update stored veBalance
        lock2_VeBalance_AfterIncreaseDuration = veMoca.getLockVeBalance(lock2_Id);
    }
}

contract StateE2_User1_IncreaseDuration_Lock2_Test is StateE2_User1_IncreaseDuration_Lock2 {

    // ============ State Verification ============

    function test_Lock2_ExpiryUpdated() public {
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.expiry, lock2_NewExpiry, "Lock2 expiry updated to E12");
        assertEq(lock.moca, lock2_MocaAmount, "Lock2 moca unchanged");
        assertEq(lock.esMoca, lock2_EsMocaAmount, "Lock2 esMoca unchanged");
    }

    function test_Lock2_VeBalance_BiasIncreased() public {
        // Slope unchanged (same amount), but bias increased (longer duration)
        assertEq(lock2_VeBalance_AfterIncreaseDuration.slope, lock2_VeBalance.slope, "Slope unchanged");
        assertGt(lock2_VeBalance_AfterIncreaseDuration.bias, lock2_VeBalance.bias, "Bias increased");
    }

    function test_SlopeChanges_Shifted() public {
        // Old expiry slopeChange should be decreased
        uint128 oldSlopeChange = veMoca.slopeChanges(lock2_Expiry);
        // New expiry slopeChange should be increased
        uint128 newSlopeChange = veMoca.slopeChanges(lock2_NewExpiry);
        
        // lock2's slope should be at new expiry
        assertEq(newSlopeChange, lock2_VeBalance.slope, "New expiry slopeChange should have lock2's slope");
    }

    function test_Delegate_Vp_Increased_Immediately() public {
        // increaseDuration on delegated lock has IMMEDIATE effect on delegate VP
        // No cronJob needed - delegate history is updated directly
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // Expected: lock1 VP + new lock2 VP (with extended duration)
        uint128 lock1Vp = getValueAt(lock1_VeBalance, currentTimestamp);
        uint128 lock2Vp = getValueAt(lock2_VeBalance_AfterIncreaseDuration, currentTimestamp);
        
        assertEq(user3DelegatedVp, lock1Vp + lock2Vp, "User3 delegated VP includes updated lock2");
    }

    // ============ Negative Tests ============

    function testRevert_Lock1_CannotIncreaseDuration() public {
        // lock1 expires at E3, current epoch is E2
        // Lock must have at least 3 epochs remaining to modify
        // lock1 only has ~1 epoch left, so any modification should fail
        
        uint128 durationIncrease = 2 * EPOCH_DURATION; // Try to add 2 epochs
        
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock1_Id, durationIncrease);
    }

    function testRevert_IncreaseDuration_PastMaxDuration() public {
        // Try to extend beyond MAX_LOCK_DURATION from current timestamp
        // Adding a duration that would make total duration exceed MAX_LOCK_DURATION
        uint128 tooLongDuration = MAX_LOCK_DURATION + EPOCH_DURATION;
        
        // Contract uses InvalidExpiry for this check
        vm.expectRevert(Errors.InvalidExpiry.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, tooLongDuration);
    }

    function testRevert_IncreaseDuration_NonOwner() public {
        uint128 durationIncrease = 2 * EPOCH_DURATION; // 2 epochs
        
        // increaseDuration uses InvalidLockId error for owner check
        vm.expectRevert(Errors.InvalidLockId.selector);
        vm.prank(user2);
        veMoca.increaseDuration(lock2_Id, durationIncrease);
    }

    function testRevert_IncreaseDuration_ZeroDuration() public {
        // Cannot pass 0 as durationToIncrease
        vm.expectRevert(Errors.InvalidLockDuration.selector);
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, 0);
    }

    // ============ State Transition Test ============

    function test_StateTransition_IncreaseAmount_Lock2() public {
        uint128 additionalMoca = 50 ether;
        uint128 additionalEsMoca = 50 ether;
        
        // Fund user1 (need ETH for both escrow and increaseAmount)
        vm.startPrank(user1);
            vm.deal(user1, additionalMoca + additionalEsMoca);
            esMoca.escrowMoca{value: additionalEsMoca}();
            esMoca.approve(address(veMoca), additionalEsMoca);
        vm.stopPrank();
        
        // Capture state before
        UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_NewExpiry, 0, user3, address(0));
        
        vm.prank(user1);
        veMoca.increaseAmount{value: additionalMoca}(lock2_Id, additionalEsMoca);
        
        // Verify amounts updated
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.moca, lock2_MocaAmount + additionalMoca, "Lock2 moca increased");
        assertEq(lock.esMoca, lock2_EsMocaAmount + additionalEsMoca, "Lock2 esMoca increased");
        
        // Verify via helper
        verifyIncreaseAmountDelegated(beforeState, additionalMoca, additionalEsMoca);
    }
}

// =====================================================
// ================= EPOCH 2 - INCREASE AMOUNT LOCK2 =================
// =====================================================

// note: user1 increases amount on lock2 (delegated lock)
abstract contract StateE2_User1_IncreaseAmount_Lock2 is StateE2_User1_IncreaseDuration_Lock2 {
    
    uint128 public lock2_AdditionalMoca;
    uint128 public lock2_AdditionalEsMoca;
    DataTypes.VeBalance public lock2_VeBalance_AfterIncreaseAmount;
    
    function setUp() public virtual override {
        super.setUp();
        
        lock2_AdditionalMoca = 50 ether;
        lock2_AdditionalEsMoca = 50 ether;
        
        // Fund user1 (need ETH for both escrow and increaseAmount)
        vm.startPrank(user1);
            vm.deal(user1, lock2_AdditionalMoca + lock2_AdditionalEsMoca);
            esMoca.escrowMoca{value: lock2_AdditionalEsMoca}();
            esMoca.approve(address(veMoca), lock2_AdditionalEsMoca);
            
            // Increase amount
            veMoca.increaseAmount{value: lock2_AdditionalMoca}(lock2_Id, lock2_AdditionalEsMoca);
        vm.stopPrank();
        
        // Update stored veBalance
        lock2_VeBalance_AfterIncreaseAmount = veMoca.getLockVeBalance(lock2_Id);
    }
}

contract StateE2_User1_IncreaseAmount_Lock2_Test is StateE2_User1_IncreaseAmount_Lock2 {

    // ============ State Verification ============

    function test_Lock2_AmountsUpdated() public {
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.moca, lock2_MocaAmount + lock2_AdditionalMoca, "Lock2 moca updated");
        assertEq(lock.esMoca, lock2_EsMocaAmount + lock2_AdditionalEsMoca, "Lock2 esMoca updated");
        assertEq(lock.expiry, lock2_NewExpiry, "Lock2 expiry unchanged");
    }

    function test_Lock2_VeBalance_SlopeIncreased() public {
        // Slope increased (more tokens), bias increased proportionally
        assertGt(lock2_VeBalance_AfterIncreaseAmount.slope, lock2_VeBalance_AfterIncreaseDuration.slope, "Slope increased");
        assertGt(lock2_VeBalance_AfterIncreaseAmount.bias, lock2_VeBalance_AfterIncreaseDuration.bias, "Bias increased");
    }

    function test_TotalLocked_Increased() public {
        uint128 expectedTotalMoca = lock1_MocaAmount + lock2_MocaAmount + lock2_AdditionalMoca;
        uint128 expectedTotalEsMoca = lock1_EsMocaAmount + lock2_EsMocaAmount + lock2_AdditionalEsMoca;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalMoca, "Total locked MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalEsMoca, "Total locked esMOCA");
    }

    function test_Delegate_Vp_Increased_Immediately() public {
        // increaseAmount on delegated lock should immediately increase delegate VP
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // Expected: lock1 VP + updated lock2 VP
        uint128 lock1Vp = getValueAt(lock1_VeBalance, currentTimestamp);
        uint128 lock2Vp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, currentTimestamp);
        
        assertEq(user3DelegatedVp, lock1Vp + lock2Vp, "User3 delegated VP includes updated lock2");
    }

    // ============ Negative Tests ============

    function testRevert_Lock1_CannotIncreaseAmount() public {
        // lock1 is near expiry, cannot modify
        vm.deal(user1, 10 ether);
        
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        vm.prank(user1);
        veMoca.increaseAmount{value: 10 ether}(lock1_Id, 0);
    }

    function testRevert_IncreaseAmount_ZeroAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        veMoca.increaseAmount{value: 0}(lock2_Id, 0);
    }

    function testRevert_IncreaseAmount_NonOwner() public {
        vm.deal(user2, 10 ether);
        
        // increaseAmount uses InvalidLockId error for owner check
        vm.expectRevert(Errors.InvalidLockId.selector);
        vm.prank(user2);
        veMoca.increaseAmount{value: 10 ether}(lock2_Id, 0);
    }

    // ============ State Transition Test ============

    function test_StateTransition_SwitchDelegate_Lock2() public {
        // Register user2 as delegate
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user2, true);
        
        // Capture state before
        UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_NewExpiry, 0, user2, user3);
        
        vm.prank(user1);
        veMoca.switchDelegate(lock2_Id, user2);
        
        // Verify delegate switched
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.delegate, user2, "Lock2 delegate switched to user2");
        
        // Verify via helper
        verifySwitchDelegate(beforeState, user2);
    }
}

// =====================================================
// ================= EPOCH 2 - SWITCH DELEGATE LOCK2 =================
// =====================================================

// note: user2 is registered as delegate
// note: user1 switches lock2 delegation from user3 to user2
abstract contract StateE2_User1_SwitchDelegate_Lock2 is StateE2_User1_IncreaseAmount_Lock2 {
    
    function setUp() public virtual override {
        super.setUp();
        
        // Register user2 as delegate
        vm.prank(MOCK_VC);
        veMoca.delegateRegistrationStatus(user2, true);
        
        // Switch lock2 delegation from user3 to user2
        vm.prank(user1);
        veMoca.switchDelegate(lock2_Id, user2);
    }
}

contract StateE2_User1_SwitchDelegate_Lock2_Test is StateE2_User1_SwitchDelegate_Lock2 {

    // ============ State Verification ============

    function test_Lock2_DelegateSwitched() public {
        DataTypes.Lock memory lock = getLock(lock2_Id);
        assertEq(lock.delegate, user2, "Lock2 delegate is user2");
    }

    function test_SwitchDelegate_PendingDeltas_Booked() public {
        // switchDelegate books pending deltas for next epoch
        // Old delegate (user3) gets subtraction, new delegate (user2) gets addition
        uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
        
        // User3 (old delegate) should have pending subtraction
        (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) 
            = veMoca.delegatePendingDeltas(user3, nextEpochStart);
        assertTrue(hasSub, "Old delegate has pending subtraction");
        assertEq(subtractions.slope, lock2_VeBalance_AfterIncreaseAmount.slope, "Old delegate sub slope = lock2 slope");
        
        // User2 (new delegate) should have pending addition
        (hasAdd, hasSub, additions, subtractions) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
        assertTrue(hasAdd, "New delegate has pending addition");
        assertEq(additions.slope, lock2_VeBalance_AfterIncreaseAmount.slope, "New delegate add slope = lock2 slope");
    }

    function test_User3_DelegatedVp_UnchangedThisEpoch() public {
        // In current epoch, user3's VP is UNCHANGED by switchDelegate (pending takes effect next epoch)
        // user3 still has lock1's VP + lock2's VP (from immediate increaseAmount effect)
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, currentTimestamp, true);
        
        // user3 has lock1 + lock2 VP (increaseAmount had immediate effect, switchDelegate is pending)
        uint128 lock1Vp = getValueAt(lock1_VeBalance, currentTimestamp);
        uint128 lock2Vp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, currentTimestamp);
        assertEq(user3DelegatedVp, lock1Vp + lock2Vp, "User3 delegated VP = lock1 + lock2 (pending switch)");
    }

    function test_User2_DelegatedVp_ZeroThisEpoch() public {
        // In current epoch, user2's delegated VP is ZERO (pending takes effect next epoch)
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user2DelegatedVp = veMoca.balanceOfAt(user2, currentTimestamp, true);
        
        // user2 doesn't have lock2's VP yet - pending addition applies next epoch
        assertEq(user2DelegatedVp, 0, "User2 delegated VP = 0 (pending)");
    }

    function test_NumOfDelegateActionsPerEpoch_Incremented() public {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 actionCount = veMoca.numOfDelegateActionsPerEpoch(lock2_Id, currentEpochStart);
        
        // lock2: delegateLock (1) + switchDelegate (1) = 2 actions
        assertEq(actionCount, 2, "Delegate action count should be 2");
    }

    // ============ Negative Tests ============

        function testRevert_SwitchDelegate_ToUnregisteredDelegate() public {
            address unregistered = address(0x123);
            
            vm.expectRevert(Errors.DelegateNotRegistered.selector);
            vm.prank(user1);
            veMoca.switchDelegate(lock2_Id, unregistered);
        }

        function testRevert_SwitchDelegate_ToSelf() public {
            vm.expectRevert(Errors.InvalidDelegate.selector);
            vm.prank(user1);
            veMoca.switchDelegate(lock2_Id, user1);
        }

        function testRevert_SwitchDelegate_NonOwner() public {
            vm.expectRevert(Errors.InvalidOwner.selector);
            vm.prank(user2);
            veMoca.switchDelegate(lock2_Id, user3);
        }

        function testRevert_Lock1_CannotSwitchDelegate() public {
            // lock1 has action limit (near expiry)
            vm.expectRevert(Errors.LockExpiresTooSoon.selector);
            vm.prank(user1);
            veMoca.switchDelegate(lock1_Id, user2);
        }

    // ============ State Transition Test ============

        function test_StateTransition_Undelegate_Lock2() public {
            // Capture state before
            UnifiedStateSnapshot memory beforeState = captureAllStatesPlusDelegates(user1, lock2_Id, lock2_NewExpiry, 0, address(0), user2);
            
            vm.prank(user1);
            veMoca.undelegateLock(lock2_Id);
            
            // Verify undelegated
            DataTypes.Lock memory lock = getLock(lock2_Id);
            assertEq(lock.delegate, address(0), "Lock2 undelegated");
            
            // Verify via helper
            verifyUndelegateLock(beforeState);
        }
}

// =====================================================
// ================= EPOCH 2 - UNDELEGATE LOCK2 =================
// =====================================================

// note: user1 undelegates lock2
// lock1: delegated to user3
// lock2: undelegated (personal VP for user1)
abstract contract StateE2_User1_Undelegates_Lock2 is StateE2_User1_SwitchDelegate_Lock2 {
    
    function setUp() public virtual override {
        super.setUp();
        
        // Undelegate lock2
        vm.prank(user1);
        veMoca.undelegateLock(lock2_Id);
    }
}

contract StateE2_User1_Undelegates_Lock2_Test is StateE2_User1_Undelegates_Lock2 {

    // ============ State Verification ============

        function test_Lock2_Undelegated() public {
            DataTypes.Lock memory lock = getLock(lock2_Id);
            assertEq(lock.delegate, address(0), "Lock2 delegate is address(0)");
        }

        function test_Undelegate_PendingDeltas_Booked() public {
            // undelegateLock books pending deltas for next epoch
            // User gets addition, old delegate (user2) gets subtraction
            uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
            
            // User1 should have pending addition (gets VP back)
            (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) 
                = veMoca.userPendingDeltas(user1, nextEpochStart);
            assertTrue(hasAdd, "User has pending addition");
            assertEq(additions.slope, lock2_VeBalance_AfterIncreaseAmount.slope, "User add slope = lock2 slope");
            
            // User2 (old delegate) should have pending subtraction
            (hasAdd, hasSub, additions, subtractions) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
            assertTrue(hasSub, "Old delegate has pending subtraction");
            assertEq(subtractions.slope, lock2_VeBalance_AfterIncreaseAmount.slope, "Old delegate sub slope = lock2 slope");
        }

        function test_User1_PersonalVp_HasLock2() public {
            // User1 has lock2's personal VP (pending subtraction from delegation not yet applied)
            // undelegateLock only books pending addition, doesn't change current VP
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 user1PersonalVp = veMoca.balanceOfAt(user1, currentTimestamp, false);
            
            // User1's personal VP = lock2 VP (still has it from creation)
            uint128 expectedVp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, currentTimestamp);
            assertEq(user1PersonalVp, expectedVp, "User1 personal VP = lock2");
        }

        function test_User2_DelegatedVp_UnchangedThisEpoch() public {
            // In current epoch, user2's VP is UNCHANGED (pending takes effect next epoch)
            // Note: lock2 was switched to user2 then undelegated in same epoch
            // Both operations book pending deltas for next epoch
            uint128 user2DelegatedVp = veMoca.balanceOfAt(user2, uint128(block.timestamp), true);
            assertEq(user2DelegatedVp, 0, "User2 delegated VP = 0");
        }

        function test_TotalSupply_Unchanged() public {
            // Undelegation is internal reallocation, totalSupply unchanged
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
            
            // Expected: lock1 VP + lock2 VP (both still exist)
            uint128 lock1Vp = getValueAt(lock1_VeBalance, currentTimestamp);
            uint128 lock2Vp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, currentTimestamp);
            
            assertEq(totalSupply, lock1Vp + lock2Vp, "Total supply = sum of both locks");
        }

    // ============ Negative Tests ============

        function testRevert_Undelegate_AlreadyUndelegated() public {
            vm.expectRevert(Errors.LockNotDelegated.selector);
            vm.prank(user1);
            veMoca.undelegateLock(lock2_Id);
        }

        function testRevert_Undelegate_NonOwner() public {
            // First re-delegate lock2 so we can test
            vm.prank(user1);
            veMoca.delegateLock(lock2_Id, user2);
            
            vm.expectRevert(Errors.InvalidOwner.selector);
            vm.prank(user2);
            veMoca.undelegateLock(lock2_Id);
        }
}

// =====================================================
// ================= EPOCH 4 - UNLOCK LOCK1 =================
// =====================================================

// note: warp to E4, lock1 has expired (expired at E3)
// user1 unlocks lock1 to retrieve principals
abstract contract StateE4_User1_Unlocks_Lock1 is StateE2_User1_Undelegates_Lock2 {
    
    // Capture state before unlock for verification
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

contract StateE4_User1_Unlocks_Lock1_Test is StateE4_User1_Unlocks_Lock1 {

    // ============ State Verification ============

    function test_Lock1_IsUnlocked() public {
        DataTypes.Lock memory lock = getLock(lock1_Id);
        assertTrue(lock.isUnlocked, "Lock1 should be unlocked");
    }

    function test_User1_ReceivedPrincipals() public {
        // user1 should receive lock1's MOCA and esMOCA
        uint128 user1MocaAfter = uint128(user1.balance);
        uint128 user1EsMocaAfter = uint128(esMoca.balanceOf(user1));
        
        assertEq(user1MocaAfter, user1_MocaBalanceBefore + lock1_MocaAmount, "User1 received MOCA");
        assertEq(user1EsMocaAfter, user1_EsMocaBalanceBefore + lock1_EsMocaAmount, "User1 received esMOCA");
    }

    function test_TotalLocked_Decreased() public {
        // TOTAL_LOCKED should only include lock2 now
        uint128 expectedTotalMoca = lock2_MocaAmount + lock2_AdditionalMoca;
        uint128 expectedTotalEsMoca = lock2_EsMocaAmount + lock2_AdditionalEsMoca;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalMoca, "Total locked MOCA = lock2 only");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalEsMoca, "Total locked esMOCA = lock2 only");
    }

    function test_User3_DelegatedVp_Zero() public {
        // lock1 was delegated to user3, but now it's expired (E4, lock1 expired at E3)
        // Lock VP decays to 0 at expiry, so user3 should have 0 delegated VP
        uint128 user3DelegatedVp = veMoca.balanceOfAt(user3, uint128(block.timestamp), true);
        assertEq(user3DelegatedVp, 0, "User3 delegated VP = 0 (lock1 expired)");
    }

    function test_GlobalState_ReflectsLock2() public {
        // veGlobal should reflect lock2 (lock1 expired)
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        // Verify global slope includes at least lock2's slope
        uint128 lock2Slope = lock2_VeBalance_AfterIncreaseAmount.slope;
        assertGe(globalSlope, lock2Slope, "Global slope >= lock2 slope");
    }

    function test_Lock1_NoLongerContributesToVp() public {
        // Lock1 expired at E3, so its VP should be 0 now
        uint128 lock1Vp = veMoca.getLockVotingPowerAt(lock1_Id, uint128(block.timestamp));
        assertEq(lock1Vp, 0, "Lock1 VP = 0 (expired)");
    }

    function test_TotalSupplyAt_E2_E3_Finalized() public {
        // unlock() in setUp triggered _updateAccountAndGlobalAndPendingDeltas
        // which should have finalized historical epochs
        
        // totalSupplyAt[E2] and totalSupplyAt[E3] should be finalized
        uint128 epoch2Start = uint128(getEpochStartTimestamp(2));
        uint128 epoch3Start = uint128(getEpochStartTimestamp(3));
        
        uint128 totalSupplyAtE2 = veMoca.totalSupplyAt(epoch2Start);
        uint128 totalSupplyAtE3 = veMoca.totalSupplyAt(epoch3Start);
        
        // E2 and E3 should have > 0 supply (lock1 was active, lock2 was created in E2)
        assertGt(totalSupplyAtE2, 0, "totalSupplyAt[E2] finalized");
        assertGt(totalSupplyAtE3, 0, "totalSupplyAt[E3] finalized");
    }

    // ============ Negative Tests ============

    function testRevert_Unlock_NonExpiredLock() public {
        // lock2 is not expired, cannot unlock
        vm.expectRevert(Errors.InvalidExpiry.selector);
        vm.prank(user1);
        veMoca.unlock(lock2_Id);
    }

    function testRevert_Unlock_AlreadyUnlocked() public {
        // lock1 already unlocked
        vm.expectRevert(Errors.InvalidLockState.selector);
        vm.prank(user1);
        veMoca.unlock(lock1_Id);
    }

    function testRevert_Unlock_NonOwner() public {
        // Warp far into future to expire lock2
        vm.warp(lock2_NewExpiry + 1);
        
        vm.expectRevert(Errors.InvalidOwner.selector);
        vm.prank(user2);
        veMoca.unlock(lock2_Id);
    }

    // ============ State Transition Test ============

    function test_StateTransition_User3_CreatesLock3_DelegatesToUser2() public {
        // Fund user3
        vm.startPrank(user3);
            vm.deal(user3, 300 ether);
            esMoca.escrowMoca{value: 150 ether}();
            esMoca.approve(address(veMoca), 150 ether);
        vm.stopPrank();
        
        // Lock3 parameters
        uint128 lock3Expiry = uint128(getEpochEndTimestamp(15));
        uint128 lock3MocaAmount = 150 ether;
        uint128 lock3EsMocaAmount = 150 ether;
        
        // Create lock3 and delegate to user2
        vm.startPrank(user3);
            bytes32 lock3Id = veMoca.createLock{value: lock3MocaAmount}(lock3Expiry, lock3EsMocaAmount);
            veMoca.delegateLock(lock3Id, user2);
        vm.stopPrank();
        
        // Verify
        DataTypes.Lock memory lock3 = getLock(lock3Id);
        assertEq(lock3.owner, user3, "Lock3 owner = user3");
        assertEq(lock3.delegate, user2, "Lock3 delegate = user2");
    }
}

// =====================================================
// ================= EPOCH 4 - USER3 DELEGATES LOCK3 TO USER2 =================
// =====================================================

// note: user3 creates lock3 and delegates to user2
// lock1: unlocked
// lock2: user1's personal VP (undelegated)
// lock3: user3 -> user2 delegation
abstract contract StateE4_User3_DelegateLock3_ToUser2 is StateE4_User1_Unlocks_Lock1 {
    
    bytes32 public lock3_Id;
    uint128 public lock3_Expiry;
    uint128 public lock3_MocaAmount;
    uint128 public lock3_EsMocaAmount;
    DataTypes.VeBalance public lock3_VeBalance;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Lock3 parameters
        lock3_Expiry = uint128(getEpochEndTimestamp(15));
        lock3_MocaAmount = 150 ether;
        lock3_EsMocaAmount = 150 ether;
        
        // Fund user3
        vm.startPrank(user3);
            vm.deal(user3, 300 ether);
            esMoca.escrowMoca{value: lock3_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock3_EsMocaAmount);
            
            // Create lock3 and delegate to user2
            lock3_Id = veMoca.createLock{value: lock3_MocaAmount}(lock3_Expiry, lock3_EsMocaAmount);
            veMoca.delegateLock(lock3_Id, user2);
        vm.stopPrank();
        
        // Capture lock3 veBalance
        lock3_VeBalance = veMoca.getLockVeBalance(lock3_Id);
    }
}

contract StateE4_User3_DelegateLock3_ToUser2_Test is StateE4_User3_DelegateLock3_ToUser2 {

    // ============ State Verification ============

    function test_Lock3_Created_AndDelegated() public {
        DataTypes.Lock memory lock = getLock(lock3_Id);
        assertEq(lock.owner, user3, "Lock3 owner = user3");
        assertEq(lock.delegate, user2, "Lock3 delegate = user2");
        assertEq(lock.moca, lock3_MocaAmount, "Lock3 moca");
        assertEq(lock.esMoca, lock3_EsMocaAmount, "Lock3 esMoca");
        assertEq(lock.expiry, lock3_Expiry, "Lock3 expiry");
    }

    function test_Lock3_DelegationPendingDeltas_Booked() public {
        // Lock3 delegation books pending deltas for next epoch
        uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
        
        // User3 pending subtraction should be booked
        (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) 
            = veMoca.userPendingDeltas(user3, nextEpochStart);
        assertTrue(hasSub, "User3 pending subtraction booked");
        assertEq(subtractions.slope, lock3_VeBalance.slope, "User3 pending sub slope = lock3 slope");
        
        // User2 (delegate) pending addition should be booked
        (hasAdd, hasSub, additions, subtractions) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
        assertTrue(hasAdd, "Delegate pending addition booked");
        assertEq(additions.slope, lock3_VeBalance.slope, "Delegate pending add slope = lock3 slope");
    }

    function test_User2_DelegatedVp_ZeroThisEpoch() public {
        // In current epoch, user2's delegated VP is 0 (pending takes effect next epoch)
        uint128 user2DelegatedVp = veMoca.balanceOfAt(user2, uint128(block.timestamp), true);
        assertEq(user2DelegatedVp, 0, "User2 delegated VP = 0 (pending)");
    }

    function test_User3_PersonalVp_HasLock3() public {
        // In current epoch, user3 still has lock3's personal VP (pending subtraction applies next epoch)
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user3PersonalVp = veMoca.balanceOfAt(user3, currentTimestamp, false);
        
        // User3's personal VP = lock3 VP (delegation pending)
        uint128 expectedVp = getValueAt(lock3_VeBalance, currentTimestamp);
        assertEq(user3PersonalVp, expectedVp, "User3 personal VP = lock3 (pending delegation)");
    }

    function test_GlobalState_Lock2_And_Lock3() public {
        // Global state should include lock2 + lock3
        uint128 expectedTotalMoca = (lock2_MocaAmount + lock2_AdditionalMoca) + lock3_MocaAmount;
        uint128 expectedTotalEsMoca = (lock2_EsMocaAmount + lock2_AdditionalEsMoca) + lock3_EsMocaAmount;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalMoca, "Total locked MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalEsMoca, "Total locked esMOCA");
    }

    function test_TotalSupply_Lock2_And_Lock3() public {
        // Total supply should reflect both active locks (lock2 + lock3)
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        uint128 lock2Vp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, currentTimestamp);
        uint128 lock3Vp = getValueAt(lock3_VeBalance, currentTimestamp);
        
        // Total supply should be at least lock2 + lock3 (may include residual from state updates)
        assertGe(totalSupply, lock2Vp + lock3Vp, "Total supply >= lock2 + lock3");
    }

    function test_Lock3_VpAtEpochEnd() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        
        uint128 lock3VpAtEnd = veMoca.getLockVotingPowerAt(lock3_Id, epochEndTimestamp);
        uint128 expectedVp = getValueAt(lock3_VeBalance, epochEndTimestamp);
        
        assertEq(lock3VpAtEnd, expectedVp, "Lock3 VP at epoch end");
    }

    // ============ Negative Tests ============

    function testRevert_User3_DelegateToUnregistered() public {
        // user3 cannot delegate to unregistered address
        address unregistered = address(0x456);
        
        // First need to create another lock for user3 to test
        vm.startPrank(user3);
            vm.deal(user3, 100 ether);
            bytes32 tempLockId = veMoca.createLock{value: 100 ether}(lock3_Expiry, 0);
        vm.stopPrank();
        
        vm.expectRevert(Errors.DelegateNotRegistered.selector);
        vm.prank(user3);
        veMoca.delegateLock(tempLockId, unregistered);
    }

    // ============ State Transition Test ============

    function test_StateTransition_User2_CreatesLock4() public {
        // Fund user2
        vm.startPrank(user2);
            vm.deal(user2, 100 ether);
            esMoca.escrowMoca{value: 50 ether}();
            esMoca.approve(address(veMoca), 50 ether);
        vm.stopPrank();
        
        // Lock4 parameters (personal lock, not delegated)
        uint128 lock4Expiry = uint128(getEpochEndTimestamp(16));
        uint128 lock4MocaAmount = 50 ether;
        uint128 lock4EsMocaAmount = 50 ether;
        
        // Create lock4 (don't delegate)
        vm.prank(user2);
        bytes32 lock4Id = veMoca.createLock{value: lock4MocaAmount}(lock4Expiry, lock4EsMocaAmount);
        
        // Verify
        DataTypes.Lock memory lock4 = getLock(lock4Id);
        assertEq(lock4.owner, user2, "Lock4 owner = user2");
        assertEq(lock4.delegate, address(0), "Lock4 not delegated");
    }
}

// =====================================================
// ================= EPOCH 4 - USER2 CREATES LOCK4 =================
// =====================================================

// note: user2 creates personal lock4 (not delegated)
// user2 has both personal VP (lock4) and delegated VP (lock3)
abstract contract StateE4_User2_CreatesLock4 is StateE4_User3_DelegateLock3_ToUser2 {
    
    bytes32 public lock4_Id;
    uint128 public lock4_Expiry;
    uint128 public lock4_MocaAmount;
    uint128 public lock4_EsMocaAmount;
    DataTypes.VeBalance public lock4_VeBalance;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Lock4 parameters
        lock4_Expiry = uint128(getEpochEndTimestamp(16));
        lock4_MocaAmount = 50 ether;
        lock4_EsMocaAmount = 50 ether;
        
        // Fund user2
        vm.startPrank(user2);
            vm.deal(user2, 100 ether);
            esMoca.escrowMoca{value: lock4_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock4_EsMocaAmount);
            
            // Create lock4 (personal, not delegated)
            lock4_Id = veMoca.createLock{value: lock4_MocaAmount}(lock4_Expiry, lock4_EsMocaAmount);
        vm.stopPrank();
        
        // Capture lock4 veBalance
        lock4_VeBalance = veMoca.getLockVeBalance(lock4_Id);
    }
}

contract StateE4_User2_CreatesLock4_Test is StateE4_User2_CreatesLock4 {

    // ============ State Verification ============

    function test_Lock4_Created_NotDelegated() public {
        DataTypes.Lock memory lock = getLock(lock4_Id);
        assertEq(lock.owner, user2, "Lock4 owner = user2");
        assertEq(lock.delegate, address(0), "Lock4 not delegated");
        assertEq(lock.moca, lock4_MocaAmount, "Lock4 moca");
        assertEq(lock.esMoca, lock4_EsMocaAmount, "Lock4 esMoca");
    }

    function test_User2_HasPersonalVp_Lock4() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user2PersonalVp = veMoca.balanceOfAt(user2, currentTimestamp, false);
        
        // user2 personal VP = lock4
        uint128 expectedVp = getValueAt(lock4_VeBalance, currentTimestamp);
        assertEq(user2PersonalVp, expectedVp, "User2 personal VP = lock4");
    }

    function test_User2_DelegatedVp_PendingFromLock3() public {
        // In current epoch, user2's delegated VP is still 0 
        // (lock3 delegation pending, takes effect next epoch)
        uint128 user2DelegatedVp = veMoca.balanceOfAt(user2, uint128(block.timestamp), true);
        assertEq(user2DelegatedVp, 0, "User2 delegated VP = 0 (pending)");
        
        // Verify pending addition is booked
        uint128 nextEpochStart = getCurrentEpochStart() + EPOCH_DURATION;
        (bool hasAdd, , DataTypes.VeBalance memory additions, ) = veMoca.delegatePendingDeltas(user2, nextEpochStart);
        assertTrue(hasAdd, "User2 has pending addition from lock3");
    }

    function test_GlobalState_AllActiveLocks() public {
        // Global state: lock2 (user1 personal) + lock3 (user3->user2) + lock4 (user2 personal)
        uint128 expectedTotalMoca = (lock2_MocaAmount + lock2_AdditionalMoca) + lock3_MocaAmount + lock4_MocaAmount;
        uint128 expectedTotalEsMoca = (lock2_EsMocaAmount + lock2_AdditionalEsMoca) + lock3_EsMocaAmount + lock4_EsMocaAmount;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalMoca, "Total locked MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalEsMoca, "Total locked esMOCA");
    }

    function test_AllUsers_BalanceAtEpochEnd_CurrentState() public {
        // In current epoch (E4), delegation pending deltas haven't been applied yet
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        
        // user1: personal VP = lock2 (undelegated in E2)
        uint128 user1BalanceAtEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        uint128 expectedUser1Vp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, epochEndTimestamp);
        assertEq(user1BalanceAtEnd, expectedUser1Vp, "User1 balanceAtEpochEnd = lock2");
        
        // user2: personal VP = lock4
        uint128 user2PersonalAtEnd = veMoca.balanceAtEpochEnd(user2, currentEpoch, false);
        uint128 expectedUser2PersonalVp = getValueAt(lock4_VeBalance, epochEndTimestamp);
        assertEq(user2PersonalAtEnd, expectedUser2PersonalVp, "User2 personal balanceAtEpochEnd = lock4");
        
        // user2: delegated VP = 0 (lock3 delegation pending, takes effect next epoch)
        uint128 user2DelegatedAtEnd = veMoca.balanceAtEpochEnd(user2, currentEpoch, true);
        assertEq(user2DelegatedAtEnd, 0, "User2 delegated balanceAtEpochEnd = 0 (pending)");
        
        // user3: personal VP = lock3 (delegation pending)
        uint128 user3PersonalAtEnd = veMoca.balanceAtEpochEnd(user3, currentEpoch, false);
        uint128 expectedUser3Vp = getValueAt(lock3_VeBalance, epochEndTimestamp);
        assertEq(user3PersonalAtEnd, expectedUser3Vp, "User3 personal balanceAtEpochEnd = lock3 (pending delegation)");
    }

    function test_TotalSupply_AllLocks() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        // Expected: lock2 + lock3 + lock4
        uint128 lock2Vp = getValueAt(lock2_VeBalance_AfterIncreaseAmount, currentTimestamp);
        uint128 lock3Vp = getValueAt(lock3_VeBalance, currentTimestamp);
        uint128 lock4Vp = getValueAt(lock4_VeBalance, currentTimestamp);
        
        // Total supply should be at least the sum of active locks
        assertGe(totalSupply, lock2Vp + lock3Vp + lock4Vp, "Total supply >= lock2 + lock3 + lock4");
    }

    // ============ Final Comprehensive State Verification ============

    function test_FinalState_AllLocks() public view {
        // Lock1: unlocked
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        assertTrue(lock1.isUnlocked, "Lock1 is unlocked");
        
        // Lock2: user1's personal lock (undelegated)
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        assertEq(lock2.owner, user1, "Lock2 owner = user1");
        assertEq(lock2.delegate, address(0), "Lock2 not delegated");
        assertFalse(lock2.isUnlocked, "Lock2 not unlocked");
        
        // Lock3: user3 -> user2 delegation
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        assertEq(lock3.owner, user3, "Lock3 owner = user3");
        assertEq(lock3.delegate, user2, "Lock3 delegate = user2");
        assertFalse(lock3.isUnlocked, "Lock3 not unlocked");
        
        // Lock4: user2's personal lock
        DataTypes.Lock memory lock4 = getLock(lock4_Id);
        assertEq(lock4.owner, user2, "Lock4 owner = user2");
        assertEq(lock4.delegate, address(0), "Lock4 not delegated");
        assertFalse(lock4.isUnlocked, "Lock4 not unlocked");
    }

    function test_FinalState_DelegateRegistrations() public view{
        // user2 and user3 are registered delegates
        assertTrue(veMoca.isRegisteredDelegate(user2), "User2 is registered delegate");
        assertTrue(veMoca.isRegisteredDelegate(user3), "User3 is registered delegate");
        // user1 is not a registered delegate
        assertFalse(veMoca.isRegisteredDelegate(user1), "User1 is not a delegate");
    }
}

*/