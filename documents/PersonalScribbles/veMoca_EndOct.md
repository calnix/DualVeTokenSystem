# hmm

1. `mapping(address user => mapping(address delegate => mapping(uint256 eTime => uint256 slopeChange))) public userDelegateSlopeChanges;`

- Do i need this to handle multiple locks with different expiries correctly (e.g., so the aggregate decays properly when specific locks expire)?



# Pendle

## create lock

- `newVe = newPosition.convertToVeBalance()`
- userHistory[user].push(`newVe`)
- positionData[user]

```solidity
mapping(address => Checkpoints.History) internal userHistory;

struct VeBalance{
    uint128 bias
    uint128 slope
}

struct LockedPosition{
    uint128 amount
    uint128 expiry
}

struct Checkpoint {
    uint128 timestamp;
    VeBalance value;
}
```

Pendle stores user's total locked in positionData[user].
- each user has only 1 lock.

Similarly, each user only has a single series of Checkpoints, `userHistory[user]`
- for each lock update, a new checkpoint is pushed, marking the veBal at that `block.timestamp`

# VeMoca

## create Lock

- `veIncoming = newPosition.convertToVeBalance()`
- _pushCheckpoint(lockHistory[], veIncoming, currentEpochStart)

```solidity
function _pushCheckpoint(DataTypes.Checkpoint[] storage lockHistory_, DataTypes.VeBalance memory veBalance, uint128 currentEpochStart) internal {
    uint256 length = lockHistory_.length;

    // if last checkpoint is in the same epoch as incoming; overwrite
    if(length > 0 && lockHistory_[length - 1].lastUpdatedAt == currentEpochStart) {
        lockHistory_[length - 1].veBalance = veBalance;
    } else {
        // new checkpoint for new epoch: set lastUpdatedAt
        // forge-lint: disable-next-line(unsafe-typecast)
        lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
    }
}
```

- in `increaseAmount()`, `newVeBalance` is pushed as a new checkpoint. 
- `newVeBalance` = `oldlock` incremented 

lockHistory contains checkpoints, each lying on an epoch boundary, since they are all pushed to `currentEpochStart`
- if a lock is created mid-epoch, its booked to `currentEpochStart`. 
- if a lock is increaseAmount/increaseDuration mid-epoch, its booked to `currentEpochStart`. 

The `ve.bias` is calculated as `veBalance.slope * lock.expiry`, so the backdating to `epochStart` does not matter nor does it create issues.
- decay will be applied on query[`balanceOf`, `balanceAtEpochEnd`]
-- the decay is applied by using the formula `ve.bias = bias - (slope * timestamp)`

## On userDelegateSlopeChanges[], _findClosestPastETime, _viewForwardAbsolute

```solidity
        function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint128) {
            require(user != address(0), Errors.InvalidAddress());
            require(delegate != address(0), Errors.InvalidAddress());
            require(isFrozen == 0, Errors.IsFrozen());  

            uint256 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
            uint256 epochEndTime = EpochMath.getEpochEndTimestamp(epoch);

            mapping(uint256 => DataTypes.VeBalance) storage accountHistory = delegatedAggregationHistory[user][delegate];

            // Find the largest eTime <= epochStartTime with a valid checkpoint.
            uint256 foundETime = _findClosestPastETime(accountHistory, epochStartTime);

            // If no checkpoint found (foundETime == 0 and slot is unset), return 0.
            if (foundETime == 0 && accountHistory[0].bias == 0) return 0;

            // Get the VeBalance at the found eTime.
            DataTypes.VeBalance memory veBalance = accountHistory[foundETime];

            // Simulate forward application of slope changes from foundETime (exclusive) to epochEndTime (inclusive).
            veBalance = _viewForwardAbsolute(veBalance, foundETime, epochEndTime, userDelegateSlopeChanges[user][delegate]);

            // Calculate the value at epochEndTime (assuming _getValueAt is bias - slope * time).
            return _getValueAt(veBalance, epochEndTime);
        }
```

These are to support `getSpecificDelegatedBalanceAtEpochEnd()`, which will be called by `VotingController.claimRewardsFromDelegate()`

`userHistory` and `delegateHistory` are not arrays, but mappings.
- most ve systems use arrays, but we choose to use mappings, since we expect a lot of updates to be made
- specifically by the protocol, creating locks for users
- hence mappings to avoid capping off on arrays.

**Mappings only store values at specific epoch start timestamps (eTime) where an actual update occurs—such as creating a lock, increasing an amount, or delegating.**

- if no update happens in a particular epoch, nothing is written to the mapping for that eTime, making it "sparse".
- thus, when querying historical balances (e.g., via `getSpecificDelegatedBalanceAtEpochEnd` or `balanceAtEpochEnd`), the code cannot directly access delegatedAggregationHistory[user][delegate][epochEndTime]/userHistory[user][eTime]
- this might simply return a veBalance as a 0 struct.

Hence, the need for `_findClosestPastETime()` - to find the last veBalance that was updated. 
- `_findClosestPastETime()` returns `foundETime`.
- we can then get the updated veBalance: `veBalance = _viewForwardAbsolute(veBalance, foundETime, epochEndTime, userDelegateSlopeChanges[user][delegate])` 
- `_viewForwardAbsolute()` simulates forward application of slopeChanges for the sum of locks delegated by the user to this delegate.
- mapping `userDelegateSlopeChanges[]` stores the aggregated slopeChanges for all these delegated locks.

Once the updated veBalance is returned by `_viewForwardAbsolute()`, to account for possible lock expiries, it is then valued to the current epoch endTime, via: `_getValueAt(veBalance, epochEndtime)`. 
- this value is passed to VotingController for delegated rewards calculations. 

A similar process occurs with `balanceAtEpochEnd()`

```solidity
        function balanceAtEpochEnd(address user, uint256 epoch, bool forDelegated) external view returns (uint256) {
            require(isFrozen == 0, Errors.IsFrozen());
            require(user != address(0), Errors.InvalidAddress());

            uint256 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
            uint256 epochEndTime = EpochMath.getEpochEndTimestamp(epoch);

            mapping(uint256 => DataTypes.VeBalance) storage accountHistory = forDelegated ? delegateHistory[user] : userHistory[user];

            // Find the largest eTime <= epochStartTime with a valid checkpoint.
            uint256 foundETime = _findClosestPastETime(accountHistory, epochStartTime);

            // If no checkpoint found (foundETime == 0 and slot is unset), return 0.
            if (foundETime == 0 && accountHistory[0].bias == 0) return 0;

            // Get the VeBalance at the found eTime.
            DataTypes.VeBalance memory veBalance = accountHistory[foundETime];

            // Choose the appropriate slopeChanges mapping.
            mapping(uint256 => uint256) storage accountSlopeChanges = forDelegated ? delegateSlopeChanges[user] : userSlopeChanges[user];

            // Simulate forward application of slope changes from foundETime (exclusive) to epochEndTime (inclusive).
            veBalance = _viewForwardAbsolute(veBalance, foundETime, epochEndTime, accountSlopeChanges);

            // Calculate the value at epochEndTime (assuming _getValueAt is bias - slope * time).
            return _getValueAt(veBalance, epochEndTime);
        }
```

This allows VotingController to accurately receive the voting power of a user.

### VotingController calls 2 functions from VotingEscrowedMoca

1. `VotingController.vote()`: `balanceAtEpochEnd()`
2. `VotingController._claimDelegateRewards()`: `getSpecificDelegatedBalanceAtEpochEnd()`


## On delegating locks

fns: delegateLock, undelegateLock, switchDelegate

For delegate/switchDelegate:

- lock is already created
- owner is marking it as delegate -> switching from user to delegate mappings. 
- but this is forward-booked to the next epoch, to prevent double voting in the current epoch.
- else users would be able to vote, then delegate, and the delegate receiver would be able to vote again, using the incoming lock's voting power

forward-book does:
- userHistory[msg.sender][nextEpochStart]
- delegateHistory[delegate][nextEpochStart]
- delegatedAggregationHistory[msg.sender][delegate][nextEpochStart]

Note: userLastUpdatedTimestamp and delegateLastUpdatedTimestamp are not updated.
> switch does the same but its delegate1 instead of user. undelegate is the opposite; add to user, remove frm delegate

problem:

`_updateAccountAndGlobal()`:
``` solidity
// get account's lastUpdatedTimestamp: {user | delegate}
uint256 accountLastUpdatedAt = accountLastUpdatedMapping[account];
// LOAD: account's previous veBalance
DataTypes.VeBalance memory veAccount = accountHistoryMapping[account][accountLastUpdatedAt]; 

    while (accountLastUpdatedAt < currentEpochStart) {
        // advance 1 epoch
        accountLastUpdatedAt += EpochMath.EPOCH_DURATION; 

        // --- UPDATE GLOBAL: if required ---
        if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {}
        
        // UPDATE ACCOUNT:
        uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];    
        veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);

        // note: book account checkpoint 
        accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
    }

    //....
```

Assuming delegateLock was done in mid-way in Epoch10,
- Epoch 11: `_updateAccountAndGlobal` is called [cos user calls any fn: increaseAmount/unlock, triggering this]
- `_updateAccountAndGlobal` references last timestamp: `accountLastUpdatedAt` = Epoch 10, and loads `veAccount` form that time
- then in the while loop, it does `_subtractExpired`, returning an updated `veAccount` which is fine,
- but it overwrites `accountHistoryMapping[account][accountLastUpdatedAt] = veAccount`, with that update

This means that it **overwrites** the update done in `delegateLock()` to both:
- userHistory[msg.sender][nextEpochStart]
- delegateHistory[delegate][nextEpochStart]

So, the result is that the delegate action didn't take place, the lock was not 'moved' from the user to the delegate.
The core of the bug is that the `_updateAccountAndGlobal` loop re-calculates state based only on `accountSlopeChanges`, and is completely blind to the state pre-written by the delegation functions.

Fix1 :

```solidity
function _updateAccountAndGlobal(address account, bool isDelegate) internal 
            returns ( 
                    DataTypes.VeBalance memory, DataTypes.VeBalance memory, 
                    uint256,
                    mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage,
                    mapping(address => mapping(uint256 => uint256)) storage
                )
        {

            (
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping,
                mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping,
                mapping(address => uint256) storage accountLastUpdatedMapping
            ) = isDelegate ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);

            // CACHE: global veBalance + lastUpdatedTimestamp
            DataTypes.VeBalance memory veGlobal_ = veGlobal;
            uint256 lastUpdatedTimestamp_ = lastUpdatedTimestamp;
            
            // get current epoch start
            uint256 currentEpochStart = EpochMath.getCurrentEpochStart();

            // --- THE FIX ---
            // Check if a delegation function has already forward-booked a checkpoint
            // for the current epoch. (Uses the check `bias > 0` OR `slope > 0` for validity)
            DataTypes.VeBalance memory prewrittenCheckpoint = accountHistoryMapping[account][currentEpochStart];
            if (prewrittenCheckpoint.bias > 0 || prewrittenCheckpoint.slope > 0) {
                // A checkpoint already exists. This IS our state.
                // We MUST update the timestamp to prevent the loop from running and overwriting it.
                accountLastUpdatedMapping[account] = currentEpochStart;
                
                // We still need to update global, so call _updateGlobal independently.
                veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);
                
                // Return the pre-written state.
                return (veGlobal_, prewrittenCheckpoint, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
            }
            // --- END FIX ---

            [cite_start]uint256 accountLastUpdatedAt = accountLastUpdatedMapping[account]; [cite: 763]
            [cite_start]DataTypes.VeBalance memory veAccount = accountHistoryMapping[account][accountLastUpdatedAt]; [cite: 764]

            // RETURN: if both global and account are up to date [no updates required]
            [cite_start]if (accountLastUpdatedAt >= currentEpochStart){ [cite: 765]
                return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
            }
            
            // ... (rest of the function remains identical) ...
```

# Fix 2:

```solidity
// In DataTypes.sol
struct VeBalanceDelta {
    VeBalance additions;
    VeBalance subtractions;
}

// In VotingEscrowMoca.sol
// For userHistory/delegateHistory
mapping(address account => mapping(uint256 epoch => DataTypes.VeBalanceDelta)) public pendingAccountDeltas;

// For delegatedAggregationHistory
mapping(address user => mapping(address delegate => mapping(uint256 epoch => DataTypes.VeBalanceDelta))) public pendingAggregationDeltas;

// 2. Modify Delegation Functions
function delegateLock(){
    // ...
    // OLD: userHistory[msg.sender][nextEpochStart] = veUser;
    // NEW:
    pendingAccountDeltas[msg.sender][nextEpochStart].subtractions = _add(pendingAccountDeltas[msg.sender][nextEpochStart].subtractions, lockVeBalance);
    
    // ...
    // OLD: delegateHistory[delegate][nextEpochStart] = veDelegate;
    // NEW:
    pendingAccountDeltas[delegate][nextEpochStart].additions = _add(pendingAccountDeltas[delegate][nextEpochStart].additions, lockVeBalance);

    // ...
    // OLD: delegatedAggregationHistory[msg.sender][delegate][nextEpochStart] = _add(...)
    // NEW:
    pendingAggregationDeltas[msg.sender][delegate][nextEpochStart].additions = _add(pendingAggregationDeltas[msg.sender][delegate][nextEpochStart].additions, lockVeBalance);
    // ...
}

// 3. Modify _updateAccountAndGlobal (The State-Changing Path)

while (accountLastUpdatedAt < currentEpochStart) {
        accountLastUpdatedAt += EpochMath.EPOCH_DURATION;

        // 1. Apply expiries
        uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];
        veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);

        // 2. Apply pending delegation deltas
        DataTypes.VeBalanceDelta memory delta = pendingAccountDeltas[account][accountLastUpdatedAt];
        if (delta.additions.bias > 0 || delta.additions.slope > 0) {
            veAccount = _add(veAccount, delta.additions);
        }
        if (delta.subtractions.bias > 0 || delta.subtractions.slope > 0) {
            veAccount = _sub(veAccount, delta.subtractions);
        }
        
        // 3. Consume the event
        delete pendingAccountDeltas[account][accountLastUpdatedAt];

        // 4. Write final checkpoint
        accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
    }

// 4. Modify _viewForwardAbsolute (The "Seamless" View Path)
function _viewForwardAbsolute(
        DataTypes.VeBalance memory ve,
        uint256 startETime,
        uint256 targetTime,
        mapping(uint256 => uint256) storage accountSlopeChanges,
        // --- ADD NEW PARAMETER ---
        mapping(address => mapping(uint256 => DataTypes.VeBalanceDelta)) storage pendingDeltas,
        address account
    ) internal view returns (DataTypes.VeBalance memory) {
        // ...
        while (nextETime <= targetTime) {
            // 1. Apply expiries
            uint256 dslope = accountSlopeChanges[nextETime];
            if (dslope > 0) {
                ve = _subtractExpired(ve, dslope, nextETime);
            }

            // 2. Apply pending delegation deltas
            DataTypes.VeBalanceDelta memory delta = pendingDeltas[account][nextETime];
            if (delta.additions.bias > 0 || delta.additions.slope > 0) {
                ve = _add(ve, delta.additions);
            }
            if (delta.subtractions.bias > 0 || delta.subtractions.slope > 0) {
                ve = _sub(ve, delta.subtractions);
            }
            
            nextETime += epochDuration;
        }
        return ve;
    }
// balanceOfAtEnd & getSpecificDelegatedBalanceAtEpochEnd reply on _viewForwardAbsolute
```

```solidity
function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint256) {
            [cite_start]// ... (initial checks and findETime are the same) [cite: 407-411]

            [cite_start]DataTypes.VeBalance memory veBalance = accountHistory[foundETime]; [cite: 412]

            // --- MODIFIED CALL ---
            // OLD: veBalance = _viewForwardAbsolute(veBalance, foundETime, epochEndTime, userDelegateSlopeChanges[user][delegate]);
            // NEW:
            veBalance = _viewForwardAbsolute(
                veBalance,
                foundETime,
                epochEndTime,
                userDelegateSlopeChanges[user][delegate], // Pass the slope changes mapping
                pendingAggregationDeltas[user][delegate]  // Pass the pending deltas mapping
            );

            [cite_start]return _getValueAt(veBalance, epochEndTime); [cite: 414]
        }
```

# MY FIX

### VotingController calls 2 functions from VotingEscrowedMoca

1. `VotingController.vote()`: `balanceAtEpochEnd()`
2. `VotingController._claimDelegateRewards()`: `getSpecificDelegatedBalanceAtEpochEnd()`

## 1. in delegate, do not book to nextEpoch.
- book to a pending mapping
- both `balanceAtEpochEnd()` & `getSpecificDelegatedBalanceAtEpochEnd()` will reference this [in case state for tt account has not been update to push pending to actual]
- need settlement function `_updateDelegatedAggregation` that consumes pendingDeltas and updates the relevant mappings like `delegatedAggregationHistory`, `userHistory`, `delegateHistory`

## Process
1. book deltas to pending mapping
2. in `_updateAccountAndGlobal()`, call `_updateDelegatedAggregation` 
3. that will book pending into: `delegatedAggregationHistory`, `userHistory`, `delegateHistory`, 
4. `userDelegateSlopeChanges[user][delegate]` updates are handled within the delegate function

```solidity
            // transfer veMoca tokens from user to delegate 
            _transfer(msg.sender, delegate, lockVeBalance.bias);         // delegateLock
            _transfer(lock.delegate, msg.sender, lockVeBalance.bias);    // undelegateLock
            _transfer(lock.delegate, newDelegate, lockVeBalance.bias);   // switchDelegate

```
- token transfer should be handled when pending is merged. 


```solidity
            // transfer veMoca tokens from user to delegate 
            
```


- `balanceAtEpochEnd` -> relies on `delegateHistory`/`userHistory`
- `getSpecificDelegatedBalanceAtEpochEnd` -> relies on `_viewForwardAbsolute(...,userDelegateSlopeChanges[user][delegate])` which simulates the decay for user's delegated locks.

## details

`_bookPendingDelegations(address user, address delegate, uint256 targetEpoch)`

- has to be called by the user, to book his pending delegated deltas
- and we need to know against which delegate
- so this can only be called in the following functions:
1. delegateLock()
2. undelegateLock()
3. switchDelegate()

then for increaseAmount, increaseDuration:
- `if (lock.delegate != address(0)) {_bookPendingDelegations(msg.sender, lock.delegate, epoch)}`
- 

Cannot be called generically in `_updateAccountAndGlobal()`


## _bookPendingDelegations

1. delegateLock()
- `_bookPendingDelegations(user, delegate, userLastUpdatedAt)`
- 

for switchDelegate, we do not update the user 
- we `_updateAccountAndGlobal(oldDelegate,true)` + `_updateAccountAndGlobal(newDelegate,true)`
- do we need ot update the user?

# fix 3

```solidity
evaluate this simpler approach:

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// ... existing imports ...

contract VotingEscrowMoca is ERC20, Pausable {
    // ... existing state (no new mappings needed) ...

    // ------------------------------- Delegation Functions (Updated for Stacking) -------------------------------

    function delegateLock(bytes32 lockId, address delegate) external whenNotPaused {
        // sanity check: delegate
        require(delegate != address(0), Errors.InvalidAddress());
        require(delegate != msg.sender, Errors.InvalidDelegate());
        require(isRegisteredDelegate[delegate], Errors.DelegateNotRegistered()); // implicit address(0) check: newDelegate != address(0)
        DataTypes.Lock memory lock = locks[lockId];
       
        // sanity check: lock
        require(lock.lockId != bytes32(0), Errors.InvalidLockId());
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        // lock must have at least 2 more epoch left, so that the delegate can vote in the next epoch [1 epoch for delegation, 1 epoch for non-zero voting power]
        // allow the delegate to meaningfully vote for the next epoch
        require(lock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");

        // Update user & global: account for decay since lastUpdate and any scheduled slope changes | false since lock is not yet delegated
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint256 currentEpochStart,,) = _updateAccountAndGlobal(msg.sender, false);
        uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's current veBalance [no checkpoint required as lock attributes have not changed]
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock);

        // FIX 2: Stack multiple delegations - load existing prewritten for user (if any), apply sub delta, rewrite
        DataTypes.VeBalance memory existingUserCheckpoint = userHistory[msg.sender][nextEpochStart];
        veUser = existingUserCheckpoint.bias > 0 || existingUserCheckpoint.slope > 0 ? existingUserCheckpoint : veUser; // Use prewritten if exists
        veUser = _sub(veUser, lockVeBalance);
        userHistory[msg.sender][nextEpochStart] = veUser;
        userSlopeChanges[msg.sender][lock.expiry] -= lockVeBalance.slope;

        // Update delegate: true for delegated
        (, DataTypes.VeBalance memory veDelegate,,,) = _updateAccountAndGlobal(delegate, true);

        // FIX 2: Stack for delegate - load existing, apply add delta, rewrite
        DataTypes.VeBalance memory existingDelegateCheckpoint = delegateHistory[delegate][nextEpochStart];
        veDelegate = existingDelegateCheckpoint.bias > 0 || existingDelegateCheckpoint.slope > 0 ? existingDelegateCheckpoint : veDelegate;
        veDelegate = _add(veDelegate, lockVeBalance);
        delegateHistory[delegate][nextEpochStart] = veDelegate;
        delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;

        // transfer veMoca tokens from user to delegate
        _transfer(msg.sender, delegate, lockVeBalance.bias);

        // STORAGE: mark lock as delegated
        lock.delegate = delegate;
        locks[lockId] = lock;

        // delegatedAggregationHistory: Stack similarly
        DataTypes.VeBalance memory existingAgg = delegatedAggregationHistory[msg.sender][delegate][nextEpochStart];
        DataTypes.VeBalance memory aggDelta = _add(existingAgg, lockVeBalance);
        delegatedAggregationHistory[msg.sender][delegate][nextEpochStart] = aggDelta;

        //NOTE: FIX: slope changes for user's delegated locks [to support VotingController's claimRewardsFromDelegate()]
        userDelegateSlopeChanges[msg.sender][delegate][lock.expiry] += lockVeBalance.slope;
       
        // STORAGE: update global state
        veGlobal = veGlobal_;
        // Emit event
        //emit LockDelegated(lockId, msg.sender, delegate);
    }

    // Similarly update undelegateLock and switchDelegate:
    // - Load existing prewritten at nextEpochStart.
    // - Apply sub/add delta for veBalance and agg.
    // - Rewrite cumulative.
    // - Adjust slopes as before.

    // ------------------------------- _updateAccountAndGlobal (Updated for Gaps) -------------------------------

    function _updateAccountAndGlobal(address account, bool isDelegate) internal
        returns (
                DataTypes.VeBalance memory, DataTypes.VeBalance memory,
                uint256,
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage, // accountHistoryMapping
                mapping(address => mapping(uint256 => uint256)) storage // accountSlopeChangesMapping
            )
    {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping,
            mapping(address => uint256) storage accountLastUpdatedMapping
        )
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);
        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint256 lastUpdatedTimestamp_ = lastUpdatedTimestamp;
   
        // get current epoch start
        uint256 currentEpochStart = EpochMath.getCurrentEpochStart();
        // get account's lastUpdatedTimestamp: {user | delegate}
        uint256 accountLastUpdatedAt = accountLastUpdatedMapping[account];
        // LOAD: account's previous veBalance
        DataTypes.VeBalance memory veAccount = accountHistoryMapping[account][accountLastUpdatedAt]; // either its empty struct or the previous veBalance
        // RETURN: if both global and account are up to date [no updates required]
        if (accountLastUpdatedAt >= currentEpochStart){
            // update global to current epoch
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);
            return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
        }
        // ACCOUNT'S FIRST TIME: no previous locks created: update global & set account's lastUpdatedTimestamp [global lastUpdatedTimestamp is set to currentEpochStart]
        // Note: contract cannot be deployed at T=0; and its not possible for a user to create a lock at T=0.
        if (accountLastUpdatedAt == 0) {
            // set account's lastUpdatedTimestamp
            accountLastUpdatedMapping[account] = currentEpochStart;
            //accountHistoryMapping[account][currentEpochStart] = veAccount; // DataTypes.VeBalance(0, 0)
            // update global: may or may not have updates [STORAGE: updates global lastUpdatedTimestamp]
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);
            return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
        }
               
        // UPDATES REQUIRED: update global & account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            accountLastUpdatedAt += EpochMath.EPOCH_DURATION; // accountLastUpdatedAt will be <= global lastUpdatedTimestamp [so we use that as the counter]
            // --- UPDATE GLOBAL: if required ---
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
               
                // subtract decay for this epoch && remove any scheduled slope changes from expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve state for the new epoch
                totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt); // STORAGE: updates totalSupplyAt[]
            }
           
            // FIX 1: Check for prewritten checkpoint at this intermediate eTime
            DataTypes.VeBalance memory prewritten = accountHistoryMapping[account][accountLastUpdatedAt];
            if (prewritten.bias > 0 || prewritten.slope > 0) {
                // Use prewritten if exists (from forward-booking)
                veAccount = prewritten;
            } else {
                // Otherwise, reconstruct with decay/expiries
                uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];
                veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
            }
           
            // book account checkpoint (write or overwrite with correct value)
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
        }
        // STORAGE: update lastUpdatedTimestamp for global and account
        lastUpdatedTimestamp = accountLastUpdatedAt;
        accountLastUpdatedMapping[account] = accountLastUpdatedAt;
        // return
        return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
    }

    // _updateGlobal and other functions unchanged
}
```

1. alice creates lockA in Epoch0
2. alice delegates lockA in Epoch1 [This forward-books to Epoch2]
3. userHistory[Alice][epoch2] = {bias: 0, slope: 0}  [due to forward-booking deduction]
4. alice creates **lockB** in **Epoch1** [createLock(1000 MOCA, expires epoch 30)]
-- `_updateAccountAndGlobal(Alice)` runs but only up to epoch 1
-- `userHistory[Alice][epoch1] = {bias: 300, slope: 20}` (now has new lock)
-- `userSlopeChanges[Alice][epoch30] += 10`
5. alice calls: increaseAmount(lockB, 100 MOCA) in **Epoch3**
6. `_updateAccountAndGlobal(Alice)` runs from 1 to 3
- in the *Epoch2* update, since `userHistory[Alice][epoch2] = {bias: 0, slope: 0}`, the else condition will execute
- accountSlopeChangesMapping[Alice][2]

i am right, ai is wrong.


1. alice creates delegated lockA in Epoch0
- userHistory[Alice][epoch0] = `{bias: 0, slope: 0}` (Alice never holds it)
- delegateHistory[Bob][epoch0] = {bias: 200, slope: 10}

2. Alice Creates Personal Lock (During Epoch 1)
- `_updateAccountAndGlobal(Alice)` updates Alice to epoch 1
- userHistory[Alice][epoch1] = `{bias: 600, slope: 20}`

3. Alice Delegates Her Personal Lock (Still Epoch 1). 
Forward-books:
- Load existing: veUser = {bias: 600, slope: 20} 
- Subtract lock: veAlice = {bias: 0, slope: 0} 
- userHistory[Alice][epoch2] = {bias: 0, slope: 0} // Zero checkpoint!

4. Alice Creates Another Lock (Still Epoch 1)
- createLock(500 MOCA, expires epoch25)
- userHistoryMapping[Alice][1] = veAccount{bias: non-zero, slope: bias: non-zero};

<alice updated to epoch1>

5. Epoch 3: `_updateAccountAndGlobal(Alice)`
- Processing epoch 2: userHistory[Alice][epoch2] = {bias: 0, slope: 0}
- <else> condition executes
-> `uint256 expiringSlope` = accountSlopeChangesMapping[alice][2];
--> expiringSlope = 0
--> veAccount = _subtractExpired(`veAccount`, `expiringSlope=0``, `accountLastUpdatedAt:2`)
veAccount remains unchanged since _subtractExpired is passed 0 for expiringSlope.
veAccount will be reflective of her lock created after delegation 


```solidity
        // --- UPDATE ACCOUNT: Check for forward-booked checkpoint first ---
        if (hasForwardBooking[account][accountLastUpdatedAt]) {
            // Use the forward-booked value (even if zero)
            veAccount = accountHistoryMapping[account][accountLastUpdatedAt];
            // Clear the forward-booking flag as we've now processed it
            hasForwardBooking[account][accountLastUpdatedAt] = false;

            uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];
            veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);

            // book account checkpoint
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
        } else {
            // Standard reconstruction: apply scheduled slope reductions & decay
            uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];
            veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
            
            // book account checkpoint
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
        }

```

--------------------------------------------------------------------------------------------
--------------------------------------------------------------------------------------------


1. update account+global for both user and delegate, to current.
2. get prewritten checkpoint at nextEpochStart: to stack
```solidity
            // STACKING FIX: Check if there's already a forward-booked value[frm a prior delegate call in the same epoch]
            DataTypes.VeBalance memory veUserNextEpoch;
            if (userHistory[msg.sender][nextEpochStart].bias > 0 || userHistory[msg.sender][nextEpochStart].slope > 0) {
                // Use the existing forward-booked value as base
                veUserNextEpoch = userHistory[msg.sender][nextEpochStart];
            } else{
                veUserNextEpoch = veUser;
            }

            // Remove specified lock from user's aggregated veBalance of the next epoch [prev. forward-booked or current veBalance]
            // user cannot vote with the delegated lock in the next epoch
            veUser = _sub(veUserNextEpoch, lockVeBalance);
            userHistory[msg.sender][nextEpochStart] = veUser;
            userSlopeChanges[msg.sender][lock.expiry] -= lockVeBalance.slope;       // cancel scheduled slope change for this lock's expiry
            

            // STACKING FIX: Check if there's already a forward-booked value[frm a prior delegate call in the same epoch]
            DataTypes.VeBalance memory veDelegateNextEpoch;
            if (delegateHistory[delegate][nextEpochStart].bias > 0 || delegateHistory[delegate][nextEpochStart].slope > 0) {
                // Use the existing forward-booked value as base
                veDelegateNextEpoch = delegateHistory[delegate][nextEpochStart];
            } else{
                veDelegateNextEpoch = veDelegate;
            }
            
            // Add the lock to delegate's delegated balance
            veDelegate = _add(veDelegateNextEpoch, lockVeBalance);
            delegateHistory[delegate][nextEpochStart] = veDelegate;
            delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;
            
```
3. add/sub as above: book to Epoch:N+1
4. now the problem is tt in _updateAccountAndGlobal(), it will LOAD the veBalance at EpochN (in which delegation was called), apply slopeChanges, and **overwrite tt to EpochN+1**

```solidity
            // get account's lastUpdatedTimestamp: {user | delegate}
            uint256 accountLastUpdatedAt = accountLastUpdatedMapping[account];
           
            // LOAD: account's previous veBalance
>>>         DataTypes.VeBalance memory veAccount = accountHistoryMapping[account][accountLastUpdatedAt];      // either its empty struct or the previous veBalance

            // 
>>>         if (accountLastUpdatedAt >= currentEpochStart){}


            // UPDATES REQUIRED: update global & account veBalance to current epoch
            while (accountLastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                accountLastUpdatedAt += EpochMath.EPOCH_DURATION;       // accountLastUpdatedAt will be <= global lastUpdatedTimestamp [so we use that as the counter]

                // --- UPDATE GLOBAL: if required ---
                if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                    
                    // subtract decay for this epoch && remove any scheduled slope changes from expiring locks
                    veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                    // book ve state for the new epoch
                    totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);                 // STORAGE: updates totalSupplyAt[]
                }
                
>>>             // UPDATE ACCOUNT: apply scheduled slope reductions & decay for this epoch | cumulative of account's expired locks
                uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];    
>>>             veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
                
                // book account checkpoint 
                accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
            }

            // STORAGE: update lastUpdatedTimestamp for global and account
            lastUpdatedTimestamp = accountLastUpdatedAt;
            accountLastUpdatedMapping[account] = accountLastUpdatedAt;      
```

so why don't we eagerly update the account to **EpochN+1**, in delegate functions. 
then when `_updateAccountAndGlobal` is called, it exits early on `if (accountLastUpdatedAt >= currentEpochStart){..just updateGlobal..}`

1. is it okay to update globally separately?
- yes 
```solidity
                // apply scheduled slope reductions and handle decay for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
                // after removing expired locks, calc. and book current ve supply for the epoch 
                totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);           // STORAGE: updates totalSupplyAt[]
```
- global timestamp is updated, `veGlobal` & `totalSupplyAt`, are updated; and that is based on global `slopeChanges` mapping
- updating account ahead of global, does not adversely impact an independent global update.

**2. what problems are there is an account is updated ahead of global?**
- 



# appendix ref.

to apply slope changes in delegate

```solidity
function delegateLock(bytes32 lockId, address delegate) external whenNotPaused {
    // ... existing validation and updates ...
    
    // Get forward-booked values (with stacking)
    DataTypes.VeBalance memory veUserNext = /* stacked value */;
    DataTypes.VeBalance memory veDelegateNext = /* stacked value */;
    
    // APPLY SLOPE CHANGES: Check for expirations at nextEpochStart
    uint256 userExpiringSlopeAtNext = userSlopeChanges[msg.sender][nextEpochStart];
    if (userExpiringSlopeAtNext > 0) {
        veUserNext = _subtractExpired(veUserNext, userExpiringSlopeAtNext, nextEpochStart);
    }
    
    uint256 delegateExpiringSlopeAtNext = delegateSlopeChanges[delegate][nextEpochStart];
    if (delegateExpiringSlopeAtNext > 0) {
        veDelegateNext = _subtractExpired(veDelegateNext, delegateExpiringSlopeAtNext, nextEpochStart);
    }
    
    // Now write complete checkpoints
    userHistory[msg.sender][nextEpochStart] = veUserNext;
    delegateHistory[delegate][nextEpochStart] = veDelegateNext;
    
    // Could then do eager update if all slope changes are handled
    userLastUpdatedTimestamp[msg.sender] = nextEpochStart;
    delegateLastUpdatedTimestamp[delegate] = nextEpochStart;
}
```

```solidity
// Apply any locks expiring at nextEpochStart (epoch 2)
uint256 expiringSlope = userSlopeChanges[msg.sender][nextEpochStart];
veUser = _subtractExpired(veUser, expiringSlope, nextEpochStart);

// Then write complete checkpoint
userHistory[msg.sender][nextEpochStart] = veUser;
userLastUpdatedTimestamp[msg.sender] = nextEpochStart;
```



# increaseAmount, increaseDuration, createLock

when a forwardBooked point is first booked into the nextEpoch, it accounts for the slopeChanges for that epoch. so it's updated to account for all cumulative decay that occurs in that nextEpoch as seen in the delegate functions. 

is it possible, that the point was to be reupdated to account for a new dSlope? how could that come to be?
- createLock, increaseAmount, increaseDuration: lock must expire >= 2 epochs   
- so this is not possible correct?

## Example:

- Current epoch: N
- Forward-booking happens at: epoch N+1 (nextEpochStart)
- When forward-booking, all slope changes for epoch N+1 are already known and applied

**Could New Slope Changes Be Added to Epoch N+1?**

For a new slope change to be scheduled at epoch N+1, we'd need a lock expiring exactly at epoch N+1.

This could only be possible through: createLock, increaseAmount, increaseDuration
- all 3 functions implement a requirement that a lock must have at least 2 epochs left
- so it would not impact a forward-booked point in the nextEpoch, should there be one

**Conclusion**
Not possible for new slope changes to be scheduled at nextEpochStart after a forward-booked checkpoint is created. The 2-epoch buffer ensures that:

- Any locks created/modified during epoch N will expire at epoch N+2 or later
- Forward-booked checkpoints at epoch N+1 are complete and final
- No need to update them for new slope changes

This is a clever design that simplifies the implementation - forward-booked checkpoints are immutable (except for delegation stacking within the same epoch).