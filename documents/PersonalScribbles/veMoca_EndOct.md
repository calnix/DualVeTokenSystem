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