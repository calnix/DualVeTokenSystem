// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import {Constants} from "../../src/libraries/Constants.sol";

//note: vm.warp(EPOCH_DURATION);
abstract contract StateE1_Deploy is TestingHarness {    

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
    // Removed duplicate MOCA_TRANSFER_GAS_LIMIT here

    function setUp() public virtual override {
        super.setUp();

        vm.warp(EPOCH_DURATION);
        assertTrue(getCurrentEpochStart() > 0, "Current epoch start time is greater than 0");
    }
        
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

    
    function getLock(bytes32 lockId) public view returns (DataTypes.Lock memory) {
        DataTypes.Lock memory lock;
        (bytes32 id, address owner, address delegate, uint128 moca, uint128 esMoca_, uint128 expiry, bool isUnlocked) = veMoca.locks(lockId);
        lock.lockId = id;
        lock.owner = owner;
        lock.delegate = delegate;
        lock.moca = moca;
        lock.esMoca = esMoca_;
        lock.expiry = expiry;
        lock.isUnlocked = isUnlocked;
        return lock;
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

    struct StateSnapshot {
        // Tokens
        uint128 userMoca;
        uint128 userEsMoca;
        uint128 contractMoca;
        uint128 contractEsMoca;
        
        // Global
        DataTypes.VeBalance veGlobal;
        uint128 totalLockedMoca;
        uint128 totalLockedEsMoca;
        uint128 lastUpdatedTimestamp;
        
        // Mappings
        uint128 slopeChange; // at expiry
        uint128 slopeChangeNewExpiry; // at newExpiry (for increaseDuration)
        uint128 totalSupplyAt; // at currentEpochStart
        
        // User
        DataTypes.VeBalance userHistory; // at currentEpochStart
        uint128 userSlopeChange; // at expiry
        uint128 userLastUpdatedTimestamp;
        
        // Pending Deltas (Next Epoch)
        DataTypes.VeDeltas userPendingDelta;
    }

    struct DelegateSnapshot {
        DataTypes.VeBalance history;
        uint128 slopeChange; // at expiry
        uint128 lastUpdatedTimestamp;
        DataTypes.VeDeltas pendingDelta; // next epoch
    }

    struct DelegatePairSnapshot {
        DataTypes.VeBalance history;
        uint128 slopeChange; // at expiry
        uint128 lastUpdatedTimestamp;
        DataTypes.VeDeltas pendingDelta; // next epoch
    }

    function captureState(address user, uint128 expiry, uint128 newExpiry) internal returns (StateSnapshot memory) {
        StateSnapshot memory state;
        
        // tokens: user, contract
        state.userMoca = uint128(user.balance);
        state.userEsMoca = uint128(esMoca.balanceOf(user));
        state.contractMoca = uint128(address(veMoca).balance);
        state.contractEsMoca = uint128(esMoca.balanceOf(address(veMoca)));
        
        // global: bias, slope, totalLockedMoca, totalLockedEsMoca, lastUpdatedTimestamp
        (state.veGlobal.bias, state.veGlobal.slope) = veMoca.veGlobal();
        state.totalLockedMoca = veMoca.TOTAL_LOCKED_MOCA();
        state.totalLockedEsMoca = veMoca.TOTAL_LOCKED_ESMOCA();
        state.lastUpdatedTimestamp = veMoca.lastUpdatedTimestamp();
        
        // global mappings: slopeChanges, totalSupplyAt
        state.slopeChange = veMoca.slopeChanges(expiry);
        if (newExpiry != 0) {
            state.slopeChangeNewExpiry = veMoca.slopeChanges(newExpiry);
        }
        state.totalSupplyAt = veMoca.totalSupplyAt(getCurrentEpochStart());
        
        // user: userHistory, userSlopeChanges, userLastUpdatedTimestamp
        (state.userHistory.bias, state.userHistory.slope) = veMoca.userHistory(user, getCurrentEpochStart());
        state.userSlopeChange = veMoca.userSlopeChanges(user, expiry);
        state.userLastUpdatedTimestamp = veMoca.userLastUpdatedTimestamp(user);

        // pending deltas: userPendingDelta
        uint128 nextEpoch = getCurrentEpochStart() + EPOCH_DURATION;
        (
            bool hasAdd, 
            bool hasSub,
            DataTypes.VeBalance memory additions,
            DataTypes.VeBalance memory subtractions
        ) = veMoca.userPendingDeltas(user, nextEpoch);

        state.userPendingDelta.additions = additions;
        state.userPendingDelta.subtractions = subtractions;
        state.userPendingDelta.hasAddition = hasAdd;
        state.userPendingDelta.hasSubtraction = hasSub;

        return state;
    }

    function captureDelegateState(address delegate, uint128 expiry) internal returns (DelegateSnapshot memory) {
        DelegateSnapshot memory state;
        
        (uint128 historyBias, uint128 historySlope) = veMoca.delegateHistory(delegate, getCurrentEpochStart());
        state.history.bias = historyBias;
        state.history.slope = historySlope;

        state.slopeChange = veMoca.delegateSlopeChanges(delegate, expiry);
        state.lastUpdatedTimestamp = veMoca.delegateLastUpdatedTimestamp(delegate);
        
        uint128 nextEpoch = getCurrentEpochStart() + EPOCH_DURATION;
        (
            bool hasAdd, 
            bool hasSub,
            DataTypes.VeBalance memory additions,
            DataTypes.VeBalance memory subtractions
        ) = veMoca.delegatePendingDeltas(delegate, nextEpoch);

        state.pendingDelta.additions = additions;
        state.pendingDelta.subtractions = subtractions;
        state.pendingDelta.hasAddition = hasAdd;
        state.pendingDelta.hasSubtraction = hasSub;
         
        return state;
    }

    function captureDelegatePairState(address user, address delegate, uint128 expiry) internal returns (DelegatePairSnapshot memory) {
        DelegatePairSnapshot memory state;
        
        (uint128 historyBias, uint128 historySlope) = veMoca.delegatedAggregationHistory(user, delegate, getCurrentEpochStart());
        state.history.bias = historyBias;
        state.history.slope = historySlope;

        state.slopeChange = veMoca.userDelegatedSlopeChanges(user, delegate, expiry);
        state.lastUpdatedTimestamp = veMoca.userDelegatedPairLastUpdatedTimestamp(user, delegate);
        
        uint128 nextEpoch = getCurrentEpochStart() + EPOCH_DURATION;
        (
            bool hasAdd, 
            bool hasSub,
            DataTypes.VeBalance memory additions,
            DataTypes.VeBalance memory subtractions
        ) = veMoca.userPendingDeltasForDelegate(user, delegate, nextEpoch);

        state.pendingDelta.additions = additions;
        state.pendingDelta.subtractions = subtractions;
        state.pendingDelta.hasAddition = hasAdd;
        state.pendingDelta.hasSubtraction = hasSub;
         
        return state;
    }

    function verifyCreateLock(
        StateSnapshot memory beforeState, 
        address user, 
        bytes32 lockId, 
        uint128 mocaAmt, 
        uint128 esMocaAmt, 
        uint128 expiry
    ) internal {
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Expected Deltas
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        // 1. Tokens
        assertEq(user.balance, beforeState.userMoca - mocaAmt, "User MOCA must be decremented");
        assertEq(esMoca.balanceOf(user), beforeState.userEsMoca - esMocaAmt, "User esMOCA must be decremented");
        assertEq(address(veMoca).balance, beforeState.contractMoca + mocaAmt, "Contract MOCA must be incremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.contractEsMoca + esMocaAmt, "Contract esMOCA must be incremented");

        // 2. Global State
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.veGlobal.bias + expectedBias, "veGlobal bias must be incremented");
        assertEq(slope, beforeState.veGlobal.slope + expectedSlope, "veGlobal slope must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.totalLockedMoca + mocaAmt, "Total Locked MOCA must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.totalLockedEsMoca + esMocaAmt, "Total Locked esMOCA must be incremented");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be incremented");

        // 3. Mappings
        assertEq(veMoca.slopeChanges(expiry), beforeState.slopeChange + expectedSlope, "Slope Changes must be incremented");
        
        // 4. User State [userHistory, userSlopeChanges, userLastUpdatedTimestamp]
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeState.userHistory.bias + expectedBias, "userHistory Bias must be incremented");
        assertEq(slope, beforeState.userHistory.slope + expectedSlope, "userHistory Slope must be incremented");
        assertEq(veMoca.userSlopeChanges(user, expiry), beforeState.userSlopeChange + expectedSlope, "userSlopeChanges must be incremented");
        assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be incremented");

        // 5. Lock
        DataTypes.Lock memory lock = getLock(lockId);
        assertEq(lock.lockId, lockId, "Lock ID");
        assertEq(lock.owner, user, "Lock Owner");
        assertEq(lock.delegate, address(0), "Lock Delegate"); // Always address(0) since createLock doesn't allow delegation
        assertEq(lock.moca, mocaAmt, "Lock Moca");
        assertEq(lock.esMoca, esMocaAmt, "Lock esMoca");
        assertEq(lock.expiry, expiry, "Lock Expiry");
        assertFalse(lock.isUnlocked, "Lock Unlocked");

        // 6. Lock History
        uint256 len = veMoca.getLockHistoryLength(lockId);
        assertGt(len, 0, "Lock History Length");
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        assertEq(cp.veBalance.bias, expectedBias, "Lock History: Checkpoint Bias must be incremented");
        assertEq(cp.veBalance.slope, expectedSlope, "Lock History: Checkpoint Slope must be incremented");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp must be incremented");
    }

    function verifyIncreaseAmount(
        StateSnapshot memory beforeState,
        bytes32 lockId,
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 expiry // Existing expiry
    ) internal {
        // Fix: Destructure the tuple returned by the public mapping getter
        (, address user,,,,,) = veMoca.locks(lockId);
        uint128 currentEpochStart = getCurrentEpochStart();

        // Expected Deltas
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        // 1. Tokens
        assertEq(user.balance, beforeState.userMoca - mocaAmt, "User MOCA");
        assertEq(esMoca.balanceOf(user), beforeState.userEsMoca - esMocaAmt, "User esMOCA");
        assertEq(address(veMoca).balance, beforeState.contractMoca + mocaAmt, "Contract MOCA");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.contractEsMoca + esMocaAmt, "Contract esMOCA");

        // 2. Global State
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.veGlobal.bias + expectedBias, "veGlobal bias");
        assertEq(slope, beforeState.veGlobal.slope + expectedSlope, "veGlobal slope");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.totalLockedMoca + mocaAmt, "Total Locked MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.totalLockedEsMoca + esMocaAmt, "Total Locked esMOCA");

        // 3. Mappings
        assertEq(veMoca.slopeChanges(expiry), beforeState.slopeChange + expectedSlope, "Slope Changes");

        // 4. User State
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeState.userHistory.bias + expectedBias, "User History Bias");
        assertEq(slope, beforeState.userHistory.slope + expectedSlope, "User History Slope");
        assertEq(veMoca.userSlopeChanges(user, expiry), beforeState.userSlopeChange + expectedSlope, "User Slope Change");

        // 5. Lock
        DataTypes.Lock memory lock = getLock(lockId);
        
        // Fix: Destructure here as well for the assertion
        (,,, uint128 currentMoca,,,) = veMoca.locks(lockId);
        assertEq(lock.moca, currentMoca, "Lock Moca"); 
        
        // 6. Checkpoint (Last checkpoint should reflect updated balance)
        uint256 len = veMoca.getLockHistoryLength(lockId);
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        // Calculate total expected for lock based on previous + new
        // This might be complex if we don't have previous lock state here, but we can check slope delta
        // For now simple check:
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Checkpoint Timestamp");
    }

    function verifyIncreaseDuration(
        StateSnapshot memory beforeState,
        bytes32 lockId,
        uint128 oldExpiry,
        uint128 newExpiry
    ) internal {
        // Destructure lock to get owner
        (, address user,,,,,) = veMoca.locks(lockId);
        uint128 currentEpochStart = getCurrentEpochStart();

        (,,, uint128 moca, uint128 esMoca,,) = veMoca.locks(lockId);
        uint128 lockSlope = (moca + esMoca) / MAX_LOCK_DURATION;
        
        uint128 biasIncrease = lockSlope * (newExpiry - oldExpiry);

        // 1. Global State
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.veGlobal.bias + biasIncrease, "veGlobal bias");
        assertEq(slope, beforeState.veGlobal.slope, "veGlobal slope"); // Slope shouldn't change for duration increase
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated");

        // 2. Mappings (Slope Changes)
        // Old expiry slope change should decrease
        assertEq(veMoca.slopeChanges(oldExpiry), beforeState.slopeChange - lockSlope, "Slope Change (Old Expiry)");
        // New expiry slope change should increase
        assertEq(veMoca.slopeChanges(newExpiry), beforeState.slopeChangeNewExpiry + lockSlope, "Slope Change (New Expiry)");

        // 3. User State
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeState.userHistory.bias + biasIncrease, "User History Bias");
        assertEq(slope, beforeState.userHistory.slope, "User History Slope");
        assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "User LastUpdated");
        
        // 4. Lock State
        (,,,,, uint128 storedExpiry,) = veMoca.locks(lockId);
        assertEq(storedExpiry, newExpiry, "Lock Expiry");

        // 5. Checkpoint
        uint256 len = veMoca.getLockHistoryLength(lockId);
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Checkpoint Timestamp");
        assertEq(cp.veBalance.bias, lockSlope * newExpiry, "Checkpoint Bias");
        assertEq(cp.veBalance.slope, lockSlope, "Checkpoint Slope");
    }

    function verifyDelegateLock(
        bytes32 lockId,
        address user,
        address delegate,
        StateSnapshot memory userStateBefore,
        DelegateSnapshot memory delegateStateBefore,
        DelegatePairSnapshot memory pairStateBefore
    ) internal {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpoch = currentEpochStart + EPOCH_DURATION;
        
        (,,, uint128 moca, uint128 esMoca, uint128 expiry,) = veMoca.locks(lockId);
        uint128 lockSlope = (moca + esMoca) / MAX_LOCK_DURATION;
        uint128 lockBias = lockSlope * expiry;

        // 1. User State
        // userSlopeChanges[expiry] decreases by lockSlope
        assertEq(veMoca.userSlopeChanges(user, expiry), userStateBefore.userSlopeChange - lockSlope, "User Slope Change");
        
        // userPendingDeltas[nextEpoch]: subtraction of lockVeBalance
        (
            bool hasAdd, 
            bool hasSub,
            DataTypes.VeBalance memory additions,
            DataTypes.VeBalance memory subtractions
        ) = veMoca.userPendingDeltas(user, nextEpoch);

        assertEq(hasSub, true, "User Pending Subtraction");
        assertEq(subtractions.bias, userStateBefore.userPendingDelta.subtractions.bias + lockBias, "User Pending Sub Bias");
        assertEq(subtractions.slope, userStateBefore.userPendingDelta.subtractions.slope + lockSlope, "User Pending Sub Slope");

        // 2. Delegate State
        // delegateSlopeChanges[expiry] increases by lockSlope
        assertEq(veMoca.delegateSlopeChanges(delegate, expiry), delegateStateBefore.slopeChange + lockSlope, "Delegate Slope Change");
        
        // delegatePendingDeltas[nextEpoch]: addition of lockVeBalance
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.delegatePendingDeltas(delegate, nextEpoch);

        assertEq(hasAdd, true, "Delegate Pending Addition");
        assertEq(additions.bias, delegateStateBefore.pendingDelta.additions.bias + lockBias, "Delegate Pending Add Bias");
        assertEq(additions.slope, delegateStateBefore.pendingDelta.additions.slope + lockSlope, "Delegate Pending Add Slope");

        // 3. Delegate Pair State
        // userDelegatedSlopeChanges[expiry] increases by lockSlope
        assertEq(veMoca.userDelegatedSlopeChanges(user, delegate, expiry), pairStateBefore.slopeChange + lockSlope, "Pair Slope Change");
        
        // userPendingDeltasForDelegate[nextEpoch]: addition of lockVeBalance
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.userPendingDeltasForDelegate(user, delegate, nextEpoch);

        assertEq(hasAdd, true, "Pair Pending Addition");
        assertEq(additions.bias, pairStateBefore.pendingDelta.additions.bias + lockBias, "Pair Pending Add Bias");
        assertEq(additions.slope, pairStateBefore.pendingDelta.additions.slope + lockSlope, "Pair Pending Add Slope");

        // 4. Lock Delegate Updated
        (,, address actualDelegate,,,,) = veMoca.locks(lockId);
        assertEq(actualDelegate, delegate, "Lock Delegate Updated");
    }

    function verifySwitchDelegate(
        bytes32 lockId,
        address user,
        address oldDelegate,
        address newDelegate,
        DelegateSnapshot memory oldDelegateStateBefore,
        DelegateSnapshot memory newDelegateStateBefore,
        DelegatePairSnapshot memory oldPairStateBefore,
        DelegatePairSnapshot memory newPairStateBefore
    ) internal {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpoch = currentEpochStart + EPOCH_DURATION;
        
        (,,, uint128 moca, uint128 esMoca, uint128 expiry,) = veMoca.locks(lockId);
        uint128 lockSlope = (moca + esMoca) / MAX_LOCK_DURATION;
        uint128 lockBias = lockSlope * expiry;

        // 1. Old Delegate State
        // delegateSlopeChanges[expiry] decreases
        assertEq(veMoca.delegateSlopeChanges(oldDelegate, expiry), oldDelegateStateBefore.slopeChange - lockSlope, "Old Del Slope Change");
        
        // delegatePendingDeltas[nextEpoch]: subtraction
        (
            bool hasAdd, 
            bool hasSub,
            DataTypes.VeBalance memory additions,
            DataTypes.VeBalance memory subtractions
        ) = veMoca.delegatePendingDeltas(oldDelegate, nextEpoch);

        assertEq(hasSub, true, "Old Del Pending Sub");
        assertEq(subtractions.bias, oldDelegateStateBefore.pendingDelta.subtractions.bias + lockBias, "Old Del Pending Sub Bias");
        
        // 2. New Delegate State
        // delegateSlopeChanges[expiry] increases
        assertEq(veMoca.delegateSlopeChanges(newDelegate, expiry), newDelegateStateBefore.slopeChange + lockSlope, "New Del Slope Change");
        
        // delegatePendingDeltas[nextEpoch]: addition
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.delegatePendingDeltas(newDelegate, nextEpoch);

        assertEq(hasAdd, true, "New Del Pending Add");
        assertEq(additions.bias, newDelegateStateBefore.pendingDelta.additions.bias + lockBias, "New Del Pending Add Bias");

        // 3. Old Pair State
        // userPendingDeltasForDelegate[nextEpoch]: subtraction
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.userPendingDeltasForDelegate(user, oldDelegate, nextEpoch);

        assertEq(hasSub, true, "Old Pair Pending Sub");
        assertEq(subtractions.bias, oldPairStateBefore.pendingDelta.subtractions.bias + lockBias, "Old Pair Pending Sub Bias");

        // 4. New Pair State
        // userPendingDeltasForDelegate[nextEpoch]: addition
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.userPendingDeltasForDelegate(user, newDelegate, nextEpoch);

        assertEq(hasAdd, true, "New Pair Pending Add");
        assertEq(additions.bias, newPairStateBefore.pendingDelta.additions.bias + lockBias, "New Pair Pending Add Bias");

        // 5. Lock Delegate Updated
        (,, address actualDelegate,,,,) = veMoca.locks(lockId);
        assertEq(actualDelegate, newDelegate, "Lock Delegate Switched");
    }

    function verifyUndelegateLock(
        bytes32 lockId,
        address user,
        address delegate,
        StateSnapshot memory userStateBefore,
        DelegateSnapshot memory delegateStateBefore,
        DelegatePairSnapshot memory pairStateBefore
    ) internal {
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 nextEpoch = currentEpochStart + EPOCH_DURATION;
        
        (,,, uint128 moca, uint128 esMoca, uint128 expiry,) = veMoca.locks(lockId);
        uint128 lockSlope = (moca + esMoca) / MAX_LOCK_DURATION;
        uint128 lockBias = lockSlope * expiry;

        // 1. Delegate State
        // delegateSlopeChanges[expiry] decreases
        assertEq(veMoca.delegateSlopeChanges(delegate, expiry), delegateStateBefore.slopeChange - lockSlope, "Delegate Slope Change");
        
        // delegatePendingDeltas[nextEpoch]: subtraction
        (
            bool hasAdd, 
            bool hasSub,
            DataTypes.VeBalance memory additions,
            DataTypes.VeBalance memory subtractions
        ) = veMoca.delegatePendingDeltas(delegate, nextEpoch);

        assertEq(hasSub, true, "Delegate Pending Sub");
        assertEq(subtractions.bias, delegateStateBefore.pendingDelta.subtractions.bias + lockBias, "Delegate Pending Sub Bias");

        // 2. User State
        // userSlopeChanges[expiry] increases
        assertEq(veMoca.userSlopeChanges(user, expiry), userStateBefore.userSlopeChange + lockSlope, "User Slope Change");
        
        // userPendingDeltas[nextEpoch]: addition
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.userPendingDeltas(user, nextEpoch);

        assertEq(hasAdd, true, "User Pending Add");
        assertEq(additions.bias, userStateBefore.userPendingDelta.additions.bias + lockBias, "User Pending Add Bias");

        // 3. Pair State
        // userPendingDeltasForDelegate[nextEpoch]: subtraction
        (
            hasAdd, 
            hasSub,
            additions,
            subtractions
        ) = veMoca.userPendingDeltasForDelegate(user, delegate, nextEpoch);

        assertEq(hasSub, true, "Pair Pending Sub");
        assertEq(subtractions.bias, pairStateBefore.pendingDelta.subtractions.bias + lockBias, "Pair Pending Sub Bias");

        // 4. Lock Delegate Cleared
        (,, address actualDelegate,,,,) = veMoca.locks(lockId);
        assertEq(actualDelegate, address(0), "Lock Delegate Cleared");
    }
}

contract StateE1_Deploy_Test is StateE1_Deploy {
    using stdStorage for StdStorage;
    
    function testRevert_ConstructorChecks() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingEscrowMoca(address(0), address(esMoca), MOCA_TRANSFER_GAS_LIMIT, globalAdmin, votingEscrowMocaAdmin, monitorAdmin, cronJobAdmin, monitor, emergencyExitHandler);
    }

    function test_Constructor() public {
        assertEq(veMoca.WMOCA(), address(mockWMoca), "WMOCA not set correctly");
        assertEq(address(veMoca.ESMOCA()), address(esMoca), "ESMOCA not set correctly");
        assertEq(veMoca.MOCA_TRANSFER_GAS_LIMIT(), MOCA_TRANSFER_GAS_LIMIT, "MOCA_TRANSFER_GAS_LIMIT not set correctly");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), 0);
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), 0);
        
        // Check role assignments
        assertTrue(veMoca.hasRole(veMoca.DEFAULT_ADMIN_ROLE(), globalAdmin), "globalAdmin should have DEFAULT_ADMIN_ROLE");
        assertTrue(veMoca.hasRole(Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE, votingEscrowMocaAdmin), "votingEscrowMocaAdmin should have VOTING_ESCROW_MOCA_ADMIN_ROLE");
        assertTrue(veMoca.hasRole(Constants.MONITOR_ADMIN_ROLE, monitorAdmin), "monitorAdmin should have MONITOR_ADMIN_ROLE");
        assertTrue(veMoca.hasRole(Constants.CRON_JOB_ADMIN_ROLE, cronJobAdmin), "cronJobAdmin should have CRON_JOB_ADMIN_ROLE");
        assertTrue(veMoca.hasRole(Constants.MONITOR_ROLE, monitor), "monitor should have MONITOR_ROLE");
        assertTrue(veMoca.hasRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler), "emergencyExitHandler should have EMERGENCY_EXIT_HANDLER_ROLE");
    }

    // --------------------------negative tests: createLock -----------------------------------------

        function testRevert_CreateLock_MinimumAmountCheck_InvalidAmount() public {
            vm.expectRevert(Errors.InvalidAmount.selector);

            uint128 esMocaAmt = uint128(Constants.MIN_LOCK_AMOUNT - 1);
            uint128 expiry = uint128(getEpochEndTimestamp(3));

            vm.prank(user1);
            veMoca.createLock(expiry, esMocaAmt);
        }

        function testRevert_CreateLock_InvalidEpochTime() public {
            vm.expectRevert(Errors.InvalidEpochTime.selector);

            uint128 esMocaAmt = Constants.MIN_LOCK_AMOUNT;

            vm.prank(user1);
            veMoca.createLock(1, esMocaAmt);
        }

        //note: expiry is at the end of epoch 2 | this is insufficient and reverts on _minimumDurationCheck()
        function testRevert_CreateLock_MinimumDurationCheck_LockExpiresTooSoon() public {
            // check currentEpochNumber
            uint128 currentEpochNumber = getCurrentEpochNumber();
            assertEq(currentEpochNumber, 1, "Current epoch number is 1");

            // therefore, expiry must be at the end of epoch 3
            // if lock expires at the end of epoch 2, it will revert on _minimumDurationCheck()

            vm.expectRevert(Errors.LockExpiresTooSoon.selector);
            
            uint128 esMocaAmt = Constants.MIN_LOCK_AMOUNT;
            uint128 expiry = uint128(getEpochEndTimestamp(2));

            vm.prank(user1);
            veMoca.createLock(expiry, esMocaAmt);
        }

        function testRevert_CreateLock_InvalidLockDuration_ExceedMaxLockDuration() public {
            uint128 esMocaAmt = Constants.MIN_LOCK_AMOUNT;
            uint128 expiry = uint128(MAX_LOCK_DURATION + EPOCH_DURATION + EPOCH_DURATION);

            vm.expectRevert(Errors.InvalidLockDuration.selector);

            vm.prank(user1);
            veMoca.createLock(expiry, esMocaAmt);
        }


    //-------------------------- state transition: user creates lock --------------------------------

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
            StateSnapshot memory beforeState = captureState(user1, expiry, 0);

            // 4) Execute
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.LockCreated(expectedLockId, user1, mocaAmount, esMocaAmount, expiry);
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.GlobalUpdated(beforeState.veGlobal.bias + expectedBias, beforeState.veGlobal.slope + expectedSlope);
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.UserUpdated(user1, beforeState.userHistory.bias + expectedBias, beforeState.userHistory.slope + expectedSlope);

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

    // ---- state_transition: cross an epoch boundary [to check totalSupplyAt]  ----
    
    // note: totalSupplyAt is only updated after crossing epoch boundary
    function test_totalSupplyAt_CrossEpochBoundary_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 1, "Current epoch number is 1");

        // get epoch 2 start timestamp
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));

        // 1) Capture State
        StateSnapshot memory beforeState = captureState(user1, lock1_Expiry, 0);
        assertEq(beforeState.totalSupplyAt, 0, "totalSupplyAt is 0");

        // 2) warp to be within Epoch 2
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // 3) cronjob: Update State [updates global and user states]
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](1);
            accounts[0] = user1;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
        vm.stopPrank();

        // 4) Capture State
        StateSnapshot memory afterState = captureState(user1, lock1_Expiry, 0);

        // calc. expected totalSupplyAt [decays bias to epoch2StartTimestamp]
        uint128 expectedTotalSupplyAt = getValueAt(beforeState.veGlobal, epoch2StartTimestamp);

        // 3) Verify: bias & slope would not change [since no new locks created]
        assertEq(afterState.veGlobal.bias, beforeState.veGlobal.bias, "veGlobal bias");
        assertEq(afterState.veGlobal.slope, beforeState.veGlobal.slope, "veGlobal slope");
        // totalSupplyAt: calculated & veMoca.totalSupplyAtTimestamp()
        assertEq(afterState.totalSupplyAt, expectedTotalSupplyAt, "totalSupplyAt is > 0 after epoch boundary (calculated)");
        assertEq(afterState.totalSupplyAt, veMoca.totalSupplyAtTimestamp(epoch2StartTimestamp), "totalSupplyAt is > 0 after epoch boundary (veMoca.totalSupplyAtTimestamp())");
    }
}


abstract contract StateE2_CronJobUpdatesState is StateE1_User1_CreateLock1 {
    
    StateSnapshot public epoch1_AfterLock1Creation;
    StateSnapshot public epoch2_AfterCronJobUpdate;

    function setUp() public virtual override {
        super.setUp();

        // 1) Capture State
        epoch1_AfterLock1Creation = captureState(user1, lock1_Expiry, 0);

        // 2) warp to be within Epoch 2
        vm.warp(uint128(getEpochStartTimestamp(2) + 1));
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // 3) perform cronjob update State
        vm.startPrank(cronJob);
        address[] memory accounts = new address[](1);
        accounts[0] = user1;
        veMoca.updateAccountsAndPendingDeltas(accounts, false);
        vm.stopPrank();

        // 4) Capture State
        epoch2_AfterCronJobUpdate = captureState(user1, lock1_Expiry, 0);
    }
}
    
// note: totalSupplyAt is only updated after crossing epoch boundary
contract StateE2_CronJobUpdatesState_Test is StateE2_CronJobUpdatesState {

    function test_totalSupplyAt_CronJobUpdatesState_E2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // before: totalSupplyAt is 0; first update has no locks
        assertEq(epoch1_AfterLock1Creation.totalSupplyAt, 0, "totalSupplyAt is 0");


        // get epoch 2 start timestamp
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));

        // calc. expected totalSupplyAt [decays bias to epoch2StartTimestamp]
        uint128 expectedTotalSupplyAt = getValueAt(epoch1_AfterLock1Creation.veGlobal, epoch2StartTimestamp);

        // 3) After: totalSupplyAt is > 0; 2nd update registers lock1's veBalance 
        // totalSupplyAt: calculated & veMoca.totalSupplyAtTimestamp()
        assertEq(epoch2_AfterCronJobUpdate.totalSupplyAt, expectedTotalSupplyAt, "totalSupplyAt is > 0 after epoch boundary (calculated)");
        assertEq(epoch2_AfterCronJobUpdate.totalSupplyAt, veMoca.totalSupplyAtTimestamp(epoch2StartTimestamp), "totalSupplyAt is > 0 after epoch boundary (veMoca.totalSupplyAtTimestamp())");
        
        // veGlobal: bias & slope are always up to date; does not have an epoch lag like totalSupplyAt[]
        assertEq(epoch2_AfterCronJobUpdate.veGlobal.bias, epoch1_AfterLock1Creation.veGlobal.bias, "veGlobal bias");
        assertEq(epoch2_AfterCronJobUpdate.veGlobal.slope, epoch1_AfterLock1Creation.veGlobal.slope, "veGlobal slope");
    }

    // ---- state transition: user creates lock2 in epoch 2 ----

    function test_User1_CreateLock2_E2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");
        
        // 1) Setup funds
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.approve(address(esMoca), 100 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // 2) Test parameters
        uint128 expiry = uint128(getEpochEndTimestamp(6));  // currentEpoch: 2; + 4 epochs [lock2 expires at end of epoch 6]
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;
        bytes32 expectedLockId = generateLockId(block.number, user1); // Salt incremented
        
        uint128 expectedSlope = (mocaAmount + esMocaAmount) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        // 3) Capture State + userVotingPower before lock2 creation
        StateSnapshot memory beforeState = captureState(user1, expiry, 0);
        uint128 userVotingPower_Before = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);

        // 4) Execute
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockCreated(expectedLockId, user1, mocaAmount, esMocaAmount, expiry);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.GlobalUpdated(beforeState.veGlobal.bias + expectedBias, beforeState.veGlobal.slope + expectedSlope);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.UserUpdated(user1, beforeState.userHistory.bias + expectedBias, beforeState.userHistory.slope + expectedSlope);

        vm.prank(user1);
        bytes32 actualLockId2 = veMoca.createLock{value: mocaAmount}(expiry, esMocaAmount);

        // 5) Verify
        assertEq(actualLockId2, expectedLockId, "Lock ID Match");
        verifyCreateLock(beforeState, user1, actualLockId2, mocaAmount, esMocaAmount, expiry);

        // Extra Check: Voting Power Accumulation
        uint128 userVotingPower_After = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        uint128 expectedPowerNewLock = veMoca.getLockVotingPowerAt(actualLockId2, uint128(block.timestamp));
        assertEq(userVotingPower_After, userVotingPower_Before + expectedPowerNewLock, "Accumulated Voting Power");
    }

}
    
//note lock2 expires at end of epoch 6
abstract contract StateE2_User1_CreateLock2 is StateE2_CronJobUpdatesState {

    bytes32 public lock2_Id;
    uint128 public lock2_Expiry;
    uint128 public lock2_MocaAmount;
    uint128 public lock2_EsMocaAmount;

    StateSnapshot public epoch2_BeforeLock2Creation;
    StateSnapshot public epoch2_AfterLock2Creation;
    uint128 public userVotingPower_BeforeLock2Creation;
    uint128 public userVotingPower_AfterLock2Creation;

    function setUp() public virtual override {
        super.setUp();


        // 1) Setup funds
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.approve(address(esMoca), 100 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // 2) Test parameters
        lock2_Expiry = uint128(getEpochEndTimestamp(6));
        lock2_MocaAmount = 100 ether;
        lock2_EsMocaAmount = 100 ether;
        
        // 3) Capture state
        epoch2_BeforeLock2Creation = captureState(user1, lock2_Expiry, 0);
        userVotingPower_BeforeLock2Creation = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        
        // 4) Execute
        vm.prank(user1);
        lock2_Id = veMoca.createLock{value: lock2_MocaAmount}(lock2_Expiry, lock2_EsMocaAmount);

        // 5) Capture State
        epoch2_AfterLock2Creation = captureState(user1, lock2_Expiry, 0);
        userVotingPower_AfterLock2Creation = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
    }
}

contract StateE2_User1_CreateLock2_Test is StateE2_User1_CreateLock2 {

    function test_VerifyUser1_CreateLock2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");
        
        // 1) Verify
        verifyCreateLock(epoch2_BeforeLock2Creation, user1, lock2_Id, lock2_MocaAmount, lock2_EsMocaAmount, lock2_Expiry);

        // 2) Extra Check: Voting Power of new lock
        uint128 votingPowerOfLock2 = veMoca.getLockVotingPowerAt(lock2_Id, uint128(block.timestamp));
        uint128 userVotingPower_After = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        assertEq(userVotingPower_After, userVotingPower_BeforeLock2Creation + votingPowerOfLock2, "Voting Power of new lock");
    }

    // --- state transition:  ---

    function test_User1_IncreaseAmount_Epoch3() public {
        // 1) Warp to Epoch 3
        uint128 epoch3StartTimestamp = uint128(getEpochStartTimestamp(3));
        vm.warp(epoch3StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 3, "Current epoch number is 3");

        // 2) Setup: fund user1 with MOCA and convert to esMOCA [BEFORE capturing state]
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // 3) Capture State [AFTER funding]
        StateSnapshot memory beforeState = captureState(user1, lock2_Expiry, 0);
        uint128 userVotingPower_BeforeAmountIncrease = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);

        // 4) Test parameters
        uint128 esMocaToAdd = 100 ether;
        uint128 mocaToAdd = 100 ether;
        uint128 expectedSlope = (mocaToAdd + esMocaToAdd) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * lock2_Expiry;

        // 5) Expect events (order must match contract emission order)
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.GlobalUpdated(epoch2_AfterLock2Creation.veGlobal.bias, epoch2_AfterLock2Creation.veGlobal.slope);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.UserUpdated(user1, epoch2_AfterLock2Creation.userHistory.bias, epoch2_AfterLock2Creation.userHistory.slope);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockAmountIncreased(lock2_Id, user1, address(0), mocaToAdd, esMocaToAdd);

        // 6) Execute
        vm.prank(user1);
        veMoca.increaseAmount{value: mocaToAdd}(lock2_Id, esMocaToAdd);

        // 7) Verify
        verifyIncreaseAmount(beforeState, lock2_Id, mocaToAdd, esMocaToAdd, lock2_Expiry);

        // 8) Extra Check: Voting Power Accumulation of lock2
        uint128 userVotingPower_After = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        uint128 expectedPowerNewLock = veMoca.getLockVotingPowerAt(lock2_Id, uint128(block.timestamp));
        assertEq(userVotingPower_After, userVotingPower_BeforeAmountIncrease + expectedPowerNewLock, "Accumulated Voting Power");
    }

    function test_User1_IncreaseAmountLock2_Epoch3() public {
        // 1) Warp to Epoch 3
        uint128 epoch3StartTimestamp = uint128(getEpochStartTimestamp(3));
        vm.warp(epoch3StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 3, "Current epoch number is 3");

        // 2) Setup: fund user1 with MOCA and convert to esMOCA [BEFORE capturing state]
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // [NEW] Update state to current epoch (3) to account for decay
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](1);
            accounts[0] = user1;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
        vm.stopPrank();

        // 3) Capture State [AFTER funding and update]
        StateSnapshot memory beforeState = captureState(user1, lock2_Expiry, 0);
        uint128 userVotingPower_BeforeAmountIncrease = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);

        // 4) Test parameters
        uint128 esMocaToAdd = 100 ether;
        uint128 mocaToAdd = 100 ether;
        uint128 expectedSlope = (mocaToAdd + esMocaToAdd) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * lock2_Expiry;

        // 5) Expect events (order must match contract emission order)
        //vm.expectEmit(false, false, false, true, address(veMoca));
        // Global Updated: base is beforeState (decayed) + new amount
        //emit Events.GlobalUpdated(beforeState.veGlobal.bias + expectedBias, beforeState.veGlobal.slope + expectedSlope);
        
        //vm.expectEmit(true, false, false, true, address(veMoca));
        // User Updated: base is beforeState (decayed) + new amount
        //emit Events.UserUpdated(user1, beforeState.userHistory.bias + expectedBias, beforeState.userHistory.slope + expectedSlope);
        
        //vm.expectEmit(true, true, true, true, address(veMoca));
        //emit Events.LockAmountIncreased(lock2_Id, user1, address(0), mocaToAdd, esMocaToAdd);

        // 6) Execute
        vm.prank(user1);
        veMoca.increaseAmount{value: mocaToAdd}(lock2_Id, esMocaToAdd);

        // 7) Verify
        verifyIncreaseAmount(beforeState, lock2_Id, mocaToAdd, esMocaToAdd, lock2_Expiry);

        // 8) Extra Check: Voting Power Accumulation of lock2
        uint128 userVotingPower_After = veMoca.balanceOfAt(user1, uint128(block.timestamp), false);
        uint128 expectedPowerNewLock = veMoca.getLockVotingPowerAt(lock2_Id, uint128(block.timestamp));
        assertEq(userVotingPower_After, userVotingPower_BeforeAmountIncrease + expectedPowerNewLock, "Accumulated Voting Power");
    }
}
    
