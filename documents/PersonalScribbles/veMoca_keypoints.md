1. voting power is forward-decayed to end of epoch

2. delegation only applies in the next epoch

- so a new lock must have at least 2 epochs for it to have voting power

2.1. consider Pending Event Queue system over forward-booking
overall might be cleaner

the answer is pending.

have a separate _updatePending() fn
```solidity

struct VeDeltas{
    DataTypes.Vebalance veAdditions;
    DataTypes.Vebalance veSubtractions;
}


 mapping userPendingDeltas(address user => mapping(uint256 eTime => DataTypes.VeDeltas veDeltas)) userPendingDeltas;
 uint256 userPendingDeltasLastUpdatedAt;
 mapping delegatePendingDeltas(address delegate => mapping(uint256 eTime => DataTypes.VeDeltas veDeltas)) delegatePendingDeltas;
 uint256 delegatePendingDeltasLastUpdatedAt;

// FOR VOTING CONTROLLER 
mapping(address user => mapping(address delegate => mapping(uint256 eTime => DataTypes.VeBalance veBalance))) public delegatedAggregationHistory; 
mapping(address user => mapping(address delegate => mapping(uint256 eTime => uint256 slopeChange))) public userDelegateSlopeChanges; 
mapping(address user => mapping(address delegate => mapping(uint256 eTime => DataTypes.VeDeltas veDeltas))) public userPendingDeltasForDelegate;
uint256 userPendingDeltasForDelegateLastUpdatedAt;

function deletegateLock(bytes32 lockId, address delegate) external {
    //...
    
    // for user
    _updateAccountAndGlobal()

    // for delegate
    _updateAccountAndGlobal()

    // update pending for user
    _updatePending(veUser, currentEpoch, userPendingDeltas)

    // update pending for delegate
    _updatePending(veDelegate, currentEpoch, delegatePendingDeltas)

    // updateGlobal

    //----- both user and delegate settled to currentEpoch & all pending actions due to prior delegations booked


    veLock = _convertToVe(lock);

    // book pending: remove lock from user's aggregate
    userPendingDeltas[user][nextEpoch].veSubtractions = veLock;
    
    //book pending: add lock to delegate's aggregate
    delegatePendingDeltas[user][nextEpoch].veAdditions = veLock;
}

```