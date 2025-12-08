// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// internal libraries
import {EpochMath} from "./EpochMath.sol";
import {DataTypes} from "./DataTypes.sol";
import {Events} from "./Events.sol";

import {VeMathLib} from "./VeMathLib.sol";


library VeDelegationLib {
    using VeMathLib for DataTypes.VeBalance;
    using VeMathLib for DataTypes.Lock;

    function executeDelegateLock(
        DataTypes.Lock memory lock, uint128 currentEpochStart, address delegate,
        mapping(bytes32 lockId => DataTypes.Lock lock) storage locks,
        mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) storage userSlopeChanges,
        mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) storage delegateSlopeChanges,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) storage userDelegatedSlopeChanges,
        mapping(address user => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage userPendingDeltas,
        mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage delegatePendingDeltas,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) storage userPendingDeltasForDelegate
    ) external {

        uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = lock.convertToVeBalance();

        // Scheduled SlopeChanges: shift from user -> delegate
        userSlopeChanges[lock.owner][lock.expiry] -= lockVeBalance.slope;
        delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;
        userDelegatedSlopeChanges[lock.owner][delegate][lock.expiry] += lockVeBalance.slope;

        // PendingDeltas: subtract from user, add to delegate & owner-delegate pair aggregation
        _bookPendingSub(userPendingDeltas[lock.owner][nextEpochStart], lockVeBalance);
        _bookPendingAdd(delegatePendingDeltas[delegate][nextEpochStart], lockVeBalance);
        _bookPendingAdd(userPendingDeltasForDelegate[lock.owner][delegate][nextEpochStart], lockVeBalance);


        // ------- STORAGE: update lock -------

        // If NO pending change exists (delegationEpoch <= current), snapshot the current holder
        // If pending change exists, we keep the existing currentHolder and only update `delegate`.
        if (lock.delegationEpoch <= currentEpochStart) {
            lock.currentHolder = lock.delegate == address(0) ? lock.owner : lock.delegate;
            lock.delegationEpoch = uint96(nextEpochStart);
        }

        lock.delegate = delegate;
        locks[lock.lockId] = lock;
        emit Events.LockDelegated(lock.lockId, lock.owner, delegate);
    }

    function executeSwitchDelegateLock(
        DataTypes.Lock memory lock, uint128 currentEpochStart, address newDelegate,
        mapping(bytes32 lockId => DataTypes.Lock lock) storage locks,
        mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) storage delegateSlopeChanges,
        mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage delegatePendingDeltas,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) storage userDelegatedSlopeChanges,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) storage userPendingDeltasForDelegate
    ) external {

        uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = lock.convertToVeBalance();

        address oldDelegate = lock.delegate;
        address owner = lock.owner; 

        // Scheduled SlopeChanges: shift from old delegate -> new delegate
        delegateSlopeChanges[oldDelegate][lock.expiry] -= lockVeBalance.slope;
        delegateSlopeChanges[newDelegate][lock.expiry] += lockVeBalance.slope;

        // Shift per-pair slope: from old delegate to new delegate
        userDelegatedSlopeChanges[owner][oldDelegate][lock.expiry] -= lockVeBalance.slope;
        userDelegatedSlopeChanges[owner][newDelegate][lock.expiry] += lockVeBalance.slope;


        // PendingDeltas: subtract from oldDelegate, add to newDelegate
        _bookPendingSub(delegatePendingDeltas[oldDelegate][nextEpochStart], lockVeBalance);
        _bookPendingAdd(delegatePendingDeltas[newDelegate][nextEpochStart], lockVeBalance);

        _bookPendingSub(userPendingDeltasForDelegate[owner][oldDelegate][nextEpochStart], lockVeBalance);
        _bookPendingAdd(userPendingDeltasForDelegate[owner][newDelegate][nextEpochStart], lockVeBalance);


        // If NO pending change exists (delegationEpoch <= current), snapshot the current holder
        // If pending change exists, we keep the existing currentHolder and only update `delegate`.
        if (lock.delegationEpoch <= currentEpochStart) {
            lock.currentHolder = lock.delegate == address(0) ? lock.owner : lock.delegate;
            lock.delegationEpoch = uint96(nextEpochStart);
        }

        lock.delegate = newDelegate;
        locks[lock.lockId] = lock;

        emit Events.LockDelegateSwitched(lock.lockId, owner, oldDelegate, newDelegate);
    }


    function executeUndelegateLock(
        DataTypes.Lock memory lock, uint128 currentEpochStart,
        mapping(bytes32 lockId => DataTypes.Lock lock) storage locks,
        mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) storage userSlopeChanges,
        mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) storage delegateSlopeChanges, 
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) storage userDelegatedSlopeChanges,
        mapping(address user => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage userPendingDeltas,
        mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage delegatePendingDeltas,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) storage userPendingDeltasForDelegate
    ) external {

        uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's veBalance
        DataTypes.VeBalance memory lockVeBalance = lock.convertToVeBalance();

        address delegate = lock.delegate;
        address owner = lock.owner;

        // Scheduled SlopeChanges: shift from delegate -> owner
        delegateSlopeChanges[delegate][lock.expiry] -= lockVeBalance.slope;
        userSlopeChanges[owner][lock.expiry] += lockVeBalance.slope;
        
        // Remove per-pair slope: from user-delegate pair
        userDelegatedSlopeChanges[owner][delegate][lock.expiry] -= lockVeBalance.slope;


        // PendingDeltas: subtract from delegate & user-delegate pair aggregation
        _bookPendingSub(delegatePendingDeltas[delegate][nextEpochStart], lockVeBalance);
        _bookPendingSub(userPendingDeltasForDelegate[owner][delegate][nextEpochStart], lockVeBalance);

        // PendingDeltas: add to owner
        _bookPendingAdd(userPendingDeltas[owner][nextEpochStart], lockVeBalance);

        // If NO pending change exists (delegationEpoch <= current), snapshot the current holder
        // If pending change exists, we keep the existing currentHolder and only update `delegate`.
        if (lock.delegationEpoch <= currentEpochStart) {
            lock.currentHolder = lock.delegate == address(0) ? lock.owner : lock.delegate;
            lock.delegationEpoch = uint96(nextEpochStart);
        }

        // STORAGE: update lock to mark it as not delegated
        delete lock.delegate;
        locks[lock.lockId] = lock;

        emit Events.LockUndelegated(lock.lockId, owner, delegate);
    }

//------------------------------- IncreaseAmount: Split Functions -----------------------------------

    /**
     * @notice Step 1: Calculate veBalances and update history mappings for increaseAmount
     * @return veCurrentAccount Updated veBalance for current account
     * @return increaseInVeBalance The increase in veBalance from the amount change
     */
    function executeIncreaseAmount_UpdateHistory(
        DataTypes.Lock memory oldLock,
        uint128 esMocaToAdd,
        uint128 mocaToAdd,
        DataTypes.VeBalance memory veCurrentAccount_,
        uint128 currentEpochStart,
        address currentAccount,
        bool currentIsDelegate,
        // Storage (4 mappings)
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage userHistory,
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage delegateHistory,
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeBalance))) storage delegatedAggregationHistory
    ) external returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory, DataTypes.Lock memory) {
        
        // create new lock: update amounts
        DataTypes.Lock memory newLock = abi.decode(abi.encode(oldLock), (DataTypes.Lock));
        newLock.moca += mocaToAdd;
        newLock.esMoca += esMocaToAdd;

        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = oldLock.convertToVeBalance();
        DataTypes.VeBalance memory newVeBalance = newLock.convertToVeBalance();

        // get increase in veBalance
        DataTypes.VeBalance memory increaseInVeBalance = newVeBalance.sub(oldVeBalance);

        // increment current account's veBalance 
        DataTypes.VeBalance memory veCurrentAccount = veCurrentAccount_.add(increaseInVeBalance);

        // Current holder of lock benefits from the increase immediately [update history mappings]
        if (currentIsDelegate) {
            // update delegate history
            delegateHistory[currentAccount][currentEpochStart] = veCurrentAccount;
            
            // update user-delegate pair aggregation
            DataTypes.VeBalance storage pairBalance = delegatedAggregationHistory[oldLock.owner][currentAccount][currentEpochStart];
            pairBalance.bias += increaseInVeBalance.bias;
            pairBalance.slope += increaseInVeBalance.slope;
        } else {
            // update user history
            userHistory[currentAccount][currentEpochStart] = veCurrentAccount;
        }

        return (veCurrentAccount, increaseInVeBalance, newLock);
    }


    /**
     * @notice Step 2: Update slope changes for increaseAmount (adds slope at same expiry)
     */
    function executeIncreaseAmount_UpdateSlopes(
        address owner,
        address futureAccount,
        uint128 expiry,
        uint128 increaseSlope,
        bool futureIsDelegate,
        // Storage (4 mappings)
        mapping(uint128 => uint128) storage globalSlopeChanges,
        mapping(address => mapping(uint128 => uint128)) storage userSlopeChanges,
        mapping(address => mapping(uint128 => uint128)) storage delegateSlopeChanges,
        mapping(address => mapping(address => mapping(uint128 => uint128))) storage userDelegatedSlopeChanges
    ) external {
        // Global slope changes
        globalSlopeChanges[expiry] += increaseSlope;

        // Future account slope changes
        if (futureIsDelegate) {
            delegateSlopeChanges[futureAccount][expiry] += increaseSlope;
            userDelegatedSlopeChanges[owner][futureAccount][expiry] += increaseSlope;
        } else {
            userSlopeChanges[futureAccount][expiry] += increaseSlope;
        }
    }

    // increaseAmount: only increases slope at current expiry
    // increase veBalance of current account in current epoch
    // queue increase in veBalance of future account in next epoch [similarly if future account is delegate]
    // queue decrease in veBalance of current account in next epoch [similarly if current account is delegate]
    /*function executeIncreaseAmountLock(
        DataTypes.Lock memory oldLock,
        DataTypes.Lock memory newLock, 
        DataTypes.VeBalance memory veCurrentAccount_,
        uint128 currentEpochStart,
        address currentAccount, address futureAccount,
        bool currentIsDelegate, bool futureIsDelegate,
        // Storage pointers
        mapping(uint128 => uint128) storage globalSlopeChanges,
        // user 
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage userHistory,
        mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) storage userSlopeChanges,
        mapping(address user => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage userPendingDeltas,
        // delegate 
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage delegateHistory,
        mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) storage delegateSlopeChanges,
        mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage delegatePendingDeltas,
        // user-delegate pair aggregation
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeBalance))) storage delegatedAggregationHistory,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) storage userDelegatedSlopeChanges,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) storage userPendingDeltasForDelegate
    ) external returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {

        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = VeMathLib.convertToVeBalance(oldLock);
        DataTypes.VeBalance memory newVeBalance = VeMathLib.convertToVeBalance(newLock);

        // get increase in veBalance
        DataTypes.VeBalance memory increaseInVeBalance = VeMathLib.sub(newVeBalance, oldVeBalance);

        // increment current account's veBalance 
        veCurrentAccount_ = VeMathLib.add(veCurrentAccount_, increaseInVeBalance);

        // Current holder of lock benefits from the increase immediately [update history mappings]
        if(currentIsDelegate){
            // update delegate history
            delegateHistory[currentAccount][currentEpochStart] = veCurrentAccount_;
            
            // update user-delegate pair aggregation
            DataTypes.VeBalance storage pairBalance = delegatedAggregationHistory[oldLock.owner][currentAccount][currentEpochStart];
            pairBalance.bias += increaseInVeBalance.bias;
            pairBalance.slope += increaseInVeBalance.slope;

        } else {
            // update user history
            userHistory[currentAccount][currentEpochStart] = veCurrentAccount_;
        }

        // SlopeChanges: update global and future account's slope changes [increaseAmount: only increases slope at current expiry]
        globalSlopeChanges[oldLock.expiry] += increaseInVeBalance.slope;

        if (futureIsDelegate){
            // update delegate slope changes
            delegateSlopeChanges[futureAccount][oldLock.expiry] += increaseInVeBalance.slope;
            // update user-delegate pair slope changes
            userDelegatedSlopeChanges[oldLock.owner][futureAccount][oldLock.expiry] += increaseInVeBalance.slope;
        } else {
            // update user slope changes
            userSlopeChanges[futureAccount][oldLock.expiry] += increaseInVeBalance.slope;
        }

        // --- Queue pending deltas if pending action exists ---
        // current account: subject to decrease in next epoch
        // future account: subject to increase in next epoch
        bool hasPending = oldLock.delegationEpoch > currentEpochStart;
        if (hasPending) {

            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // Sub from current account
            if (currentIsDelegate) {
                _bookPendingSub(delegatePendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
                _bookPendingSub(userPendingDeltasForDelegate[oldLock.owner][currentAccount][nextEpochStart], increaseInVeBalance);
            } else {
                _bookPendingSub(userPendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
            }

            // Add to future account
            if (futureIsDelegate) {
                _bookPendingAdd(delegatePendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
                _bookPendingAdd(userPendingDeltasForDelegate[oldLock.owner][futureAccount][nextEpochStart], increaseInVeBalance);
            } else {
                _bookPendingAdd(userPendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
            }
        }

        return (veCurrentAccount_, increaseInVeBalance);
    }*/

//------------------------------- IncreaseDuration: Split Functions -----------------------------------

    /**
    * @notice Step 1: Calculate veBalances and update history mappings for increaseDuration
    * @return veCurrentAccount Updated veBalance for current account
    * @return oldSlope The slope of old veBalance (for slope shifting)
    * @return newSlope The slope of new veBalance (for slope shifting)
    * @return increaseInVeBalance The increase in veBalance from the duration change
    */
    function executeIncreaseDuration_UpdateHistory(
        DataTypes.Lock memory oldLock,
        uint128 newExpiry,
        DataTypes.VeBalance memory veCurrentAccount_,
        uint128 currentEpochStart,
        address currentAccount,
        bool currentIsDelegate,
        // Storage (3 mappings)
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage userHistory,
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage delegateHistory,
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeBalance))) storage delegatedAggregationHistory
    ) external returns (
        DataTypes.VeBalance memory, uint128, uint128,DataTypes.VeBalance memory, DataTypes.Lock memory) {
        
        // Create new lock: update amounts
        DataTypes.Lock memory newLock = abi.decode(abi.encode(oldLock), (DataTypes.Lock));
        newLock.expiry = newExpiry;
        
        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = oldLock.convertToVeBalance();
        DataTypes.VeBalance memory newVeBalance = newLock.convertToVeBalance();

        // capture slopes for return
        uint128 oldSlope = oldVeBalance.slope;
        uint128 newSlope = newVeBalance.slope;

        // get increase in veBalance
        DataTypes.VeBalance memory increaseInVeBalance = newVeBalance.sub(oldVeBalance);
        
        // increment current account's veBalance 
        DataTypes.VeBalance memory veCurrentAccount = veCurrentAccount_.add(increaseInVeBalance);

        // Current holder of lock benefits from the increase immediately [update history mappings]
        if (currentIsDelegate) {
            // update delegate history
            delegateHistory[currentAccount][currentEpochStart] = veCurrentAccount;
            
            // update user-delegate pair aggregation
            DataTypes.VeBalance storage pairBalance = delegatedAggregationHistory[oldLock.owner][currentAccount][currentEpochStart];
            pairBalance.bias += increaseInVeBalance.bias;
            pairBalance.slope += increaseInVeBalance.slope;
        } else {
            // update user history
            userHistory[currentAccount][currentEpochStart] = veCurrentAccount;
        }

        return (veCurrentAccount, oldSlope, newSlope, increaseInVeBalance, newLock);
    }

    /**
     * @notice Step 2: Update slope changes for increaseDuration (shifts slopes from old to new expiry)
     */
    function executeIncreaseDuration_UpdateSlopes(
        address owner,
        address futureAccount,
        uint128 oldExpiry,
        uint128 newExpiry,
        uint128 oldSlope,
        uint128 newSlope,
        bool futureIsDelegate,
        // Storage (4 mappings)
        mapping(uint128 => uint128) storage globalSlopeChanges,
        mapping(address => mapping(uint128 => uint128)) storage userSlopeChanges,
        mapping(address => mapping(uint128 => uint128)) storage delegateSlopeChanges,
        mapping(address => mapping(address => mapping(uint128 => uint128))) storage userDelegatedSlopeChanges
    ) external {
        // Global slope changes: remove old, add new
        globalSlopeChanges[oldExpiry] -= oldSlope;
        globalSlopeChanges[newExpiry] += newSlope;

        // Future account slope changes
        if (futureIsDelegate) {
            delegateSlopeChanges[futureAccount][oldExpiry] -= oldSlope;
            delegateSlopeChanges[futureAccount][newExpiry] += newSlope;
            userDelegatedSlopeChanges[owner][futureAccount][oldExpiry] -= oldSlope;
            userDelegatedSlopeChanges[owner][futureAccount][newExpiry] += newSlope;
        } else {
            userSlopeChanges[futureAccount][oldExpiry] -= oldSlope;
            userSlopeChanges[futureAccount][newExpiry] += newSlope;
        }
    }

    // increaseDuration results in shifting of slopes at current expiry to new expiry
    /*function executeIncreaseDurationLock(
        DataTypes.Lock memory oldLock,
        DataTypes.Lock memory newLock, 
        DataTypes.VeBalance memory veCurrentAccount_,
        uint128 currentEpochStart,
        address currentAccount, address futureAccount,
        bool currentIsDelegate, bool futureIsDelegate,
        // Storage pointers
        mapping(uint128 => uint128) storage globalSlopeChanges,
        // user 
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage userHistory,
        mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) storage userSlopeChanges,
        mapping(address user => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage userPendingDeltas,
        // delegate 
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage delegateHistory,
        mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) storage delegateSlopeChanges,
        mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage delegatePendingDeltas,
        // user-delegate pair aggregation
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeBalance))) storage delegatedAggregationHistory,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) storage userDelegatedSlopeChanges,
        mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) storage userPendingDeltasForDelegate
    ) external returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        
        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = oldLock.convertToVeBalance();
        DataTypes.VeBalance memory newVeBalance = newLock.convertToVeBalance();

        // get increase in veBalance
        DataTypes.VeBalance memory increaseInVeBalance = newVeBalance.sub(oldVeBalance);
        
        // increment current account's veBalance 
        veCurrentAccount_ = veCurrentAccount_.add(increaseInVeBalance);

        // Current holder of lock benefits from the increase immediately [update history mappings]
        if(currentIsDelegate){
            // update delegate history
            delegateHistory[currentAccount][currentEpochStart] = veCurrentAccount_;
            
            // update user-delegate pair aggregation
            DataTypes.VeBalance storage pairBalance = delegatedAggregationHistory[oldLock.owner][currentAccount][currentEpochStart];
            pairBalance.bias += increaseInVeBalance.bias;
            pairBalance.slope += increaseInVeBalance.slope;

        } else {
            // update user history
            userHistory[currentAccount][currentEpochStart] = veCurrentAccount_;
        }

        // SlopeChanges: remove old slope, add new slope
        globalSlopeChanges[oldLock.expiry] -= oldVeBalance.slope;
        globalSlopeChanges[newLock.expiry] += newVeBalance.slope;

        // Future account: subject to increase in new expiry
        if (futureIsDelegate) {
            // update delegate slope changes
            delegateSlopeChanges[futureAccount][oldLock.expiry] -= oldVeBalance.slope;
            delegateSlopeChanges[futureAccount][newLock.expiry] += newVeBalance.slope;
            // update user-delegate pair slope changes
            userDelegatedSlopeChanges[oldLock.owner][futureAccount][oldLock.expiry] -= oldVeBalance.slope;
            userDelegatedSlopeChanges[oldLock.owner][futureAccount][newLock.expiry] += newVeBalance.slope;
        } else {
            // update user slope changes
            userSlopeChanges[futureAccount][oldLock.expiry] -= oldVeBalance.slope;
            userSlopeChanges[futureAccount][newLock.expiry] += newVeBalance.slope;
        }

        // --- Queue pending deltas if pending action exists ---
        // current account: subject to decrease in next epoch
        // future account: subject to increase in next epoch
        bool hasPending = oldLock.delegationEpoch > currentEpochStart;
        if (hasPending) {

            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // Sub from current account
            if (currentIsDelegate) {
                _bookPendingSub(delegatePendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
                _bookPendingSub(userPendingDeltasForDelegate[oldLock.owner][currentAccount][nextEpochStart], increaseInVeBalance);
            } else {
                _bookPendingSub(userPendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
            }

            // Add to future account
            if (futureIsDelegate) {
                _bookPendingAdd(delegatePendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
                _bookPendingAdd(userPendingDeltasForDelegate[oldLock.owner][futureAccount][nextEpochStart], increaseInVeBalance);
            } else {
                _bookPendingAdd(userPendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
            }
        }

        return (veCurrentAccount_, increaseInVeBalance);
    }*/

//------------------------------- Shared: Pending Deltas Update -----------------------------------

    /**
     * @notice Step 3 (shared): Update pending deltas when a pending delegation action exists
     * @dev Called by both increaseAmount and increaseDuration when hasPending is true
     */
    function updatePendingDeltas(
        address owner,
        address currentAccount,
        address futureAccount,
        uint128 nextEpochStart,
        DataTypes.VeBalance memory increaseInVeBalance,
        bool currentIsDelegate,
        bool futureIsDelegate,
        // Storage (3 mappings)
        mapping(address => mapping(uint128 => DataTypes.VeDeltas)) storage userPendingDeltas,
        mapping(address => mapping(uint128 => DataTypes.VeDeltas)) storage delegatePendingDeltas,
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeDeltas))) storage userPendingDeltasForDelegate
    ) external {
        // Sub from current account
        if (currentIsDelegate) {
            _bookPendingSub(delegatePendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
            _bookPendingSub(userPendingDeltasForDelegate[owner][currentAccount][nextEpochStart], increaseInVeBalance);
        } else {
            _bookPendingSub(userPendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
        }

        // Add to future account
        if (futureIsDelegate) {
            _bookPendingAdd(delegatePendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
            _bookPendingAdd(userPendingDeltasForDelegate[owner][futureAccount][nextEpochStart], increaseInVeBalance);
        } else {
            _bookPendingAdd(userPendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
        }
    }

    /**
     * @notice Handles lock modification (increase amount/duration) with pending delegation awareness
     * @dev Routes veBalance to effective account, slopes to future account, queues pending deltas if needed
     */
    /*function executeModifyLock(
        DataTypes.Lock memory oldLock,
        DataTypes.Lock memory newLock,
        uint128 currentEpochStart,
        DataTypes.VeBalance memory veAccount_,
        address currentAccount, address futureAccount,
        bool currentIsDelegate, bool futureIsDelegate,
        // Storage pointers
        mapping(uint128 => uint128) storage globalSlopeChanges,
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage userHistory,
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage delegateHistory,
        mapping(address => mapping(uint128 => uint128)) storage userSlopeChanges,
        mapping(address => mapping(uint128 => uint128)) storage delegateSlopeChanges,
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeBalance))) storage delegatedAggregationHistory,
        mapping(address => mapping(address => mapping(uint128 => uint128))) storage userDelegatedSlopeChanges,
        mapping(address => mapping(uint128 => DataTypes.VeDeltas)) storage userPendingDeltas,
        mapping(address => mapping(uint128 => DataTypes.VeDeltas)) storage delegatePendingDeltas,
        mapping(address => mapping(address => mapping(uint128 => DataTypes.VeDeltas))) storage userPendingDeltasForDelegate
    ) external returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        
        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = oldLock.convertToVeBalance();
        DataTypes.VeBalance memory newVeBalance = newLock.convertToVeBalance();
        
        // get increase in veBalance
        DataTypes.VeBalance memory increaseInVeBalance = newVeBalance.sub(oldVeBalance);
    
        // --- Update current account's veBalance ---
        veAccount_ = veAccount_.add(increaseInVeBalance);
        if (currentIsDelegate) delegateHistory[currentAccount][currentEpochStart] = veAccount_;
        else userHistory[currentAccount][currentEpochStart] = veAccount_;

        // --- Global slope changes ---
        bool isExpiryChange = newLock.expiry != oldLock.expiry;
        if (isExpiryChange) {
            globalSlopeChanges[oldLock.expiry] -= oldVeBalance.slope;
            globalSlopeChanges[newLock.expiry] += newVeBalance.slope;
        } else {
            globalSlopeChanges[newLock.expiry] += increaseInVeBalance.slope;
        }

        // --- Future account slope changes (next holder of voting power) ---
        if (futureIsDelegate) {
            if (isExpiryChange) {
                delegateSlopeChanges[futureAccount][oldLock.expiry] -= oldVeBalance.slope;
                delegateSlopeChanges[futureAccount][newLock.expiry] += newVeBalance.slope;
            } else {
                delegateSlopeChanges[futureAccount][newLock.expiry] += increaseInVeBalance.slope;
            }
        } else {
            if (isExpiryChange) {
                userSlopeChanges[futureAccount][oldLock.expiry] -= oldVeBalance.slope;
                userSlopeChanges[futureAccount][newLock.expiry] += newVeBalance.slope;
            } else {
                userSlopeChanges[futureAccount][newLock.expiry] += increaseInVeBalance.slope;
            }
        }

        // --- User-delegate pair: current account's pair if delegated ---
        if (currentIsDelegate) {
            DataTypes.VeBalance storage pairBalance = delegatedAggregationHistory[oldLock.owner][currentAccount][currentEpochStart];
            pairBalance.bias += increaseInVeBalance.bias;
            pairBalance.slope += increaseInVeBalance.slope;
        }

        // --- Future delegate pair slope changes ---
        if (futureIsDelegate) {
            if (isExpiryChange) {
                userDelegatedSlopeChanges[oldLock.owner][futureAccount][oldLock.expiry] -= oldVeBalance.slope;
                userDelegatedSlopeChanges[oldLock.owner][futureAccount][newLock.expiry] += newVeBalance.slope;
            } else {
                userDelegatedSlopeChanges[oldLock.owner][futureAccount][newLock.expiry] += increaseInVeBalance.slope;
            }
        }

        // --- Queue pending deltas if pending action exists ---
        bool hasPending = oldLock.delegationEpoch > currentEpochStart;
        if (hasPending) {
            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;
            
            // Sub from current account
            if (currentIsDelegate) {
                _bookPendingSub(delegatePendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
                _bookPendingSub(userPendingDeltasForDelegate[oldLock.owner][currentAccount][nextEpochStart], increaseInVeBalance);
            } else {
                _bookPendingSub(userPendingDeltas[currentAccount][nextEpochStart], increaseInVeBalance);
            }
            
            // Add to future account
            if (futureIsDelegate) {
                _bookPendingAdd(delegatePendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
                _bookPendingAdd(userPendingDeltasForDelegate[oldLock.owner][futureAccount][nextEpochStart], increaseInVeBalance);
            } else {
                _bookPendingAdd(userPendingDeltas[futureAccount][nextEpochStart], increaseInVeBalance);
            }
        }

        return (veAccount_, newVeBalance);
    }*/

//------------------------------- Internal: Pending Delta Booking -----------------------------------


    function _bookPendingAdd(DataTypes.VeDeltas storage delta, DataTypes.VeBalance memory ve) internal {
        delta.hasAddition = true;
        delta.additions = delta.additions.add(ve);
    }

    function _bookPendingSub(DataTypes.VeDeltas storage delta, DataTypes.VeBalance memory ve) internal {
        delta.hasSubtraction = true;
        delta.subtractions = delta.subtractions.add(ve);
    }

}