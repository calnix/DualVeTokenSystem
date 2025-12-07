// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// internal libraries
import {EpochMath} from "./EpochMath.sol";
import {DataTypes} from "./DataTypes.sol";
import {Events} from "./Events.sol";

import {VeMathLib} from "./VeMathLib.sol";


library VeDelegationLib {


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
        DataTypes.VeBalance memory lockVeBalance = VeMathLib.convertToVeBalance(lock);

        // Scheduled SlopeChanges: shift from user -> delegate
        userSlopeChanges[lock.owner][lock.expiry] -= lockVeBalance.slope;
        delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;
        userDelegatedSlopeChanges[lock.owner][delegate][lock.expiry] += lockVeBalance.slope;

        // PendingDeltas: subtract from user, add to delegate & owner-delegate pair aggregation
        _bookPendingSub(userPendingDeltas[lock.owner][nextEpochStart], lockVeBalance);
        _bookPendingAdd(delegatePendingDeltas[delegate][nextEpochStart], lockVeBalance);
        _bookPendingAdd(userPendingDeltasForDelegate[lock.owner][delegate][nextEpochStart], lockVeBalance);

        // STORAGE: update lock to mark it as delegated
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
        DataTypes.VeBalance memory lockVeBalance = VeMathLib.convertToVeBalance(lock);

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


        // STORAGE: update lock to mark it as delegated to newDelegate
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
        DataTypes.VeBalance memory lockVeBalance = VeMathLib.convertToVeBalance(lock);

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

        // STORAGE: update lock to mark it as not delegated
        delete lock.delegate;
        locks[lock.lockId] = lock;

        emit Events.LockUndelegated(lock.lockId, owner, delegate);
    }



//------------------------------- Internal: Pending Delta Booking -----------------------------------


    function _bookPendingAdd(DataTypes.VeDeltas storage delta, DataTypes.VeBalance memory ve) internal {
        delta.hasAddition = true;
        delta.additions = VeMathLib.add(delta.additions, ve);
    }

    function _bookPendingSub(DataTypes.VeDeltas storage delta, DataTypes.VeBalance memory ve) internal {
        delta.hasSubtraction = true;
        delta.subtractions = VeMathLib.add(delta.subtractions, ve);
    }
}