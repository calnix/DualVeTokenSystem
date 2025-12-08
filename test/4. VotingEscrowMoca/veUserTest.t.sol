// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

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

    
    function getLock(bytes32 lockId) public view returns (DataTypes.Lock memory lock) {
        (
            lock.lockId,
            lock.owner,
            lock.delegate,
            lock.moca,
            lock.esMoca,
            lock.expiry,
            lock.isUnlocked,
            lock.delegationEpoch,
            lock.currentHolder
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
    }

    struct UserStateSnapshot {
        DataTypes.VeBalance userHistory; // at currentEpochStart
        uint128 userSlopeChange; // at expiry
        uint128 userLastUpdatedTimestamp;

        uint128 userSlopeChangeNewExpiry; // at newExpiry (for increaseDuration)
        // balanceOfAt
        uint128 userVotingPower;
    }

    struct LockStateSnapshot {
        DataTypes.Lock lock;
        DataTypes.Checkpoint[] lockHistory;
        uint128 lockVotingPower;
    }

    // Unified State Snapshot
    struct StateSnapshot {
        TokensSnapshot tokens;
        GlobalStateSnapshot global;
        UserStateSnapshot user;
        LockStateSnapshot lock;
    }

    function captureTokensState(address user) internal returns (TokensSnapshot memory) {
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
        return state;
    }

    function captureUserState(address user, uint128 expiry, uint128 newExpiry) internal returns (UserStateSnapshot memory) {
        UserStateSnapshot memory state;
        // user vars
        (state.userHistory.bias, state.userHistory.slope) = veMoca.userHistory(user, getCurrentEpochStart());
        state.userSlopeChange = veMoca.userSlopeChanges(user, expiry);
        state.userLastUpdatedTimestamp = veMoca.userLastUpdatedTimestamp(user);

        if (newExpiry != 0) state.userSlopeChangeNewExpiry = veMoca.userSlopeChanges(user, newExpiry);

        // userVotingPower
        state.userVotingPower = veMoca.balanceOfAt(user, uint128(block.timestamp), false);

        return state;
    }

    function captureLockState(bytes32 lockId) internal returns (LockStateSnapshot memory) {
        LockStateSnapshot memory state;
        state.lock = getLock(lockId);
        // lock history
        uint256 len = veMoca.getLockHistoryLength(lockId);
        state.lockHistory = new DataTypes.Checkpoint[](len);
        
        for(uint256 i; i < len; ++i) {
            state.lockHistory[i] = getLockHistory(lockId, i);
        }
        
        // lockVotingPower
        state.lockVotingPower = getLockVotingPowerAt(lockId, uint128(block.timestamp));
        
        return state;
    }

    function captureAllStates(address user, bytes32 lockId, uint128 expiry, uint128 newExpiry) internal 
        returns (StateSnapshot memory) {
        StateSnapshot memory state;
        
        state.tokens = captureTokensState(user);
        state.global = captureGlobalState(expiry, newExpiry);
        state.user = captureUserState(user, expiry, newExpiry);
        state.lock = captureLockState(lockId);
        
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
        TokensSnapshot memory beforeTokens = beforeState.tokens;
        GlobalStateSnapshot memory beforeGlobal = beforeState.global;
        UserStateSnapshot memory beforeUser = beforeState.user;
        LockStateSnapshot memory beforeLock = beforeState.lock;
        
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // Expected Deltas
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        // 1. Tokens
        assertEq(user.balance, beforeTokens.userMoca - mocaAmt, "User MOCA must be decremented");
        assertEq(esMoca.balanceOf(user), beforeTokens.userEsMoca - esMocaAmt, "User esMOCA must be decremented");
        assertEq(address(veMoca).balance, beforeTokens.contractMoca + mocaAmt, "Contract MOCA must be incremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeTokens.contractEsMoca + esMocaAmt, "Contract esMOCA must be incremented");

        // 2. Global State
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeGlobal.veGlobal.bias + expectedBias, "veGlobal bias must be incremented");
        assertEq(slope, beforeGlobal.veGlobal.slope + expectedSlope, "veGlobal slope must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeGlobal.TOTAL_LOCKED_MOCA + mocaAmt, "Total Locked MOCA must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeGlobal.TOTAL_LOCKED_ESMOCA + esMocaAmt, "Total Locked esMOCA must be incremented");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be incremented");

        // 3. Mappings
        assertEq(veMoca.slopeChanges(expiry), beforeGlobal.slopeChange + expectedSlope, "Slope Changes must be incremented");
        
        // 4. User State [userHistory, userSlopeChanges, userLastUpdatedTimestamp]
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeUser.userHistory.bias + expectedBias, "userHistory Bias must be incremented");
        assertEq(slope, beforeUser.userHistory.slope + expectedSlope, "userHistory Slope must be incremented");
        assertEq(veMoca.userSlopeChanges(user, expiry), beforeUser.userSlopeChange + expectedSlope, "userSlopeChanges must be incremented");
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
        assertEq(len, 1, "Lock History Length must be 1");
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, 0);
        assertEq(cp.veBalance.bias, expectedBias, "Lock History: Checkpoint Bias must be incremented");
        assertEq(cp.veBalance.slope, expectedSlope, "Lock History: Checkpoint Slope must be incremented");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp must be incremented");

        // 7. view functions
        _verifyUserVotingPower(user, lock, beforeUser, beforeLock, true);
    }

    function _verifyUserVotingPower(
        address user, 
        DataTypes.Lock memory lock, 
        UserStateSnapshot memory beforeUser,
        LockStateSnapshot memory beforeLock,
        bool isNewLock
    ) internal {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 userVotingPower = veMoca.balanceOfAt(user, currentTimestamp, false);
        uint128 newLockVotingPower = getLockVotingPowerAt(lock.lockId, currentTimestamp);

        if (isNewLock) {
            // createLock: user VP increases by full lock VP
            assertEq(userVotingPower, beforeUser.userVotingPower + newLockVotingPower, "Voting Power must be incremented (new lock)");
        } else {
            // increaseAmount/increaseDuration: user VP increases by lock VP delta
            uint128 oldLockVotingPower = getValueAt(convertToVeBalance(beforeLock.lock), currentTimestamp);
            uint128 lockVPDelta = newLockVotingPower - oldLockVotingPower;
            assertEq(userVotingPower, beforeUser.userVotingPower + lockVPDelta, "Voting Power must be incremented (modify lock)");
        }
    }

    function _verifyLockVotingPower(DataTypes.Lock memory lock, LockStateSnapshot memory beforeLock, bool isIncreaseAmount) internal {
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // Skip if lock is expired
        if (lock.expiry <= currentTimestamp) {
            assertEq(getLockVotingPowerAt(lock.lockId, currentTimestamp), 0, "Expired lock should have 0 VP");
            return;
        }
        
        // 1. Calculate before voting power from saved state
        uint128 beforeVotingPower = 0;
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
        uint128 actualVotingPower = getLockVotingPowerAt(lock.lockId, currentTimestamp);
        
        // 5. Verify actual matches expected
        assertEq(actualVotingPower, expectedVotingPower, "Actual VP must match expected");
        
        // 6. Verify voting power increased
        assertGt(actualVotingPower, beforeVotingPower, "Voting power must have increased");
    }

    function verifyIncreaseAmount(
        StateSnapshot memory beforeState,
        uint128 mocaAmt,
        uint128 esMocaAmt
    ) internal {
        // Derive from beforeState.lock
        bytes32 lockId = beforeState.lock.lock.lockId;
        uint128 expiry = beforeState.lock.lock.expiry;
        address user = beforeState.lock.lock.owner;
        uint128 currentEpochStart = getCurrentEpochStart();

        // Calculate expected values the way the contract does (from totals, not deltas)
        // The contract recalculates the entire lock's slope from the new total amounts
        uint128 newLockTotalMoca = beforeState.lock.lock.moca + mocaAmt;
        uint128 newLockTotalEsMoca = beforeState.lock.lock.esMoca + esMocaAmt;
        uint128 newLockSlope = (newLockTotalMoca + newLockTotalEsMoca) / MAX_LOCK_DURATION;
        uint128 newLockBias = newLockSlope * expiry;
        
        // Delta is the difference between new and old lock veBalance
        uint128 oldLockSlope = (beforeState.lock.lock.moca + beforeState.lock.lock.esMoca) / MAX_LOCK_DURATION;
        uint128 oldLockBias = oldLockSlope * expiry;
        
        uint128 expectedSlopeDelta = newLockSlope - oldLockSlope;
        uint128 expectedBiasDelta = newLockBias - oldLockBias;
        
        // 1. Tokens
        assertEq(user.balance, beforeState.tokens.userMoca - mocaAmt, "User MOCA must be decremented");
        assertEq(esMoca.balanceOf(user), beforeState.tokens.userEsMoca - esMocaAmt, "User esMOCA must be decremented");
        assertEq(address(veMoca).balance, beforeState.tokens.contractMoca + mocaAmt, "Contract MOCA must be incremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokens.contractEsMoca + esMocaAmt, "Contract esMOCA must be incremented");

        // 2. Global State
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.global.veGlobal.bias + expectedBiasDelta, "veGlobal bias must be incremented");
        assertEq(slope, beforeState.global.veGlobal.slope + expectedSlopeDelta, "veGlobal slope must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA + mocaAmt, "Total Locked MOCA must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA + esMocaAmt, "Total Locked esMOCA must be incremented");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be updated");

        // 3. Global Mappings
        assertEq(veMoca.slopeChanges(expiry), beforeState.global.slopeChange + expectedSlopeDelta, "Slope Changes must be incremented");

        // 4. User State [userHistory, userSlopeChanges, userLastUpdatedTimestamp]
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeState.user.userHistory.bias + expectedBiasDelta, "userHistory Bias must be incremented");
        assertEq(slope, beforeState.user.userHistory.slope + expectedSlopeDelta, "userHistory Slope must be incremented");
        assertEq(veMoca.userSlopeChanges(user, expiry), beforeState.user.userSlopeChange + expectedSlopeDelta, "userSlopeChanges must be incremented");
        assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be updated");

        // 5. Lock
        DataTypes.Lock memory lock = getLock(lockId);
        assertEq(lock.lockId, lockId, "Lock ID must match");
        assertEq(lock.owner, user, "Lock Owner must match");
        assertEq(lock.delegate, beforeState.lock.lock.delegate, "Lock Delegate must be unchanged");
        assertEq(lock.moca, beforeState.lock.lock.moca + mocaAmt, "Lock Moca must be incremented");
        assertEq(lock.esMoca, beforeState.lock.lock.esMoca + esMocaAmt, "Lock esMoca must be incremented");
        assertEq(lock.expiry, expiry, "Lock Expiry must be unchanged");
        assertEq(lock.isUnlocked, beforeState.lock.lock.isUnlocked, "Lock Unlocked must be unchanged");
        
        // 6. Lock History (checkpoint updated in-place if same epoch, new checkpoint only if different epoch)
        uint256 len = veMoca.getLockHistoryLength(lockId);
        // Same epoch = overwrite existing checkpoint (length unchanged) | Different epoch = push new checkpoint (length +1)
        if (beforeState.lock.lockHistory[beforeState.lock.lockHistory.length - 1].lastUpdatedAt == currentEpochStart) {
            // Same epoch: length unchanged, checkpoint overwritten
            assertEq(len, beforeState.lock.lockHistory.length, "Lock History Length unchanged (same epoch)");
        } else {
            // Different epoch: new checkpoint pushed
            assertEq(len, beforeState.lock.lockHistory.length + 1, "Lock History Length must be incremented (new epoch)");
        }

        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        // Use the recalculated total veBalance for checkpoint verification
        assertEq(cp.veBalance.bias, newLockBias, "Lock History: Checkpoint Bias must reflect total");
        assertEq(cp.veBalance.slope, newLockSlope, "Lock History: Checkpoint Slope must reflect total");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp must be updated");
        
        // 7. View functions
        _verifyUserVotingPower(user, lock, beforeState.user, beforeState.lock, false);
        _verifyLockVotingPower(lock, beforeState.lock, true);  // true = increaseAmount
    }

    function verifyIncreaseDuration(
        StateSnapshot memory beforeState, 
        uint128 newExpiry
    ) internal {
        TokensSnapshot memory beforeTokens = beforeState.tokens;
        GlobalStateSnapshot memory beforeGlobal = beforeState.global;
        UserStateSnapshot memory beforeUser = beforeState.user;
        LockStateSnapshot memory beforeLock = beforeState.lock;
        
        // Derive from beforeLock
        bytes32 lockId = beforeLock.lock.lockId;
        uint128 oldExpiry = beforeLock.lock.expiry;
        address user = beforeLock.lock.owner;
        uint128 currentEpochStart = getCurrentEpochStart();

        uint128 mocaAmt = beforeLock.lock.moca;
        uint128 esMocaAmt = beforeLock.lock.esMoca;
        
        // Expected Deltas
        uint128 lockSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 biasIncrease = lockSlope * (newExpiry - oldExpiry);

        // 1. Tokens (Should be unchanged)
        assertEq(user.balance, beforeTokens.userMoca, "User MOCA must be unchanged");
        assertEq(esMoca.balanceOf(user), beforeTokens.userEsMoca, "User esMOCA must be unchanged");
        assertEq(address(veMoca).balance, beforeTokens.contractMoca, "Contract MOCA must be unchanged");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeTokens.contractEsMoca, "Contract esMOCA must be unchanged");

        // 2. Global State
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeGlobal.veGlobal.bias + biasIncrease, "veGlobal bias must be incremented");
        assertEq(slope, beforeGlobal.veGlobal.slope, "veGlobal slope must be unchanged");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeGlobal.TOTAL_LOCKED_MOCA, "Total Locked MOCA must be unchanged");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeGlobal.TOTAL_LOCKED_ESMOCA, "Total Locked esMOCA must be unchanged");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be updated");

        // 3. Global Mappings (Slope Changes)
        // Old expiry slope change should decrease
        assertEq(veMoca.slopeChanges(oldExpiry), beforeGlobal.slopeChange - lockSlope, "Slope Change (Old Expiry) must be decremented");
        // New expiry slope change should increase
        assertEq(veMoca.slopeChanges(newExpiry), beforeGlobal.slopeChangeNewExpiry + lockSlope, "Slope Change (New Expiry) must be incremented");

        // 4. User State
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeUser.userHistory.bias + biasIncrease, "User History Bias must be incremented");
        assertEq(slope, beforeUser.userHistory.slope, "User History Slope must be unchanged");
        assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "User LastUpdated must be updated");
        
        // 5. Lock
        DataTypes.Lock memory lock = getLock(lockId);
        assertEq(lock.lockId, lockId, "Lock ID must match");
        assertEq(lock.owner, user, "Lock Owner must match");
        assertEq(lock.delegate, beforeLock.lock.delegate, "Lock Delegate must be unchanged");
        assertEq(lock.moca, mocaAmt, "Lock Moca must be unchanged");
        assertEq(lock.esMoca, esMocaAmt, "Lock esMoca must be unchanged");
        assertEq(lock.expiry, newExpiry, "Lock Expiry must be updated");
        assertEq(lock.isUnlocked, beforeLock.lock.isUnlocked, "Lock Unlocked must be unchanged");

        // 6. Lock History (checkpoint updated in-place if same epoch, new checkpoint only if different epoch)
        uint256 len = veMoca.getLockHistoryLength(lockId);
        // Same epoch = overwrite existing checkpoint (length unchanged) | Different epoch = push new checkpoint (length +1)
        if (beforeState.lock.lockHistory[beforeState.lock.lockHistory.length - 1].lastUpdatedAt == currentEpochStart) {
            // Same epoch: length unchanged, checkpoint overwritten
            assertEq(len, beforeState.lock.lockHistory.length, "Lock History Length unchanged (same epoch)");
        } else {
            // Different epoch: new checkpoint pushed
            assertEq(len, beforeState.lock.lockHistory.length + 1, "Lock History Length must be incremented (new epoch)");
        }
        
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        DataTypes.VeBalance memory newVeBalance = convertToVeBalance(lock);
        assertEq(cp.veBalance.bias, newVeBalance.bias, "Lock History: Checkpoint Bias must reflect new expiry");
        assertEq(cp.veBalance.slope, newVeBalance.slope, "Lock History: Checkpoint Slope must reflect new expiry (same slope)");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp must be updated");

        // 7. View functions
        _verifyUserVotingPower(user, lock, beforeUser, beforeLock, false);
        _verifyLockVotingPower(lock, beforeLock, false); // false = increaseDuration
    }

    function verifyUnlock(StateSnapshot memory beforeState) internal {
        // Derive from beforeState.lock
        bytes32 lockId = beforeState.lock.lock.lockId;
        uint128 expiry = beforeState.lock.lock.expiry;
        address user = beforeState.lock.lock.owner;
        uint128 currentEpochStart = getCurrentEpochStart();
        uint128 currentTimestamp = uint128(block.timestamp);
        
        uint128 mocaAmt = beforeState.lock.lock.moca;
        uint128 esMocaAmt = beforeState.lock.lock.esMoca;

        // 1. Tokens (User receives tokens back)
        assertEq(user.balance, beforeState.tokens.userMoca + mocaAmt, "User MOCA must be incremented");
        assertEq(esMoca.balanceOf(user), beforeState.tokens.userEsMoca + esMocaAmt, "User esMOCA must be incremented");
        assertEq(address(veMoca).balance, beforeState.tokens.contractMoca - mocaAmt, "Contract MOCA must be decremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokens.contractEsMoca - esMocaAmt, "Contract esMOCA must be decremented");

        // 2. Global State
        // Note: veGlobal is updated via _updateAccountAndGlobalAndPendingDeltas to process any pending slope changes
        // Since the lock is expired, its contribution was already removed when crossing the expiry epoch
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        // The veBalance should remain essentially the same (lock contribution was already 0 due to expiry)
        // But we check it's at least not increased
        assertLe(bias, beforeState.global.veGlobal.bias, "veGlobal bias must not increase");
        assertLe(slope, beforeState.global.veGlobal.slope, "veGlobal slope must not increase");
                
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA - mocaAmt, "Total Locked MOCA must be decremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA - esMocaAmt, "Total Locked esMOCA must be decremented");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdatedTimestamp must be updated");

        // 3. Global Mappings (slopeChanges at expiry - should be unchanged, already processed)
        assertEq(veMoca.slopeChanges(expiry), beforeState.global.slopeChange, "Slope Change at expiry must be unchanged");

        // 4. User State
        (bias, slope) = veMoca.userHistory(user, currentEpochStart);
        // A checkpoint is created/updated at currentEpochStart
        // If beforeState had no checkpoint (0,0), the new values reflect user's remaining locks
        // If beforeState had a checkpoint, the lock's expired contribution was already 0, so values should not increase
        if (beforeState.user.userHistory.bias == 0 && beforeState.user.userHistory.slope == 0) {
            // No checkpoint existed before - new checkpoint created with remaining locks' veBalance
            // Just verify the checkpoint was created and userLastUpdatedTimestamp is updated
            assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be updated");
        } else {
            // Checkpoint existed - since lock was expired, its contribution was already 0
            assertLe(bias, beforeState.user.userHistory.bias, "userHistory Bias must not increase");
            assertLe(slope, beforeState.user.userHistory.slope, "userHistory Slope must not increase");
            assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be updated");
        }

        // 5. Lock State
        DataTypes.Lock memory lock = getLock(lockId);
        assertEq(lock.lockId, lockId, "Lock ID must match");
        assertEq(lock.owner, user, "Lock Owner must match");
        assertEq(lock.delegate, beforeState.lock.lock.delegate, "Lock Delegate must be unchanged");
        assertEq(lock.moca, 0, "Lock Moca must be zero after unlock");
        assertEq(lock.esMoca, 0, "Lock esMoca must be zero after unlock");
        assertEq(lock.expiry, expiry, "Lock Expiry must be unchanged");
        assertTrue(lock.isUnlocked, "Lock must be marked as unlocked");

        // 6. Lock History - a checkpoint IS pushed during unlock
        uint256 len = veMoca.getLockHistoryLength(lockId);
        if (beforeState.lock.lockHistory[beforeState.lock.lockHistory.length - 1].lastUpdatedAt == currentEpochStart) {
            // Same epoch: checkpoint overwritten
            assertEq(len, beforeState.lock.lockHistory.length, "Lock History Length unchanged (same epoch)");
        } else {
            // Different epoch: new checkpoint pushed
            assertEq(len, beforeState.lock.lockHistory.length + 1, "Lock History Length must be incremented");
        }
        
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        // Checkpoint is pushed BEFORE lock.moca/esMoca are zeroed, so it captures the original veBalance
        DataTypes.VeBalance memory expectedVeBalance = convertToVeBalance(beforeState.lock.lock);
        assertEq(cp.veBalance.bias, expectedVeBalance.bias, "Lock History: Final checkpoint bias");
        assertEq(cp.veBalance.slope, expectedVeBalance.slope, "Lock History: Final checkpoint slope");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint timestamp");

        // 7. Voting Power (should be 0 since lock was expired)
        uint128 lockVotingPower = getLockVotingPowerAt(lockId, currentTimestamp);
        assertEq(lockVotingPower, 0, "Lock Voting Power must be 0 after unlock");
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
            StateSnapshot memory beforeState = captureAllStates(user1, expectedLockId, expiry, 0);
                TokensSnapshot memory beforeTokens = beforeState.tokens;
                GlobalStateSnapshot memory beforeGlobal = beforeState.global;
                UserStateSnapshot memory beforeUser = beforeState.user;
                LockStateSnapshot memory beforeLock = beforeState.lock;

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

    // ---- state_transition to E2: cross an epoch boundary; to check totalSupplyAt  ----
    
    // note: totalSupplyAt is only updated after crossing epoch boundary
    function test_totalSupplyAt_CrossEpochBoundary_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 1, "Current epoch number is 1");

        // 1) Capture State
        GlobalStateSnapshot memory beforeGlobal = captureGlobalState(lock1_Expiry, 0);
        assertEq(beforeGlobal.totalSupplyAt, 0, "totalSupplyAt is 0");

        // 2) warp to be within Epoch 2
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // 3) cronjob: Update State [updates global and user states]
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](1);
            accounts[0] = user1;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
        vm.stopPrank();

        // 4) Capture State
        GlobalStateSnapshot memory afterGlobal = captureGlobalState(lock1_Expiry, 0);

        // calc. expected totalSupplyAt [account for decay till epoch2StartTimestamp]
        uint128 expectedTotalSupplyAt = getValueAt(beforeGlobal.veGlobal, epoch2StartTimestamp);

        // 5) Verify: Bias & slope would not change [since no new locks created]
        assertEq(afterGlobal.veGlobal.bias, beforeGlobal.veGlobal.bias, "veGlobal bias");
        assertEq(afterGlobal.veGlobal.slope, beforeGlobal.veGlobal.slope, "veGlobal slope");
        
        // 6) Verify: totalSupplyAt is > 0 after epoch boundary (calculated) & (veMoca.totalSupplyAtTimestamp())
        assertEq(afterGlobal.totalSupplyAt, expectedTotalSupplyAt, "totalSupplyAt is > 0 after epoch boundary (calculated)");
        assertEq(afterGlobal.totalSupplyAt, veMoca.totalSupplyAtTimestamp(epoch2StartTimestamp), "totalSupplyAt is > 0 after epoch boundary (veMoca.totalSupplyAtTimestamp())");
    }
}


// note: state is updated as per E2, via cronjob update
abstract contract StateE2_CronJobUpdatesState is StateE1_User1_CreateLock1 {
    
    StateSnapshot public epoch1_AfterLock1Creation;
    StateSnapshot public epoch2_AfterCronJobUpdate;

    function setUp() public virtual override {
        super.setUp();

        // 1) Capture State
        epoch1_AfterLock1Creation = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);

        // 2) warp to be within Epoch 2
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));
        vm.warp(epoch2StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // 3) perform cronjob update State
        vm.startPrank(cronJob);
            address[] memory accounts = new address[](1);
            accounts[0] = user1;
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
        vm.stopPrank();

        // 4) Capture State
        epoch2_AfterCronJobUpdate = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);
    }
}
    
// note: totalSupplyAt is only updated after crossing epoch boundary
contract StateE2_CronJobUpdatesState_Test is StateE2_CronJobUpdatesState {

    function test_totalSupplyAt_CronJobUpdatesState_E2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");
        
        // get global states
        GlobalStateSnapshot memory beforeGlobal = epoch1_AfterLock1Creation.global;
        GlobalStateSnapshot memory afterGlobal = epoch2_AfterCronJobUpdate.global;


        // before: totalSupplyAt is 0; first update cycle has no locks
        assertEq(beforeGlobal.totalSupplyAt, 0, "before: totalSupplyAt is 0");

        // get epoch 2 start timestamp
        uint128 epoch2StartTimestamp = uint128(getEpochStartTimestamp(2));

        // calc. expected totalSupplyAt [decays bias to epoch2StartTimestamp]
        uint128 expectedTotalSupplyAt = getValueAt(afterGlobal.veGlobal, epoch2StartTimestamp);

        // after: totalSupplyAt is > 0; 2nd update registers lock1's veBalance 
        // totalSupplyAt: calculated & veMoca.totalSupplyAtTimestamp()
        assertEq(afterGlobal.totalSupplyAt, expectedTotalSupplyAt, "totalSupplyAt is > 0 after epoch boundary (calculated)");
        assertEq(afterGlobal.totalSupplyAt, veMoca.totalSupplyAtTimestamp(epoch2StartTimestamp), "totalSupplyAt is > 0 after epoch boundary (veMoca.totalSupplyAtTimestamp())");
        
        // veGlobal: bias & slope are always up to date; does not have an epoch lag like totalSupplyAt[]
        assertEq(afterGlobal.veGlobal.bias, beforeGlobal.veGlobal.bias, "veGlobal bias");
        assertEq(afterGlobal.veGlobal.slope, beforeGlobal.veGlobal.slope, "veGlobal slope");
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
        StateSnapshot memory beforeState = captureAllStates(user1, expectedLockId, expiry, 0);
        
        // 4) Execute
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockCreated(expectedLockId, user1, mocaAmount, esMocaAmount, expiry);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.GlobalUpdated(beforeState.global.veGlobal.bias + expectedBias, beforeState.global.veGlobal.slope + expectedSlope);
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.UserUpdated(user1, beforeState.user.userHistory.bias + expectedBias, beforeState.user.userHistory.slope + expectedSlope);

        vm.prank(user1);
        bytes32 actualLockId2 = veMoca.createLock{value: mocaAmount}(expiry, esMocaAmount);

        // 5) Verify
        assertEq(actualLockId2, expectedLockId, "Lock ID Match");
        verifyCreateLock(beforeState, user1, actualLockId2, mocaAmount, esMocaAmount, expiry);
    }

}

// note: lock1 expires at end of epoch 3
// note: lock2 expires at end of epoch 6
abstract contract StateE2_User1_CreateLock2 is StateE2_CronJobUpdatesState {

    bytes32 public lock2_Id;
    uint128 public lock2_Expiry;
    uint128 public lock2_MocaAmount;
    uint128 public lock2_EsMocaAmount;

    StateSnapshot public epoch2_BeforeLock2Creation;
    StateSnapshot public epoch2_AfterLock2Creation;

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
        lock2_Id = generateLockId(block.number, user1); // Salt incremented

        // 3) Capture state
        epoch2_BeforeLock2Creation = captureAllStates(user1, lock2_Id, lock2_Expiry, 0);
        
        // 4) Execute
        vm.prank(user1);
        veMoca.createLock{value: lock2_MocaAmount}(lock2_Expiry, lock2_EsMocaAmount);

        // 5) Capture State
        epoch2_AfterLock2Creation = captureAllStates(user1, lock2_Id, lock2_Expiry, 0);
    }
}

contract StateE2_User1_CreateLock2_Test is StateE2_User1_CreateLock2 {

    // sanity check: verify user's combined voting power = sum of lock voting powers
    function test_User1_CombinedVotingPower_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");
        
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // 1. Get individual lock voting powers
        uint128 lock1VotingPower = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VotingPower = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        
        // 2. Get user's total voting power
        uint128 userTotalVotingPower = veMoca.balanceOfAt(user1, currentTimestamp, false);
        
        // 3. Verify: user's total voting power = lock1 + lock2
        assertEq(userTotalVotingPower, lock1VotingPower + lock2VotingPower, "User voting power must equal sum of lock voting powers");
        
        // 4. Get individual lock veBalances
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);
        
        // 5. Get user's veBalance (userHistory at current epoch start)
        uint128 currentEpochStart = getCurrentEpochStart();
        (uint128 userBias, uint128 userSlope) = veMoca.userHistory(user1, currentEpochStart);
        
        // 6. Verify: user's veBalance = sum of lock veBalances
        uint128 expectedUserBias = lock1VeBalance.bias + lock2VeBalance.bias;
        uint128 expectedUserSlope = lock1VeBalance.slope + lock2VeBalance.slope;
        
        assertEq(userBias, expectedUserBias, "User bias must equal sum of lock biases");
        assertEq(userSlope, expectedUserSlope, "User slope must equal sum of lock slopes");
        
        // 7. Get global veBalance
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        // 8. Verify: global veBalance matches user's veBalance (since user1 is the only user)
        assertEq(globalBias, userBias, "Global bias must equal user bias (single user)");
        assertEq(globalSlope, userSlope, "Global slope must equal user slope (single user)");
        
        // 9. Verify: global total locked amounts
        uint128 expectedTotalLockedMoca = lock1_MocaAmount + lock2_MocaAmount;
        uint128 expectedTotalLockedEsMoca = lock1_EsMocaAmount + lock2_EsMocaAmount;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalLockedMoca, "Total locked MOCA must match sum of locks");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalLockedEsMoca, "Total locked esMOCA must match sum of locks");
        
        // 10. Cross-check: calculate voting power from veBalance and compare
        uint128 calculatedUserVP = getValueAt(DataTypes.VeBalance(userBias, userSlope), currentTimestamp);
        assertEq(userTotalVotingPower, calculatedUserVP, "User VP must match calculated VP from veBalance");

        // 11. Verify balanceAtEpochEnd 
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 user1BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);

        // Calculate expected: both locks' VP at epoch end
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 lock1VPAtEnd = getValueAt(lock1VeBalance, epochEndTimestamp);
        uint128 lock2VPAtEnd = getValueAt(lock2VeBalance, epochEndTimestamp);
        uint128 expectedBalanceAtEnd = lock1VPAtEnd + lock2VPAtEnd;

        assertEq(user1BalanceAtEpochEnd, expectedBalanceAtEnd, "balanceAtEpochEnd must equal sum of locks' VP at epoch end");
    }


    // ---- negative tests: increaseAmount ----

    function testRevert_IncreaseAmount_LockNotOwned() public {
        // lock not owned by user
        vm.expectRevert(Errors.InvalidLockId.selector);

        vm.prank(user2);
        veMoca.increaseAmount(lock2_Id, 100 ether);
    }

    function testRevert_IncreaseAmount_InvalidLockId() public {
        // invalid lock id
        vm.expectRevert(Errors.InvalidLockId.selector);

        vm.prank(user1);
        veMoca.increaseAmount(bytes32(0), 100 ether);
    }

    function testRevert_IncreaseAmount_LockExpiresTooSoon() public {
        // lock expires too soon
        vm.expectRevert(Errors.LockExpiresTooSoon.selector);

        vm.prank(user1);
        veMoca.increaseAmount(lock1_Id, 100 ether);
    }

    function testRevert_IncreaseAmount_InvalidAmount() public {
        // invalid amount
        vm.expectRevert(Errors.InvalidAmount.selector);

        vm.prank(user1);
        veMoca.increaseAmount(lock2_Id, 1 wei);
    }


    // ---- state transition: user increases amount of lock2 in epoch 2 ----

    function test_User1_IncreaseAmountLock2_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // 1) Setup: fund user1 with MOCA and convert to esMOCA [BEFORE capturing state]
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // 2) Test parameters
        uint128 esMocaToAdd = 100 ether;
        uint128 mocaToAdd = 100 ether;

        // 3) Capture State [AFTER funding] - user1's token states
        StateSnapshot memory beforeState = captureAllStates(user1, lock2_Id, lock2_Expiry, 0);

        // 4) Calculate expected values the way the contract does (from totals, not deltas)
        // The contract recalculates the entire lock's slope from the new total amounts
        uint128 newLockTotalMoca = beforeState.lock.lock.moca + mocaToAdd;
        uint128 newLockTotalEsMoca = beforeState.lock.lock.esMoca + esMocaToAdd;
        uint128 newLockSlope = (newLockTotalMoca + newLockTotalEsMoca) / MAX_LOCK_DURATION;
        uint128 newLockBias = newLockSlope * lock2_Expiry;
        
        // Delta is the difference between new and old lock veBalance
        uint128 oldLockSlope = (beforeState.lock.lock.moca + beforeState.lock.lock.esMoca) / MAX_LOCK_DURATION;
        uint128 oldLockBias = oldLockSlope * lock2_Expiry;
        
        uint128 slopeDelta = newLockSlope - oldLockSlope;
        uint128 biasDelta = newLockBias - oldLockBias;

        // 5) Expect events (order must match contract emission order)
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.GlobalUpdated(
            beforeState.global.veGlobal.bias + biasDelta, 
            beforeState.global.veGlobal.slope + slopeDelta
        );
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.UserUpdated(
            user1, 
            beforeState.user.userHistory.bias + biasDelta, 
            beforeState.user.userHistory.slope + slopeDelta
        );
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockAmountIncreased(lock2_Id, user1, address(0), mocaToAdd, esMocaToAdd);

        // 6) Execute
        vm.prank(user1);
        veMoca.increaseAmount{value: mocaToAdd}(lock2_Id, esMocaToAdd);

        // 7) Verify
        verifyIncreaseAmount(beforeState, mocaToAdd, esMocaToAdd);

        // 8) Extra Check: User's total voting power = lock1 VP + lock2 VP (after increase)
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 userVotingPower_After = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 lock1VotingPower = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VotingPower_After = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        
        assertEq(userVotingPower_After, lock1VotingPower + lock2VotingPower_After, "User VP must equal sum of lock VPs");
        
        // 9) Verify lock2's VP increased
        assertGt(lock2VotingPower_After, beforeState.lock.lockVotingPower, "Lock2 VP must have increased");
    }
}

abstract contract StateE2_User1_IncreaseAmountLock2 is StateE2_User1_CreateLock2 {

    StateSnapshot public epoch2_BeforeLock2IncreaseAmount;
    StateSnapshot public epoch2_AfterLock2IncreaseAmount;

    function setUp() public virtual override {
        super.setUp();

        // 1) Setup: fund user1 with MOCA and convert to esMOCA [BEFORE capturing state]
        vm.startPrank(user1);
            vm.deal(user1, 200 ether);
            esMoca.escrowMoca{value: 100 ether}();
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // 2) Test parameters
        uint128 esMocaToAdd = 100 ether;
        uint128 mocaToAdd = 100 ether;

        // 3) Capture State
        epoch2_BeforeLock2IncreaseAmount = captureAllStates(user1, lock2_Id, lock2_Expiry, 0);

        // 4) Execute
        vm.prank(user1);
        veMoca.increaseAmount{value: mocaToAdd}(lock2_Id, esMocaToAdd);

        // 5) Capture State
        epoch2_AfterLock2IncreaseAmount = captureAllStates(user1, lock2_Id, lock2_Expiry, 0);
    }
}

contract StateE2_User1_IncreaseAmountLock2_Test is StateE2_User1_IncreaseAmountLock2 {

    /**
     * Test verifies the following after increasing lock2's amount in epoch 2:
         
         1. State changes via verifyIncreaseAmount
         2. Lock2 VP increased after the amount increase
         3. Lock1 VP unaffected - isolated from lock2's modification
         4. User total VP = sum of lock VPs - aggregation correctness
         5. Lock2's veBalance reflects the new amounts
         6. User's veBalance = sum of lock veBalances - accounting integrity
         7. Global veBalance = user's veBalance (single user invariant)
         8. Total locked amounts are correctly incremented
         9. Cross-check VP calculation - veBalance → VP consistency
         10. Global slopeChanges at each expiry timestamp
         11. User slopeChanges at each expiry timestamp
         12. VP delta consistency - user VP increase equals lock2 VP increase
     */
    function test_User1VotingPower_AfterIncreaseAmountLock2_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        uint128 esMocaToAdd = 100 ether;
        uint128 mocaToAdd = 100 ether;

        // 1) Verify state changes from increaseAmount
        verifyIncreaseAmount(epoch2_BeforeLock2IncreaseAmount, mocaToAdd, esMocaToAdd);

        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();

        // ============ 2) Individual Lock Voting Powers ============
        uint128 lock1VotingPower = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VotingPower_After = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);

        // Verify lock2's VP increased
        assertGt(lock2VotingPower_After, epoch2_BeforeLock2IncreaseAmount.lock.lockVotingPower, "Lock2 VP must have increased");

        // Verify lock1's VP is unaffected (calculate expected from lock1's state)
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        uint128 expectedLock1VP = getValueAt(convertToVeBalance(lock1), currentTimestamp);
        assertEq(lock1VotingPower, expectedLock1VP, "Lock1 VP must be correctly calculated");

        // ============ 3) User's Total Voting Power ============
        uint128 userTotalVotingPower = veMoca.balanceOfAt(user1, currentTimestamp, false);
        
        // User VP must equal sum of individual lock VPs
        assertEq(userTotalVotingPower, lock1VotingPower + lock2VotingPower_After, "User VP must equal sum of lock VPs");

        // ============ 4) Individual Lock veBalances ============
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);

        // Verify lock2's veBalance reflects the increase
        uint128 expectedLock2Slope = (lock2_MocaAmount + mocaToAdd + lock2_EsMocaAmount + esMocaToAdd) / MAX_LOCK_DURATION;
        uint128 expectedLock2Bias = expectedLock2Slope * lock2_Expiry;
        assertEq(lock2VeBalance.slope, expectedLock2Slope, "Lock2 slope must reflect increased amounts");
        assertEq(lock2VeBalance.bias, expectedLock2Bias, "Lock2 bias must reflect increased amounts");

        // ============ 5) User's veBalance = sum of lock veBalances ============
        (uint128 userBias, uint128 userSlope) = veMoca.userHistory(user1, currentEpochStart);
        
        uint128 expectedUserBias = lock1VeBalance.bias + lock2VeBalance.bias;
        uint128 expectedUserSlope = lock1VeBalance.slope + lock2VeBalance.slope;
        
        assertEq(userBias, expectedUserBias, "User bias must equal sum of lock biases");
        assertEq(userSlope, expectedUserSlope, "User slope must equal sum of lock slopes");

        // ============ 6) Global veBalance matches user's (single user) ============
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        assertEq(globalBias, userBias, "Global bias must equal user bias (single user)");
        assertEq(globalSlope, userSlope, "Global slope must equal user slope (single user)");

        // ============ 7) Global total locked amounts ============
        uint128 expectedTotalLockedMoca = lock1_MocaAmount + lock2_MocaAmount + mocaToAdd;
        uint128 expectedTotalLockedEsMoca = lock1_EsMocaAmount + lock2_EsMocaAmount + esMocaToAdd;
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), expectedTotalLockedMoca, "Total locked MOCA must match sum of locks");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), expectedTotalLockedEsMoca, "Total locked esMOCA must match sum of locks");

        // ============ 8) Cross-check: VP calculated from veBalance matches actual VP ============
        uint128 calculatedUserVP = getValueAt(DataTypes.VeBalance(userBias, userSlope), currentTimestamp);
        assertEq(userTotalVotingPower, calculatedUserVP, "User VP must match calculated VP from veBalance");

        // ============ 9) Verify slopeChanges are correct ============
        // lock1 expires at lock1_Expiry, lock2 expires at lock2_Expiry
        uint128 lock1SlopeChange = veMoca.slopeChanges(lock1_Expiry);
        uint128 lock2SlopeChange = veMoca.slopeChanges(lock2_Expiry);
        
        assertEq(lock1SlopeChange, lock1VeBalance.slope, "Global slopeChange at lock1 expiry must equal lock1 slope");
        assertEq(lock2SlopeChange, lock2VeBalance.slope, "Global slopeChange at lock2 expiry must equal lock2 slope");

        // ============ 10) Verify userSlopeChanges ============
        uint128 userLock1SlopeChange = veMoca.userSlopeChanges(user1, lock1_Expiry);
        uint128 userLock2SlopeChange = veMoca.userSlopeChanges(user1, lock2_Expiry);
        
        assertEq(userLock1SlopeChange, lock1VeBalance.slope, "User slopeChange at lock1 expiry must equal lock1 slope");
        assertEq(userLock2SlopeChange, lock2VeBalance.slope, "User slopeChange at lock2 expiry must equal lock2 slope");

        // ============ 11) Verify voting power increase delta ============
        uint128 oldLock2VP = getValueAt(convertToVeBalance(epoch2_BeforeLock2IncreaseAmount.lock.lock), currentTimestamp);
        uint128 lock2VPDelta = lock2VotingPower_After - oldLock2VP;
        uint128 userVPDelta = userTotalVotingPower - epoch2_BeforeLock2IncreaseAmount.user.userVotingPower;
        
        // The increase in user's VP should equal the increase in lock2's VP
        assertEq(userVPDelta, lock2VPDelta, "User VP increase must equal lock2 VP increase");
        
        // ============ 12) Verify balanceAtEpochEnd increased ============
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 user1BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);

        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 expectedBalanceAtEnd = getValueAt(DataTypes.VeBalance(userBias, userSlope), epochEndTimestamp);

        assertEq(user1BalanceAtEpochEnd, expectedBalanceAtEnd, "balanceAtEpochEnd must match user veBalance at epoch end");
        assertGt(user1BalanceAtEpochEnd, 0, "balanceAtEpochEnd must be > 0");
    }

    // ---- negative tests: increaseDuration ----

    
        function testRevert_IncreaseDuration_LockNotOwned() public {
            // lock not owned by user
            vm.expectRevert(Errors.InvalidLockId.selector);

            vm.prank(user2);
            veMoca.increaseDuration(lock2_Id, EPOCH_DURATION);
        }

        function testRevert_IncreaseDuration_InvalidLockDuration() public {
            // invalid lock duration
            vm.expectRevert(Errors.InvalidLockDuration.selector);

            vm.prank(user1);
            veMoca.increaseDuration(lock2_Id, 0);
        }

        function testRevert_IncreaseDuration_InvalidLockId() public {
            // invalid lock id
            vm.expectRevert(Errors.InvalidLockId.selector);

            vm.prank(user1);
            veMoca.increaseDuration(bytes32(0), 1);
        }

        function testRevert_IncreaseDuration_LockExpiresTooSoon() public {
            // lock expires too soon
            vm.expectRevert(Errors.LockExpiresTooSoon.selector);

            vm.prank(user1);
            veMoca.increaseDuration(lock1_Id, EPOCH_DURATION);
        }

        function testRevert_IncreaseDuration_InvalidEpochTime() public {
            // invalid epoch time
            vm.expectRevert(Errors.InvalidEpochTime.selector);

            vm.prank(user1);
            veMoca.increaseDuration(lock2_Id, 1);
        }

        function testRevert_IncreaseDuration_InvalidExpiry() public {
            // invalid expiry
            vm.expectRevert(Errors.InvalidExpiry.selector);

            vm.prank(user1);
            veMoca.increaseDuration(lock2_Id, MAX_LOCK_DURATION + EPOCH_DURATION);
        }

    // ---- state transition: user increases duration of lock2 in epoch 2 ----

        /** 
         Test verifies the following after increasing lock2's duration in epoch 2:
    
         1. Events emitted in correct order with correct values
         2. State changes via verifyIncreaseDuration
         3. User total VP = sum of lock VPs
         4. Lock2 VP increased after duration extension
         5. Lock1 VP unaffected (isolated from lock2's modification)
         6. Lock2's veBalance reflects new expiry (same slope, higher bias)
         7. User's veBalance = sum of lock veBalances
         8. Global veBalance = user's veBalance (single user invariant)
         9. Total locked amounts unchanged (no token transfers)
         10. Cross-check VP calculation from veBalance
         11. Global slopeChanges moved from old to new expiry
         12. User slopeChanges moved from old to new expiry
         13. VP delta consistency - user VP increase equals lock2 VP increase
        */ 
    function test_User1_IncreaseDurationLock2_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        // 1) Test parameters
        uint128 durationToIncrease = EPOCH_DURATION;
        uint128 newExpiry = lock2_Expiry + durationToIncrease;

        // 2) Capture State [passing newExpiry to capture slopeChangeNewExpiry]
        StateSnapshot memory beforeState = captureAllStates(user1, lock2_Id, lock2_Expiry, newExpiry);

        // 3) Calculate expected values
        // For increaseDuration: slope stays same, bias increases by slope * durationToIncrease
        uint128 lockTotalAmount = beforeState.lock.lock.moca + beforeState.lock.lock.esMoca;
        uint128 lockSlope = lockTotalAmount / MAX_LOCK_DURATION;
        uint128 biasIncrease = lockSlope * durationToIncrease;

        // New lock veBalance after duration increase
        uint128 newLockBias = lockSlope * newExpiry;

        // 4) Expect events (order must match contract emission order)
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.GlobalUpdated(
            beforeState.global.veGlobal.bias + biasIncrease, 
            beforeState.global.veGlobal.slope  // slope unchanged
        );
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.UserUpdated(
            user1, 
            beforeState.user.userHistory.bias + biasIncrease, 
            beforeState.user.userHistory.slope  // slope unchanged
        );
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockDurationIncreased(lock2_Id, user1, address(0), lock2_Expiry, newExpiry);

        // 5) Execute
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, durationToIncrease);

        // 6) Verify state changes
        verifyIncreaseDuration(beforeState, newExpiry);

        // ============ 7) Extra Checks ============
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();

        // 7a) User's total voting power = lock1 VP + lock2 VP (after increase)
        uint128 userVotingPower_After = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 lock1VotingPower = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VotingPower_After = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        
        assertEq(userVotingPower_After, lock1VotingPower + lock2VotingPower_After, "User VP must equal sum of lock VPs");

        // 7b) Verify lock2's VP increased
        assertGt(lock2VotingPower_After, beforeState.lock.lockVotingPower, "Lock2 VP must have increased");

        // 7c) Verify lock1's VP is unaffected
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        uint128 expectedLock1VP = getValueAt(convertToVeBalance(lock1), currentTimestamp);
        assertEq(lock1VotingPower, expectedLock1VP, "Lock1 VP must be correctly calculated");

        // 7d) Individual lock veBalances
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);

        // 7e) Verify lock2's veBalance reflects the new expiry
        assertEq(lock2VeBalance.slope, lockSlope, "Lock2 slope must be unchanged");
        assertEq(lock2VeBalance.bias, newLockBias, "Lock2 bias must reflect new expiry");

        // 7f) User's veBalance = sum of lock veBalances
        (uint128 userBias, uint128 userSlope) = veMoca.userHistory(user1, currentEpochStart);
        
        uint128 expectedUserBias = lock1VeBalance.bias + lock2VeBalance.bias;
        uint128 expectedUserSlope = lock1VeBalance.slope + lock2VeBalance.slope;
        
        assertEq(userBias, expectedUserBias, "User bias must equal sum of lock biases");
        assertEq(userSlope, expectedUserSlope, "User slope must equal sum of lock slopes");

        // 7g) Global veBalance matches user's (single user scenario)
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        assertEq(globalBias, userBias, "Global bias must equal user bias (single user)");
        assertEq(globalSlope, userSlope, "Global slope must equal user slope (single user)");

        // 7h) Global total locked amounts (unchanged for increaseDuration)
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA, "Total locked MOCA must be unchanged");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA, "Total locked esMOCA must be unchanged");

        // 7i) Cross-check: VP from veBalance matches actual VP
        uint128 calculatedUserVP = getValueAt(DataTypes.VeBalance(userBias, userSlope), currentTimestamp);
        assertEq(userVotingPower_After, calculatedUserVP, "User VP must match calculated VP from veBalance");

        // 7j) Verify slopeChanges are correct
        // lock1 at lock1_Expiry, lock2 MOVED from lock2_Expiry to newExpiry
        uint128 globalLock1SlopeChange = veMoca.slopeChanges(lock1_Expiry);
        uint128 globalOldLock2SlopeChange = veMoca.slopeChanges(lock2_Expiry);
        uint128 globalNewLock2SlopeChange = veMoca.slopeChanges(newExpiry);
        
        assertEq(globalLock1SlopeChange, lock1VeBalance.slope, "Global slopeChange at lock1 expiry must equal lock1 slope");
        assertEq(globalOldLock2SlopeChange, 0, "Global slopeChange at old lock2 expiry must be 0 (moved)");
        assertEq(globalNewLock2SlopeChange, lock2VeBalance.slope, "Global slopeChange at new lock2 expiry must equal lock2 slope");

        // 7k) Verify userSlopeChanges
        uint128 userLock1SlopeChange = veMoca.userSlopeChanges(user1, lock1_Expiry);
        uint128 userOldLock2SlopeChange = veMoca.userSlopeChanges(user1, lock2_Expiry);
        uint128 userNewLock2SlopeChange = veMoca.userSlopeChanges(user1, newExpiry);
        
        assertEq(userLock1SlopeChange, lock1VeBalance.slope, "User slopeChange at lock1 expiry must equal lock1 slope");
        assertEq(userOldLock2SlopeChange, 0, "User slopeChange at old lock2 expiry must be 0 (moved)");
        assertEq(userNewLock2SlopeChange, lock2VeBalance.slope, "User slopeChange at new lock2 expiry must equal lock2 slope");

        // 7l) Verify voting power increase delta
        uint128 oldLock2VP = getValueAt(convertToVeBalance(beforeState.lock.lock), currentTimestamp);
        uint128 lock2VPDelta = lock2VotingPower_After - oldLock2VP;
        uint128 userVPDelta = userVotingPower_After - beforeState.user.userVotingPower;
        
        // The increase in user's VP should equal the increase in lock2's VP
        assertEq(userVPDelta, lock2VPDelta, "User VP increase must equal lock2 VP increase");
    }
}

// note: lock 1 expires at the end of epoch 3
// note: lock2 now expires at end of epoch 7
// note: lock3 expires at end of epoch 6
abstract contract StateE2_User1_IncreaseDurationLock2 is StateE2_User1_IncreaseAmountLock2 {

    StateSnapshot public epoch2_BeforeLock2IncreaseDuration;
    StateSnapshot public epoch2_AfterLock2IncreaseDuration;

    function setUp() public virtual override {
        super.setUp();

        // 1) Test parameters
        uint128 durationToIncrease = EPOCH_DURATION;
        uint128 newExpiry = lock2_Expiry + durationToIncrease;

        // 2) Capture State
        epoch2_BeforeLock2IncreaseDuration = captureAllStates(user1, lock2_Id, lock2_Expiry, newExpiry);

        // 3) Execute
        vm.prank(user1);
        veMoca.increaseDuration(lock2_Id, durationToIncrease);

        // 4) Capture State
        epoch2_AfterLock2IncreaseDuration = captureAllStates(user1, lock2_Id, lock2_Expiry, newExpiry);
    }
}

contract StateE2_User1_IncreaseDurationLock2_Test is StateE2_User1_IncreaseDurationLock2 {
  
    /**
     * Test verifies the following after increasing lock2's duration in epoch 2:
         
         1. State changes via verifyIncreaseDuration
         2. Lock2 VP increased after the duration increase
         3. Lock1 VP unaffected - isolated from lock2's modification
         4. User total VP = sum of lock VPs - aggregation correctness
         5. Lock2's veBalance reflects the new expiry (same slope, higher bias)
         6. User's veBalance = sum of lock veBalances - accounting integrity
         7. Global veBalance = user's veBalance (single user invariant)
         8. Total locked amounts unchanged (no token transfers)
         9. Cross-check VP calculation - veBalance → VP consistency
         10. Global slopeChanges moved from old to new expiry
         11. User slopeChanges moved from old to new expiry
         12. VP delta consistency - user VP increase equals lock2 VP increase
     */
    function test_User1VotingPower_AfterIncreaseDurationLock2_Epoch2() public {
        assertEq(getCurrentEpochNumber(), 2, "Current epoch number is 2");

        uint128 durationToIncrease = EPOCH_DURATION;
        uint128 newExpiry = lock2_Expiry + durationToIncrease;

        // 1) Verify state changes from increaseDuration
        verifyIncreaseDuration(epoch2_BeforeLock2IncreaseDuration, newExpiry);

        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();

        // ============ 2) Individual Lock Voting Powers ============
        uint128 lock1VotingPower = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VotingPower_After = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);

        // Verify lock2's VP increased
        assertGt(lock2VotingPower_After, epoch2_BeforeLock2IncreaseDuration.lock.lockVotingPower, "Lock2 VP must have increased");

        // Verify lock1's VP is unaffected (calculate expected from lock1's state)
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        uint128 expectedLock1VP = getValueAt(convertToVeBalance(lock1), currentTimestamp);
        assertEq(lock1VotingPower, expectedLock1VP, "Lock1 VP must be correctly calculated");

        // ============ 3) User's Total Voting Power ============
        uint128 userTotalVotingPower = veMoca.balanceOfAt(user1, currentTimestamp, false);
        
        // User VP must equal sum of individual lock VPs
        assertEq(userTotalVotingPower, lock1VotingPower + lock2VotingPower_After, "User VP must equal sum of lock VPs");

        // ============ 4) Individual Lock veBalances ============
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);

        // Verify lock2's veBalance reflects the new expiry
        // For increaseDuration: slope stays same, bias = slope * newExpiry
        uint128 lock2TotalAmount = epoch2_BeforeLock2IncreaseDuration.lock.lock.moca + epoch2_BeforeLock2IncreaseDuration.lock.lock.esMoca;
        uint128 expectedLock2Slope = lock2TotalAmount / MAX_LOCK_DURATION;
        uint128 expectedLock2Bias = expectedLock2Slope * newExpiry;
        assertEq(lock2VeBalance.slope, expectedLock2Slope, "Lock2 slope must be unchanged");
        assertEq(lock2VeBalance.bias, expectedLock2Bias, "Lock2 bias must reflect new expiry");

        // Verify lock2's expiry was updated
        assertEq(lock2.expiry, newExpiry, "Lock2 expiry must be updated");

        // ============ 5) User's veBalance = sum of lock veBalances ============
        (uint128 userBias, uint128 userSlope) = veMoca.userHistory(user1, currentEpochStart);
        
        uint128 expectedUserBias = lock1VeBalance.bias + lock2VeBalance.bias;
        uint128 expectedUserSlope = lock1VeBalance.slope + lock2VeBalance.slope;
        
        assertEq(userBias, expectedUserBias, "User bias must equal sum of lock biases");
        assertEq(userSlope, expectedUserSlope, "User slope must equal sum of lock slopes");

        // ============ 6) Global veBalance matches user's (single user) ============
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        assertEq(globalBias, userBias, "Global bias must equal user bias (single user)");
        assertEq(globalSlope, userSlope, "Global slope must equal user slope (single user)");

        // ============ 7) Global total locked amounts (unchanged for increaseDuration) ============
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), epoch2_BeforeLock2IncreaseDuration.global.TOTAL_LOCKED_MOCA, "Total locked MOCA must be unchanged");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), epoch2_BeforeLock2IncreaseDuration.global.TOTAL_LOCKED_ESMOCA, "Total locked esMOCA must be unchanged");

        // ============ 8) Cross-check: VP from veBalance matches actual VP ============
        uint128 calculatedUserVP = getValueAt(DataTypes.VeBalance(userBias, userSlope), currentTimestamp);
        assertEq(userTotalVotingPower, calculatedUserVP, "User VP must match calculated VP from veBalance");

        // ============ 9) Verify slopeChanges MOVED from old to new expiry ============
        // lock1 stays at lock1_Expiry, lock2 MOVED from lock2_Expiry to newExpiry
        uint128 globalLock1SlopeChange = veMoca.slopeChanges(lock1_Expiry);
        uint128 globalOldLock2SlopeChange = veMoca.slopeChanges(lock2_Expiry);
        uint128 globalNewLock2SlopeChange = veMoca.slopeChanges(newExpiry);
        
        assertEq(globalLock1SlopeChange, lock1VeBalance.slope, "Global slopeChange at lock1 expiry must equal lock1 slope");
        assertEq(globalOldLock2SlopeChange, 0, "Global slopeChange at old lock2 expiry must be 0 (moved)");
        assertEq(globalNewLock2SlopeChange, lock2VeBalance.slope, "Global slopeChange at new lock2 expiry must equal lock2 slope");

        // ============ 10) Verify userSlopeChanges MOVED ============
        uint128 userLock1SlopeChange = veMoca.userSlopeChanges(user1, lock1_Expiry);
        uint128 userOldLock2SlopeChange = veMoca.userSlopeChanges(user1, lock2_Expiry);
        uint128 userNewLock2SlopeChange = veMoca.userSlopeChanges(user1, newExpiry);
        
        assertEq(userLock1SlopeChange, lock1VeBalance.slope, "User slopeChange at lock1 expiry must equal lock1 slope");
        assertEq(userOldLock2SlopeChange, 0, "User slopeChange at old lock2 expiry must be 0 (moved)");
        assertEq(userNewLock2SlopeChange, lock2VeBalance.slope, "User slopeChange at new lock2 expiry must equal lock2 slope");

        // ============ 11) Verify voting power increase delta ============
        uint128 oldLock2VP = getValueAt(convertToVeBalance(epoch2_BeforeLock2IncreaseDuration.lock.lock), currentTimestamp);
        uint128 lock2VPDelta = lock2VotingPower_After - oldLock2VP;
        uint128 userVPDelta = userTotalVotingPower - epoch2_BeforeLock2IncreaseDuration.user.userVotingPower;
        
        // The increase in user's VP should equal the increase in lock2's VP
        assertEq(userVPDelta, lock2VPDelta, "User VP increase must equal lock2 VP increase");

        // ============ 12) Verify token balances unchanged ============
        assertEq(user1.balance, epoch2_BeforeLock2IncreaseDuration.tokens.userMoca, "User MOCA balance must be unchanged");
        assertEq(esMoca.balanceOf(user1), epoch2_BeforeLock2IncreaseDuration.tokens.userEsMoca, "User esMOCA balance must be unchanged");
        assertEq(address(veMoca).balance, epoch2_BeforeLock2IncreaseDuration.tokens.contractMoca, "Contract MOCA balance must be unchanged");
        assertEq(esMoca.balanceOf(address(veMoca)), epoch2_BeforeLock2IncreaseDuration.tokens.contractEsMoca, "Contract esMOCA balance must be unchanged");

        // ============ 13) Verify balanceAtEpochEnd increased ============
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 user1BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));
        uint128 expectedBalanceAtEnd = getValueAt(DataTypes.VeBalance(userBias, userSlope), epochEndTimestamp);

        assertEq(user1BalanceAtEpochEnd, expectedBalanceAtEnd, "balanceAtEpochEnd must match");
    }

    function test_Lock2_Expires_InEpoch7() public {
        //get lock
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        assertEq(lock2.expiry, uint128(getEpochEndTimestamp(7)), "Lock2 expiry must be at the end of epoch 7");
    }

    // ---- state transition: user2 creates lock3 ----
    function test_User2_CreatesLock3_InEpoch3() public {

        // ============ 1) Warp to epoch 3 ============

            uint128 epoch3StartTimestamp = uint128(getEpochStartTimestamp(3));
            vm.warp(epoch3StartTimestamp + 1);
            assertEq(getCurrentEpochNumber(), 3, "Current epoch number is 3");

        // ============ 2) Setup: Fund user2 ============
            vm.startPrank(user2);
                vm.deal(user2, 200 ether);
                esMoca.escrowMoca{value: 100 ether}();
                esMoca.approve(address(veMoca), 100 ether);
            vm.stopPrank();
            
        // ============ 3) Test Parameters ============
            // Lock3 must expire at least 3 epochs from now (epoch 3 + 3 = epoch 6 minimum)
            uint128 lock3_Expiry = uint128(getEpochEndTimestamp(6));
            uint128 lock3_MocaAmount = 100 ether;
            uint128 lock3_EsMocaAmount = 100 ether;
            bytes32 expectedLock3Id = generateLockId(block.number, user2);
            
            uint128 expectedSlope = (lock3_MocaAmount + lock3_EsMocaAmount) / MAX_LOCK_DURATION;
            uint128 expectedBias = expectedSlope * lock3_Expiry;

        // ============ 4) Capture State Before ============
            StateSnapshot memory beforeState = captureAllStates(user2, expectedLock3Id, lock3_Expiry, 0);
            
            // Verify user2 has no existing locks/voting power
            assertEq(beforeState.user.userVotingPower, 0, "User2 should have no voting power before lock");
            assertEq(beforeState.user.userHistory.bias, 0, "User2 userHistory bias should be 0");
            assertEq(beforeState.user.userHistory.slope, 0, "User2 userHistory slope should be 0");

        // ============ 5) Expect Events ============
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.LockCreated(expectedLock3Id, user2, lock3_MocaAmount, lock3_EsMocaAmount, lock3_Expiry);
            
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.GlobalUpdated(
                beforeState.global.veGlobal.bias + expectedBias, 
                beforeState.global.veGlobal.slope + expectedSlope
            );
            
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.UserUpdated(user2, expectedBias, expectedSlope);

        // ============ 6) Execute ============
            vm.prank(user2);
            bytes32 actualLock3Id = veMoca.createLock{value: lock3_MocaAmount}(lock3_Expiry, lock3_EsMocaAmount);

        // ============ 7) Verify Lock ID ============
            assertEq(actualLock3Id, expectedLock3Id, "Lock3 ID must match expected");

        // ============ 8) Verify State Changes ============
            verifyCreateLock(beforeState, user2, actualLock3Id, lock3_MocaAmount, lock3_EsMocaAmount, lock3_Expiry);

        // ============ 9) Additional Checks ============
        uint128 currentTimestamp = uint128(block.timestamp);

        // 9a) User2's voting power
        uint128 user2VotingPower = veMoca.balanceOfAt(user2, currentTimestamp, false);
        uint128 expectedUser2VP = expectedSlope * (lock3_Expiry - currentTimestamp);
        assertEq(user2VotingPower, expectedUser2VP, "User2 voting power must match expected");

        // 9b) Lock3 voting power
        uint128 lock3VotingPower = veMoca.getLockVotingPowerAt(actualLock3Id, currentTimestamp);
        assertEq(lock3VotingPower, expectedUser2VP, "Lock3 voting power must equal user2 VP");
        assertEq(lock3VotingPower, user2VotingPower, "Lock3 VP must equal user2 VP");

        // 9c) Global state now includes user2's lock
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        assertEq(globalBias, beforeState.global.veGlobal.bias + expectedBias, "Global bias must be incremented");
        assertEq(globalSlope, beforeState.global.veGlobal.slope + expectedSlope, "Global slope must be incremented");

        // 9d) Total locked amounts increased
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA + lock3_MocaAmount, "Total locked MOCA must include lock3");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA + lock3_EsMocaAmount, "Total locked esMOCA must include lock3");

        // 9e) User1's locks are unaffected
        uint128 user1VotingPower = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 lock1VotingPower = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VotingPower = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        assertEq(user1VotingPower, lock1VotingPower + lock2VotingPower, "User1 VP must equal sum of lock1 + lock2");

        // 9f) Global slopeChanges updated at lock3 expiry
        uint128 slopeChangeAtLock3Expiry = veMoca.slopeChanges(lock3_Expiry);
        assertEq(slopeChangeAtLock3Expiry, beforeState.global.slopeChange + expectedSlope, "SlopeChange at lock3 expiry must be set");

        // 9g) User2 slopeChanges
        uint128 user2SlopeChange = veMoca.userSlopeChanges(user2, lock3_Expiry);
        assertEq(user2SlopeChange, expectedSlope, "User2 slopeChange at lock3 expiry must be set");

        // 9h) Lock3 details
        DataTypes.Lock memory lock3 = getLock(actualLock3Id);
        assertEq(lock3.owner, user2, "Lock3 owner must be user2");
        assertEq(lock3.moca, lock3_MocaAmount, "Lock3 moca amount");
        assertEq(lock3.esMoca, lock3_EsMocaAmount, "Lock3 esMoca amount");
        assertEq(lock3.expiry, lock3_Expiry, "Lock3 expiry");
        assertFalse(lock3.isUnlocked, "Lock3 must not be unlocked");
        assertEq(lock3.delegate, address(0), "Lock3 must not be delegated");
    }    
}

// note: lock 1 expires at the end of epoch 3
// note: lock2 now expires at end of epoch 7
// note: lock3 expires at end of epoch 6
abstract contract StateE3_User2_CreateLock3 is StateE2_User1_IncreaseDurationLock2 {

    bytes32 public lock3_Id;
    uint128 public lock3_Expiry;
    uint128 public lock3_MocaAmount;
    uint128 public lock3_EsMocaAmount;
    uint128 public lock3_CurrentEpochStart;
    DataTypes.VeBalance public lock3_VeBalance;

    StateSnapshot public epoch3_BeforeLock3Creation;
    StateSnapshot public epoch3_AfterLock3Creation;

    function setUp() public virtual override {
        super.setUp();

        // ============ 1) Warp to Epoch 3 ============
        uint128 epoch3StartTimestamp = uint128(getEpochStartTimestamp(3));
        vm.warp(epoch3StartTimestamp + 1);
        assertEq(getCurrentEpochNumber(), 3, "Current epoch number is 3");

        // ============ 2) Test parameters ============
        lock3_Expiry = uint128(getEpochEndTimestamp(6)); // expires at end of epoch 6
        lock3_MocaAmount = 100 ether;
        lock3_EsMocaAmount = 100 ether;
        lock3_Id = generateLockId(block.number, user2);
        lock3_CurrentEpochStart = getCurrentEpochStart();

        // ============ 3) Setup: Fund user2 ============
        vm.startPrank(user2);
            vm.deal(user2, 200 ether);
            esMoca.escrowMoca{value: lock3_EsMocaAmount}();
            esMoca.approve(address(veMoca), lock3_EsMocaAmount);
        vm.stopPrank();

        // ============ 4) Capture State Before ============
        epoch3_BeforeLock3Creation = captureAllStates(user2, lock3_Id, lock3_Expiry, 0);

        // ============ 5) Execute: user2 creates lock3 ============
        vm.prank(user2);
        bytes32 actualLock3Id = veMoca.createLock{value: lock3_MocaAmount}(lock3_Expiry, lock3_EsMocaAmount);
        
        // Verify lock ID matches expected
        require(actualLock3Id == lock3_Id, "Lock3 ID mismatch");

        // ============ 6) Capture lock3_VeBalance ============
        lock3_VeBalance = veMoca.getLockVeBalance(lock3_Id);

        // ============ 7) Capture State After ============
        epoch3_AfterLock3Creation = captureAllStates(user2, lock3_Id, lock3_Expiry, 0);
    }
}

contract StateE3_User2_CreateLock3_Test is StateE3_User2_CreateLock3 {

    function test_Epoch3() public {
        assertEq(getCurrentEpochNumber(), 3, "Current epoch number is 3");
    }

    function test_Lock3_Created() public {
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        assertEq(lock3.owner, user2, "Lock3 owner must be user2");
        assertEq(lock3.moca, lock3_MocaAmount, "Lock3 moca amount");
        assertEq(lock3.esMoca, lock3_EsMocaAmount, "Lock3 esMoca amount");
        assertEq(lock3.expiry, lock3_Expiry, "Lock3 expiry");
        assertFalse(lock3.isUnlocked, "Lock3 must not be unlocked");
        assertEq(lock3.delegate, address(0), "Lock3 must not be delegated");
    }

    function test_Lock3_Expires_AtEndOfEpoch6() public {
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        assertEq(lock3.expiry, uint128(getEpochEndTimestamp(6)), "Lock3 expiry must be at end of epoch 6");
    }

    function test_User2_VotingPower() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user2VP = veMoca.balanceOfAt(user2, currentTimestamp, false);
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, currentTimestamp);
        
        assertEq(user2VP, lock3VP, "User2 VP must equal lock3 VP");
        assertGt(user2VP, 0, "User2 must have voting power");
    }

    function test_GlobalState_IncludesUser2() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        
        // ============ 1) Individual User Voting Powers ============
        uint128 user1VP = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user2VP = veMoca.balanceOfAt(user2, currentTimestamp, false);
        
        // ============ 2) Individual Lock Voting Powers ============
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VP = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, currentTimestamp);
        
        // Verify user VPs equal sum of their locks
        assertEq(user1VP, lock1VP + lock2VP, "User1 VP must equal lock1 + lock2");
        assertEq(user2VP, lock3VP, "User2 VP must equal lock3");
        
        // ============ 3) Total Voting Power ============
        uint128 totalVotingPower = user1VP + user2VP;
        assertEq(totalVotingPower, lock1VP + lock2VP + lock3VP, "Total VP must equal sum of all locks");
        
        // ============ 4) Lock veBalances (computed from current lock state) ============
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);
        DataTypes.VeBalance memory lock3VeBalance = convertToVeBalance(lock3);
        
        // Verify lock VPs match computed from veBalance
        assertEq(lock1VP, getValueAt(lock1VeBalance, currentTimestamp), "Lock1 VP must match computed from veBalance");
        assertEq(lock2VP, getValueAt(lock2VeBalance, currentTimestamp), "Lock2 VP must match computed from veBalance");
        assertEq(lock3VP, getValueAt(lock3VeBalance, currentTimestamp), "Lock3 VP must match computed from veBalance");
        
        // ============ 5) Global veBalance ============
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        // Global should equal sum of all lock veBalances
        uint128 expectedGlobalBias = lock1VeBalance.bias + lock2VeBalance.bias + lock3VeBalance.bias;
        uint128 expectedGlobalSlope = lock1VeBalance.slope + lock2VeBalance.slope + lock3VeBalance.slope;
        
        assertEq(globalBias, expectedGlobalBias, "Global bias must equal sum of all lock biases");
        assertEq(globalSlope, expectedGlobalSlope, "Global slope must equal sum of all lock slopes");
        
        // Global VP must match total VP
        uint128 globalVP = getValueAt(DataTypes.VeBalance(globalBias, globalSlope), currentTimestamp);
        assertEq(globalVP, totalVotingPower, "Global VP must match total of user VPs");
        
        // ============ 6) Total Locked Amounts (use actual lock data, not constants) ============
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), lock1.moca + lock2.moca + lock3.moca, "Total locked MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), lock1.esMoca + lock2.esMoca + lock3.esMoca, "Total locked esMOCA");
        
        // ============ 7) SlopeChanges at each expiry (use actual lock expiries) ============
        assertEq(veMoca.slopeChanges(lock1.expiry), lock1VeBalance.slope, "SlopeChange at lock1 expiry");
        assertEq(veMoca.slopeChanges(lock2.expiry), lock2VeBalance.slope, "SlopeChange at lock2 expiry");
        assertEq(veMoca.slopeChanges(lock3.expiry), lock3VeBalance.slope, "SlopeChange at lock3 expiry");

        // ============ 8) Verify balanceAtEpochEnd for both users ============
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));

        uint128 user1BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        uint128 user2BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user2, currentEpoch, false);

        // Calculate expected
        uint128 user1ExpectedAtEnd = getValueAt(DataTypes.VeBalance(lock1VeBalance.bias + lock2VeBalance.bias, lock1VeBalance.slope + lock2VeBalance.slope), epochEndTimestamp);
        uint128 user2ExpectedAtEnd = getValueAt(lock3VeBalance, epochEndTimestamp);

        assertEq(user1BalanceAtEpochEnd, user1ExpectedAtEnd, "User1 balanceAtEpochEnd");
        assertEq(user2BalanceAtEpochEnd, user2ExpectedAtEnd, "User2 balanceAtEpochEnd");

        // Total should equal sum
        uint128 totalBalanceAtEnd = user1BalanceAtEpochEnd + user2BalanceAtEpochEnd;
        uint128 expectedTotalAtEnd = getValueAt(DataTypes.VeBalance(globalBias, globalSlope), epochEndTimestamp);
        assertEq(totalBalanceAtEnd, expectedTotalAtEnd, "Total balanceAtEpochEnd must match global");
    }

    function test_totalSupplyAt_UpdatedCorrectly_Epoch3() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // ============ 1) Verify lastUpdatedTimestamp was updated by createLock (lock3) ============
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "lastUpdatedTimestamp must be current epoch start");
        assertEq(getCurrentEpochNumber(), 3, "Must be in epoch 3");
        
        // ============ 2) Get totalSupplyAt for current epoch (stored mapping value) ============
        uint128 totalSupplyStored = veMoca.totalSupplyAt(currentEpochStart);
        
        // ============ 3) Get totalSupplyAtTimestamp (dynamically calculated) ============
        uint128 totalSupplyCalculated = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        // ============ 4) Get all locks' voting power at same timestamp ============
        // In epoch 3: lock1 (user1), lock2 (user1), lock3 (user2) are all active
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VP = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, currentTimestamp);
        
        // All locks should have non-zero VP
        assertGt(lock1VP, 0, "Lock1 VP must be > 0 (still active in epoch 3)");
        assertGt(lock2VP, 0, "Lock2 VP must be > 0");
        assertGt(lock3VP, 0, "Lock3 VP must be > 0");
        
        // ============ 5) Verify totalSupplyAtTimestamp equals sum of all locks' VP ============
        uint128 expectedTotalSupply = lock1VP + lock2VP + lock3VP;
        assertEq(totalSupplyCalculated, expectedTotalSupply, "totalSupplyAtTimestamp must equal sum of all locks' VP");
        
        // ============ 6) Verify via veGlobal ============
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        // Get lock veBalances
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        DataTypes.VeBalance memory lock1VeBalance = convertToVeBalance(lock1);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);
        DataTypes.VeBalance memory lock3VeBalance = convertToVeBalance(lock3);
        
        // Global veBalance should equal sum of all locks
        uint128 expectedGlobalBias = lock1VeBalance.bias + lock2VeBalance.bias + lock3VeBalance.bias;
        uint128 expectedGlobalSlope = lock1VeBalance.slope + lock2VeBalance.slope + lock3VeBalance.slope;
        
        assertEq(globalBias, expectedGlobalBias, "veGlobal bias must equal sum of all locks' biases");
        assertEq(globalSlope, expectedGlobalSlope, "veGlobal slope must equal sum of all locks' slopes");
        
        // ============ 7) Cross-check: VP calculated from veGlobal matches totalSupplyAtTimestamp ============
        uint128 calculatedGlobalVP = getValueAt(DataTypes.VeBalance(globalBias, globalSlope), currentTimestamp);
        assertEq(calculatedGlobalVP, totalSupplyCalculated, "VP from veGlobal must match totalSupplyAtTimestamp");
        
        // ============ 8) Verify stored totalSupplyAt is historical snapshot (before lock3) ============
        // totalSupplyAt[epoch3Start] was booked during epoch2→epoch3 transition, BEFORE lock3 was created
        // totalSupplyAt[epoch3Start] === totalSupplyAt[epoch2End]; reflecting the sum of actions in epoch2
        // So it only reflects lock1 + lock2 at that time
        
        // Calculate what lock1+lock2 VP would be at epoch3Start (without lock3)
        uint128 lock1VpAtEpochStart = getValueAt(lock1VeBalance, currentEpochStart);
        uint128 lock2VpAtEpochStart = getValueAt(lock2VeBalance, currentEpochStart);
        uint128 expectedHistoricalVp = lock1VpAtEpochStart + lock2VpAtEpochStart;
        
        // Note: totalSupplyStored may differ slightly due to when veGlobal was snapshotted vs lock veBalances
        assertLt(totalSupplyStored, totalSupplyCalculated, "Historical totalSupplyAt must be less than current (lock3 not included)");
        
        // Verify totalSupplyAt will be correctly updated at epoch4Start (to include all epoch3 actions)
        // requires warping to epoch4 and triggering a state update
        
        // ============ 9) Verify slope changes are registered correctly ============
        assertEq(veMoca.slopeChanges(lock1.expiry), lock1VeBalance.slope, "SlopeChange at lock1 expiry");
        assertEq(veMoca.slopeChanges(lock2.expiry), lock2VeBalance.slope, "SlopeChange at lock2 expiry");
        assertEq(veMoca.slopeChanges(lock3.expiry), lock3VeBalance.slope, "SlopeChange at lock3 expiry");
        
        // ============ 10) Verify totalSupply increased from before lock3 creation ============
        assertGt(globalBias, epoch3_BeforeLock3Creation.global.veGlobal.bias, "veGlobal bias must have increased after lock3 creation");
        assertGt(globalSlope, epoch3_BeforeLock3Creation.global.veGlobal.slope, "veGlobal slope must have increased after lock3 creation");
        
        // ============ 11) User voting power matches their locks ============
        uint128 user1VP = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 user2VP = veMoca.balanceOfAt(user2, currentTimestamp, false);
        
        assertEq(user1VP, lock1VP + lock2VP, "User1 VP must equal lock1 + lock2");
        assertEq(user2VP, lock3VP, "User2 VP must equal lock3");
        assertEq(user1VP + user2VP, totalSupplyCalculated, "Sum of user VPs must equal totalSupplyAtTimestamp");
    }

    // --- state transition: user1 can unlock lock1 at the end of epoch 3/start of epoch 4; lock1 has expired ----
    function test_User1_UnlocksLock1_InEpoch4() public {
        // ============ 1) Warp to Epoch 4 ============
            uint128 epoch4StartTimestamp = uint128(getEpochStartTimestamp(4));
            vm.warp(epoch4StartTimestamp);
            assertEq(getCurrentEpochNumber(), 4, "Current epoch number is 4");
            assertEq(epoch4StartTimestamp, uint128(getEpochEndTimestamp(3)), "Epoch 4 start timestamp must be at end of epoch 3");
            
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 currentEpochStart = getCurrentEpochStart();
        
        // ============ 2) Verify Lock1 State Before Unlock ============
            DataTypes.Lock memory lock1Before = getLock(lock1_Id);
            assertEq(lock1Before.expiry, uint128(getEpochEndTimestamp(3)), "Lock1 expiry must be at end of epoch 3");
            assertFalse(lock1Before.isUnlocked, "Lock1 must not be unlocked yet");
            assertEq(lock1Before.moca, lock1_MocaAmount, "Lock1 moca amount");
            assertEq(lock1Before.esMoca, lock1_EsMocaAmount, "Lock1 esMoca amount");
        
        // ============ 3) Verify Lock1 Voting Power is 0 (Expired) ============
            uint128 lock1VPBefore = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
            assertEq(lock1VPBefore, 0, "Lock1 voting power must be 0 (expired)");
        
        // ============ 4) Capture State Before Unlock ============
            StateSnapshot memory beforeState = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);
            
            // Store user1's token balances before
            uint256 user1MocaBefore = user1.balance;
            uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
        
        // ============ 5) Expect Events ============
            
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.LockUnlocked(lock1_Id, user1, lock1_MocaAmount, lock1_EsMocaAmount);
        
        // ============ 6) Execute Unlock ============
            vm.prank(user1);
            veMoca.unlock(lock1_Id);
            
        // ============ 7) Verify via verifyUnlock helper ============
            verifyUnlock(beforeState);
        
        // ============ 8) Additional Verifications ============
        
            // 8a. Lock state after unlock
            DataTypes.Lock memory lock1After = getLock(lock1_Id);
            assertTrue(lock1After.isUnlocked, "Lock1 must be marked as unlocked");
            assertEq(lock1After.moca, 0, "Lock1 moca must be 0 after unlock");
            assertEq(lock1After.esMoca, 0, "Lock1 esMoca must be 0 after unlock");
            assertEq(lock1After.owner, user1, "Lock1 owner must be unchanged");
            assertEq(lock1After.expiry, lock1_Expiry, "Lock1 expiry must be unchanged");
            
            // 8b. User1 received tokens back
            assertEq(user1.balance, user1MocaBefore + lock1_MocaAmount, "User1 must receive MOCA back");
            assertEq(esMoca.balanceOf(user1), user1EsMocaBefore + lock1_EsMocaAmount, "User1 must receive esMOCA back");
            
            // 8c. Global totals decreased
            assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA - lock1_MocaAmount,"TOTAL_LOCKED_MOCA must decrease by lock1 amount");
            assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA - lock1_EsMocaAmount,"TOTAL_LOCKED_ESMOCA must decrease by lock1 amount");
            
            // 8d. Lock1 voting power still 0
            uint128 lock1VPAfter = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
            assertEq(lock1VPAfter, 0, "Lock1 voting power must still be 0");
            
            // 8e. User1 still has voting power from lock2
            uint128 user1VPAfter = veMoca.balanceOfAt(user1, currentTimestamp, false);
            uint128 lock2VP = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
            assertEq(user1VPAfter, lock2VP, "User1 VP must equal lock2 VP (lock1 was expired)");
            assertGt(user1VPAfter, 0, "User1 must still have VP from lock2");
            
            // 8f. Lock2 and Lock3 are unaffected
            DataTypes.Lock memory lock2 = getLock(lock2_Id);
            DataTypes.Lock memory lock3 = getLock(lock3_Id);
            assertFalse(lock2.isUnlocked, "Lock2 must not be unlocked");
            assertFalse(lock3.isUnlocked, "Lock3 must not be unlocked");
            assertGt(lock2.moca, 0, "Lock2 must still have moca");
            assertGt(lock3.moca, 0, "Lock3 must still have moca");
        
        // ============ 9) Verify Cannot Unlock Again ============
            vm.expectRevert(Errors.InvalidLockState.selector);
            vm.prank(user1);
            veMoca.unlock(lock1_Id);
        
        // ============ 10) Verify Non-Owner Cannot Unlock (even though already unlocked) ============
            vm.expectRevert(Errors.InvalidOwner.selector);
            vm.prank(user2);
            veMoca.unlock(lock1_Id);
    }

}


// note: lock 1 expires at the end of epoch 3
// note: lock2 now expires at end of epoch 7
// note: lock3 expires at end of epoch 6
abstract contract StateE4_User1_UnlocksLock1 is StateE3_User2_CreateLock3 {

    StateSnapshot public epoch4_BeforeUnlock;
    StateSnapshot public epoch4_AfterUnlock;
    
    // Store user1's token balances before unlock for verification
    uint256 public user1_MocaBalanceBeforeUnlock;
    uint256 public user1_EsMocaBalanceBeforeUnlock;

    function setUp() public virtual override {
        super.setUp();

        // ============ 1) Warp to Epoch 4 ============
        uint128 epoch4StartTimestamp = uint128(getEpochStartTimestamp(4));
        vm.warp(epoch4StartTimestamp);
        assertEq(getCurrentEpochNumber(), 4, "Current epoch number is 4");
        assertEq(epoch4StartTimestamp, uint128(getEpochEndTimestamp(3)), "Epoch 4 start timestamp must be at end of epoch 3");

        // ============ 2) Verify Lock1 is Expired ============
        DataTypes.Lock memory lock1Before = getLock(lock1_Id);
        assertEq(lock1Before.expiry, epoch4StartTimestamp, "Lock1 expiry must equal epoch 4 start");
        assertFalse(lock1Before.isUnlocked, "Lock1 must not be unlocked yet");

        // ============ 3) Capture State Before Unlock ============
        epoch4_BeforeUnlock = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);
        user1_MocaBalanceBeforeUnlock = user1.balance;
        user1_EsMocaBalanceBeforeUnlock = esMoca.balanceOf(user1);

        // ============ 4) Execute Unlock ============
        vm.prank(user1);
        veMoca.unlock(lock1_Id);

        // ============ 5) Capture State After Unlock ============
        epoch4_AfterUnlock = captureAllStates(user1, lock1_Id, lock1_Expiry, 0);
    }
}

contract StateE4_User1_UnlocksLock1_Test is StateE4_User1_UnlocksLock1 {

    function test_Epoch4() public {
        assertEq(getCurrentEpochNumber(), 4, "Current epoch number is 4");
    }

    function test_Lock1_IsUnlocked() public {
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        assertTrue(lock1.isUnlocked, "Lock1 must be unlocked");
        assertEq(lock1.moca, 0, "Lock1 moca must be 0");
        assertEq(lock1.esMoca, 0, "Lock1 esMoca must be 0");
        assertEq(lock1.owner, user1, "Lock1 owner must be unchanged");
        assertEq(lock1.expiry, lock1_Expiry, "Lock1 expiry must be unchanged");
    }

    function test_User1_ReceivedTokensBack() public {
        assertEq(user1.balance, user1_MocaBalanceBeforeUnlock + lock1_MocaAmount, "User1 must receive MOCA back");
        assertEq(esMoca.balanceOf(user1), user1_EsMocaBalanceBeforeUnlock + lock1_EsMocaAmount, "User1 must receive esMOCA back");
    }

    function test_GlobalTotals_Decreased() public {
        assertEq(
            veMoca.TOTAL_LOCKED_MOCA(),
            epoch4_BeforeUnlock.global.TOTAL_LOCKED_MOCA - lock1_MocaAmount,
            "Total locked MOCA must decrease"
        );
        assertEq(
            veMoca.TOTAL_LOCKED_ESMOCA(),
            epoch4_BeforeUnlock.global.TOTAL_LOCKED_ESMOCA - lock1_EsMocaAmount,
            "Total locked esMOCA must decrease"
        );
    }

    function test_Lock1_VotingPower_IsZero() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        assertEq(lock1VP, 0, "Lock1 voting power must be 0");
    }

    function test_User1_VotingPower_OnlyFromLock2() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 user1VP = veMoca.balanceOfAt(user1, currentTimestamp, false);
        uint128 lock2VP = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        
        assertEq(user1VP, lock2VP, "User1 VP must equal lock2 VP only");
        assertGt(user1VP, 0, "User1 must still have VP from lock2");
    }

    function test_Lock2_And_Lock3_Unaffected() public {
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        
        assertFalse(lock2.isUnlocked, "Lock2 must not be unlocked");
        assertFalse(lock3.isUnlocked, "Lock3 must not be unlocked");
        assertGt(lock2.moca, 0, "Lock2 must still have moca");
        assertGt(lock3.moca, 0, "Lock3 must still have moca");
    }

    function test_totalSupplyAt_UpdatedCorrectly_Epoch4() public {
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentEpochStart = getCurrentEpochStart();
        
        // ============ 1) Verify lastUpdatedTimestamp was updated by unlock() ============
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "lastUpdatedTimestamp must be current epoch start");
        
        // ============ 2) Get totalSupplyAt for current epoch ============
        uint128 totalSupply = veMoca.totalSupplyAt(currentEpochStart);
        
        // ============ 3) Get remaining locks' voting power ============
        // lock1 is expired/unlocked (VP = 0)
        // lock2 (user1) and lock3 (user2) are still active
        uint128 lock1VP = veMoca.getLockVotingPowerAt(lock1_Id, currentTimestamp);
        uint128 lock2VP = veMoca.getLockVotingPowerAt(lock2_Id, currentTimestamp);
        uint128 lock3VP = veMoca.getLockVotingPowerAt(lock3_Id, currentTimestamp);
        
        assertEq(lock1VP, 0, "Lock1 VP must be 0 (expired/unlocked)");
        
        // ============ 4) Verify totalSupplyAt equals sum of active locks' VP ============
        uint128 expectedTotalSupply = lock2VP + lock3VP;
        assertEq(totalSupply, expectedTotalSupply, "totalSupplyAt must equal sum of active locks' VP");
        
        // ============ 5) Verify via veGlobal ============
        (uint128 globalBias, uint128 globalSlope) = veMoca.veGlobal();
        
        // Get lock veBalances
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);
        DataTypes.VeBalance memory lock3VeBalance = convertToVeBalance(lock3);
        
        // Global veBalance should equal sum of remaining locks
        uint128 expectedGlobalBias = lock2VeBalance.bias + lock3VeBalance.bias;
        uint128 expectedGlobalSlope = lock2VeBalance.slope + lock3VeBalance.slope;
        
        assertEq(globalBias, expectedGlobalBias, "veGlobal bias must equal sum of active locks' biases");
        assertEq(globalSlope, expectedGlobalSlope, "veGlobal slope must equal sum of active locks' slopes");
        
        // ============ 6) Cross-check: VP calculated from veGlobal matches totalSupply ============
        uint128 calculatedGlobalVP = getValueAt(DataTypes.VeBalance(globalBias, globalSlope), currentTimestamp);
        assertEq(calculatedGlobalVP, totalSupply, "VP from veGlobal must match totalSupplyAt");
        
        // ============ 7) Verify slope changes were processed correctly ============
        // lock1's slopeChange at its expiry should still exist (not cleared by unlock)
        uint128 lock1SlopeChange = veMoca.slopeChanges(lock1_Expiry);
        assertEq(lock1SlopeChange, epoch4_BeforeUnlock.global.slopeChange, "lock1 slopeChange must be unchanged");
        
        // ============ 8) Verify totalSupply decreased from before unlock ============
        // Note: before unlock, veGlobal was stale (not yet processed slope changes)
        // The actual VP before unlock (if calculated) would have been the same as after, because lock1 was already expired and has 0 VP
        // But the stored veGlobal.bias was higher (stale)
        assertLt(globalBias, epoch4_BeforeUnlock.global.veGlobal.bias, "veGlobal bias must have decreased (slope changes processed)");
        assertLt(globalSlope, epoch4_BeforeUnlock.global.veGlobal.slope, "veGlobal slope must have decreased (slope changes processed)");

        // ============ 9) Verify totalSupplyAtTimestamp view function ============
        uint128 totalSupplyAtTs = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        assertEq(totalSupplyAtTs, totalSupply, "totalSupplyAtTimestamp must match totalSupplyAt at epoch start");
        assertEq(totalSupplyAtTs, expectedTotalSupply, "totalSupplyAtTimestamp must equal sum of active locks' VP");
        assertEq(totalSupplyAtTs, calculatedGlobalVP, "totalSupplyAtTimestamp must match VP calculated from veGlobal");

        // ============ 10) Verify balanceAtEpochEnd after unlock ============
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 epochEndTimestamp = uint128(getEpochEndTimestamp(currentEpoch));

        // User1's balance (only lock2 now, lock1 expired/unlocked)
        uint128 user1BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        uint128 expectedUser1AtEnd = getValueAt(lock2VeBalance, epochEndTimestamp);
        assertEq(user1BalanceAtEpochEnd, expectedUser1AtEnd, "User1 balanceAtEpochEnd must only include lock2");

        // User2's balance (lock3)
        uint128 user2BalanceAtEpochEnd = veMoca.balanceAtEpochEnd(user2, currentEpoch, false);
        uint128 expectedUser2AtEnd = getValueAt(lock3VeBalance, epochEndTimestamp);
        assertEq(user2BalanceAtEpochEnd, expectedUser2AtEnd, "User2 balanceAtEpochEnd");

        // Historical check: query epoch 3 (lock1 was still active)
        uint128 user1BalanceAtEpoch3End = veMoca.balanceAtEpochEnd(user1, 3, false);
        assertGt(user1BalanceAtEpoch3End, user1BalanceAtEpochEnd, "User1 had more VP at epoch 3 end (lock1 was active)");
    }

    function test_balanceAtEpochEnd_HistoricalQueries() public {
        // Note: This test runs AFTER lock1 is UNLOCKED (moca=0, esMoca=0)
        // So balanceAtEpochEnd uses CURRENT state where only lock2 (400e) contributes for user1
        
        uint128 epoch1 = 1;
        uint128 epoch2 = 2;
        uint128 epoch3 = 3;
        uint128 currentEpoch = getCurrentEpochNumber(); // epoch 4
        
        // User1's VP is entirely from lock2 (400 ether) - lock1 is unlocked
        // VP decreases for later epochs due to decay (earlier epoch end = higher VP)
        uint128 user1AtEpoch1End = veMoca.balanceAtEpochEnd(user1, epoch1, false);
        uint128 user1AtEpoch2End = veMoca.balanceAtEpochEnd(user1, epoch2, false);
        uint128 user1AtEpoch3End = veMoca.balanceAtEpochEnd(user1, epoch3, false);
        uint128 user1AtEpoch4End = veMoca.balanceAtEpochEnd(user1, currentEpoch, false);
        
        // All should be > 0 (from lock2)
        assertGt(user1AtEpoch1End, 0, "User1 has VP at epoch 1 end (from lock2)");
        assertGt(user1AtEpoch2End, 0, "User1 has VP at epoch 2 end");
        assertGt(user1AtEpoch3End, 0, "User1 has VP at epoch 3 end");
        assertGt(user1AtEpoch4End, 0, "User1 has VP at epoch 4 end");
        
        // VP decreases for later epochs (decay over time)
        assertGt(user1AtEpoch1End, user1AtEpoch2End, "VP decays: epoch1 > epoch2");
        assertGt(user1AtEpoch2End, user1AtEpoch3End, "VP decays: epoch2 > epoch3");
        assertGt(user1AtEpoch3End, user1AtEpoch4End, "VP decays: epoch3 > epoch4");
        
        // User2's VP from lock3 (200 ether)
        uint128 user2AtEpoch3End = veMoca.balanceAtEpochEnd(user2, epoch3, false);
        uint128 user2AtEpoch4End = veMoca.balanceAtEpochEnd(user2, currentEpoch, false);
        
        assertGt(user2AtEpoch3End, 0, "User2 has VP at epoch 3 end (from lock3)");
        assertGt(user2AtEpoch4End, 0, "User2 has VP at epoch 4 end");
        assertGt(user2AtEpoch3End, user2AtEpoch4End, "User2 VP decays: epoch3 > epoch4");
        
        // User2 has VP even in epochs 1 and 2 (lock3 exists NOW and is projected backward)
        // This is because balanceAtEpochEnd uses CURRENT state, not historical
        uint128 user2AtEpoch1End = veMoca.balanceAtEpochEnd(user2, epoch1, false);
        uint128 user2AtEpoch2End = veMoca.balanceAtEpochEnd(user2, epoch2, false);
        assertGt(user2AtEpoch1End, 0, "User2 has VP at epoch 1 end (lock3 projected backward)");
        assertGt(user2AtEpoch2End, 0, "User2 has VP at epoch 2 end");
        
        // Verify no delegated balance (no delegation set up)
        assertEq(veMoca.balanceAtEpochEnd(user1, currentEpoch, true), 0, "User1 has no delegated VP");
        assertEq(veMoca.balanceAtEpochEnd(user2, currentEpoch, true), 0, "User2 has no delegated VP");
    }

    // Note: totalSupplyAt[epochStart] is a HISTORICAL snapshot
    // It's booked when transitioning TO that epoch and reflects the final state of the previous epoch
    // DIFFERENT from balanceAtEpochEnd which uses CURRENT state
    function test_totalSupplyAt_HistoricalQueries() public {
        
        uint128 epoch1Start = uint128(getEpochStartTimestamp(1));
        uint128 epoch2Start = uint128(getEpochStartTimestamp(2));
        uint128 epoch3Start = uint128(getEpochStartTimestamp(3));
        uint128 epoch4Start = uint128(getEpochStartTimestamp(4)); // current epoch
        
        // ============ Query historical totalSupplyAt snapshots ============
        uint128 supplyAtEpoch1 = veMoca.totalSupplyAt(epoch1Start);
        uint128 supplyAtEpoch2 = veMoca.totalSupplyAt(epoch2Start);
        uint128 supplyAtEpoch3 = veMoca.totalSupplyAt(epoch3Start);
        uint128 supplyAtEpoch4 = veMoca.totalSupplyAt(epoch4Start);
        
        // ============ Epoch 1: First epoch, no prior state ============
        // totalSupplyAt[epoch1Start] may be 0 (no prior epoch to snapshot from)
        // or reflect initial state if any locks existed before epoch 1
        
        // ============ Epoch 2: Snapshot includes only lock1 ============
        // lock1 was created in epoch 1, so epoch 2 start snapshot includes lock1
        // lock2 was created DURING epoch 2, so NOT included in epoch 2 snapshot
        assertGt(supplyAtEpoch2, 0, "Epoch 2 snapshot must include lock1");
        
        // ============ Epoch 3: Snapshot includes lock1 + lock2 + increaseAmount + increaseDuration ============
        // All epoch 2 actions are reflected in the epoch 3 start snapshot
        // lock3 was created DURING epoch 3, so NOT included
        assertGt(supplyAtEpoch3, supplyAtEpoch2, "Epoch 3 snapshot > Epoch 2 (lock2 + modifications added)");
        
        // ============ Epoch 4: Snapshot includes lock1 + lock2 + lock3 ============
        // All epoch 3 actions (including lock3 creation) are reflected
        // BUT lock1 EXPIRED at epoch 3 end, so its contribution is 0
        // Note: unlock() happens AFTER epoch 4 snapshot was taken during the transition
        
        // ============ Compare with totalSupplyAtTimestamp (CURRENT state) ============
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 currentTotalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        // totalSupplyAtTimestamp uses CURRENT veGlobal (after unlock)
        // totalSupplyAt[epoch4Start] was booked during epoch3→epoch4 transition
        // They may differ if unlock() modified veGlobal after the snapshot was taken
        
        // ============ Verify decay pattern in snapshots ============
        // Each snapshot is at epoch START, reflecting state at that moment
        // For the same set of locks, later snapshots should show less VP (decay)
        // But if new locks were added, later snapshots could be higher
        
        // From epoch 2 to epoch 3: lock2 + modifications added, so INCREASES
        assertGt(supplyAtEpoch3, supplyAtEpoch2, "Epoch 3 > Epoch 2 due to lock2 additions");
        
        // From epoch 3 to epoch 4: lock3 added BUT lock1 expired at epoch 3 end
        // lock1 was 200 ether (expired), lock3 is 200 ether (new)
        // Net effect depends on lock2's decay vs lock3's addition
        // Since lock2 has 400 ether and lock3 has 200 ether, and lock1 had 0 VP at epoch 3 end (expired)
        // Epoch 4 snapshot should include lock2 + lock3 (600 ether total)
        // vs Epoch 3 snapshot which had lock1 (decayed) + lock2 (400 ether)
        
        // ============ Verify specific lock contributions at each snapshot ============
        // Get current lock states
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        DataTypes.Lock memory lock2 = getLock(lock2_Id);
        DataTypes.Lock memory lock3 = getLock(lock3_Id);
        
        // lock1 is unlocked now (moca=0, esMoca=0)
        assertEq(lock1.moca, 0, "Lock1 is unlocked");
        assertTrue(lock1.isUnlocked, "Lock1 marked as unlocked");
        
        // lock2 and lock3 are still active
        assertGt(lock2.moca, 0, "Lock2 is active");
        assertGt(lock3.moca, 0, "Lock3 is active");
        
        // ============ Verify epoch 4 snapshot matches expected ============
        // At epoch 4 start: lock1 just expired (VP=0), lock2 active, lock3 active
        // totalSupplyAt[epoch4Start] should equal lock2's VP + lock3's VP at epoch 4 start
        DataTypes.VeBalance memory lock2VeBalance = convertToVeBalance(lock2);
        DataTypes.VeBalance memory lock3VeBalance = convertToVeBalance(lock3);
        
        uint128 lock2VpAtEpoch4Start = getValueAt(lock2VeBalance, epoch4Start);
        uint128 lock3VpAtEpoch4Start = getValueAt(lock3VeBalance, epoch4Start);
        uint128 expectedSupplyAtEpoch4 = lock2VpAtEpoch4Start + lock3VpAtEpoch4Start;
        
        assertEq(supplyAtEpoch4, expectedSupplyAtEpoch4, "Epoch 4 snapshot must equal lock2 + lock3 VP at epoch 4 start");
        
        // ============ Log values for debugging ============
        // console2.log("totalSupplyAt[epoch1Start]:", supplyAtEpoch1);
        // console2.log("totalSupplyAt[epoch2Start]:", supplyAtEpoch2);
        // console2.log("totalSupplyAt[epoch3Start]:", supplyAtEpoch3);
        // console2.log("totalSupplyAt[epoch4Start]:", supplyAtEpoch4);
        // console2.log("totalSupplyAtTimestamp(now):", currentTotalSupply);
    }

    // ----- negative tests: unlock -----

        function testRevert_Unlock_InvalidOwner() public {
            vm.expectRevert(Errors.InvalidOwner.selector);
            vm.prank(user1);
            veMoca.unlock(lock3_Id);
        }

        function testRevert_Unlock_InvalidExpiry() public {
            vm.expectRevert(Errors.InvalidExpiry.selector);
            vm.prank(user2);
            veMoca.unlock(lock3_Id);
        }

        function testRevert_Unlock_InvalidLockState() public {
            vm.expectRevert(Errors.InvalidLockState.selector);
            vm.prank(user1);
            veMoca.unlock(lock1_Id);
        }

        function testRevert_CannotUnlockAgain() public {
            vm.expectRevert(Errors.InvalidLockState.selector);
            vm.prank(user1);
            veMoca.unlock(lock1_Id);
        }

        function testRevert_NonOwnerCannotUnlock() public {
            vm.expectRevert(Errors.InvalidOwner.selector);
            vm.prank(user2);
            veMoca.unlock(lock1_Id);
        }


    // ----- state transition: pause contract -----

    function testRevert_EmergencyExitHandlerCannot_EmergencyExit_NotFrozen() public {
        bytes32[] memory lockIds = new bytes32[](1);
        lockIds[0] = lock1_Id;
        
        vm.expectRevert(Errors.NotFrozen.selector);
        vm.prank(emergencyExitHandler);
        veMoca.emergencyExit(lockIds);
    }

    function testRevert_Freeze_WhenNotPaused() public {
        assertFalse(veMoca.paused(), "Contract should not be paused");
        assertEq(veMoca.isFrozen(), 0, "Contract should not be frozen");

        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(globalAdmin);
        veMoca.freeze();
    }

    function test_PauseContract() public {
        vm.startPrank(monitor);
            veMoca.pause();
        vm.stopPrank();
        assertTrue(veMoca.paused(), "Contract should be paused");
    }
}

abstract contract StateE4_PauseContract is StateE4_User1_UnlocksLock1 {

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(monitor);
            veMoca.pause();
        vm.stopPrank();
    }
}

contract StateE4_PauseContract_Test is StateE4_PauseContract {

    // --- negative tests: pause contract -----

        function testRevert_UserCannotPause() public {
            // First unpause to test pausing
            vm.prank(globalAdmin);
            veMoca.unpause();
            
            vm.expectRevert();
            vm.prank(user1);
            veMoca.pause();
        }

        function testRevert_MonitorCannotPauseWhenAlreadyPaused() public {
            // Contract is already paused in setUp
            assertTrue(veMoca.paused(), "Contract should be paused");
            
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(monitor);
            veMoca.pause();
        }

    // --- testRevert: whenNotPaused functions should revert when paused ---

        function testRevert_CreateLock_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user1);
            veMoca.createLock{value: 100 ether}(uint128(getEpochEndTimestamp(10)), 0);
        }

        function testRevert_IncreaseAmount_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user1);
            veMoca.increaseAmount{value: 100 ether}(lock2_Id, 0);
        }

        function testRevert_IncreaseDuration_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user1);
            veMoca.increaseDuration(lock2_Id, EPOCH_DURATION);
        }

        function testRevert_Unlock_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user2);
            veMoca.unlock(lock3_Id);
        }

        function testRevert_DelegateLock_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user1);
            veMoca.delegateLock(lock2_Id, user2);
        }

        function testRevert_SwitchDelegate_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user1);
            veMoca.switchDelegate(lock2_Id, user2);
        }

        function testRevert_UndelegateLock_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(user1);
            veMoca.undelegateLock(lock2_Id);
        }

        function testRevert_UpdateAccountsAndPendingDeltas_WhenPaused() public {
            address[] memory accounts = new address[](1);
            accounts[0] = user1;
            
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(cronJob);
            veMoca.updateAccountsAndPendingDeltas(accounts, false);
        }

        function testRevert_UpdateDelegatePairs_WhenPaused() public {
            address[] memory users = new address[](1);
            address[] memory delegates = new address[](1);
            users[0] = user1;
            delegates[0] = user2;
            
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(cronJob);
            veMoca.updateDelegatePairs(users, delegates);
        }

        function testRevert_CreateLockFor_WhenPaused() public {
            address[] memory users = new address[](1);
            uint128[] memory esMocaAmounts = new uint128[](1);
            uint128[] memory mocaAmounts = new uint128[](1);
            users[0] = user1;
            esMocaAmounts[0] = 100 ether;
            
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(cronJob);
            veMoca.createLockFor(users, esMocaAmounts, mocaAmounts, uint128(getEpochEndTimestamp(10)));
        }

        function testRevert_SetMocaTransferGasLimit_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(votingEscrowMocaAdmin);
            veMoca.setMocaTransferGasLimit(100000);
        }

    /*TODO
        function testRevert_DelegateRegistrationStatus_WhenPaused() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(address(votingController));
            veMoca.delegateRegistrationStatus(user1, true);
        }*/

        function testRevert_EmergencyExitHandlerCannot_EmergencyExit_WhenPaused() public {
            bytes32[] memory lockIds = new bytes32[](1);
            lockIds[0] = lock1_Id;
            
            vm.expectRevert(Errors.NotFrozen.selector);
            vm.prank(emergencyExitHandler);
            veMoca.emergencyExit(lockIds);
        }

    // --- negative tests: unpause ---

        function testRevert_MonitorCannotUnpause() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, monitor, veMoca.DEFAULT_ADMIN_ROLE()));
            vm.prank(monitor);
            veMoca.unpause();
        }

        function testRevert_UserCannotUnpause() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, veMoca.DEFAULT_ADMIN_ROLE()));
            vm.prank(user1);
            veMoca.unpause();
        }

        function testRevert_AdminCannotUnpause() public {
            // votingEscrowMocaAdmin is not globalAdmin (DEFAULT_ADMIN_ROLE)
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, votingEscrowMocaAdmin, veMoca.DEFAULT_ADMIN_ROLE()));
            vm.prank(votingEscrowMocaAdmin);
            veMoca.unpause();
        }

    // --- state transition: only globalAdmin can unpause ---

    function test_GlobalAdminCanUnpause() public {
        assertTrue(veMoca.paused(), "Contract should be paused");
        
        vm.prank(globalAdmin);
        veMoca.unpause();
        
        assertFalse(veMoca.paused(), "Contract should be unpaused");
    }

    // --- state transition: globalAdmin can freeze contract -----

    function testRevert_Freeze_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, veMoca.DEFAULT_ADMIN_ROLE()));
        vm.prank(user1);
        veMoca.freeze();
    }

    function test_GlobalAdminCanFreeze() public {
        assertTrue(veMoca.paused(), "Contract should be paused");
        
        vm.expectEmit(true, true, true, true);
        emit Events.ContractFrozen();
        
        vm.prank(globalAdmin);
        veMoca.freeze();
        
        assertTrue(veMoca.isFrozen() == 1, "Contract should be frozen");
    }
}

abstract contract StateE4_FreezeContract is StateE4_PauseContract {

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(globalAdmin);
            veMoca.freeze();
        vm.stopPrank();
    }
}

contract StateE4_FreezeContract_Test is StateE4_FreezeContract {

    // --- sanity checks ---

        function test_ContractIsFrozen() public {
            assertEq(veMoca.isFrozen(), 1, "Contract should be frozen");
            assertTrue(veMoca.paused(), "Contract should be paused");
        }

        function testRevert_Freeze_Twice() public {
            vm.expectRevert(Errors.IsFrozen.selector);
            vm.prank(globalAdmin);
            veMoca.freeze();
        }

        function testRevert_Unpause_WhenFrozen() public {
            vm.expectRevert(Errors.IsFrozen.selector);
            vm.prank(globalAdmin);
            veMoca.unpause();
        }

    // --- negative tests: emergencyExit -----

        function testRevert_UserCannotCallEmergencyExit() public {
            bytes32[] memory lockIds = new bytes32[](1);
            lockIds[0] = lock2_Id;
            
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, 
                    user1, 
                    Constants.EMERGENCY_EXIT_HANDLER_ROLE
                )
            );
            vm.prank(user1);
            veMoca.emergencyExit(lockIds);
        }

        function testRevert_MonitorCannotCallEmergencyExit() public {
            bytes32[] memory lockIds = new bytes32[](1);
            lockIds[0] = lock2_Id;
            
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, 
                    monitor, 
                    Constants.EMERGENCY_EXIT_HANDLER_ROLE
                )
            );
            vm.prank(monitor);
            veMoca.emergencyExit(lockIds);
        }

        function testRevert_GlobalAdminCannotCallEmergencyExit() public {
            bytes32[] memory lockIds = new bytes32[](1);
            lockIds[0] = lock2_Id;
            
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, 
                    globalAdmin, 
                    Constants.EMERGENCY_EXIT_HANDLER_ROLE
                )
            );
            vm.prank(globalAdmin);
            veMoca.emergencyExit(lockIds);
        }

        function testRevert_EmergencyExit_InvalidArray_EmptyLockIds() public {
            bytes32[] memory emptyLockIds = new bytes32[](0);
            
            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(emergencyExitHandler);
            veMoca.emergencyExit(emptyLockIds);
        }

    // --- positive tests: only EMERGENCY_EXIT_HANDLER_ROLE can call emergencyExit ---

    function test_EmergencyExitHandler_CanCallEmergencyExit() public {
        // ============ 1) Capture State Before ============
        DataTypes.Lock memory lock2Before = getLock(lock2_Id);
        assertFalse(lock2Before.isUnlocked, "Lock2 should not be unlocked yet");
        assertGt(lock2Before.moca, 0, "Lock2 should have moca");
        assertGt(lock2Before.esMoca, 0, "Lock2 should have esMoca");
        
        uint256 user1MocaBefore = user1.balance;
        uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
        
        uint128 totalLockedMocaBefore = veMoca.TOTAL_LOCKED_MOCA();
        uint128 totalLockedEsMocaBefore = veMoca.TOTAL_LOCKED_ESMOCA();
        
        uint256 contractMocaBefore = address(veMoca).balance;
        uint256 contractEsMocaBefore = esMoca.balanceOf(address(veMoca));
        
        // ============ 2) Prepare lockIds ============
        bytes32[] memory lockIds = new bytes32[](1);
        lockIds[0] = lock2_Id;
        
        // ============ 3) Expect Event ============
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.EmergencyExit(lockIds, 1, lock2Before.moca, lock2Before.esMoca);
        
        // ============ 4) Execute ============
        vm.prank(emergencyExitHandler);
        (uint256 totalLocks, uint256 totalMoca, uint256 totalEsMoca) = veMoca.emergencyExit(lockIds);
        
        // ============ 5) Verify Return Values ============
        assertEq(totalLocks, 1, "Should process 1 lock");
        assertEq(totalMoca, lock2Before.moca, "Total MOCA returned must match lock2 moca");
        assertEq(totalEsMoca, lock2Before.esMoca, "Total esMOCA returned must match lock2 esMoca");
        
        // ============ 6) Verify Lock State Updated ============
        DataTypes.Lock memory lock2After = getLock(lock2_Id);
        assertTrue(lock2After.isUnlocked, "Lock2 must be marked as unlocked");
        assertEq(lock2After.moca, 0, "Lock2 moca must be 0 after emergency exit");
        assertEq(lock2After.esMoca, 0, "Lock2 esMoca must be 0 after emergency exit");
        assertEq(lock2After.owner, lock2Before.owner, "Lock2 owner must be unchanged");
        assertEq(lock2After.expiry, lock2Before.expiry, "Lock2 expiry must be unchanged");
        assertEq(lock2After.delegate, lock2Before.delegate, "Lock2 delegate must be unchanged");
        
        // ============ 7) Verify Global State Variables Updated ============
        assertEq(
            veMoca.TOTAL_LOCKED_MOCA(), 
            totalLockedMocaBefore - lock2Before.moca, 
            "TOTAL_LOCKED_MOCA must decrease by lock2 moca"
        );
        assertEq(
            veMoca.TOTAL_LOCKED_ESMOCA(), 
            totalLockedEsMocaBefore - lock2Before.esMoca, 
            "TOTAL_LOCKED_ESMOCA must decrease by lock2 esMoca"
        );
        
        // ============ 8) Verify User Received Tokens Back ============
        assertEq(user1.balance, user1MocaBefore + lock2Before.moca, "User1 must receive MOCA back");
        assertEq(esMoca.balanceOf(user1), user1EsMocaBefore + lock2Before.esMoca, "User1 must receive esMOCA back");
        
        // ============ 9) Verify Contract Balances Decreased ============
        assertEq(address(veMoca).balance, contractMocaBefore - lock2Before.moca, "Contract MOCA must decrease");
        assertEq(esMoca.balanceOf(address(veMoca)), contractEsMocaBefore - lock2Before.esMoca, "Contract esMOCA must decrease");
    }

    function test_EmergencyExitHandler_CanExitMultipleLocks() public {
        // ============ 1) Capture State Before ============
        DataTypes.Lock memory lock2Before = getLock(lock2_Id);
        DataTypes.Lock memory lock3Before = getLock(lock3_Id);
        
        assertFalse(lock2Before.isUnlocked, "Lock2 should not be unlocked yet");
        assertFalse(lock3Before.isUnlocked, "Lock3 should not be unlocked yet");
        
        uint256 user1MocaBefore = user1.balance;
        uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
        uint256 user2MocaBefore = user2.balance;
        uint256 user2EsMocaBefore = esMoca.balanceOf(user2);
        
        uint128 totalLockedMocaBefore = veMoca.TOTAL_LOCKED_MOCA();
        uint128 totalLockedEsMocaBefore = veMoca.TOTAL_LOCKED_ESMOCA();
        
        uint256 contractMocaBefore = address(veMoca).balance;
        uint256 contractEsMocaBefore = esMoca.balanceOf(address(veMoca));
        
        // Expected totals
        uint128 expectedTotalMoca = lock2Before.moca + lock3Before.moca;
        uint128 expectedTotalEsMoca = lock2Before.esMoca + lock3Before.esMoca;
        
        // ============ 2) Prepare lockIds ============
        bytes32[] memory lockIds = new bytes32[](2);
        lockIds[0] = lock2_Id;
        lockIds[1] = lock3_Id;
        
        // ============ 3) Expect Event ============
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.EmergencyExit(lockIds, 2, expectedTotalMoca, expectedTotalEsMoca);
        
        // ============ 4) Execute ============
        vm.prank(emergencyExitHandler);
        (uint256 totalLocks, uint256 totalMoca, uint256 totalEsMoca) = veMoca.emergencyExit(lockIds);
        
        // ============ 5) Verify Return Values ============
        assertEq(totalLocks, 2, "Should process 2 locks");
        assertEq(totalMoca, expectedTotalMoca, "Total MOCA must match sum of locks");
        assertEq(totalEsMoca, expectedTotalEsMoca, "Total esMOCA must match sum of locks");
        
        // ============ 6) Verify Lock2 State Updated ============
        DataTypes.Lock memory lock2After = getLock(lock2_Id);
        assertTrue(lock2After.isUnlocked, "Lock2 must be marked as unlocked");
        assertEq(lock2After.moca, 0, "Lock2 moca must be 0");
        assertEq(lock2After.esMoca, 0, "Lock2 esMoca must be 0");
        assertEq(lock2After.owner, lock2Before.owner, "Lock2 owner unchanged");
        
        // ============ 7) Verify Lock3 State Updated ============
        DataTypes.Lock memory lock3After = getLock(lock3_Id);
        assertTrue(lock3After.isUnlocked, "Lock3 must be marked as unlocked");
        assertEq(lock3After.moca, 0, "Lock3 moca must be 0");
        assertEq(lock3After.esMoca, 0, "Lock3 esMoca must be 0");
        assertEq(lock3After.owner, lock3Before.owner, "Lock3 owner unchanged");
        
        // ============ 8) Verify Global State Variables Updated ============
        assertEq(
            veMoca.TOTAL_LOCKED_MOCA(), 
            totalLockedMocaBefore - expectedTotalMoca, 
            "TOTAL_LOCKED_MOCA must decrease by sum of locks' moca"
        );
        assertEq(
            veMoca.TOTAL_LOCKED_ESMOCA(), 
            totalLockedEsMocaBefore - expectedTotalEsMoca, 
            "TOTAL_LOCKED_ESMOCA must decrease by sum of locks' esMoca"
        );
        
        // ============ 9) Verify User1 Received Tokens Back (lock2) ============
        assertEq(user1.balance, user1MocaBefore + lock2Before.moca, "User1 must receive lock2 MOCA");
        assertEq(esMoca.balanceOf(user1), user1EsMocaBefore + lock2Before.esMoca, "User1 must receive lock2 esMOCA");
        
        // ============ 10) Verify User2 Received Tokens Back (lock3) ============
        assertEq(user2.balance, user2MocaBefore + lock3Before.moca, "User2 must receive lock3 MOCA");
        assertEq(esMoca.balanceOf(user2), user2EsMocaBefore + lock3Before.esMoca, "User2 must receive lock3 esMOCA");
        
        // ============ 11) Verify Contract Balances Decreased ============
        assertEq(
            address(veMoca).balance, 
            contractMocaBefore - expectedTotalMoca, 
            "Contract MOCA must decrease by total"
        );
        assertEq(
            esMoca.balanceOf(address(veMoca)), 
            contractEsMocaBefore - expectedTotalEsMoca, 
            "Contract esMOCA must decrease by total"
        );
    }

    function test_EmergencyExit_SkipsAlreadyUnlockedLocks() public {
        // lock1 was already unlocked in StateE4_User1_UnlocksLock1
        DataTypes.Lock memory lock1 = getLock(lock1_Id);
        assertTrue(lock1.isUnlocked, "Lock1 should already be unlocked");
        
        bytes32[] memory lockIds = new bytes32[](1);
        lockIds[0] = lock1_Id;
        
        vm.prank(emergencyExitHandler);
        (uint256 totalLocks, uint256 totalMoca, uint256 totalEsMoca) = veMoca.emergencyExit(lockIds);
        
        // Should skip the already unlocked lock
        assertEq(totalLocks, 0, "Should skip already unlocked lock");
        assertEq(totalMoca, 0, "No MOCA should be returned");
        assertEq(totalEsMoca, 0, "No esMOCA should be returned");
    }
}





/**
others:
 test_CreateLock_EsMocaOnly / test_CreateLock_MocaOnly


 */