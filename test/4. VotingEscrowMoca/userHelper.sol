// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";

import "../utils/TestingHarness.sol";
import {Constants} from "../../src/libraries/Constants.sol";

/**
 * @title UserHelper
 * @notice Helper contract for user-related tests in VotingEscrowMoca
 * @dev Contains epoch math, state snapshots, capture functions, and verify functions
 *      Verify functions are split into smaller sub-functions to avoid stack-too-deep errors
 */
abstract contract UserHelper is Test, TestingHarness {
    using stdStorage for StdStorage;

    // PERIODICITY: does not account for leap year or leap seconds
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

// ================= STATE SNAPSHOTS =================

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
        bytes32 lockId;
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

// ================= CAPTURE FUNCTIONS =================

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
        state.lockId = lockId;
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

// ================= VERIFY CREATE LOCK =================

    function _verifyCreateLockTokens(
        StateSnapshot memory beforeState, 
        address user, 
        uint128 mocaAmt,
        uint128 esMocaAmt
    ) internal view {
        assertEq(user.balance, beforeState.tokens.userMoca - mocaAmt, "User MOCA must be decremented");
        assertEq(esMoca.balanceOf(user), beforeState.tokens.userEsMoca - esMocaAmt, "User esMOCA must be decremented");
        assertEq(address(veMoca).balance, beforeState.tokens.contractMoca + mocaAmt, "Contract MOCA must be incremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokens.contractEsMoca + esMocaAmt, "Contract esMOCA must be incremented");
    }

    function _verifyCreateLockGlobal(
        StateSnapshot memory beforeState, 
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 expiry,
        uint128 currentEpochStart
    ) internal view {
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.global.veGlobal.bias + expectedBias, "veGlobal bias must be incremented");
        assertEq(slope, beforeState.global.veGlobal.slope + expectedSlope, "veGlobal slope must be incremented");
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA + mocaAmt, "Total Locked MOCA must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA + esMocaAmt, "Total Locked esMOCA must be incremented");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be incremented");
    }

    function _verifyCreateLockMappings(
        StateSnapshot memory beforeState, 
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 expiry
    ) internal view {
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        assertEq(veMoca.slopeChanges(expiry), beforeState.global.slopeChange + expectedSlope, "Slope Changes must be incremented");
    }

    function _verifyCreateLockUser(
        StateSnapshot memory beforeState, 
        address user, 
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 expiry,
        uint128 currentEpochStart
    ) internal view {
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        (uint128 bias, uint128 slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeState.user.userHistory.bias + expectedBias, "userHistory Bias must be incremented");
        assertEq(slope, beforeState.user.userHistory.slope + expectedSlope, "userHistory Slope must be incremented");
        
        assertEq(veMoca.userSlopeChanges(user, expiry), beforeState.user.userSlopeChange + expectedSlope, "userSlopeChanges must be incremented");
        assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be incremented");
    }

    function _verifyCreateLockLock(
        bytes32 lockId,
        address user, 
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 expiry
    ) internal view {
        DataTypes.Lock memory lock = getLock(lockId);
        assertEq(lock.owner, user, "Lock Owner");
        assertEq(lock.delegate, address(0), "Lock Delegate");
        assertEq(lock.moca, mocaAmt, "Lock Moca");
        assertEq(lock.esMoca, esMocaAmt, "Lock esMoca");
        assertEq(lock.expiry, expiry, "Lock Expiry");
        assertFalse(lock.isUnlocked, "Lock Unlocked");
    }

    function _verifyCreateLockHistory(
        bytes32 lockId,
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 expiry,
        uint128 currentEpochStart
    ) internal view {
        uint128 expectedSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * expiry;

        uint256 len = veMoca.getLockHistoryLength(lockId);
        assertEq(len, 1, "Lock History Length must be 1");
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, 0);
        assertEq(cp.veBalance.bias, expectedBias, "Lock History: Checkpoint Bias must be incremented");
        assertEq(cp.veBalance.slope, expectedSlope, "Lock History: Checkpoint Slope must be incremented");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp must be incremented");
    }

    function _verifyCreateLockVP(
        address user,
        bytes32 lockId
    ) internal view {
        uint128 ts = uint128(block.timestamp);
        uint128 userVP = veMoca.balanceOfAt(user, ts, false);
        uint128 lockVP = getLockVotingPowerAt(lockId, ts);
        assertGt(userVP, 0, "User must have voting power after createLock");
        assertGt(lockVP, 0, "Lock must have voting power");
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
        
        _verifyCreateLockTokens(beforeState, user, mocaAmt, esMocaAmt);
        _verifyCreateLockGlobal(beforeState, mocaAmt, esMocaAmt, expiry, currentEpochStart);
        _verifyCreateLockMappings(beforeState, mocaAmt, esMocaAmt, expiry);
        _verifyCreateLockUser(beforeState, user, mocaAmt, esMocaAmt, expiry, currentEpochStart);
        _verifyCreateLockLock(lockId, user, mocaAmt, esMocaAmt, expiry);
        _verifyCreateLockHistory(lockId, mocaAmt, esMocaAmt, expiry, currentEpochStart);
        _verifyCreateLockVP(user, lockId);
    }

// ================= VERIFY INCREASE AMOUNT =================

    struct IncreaseAmountDeltas {
        uint128 newLockSlope;
        uint128 newLockBias;
        uint128 expectedSlopeDelta;
        uint128 expectedBiasDelta;
    }

    function _calcIncreaseAmountDeltas(
        StateSnapshot memory beforeState,
        uint128 mocaAmt,
        uint128 esMocaAmt
    ) internal pure returns (IncreaseAmountDeltas memory deltas) {
        uint128 expiry = beforeState.lock.lock.expiry;
        uint128 newLockTotalMoca = beforeState.lock.lock.moca + mocaAmt;
        uint128 newLockTotalEsMoca = beforeState.lock.lock.esMoca + esMocaAmt;
        deltas.newLockSlope = (newLockTotalMoca + newLockTotalEsMoca) / MAX_LOCK_DURATION;
        deltas.newLockBias = deltas.newLockSlope * expiry;
        
        uint128 oldLockSlope = (beforeState.lock.lock.moca + beforeState.lock.lock.esMoca) / MAX_LOCK_DURATION;
        uint128 oldLockBias = oldLockSlope * expiry;
        
        deltas.expectedSlopeDelta = deltas.newLockSlope - oldLockSlope;
        deltas.expectedBiasDelta = deltas.newLockBias - oldLockBias;
    }

    function _verifyIncreaseAmountTokens(
        StateSnapshot memory beforeState,
        address user,
        uint128 mocaAmt,
        uint128 esMocaAmt
    ) internal view {
        assertEq(user.balance, beforeState.tokens.userMoca - mocaAmt, "User MOCA must be decremented");
        assertEq(esMoca.balanceOf(user), beforeState.tokens.userEsMoca - esMocaAmt, "User esMOCA must be decremented");
        assertEq(address(veMoca).balance, beforeState.tokens.contractMoca + mocaAmt, "Contract MOCA must be incremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokens.contractEsMoca + esMocaAmt, "Contract esMOCA must be incremented");
    }

    function _verifyIncreaseAmountGlobal(
        StateSnapshot memory beforeState,
        IncreaseAmountDeltas memory deltas,
        uint128 mocaAmt,
        uint128 esMocaAmt,
        uint128 currentEpochStart
    ) internal view {
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.global.veGlobal.bias + deltas.expectedBiasDelta, "veGlobal bias must be incremented");
        assertEq(slope, beforeState.global.veGlobal.slope + deltas.expectedSlopeDelta, "veGlobal slope must be incremented");
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA + mocaAmt, "Total Locked MOCA must be incremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA + esMocaAmt, "Total Locked esMOCA must be incremented");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global LastUpdated must be updated");
    }

    function _verifyIncreaseAmountMappingsAndUser(
        StateSnapshot memory beforeState,
        IncreaseAmountDeltas memory deltas,
        uint128 currentEpochStart
    ) internal view {
        bytes32 lockId = beforeState.lock.lockId;
        uint128 expiry = beforeState.lock.lock.expiry;
        address user = beforeState.lock.lock.owner;

        // Global Mappings
        assertEq(veMoca.slopeChanges(expiry), beforeState.global.slopeChange + deltas.expectedSlopeDelta, "Slope Changes must be incremented");

        // User State
        (uint128 bias, uint128 slope) = veMoca.userHistory(user, currentEpochStart);
        assertEq(bias, beforeState.user.userHistory.bias + deltas.expectedBiasDelta, "userHistory Bias must be incremented");
        assertEq(slope, beforeState.user.userHistory.slope + deltas.expectedSlopeDelta, "userHistory Slope must be incremented");
        
        assertEq(veMoca.userSlopeChanges(user, expiry), beforeState.user.userSlopeChange + deltas.expectedSlopeDelta, "userSlopeChanges must be incremented");
        assertEq(veMoca.userLastUpdatedTimestamp(user), currentEpochStart, "userLastUpdatedTimestamp must be updated");
    }

    function _verifyIncreaseAmountLock(
        StateSnapshot memory beforeState,
        uint128 mocaAmt,
        uint128 esMocaAmt
    ) internal view {
        bytes32 lockId = beforeState.lock.lockId;
        uint128 expiry = beforeState.lock.lock.expiry;
        address user = beforeState.lock.lock.owner;

        DataTypes.Lock memory lock = getLock(lockId);
        assertEq(lock.owner, user, "Lock Owner must match");
        assertEq(lock.delegate, beforeState.lock.lock.delegate, "Lock Delegate must be unchanged");
        assertEq(lock.moca, beforeState.lock.lock.moca + mocaAmt, "Lock Moca must be incremented");
        assertEq(lock.esMoca, beforeState.lock.lock.esMoca + esMocaAmt, "Lock esMoca must be incremented");
        assertEq(lock.expiry, expiry, "Lock Expiry must be unchanged");
        assertEq(lock.isUnlocked, beforeState.lock.lock.isUnlocked, "Lock Unlocked must be unchanged");
    }

    function _verifyIncreaseAmountHistory(
        StateSnapshot memory beforeState,
        IncreaseAmountDeltas memory deltas,
        uint128 currentEpochStart
    ) internal view {
        bytes32 lockId = beforeState.lock.lockId;
        
        uint256 len = veMoca.getLockHistoryLength(lockId);
        if (beforeState.lock.lockHistory[beforeState.lock.lockHistory.length - 1].lastUpdatedAt == currentEpochStart) {
            assertEq(len, beforeState.lock.lockHistory.length, "Lock History Length unchanged (same epoch)");
        } else {
            assertEq(len, beforeState.lock.lockHistory.length + 1, "Lock History Length must be incremented (new epoch)");
        }

        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        assertEq(cp.veBalance.bias, deltas.newLockBias, "Lock History: Checkpoint Bias must reflect total");
        assertEq(cp.veBalance.slope, deltas.newLockSlope, "Lock History: Checkpoint Slope must reflect total");
        assertEq(cp.lastUpdatedAt, currentEpochStart, "Lock History: Checkpoint Timestamp must be updated");
    }

    function _verifyIncreaseAmountVP(
        StateSnapshot memory beforeState
    ) internal view {
        bytes32 lockId = beforeState.lock.lockId;
        address user = beforeState.lock.lock.owner;
        uint128 ts = uint128(block.timestamp);
        
        uint128 userVP = veMoca.balanceOfAt(user, ts, false);
        uint128 lockVP = getLockVotingPowerAt(lockId, ts);
        assertGt(userVP, 0, "User must have voting power");
        assertGt(lockVP, beforeState.lock.lockVotingPower, "Lock VP must have increased");
    }

    function verifyIncreaseAmount(StateSnapshot memory beforeState, uint128 mocaAmt, uint128 esMocaAmt) internal {
        uint128 currentEpochStart = getCurrentEpochStart();
        address user = beforeState.lock.lock.owner;
        
        IncreaseAmountDeltas memory deltas = _calcIncreaseAmountDeltas(beforeState, mocaAmt, esMocaAmt);

        _verifyIncreaseAmountTokens(beforeState, user, mocaAmt, esMocaAmt);
        _verifyIncreaseAmountGlobal(beforeState, deltas, mocaAmt, esMocaAmt, currentEpochStart);
        _verifyIncreaseAmountMappingsAndUser(beforeState, deltas, currentEpochStart);
        _verifyIncreaseAmountLock(beforeState, mocaAmt, esMocaAmt);
        _verifyIncreaseAmountHistory(beforeState, deltas, currentEpochStart);
        _verifyIncreaseAmountVP(beforeState);
    }

// ================= VERIFY INCREASE DURATION =================

    struct IncreaseDurationParams {
        uint128 oldExpiry;
        uint128 newExpiry;
        uint128 lockSlope;
        uint128 biasIncrease;
        uint128 currentEpochStart;
        address user;
    }

    function _calcIncreaseDurationParams(
        StateSnapshot memory beforeState, 
        uint128 newExpiry
    ) internal returns (IncreaseDurationParams memory params) {
        params.oldExpiry = beforeState.lock.lock.expiry;
        params.newExpiry = newExpiry;
        params.user = beforeState.lock.lock.owner;
        params.currentEpochStart = getCurrentEpochStart();
        
        uint128 mocaAmt = beforeState.lock.lock.moca;
        uint128 esMocaAmt = beforeState.lock.lock.esMoca;
        params.lockSlope = (mocaAmt + esMocaAmt) / MAX_LOCK_DURATION;
        params.biasIncrease = params.lockSlope * (newExpiry - params.oldExpiry);
    }

    function _verifyIncreaseDurationTokens(
        StateSnapshot memory beforeState
    ) internal view {
        address user = beforeState.lock.lock.owner;
        assertEq(user.balance, beforeState.tokens.userMoca, "User MOCA must be unchanged");
        assertEq(esMoca.balanceOf(user), beforeState.tokens.userEsMoca, "User esMOCA must be unchanged");
        assertEq(address(veMoca).balance, beforeState.tokens.contractMoca, "Contract MOCA must be unchanged");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokens.contractEsMoca, "Contract esMOCA must be unchanged");
    }

    function _verifyIncreaseDurationGlobal(
        StateSnapshot memory beforeState,
        IncreaseDurationParams memory params
    ) internal view {
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.global.veGlobal.bias + params.biasIncrease, "veGlobal bias must be incremented");
        assertEq(slope, beforeState.global.veGlobal.slope, "veGlobal slope must be unchanged");
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA, "Total Locked MOCA must be unchanged");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA, "Total Locked esMOCA must be unchanged");
        assertEq(veMoca.lastUpdatedTimestamp(), params.currentEpochStart, "Global LastUpdated must be updated");
    }

    function _verifyIncreaseDurationMappings(
        StateSnapshot memory beforeState,
        IncreaseDurationParams memory params
    ) internal view {
        assertEq(veMoca.slopeChanges(params.oldExpiry), beforeState.global.slopeChange - params.lockSlope, "Slope Change (Old Expiry) must be decremented");
        assertEq(veMoca.slopeChanges(params.newExpiry), beforeState.global.slopeChangeNewExpiry + params.lockSlope, "Slope Change (New Expiry) must be incremented");
    }

    function _verifyIncreaseDurationUser(
        StateSnapshot memory beforeState,
        IncreaseDurationParams memory params
    ) internal view {
        (uint128 bias, uint128 slope) = veMoca.userHistory(params.user, params.currentEpochStart);
        assertEq(bias, beforeState.user.userHistory.bias + params.biasIncrease, "User History Bias must be incremented");
        assertEq(slope, beforeState.user.userHistory.slope, "User History Slope must be unchanged");
        
        assertEq(veMoca.userLastUpdatedTimestamp(params.user), params.currentEpochStart, "User LastUpdated must be updated");
    }

    function _verifyIncreaseDurationLock(
        StateSnapshot memory beforeState,
        uint128 newExpiry
    ) internal view {
        DataTypes.Lock memory lock = getLock(beforeState.lock.lockId);
        assertEq(lock.owner, beforeState.lock.lock.owner, "Lock Owner must match");
        assertEq(lock.delegate, beforeState.lock.lock.delegate, "Lock Delegate must be unchanged");
        assertEq(lock.moca, beforeState.lock.lock.moca, "Lock Moca must be unchanged");
        assertEq(lock.esMoca, beforeState.lock.lock.esMoca, "Lock esMoca must be unchanged");
        assertEq(lock.expiry, newExpiry, "Lock Expiry must be updated");
        assertEq(lock.isUnlocked, beforeState.lock.lock.isUnlocked, "Lock Unlocked must be unchanged");
    }

    function _verifyIncreaseDurationHistory(
        StateSnapshot memory beforeState,
        IncreaseDurationParams memory params
    ) internal view {
        bytes32 lockId = beforeState.lock.lockId;
        
        uint256 len = veMoca.getLockHistoryLength(lockId);
        if (beforeState.lock.lockHistory[beforeState.lock.lockHistory.length - 1].lastUpdatedAt == params.currentEpochStart) {
            assertEq(len, beforeState.lock.lockHistory.length, "Lock History Length unchanged (same epoch)");
        } else {
            assertEq(len, beforeState.lock.lockHistory.length + 1, "Lock History Length must be incremented (new epoch)");
        }
        
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        uint128 expectedBias = params.lockSlope * params.newExpiry;
        assertEq(cp.veBalance.bias, expectedBias, "Lock History: Checkpoint Bias must reflect new expiry");
        assertEq(cp.veBalance.slope, params.lockSlope, "Lock History: Checkpoint Slope must reflect new expiry (same slope)");
        assertEq(cp.lastUpdatedAt, params.currentEpochStart, "Lock History: Checkpoint Timestamp must be updated");
    }

    function _verifyIncreaseDurationVP(
        StateSnapshot memory beforeState
    ) internal view {
        uint128 ts = uint128(block.timestamp);
        uint128 userVP = veMoca.balanceOfAt(beforeState.lock.lock.owner, ts, false);
        uint128 lockVP = getLockVotingPowerAt(beforeState.lock.lockId, ts);
        assertGt(userVP, 0, "User must have voting power");
        assertGt(lockVP, beforeState.lock.lockVotingPower, "Lock VP must have increased");
    }

    function verifyIncreaseDuration(StateSnapshot memory beforeState, uint128 newExpiry) internal {
        IncreaseDurationParams memory params = _calcIncreaseDurationParams(beforeState, newExpiry);

        _verifyIncreaseDurationTokens(beforeState);
        _verifyIncreaseDurationGlobal(beforeState, params);
        _verifyIncreaseDurationMappings(beforeState, params);
        _verifyIncreaseDurationUser(beforeState, params);
        _verifyIncreaseDurationLock(beforeState, newExpiry);
        _verifyIncreaseDurationHistory(beforeState, params);
        _verifyIncreaseDurationVP(beforeState);
    }

// ================= VERIFY UNLOCK =================

    struct UnlockParams {
        uint128 expiry;
        uint128 mocaAmt;
        uint128 esMocaAmt;
        uint128 currentEpochStart;
        address user;
    }

    function _calcUnlockParams(StateSnapshot memory beforeState) internal returns (UnlockParams memory params) {
        params.expiry = beforeState.lock.lock.expiry;
        params.mocaAmt = beforeState.lock.lock.moca;
        params.esMocaAmt = beforeState.lock.lock.esMoca;
        params.user = beforeState.lock.lock.owner;
        params.currentEpochStart = getCurrentEpochStart();
    }

    function _verifyUnlockTokens(
        StateSnapshot memory beforeState,
        UnlockParams memory params
    ) internal view {
        assertEq(params.user.balance, beforeState.tokens.userMoca + params.mocaAmt, "User MOCA must be incremented");
        assertEq(esMoca.balanceOf(params.user), beforeState.tokens.userEsMoca + params.esMocaAmt, "User esMOCA must be incremented");
        assertEq(address(veMoca).balance, beforeState.tokens.contractMoca - params.mocaAmt, "Contract MOCA must be decremented");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeState.tokens.contractEsMoca - params.esMocaAmt, "Contract esMOCA must be decremented");
    }

    function _verifyUnlockGlobal(
        StateSnapshot memory beforeState,
        UnlockParams memory params
    ) internal view {
        // unlock() does NOT update veGlobal or lastUpdatedTimestamp
        (uint128 bias, uint128 slope) = veMoca.veGlobal();
        assertEq(bias, beforeState.global.veGlobal.bias, "veGlobal bias unchanged by unlock");
        assertEq(slope, beforeState.global.veGlobal.slope, "veGlobal slope unchanged by unlock");
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeState.global.TOTAL_LOCKED_MOCA - params.mocaAmt, "Total Locked MOCA must be decremented");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeState.global.TOTAL_LOCKED_ESMOCA - params.esMocaAmt, "Total Locked esMOCA must be decremented");
        assertEq(veMoca.lastUpdatedTimestamp(), beforeState.global.lastUpdatedTimestamp, "lastUpdatedTimestamp unchanged by unlock");
    }

    function _verifyUnlockMappingsAndUser(
        StateSnapshot memory beforeState,
        UnlockParams memory params
    ) internal view {
        // slopeChanges unchanged by unlock()
        assertEq(veMoca.slopeChanges(params.expiry), beforeState.global.slopeChange, "Slope Change at expiry must be unchanged");

        // unlock() does NOT update userHistory or userLastUpdatedTimestamp
        assertEq(veMoca.userLastUpdatedTimestamp(params.user), beforeState.user.userLastUpdatedTimestamp, "userLastUpdatedTimestamp unchanged by unlock");
        
        (uint128 bias, uint128 slope) = veMoca.userHistory(params.user, params.currentEpochStart);
        assertEq(bias, beforeState.user.userHistory.bias, "userHistory bias unchanged by unlock");
        assertEq(slope, beforeState.user.userHistory.slope, "userHistory slope unchanged by unlock");
    }

    function _verifyUnlockLock(
        StateSnapshot memory beforeState
    ) internal view {
        DataTypes.Lock memory lock = getLock(beforeState.lock.lockId);
        assertEq(lock.owner, beforeState.lock.lock.owner, "Lock Owner must match");
        assertEq(lock.delegate, beforeState.lock.lock.delegate, "Lock Delegate must be unchanged");
        assertEq(lock.moca, 0, "Lock Moca must be zero after unlock");
        assertEq(lock.esMoca, 0, "Lock esMoca must be zero after unlock");
        assertEq(lock.expiry, beforeState.lock.lock.expiry, "Lock Expiry must be unchanged");
        assertTrue(lock.isUnlocked, "Lock must be marked as unlocked");
    }

    function _verifyUnlockHistory(
        StateSnapshot memory beforeState,
        UnlockParams memory params
    ) internal view {
        bytes32 lockId = beforeState.lock.lockId;

        // unlock() pushes a final checkpoint via _pushCheckpoint()
        uint256 len = veMoca.getLockHistoryLength(lockId);
        uint256 beforeLen = beforeState.lock.lockHistory.length;
        if (beforeState.lock.lockHistory[beforeLen - 1].lastUpdatedAt == params.currentEpochStart) {
            assertEq(len, beforeLen, "Lock History Length unchanged (same epoch)");
        } else {
            assertEq(len, beforeLen + 1, "Lock History Length must be incremented");
        }

        // Lock History checkpoint - final checkpoint records the lock's veBalance at unlock time
        DataTypes.Checkpoint memory cp = getLockHistory(lockId, len - 1);
        uint128 expectedSlope = (params.mocaAmt + params.esMocaAmt) / MAX_LOCK_DURATION;
        uint128 expectedBias = expectedSlope * params.expiry;
        assertEq(cp.veBalance.bias, expectedBias, "Lock History: Final checkpoint bias");
        assertEq(cp.veBalance.slope, expectedSlope, "Lock History: Final checkpoint slope");
        assertEq(cp.lastUpdatedAt, params.currentEpochStart, "Lock History: Checkpoint timestamp");
    }

    function _verifyUnlockVP(
        StateSnapshot memory beforeState
    ) internal view {
        uint128 lockVotingPower = getLockVotingPowerAt(beforeState.lock.lockId, uint128(block.timestamp));
        assertEq(lockVotingPower, 0, "Lock Voting Power must be 0 after unlock");
    }

    function verifyUnlock(StateSnapshot memory beforeState) internal {
        UnlockParams memory params = _calcUnlockParams(beforeState);

        _verifyUnlockTokens(beforeState, params);
        _verifyUnlockGlobal(beforeState, params);
        _verifyUnlockMappingsAndUser(beforeState, params);
        _verifyUnlockLock(beforeState);
        _verifyUnlockHistory(beforeState, params);
        _verifyUnlockVP(beforeState);
    }
}

