// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import {Constants} from "../../src/libraries/Constants.sol";


abstract contract DelegateHelper is Test, TestingHarness {
    using stdStorage for StdStorage;

    // PERIODICITY:  does not account for leap year or leap seconds
    uint128 public constant EPOCH_DURATION = 14 days;                    
    uint128 public constant MIN_LOCK_DURATION = 28 days;            
    uint128 public constant MAX_LOCK_DURATION = 728 days;     


    /** note: why use dummy variable? 
        When you call EpochMath.getCurrentEpochNumber() directly in a test, these internal functions get inlined into the test contract at compile time. 
        This can cause issues with Foundry's runtime state modifications like vm.warp().
        The issue is that the Solidity optimizer might be evaluating block.timestamp at a different point than expected, 
        or caching values in unexpected ways when dealing with inlined library code.
        So we need to use a dummy variable to prevent the compiler from inlining the functions.
    */
    uint256 private dummy; // so that solidity compiler does not optimize out the functions

// ================= EPOCH MATH =================

        ///@dev returns epoch number for a given timestamp
        function getEpochNumber(uint128 timestamp) public returns (uint128) {
            dummy = 1;
            return timestamp / EPOCH_DURATION;
        }

        ///@dev returns current epoch number
        function getCurrentEpochNumber() public returns (uint128) {
            dummy = 1;
            return getEpochNumber(uint128(block.timestamp));
        }

        ///@dev returns epoch start time for a given timestamp
        function getEpochStartForTimestamp(uint128 timestamp) public returns (uint128) {
            dummy = 1;
            // intentionally divide first to "discard" remainder
            return (timestamp / EPOCH_DURATION) * EPOCH_DURATION;   // forge-lint: disable-line(divide-before-multiply)
        }

        ///@dev returns epoch end time for a given timestamp
        function getEpochEndForTimestamp(uint128 timestamp) public returns (uint128) {
            dummy = 1;
            return getEpochStartForTimestamp(timestamp) + EPOCH_DURATION;
        }
        

        ///@dev returns current epoch start time | uint128: Checkpoint{veBla, uint128 lastUpdatedAt}
        function getCurrentEpochStart() public returns (uint128) {
            dummy = 1;
            return uint128(getEpochStartForTimestamp(uint128(block.timestamp)));
        }

        ///@dev returns current epoch end time
        function getCurrentEpochEnd() public returns (uint128) {
            dummy = 1;
            return getEpochEndTimestamp(getCurrentEpochNumber());
        }

        function getEpochStartTimestamp(uint128 epoch) public returns (uint128) {
            dummy = 1;
            return epoch * EPOCH_DURATION;
        }

        ///@dev returns epoch end time for a given epoch number
        function getEpochEndTimestamp(uint128 epoch) public returns (uint128) {
            dummy = 1;
            // end of epoch:N is the start of epoch:N+1
            return (epoch + 1) * EPOCH_DURATION;
        }

        // used in _createLockFor()
        function isValidEpochTime(uint256 timestamp) public returns (bool) {
            dummy = 1;
            return timestamp % EPOCH_DURATION == 0;
        }

// ================= STATE VERIFICATION HELPERS =================

    
    function getLock(bytes32 lockId) public view returns (DataTypes.Lock memory lock) {
        (
            lock.owner,
            lock.expiry,
            lock.moca,
            lock.esMoca,
            lock.isUnlocked,
            lock.delegate,
            lock.currentHolder,
            lock.delegationEpoch
        ) = veMoca.locks(lockId);
    }

    function getLockHistory(bytes32 lockId, uint256 index) public view returns (DataTypes.Checkpoint memory) {
        DataTypes.Checkpoint memory checkpoint;
        (checkpoint.veBalance, checkpoint.lastUpdatedAt) = veMoca.lockHistory(lockId, index);
        return checkpoint;
    }

    function getValueAt(DataTypes.VeBalance memory a, uint128 timestamp) public pure returns (uint128) {
        uint128 decay = a.slope * timestamp;
        if(a.bias <= decay) return 0;
        return a.bias - decay;
    }

    function convertToVeBalance(DataTypes.Lock memory lock) public pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;
        veBalance.slope = (lock.moca + lock.esMoca) / MAX_LOCK_DURATION;
        veBalance.bias = veBalance.slope * lock.expiry;
        return veBalance;
    }

    function getLockVotingPowerAt(bytes32 lockId, uint128 timestamp) public view returns (uint128) {
        DataTypes.Lock memory lock = getLock(lockId);
        if(lock.expiry <= timestamp) return 0;

        return getValueAt(convertToVeBalance(lock), timestamp);
    }

// ================= DELEGATION STATE SNAPSHOTS =================

    struct TokensSnapshot {
        uint128 userMoca;
        uint128 userEsMoca;
        uint128 contractMoca; 
        uint128 contractEsMoca;
    }

    struct GlobalStateSnapshot {
        // global vars
        uint128 TOTAL_LOCKED_MOCA;
        uint128 TOTAL_LOCKED_ESMOCA;
        DataTypes.VeBalance veGlobal;
        uint128 lastUpdatedTimestamp;

        // Mappings
        uint128 slopeChange; // at expiry
        uint128 slopeChangeNewExpiry; // at newExpiry (for increaseDuration)
        uint128 totalSupplyAt; // at currentEpochStart

        // View functions
        uint128 totalSupplyAtTimestamp;              // totalSupplyAt(timestamp)
    }

    struct UserStateSnapshot {
        DataTypes.VeBalance userHistory;  // at currentEpochStart
        uint128 userSlopeChange;          // at expiry
        uint128 userLastUpdatedTimestamp;

        uint128 userSlopeChangeNewExpiry; // at newExpiry (for increaseDuration)

        // Pending deltas (for next epoch)
        DataTypes.VeDeltas userPendingDelta;

        // View functions
        uint128 userCurrentVotingPower;               // balanceOfAt(user, currentTimestamp, false)
        uint128 userVotingPowerAtEpochEnd;            // balanceAtEpochEnd(user, epoch, false)

        uint128 userDelegatedVotingPower;
        uint128 userDelegatedVotingPowerAtEpochEnd;
    }

    struct LockStateSnapshot {
        bytes32 lockId;
        DataTypes.Lock lock;
        DataTypes.Checkpoint[] lockHistory;
        uint128 lockCurrentVotingPower;
        uint128 lockVotingPowerAtEpochEnd;
        uint128 numOfDelegateActionsThisEpoch;
    }

    struct DelegateStateSnapshot {
        // Core delegate state
        DataTypes.VeBalance delegateHistory;          // at currentEpochStart
        uint128 delegateSlopeChange;                  // at lock expiry
        uint128 delegateLastUpdatedTimestamp;
        
        uint128 delegateSlopeChangeNewExpiry;        // at newExpiry (for increaseDuration)

        // Pending deltas (for next epoch)
        DataTypes.VeDeltas delegatePendingDelta;
        
        // View functions
        uint128 delegateCurrentVotingPower;               // balanceOfAt(delegate, timestamp, true)
        uint128 delegateVotingPowerAtEpochEnd;            // balanceAtEpochEnd(delegate, epoch, true)
    }

    struct UserDelegatePairStateSnapshot {
        // Core pair state
        DataTypes.VeBalance delegatedAggregationHistory;   // at currentEpochStart
        uint128 userDelegatedSlopeChange;                  // at lock expiry
        uint128 userDelegatedPairLastUpdatedTimestamp;
        
        uint128 userDelegatedSlopeChangeNewExpiry;        // at newExpiry (for increaseDuration)

        // Pending deltas (for next epoch)
        DataTypes.VeDeltas pairPendingDelta;
        
        // View functions
        uint128 userDelegatedCurrentVotingPower;          // calculated from delegatedAggregationHistory
        uint128 userDelegatedVotingPowerAtEpochEnd;       // getSpecificDelegatedBalanceAtEpochEnd
    }

    // Unified State Snapshot
    struct UnifiedStateSnapshot {
        // Common states
        TokensSnapshot tokensState;
        GlobalStateSnapshot globalState;
        UserStateSnapshot userState;
        LockStateSnapshot lockState;

        // Target delegate state (for delegateLock/switchDelegate target)
        DelegateStateSnapshot targetDelegateState;

        // Old delegate state (for switchDelegate/undelegate)
        DelegateStateSnapshot oldDelegateState;

        // User-TargetDelegate pair state
        UserDelegatePairStateSnapshot targetPairState;
        
        // User-OldDelegate pair state (for switchDelegate/undelegate)
        UserDelegatePairStateSnapshot oldPairState;
    }

// ================= CAPTURE FUNCTIONS =================

    function captureTokensState(address user) internal view returns (TokensSnapshot memory) {
        TokensSnapshot memory state;
        // user
        state.userMoca = uint128(user.balance);
        state.userEsMoca = uint128(esMoca.balanceOf(user));
        // contract
        state.contractMoca = uint128(address(veMoca).balance);
        state.contractEsMoca = uint128(esMoca.balanceOf(address(veMoca)));

        return state;
    }

    function captureGlobalState(uint128 expiry, uint128 newExpiry) internal returns (GlobalStateSnapshot memory) {
        GlobalStateSnapshot memory state;

        // global vars
        (state.veGlobal.bias, state.veGlobal.slope) = veMoca.veGlobal();
        state.TOTAL_LOCKED_MOCA = veMoca.TOTAL_LOCKED_MOCA();
        state.TOTAL_LOCKED_ESMOCA = veMoca.TOTAL_LOCKED_ESMOCA();
        state.lastUpdatedTimestamp = veMoca.lastUpdatedTimestamp();
        
        // slopeChange
        state.slopeChange = veMoca.slopeChanges(expiry);
        if (newExpiry != 0) state.slopeChangeNewExpiry = veMoca.slopeChanges(newExpiry);
        
        // totalSupplyAt
        state.totalSupplyAt = veMoca.totalSupplyAt(getCurrentEpochStart());
        // View functions
        state.totalSupplyAtTimestamp = veMoca.totalSupplyAtTimestamp(uint128(block.timestamp));

        return state;
    }

    // pendingDeltas are captured for nextEpoch
    function captureUserState(address user, uint128 expiry, uint128 newExpiry) internal returns (UserStateSnapshot memory) {
        UserStateSnapshot memory state;

        // epoch vars
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 epoch = getCurrentEpochNumber();

        // user vars
        (state.userHistory.bias, state.userHistory.slope) = veMoca.userHistory(user, currentEpochStart);
        state.userSlopeChange = veMoca.userSlopeChanges(user, expiry);
        state.userLastUpdatedTimestamp = veMoca.userLastUpdatedTimestamp(user);

        // Slope change at newExpiry (for increaseDuration)
        if (newExpiry != 0) state.userSlopeChangeNewExpiry = veMoca.userSlopeChanges(user, newExpiry);

        // Pending deltas
        (
            state.userPendingDelta.hasAddition,
            state.userPendingDelta.hasSubtraction,
            state.userPendingDelta.additions,
            state.userPendingDelta.subtractions
        ) = veMoca.userPendingDeltas(user, nextEpochStart);

        // View functions
        state.userCurrentVotingPower = veMoca.balanceOfAt(user, uint128(block.timestamp), false);
        state.userVotingPowerAtEpochEnd = veMoca.balanceAtEpochEnd(user, epoch, false);
        state.userDelegatedVotingPower = veMoca.balanceOfAt(user, uint128(block.timestamp), true);
        state.userDelegatedVotingPowerAtEpochEnd = veMoca.balanceAtEpochEnd(user, epoch, true);

        return state;
    }

    // pendingDeltas are captured for nextEpoch
    function captureDelegateState(address delegate, uint128 expiry, uint128 newExpiry) internal returns (DelegateStateSnapshot memory) {
        DelegateStateSnapshot memory state;

        // epoch vars
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 epoch = getCurrentEpochNumber();

        // Core state
        (state.delegateHistory.bias, state.delegateHistory.slope) = veMoca.delegateHistory(delegate, currentEpochStart);
        state.delegateSlopeChange = veMoca.delegateSlopeChanges(delegate, expiry);
        state.delegateLastUpdatedTimestamp = veMoca.delegateLastUpdatedTimestamp(delegate);

        // Slope change at newExpiry (for increaseDuration)
        if (newExpiry != 0) state.delegateSlopeChangeNewExpiry = veMoca.delegateSlopeChanges(delegate, newExpiry);
        
        // Pending deltas: will be applied in the next epoch
        (
            state.delegatePendingDelta.hasAddition, 
            state.delegatePendingDelta.hasSubtraction,
            state.delegatePendingDelta.additions,
            state.delegatePendingDelta.subtractions
        ) = veMoca.delegatePendingDeltas(delegate, nextEpochStart);
        
        // View functions
        state.delegateCurrentVotingPower = veMoca.balanceOfAt(delegate, uint128(block.timestamp), true);
        state.delegateVotingPowerAtEpochEnd = veMoca.balanceAtEpochEnd(delegate, epoch, true);
        
        return state;
    }

    // pendingDeltas are captured for nextEpoch
    function captureUserDelegatePairState(address user, address delegate, uint128 expiry, uint128 newExpiry) internal returns (UserDelegatePairStateSnapshot memory) {
        UserDelegatePairStateSnapshot memory state;

        // epoch vars
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 epoch = getCurrentEpochNumber();

        // Core state
        (state.delegatedAggregationHistory.bias, state.delegatedAggregationHistory.slope) = veMoca.delegatedAggregationHistory(user, delegate, currentEpochStart);
        state.userDelegatedSlopeChange = veMoca.userDelegatedSlopeChanges(user, delegate, expiry);
        state.userDelegatedPairLastUpdatedTimestamp = veMoca.userDelegatedPairLastUpdatedTimestamp(user, delegate);

        // Slope change at newExpiry (for increaseDuration)
        if (newExpiry != 0) state.userDelegatedSlopeChangeNewExpiry = veMoca.userDelegatedSlopeChanges(user, delegate, newExpiry);
        
        // Pending deltas: will be applied in the next epoch
        (
            state.pairPendingDelta.hasAddition,
            state.pairPendingDelta.hasSubtraction,
            state.pairPendingDelta.additions,
            state.pairPendingDelta.subtractions
        ) = veMoca.userPendingDeltasForDelegate(user, delegate, nextEpochStart);
        
        // View functions
        state.userDelegatedCurrentVotingPower = getValueAt(state.delegatedAggregationHistory, uint128(block.timestamp));
        state.userDelegatedVotingPowerAtEpochEnd = veMoca.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, epoch);

        return state;
    }

    function captureLockState(bytes32 lockId) internal returns (LockStateSnapshot memory) {
        LockStateSnapshot memory state;

        // epoch vars
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // store lock state
        state.lock = getLock(lockId);
        state.lockId = lockId;

        // lock history
        uint256 len = veMoca.getLockHistoryLength(lockId);
        state.lockHistory = new DataTypes.Checkpoint[](len);
        
        for(uint256 i; i < len; ++i) {
            state.lockHistory[i] = getLockHistory(lockId, i);
        }
        
        // lockVotingPower
        state.lockCurrentVotingPower = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
        state.lockVotingPowerAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, getCurrentEpochEnd());

        // numOfDelegateActionsThisEpoch
        state.numOfDelegateActionsThisEpoch = veMoca.numOfDelegateActionsPerEpoch(lockId, currentEpochStart);
        
        return state;
    }

    // Captures all states for delegation-related tests
    // current lock expiry & new expiry (for increaseDuration, 0 otherwise)
    // targetDelegate: The target delegate address (for delegateLock/switchDelegate, address(0) if none)
    // oldDelegate: The old delegate address (for switchDelegate/undelegate, address(0) if none)
    function captureAllStatesPlusDelegates(
        address user, bytes32 lockId, uint128 expiry, uint128 newExpiry,
        address targetDelegate, address oldDelegate
    ) internal returns (UnifiedStateSnapshot memory) {
        UnifiedStateSnapshot memory state;
        
        // Common states
        state.tokensState = captureTokensState(user);
        state.globalState = captureGlobalState(expiry, newExpiry);
        state.userState = captureUserState(user, expiry, newExpiry);
        state.lockState = captureLockState(lockId);
        
        // Target delegate state (for delegateLock/switchDelegate)
        if (targetDelegate != address(0)) {
            state.targetDelegateState = captureDelegateState(targetDelegate, expiry, newExpiry);
            state.targetPairState = captureUserDelegatePairState(user, targetDelegate, expiry, newExpiry);
        }
        
        // Old delegate state (for switchDelegate/undelegate)
        if (oldDelegate != address(0)) {
            state.oldDelegateState = captureDelegateState(oldDelegate, expiry, newExpiry);
            state.oldPairState = captureUserDelegatePairState(user, oldDelegate, expiry, newExpiry);
        }
        
        return state;
    }

    // Overload for non-delegation scenarios (backward compatibility)
    // current lock expiry & new expiry (for increaseDuration, 0 otherwise)
    function captureAllStates(address user, bytes32 lockId, uint128 expiry, uint128 newExpiry) internal returns (UnifiedStateSnapshot memory) {
        return captureAllStatesPlusDelegates(user, lockId, expiry, newExpiry, address(0), address(0));
    }

// ================= VERIFY FUNCTIONS =================

    // Verifies State: delegateLock(targetDelegate) -> user + targetDelegate + user-delegate pair
    // takes in beforeState and references against current state[afterState] of the contract -> therefore no need to capture afterState
    function verifyDelegateLock(UnifiedStateSnapshot memory beforeState, address targetDelegate) internal {
        // Get lock info from beforeState
        DataTypes.Lock memory lockBefore = beforeState.lockState.lock;
        bytes32 lockId = beforeState.lockState.lockId;

        // Calculate lock veBalance using helper
        DataTypes.VeBalance memory lockVeBalance = convertToVeBalance(lockBefore);
        uint128 lockSlope = lockVeBalance.slope;
        uint128 lockBias = lockVeBalance.bias;

        // Epoch timing
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 epoch = getCurrentEpochNumber();

        // ============ 1. Lock State ============
            DataTypes.Lock memory lockAfter = getLock(lockId);
            assertEq(lockAfter.delegate, targetDelegate, "Lock delegate must be set");
            assertEq(lockAfter.owner, lockBefore.owner, "Lock owner unchanged");
            assertEq(lockAfter.moca, lockBefore.moca, "Lock moca unchanged");
            assertEq(lockAfter.esMoca, lockBefore.esMoca, "Lock esMoca unchanged");
            assertEq(lockAfter.expiry, lockBefore.expiry, "Lock expiry unchanged");
            assertFalse(lockAfter.isUnlocked, "Lock not unlocked");

        // ============ 1.1 Lock Voting Power (UNCHANGED) ============
            uint128 lockVPNow = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
            uint128 lockVPAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, getCurrentEpochEnd());
            assertEq(lockVPNow, beforeState.lockState.lockCurrentVotingPower, "Lock VP current unchanged");
            assertEq(lockVPAtEpochEnd, beforeState.lockState.lockVotingPowerAtEpochEnd, "Lock VP at epoch end unchanged");

        // ============ 2. Delegate Registration ============
            // if delegation txn is successful, this check is redundant. but kept for redundancy
            assertTrue(veMoca.isRegisteredDelegate(targetDelegate), "Target delegate must be registered");

        // ============ 2.1 Delegation Action Counter ============
            uint128 actionCountAfter = veMoca.numOfDelegateActionsPerEpoch(lockId, currentEpochStart);
            assertEq(actionCountAfter, beforeState.lockState.numOfDelegateActionsThisEpoch + 1, "Action counter incremented");
        
        // ============ 2.2 Timestamp Updates ============
            assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdated");
            assertEq(veMoca.userLastUpdatedTimestamp(lockAfter.owner), currentEpochStart, "User lastUpdated");
            assertEq(veMoca.delegateLastUpdatedTimestamp(targetDelegate), currentEpochStart, "Delegate lastUpdated");
            assertEq(veMoca.userDelegatedPairLastUpdatedTimestamp(lockAfter.owner, targetDelegate), currentEpochStart, "Pair lastUpdated");

        // ============ 3. User State ============
            // userSlopeChanges[expiry]: decreases by lockSlope
            assertEq(veMoca.userSlopeChanges(lockAfter.owner, lockAfter.expiry), beforeState.userState.userSlopeChange - lockSlope, "User slopeChange decreased");
        
            // userPendingDeltas[nextEpoch]: subtraction booked for user || he would no longer have the lock's VP - delegate should have it.
            (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) = veMoca.userPendingDeltas(lockAfter.owner, nextEpochStart);
        
            assertTrue(hasSub, "User pending subtraction");
            assertEq(subtractions.bias, beforeState.userState.userPendingDelta.subtractions.bias + lockBias, "User pending sub bias");
            assertEq(subtractions.slope, beforeState.userState.userPendingDelta.subtractions.slope + lockSlope, "User pending sub slope");
            
            // User VP unchanged in current epoch
            assertEq(veMoca.balanceOfAt(lockAfter.owner, uint128(block.timestamp), false), beforeState.userState.userCurrentVotingPower, "User VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(lockAfter.owner, epoch, false), beforeState.userState.userVotingPowerAtEpochEnd, "User VP at epoch end unchanged");

        // ============ 4. Target Delegate State ============
            
            // delegateSlopeChanges[expiry]: increases by lockSlope
            assertEq(veMoca.delegateSlopeChanges(targetDelegate, lockAfter.expiry), beforeState.targetDelegateState.delegateSlopeChange + lockSlope, "Delegate slopeChange increased");
            
            // delegatePendingDeltas[nextEpoch]: addition booked for delegate || he would now have the lock's VP - user should no longer have it.
            (hasAdd, hasSub, additions, subtractions) = veMoca.delegatePendingDeltas(targetDelegate, nextEpochStart);
            
            assertTrue(hasAdd, "Delegate pending addition");
            assertEq(additions.bias, beforeState.targetDelegateState.delegatePendingDelta.additions.bias + lockBias, "Delegate pending add bias");
            assertEq(additions.slope, beforeState.targetDelegateState.delegatePendingDelta.additions.slope + lockSlope, "Delegate pending add slope");
            
            // Delegate VP unchanged in current epoch
            assertEq(veMoca.balanceOfAt(targetDelegate, uint128(block.timestamp), true), beforeState.targetDelegateState.delegateCurrentVotingPower, "Delegate VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(targetDelegate, epoch, true), beforeState.targetDelegateState.delegateVotingPowerAtEpochEnd, "Delegate VP at epoch end unchanged");

        // ============ 5. User-Delegate Pair State ============

            // userDelegatedSlopeChanges[expiry]: increases by lockSlope [shifted away from owner to delegate]
            assertEq(veMoca.userDelegatedSlopeChanges(lockAfter.owner, targetDelegate, lockAfter.expiry), beforeState.targetPairState.userDelegatedSlopeChange + lockSlope, "Pair slopeChange increased");
            
            // userPendingDeltasForDelegate[nextEpoch]: addition booked for pair in NEXT_EPOCH || user would no longer have the lock's VP - delegate should have it
            (hasAdd, hasSub, additions, subtractions) = veMoca.userPendingDeltasForDelegate(lockAfter.owner, targetDelegate, nextEpochStart);
            
            assertTrue(hasAdd, "Pair pending addition");
            assertEq(additions.bias, beforeState.targetPairState.pairPendingDelta.additions.bias + lockBias, "Pair pending add bias");
            assertEq(additions.slope, beforeState.targetPairState.pairPendingDelta.additions.slope + lockSlope, "Pair pending add slope");
           
            // Verify Pair Current VP (calculated) - Should be UNCHANGED
            {
                DataTypes.VeBalance memory currentHistory;
                (currentHistory.bias, currentHistory.slope) = veMoca.delegatedAggregationHistory(lockAfter.owner, targetDelegate, currentEpochStart);

                assertEq(getValueAt(currentHistory, uint128(block.timestamp)), beforeState.targetPairState.userDelegatedCurrentVotingPower, "Pair VP current unchanged");
            }

            // Pair VP at epoch end unchanged
            assertEq(veMoca.getSpecificDelegatedBalanceAtEpochEnd(lockAfter.owner, targetDelegate, epoch), beforeState.targetPairState.userDelegatedVotingPowerAtEpochEnd, "Pair VP at epoch end unchanged");

        // ============ 5.1) Storage: Pair History (No immediate changes) ============
        
            // Verify storage directly: History at current epoch start should match snapshot (no immediate changes)
            (uint128 b, uint128 s) = veMoca.delegatedAggregationHistory(lockAfter.owner, targetDelegate, currentEpochStart);
            assertEq(b, beforeState.targetPairState.delegatedAggregationHistory.bias, "Storage: Pair history bias unchanged");
            assertEq(s, beforeState.targetPairState.delegatedAggregationHistory.slope, "Storage: Pair history slope unchanged");

        // ============ 6. Global State (Invariants) ============

            (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
            assertEq(globalBias, beforeState.globalState.veGlobal.bias, "Global bias unchanged");
            assertEq(globalSlope, beforeState.globalState.veGlobal.slope, "Global slope unchanged");
            assertEq(veMoca.slopeChanges(lockAfter.expiry), beforeState.globalState.slopeChange, "Global slopeChange unchanged");
            assertEq(veMoca.totalSupplyAtTimestamp(uint128(block.timestamp)), beforeState.globalState.totalSupplyAtTimestamp, "Total supply unchanged");
            
            // totalSupplyAt for currentEpochStart unchanged (is only updated in the new epoch for the current epoch)
            assertEq(veMoca.totalSupplyAt(currentEpochStart), beforeState.globalState.totalSupplyAt, "TotalSupplyAt for currentEpoch unchanged");

        // ============ 7. Tokens State (No transfers) ============

            assertEq(uint128(lockAfter.owner.balance), beforeState.tokensState.userMoca, "User MOCA unchanged");
            assertEq(uint128(esMoca.balanceOf(lockAfter.owner)), beforeState.tokensState.userEsMoca, "User esMOCA unchanged");
            assertEq(uint128(address(veMoca).balance), beforeState.tokensState.contractMoca, "Contract MOCA unchanged");
            assertEq(uint128(esMoca.balanceOf(address(veMoca))), beforeState.tokensState.contractEsMoca, "Contract esMOCA unchanged");
    }

    // Verifies State: switchDelegate(newDelegate) -> user + oldDelegate + user-oldDelegate pair + newDelegate + user-newDelegate pair
    function verifySwitchDelegate(UnifiedStateSnapshot memory beforeState, address newDelegate) internal {
        // Get lock info from beforeState
        DataTypes.Lock memory lockBefore = beforeState.lockState.lock;
        bytes32 lockId = beforeState.lockState.lockId;
        address owner = lockBefore.owner;
        address oldDelegate = lockBefore.delegate;
        uint128 expiry = lockBefore.expiry;
        
        // Calculate lock veBalance using helper
        DataTypes.VeBalance memory lockVeBalance = convertToVeBalance(lockBefore);
        uint128 lockSlope = lockVeBalance.slope;
        uint128 lockBias = lockVeBalance.bias;

        // Epoch timing
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 epoch = getCurrentEpochNumber();

        // ============ 1. Lock State ============

            DataTypes.Lock memory lockAfter = getLock(lockId);
            assertEq(lockAfter.delegate, newDelegate, "Lock delegate switched");
            assertEq(lockAfter.owner, owner, "Lock owner unchanged");
            assertEq(lockAfter.moca, lockBefore.moca, "Lock moca unchanged");
            assertEq(lockAfter.esMoca, lockBefore.esMoca, "Lock esMoca unchanged");
            assertEq(lockAfter.expiry, expiry, "Lock expiry unchanged");
            assertFalse(lockAfter.isUnlocked, "Lock not unlocked");

        // ============ 1.1 Lock Voting Power (UNCHANGED) ============

            uint128 lockVPNow = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
            uint128 lockVPAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, getCurrentEpochEnd());
            assertEq(lockVPNow, beforeState.lockState.lockCurrentVotingPower, "Lock VP current unchanged");
            assertEq(lockVPAtEpochEnd, beforeState.lockState.lockVotingPowerAtEpochEnd, "Lock VP at epoch end unchanged");
    
        // ============ 2.Delegate Registration ============

            // if delegation txn is successful, this check is obsolete; but kept for redundancy
            assertTrue(veMoca.isRegisteredDelegate(newDelegate), "New delegate must be registered");

        // ============ 2.1 Delegation Action Counter ============

            // lock's action counter incremented by 1 for the current epoch
            uint128 actionCountAfter = veMoca.numOfDelegateActionsPerEpoch(lockId, currentEpochStart);
            assertEq(actionCountAfter, beforeState.lockState.numOfDelegateActionsThisEpoch + 1, "Action counter incremented");
            
        // ============ 2.2 Timestamp Updates ============
            
            // all timestamps updated to currentEpochStart: global, user, oldDelegate, newDelegate, oldPair, newPair
            assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdated");
            assertEq(veMoca.userLastUpdatedTimestamp(owner), currentEpochStart, "User lastUpdated");
            assertEq(veMoca.delegateLastUpdatedTimestamp(oldDelegate), currentEpochStart, "Old delegate lastUpdated");
            assertEq(veMoca.delegateLastUpdatedTimestamp(newDelegate), currentEpochStart, "New delegate lastUpdated");
            assertEq(veMoca.userDelegatedPairLastUpdatedTimestamp(owner, oldDelegate), currentEpochStart, "Old pair lastUpdated");
            assertEq(veMoca.userDelegatedPairLastUpdatedTimestamp(owner, newDelegate), currentEpochStart, "New pair lastUpdated");

        // ============ 3. Old Delegate State (Subtraction) ============
            
            // delegateSlopeChanges[expiry]: decreases by lockSlope
            assertEq(veMoca.delegateSlopeChanges(oldDelegate, expiry), beforeState.oldDelegateState.delegateSlopeChange - lockSlope, "Old delegate slopeChange decreased");
        
            // delegatePendingDeltas[nextEpoch]: subtraction booked
            (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) = veMoca.delegatePendingDeltas(oldDelegate, nextEpochStart);
            
            assertTrue(hasSub, "Old delegate pending subtraction");
            assertEq(subtractions.bias, beforeState.oldDelegateState.delegatePendingDelta.subtractions.bias + lockBias, "Old delegate pending sub bias");
            assertEq(subtractions.slope, beforeState.oldDelegateState.delegatePendingDelta.subtractions.slope + lockSlope, "Old delegate pending sub slope");
            
            // Old delegate VP unchanged in current epoch (pending deltas apply next epoch)
            assertEq(veMoca.balanceOfAt(oldDelegate, uint128(block.timestamp), true), beforeState.oldDelegateState.delegateCurrentVotingPower, "Old delegate VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(oldDelegate, epoch, true), beforeState.oldDelegateState.delegateVotingPowerAtEpochEnd, "Old delegate VP at epoch end unchanged");

        // ============ 4. New Delegate State (Addition) ============
            
            // delegateSlopeChanges[expiry]: increases by lockSlope
            assertEq(veMoca.delegateSlopeChanges(newDelegate, expiry), beforeState.targetDelegateState.delegateSlopeChange + lockSlope, "New delegate slopeChange increased");
            
            // delegatePendingDeltas[nextEpoch]: addition booked
            (hasAdd, hasSub, additions, subtractions) = veMoca.delegatePendingDeltas(newDelegate, nextEpochStart);
            
            assertTrue(hasAdd, "New delegate pending addition");
            assertEq(additions.bias, beforeState.targetDelegateState.delegatePendingDelta.additions.bias + lockBias, "New delegate pending add bias");
            assertEq(additions.slope, beforeState.targetDelegateState.delegatePendingDelta.additions.slope + lockSlope, "New delegate pending add slope");
            
            // New delegate VP unchanged in current epoch (pending deltas apply next epoch)
            assertEq(veMoca.balanceOfAt(newDelegate, uint128(block.timestamp), true), beforeState.targetDelegateState.delegateCurrentVotingPower, "New delegate VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(newDelegate, epoch, true), beforeState.targetDelegateState.delegateVotingPowerAtEpochEnd, "New delegate VP at epoch end unchanged");

        // ============ 5. Old Pair State (Subtraction) ============
           
            // userDelegatedSlopeChanges[expiry]: decreases by lockSlope [shifted away from owner to oldDelegate]
            assertEq(veMoca.userDelegatedSlopeChanges(owner, oldDelegate, expiry), beforeState.oldPairState.userDelegatedSlopeChange - lockSlope, "Old pair slopeChange decreased");
            
            // userPendingDeltasForDelegate[nextEpoch]: subtraction booked
            (hasAdd, hasSub, additions, subtractions) = veMoca.userPendingDeltasForDelegate(owner, oldDelegate, nextEpochStart);
            
            assertTrue(hasSub, "Old pair pending subtraction");
            assertEq(subtractions.bias, beforeState.oldPairState.pairPendingDelta.subtractions.bias + lockBias, "Old pair pending sub bias");
            assertEq(subtractions.slope, beforeState.oldPairState.pairPendingDelta.subtractions.slope + lockSlope, "Old pair pending sub slope");
            
            // Verify Old Pair History (No immediate changes - therefore no changes to current VP)
            {
                (uint128 b, uint128 s) = veMoca.delegatedAggregationHistory(owner, oldDelegate, currentEpochStart);
                assertEq(b, beforeState.oldPairState.delegatedAggregationHistory.bias, "Storage: Old Pair history bias unchanged");
                assertEq(s, beforeState.oldPairState.delegatedAggregationHistory.slope, "Storage: Old Pair history slope unchanged");
            }

            // Old pair VP at epoch end unchanged
            assertEq(veMoca.getSpecificDelegatedBalanceAtEpochEnd(owner, oldDelegate, epoch), beforeState.oldPairState.userDelegatedVotingPowerAtEpochEnd, "Old pair VP at epoch end unchanged");

        // ============ 6. New Pair State (Addition) ============

            // userDelegatedSlopeChanges[expiry]: increases by lockSlope
            assertEq(veMoca.userDelegatedSlopeChanges(owner, newDelegate, expiry), beforeState.targetPairState.userDelegatedSlopeChange + lockSlope, "New pair slopeChange increased");
        
            // userPendingDeltasForDelegate[nextEpoch]: addition booked
            (hasAdd, hasSub, additions, subtractions) = veMoca.userPendingDeltasForDelegate(owner, newDelegate, nextEpochStart);
            
            assertTrue(hasAdd, "New pair pending addition");
            assertEq(additions.bias, beforeState.targetPairState.pairPendingDelta.additions.bias + lockBias, "New pair pending add bias");
            assertEq(additions.slope, beforeState.targetPairState.pairPendingDelta.additions.slope + lockSlope, "New pair pending add slope");
            
            // Verify New Pair History (No immediate changes - therefore no changes to current VP)
            {
                (uint128 b, uint128 s) = veMoca.delegatedAggregationHistory(owner, newDelegate, currentEpochStart);
                assertEq(b, beforeState.targetPairState.delegatedAggregationHistory.bias, "Storage: New Pair history bias unchanged");
                assertEq(s, beforeState.targetPairState.delegatedAggregationHistory.slope, "Storage: New Pair history slope unchanged");
            }

            // New pair VP at epoch end unchanged
            assertEq(veMoca.getSpecificDelegatedBalanceAtEpochEnd(owner, newDelegate, epoch), beforeState.targetPairState.userDelegatedVotingPowerAtEpochEnd, "New pair VP at epoch end unchanged");

        // ============ 7. User State (Unchanged - switch doesn't affect user's own VP) ============

            assertEq(veMoca.userSlopeChanges(owner, expiry), beforeState.userState.userSlopeChange, "User slopeChange unchanged");
            assertEq(veMoca.balanceOfAt(owner, uint128(block.timestamp), false), beforeState.userState.userCurrentVotingPower, "User VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(owner, epoch, false), beforeState.userState.userVotingPowerAtEpochEnd, "User VP at epoch end unchanged");

        // ============ 8. Global State (Invariants) ============

            (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
            assertEq(globalBias, beforeState.globalState.veGlobal.bias, "Global bias unchanged");
            assertEq(globalSlope, beforeState.globalState.veGlobal.slope, "Global slope unchanged");
            assertEq(veMoca.slopeChanges(expiry), beforeState.globalState.slopeChange, "Global slopeChange unchanged");
            assertEq(veMoca.totalSupplyAtTimestamp(uint128(block.timestamp)), beforeState.globalState.totalSupplyAtTimestamp, "Total supply unchanged");

        // ============ 8.1) totalSupplyAt(currentEpochStart) unchanged (delegation is internal reallocation) ====

            // Verify totalSupplyAt(currentEpochStart) unchanged: it is only updated in the new epoch for the current epoch
            assertEq(veMoca.totalSupplyAt(currentEpochStart), beforeState.globalState.totalSupplyAt, "TotalSupplyAt epoch unchanged");

        // ============ 9. Tokens State (No transfers) ============

            assertEq(uint128(owner.balance), beforeState.tokensState.userMoca, "User MOCA unchanged");
            assertEq(uint128(esMoca.balanceOf(owner)), beforeState.tokensState.userEsMoca, "User esMOCA unchanged");
            assertEq(uint128(address(veMoca).balance), beforeState.tokensState.contractMoca, "Contract MOCA unchanged");
            assertEq(uint128(esMoca.balanceOf(address(veMoca))), beforeState.tokensState.contractEsMoca, "Contract esMOCA unchanged");
    }

    // Verifies State: undelegateLock() -> user + oldDelegate + user-oldDelegate pair
    function verifyUndelegateLock(UnifiedStateSnapshot memory beforeState) internal {
        // Get lock info from beforeState
        DataTypes.Lock memory lockBefore = beforeState.lockState.lock;
        bytes32 lockId = beforeState.lockState.lockId;
        address owner = lockBefore.owner;
        address oldDelegate = lockBefore.delegate;
        uint128 expiry = lockBefore.expiry;
        
        // Calculate lock veBalance using helper
        DataTypes.VeBalance memory lockVeBalance = convertToVeBalance(lockBefore);
        uint128 lockSlope = lockVeBalance.slope;
        uint128 lockBias = lockVeBalance.bias;

        // Epoch timing
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;
        uint128 epoch = getCurrentEpochNumber();

        // ============ 1. Lock State ============

            DataTypes.Lock memory lockAfter = getLock(lockId);
            assertEq(lockAfter.delegate, address(0), "Lock delegate cleared");
            assertEq(lockAfter.owner, owner, "Lock owner unchanged");
            assertEq(lockAfter.moca, lockBefore.moca, "Lock moca unchanged");
            assertEq(lockAfter.esMoca, lockBefore.esMoca, "Lock esMoca unchanged");
            assertEq(lockAfter.expiry, expiry, "Lock expiry unchanged");
            assertFalse(lockAfter.isUnlocked, "Lock not unlocked");
        // ============ 1.1 Lock Voting Power (UNCHANGED) ============
            uint128 lockVPNow = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
            uint128 lockVPAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, getCurrentEpochEnd());
            assertEq(lockVPNow, beforeState.lockState.lockCurrentVotingPower, "Lock VP current unchanged");
            assertEq(lockVPAtEpochEnd, beforeState.lockState.lockVotingPowerAtEpochEnd, "Lock VP at epoch end unchanged");
        // ============ 2. Delegation Action Counter ============
            uint128 actionCountAfter = veMoca.numOfDelegateActionsPerEpoch(lockId, currentEpochStart);
            assertEq(actionCountAfter, beforeState.lockState.numOfDelegateActionsThisEpoch + 1, "Action counter incremented");

        // ============ 2.1) Timestamp Updates ============
            
            // all timestamps updated to currentEpochStart: global, user, oldDelegate, oldPair
            assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdated");
            assertEq(veMoca.userLastUpdatedTimestamp(owner), currentEpochStart, "User lastUpdated");
            assertEq(veMoca.delegateLastUpdatedTimestamp(oldDelegate), currentEpochStart, "Old delegate lastUpdated");
            assertEq(veMoca.userDelegatedPairLastUpdatedTimestamp(owner, oldDelegate), currentEpochStart, "Old pair lastUpdated");

        // ============ 3. Old Delegate State (Subtraction) ============

            // delegateSlopeChanges[expiry]: decreases by lockSlope
            assertEq(veMoca.delegateSlopeChanges(oldDelegate, expiry), beforeState.oldDelegateState.delegateSlopeChange - lockSlope, "Delegate slopeChange decreased");
        
            // delegatePendingDeltas[nextEpoch]: subtraction booked
            (bool hasAdd, bool hasSub, DataTypes.VeBalance memory additions, DataTypes.VeBalance memory subtractions) = veMoca.delegatePendingDeltas(oldDelegate, nextEpochStart);
            
            assertTrue(hasSub, "Delegate pending subtraction");
            assertEq(subtractions.bias, beforeState.oldDelegateState.delegatePendingDelta.subtractions.bias + lockBias, "Delegate pending sub bias");
            assertEq(subtractions.slope, beforeState.oldDelegateState.delegatePendingDelta.subtractions.slope + lockSlope, "Delegate pending sub slope");
            
            // Delegate VP unchanged in current epoch (pending deltas apply next epoch)
            assertEq(veMoca.balanceOfAt(oldDelegate, uint128(block.timestamp), true), beforeState.oldDelegateState.delegateCurrentVotingPower, "Delegate VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(oldDelegate, epoch, true), beforeState.oldDelegateState.delegateVotingPowerAtEpochEnd, "Delegate VP at epoch end unchanged");

        // ============ 4. User State (Addition) ============

            // userSlopeChanges[expiry]: increases by lockSlope
            assertEq(veMoca.userSlopeChanges(owner, expiry), beforeState.userState.userSlopeChange + lockSlope, "User slopeChange increased");
            
            // userPendingDeltas[nextEpoch]: addition booked
            (hasAdd, hasSub, additions, subtractions) = veMoca.userPendingDeltas(owner, nextEpochStart);
            
            assertTrue(hasAdd, "User pending addition");
            assertEq(additions.bias, beforeState.userState.userPendingDelta.additions.bias + lockBias, "User pending add bias");
            assertEq(additions.slope, beforeState.userState.userPendingDelta.additions.slope + lockSlope, "User pending add slope");
            
            // User VP unchanged in current epoch (pending deltas apply next epoch)
            assertEq(veMoca.balanceOfAt(owner, uint128(block.timestamp), false), beforeState.userState.userCurrentVotingPower, "User VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(owner, epoch, false), beforeState.userState.userVotingPowerAtEpochEnd, "User VP at epoch end unchanged");

        // ============ 5. Old Pair State (Subtraction) ============

            // userDelegatedSlopeChanges[expiry]: decreases by lockSlope
            assertEq(veMoca.userDelegatedSlopeChanges(owner, oldDelegate, expiry), beforeState.oldPairState.userDelegatedSlopeChange - lockSlope, "Pair slopeChange decreased");
            
            // userPendingDeltasForDelegate[nextEpoch]: subtraction booked
            (hasAdd, hasSub, additions, subtractions) = veMoca.userPendingDeltasForDelegate(owner, oldDelegate, nextEpochStart);
            
            assertTrue(hasSub, "Pair pending subtraction");
            assertEq(subtractions.bias, beforeState.oldPairState.pairPendingDelta.subtractions.bias + lockBias, "Pair pending sub bias");
            assertEq(subtractions.slope, beforeState.oldPairState.pairPendingDelta.subtractions.slope + lockSlope, "Pair pending sub slope");
            
            // Verify Old Pair History (No immediate changes) [therefore no changes to current VP]
            {
                (uint128 b, uint128 s) = veMoca.delegatedAggregationHistory(owner, oldDelegate, currentEpochStart);
                assertEq(b, beforeState.oldPairState.delegatedAggregationHistory.bias, "Storage: Old Pair history bias unchanged");
                assertEq(s, beforeState.oldPairState.delegatedAggregationHistory.slope, "Storage: Old Pair history slope unchanged");
            }

            // Pair VP at epoch end unchanged
            assertEq(veMoca.getSpecificDelegatedBalanceAtEpochEnd(owner, oldDelegate, epoch), beforeState.oldPairState.userDelegatedVotingPowerAtEpochEnd, "Pair VP at epoch end unchanged");

        // ============ 6. Global State (Invariants) ============
            
            // verify global state unchanged: bias, slope, slopeChanges, totalSupplyAtTimestamp
            (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
            assertEq(globalBias, beforeState.globalState.veGlobal.bias, "Global bias unchanged");
            assertEq(globalSlope, beforeState.globalState.veGlobal.slope, "Global slope unchanged");
            assertEq(veMoca.slopeChanges(expiry), beforeState.globalState.slopeChange, "Global slopeChange unchanged");
            assertEq(veMoca.totalSupplyAtTimestamp(uint128(block.timestamp)), beforeState.globalState.totalSupplyAtTimestamp, "Total supply unchanged");

        // ============ 6.1) totalSupplyAt(currentEpochStart) unchanged (delegation is internal reallocation) ============
            
            // Verify totalSupplyAt(currentEpochStart) unchanged: it is only updated in the new epoch for the current epoch
            assertEq(veMoca.totalSupplyAt(currentEpochStart), beforeState.globalState.totalSupplyAt, "TotalSupplyAt epoch unchanged");

        // ============ 7. Tokens State (No transfers) ============

            // verify tokens state unchanged: userMoca, userEsMoca, contractMoca, contractEsMoca
            assertEq(uint128(owner.balance), beforeState.tokensState.userMoca, "User MOCA unchanged");
            assertEq(uint128(esMoca.balanceOf(owner)), beforeState.tokensState.userEsMoca, "User esMOCA unchanged");
            assertEq(uint128(address(veMoca).balance), beforeState.tokensState.contractMoca, "Contract MOCA unchanged");
            assertEq(uint128(esMoca.balanceOf(address(veMoca))), beforeState.tokensState.contractEsMoca, "Contract esMOCA unchanged");
    }
    

    // Verifies State: createLock() -> user + global + lock
    function verifyCreateLock(
        UnifiedStateSnapshot memory beforeState, 
        address user, bytes32 lockId, uint128 mocaAmt, uint128 esMocaAmt, uint128 expiry
    ) internal {
        
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Expected Deltas: slope, bias
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        // ============ 1. Tokens ============

            assertEq(user.balance, beforeState.tokensState.userMoca - mocaAmt, "User MOCA must be decremented");
            assertEq(esMoca.balanceOf(user), beforeState.tokensState.userEsMoca - esMocaAmt, "User esMOCA must be decremented");
            assertEq(address(veMoca).balance, beforeState.tokensState.contractMoca + mocaAmt, "Contract MOCA must be incremented");
            assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokensState.contractEsMoca + esMocaAmt, "Contract esMOCA must be incremented");

        // ============ 2. Global State ============
            {
                (uint128 bias, uint128 slope) = veMoca.veGlobal();
                assertEq(bias, beforeState.globalState.veGlobal.bias + expectedBias, "veGlobal bias must be incremented");
                assertEq(slope, beforeState.globalState.veGlobal.slope + expectedSlope, "veGlobal slope must be incremented");
            }
            assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.globalState.TOTAL_LOCKED_MOCA + mocaAmt, "Total Locked MOCA must be incremented");
            assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.globalState.TOTAL_LOCKED_ESMOCA + esMocaAmt, "Total Locked esMOCA must be incremented");
            assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be updated");

        // ============ 3. Global Mappings ============
            assertEq(veMoca.slopeChanges(expiry), beforeState.globalState.slopeChange + expectedSlope, "Slope Changes must be incremented");
        
        // ============ 4. User State ============
            {
                (uint128 bias, uint128 slope) = veMoca.userHistory(user, currentEpochStart);
                assertEq(bias, beforeState.userState.userHistory.bias + expectedBias, "userHistory Bias must be incremented");
                assertEq(slope, beforeState.userState.userHistory.slope + expectedSlope, "userHistory Slope must be incremented");
            }
            assertEq(veMoca.userSlopeChanges(user, expiry), beforeState.userState.userSlopeChange + expectedSlope, "userSlopeChanges must be incremented");
            assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be updated");

        // ============ 5. Lock State + 6. Lock History + 6.1 Lock Voting Power + 7. View Functions ============
            {
                DataTypes.Lock memory lock = getLock(lockId);
                assertEq(lock.owner, user, "Lock Owner");
                assertEq(lock.delegate, address(0), "Lock Delegate must be address(0)");
                assertEq(lock.moca, mocaAmt, "Lock Moca");
                assertEq(lock.esMoca, esMocaAmt, "Lock esMoca");
                assertEq(lock.expiry, expiry, "Lock Expiry");
                assertFalse(lock.isUnlocked, "Lock must not be unlocked");

                // 6. Lock History
                uint256 len = veMoca.getLockHistoryLength(lockId);
                assertEq(len, 1, "Lock History Length must be 1 for new lock");
                
                DataTypes.Checkpoint memory cp = getLockHistory(lockId, 0);
                assertEq(cp.veBalance.bias, expectedBias, "Lock History: Checkpoint Bias");
                assertEq(cp.veBalance.slope, expectedSlope, "Lock History: Checkpoint Slope");
                assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp");

                // 6.1 Lock Voting Power
                uint128 lockVPNow = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
                uint128 expectedLockVPNow = getValueAt(convertToVeBalance(lock), uint128(block.timestamp));
                assertEq(lockVPNow, expectedLockVPNow, "Lock VP current matches expected");

                uint128 epochEnd = getEpochEndTimestamp(getCurrentEpochNumber());
                uint128 lockVPAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, epochEnd);
                uint128 expectedLockVPAtEpochEnd = expiry <= epochEnd ? 0 : getValueAt(convertToVeBalance(lock), epochEnd);
                assertEq(lockVPAtEpochEnd, expectedLockVPAtEpochEnd, "Lock VP at epoch end matches expected");

                // 7. View Functions
                _verifyUserVotingPower(user, lock, beforeState.userState, beforeState.lockState, true);
            }
    }

    // used in verifyCreateLock() for non-delegated locks
    function _verifyUserVotingPower(
        address user, 
        DataTypes.Lock memory newLock,
        UserStateSnapshot memory beforeUser,
        LockStateSnapshot memory beforeLock,
        bool isNewLock
    ) internal {
        
        // current timestamp
        uint128 currentTimestamp = uint128(block.timestamp);

        // verify user voting power: current, epoch end
        uint128 userVotingPower = veMoca.balanceOfAt(user, currentTimestamp, false);
        uint128 newLockVotingPower = getValueAt(convertToVeBalance(newLock), currentTimestamp);

        // Calculate expected VP at epoch end
        uint128 epoch = getCurrentEpochNumber();
        uint128 epochEnd = getEpochEndTimestamp(epoch);
        uint128 userVPAtEpochEnd = veMoca.balanceAtEpochEnd(user, epoch, false);
        uint128 newLockVPAtEpochEnd = newLock.expiry <= epochEnd ? 0 : getValueAt(convertToVeBalance(newLock), epochEnd);

        if (isNewLock) {
            // createLock: user VP increases by full lock VP
            assertEq(userVotingPower, beforeUser.userCurrentVotingPower + newLockVotingPower, "Voting Power must be incremented (new lock)");
            // check VP at epoch end
            assertEq(userVPAtEpochEnd, beforeUser.userVotingPowerAtEpochEnd + newLockVPAtEpochEnd, "VP at EpochEnd must be incremented (new lock)");

        } else {
            // increaseAmount/increaseDuration: user VP increases by lock VP delta
            uint128 oldLockVotingPower = getValueAt(convertToVeBalance(beforeLock.lock), currentTimestamp);
            uint128 lockVPDelta = newLockVotingPower - oldLockVotingPower;
            assertEq(userVotingPower, beforeUser.userCurrentVotingPower + lockVPDelta, "Voting Power must be incremented (modify lock)");

            // Calculate OLD lock VP at epoch end
            uint128 oldLockVPAtEpochEnd = beforeLock.lock.expiry <= epochEnd ? 0 : getValueAt(convertToVeBalance(beforeLock.lock), epochEnd);
            uint128 lockVPAtEpochEndDelta = newLockVPAtEpochEnd - oldLockVPAtEpochEnd;
            assertEq(userVPAtEpochEnd, beforeUser.userVotingPowerAtEpochEnd + lockVPAtEpochEndDelta, "VP at EpochEnd must be incremented (modify lock)");
        }
    }

    function _verifyLockVotingPower(
        DataTypes.Lock memory lock, 
        LockStateSnapshot memory beforeLock, 
        bool isIncreaseAmount
    ) internal view {
        uint128 currentTimestamp = uint128(block.timestamp);
        bytes32 lockId = beforeLock.lockId;

        // Skip if lock is expired
        if (lock.expiry <= currentTimestamp) {
            assertEq(getLockVotingPowerAt(lockId, currentTimestamp), 0, "Expired lock should have 0 VP");
            return;
        }
        
        // 1. Calculate before voting power from saved state (only if still alive)
        uint128 beforeVotingPower;
        if (beforeLock.lock.expiry > currentTimestamp) {
            beforeVotingPower = getValueAt(convertToVeBalance(beforeLock.lock), currentTimestamp);
        }
        
        // 2. Calculate expected voting power from NEW lock state
        uint128 expectedVotingPower = getValueAt(convertToVeBalance(lock), currentTimestamp);
        
        // 3. Validate based on operation type
        uint128 beforeTotalAmount = beforeLock.lock.moca + beforeLock.lock.esMoca;
        uint128 newTotalAmount = lock.moca + lock.esMoca;
        
        if (isIncreaseAmount) {
            assertEq(lock.expiry, beforeLock.lock.expiry, "Expiry should be unchanged for increaseAmount");
            assertGt(newTotalAmount, beforeTotalAmount, "Total amount must increase");
        } else {
            assertEq(newTotalAmount, beforeTotalAmount, "Amounts should be unchanged for increaseDuration");
            assertGt(lock.expiry, beforeLock.lock.expiry, "Expiry must increase");
        }
        
        // 4. Get actual voting power from contract
        uint128 actualVotingPower = getLockVotingPowerAt(lockId, currentTimestamp);
        
        // 5. Verify actual matches expected
        assertEq(actualVotingPower, expectedVotingPower, "Actual VP must match expected");
        
        // 6. Verify voting power increased
        uint128 deltaExpected = expectedVotingPower - beforeVotingPower;
        uint128 deltaActual   = actualVotingPower  - beforeVotingPower;
        assertEq(deltaActual, deltaExpected, "Voting-power delta mismatch");
    }

// ================= DELEGATION TAKES EFFECT VERIFY FUNCTIONS =================

    /**
     * @notice Verifies state after delegation takes effect (E1->E2 transition via cronjob)
     * @dev Checks that VP is properly transferred from user to delegate after pending deltas are applied
     * @param beforeState State captured AFTER delegation was made but BEFORE it took effect (in epoch N)
     * @param afterState State captured AFTER delegation took effect (in epoch N+1 after cronjob)
     * @param lockId The lock ID to get current voting power
     */
    function verifyDelegationTakesEffect(
        UnifiedStateSnapshot memory beforeState,
        UnifiedStateSnapshot memory afterState,
        bytes32 lockId
    ) internal {
        // Get lock's veBalance at current timestamp (after delegation took effect)
        uint128 lockVotingPowerNow = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
        
        // Calculate lock's veBalance from beforeState (bias/slope at time of delegation)
        DataTypes.VeBalance memory lockVeBalance = convertToVeBalance(beforeState.lockState.lock);

        // ============ 1. User State Changes ============
        
            // User history bias/slope should decrease by exact lock's bias/slope
            assertEq(
                afterState.userState.userHistory.bias,
                beforeState.userState.userHistory.bias - lockVeBalance.bias,
                "User history bias decreased by lock bias"
            );
            assertEq(
                afterState.userState.userHistory.slope,
                beforeState.userState.userHistory.slope - lockVeBalance.slope,
                "User history slope decreased by lock slope"
            );
            
            // User VP at current timestamp should equal calculated VP from afterState history
            uint128 expectedUserVP = getValueAt(afterState.userState.userHistory, uint128(block.timestamp));
            assertEq(
                afterState.userState.userCurrentVotingPower,
                expectedUserVP,
                "User VP matches calculated from history"
            );
            
            // User pending deltas should be cleared (subtraction was processed)
            assertFalse(afterState.userState.userPendingDelta.hasSubtraction, "User pending sub cleared");

        // ============ 2. Delegate State Changes ============

            // Delegate history bias/slope should increase by exact lock's bias/slope
            assertEq(
                afterState.targetDelegateState.delegateHistory.bias,
                beforeState.targetDelegateState.delegateHistory.bias + lockVeBalance.bias,
                "Delegate history bias increased by lock bias"
            );
            assertEq(
                afterState.targetDelegateState.delegateHistory.slope,
                beforeState.targetDelegateState.delegateHistory.slope + lockVeBalance.slope,
                "Delegate history slope increased by lock slope"
            );
            
            // Delegate VP at current timestamp should equal calculated VP from afterState history
            uint128 expectedDelegateVP = getValueAt(afterState.targetDelegateState.delegateHistory, uint128(block.timestamp));
            assertEq(
                afterState.targetDelegateState.delegateCurrentVotingPower,
                expectedDelegateVP,
                "Delegate VP matches calculated from history"
            );
            
            // Delegate pending deltas should be cleared (addition was processed)
            assertFalse(afterState.targetDelegateState.delegatePendingDelta.hasAddition, "Delegate pending add cleared");

        // ============ 3. User-Delegate Pair State Changes ============

            // Pair history bias/slope should increase by exact lock's bias/slope
            assertEq(
                afterState.targetPairState.delegatedAggregationHistory.bias,
                beforeState.targetPairState.delegatedAggregationHistory.bias + lockVeBalance.bias,
                "Pair history bias increased by lock bias"
            );
            assertEq(
                afterState.targetPairState.delegatedAggregationHistory.slope,
                beforeState.targetPairState.delegatedAggregationHistory.slope + lockVeBalance.slope,
                "Pair history slope increased by lock slope"
            );
            
            // Pair VP at current timestamp should equal calculated VP from afterState history
            uint128 expectedPairVP = getValueAt(afterState.targetPairState.delegatedAggregationHistory, uint128(block.timestamp));
            assertEq(
                afterState.targetPairState.userDelegatedCurrentVotingPower,
                expectedPairVP,
                "Pair VP matches calculated from history"
            );
            
            // Pair pending deltas should be cleared (addition was processed)
            assertFalse(afterState.targetPairState.pairPendingDelta.hasAddition, "Pair pending add cleared");

        // ============ 4. Slope Changes Verification ============
        
        // NOTE: Slope changes are moved during delegationAction(), so beforeState already has them moved. 
        // verify slope changes at expiry are unchanged

            // User slope changes at expiry are unchanged [NOTE: slope changes are moved during delegationAction()]
            assertEq(
                afterState.userState.userSlopeChange,
                beforeState.userState.userSlopeChange,
                "User slope change unchanged"
            );
            
            // Delegate slope changes at expiry are increased by exact lock's slope [NOTE: slope changes are moved during delegationAction()]   
            assertEq(
                afterState.targetDelegateState.delegateSlopeChange,
                beforeState.targetDelegateState.delegateSlopeChange,
                "Delegate slope change unchanged"
            );

        // ============ 5. Global State (Should be unchanged) ============

            // Global VP should be unchanged (delegation is internal redistribution)
            assertEq(
                afterState.globalState.veGlobal.bias,
                beforeState.globalState.veGlobal.bias,
                "Global bias unchanged by delegation taking effect"
            );
            assertEq(
                afterState.globalState.veGlobal.slope,
                beforeState.globalState.veGlobal.slope,
                "Global slope unchanged by delegation taking effect"
            );

        // ============ 6. VP Conservation Check ============
            
            // Verify VP conservation: what user lost, delegate gained
            // Calculate VP delta using history at epoch boundary
            uint128 currentEpochStart = getCurrentEpochStart();
            
            uint128 userVPAtEpochStart_Before = getValueAt(beforeState.userState.userHistory, currentEpochStart);
            uint128 userVPAtEpochStart_After = getValueAt(afterState.userState.userHistory, currentEpochStart);
            uint128 userVPLost = userVPAtEpochStart_Before - userVPAtEpochStart_After;
            
            uint128 delegateVPAtEpochStart_Before = getValueAt(beforeState.targetDelegateState.delegateHistory, currentEpochStart);
            uint128 delegateVPAtEpochStart_After = getValueAt(afterState.targetDelegateState.delegateHistory, currentEpochStart);
            uint128 delegateVPGained = delegateVPAtEpochStart_After - delegateVPAtEpochStart_Before;
            
            // VP transferred should be exact
            assertEq(userVPLost, delegateVPGained, "VP lost by user equals VP gained by delegate");
            
            // This should equal lock's VP at epoch start
            uint128 lockVPAtEpochStart = getValueAt(lockVeBalance, currentEpochStart);
            assertEq(userVPLost, lockVPAtEpochStart, "VP transferred equals lock VP at epoch start");
    }


// ================= ACTIVE DELEGATION VERIFY FUNCTIONS =================

    /** For ACTIVE delegation (delegationEpoch <= currentEpochStart):
     * - currentAccount = delegate
     * - futureAccount = delegate  
     * - NO pending deltas are queued (same account)
     * - Delegate gets IMMEDIATE VP increase
     * - User state is UNCHANGED
     */

    // Verifies State: increaseAmount on DELEGATED lock -> tokens + global + delegate (immediate) + pair (immediate) + lock
    function verifyIncreaseAmountActiveDelegation(UnifiedStateSnapshot memory beforeState, uint128 mocaAmt, uint128 esMocaAmt) internal {
        // Extract sub-snapshots
        TokensSnapshot memory beforeTokens = beforeState.tokensState;
        GlobalStateSnapshot memory beforeGlobal = beforeState.globalState;
        UserStateSnapshot memory beforeUser = beforeState.userState;
        LockStateSnapshot memory beforeLock = beforeState.lockState;
        DelegateStateSnapshot memory beforeDelegate = beforeState.targetDelegateState;
        UserDelegatePairStateSnapshot memory beforePair = beforeState.targetPairState;

        // Derive from lock
        bytes32 lockId = beforeLock.lockId;
        uint128 expiry = beforeLock.lock.expiry;
        address user = beforeLock.lock.owner;
        address delegate = beforeLock.lock.delegate;
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 epoch = getCurrentEpochNumber();
        uint128 currentTimestamp = uint128(block.timestamp);

        // Calculate delta (new lock veBalance - old lock veBalance)
        // For increaseAmount: slope increases, bias increases
        uint128 oldLockSlope = (beforeLock.lock.moca + beforeLock.lock.esMoca) / MAX_LOCK_DURATION;
        uint128 newLockSlope = (beforeLock.lock.moca + mocaAmt + beforeLock.lock.esMoca + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 slopeDelta = newLockSlope - oldLockSlope;
        uint128 newLockBias = newLockSlope * expiry;
        uint128 biasDelta = slopeDelta * expiry;

        // Calculate VP Deltas: now & epoch end
        // VP Delta = slopeDelta * (expiry - timestamp)
        uint128 vpDeltaNow = slopeDelta * (expiry - currentTimestamp);
        
        uint128 epochEndTimestamp = getEpochEndTimestamp(epoch);
        // If expiry is before epoch end, delta is just whatever value it had (likely 0 if handled correctly elsewhere, but for valid locks expiry > currentEpochEnd)
        uint128 vpDeltaEpochEnd = expiry <= epochEndTimestamp ? 0 : slopeDelta * (expiry - epochEndTimestamp);


        // ============ 1. Tokens ============

            assertEq(user.balance, beforeTokens.userMoca - mocaAmt, "User MOCA decremented");
            assertEq(esMoca.balanceOf(user), beforeTokens.userEsMoca - esMocaAmt, "User esMOCA decremented");
            assertEq(address(veMoca).balance, beforeTokens.contractMoca + mocaAmt, "Contract MOCA incremented");
            assertEq(esMoca.balanceOf(address(veMoca)), beforeTokens.contractEsMoca + esMocaAmt, "Contract esMOCA incremented");

        // ============ 2. Global State (IMMEDIATE) ============

            (uint128 bias, uint128 slope) = veMoca.veGlobal();
            assertEq(bias, beforeGlobal.veGlobal.bias + biasDelta, "veGlobal bias incremented");
            assertEq(slope, beforeGlobal.veGlobal.slope + slopeDelta, "veGlobal slope incremented");
            
            assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeGlobal.TOTAL_LOCKED_MOCA + mocaAmt, "Total Locked MOCA incremented");
            assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeGlobal.TOTAL_LOCKED_ESMOCA + esMocaAmt, "Total Locked esMOCA incremented");
            
            assertEq(veMoca.slopeChanges(expiry), beforeGlobal.slopeChange + slopeDelta, "Global slopeChange incremented");
            assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdated");
            assertEq(veMoca.totalSupplyAtTimestamp(currentTimestamp), beforeGlobal.totalSupplyAtTimestamp + vpDeltaNow, "Total supply VP increased");

            // Verify totalSupplyAt(currentEpochStart) unchanged: it is only updated in the new epoch for the current epoch
            assertEq(veMoca.totalSupplyAt(currentEpochStart), beforeGlobal.totalSupplyAt, "TotalSupplyAt epoch unchanged");

        // ============ 3. User State (UNCHANGED) ==============

            (bias, slope) = veMoca.userHistory(user, currentEpochStart);
            assertEq(bias, beforeUser.userHistory.bias, "userHistory bias unchanged");
            assertEq(slope, beforeUser.userHistory.slope, "userHistory slope unchanged");
        
            assertEq(veMoca.userSlopeChanges(user, expiry), beforeUser.userSlopeChange, "userSlopeChange unchanged");
            assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "User lastUpdated");

        // ============ 3.1 User VP (UNCHANGED) ============

            assertEq(veMoca.balanceOfAt(user, currentTimestamp, false), beforeUser.userCurrentVotingPower, "User VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(user, epoch, false), beforeUser.userVotingPowerAtEpochEnd, "User VP at epoch end unchanged");

        // ============ 4. Delegate State (IMMEDIATE) ============

            (bias, slope) = veMoca.delegateHistory(delegate, currentEpochStart);
            assertEq(bias, beforeDelegate.delegateHistory.bias + biasDelta, "delegateHistory bias incremented");
            assertEq(slope, beforeDelegate.delegateHistory.slope + slopeDelta, "delegateHistory slope incremented");
        
            assertEq(veMoca.delegateSlopeChanges(delegate, expiry), beforeDelegate.delegateSlopeChange + slopeDelta, "delegateSlopeChange incremented");
            assertEq(veMoca.delegateLastUpdatedTimestamp(delegate), currentEpochStart, "Delegate lastUpdated");

        // ============ 4.1 Delegate VP ============

            assertEq(veMoca.balanceOfAt(delegate, currentTimestamp, true), beforeDelegate.delegateCurrentVotingPower + vpDeltaNow, "Delegate VP increased");
            assertEq(veMoca.balanceAtEpochEnd(delegate, epoch, true), beforeDelegate.delegateVotingPowerAtEpochEnd + vpDeltaEpochEnd, "Delegate VP at epoch end increased");

        // ============ 5. User-Delegate Pair State (IMMEDIATE) ============

            (bias, slope) = veMoca.delegatedAggregationHistory(user, delegate, currentEpochStart);
            assertEq(bias, beforePair.delegatedAggregationHistory.bias + biasDelta, "pairHistory bias incremented");
            assertEq(slope, beforePair.delegatedAggregationHistory.slope + slopeDelta, "pairHistory slope incremented");
            
            assertEq(veMoca.userDelegatedSlopeChanges(user, delegate, expiry), beforePair.userDelegatedSlopeChange + slopeDelta, "pairSlopeChange incremented");

            // Verify Pair Current VP - Should be INCREASED
            {
                DataTypes.VeBalance memory currentHistory = DataTypes.VeBalance(bias, slope);
                assertEq(getValueAt(currentHistory, currentTimestamp), beforePair.userDelegatedCurrentVotingPower + vpDeltaNow, "Pair VP current increased");
            }

            assertEq(veMoca.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, epoch), beforePair.userDelegatedVotingPowerAtEpochEnd + vpDeltaEpochEnd, "Pair VP at epoch end increased");
            assertEq(veMoca.userDelegatedPairLastUpdatedTimestamp(user, delegate), currentEpochStart, "Pair lastUpdated");     

        // ============ 6. Lock State ============

            DataTypes.Lock memory lock = getLock(lockId);
            assertEq(lock.moca, beforeLock.lock.moca + mocaAmt, "Lock moca incremented");
            assertEq(lock.esMoca, beforeLock.lock.esMoca + esMocaAmt, "Lock esMoca incremented");
            assertEq(lock.delegate, delegate, "Lock delegate unchanged");
            assertEq(lock.expiry, expiry, "Lock expiry unchanged");

        // ============ 7. Lock History ============
            uint256 len = veMoca.getLockHistoryLength(lockId);
            uint256 beforeLen = beforeLock.lockHistory.length;
            
            // Same epoch = overwrite existing checkpoint (length unchanged) | Different epoch = push new checkpoint (length +1)
            if (beforeLock.lockHistory[beforeLen - 1].lastUpdatedAt == currentEpochStart) {
                assertEq(len, beforeLen, "Lock History Length unchanged (same epoch)");
            } else {
                assertEq(len, beforeLen + 1, "Lock History Length incremented (new epoch)");
            }

            DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
            assertEq(cp.veBalance.bias, newLockBias, "Checkpoint bias");
            assertEq(cp.veBalance.slope, newLockSlope, "Checkpoint slope");
            assertEq(cp.lastUpdatedAt, currentEpochStart, "Checkpoint timestamp");
        
        // ============ 8. Lock VP ============
            // verify lock voting power increased
            uint128 lockVPNow = veMoca.getLockVotingPowerAt(lockId, currentTimestamp);
            assertGt(lockVPNow, beforeLock.lockCurrentVotingPower, "Lock VP current increased");
            
            uint128 epochEnd = getEpochEndTimestamp(epoch);
            uint128 lockVPAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, epochEnd);
            // Only check if lock is still active at epoch end
            if (expiry > epochEnd) {
                assertGt(lockVPAtEpochEnd, beforeLock.lockVotingPowerAtEpochEnd, "Lock VP at epoch end increased");
            }
            // verify lock voting power: current
            _verifyLockVotingPower(lock, beforeLock, true);  // true = increaseAmount
    }

    // Verifies State: increaseDuration on DELEGATED lock -> tokens (unchanged) + global + delegate (immediate) + pair (immediate) + lock
    function verifyIncreaseDurationActiveDelegation(UnifiedStateSnapshot memory beforeState, uint128 newExpiry) internal {
        // Setup essential deltas (kept at top level as they are used across blocks)
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 lockSlope = (beforeState.lockState.lock.moca + beforeState.lockState.lock.esMoca) / MAX_LOCK_DURATION;
        // biasDelta = slope * duration_increase
        uint128 biasDelta = lockSlope * (newExpiry - beforeState.lockState.lock.expiry);

        // ============ 1. Tokens (UNCHANGED) ============
        {
            address user = beforeState.lockState.lock.owner;
            assertEq(user.balance, beforeState.tokensState.userMoca, "User MOCA unchanged");
            assertEq(esMoca.balanceOf(user), beforeState.tokensState.userEsMoca, "User esMOCA unchanged");
            assertEq(address(veMoca).balance, beforeState.tokensState.contractMoca, "Contract MOCA unchanged");
            assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokensState.contractEsMoca, "Contract esMOCA unchanged");
        }

        // ============ 2. Global State (IMMEDIATE) ============
        {
            (uint128 bias, uint128 slope) = veMoca.veGlobal();
            assertEq(bias, beforeState.globalState.veGlobal.bias + biasDelta, "veGlobal bias incremented");
            assertEq(slope, beforeState.globalState.veGlobal.slope, "veGlobal slope unchanged");

            assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.globalState.TOTAL_LOCKED_MOCA, "Total Locked MOCA unchanged");
            assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.globalState.TOTAL_LOCKED_ESMOCA, "Total Locked esMOCA unchanged");

            // slopeChanges: old expiry decreases, new expiry increases
            assertEq(veMoca.slopeChanges(beforeState.lockState.lock.expiry), beforeState.globalState.slopeChange - lockSlope, "Global slopeChange at oldExpiry decreased");
            assertEq(veMoca.slopeChanges(newExpiry), beforeState.globalState.slopeChangeNewExpiry + lockSlope, "Global slopeChange at newExpiry increased");
            
            assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdated");
            assertEq(veMoca.totalSupplyAtTimestamp(uint128(block.timestamp)), beforeState.globalState.totalSupplyAtTimestamp + biasDelta, "Total supply VP increased");
        }

        // ============ 3. User State (UNCHANGED) ============
        {
            address user = beforeState.lockState.lock.owner;
            (uint128 bias, uint128 slope) = veMoca.userHistory(user, currentEpochStart);
            assertEq(bias, beforeState.userState.userHistory.bias, "userHistory bias unchanged");
            assertEq(slope, beforeState.userState.userHistory.slope, "userHistory slope unchanged");
            
            assertEq(veMoca.userSlopeChanges(user, beforeState.lockState.lock.expiry), beforeState.userState.userSlopeChange, "userSlopeChange at oldExpiry unchanged");
            assertEq(veMoca.userSlopeChanges(user, newExpiry), beforeState.userState.userSlopeChangeNewExpiry, "userSlopeChange at newExpiry unchanged");
            assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "User lastUpdated");

            // User VP (UNCHANGED)
            assertEq(veMoca.balanceOfAt(user, uint128(block.timestamp), false), beforeState.userState.userCurrentVotingPower, "User VP unchanged");
            assertEq(veMoca.balanceAtEpochEnd(user, getCurrentEpochNumber(), false), beforeState.userState.userVotingPowerAtEpochEnd, "User VP at epoch end unchanged");
        }

        // ============ 4. Delegate State (IMMEDIATE) ============
        {
            address delegate = beforeState.lockState.lock.delegate;
            (uint128 bias, uint128 slope) = veMoca.delegateHistory(delegate, currentEpochStart);
            assertEq(bias, beforeState.targetDelegateState.delegateHistory.bias + biasDelta, "delegateHistory bias incremented");
            assertEq(slope, beforeState.targetDelegateState.delegateHistory.slope, "delegateHistory slope unchanged");
        
            assertEq(veMoca.delegateSlopeChanges(delegate, beforeState.lockState.lock.expiry), beforeState.targetDelegateState.delegateSlopeChange - lockSlope, "delegateSlopeChange at oldExpiry decreased");
            assertEq(veMoca.delegateSlopeChanges(delegate, newExpiry), beforeState.targetDelegateState.delegateSlopeChangeNewExpiry + lockSlope, "delegateSlopeChange at newExpiry increased");
            assertEq(veMoca.delegateLastUpdatedTimestamp(delegate), currentEpochStart, "Delegate lastUpdated");
            
            // Delegate VP (INCREASED)
            assertEq(veMoca.balanceOfAt(delegate, uint128(block.timestamp), true), beforeState.targetDelegateState.delegateCurrentVotingPower + biasDelta, "Delegate VP increased");
            assertEq(veMoca.balanceAtEpochEnd(delegate, getCurrentEpochNumber(), true), beforeState.targetDelegateState.delegateVotingPowerAtEpochEnd + biasDelta, "Delegate VP at epoch end increased");
        }

        // ============ 5. User-Delegate Pair State (IMMEDIATE) ============
        {
            address user = beforeState.lockState.lock.owner;
            address delegate = beforeState.lockState.lock.delegate;
            
            (uint128 bias, uint128 slope) = veMoca.delegatedAggregationHistory(user, delegate, currentEpochStart);
            assertEq(bias, beforeState.targetPairState.delegatedAggregationHistory.bias + biasDelta, "pairHistory bias incremented");
            assertEq(slope, beforeState.targetPairState.delegatedAggregationHistory.slope, "pairHistory slope unchanged");
            
            assertEq(veMoca.userDelegatedSlopeChanges(user, delegate, beforeState.lockState.lock.expiry), beforeState.targetPairState.userDelegatedSlopeChange - lockSlope, "pairSlopeChange at oldExpiry decreased");
            assertEq(veMoca.userDelegatedSlopeChanges(user, delegate, newExpiry), beforeState.targetPairState.userDelegatedSlopeChangeNewExpiry + lockSlope, "pairSlopeChange at newExpiry increased");
            assertEq(veMoca.userDelegatedPairLastUpdatedTimestamp(user, delegate), currentEpochStart, "Pair lastUpdated");

            // Pair VP (INCREASED)
            DataTypes.VeBalance memory currentHistory = DataTypes.VeBalance(bias, slope);
            assertEq(getValueAt(currentHistory, uint128(block.timestamp)), beforeState.targetPairState.userDelegatedCurrentVotingPower + biasDelta, "Pair VP current increased");
            
            assertEq(veMoca.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, getCurrentEpochNumber()), beforeState.targetPairState.userDelegatedVotingPowerAtEpochEnd + biasDelta, "Pair VP at epoch end increased");
        }

        // ============ 6. Lock State ============
        {
            bytes32 lockId = beforeState.lockState.lockId;
            DataTypes.Lock memory lock = getLock(lockId);
            assertEq(lock.moca, beforeState.lockState.lock.moca, "Lock moca unchanged");
            assertEq(lock.esMoca, beforeState.lockState.lock.esMoca, "Lock esMoca unchanged");
            assertEq(lock.delegate, beforeState.lockState.lock.delegate, "Lock delegate unchanged");
            assertEq(lock.expiry, newExpiry, "Lock expiry updated");

            // Lock History
            uint256 len = veMoca.getLockHistoryLength(lockId);
            uint256 beforeLen = beforeState.lockState.lockHistory.length;
            
            if (beforeState.lockState.lockHistory[beforeLen - 1].lastUpdatedAt == currentEpochStart) {
                assertEq(len, beforeLen, "Lock History Length unchanged (same epoch)");
            } else {
                assertEq(len, beforeLen + 1, "Lock History Length incremented (new epoch)");
            }

            DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
            // newBias = lockSlope * newExpiry
            assertEq(cp.veBalance.bias, lockSlope * newExpiry, "Checkpoint bias"); 
            assertEq(cp.veBalance.slope, lockSlope, "Checkpoint slope unchanged");
            assertEq(cp.lastUpdatedAt, currentEpochStart, "Checkpoint timestamp");
        
            // Lock VP
            uint128 lockVPNow = veMoca.getLockVotingPowerAt(lockId, uint128(block.timestamp));
            assertGt(lockVPNow, beforeState.lockState.lockCurrentVotingPower, "Lock VP current increased");
            
            uint128 epochEnd = getEpochEndTimestamp(getCurrentEpochNumber());
            uint128 lockVPAtEpochEnd = veMoca.getLockVotingPowerAt(lockId, epochEnd);
            // If lock extends beyond epoch end, VP should be > 0 (and > before if before was 0 or less)
            if (newExpiry > epochEnd) {
                 // It's possible before VP was 0 if old expiry was <= epochEnd
                 // But now it should definitely have VP
                 assertGt(lockVPAtEpochEnd, 0, "Lock VP at epoch end > 0");
            }
            
            _verifyLockVotingPower(lock, beforeState.lockState, false);  // false = increaseDuration
        }
    }


// ================= PENDING DELEGATION VERIFY FUNCTIONS =================

    /** For PENDING delegation (delegationEpoch > currentEpochStart):
     * - currentAccount = owner (gets immediate VP increase)
     * - futureAccount = delegate (gets pending addition)
     * - Pending deltas ARE queued
     * - Owner gets IMMEDIATE VP increase
     * - Delegate state has pending addition queued
     */

    function verifyIncreaseAmountPendingDelegation(UnifiedStateSnapshot memory beforeState, uint128 mocaAmt, uint128 esMocaAmt) internal {
        // Derived values
        uint128 oldSlope = (beforeState.lockState.lock.moca + beforeState.lockState.lock.esMoca) / MAX_LOCK_DURATION;
        uint128 newSlope = (beforeState.lockState.lock.moca + mocaAmt + beforeState.lockState.lock.esMoca + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 slopeDelta = newSlope - oldSlope;
        uint128 biasDelta = slopeDelta * beforeState.lockState.lock.expiry;
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;

        // 1. Owner State (IMMEDIATE)
        // Owner is currentAccount, so they get immediate update
        {
            address owner = beforeState.lockState.lock.owner;
            (uint128 bias, uint128 slope) = veMoca.userHistory(owner, currentEpochStart);
            assertEq(bias, beforeState.userState.userHistory.bias + biasDelta, "Owner history bias increased");
            assertEq(slope, beforeState.userState.userHistory.slope + slopeDelta, "Owner history slope increased");
            
            // Check pending subtraction queued for owner (moving VP away next epoch)
            (, bool hasSub, , DataTypes.VeBalance memory subs) = veMoca.userPendingDeltas(owner, nextEpochStart);
            assertTrue(hasSub, "Owner has pending subtraction");
            // Note: accumulation of pending deltas is complex to verify exactly without tracking all prev deltas, 
            // but we can verify it exists.
        }

        // 2. Delegate State (PENDING)
        // Delegate is futureAccount, so they get PENDING update (NO immediate change)
        {
            address delegate = beforeState.lockState.lock.delegate;
            (uint128 bias, uint128 slope) = veMoca.delegateHistory(delegate, currentEpochStart);
            assertEq(bias, beforeState.targetDelegateState.delegateHistory.bias, "Delegate history bias UNCHANGED");
            assertEq(slope, beforeState.targetDelegateState.delegateHistory.slope, "Delegate history slope UNCHANGED");
            
            // Check pending addition queued for delegate
            (bool hasAdd, , DataTypes.VeBalance memory adds, ) = veMoca.delegatePendingDeltas(delegate, nextEpochStart);
            assertTrue(hasAdd, "Delegate has pending addition");
        }

        // 3. Global State (IMMEDIATE)
        // Global always updates immediately regardless of delegation
        {
            (uint128 bias, uint128 slope) = veMoca.veGlobal();
            assertEq(bias, beforeState.globalState.veGlobal.bias + biasDelta, "Global bias increased");
            assertEq(slope, beforeState.globalState.veGlobal.slope + slopeDelta, "Global slope increased");
        }
    }

    function verifyIncreaseDurationPendingDelegation(UnifiedStateSnapshot memory beforeState, uint128 newExpiry) internal {
        // Derived values
        uint128 slope = (beforeState.lockState.lock.moca + beforeState.lockState.lock.esMoca) / MAX_LOCK_DURATION;
        uint128 biasDelta = slope * (newExpiry - beforeState.lockState.lock.expiry);
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpochStart = currentEpochStart + EPOCH_DURATION;

        // 1. Owner State (IMMEDIATE)
        {
            address owner = beforeState.lockState.lock.owner;
            (uint128 bias, uint128 s) = veMoca.userHistory(owner, currentEpochStart);
            assertEq(bias, beforeState.userState.userHistory.bias + biasDelta, "Owner history bias increased");
            assertEq(s, beforeState.userState.userHistory.slope, "Owner history slope UNCHANGED"); // duration increase = bias only
            
            // Check pending subtraction
            (, bool hasSub, , ) = veMoca.userPendingDeltas(owner, nextEpochStart);
            assertTrue(hasSub, "Owner has pending subtraction");
        }

        // 2. Delegate State (PENDING)
        {
            address delegate = beforeState.lockState.lock.delegate;
            (uint128 bias, uint128 s) = veMoca.delegateHistory(delegate, currentEpochStart);
            assertEq(bias, beforeState.targetDelegateState.delegateHistory.bias, "Delegate history bias UNCHANGED");
            
            // Check pending addition
            (bool hasAdd, , , ) = veMoca.delegatePendingDeltas(delegate, nextEpochStart);
            assertTrue(hasAdd, "Delegate has pending addition");
        }

        // 3. Global State (IMMEDIATE)
        {
            (uint128 bias, ) = veMoca.veGlobal();
            assertEq(bias, beforeState.globalState.veGlobal.bias + biasDelta, "Global bias increased");
        }
    }


    /// @notice Verifies state after cronjob applies pending deltas (E1->E2 transition)
    function verifyCronjobAppliedDelegation(
        UnifiedStateSnapshot memory beforeState,
        UnifiedStateSnapshot memory afterState
    ) internal pure {
        // Verify pending deltas were cleared
        assertFalse(afterState.userState.userPendingDelta.hasSubtraction, "User pending cleared");
        assertFalse(afterState.targetDelegateState.delegatePendingDelta.hasAddition, "Delegate pending cleared");
        
        // Verify VP transferred
        uint128 userVpDelta = beforeState.userState.userCurrentVotingPower - afterState.userState.userCurrentVotingPower;
        uint128 delegateVpDelta = afterState.targetDelegateState.delegateCurrentVotingPower - beforeState.targetDelegateState.delegateCurrentVotingPower;
        
        // Account for decay during time warp
        assertGt(delegateVpDelta, 0, "Delegate gained VP");
        assertEq(afterState.userState.userCurrentVotingPower, 0, "User lost all delegated VP");
    }

    /// @notice Verifies increaseAmount/increaseDuration on ACTIVE delegated lock
    function verifyIncreaseOnActiveDelegation(
        UnifiedStateSnapshot memory beforeState,
        UnifiedStateSnapshot memory afterState,
        uint128 expectedBiasDelta,
        uint128 expectedSlopeDelta
    ) internal pure {
        // ============ 1. User State (UNCHANGED) ============
        // Owner VP unchanged (still 0 for delegated lock)
        assertEq(afterState.userState.userCurrentVotingPower, 0, "Owner VP still 0");
        assertEq(
            afterState.userState.userHistory.bias,
            beforeState.userState.userHistory.bias,
            "Owner history bias unchanged"
        );
        assertEq(
            afterState.userState.userHistory.slope,
            beforeState.userState.userHistory.slope,
            "Owner history slope unchanged"
        );
        // No pending deltas for user
        assertEq(
            afterState.userState.userPendingDelta.hasSubtraction,
            beforeState.userState.userPendingDelta.hasSubtraction,
            "Owner pending sub unchanged"
        );

        // ============ 2. Delegate State (IMMEDIATE) ============
        // Delegate gets immediate VP (no pending deltas)
        assertEq(
            afterState.targetDelegateState.delegateHistory.bias - beforeState.targetDelegateState.delegateHistory.bias,
            expectedBiasDelta,
            "Delegate history bias increased"
        );
        assertEq(
            afterState.targetDelegateState.delegateHistory.slope - beforeState.targetDelegateState.delegateHistory.slope,
            expectedSlopeDelta,
            "Delegate history slope increased"
        );
        assertGt(
            afterState.targetDelegateState.delegateCurrentVotingPower,
            beforeState.targetDelegateState.delegateCurrentVotingPower,
            "Delegate current VP increased"
        );
        
        // No new pending deltas queued
        assertEq(
            afterState.targetDelegateState.delegatePendingDelta.hasAddition,
            beforeState.targetDelegateState.delegatePendingDelta.hasAddition,
            "No new pending additions"
        );

        // ============ 3. Global State (IMMEDIATE) ============
        assertEq(
            afterState.globalState.veGlobal.bias - beforeState.globalState.veGlobal.bias,
            expectedBiasDelta,
            "Global bias increased"
        );
        assertEq(
            afterState.globalState.veGlobal.slope - beforeState.globalState.veGlobal.slope,
            expectedSlopeDelta,
            "Global slope increased"
        );
        assertGt(
            afterState.globalState.totalSupplyAtTimestamp,
            beforeState.globalState.totalSupplyAtTimestamp,
            "Total supply increased"
        );
    }

    /// @notice Verifies increaseAmount/increaseDuration on PENDING delegated lock
    function verifyIncreaseOnPendingDelegation(
        UnifiedStateSnapshot memory beforeState,
        UnifiedStateSnapshot memory afterState,
        uint128 expectedBiasDelta,
        uint128 expectedSlopeDelta
    ) internal pure {
        // ============ 1. User State (IMMEDIATE) ============
        // Owner gets immediate VP
        assertEq(
            afterState.userState.userHistory.bias - beforeState.userState.userHistory.bias,
            expectedBiasDelta,
            "Owner history bias increased"
        );
        assertEq(
            afterState.userState.userHistory.slope - beforeState.userState.userHistory.slope,
            expectedSlopeDelta,
            "Owner history slope increased"
        );
        assertGt(
            afterState.userState.userCurrentVotingPower,
            beforeState.userState.userCurrentVotingPower,
            "Owner current VP increased"
        );
        // Pending deltas queued for transfer
        assertTrue(afterState.userState.userPendingDelta.hasSubtraction, "User pending sub queued");

        // ============ 2. Delegate State (PENDING) ============
        // Delegate VP unchanged in current epoch
        assertEq(
            afterState.targetDelegateState.delegateHistory.bias,
            beforeState.targetDelegateState.delegateHistory.bias,
            "Delegate history bias unchanged"
        );
        assertEq(
            afterState.targetDelegateState.delegateHistory.slope,
            beforeState.targetDelegateState.delegateHistory.slope,
            "Delegate history slope unchanged"
        );
        assertEq(
            afterState.targetDelegateState.delegateCurrentVotingPower,
            beforeState.targetDelegateState.delegateCurrentVotingPower,
            "Delegate VP unchanged"
        );
        // Pending addition queued
        assertTrue(afterState.targetDelegateState.delegatePendingDelta.hasAddition, "Delegate pending add queued");

        // ============ 3. Global State (IMMEDIATE) ============
        assertEq(
            afterState.globalState.veGlobal.bias - beforeState.globalState.veGlobal.bias,
            expectedBiasDelta,
            "Global bias increased"
        );
        assertEq(
            afterState.globalState.veGlobal.slope - beforeState.globalState.veGlobal.slope,
            expectedSlopeDelta,
            "Global slope increased"
        );
        assertGt(
            afterState.globalState.totalSupplyAtTimestamp,
            beforeState.globalState.totalSupplyAtTimestamp,
            "Total supply increased"
        );
    }
}
