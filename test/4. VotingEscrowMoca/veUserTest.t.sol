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
    }


    // ---- negative tests: increaseAmount ----

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

        // ============ 8) Cross-check: VP from veBalance matches actual VP ============
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
    }

    // ---- negative tests: increaseDuration ----

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

/*
abstract contract StateE2_User1_IncreaseDurationLock2 is StateE2_User1_IncreaseDurationLock2 {

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
}*/