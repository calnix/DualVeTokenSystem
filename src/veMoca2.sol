// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// OZ
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {EpochMath} from "./libraries/EpochMath.sol";
import {Constants} from "./libraries/Constants.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
    - Stake MOCA tokens to receive veMOCA (voting power)
    - Longer lock periods result in higher veMOCA allocation
    - veMOCA decays linearly over time, reducing voting power
    - Formula-based calculation determines veMOCA amount based on stake amount and duration
 */

contract veMocaV2 is LowLevelWMoca, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    address public immutable WMOCA;
    IERC20 public immutable ESMOCA;

    address public immutable VOTING_CONTROLLER;

    // global principal amounts
    uint256 public TOTAL_LOCKED_MOCA;
    uint256 public TOTAL_LOCKED_ESMOCA;

    // global veBalance
    DataTypes.VeBalance public veGlobal;
    uint128 public lastUpdatedTimestamp;  

    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;    

    // risk
    uint256 public isFrozen;

//------------------------------- Mappings ------------------------------------------

    // --------- Global state ---------
    // scheduled global slope changes
    mapping(uint128 eTime => uint128 slopeChange) public slopeChanges;
    // saving totalSupply checkpoint for each epoch
    mapping(uint128 eTime => uint128 totalSupply) public totalSupplyAt;


    // --------- Lock state ---------
    mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
    // Checkpoints are added upon every state transition; checkpoints timestamp will lie on epoch boundaries
    mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;

    // --------- User state [Aggregates user's veBalance & slope changes] ---------
    // user personal data: cannot use array as likely will get very large
    mapping(address user => mapping(uint128 eTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
    mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) public userSlopeChanges;
    mapping(address user => uint128 lastUpdatedTimestamp) public userLastUpdatedTimestamp;

    // ----- Delegation state [Aggregates delegate's veBalance & slope changes] -----
    mapping(address delegate => bool isRegistered) public isRegisteredDelegate;                             // called by VotingController to register a delegate
    mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) public delegateSlopeChanges;
    mapping(address delegate => mapping(uint128 eTime => DataTypes.VeBalance veBalance)) public delegateHistory; // aggregated delegate veBalance
    mapping(address delegate => uint128 lastUpdatedTimestamp) public delegateLastUpdatedTimestamp;

    // ----- Pending Delegation Queue [PEQ]: to apply to user & delegate aggregations when updating pending deltas -----
    mapping (address user => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) public userPendingDeltas;
    mapping (address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) public delegatePendingDeltas;
    // timestamps for the above mappings are based on userLastUpdatedTimestamp & delegateLastUpdatedTimestamp

    // ----- Aggregation of a specific user-delegate pair: for VotingController to determine users' share of rewards from delegates -----
    // delegatedAggregationHistory tracks how much veBalance a user has delegated out
    mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeBalance veBalance))) public delegatedAggregationHistory;   // user's aggregated delegated veBalance for a specific delegate
    mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) public userDelegatedSlopeChanges;               // aggregated slope changes for user's delegated locks for a specific delegate
    mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) public userPendingDeltasForDelegate;    // pending deltas for user's delegated locks for a specific delegate
    mapping(address user => mapping(address delegate => uint128 lastUpdatedTimestamp)) public userDelegatedPairLastUpdatedTimestamp;                    // last updated timestamp for user-delegate pair

//------------------------------- Constructor ------------------------------------------

    constructor(address wMoca_, address esMoca_, address votingController_, address owner_, uint256 mocaTransferGasLimit) {
        // cannot deploy at T=0
        require(block.timestamp > 0, Errors.InvalidTimestamp());

        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // esMoca 
        require(esMoca_ != address(0), Errors.InvalidAddress());
        ESMOCA = IERC20(esMoca_);

        // check: voting controller is set
        VOTING_CONTROLLER = votingController_;
        require(VOTING_CONTROLLER != address(0), Errors.InvalidAddress());

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;

        // roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
    }

//------------------------------- External functions------------------------------------------


    // lock created is booked to currentEpochStart
    function createLock(uint128 expiry, uint128 esMoca) external payable  whenNotPaused returns (bytes32) {
        // Enforce minimum increment amount to avoid precision loss
        uint128 moca = uint128(msg.value);
        _minimumAmountCheck(moca, esMoca);

        // check: expiry is a valid epoch time [must end on an epoch boundary]
        require(EpochMath.isValidEpochTime(expiry), Errors.InvalidEpochTime());

        // check: lock duration is within allowed range
        require(expiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, Errors.InvalidLockDuration());
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());


        // check: lock will end at or after the 3 epochs from current epoch start [current + 2 more epochs]
        uint128 currentEpochStart = _minimumDurationCheck(expiry);

        // update user and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & user]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(msg.sender, currentEpochStart, false);

        // --------- generate lockId ---------

            // vaultId generation
            bytes32 lockId;
            {
                uint256 salt = block.number;
                lockId = _generateVaultId(salt, msg.sender);
                while (locks[lockId].lockId != bytes32(0)) lockId = _generateVaultId(++salt, msg.sender);      // If lockId exists, generate new random Id
            }

        // --------- create lock ---------
            DataTypes.Lock memory newLock;
                newLock.lockId = lockId;
                newLock.owner = msg.sender;
                newLock.moca = moca;
                newLock.esMoca = esMoca;
                newLock.expiry = expiry;
            // STORAGE: book lock
            locks[lockId] = newLock;

            // get lock's veBalance
            DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);

            // STORAGE: book checkpoint into lock history 
            _pushCheckpoint(lockHistory[lockId], veIncoming, uint128(currentEpochStart));

            // emit: lock created
            emit Events.LockCreated(lockId, msg.sender, /*delegate*/ address(0), newLock.moca, newLock.esMoca, newLock.expiry);

        // --------- Increment global state: add veIncoming to veGlobal ---------
        
        // STORAGE: update global [veBalance & schedule slope change]
        veGlobal_ = _add(veGlobal_, veIncoming);
        veGlobal = veGlobal_;
        slopeChanges[newLock.expiry] += veIncoming.slope;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // --------- Increment user state: add veIncoming to user ---------
        
        // STORAGE: update user [veBalance & schedule slope change]
        veUser_ = _add(veUser_, veIncoming);
        userHistory[msg.sender][currentEpochStart] = veUser_;
        userSlopeChanges[msg.sender][newLock.expiry] += veIncoming.slope;
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        // STORAGE: increment global TOTAL_LOCKED_MOCA
        if(moca > 0) TOTAL_LOCKED_MOCA += moca;

        // STORAGE: increment global TOTAL_LOCKED_ESMOCA & TRANSFER: esMoca to contract
        if(esMoca > 0) {
            TOTAL_LOCKED_ESMOCA += esMoca;
            ESMOCA.safeTransferFrom(msg.sender, address(this), esMoca);
        }

        return lockId;
    }

    // user to increase amount of lock
    function increaseAmount(bytes32 lockId, uint128 esMocaToAdd) external payable whenNotPaused {
        DataTypes.Lock memory oldLock = locks[lockId];

        // sanity check: lock exists & user is the owner
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());
        // sanity check: lock is not expired
        require(oldLock.expiry > block.timestamp, Errors.LockExpired());

        // check: lock will end at or after the 3 epochs from current epoch start [current + 2 more epochs]
        uint128 currentEpochStart = _minimumDurationCheck(oldLock.expiry);

        // Enforce minimum increment amount to avoid precision loss
        uint128 mocaToAdd = uint128(msg.value);
        _minimumAmountCheck(mocaToAdd, esMocaToAdd);

        // DELEGATED OR PERSONAL LOCK:
        bool isDelegated = oldLock.delegate != address(0);
        address account = isDelegated ? oldLock.delegate : msg.sender;

        // update account and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & account & pending deltas]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) = _updateAccountAndGlobalAndPendingDeltas(account, currentEpochStart, isDelegated);


        // create new lock: update amounts
        DataTypes.Lock memory newLock = oldLock;
            newLock.moca += mocaToAdd;
            newLock.esMoca += esMocaToAdd;

        // STORAGE: update global + update account [veBalance & schedule slope change]
        DataTypes.VeBalance memory newLockVeBalance = _modifyLock(veGlobal_, veAccount_, oldLock, newLock, currentEpochStart);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newLockVeBalance, uint128(currentEpochStart));

        // STORAGE: increment global TOTAL_LOCKED_MOCA
        if(mocaToAdd > 0) TOTAL_LOCKED_MOCA += mocaToAdd;

        // STORAGE: increment global TOTAL_LOCKED_ESMOCA & TRANSFER: esMoca to contract
        if(esMocaToAdd > 0) {
            TOTAL_LOCKED_ESMOCA += esMocaToAdd;
            ESMOCA.safeTransferFrom(msg.sender, address(this), esMocaToAdd);
        }

        // emit event
        emit Events.LockAmountIncreased(lockId, account, mocaToAdd, esMocaToAdd);
    }


    // user to increase duration of lock
    function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external whenNotPaused {  
        // get lock
        DataTypes.Lock memory oldLock = locks[lockId];

        // sanity check: lock exists, user is the owner, lock is not expired
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());
        require(oldLock.expiry > block.timestamp, Errors.LockExpired());

        // check: new expiry is a valid epoch time & within allowed range
        uint128 newExpiry = oldLock.expiry + durationToIncrease;
        require(EpochMath.isValidEpochTime(newExpiry), Errors.InvalidEpochTime());
        require(newExpiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidExpiry());

        // check: lock will end at or after the 3 epochs from current epoch start [current + 2 more epochs]
        uint128 currentEpochStart = _minimumDurationCheck(newExpiry);
        
        // DELEGATED OR PERSONAL LOCK:
        bool isDelegated = oldLock.delegate != address(0);
        address account = isDelegated ? oldLock.delegate : msg.sender;

        // update account and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & account & pending deltas]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) = _updateAccountAndGlobalAndPendingDeltas(account, currentEpochStart, isDelegated);


        // copy old lock: update duration
        DataTypes.Lock memory newLock = oldLock;
        newLock.expiry = newExpiry;

        // STORAGE: update global + update account [veBalance & schedule slope change]
        DataTypes.VeBalance memory newLockVeBalance = _modifyLock(veGlobal_, veAccount_, oldLock, newLock, currentEpochStart);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newLockVeBalance, uint128(currentEpochStart));

        // emit event
        emit Events.LockDurationIncreased(lockId, account, oldLock.expiry, newLock.expiry);
    }


    /**
     * @notice Withdraws principals of an expired lock 
     * @dev ve will be burnt, altho veBalance will return 0 on expiry
     * @dev Only the lock owner can call this function.
     * @param lockId The unique identifier of the lock to unlock.
     */
    function unlock(bytes32 lockId) external whenNotPaused {
        DataTypes.Lock memory lock = locks[lockId];

        // sanity check: lock exists + user is the owner
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        // sanity check: lock is expired 
        require(lock.expiry <= block.timestamp, Errors.InvalidExpiry());
        // sanity check: lock is not already unlocked
        require(lock.isUnlocked == false, Errors.InvalidLockState());

        // get current epoch start
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // update user and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & user]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(msg.sender, currentEpochStart, false);

        // STORAGE: push final checkpoint into lock history
        _pushCheckpoint(lockHistory[lockId], _convertToVeBalance(lock), uint128(currentEpochStart));
       
        // STORAGE: update user veBalance [no need to subtract veBalance from user, since it will be 0 on expiry]
        userHistory[msg.sender][currentEpochStart] = veUser_;
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        // STORAGE: update global veBalance 
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // STORAGE: decrement global totalLocked counters
        TOTAL_LOCKED_MOCA -= lock.moca;
        TOTAL_LOCKED_ESMOCA -= lock.esMoca;


        // cache principals + delete from lock
        uint128 cachedMoca = lock.moca;
        uint128 cachedEsMoca = lock.esMoca;
        delete lock.moca;
        delete lock.esMoca;

        // storage: update lock
        lock.isUnlocked = true;    
        locks[lockId] = lock;

        emit Events.LockUnlocked(lockId, lock.owner, cachedMoca, cachedEsMoca);

        // return principals to lock.owner
        if(cachedEsMoca > 0) ESMOCA.safeTransfer(lock.owner, cachedEsMoca);        
        if(cachedMoca > 0) _transferMocaAndWrapIfFailWithGasLimit(WMOCA, lock.owner, cachedMoca, MOCA_TRANSFER_GAS_LIMIT);
    }


//-------------------------------User Delegate functions-------------------------------------

    /** Problem: user can vote, then delegate
        ⦁	sub their veBal, add to delegate veBal
        ⦁	_vote only references `veMoca.balanceOfAt(caller, epochEnd, isDelegated)`
        ⦁	so this creates a double-voting exploit
        Solution: forward-delegate. impacts on next epoch.

        With forward-delegations, we need to ensure that the lock has a non-zero voting power at the end of the next epoch.
        Else, the delegate would not be able to vote; and the delegation is pointless. 
        This is why we check that the lock has at least 2 more epochs left before expiry: current + 2 more epochs.
        - if current +1: non-zero voting power in the current epoch; 0 voting power in the next epoch. [due to forward-decay]
        - if current +2: non-zero voting power in the current epoch; non-zero voting power in the next epoch.
        -- on the 3rd epoch voting power will be 0. 
        
        This problem does not occur when users' are createLock(isDelegated); as the lock is delegated immediately.
        - so createLock(isDelegated) will only need to check that the lock has at least 1 more epoch left before expiry: current + 1 more epoch.
    */

    function _updatePendingForDelegatePair(address user, address delegate, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {
        uint128 pairLastUpdatedAt = userDelegatedPairLastUpdatedTimestamp[user][delegate];

        // init user veUser
        DataTypes.VeBalance memory vePair_;

        // if the pair has never been updated, return the initial aggregated veBalance
        if(pairLastUpdatedAt == 0) {
            // update the last updated timestamp
            userDelegatedPairLastUpdatedTimestamp[user][delegate] = currentEpochStart;
            return vePair_;
        }

        // copy the previous aggregated veBalance to mem [if the pair is already up to date, return]
        vePair_ = delegatedAggregationHistory[user][delegate][pairLastUpdatedAt];
        if(pairLastUpdatedAt == currentEpochStart) return vePair_; 

        // update pair's aggregated veBalance to current epoch start
        while(pairLastUpdatedAt < currentEpochStart) {

            // advance to next epoch
            pairLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // apply decay to the aggregated veBalance
            vePair_ = _subtractExpired(vePair_, userDelegatedSlopeChanges[user][delegate][pairLastUpdatedAt], pairLastUpdatedAt);
            
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
            
            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;
            
            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;
            
            // apply the pending delta to the vePair [add then sub]
            if(hasAddition) vePair_ = _add(vePair_, deltaPtr.additions);
            if(hasSubtraction) vePair_ = _sub(vePair_, deltaPtr.subtractions);

            // clean up after applying
            delete userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
        }

        // update the last updated timestamp
        userDelegatedPairLastUpdatedTimestamp[user][delegate] = pairLastUpdatedAt;

        return vePair_;
    }
    
    function delegateLock(bytes32 lockId, address delegate) external whenNotPaused {
        // sanity check: delegate is registered + not the same as the caller
        require(delegate != msg.sender, Errors.InvalidDelegate());
        require(isRegisteredDelegate[delegate], Errors.DelegateNotRegistered());

        DataTypes.Lock memory lock = locks[lockId];

        // sanity check: lock exists + user is the owner & lock is not already delegated
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        require(lock.delegate == address(0), Errors.LockAlreadyDelegated());

        // check: lock will end at or after the 3rd epoch from current epoch start
        uint128 currentEpochStart = _minimumDurationCheck(lock.expiry);     // also prevents delegating expired locks

        // ------ Update global, user, delegate to currentEpochStart ------
        // update user and global veBalance: updates lastUpdatedTimestamp for global & user
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(msg.sender, currentEpochStart, false);
        // update delegate: updates delegate's lastUpdatedTimestamp        
        (,DataTypes.VeBalance memory veDelegate_) = _updateAccountAndGlobalAndPendingDeltas(delegate, currentEpochStart, true);

        // ------ Book pending deltas for user & delegate & aggregated ------
        DataTypes.VeBalance memory veDelegatePair_ = _updatePendingForDelegatePair(msg.sender, delegate, currentEpochStart); // update pending for aggregated [userDelegateLastUpdatedTimestamp is updated to currentEpochStart]

        // ------ Book updated states to storage: global, user, delegate, aggregated ------
        veGlobal = veGlobal_;   
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);
        
        userHistory[msg.sender][currentEpochStart] = veUser_;
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        delegateHistory[delegate][currentEpochStart] = veDelegate_;
        emit Events.DelegateUpdated(delegate, veDelegate_.bias, veDelegate_.slope);

        delegatedAggregationHistory[msg.sender][delegate][currentEpochStart] = veDelegatePair_;
        emit Events.DelegatedAggregationUpdated(msg.sender, delegate, veDelegatePair_.bias, veDelegatePair_.slope);

        // ------ Handle lock's delegation [only kicks in the next epoch; not current] ------

        // get nextEpoch [delegation impact occurs in the next epoch; not current]
        uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 

        // shift scheduled slope change for this lock's expiry from user to delegate
        userSlopeChanges[msg.sender][lock.expiry] -= lockVeBalance.slope;       
        delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;
        userDelegatedSlopeChanges[msg.sender][delegate][lock.expiry] += lockVeBalance.slope;


        // book pending for user: remove lock from user's aggregated veBalance 
        userPendingDeltas[msg.sender][nextEpochStart].hasSubtraction = true;
        userPendingDeltas[msg.sender][nextEpochStart].subtractions = _add(userPendingDeltas[msg.sender][nextEpochStart].subtractions, lockVeBalance);

        // book pending for delegate: add lock to delegate's aggregated veBalance 
        delegatePendingDeltas[delegate][nextEpochStart].hasAddition = true;
        delegatePendingDeltas[delegate][nextEpochStart].additions = _add(delegatePendingDeltas[delegate][nextEpochStart].additions, lockVeBalance);


        // Agg: book pending for user-delegate pair aggregation
        userPendingDeltasForDelegate[msg.sender][delegate][nextEpochStart].hasAddition = true;
        userPendingDeltasForDelegate[msg.sender][delegate][nextEpochStart].additions = _add(userPendingDeltasForDelegate[msg.sender][delegate][nextEpochStart].additions, lockVeBalance);


        // storage: update lock to mark it as delegated
        lock.delegate = delegate;
        locks[lockId] = lock;

        emit Events.LockDelegated(lockId, msg.sender, delegate);
    }

    // delegation impact occurs in the next epoch; not current
    function switchDelegate(bytes32 lockId, address newDelegate) external whenNotPaused {
        // sanity check: newDelegate is registered + not the same as the caller
        require(newDelegate != msg.sender, Errors.InvalidDelegate());
        require(isRegisteredDelegate[newDelegate], Errors.DelegateNotRegistered());

        DataTypes.Lock memory lock = locks[lockId];

        // sanity check: lock exists + caller is the owner & lock is currently delegated & not switching to same delegate
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        require(lock.delegate != address(0), Errors.LockNotDelegated());
        require(lock.delegate != newDelegate, Errors.InvalidDelegate());

        // check: lock will end at or after the 3rd epoch from current epoch start
        uint128 currentEpochStart = _minimumDurationCheck(lock.expiry);

        // ------ Update global, currentDelegate, newDelegate to currentEpochStart ------
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veCurrentDelegate_) = _updateAccountAndGlobalAndPendingDeltas(lock.delegate, currentEpochStart, true);
        (, DataTypes.VeBalance memory veNewDelegate_) = _updateAccountAndGlobalAndPendingDeltas(newDelegate, currentEpochStart, true);

        // ------ Book pending deltas for user & delegate & aggregated ------
        DataTypes.VeBalance memory vePairOldDelegate_ = _updatePendingForDelegatePair(msg.sender, lock.delegate, currentEpochStart); 
        DataTypes.VeBalance memory vePairNewDelegate_ = _updatePendingForDelegatePair(msg.sender, newDelegate, currentEpochStart);

        // ------ Book updated states to storage: global, delegates ------
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        delegateHistory[lock.delegate][currentEpochStart] = veCurrentDelegate_;
        emit Events.DelegateUpdated(lock.delegate, veCurrentDelegate_.bias, veCurrentDelegate_.slope);  // old delegate

        delegateHistory[newDelegate][currentEpochStart] = veNewDelegate_;
        emit Events.DelegateUpdated(newDelegate, veNewDelegate_.bias, veNewDelegate_.slope);        // new delegate

        // user delegate aggregation: old & new delegate pairs
        delegatedAggregationHistory[msg.sender][lock.delegate][currentEpochStart] = vePairOldDelegate_;
        emit Events.DelegatedAggregationUpdated(msg.sender, lock.delegate, vePairOldDelegate_.bias, vePairOldDelegate_.slope);

        delegatedAggregationHistory[msg.sender][newDelegate][currentEpochStart] = vePairNewDelegate_;
        emit Events.DelegatedAggregationUpdated(msg.sender, newDelegate, vePairNewDelegate_.bias, vePairNewDelegate_.slope);


        // ------ Handle lock's delegation switch [only kicks in the next epoch; not current] ------

        // get nextEpoch [delegation impact occurs in the next epoch; not current]
        uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock);

        // Remove lock from currentDelegate: remove slope change & pending delta for next epoch
        delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;
        delegatePendingDeltas[lock.delegate][nextEpochStart].hasSubtraction = true;
        delegatePendingDeltas[lock.delegate][nextEpochStart].subtractions = _add(delegatePendingDeltas[lock.delegate][nextEpochStart].subtractions, lockVeBalance);

        // Add lock to newDelegate: add slope change & pending addition for next epoch
        delegateSlopeChanges[newDelegate][lock.expiry] += lockVeBalance.slope;
        delegatePendingDeltas[newDelegate][nextEpochStart].hasAddition = true;
        delegatePendingDeltas[newDelegate][nextEpochStart].additions = _add(delegatePendingDeltas[newDelegate][nextEpochStart].additions, lockVeBalance);

        // Agg: book pending for user-delegate-agg (remove from old, add to new)
        userPendingDeltasForDelegate[msg.sender][lock.delegate][nextEpochStart].hasSubtraction = true;
        userPendingDeltasForDelegate[msg.sender][lock.delegate][nextEpochStart].subtractions = _add(userPendingDeltasForDelegate[msg.sender][lock.delegate][nextEpochStart].subtractions, lockVeBalance);

        userPendingDeltasForDelegate[msg.sender][newDelegate][nextEpochStart].hasAddition = true;
        userPendingDeltasForDelegate[msg.sender][newDelegate][nextEpochStart].additions = _add(userPendingDeltasForDelegate[msg.sender][newDelegate][nextEpochStart].additions, lockVeBalance);


        // storage: update lock to mark it as delegated to newDelegate
        lock.delegate = newDelegate;
        locks[lockId] = lock;

        emit Events.LockDelegateSwitched(lockId, msg.sender, lock.delegate, newDelegate);
    }

    function undelegateLock(bytes32 lockId) external whenNotPaused {
        DataTypes.Lock memory lock = locks[lockId];

        // sanity checks: caller is the owner & lock is delegated
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        require(lock.delegate != address(0), Errors.LockNotDelegated());

        // check: lock will end at or after the 3rd epoch from current epoch start
        uint128 currentEpochStart = _minimumDurationCheck(lock.expiry);

        // ------ Update global, user, delegate to currentEpochStart ------
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(msg.sender, currentEpochStart, false);
        (, DataTypes.VeBalance memory veDelegate_) = _updateAccountAndGlobalAndPendingDeltas(lock.delegate, currentEpochStart, true);

        // ------ Book pending deltas for user-delegate pair aggregation ------
        DataTypes.VeBalance memory veDelegatePair_ = _updatePendingForDelegatePair(msg.sender, lock.delegate, currentEpochStart); 

        // ------ Book updated states to storage: global, user, delegate, aggregated ------
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        userHistory[msg.sender][currentEpochStart] = veUser_;
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        delegateHistory[lock.delegate][currentEpochStart] = veDelegate_;
        emit Events.DelegateUpdated(lock.delegate, veDelegate_.bias, veDelegate_.slope);

        delegatedAggregationHistory[msg.sender][lock.delegate][currentEpochStart] = veDelegatePair_;
        emit Events.DelegatedAggregationUpdated(msg.sender, lock.delegate, veDelegatePair_.bias, veDelegatePair_.slope);


        // ------ Handle lock's delegation [only kicks in the next epoch; not current] ------

        // get nextEpoch [delegation impact occurs in the next epoch; not current]
        uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 

        // Remove lock from delegate: remove slope change & book pending delta for next epoch
        delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;
        delegatePendingDeltas[lock.delegate][nextEpochStart].hasSubtraction = true;
        delegatePendingDeltas[lock.delegate][nextEpochStart].subtractions = _add(delegatePendingDeltas[lock.delegate][nextEpochStart].subtractions, lockVeBalance);


        // Add lock to user: add slope change & book pending addition for next epoch
        userSlopeChanges[msg.sender][lock.expiry] += lockVeBalance.slope;
        userPendingDeltas[msg.sender][nextEpochStart].hasAddition = true;
        userPendingDeltas[msg.sender][nextEpochStart].additions = _add(userPendingDeltas[msg.sender][nextEpochStart].additions, lockVeBalance);

        // Agg: book pending for user-delegate pair aggregation (remove from old, add to new)
        userPendingDeltasForDelegate[msg.sender][lock.delegate][nextEpochStart].hasSubtraction = true;
        userPendingDeltasForDelegate[msg.sender][lock.delegate][nextEpochStart].subtractions = _add(userPendingDeltasForDelegate[msg.sender][lock.delegate][nextEpochStart].subtractions, lockVeBalance);


        // storage: update lock to mark it as not delegated
        delete lock.delegate;
        locks[lockId] = lock;

        emit Events.LockUndelegated(lockId, msg.sender, lock.delegate);
    }

//------------------------------ CronJob: createLockFor()---------------------------------------------

    /** consider:

        Doing msg.value validation earlier, in a separate loop, like so:

        for(uint256 i = 0; i < length; i++) {
            totalMocaRequired += mocaAmounts[i];
            totalEsMocaRequired += esMocaAmounts[i];
        }
        require(msg.value == totalMocaRequired, Errors.InvalidAmount());
    
        reverts early, but at the cost of double for loops.
     */

    function createLockFor(address[] calldata users, uint128[] calldata esMocaAmounts, uint128[] calldata mocaAmounts, uint128 expiry) external payable onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused returns (bytes32[] memory) { 
        // array validation
        uint256 length = users.length;
        require(length > 0, Errors.InvalidArray());
        require(length == esMocaAmounts.length, Errors.MismatchedArrayLengths());
        require(length == mocaAmounts.length, Errors.MismatchedArrayLengths());


        // check: expiry is a valid epoch time [must end on an epoch boundary]
        require(EpochMath.isValidEpochTime(expiry), Errors.InvalidEpochTime());

        // check: lock duration is within allowed range
        require(expiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, "Lock duration too short");
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, "Lock duration too long");

        // check: expiry is at least 2 Epochs from current epoch start [lock lasts for current epoch and expires at the end of the next epoch]
        uint128 currentEpochStart = _minimumDurationCheck(expiry);

        // update global veBalance
        DataTypes.VeBalance memory veGlobal_ = _updateGlobal(veGlobal, lastUpdatedTimestamp, currentEpochStart);


        // counters: track totals
        uint128 totalEsMoca;
        uint128 totalMoca;
        uint128 totalSlopeChanges;

        // to store lockIds
        bytes32[] memory lockIds = new bytes32[](length);
        
        for(uint256 i; i < length; ++i) {

            DataTypes.VeBalance memory veIncoming;
            (lockIds[i], veIncoming) = _createSingleLock(users[i], mocaAmounts[i], esMocaAmounts[i], expiry, currentEpochStart);

            // counter: tracking total incoming veBalance
            veGlobal_ = _add(veGlobal_, veIncoming);
            totalSlopeChanges += veIncoming.slope;
            
            // accumulate totals: for verification
            totalMoca += mocaAmounts[i];
            totalEsMoca += esMocaAmounts[i];
        }
        
        // check: msg.value matches totalMoca
        require(msg.value == totalMoca, Errors.InvalidAmount());

        // STORAGE: update global veBalance after all locks
        veGlobal = veGlobal_;
        slopeChanges[expiry] += totalSlopeChanges;

        // emit: global updated once at the end
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // STORAGE: increment global moca locked
        TOTAL_LOCKED_MOCA += totalMoca;

        // TRANSFER: esMoca to contract [Moca is transferred in msg.value]
        if(totalEsMoca > 0) {
            TOTAL_LOCKED_ESMOCA += totalEsMoca;
            ESMOCA.safeTransferFrom(msg.sender, address(this), totalEsMoca);
        }
        return lockIds;
    }

    function _createSingleLock(address user, uint128 moca, uint128 esMoca, uint128 expiry, uint128 currentEpochStart) internal returns (bytes32, DataTypes.VeBalance memory) {
        // update user veBalance: may or may not have updates [STORAGE: updates userLastUpdatedTimestamp]
        DataTypes.VeBalance memory veUser_ = _updateUser(user, currentEpochStart);

        // check: minimum amount
        _minimumAmountCheck(moca, esMoca);


        // --------- generate lockId ---------
        bytes32 lockId;
        {
            uint256 salt = block.number;
            lockId = _generateVaultId(salt, user);
            while (locks[lockId].lockId != bytes32(0)) lockId = _generateVaultId(++salt, user);      // If lockId exists, generate new random Id
        }

        // --------- create lock ---------
        DataTypes.Lock memory newLock;
        newLock.lockId = lockId;
        newLock.owner = user;
        newLock.moca = moca;
        newLock.esMoca = esMoca;
        newLock.expiry = expiry;

        // get lock's veBalance
        DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);

        // STORAGE: book lock and create new checkpoint in lock history 
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], veIncoming, uint128(currentEpochStart));
    
        emit Events.LockCreated(lockId, user, /*delegate*/ address(0), newLock.moca, newLock.esMoca, newLock.expiry);

        // --------- Increment user state: add veIncoming to user ---------
        veUser_ = _add(veUser_, veIncoming);
        userHistory[user][currentEpochStart] = veUser_;
        userSlopeChanges[user][newLock.expiry] += veIncoming.slope;

        // emit: user updated
        emit Events.UserUpdated(user, veUser_.bias, veUser_.slope);

        return (lockId, veIncoming);
    }

//-------------------------------Admin function: setMocaTransferGasLimit() ---------------------------------------------

    /**
        * @notice Sets the gas limit for moca transfer.
        * @dev Only callable by the VotingEscrowMocaAdmin.
        * @param newMocaTransferGasLimit The new gas limit for moca transfer.
        */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyRole(Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE) whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }


//-------------------------------VotingController.sol functions------------------------------------------
    
    // note combine to 1 -> update Voting Controller

    // note: registration fees were collected by VotingController
    // require(delegate != address(0) not needed since external contract call
    function registerAsDelegate(address delegate) external whenNotPaused {
        require(msg.sender == VOTING_CONTROLLER, Errors.OnlyCallableByVotingControllerContract());
        require(!isRegisteredDelegate[delegate], Errors.DelegateAlreadyRegistered());

        isRegisteredDelegate[delegate] = true;

        emit Events.DelegateRegistered(delegate);
    }

    function unregisterAsDelegate(address delegate) external whenNotPaused {
        require(msg.sender == VOTING_CONTROLLER, Errors.OnlyCallableByVotingControllerContract());
        require(isRegisteredDelegate[delegate], Errors.DelegateNotRegistered());

        isRegisteredDelegate[delegate] = false;

        emit Events.DelegateUnregistered(delegate);
    }

//-------------------------------internal: update functions-----------------------------------------------------


    // does not update veGlobal. updates lastUpdatedTimestamp, totalSupplyAt[]
    function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current epoch [already up to date]
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // 1st call: no prior updates [global lastUpdatedTimestamp is set to currentEpochStart]
        if(lastUpdatedAt == 0) {
            lastUpdatedTimestamp = currentEpochStart;   // move forward the anchor point to skip empty epochs
            return veGlobal_;
        }

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);

            // book ve supply for this epoch
            totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);
        }

        // set final lastUpdatedTimestamp
        lastUpdatedTimestamp = lastUpdatedAt;

        return (veGlobal_);
    }

    /*
    function _updateUserAndGlobal(address user, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init user veUser
        DataTypes.VeBalance memory veUser_;

        // get user's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 userLastUpdatedAt = userLastUpdatedTimestamp[user];
        

        // user's first time: no prior updates to execute 
        if (userLastUpdatedAt == 0) {
            
            // set user's lastUpdatedTimestamp
            userLastUpdatedTimestamp[user] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veUser_);
        }
                
        // get user's previous veBalance: if both global and user are up to date, return
        veUser_ = userHistory[user][userLastUpdatedAt];
        if(userLastUpdatedAt >= currentEpochStart) return (veGlobal_, veUser_); 

        // update both global and user veBalance to current epoch
        while (userLastUpdatedAt < currentEpochStart) {

            // advance 1 epoch
            userLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < userLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[userLastUpdatedAt], userLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[userLastUpdatedAt] = _getValueAt(veGlobal_, userLastUpdatedAt);
            }

            // update user: apply scheduled slope reductions and decrement bias for expiring locks
            veUser_ = _subtractExpired(veUser_, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
            // book user checkpoint 
            userHistory[user][userLastUpdatedAt] = veUser_;
        }

        // set final lastUpdatedTimestamp: for global & user
        lastUpdatedTimestamp = userLastUpdatedTimestamp[user] = userLastUpdatedAt;
        
        // return
        return (veGlobal_, veUser_);
    }*/

    /*
    function _updateAccountAndGlobal(address account, uint128 currentEpochStart, bool isDelegate) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address => uint128) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);

        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init user veUser
        DataTypes.VeBalance memory veAccount_;

        // get user's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];
        
        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // set account's lastUpdatedTimestamp
            accountLastUpdatedMapping[account] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 


        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            accountLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = _subtractExpired(veAccount_, accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);
            // book account checkpoint 
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount_;
        }

        // set final lastUpdatedTimestamp: for global & account
        lastUpdatedTimestamp = accountLastUpdatedMapping[account] = accountLastUpdatedAt;

        // return
        return (veGlobal_, veAccount_);
    }*/

    /**
        - user.lastUpdatedAt either matches the global.lastUpdatedAt OR is behind it
        - the global never lags behind the user
     */
    function _updateAccountAndGlobalAndPendingDeltas(address account, uint128 currentEpochStart, bool isDelegate) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address account => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage accountPendingDeltas,
            mapping(address account => uint128 lastUpdatedTimestamp) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegatePendingDeltas, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userPendingDeltas, userLastUpdatedTimestamp);

        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init account veAccount
        DataTypes.VeBalance memory veAccount_;

        // get account's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];
        
        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // set account's lastUpdatedTimestamp
            accountLastUpdatedMapping[account] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 


        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            accountLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = _subtractExpired(veAccount_, accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

    
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];

            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;

            // apply the pending delta to the veAccount [add then sub]
            if(hasAddition) veAccount_ = _add(veAccount_, deltaPtr.additions);
            if(hasSubtraction) veAccount_ = _sub(veAccount_, deltaPtr.subtractions);

            // book account checkpoint 
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount_;

            // clean up after applying
            delete accountPendingDeltas[account][accountLastUpdatedAt];
        }

        // set final lastUpdatedTimestamp: for global & account
        lastUpdatedTimestamp = accountLastUpdatedMapping[account] = accountLastUpdatedAt;

        return (veGlobal_, veAccount_);
    }

    function _updateUser(address user, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {
        // init user veBalance
        DataTypes.VeBalance memory veUser_;

        // get user's lastUpdatedTimestamp
        uint128 userLastUpdatedAt = userLastUpdatedTimestamp[user];
        
        // user's first time: no prior updates to execute 
        if (userLastUpdatedAt == 0) {
            // set user's lastUpdatedTimestamp
            userLastUpdatedTimestamp[user] = currentEpochStart;
            return veUser_;
        }

        // get user's previous veBalance: if user is already up to date, return
        veUser_ = userHistory[user][userLastUpdatedAt];
        if(userLastUpdatedAt >= currentEpochStart) return veUser_; 

        // update user veBalance to current epoch
        while (userLastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            userLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // update user: apply scheduled slope reductions and decrement bias for expiring locks
            veUser_ = _subtractExpired(veUser_, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
            
            // book user checkpoint 
            userHistory[user][userLastUpdatedAt] = veUser_;
        }

        // set final userLastUpdatedTimestamp
        userLastUpdatedTimestamp[user] = userLastUpdatedAt;
        
        return veUser_;
    }
        

    /**
     * @dev Internal function to handle lock modifications (amount or duration changes)
     * @param veGlobal_ Current global veBalance (already updated to currentEpochStart)
     * @param veUser_ Current user veBalance (already updated to currentEpochStart)
     * @param oldLock The lock before modification
     * @param newLock The lock after modification
     * @param currentEpochStart The current epoch start timestamp
     * @return newVeBalance The new veBalance calculated from newLock
     */
    function _modifyLock(
        DataTypes.VeBalance memory veGlobal_,
        DataTypes.VeBalance memory veUser_,
        DataTypes.Lock memory oldLock,
        DataTypes.Lock memory newLock,
        uint128 currentEpochStart
    ) internal returns (DataTypes.VeBalance memory) {
        
        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(oldLock);
        DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(newLock);

        // get delta btw veBalance of old and new lock
        DataTypes.VeBalance memory increaseInVeBalance = _sub(newVeBalance, oldVeBalance);

        // handle slope changes: global + user
        if(newLock.expiry != oldLock.expiry) {
            // SCENARIO: increaseDuration() - expiry changed

            // global slope changes
            slopeChanges[oldLock.expiry] -= oldVeBalance.slope;
            slopeChanges[newLock.expiry] += newVeBalance.slope;
            
            // user slope changes
            userSlopeChanges[msg.sender][oldLock.expiry] -= oldVeBalance.slope;
            userSlopeChanges[msg.sender][newLock.expiry] += newVeBalance.slope;
        } else {
            // SCENARIO: increaseAmount() - only amounts changed
            
            // global slope changes
            slopeChanges[newLock.expiry] += increaseInVeBalance.slope;
            // user slope changes
            userSlopeChanges[msg.sender][newLock.expiry] += increaseInVeBalance.slope;
        }


        // STORAGE: update global veBalance
        veGlobal_ = _add(veGlobal_, increaseInVeBalance);
        veGlobal = veGlobal_;

        // emit: global updated
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);


        // STORAGE: update user veBalance
        veUser_ = _add(veUser_, increaseInVeBalance);
        userHistory[msg.sender][currentEpochStart] = veUser_;

        // emit: user updated
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        return newVeBalance;
    }

//-------------------------------internal: helper functions-----------------------------------------------------

    ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }

    function _minimumAmountCheck(uint128 moca, uint128 esMoca) internal pure {
        uint128 totalAmount = moca + esMoca;
        require(totalAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());
    }
    
    /*  lock must have at least 3 epochs `liveliness` before expiry: current + 2 more epochs
        - non-zero voting power in the current and next epoch. 
        - 0 voting power in the 3rd epoch.
        This is a result of forward-decay: benchmarking voting power to the end of the epoch [to freeze intra-epoch decay] 
        
        We also want locks created to be delegated, and since delegation takes effect in the next epoch;
        need to check that the lock has at least 3 epochs before expiry: current + 2 more epochs.
    */  
    function _minimumDurationCheck(uint128 expiry) internal view returns (uint128) {
        // get current epoch start
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // multiply start by 4, to get the end of the 3rd epoch [start of 4th epoch is the end of the 3rd]
        require(expiry >= currentEpochStart + (4 * EpochMath.EPOCH_DURATION), Errors.LockExpiresTooSoon());

        return currentEpochStart;
    }


//-------------------------------internal: lib-----------------------------------------------------
   
    /**
     * @notice Removes expired locks from a veBalance.
     * @dev Overflow is only possible if 100% of MOCA is locked at the same expiry, which is infeasible in practice.
     *      No SafeCast required as only previously added values are subtracted; 8.89B MOCA supply ensures overflow is impossible.
     *      Does not update global parameter: lastUpdatedAt.
     * @param a The veBalance to update.
     * @param expiringSlope The slope value expiring at the given expiry.
     * @param expiry The timestamp at which the slope expires.
     * @return The updated veBalance with expired values removed.
     */
    function _subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint128 biasReduction = expiringSlope * expiry;

        // defensive: to prevent underflow [should not be possible in practice]
        a.bias = a.bias > biasReduction ? a.bias - biasReduction : 0;      // remove decayed ve
        a.slope = a.slope > expiringSlope ? a.slope - expiringSlope : 0; // remove expiring slopes
        return a;
    }

    // calc. veBalance{bias,slope} from lock; based on expiry time | inception offset is handled by balanceOf() queries
    function _convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;

        veBalance.slope = (lock.moca + lock.esMoca) / uint128(EpochMath.MAX_LOCK_DURATION);
        veBalance.bias = veBalance.slope * lock.expiry;

        return veBalance;
    }

    
    function _pushCheckpoint(DataTypes.Checkpoint[] storage lockHistory_, DataTypes.VeBalance memory veBalance, uint128 currentEpochStart) internal {
        uint256 length = lockHistory_.length;

        // if last checkpoint is in the same epoch as incoming; overwrite
        if(length > 0 && lockHistory_[length - 1].lastUpdatedAt == currentEpochStart) {
            lockHistory_[length - 1].veBalance = veBalance;
        } else {
            // new checkpoint for new epoch: set lastUpdatedAt to currentEpochStart
            lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
        }
    }




    // subtracts b from a: a - b
    function _sub(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory res;
            res.bias = a.bias - b.bias;
            res.slope = a.slope - b.slope;

        return res;
    }

    function _add(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory res;
            res.bias = a.bias + b.bias;
            res.slope = a.slope + b.slope;

        return res;
    }

    // time is timestamp, not duration
    function _getValueAt(DataTypes.VeBalance memory a, uint128 timestamp) internal pure returns (uint128) {
        uint128 decay = a.slope * timestamp;

        if(a.bias <= decay) return 0;

        // offset inception inflation
        return a.bias - decay;
    }

//-------------------------------internal: view functions-----------------------------------------------------

    // needed for totalSupplyAtTimestamp()
    function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal view returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current epoch 
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // skip first time: no prior updates needed | set lastUpdatedAt | return
        if(lastUpdatedAt == 0) {
            return veGlobal_;
        }

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
        }

        return (veGlobal_);
    }

    function _viewUserAndGlobal(address user, uint128 currentEpochStart) internal view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init user veUser
        DataTypes.VeBalance memory veUser_;

        // get user's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 userLastUpdatedAt = userLastUpdatedTimestamp[user];
        

        // user's first time: no prior updates to execute 
        if (userLastUpdatedAt == 0) {

            // view global: may or may not have updates
            veGlobal_ = _viewGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veUser_);
        }
                
        // get user's previous veBalance: if both global and user are up to date, return
        veUser_ = userHistory[user][userLastUpdatedAt];
        if(userLastUpdatedAt >= currentEpochStart) return (veGlobal_, veUser_); 

        // update both global and user veBalance to current epoch
        while (userLastUpdatedAt < currentEpochStart) {

            // advance 1 epoch
            userLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // view global: if needed 
            if(lastUpdatedTimestamp_ < userLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[userLastUpdatedAt], userLastUpdatedAt);
            }

            // view user: apply scheduled slope reductions and decrement bias for expiring locks
            veUser_ = _subtractExpired(veUser_, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
        }

        return (veGlobal_, veUser_);
    }

    function _viewAccountAndGlobalAndPendingDeltas(address account, uint128 currentEpochStart, bool isDelegate) internal view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address account => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage accountPendingDeltas,
            mapping(address account => uint128 lastUpdatedTimestamp) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegatePendingDeltas, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userPendingDeltas, userLastUpdatedTimestamp);

        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init account veAccount
        DataTypes.VeBalance memory veAccount_;

        // get account's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];

        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // set account's lastUpdatedTimestamp
            accountLastUpdatedMapping[account] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = _viewGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 

        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            accountLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                //totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = _subtractExpired(veAccount_, accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];
           
            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;

            // apply the pending delta to the veAccount [add then sub]
            if(hasAddition) veAccount_ = _add(veAccount_, deltaPtr.additions);
            if(hasSubtraction) veAccount_ = _sub(veAccount_, deltaPtr.subtractions);
        }

        return (veGlobal_, veAccount_);
    }

//-------------------------------External: View functions-----------------------------------------

    function totalSupplyAtTimestamp(uint128 timestamp) public view returns (uint256) {
        require(timestamp >= block.timestamp, Errors.InvalidTimestamp());

        // get target epoch start
        uint128 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, targetEpochStartTime);
        return _getValueAt(veGlobal_, timestamp);
    }


    // returns either a user's personal voting power, or voting power that was delegated to him, at given timestamp 
    function balanceOfAt(address user, uint128 timestamp, bool isDelegate) public view returns (uint256) {
        require(user != address(0), Errors.InvalidAddress());
        require(timestamp <= block.timestamp, Errors.InvalidTimestamp());   // cannot query the future

        // get target epoch start
        uint128 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        (/*DataTypes.VeBalance memory veGlobal_*/, DataTypes.VeBalance memory veAccount_) = _viewAccountAndGlobalAndPendingDeltas(user, targetEpochStartTime, isDelegate);
        if(veAccount_.bias == 0) return 0; 

        // return user's voting power at given timestamp
        return _getValueAt(veAccount_, timestamp);
    }

    // note: used by VotingController for vote()
    function balanceAtEpochEnd(address user, uint256 epoch, bool isDelegate) external view returns (uint256) {
        require(user != address(0), Errors.InvalidAddress());

        // restrict to current/past epochs | can be used by VotingController and for other general queries
        uint128 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
        require(epochStartTime <= EpochMath.getCurrentEpochStart(), Errors.InvalidTimestamp());  

        (/*veGlobal_*/, DataTypes.VeBalance memory veAccount_) = _viewAccountAndGlobalAndPendingDeltas(user, epochStartTime, isDelegate);
        if(veAccount_.bias == 0) return 0;

        // return user's voting power at the end of the epoch
        uint128 epochEndTime = epochStartTime + EpochMath.EPOCH_DURATION;
        return _getValueAt(veAccount_, epochEndTime);
    }

    //Note: used by VotingController.claimRewardsFromDelegate() | returns userVotesAllocatedToDelegateForEpoch
    function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint256) {
        require(user != address(0), Errors.InvalidAddress());
        require(delegate != address(0), Errors.InvalidAddress());
        //require(isFrozen == 0, Errors.IsFrozen());   

        // 1. Determine time boundaries for the requested epoch
        uint128 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
        uint128 epochEndTime = epochStartTime + EpochMath.EPOCH_DURATION;
        
        // 2. Retrieve the timestamp of the last state update for this specific user-delegate pair
        uint128 lastUpdate = userDelegatedPairLastUpdatedTimestamp[user][delegate];

        // 3. If there is no history of interaction, the balance is 0
        if (lastUpdate == 0) return 0;

        // 4. Load baseline state from history
        DataTypes.VeBalance memory veBalance = delegatedAggregationHistory[user][delegate][lastUpdate]; // 

        // 5. If data is already up to date (lastUpdate >= epochStartTime), simply calculate value at epochEndTime. 
        if (lastUpdate >= epochStartTime) return _getValueAt(veBalance, epochEndTime);

        
        // 6. Simulate the state forward from the last update to the start of the requested epoch
        // This accounts for linear decay, slope changes, and pending deltas (additions/subtractions)
        // Logic mirrors _viewAccountAndGlobalAndPendingDeltas
        while (lastUpdate < epochStartTime) {

            // advance to the next epoch
            lastUpdate += EpochMath.EPOCH_DURATION;

            // Apply decay and slope changes scheduled for this epoch
            veBalance = _subtractExpired(veBalance, userDelegatedSlopeChanges[user][delegate][lastUpdate], lastUpdate);

            // Apply any pending deltas (delegations/undelegations) that were queued for this epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][lastUpdate];

            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;
            
            // apply the pending delta to the veBalance [add then sub]
            if(hasAddition) veBalance = _add(veBalance, deltaPtr.additions);
            if(hasSubtraction) veBalance = _sub(veBalance, deltaPtr.subtractions);
        }

        // if 0 bias, return 0
        if(veBalance.bias == 0) return 0;

        // return the calculated voting power at the exact end of the epoch
        return _getValueAt(veBalance, epochEndTime);
    }
}
