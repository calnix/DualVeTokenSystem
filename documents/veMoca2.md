# veMoca


## min. lock duration: freezing decay + delegation

To understand the minimum duration of a lock, consider the scenario:
1. user creates lock in epoch 1
2. user delegates lock in epoch 2; user still has voting rights of said lock in epoch2
4. delegation effect occurs in epoch 3; delegate can now vote with lock
5. in epoch 4 lock's voting power is forward decay-ed to 0

Therefore, the min. requirement: currentEpoch + 3
This minimum is a result of two requirements:
1. freezing decay by forward-decaying all locks' voting power to epoch end,
2. delegating a lock only takes effect in the next epoch


## _updateAccountAndGlobal

- an address has both personal holdings as well as delegated holdings
- false: updates the address's personal holdings
- true: updates the address's delegated holdings

slopeChanges and decay are applied; to both global and account.
timestamps are updated. 

this serves to bring global & account updated to currentEpochStart.



## delegation: fwd-booking to nextEpoch

**Why is acceptable?**

- when we convert a lock to veBalance: `DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock);`
- its `lockVeBalance` remains unchanged, regardless when in time the conversion happens

*Put differently, a lock's veBalance is constant throughout time*

```solidity
function _convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
    DataTypes.VeBalance memory veBalance;

    veBalance.slope = (lock.moca + lock.esMoca) / uint128(EpochMath.MAX_LOCK_DURATION);
    veBalance.bias = veBalance.slope * lock.expiry;

    return veBalance;
}
```
This is because we calculate on the basis of its expiry, not duration.
Its an absolute-bias system.

**So forward-booking a lock's veBalance to the next epoch**: `userHistory[msg.sender][nextEpochStart] = _sub(veUser_, lockVeBalance);`

**will not cause issues.**


```solidity
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

    function _subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure 
    returns (DataTypes.VeBalance memory) {

        uint128 biasReduction = expiringSlope * expiry;

        // defensive: to prevent underflow [should not be possible in practice]
        a.bias = a.bias > biasReduction ? a.bias - biasReduction : 0;      // remove decayed ve
        a.slope = a.slope > expiringSlope ? a.slope - expiringSlope : 0; // remove expiring slopes
        return a;
    }
```

## undelegating then redelegating again immediately

in undelegate, lock.delegate is deleted, allowing the lock owner to redelegate immediately.
- this might seem like a bug
- but is not

**The Math: "Undelegate + Delegate" = "Switch"**

If a user performs undelegateLock and then delegateLock in the same epoch, the contract schedules two opposing updates for the Next Epoch. These cancel each other out perfectly for the user.

```bash
| Action         | Effect on User's Pending Deltas   | Effect on Delegate A        | Effect on Delegate B     |
|----------------|-----------------------------------|-----------------------------|--------------------------|
| Undelegate     | Add Voting Power (`+V`)           | Remove Power (`−V`)         | No Change                |
| Delegate       | Subtract Voting Power (`−V`)      | No Change                   | Add Power (`+V`)         |
| **Net Result** | 0 Change (`+V` and `−V` cancel)   | −V (Lost Power)             | +V (Gained Power)        |
```

This is mathematically identical to switchDelegate, where A loses power and B gains it, with the user acting as the net-neutral conduit.

The implementation is mathematically safe, although semantically wrong, in the sense that we update lock.delegate immediately, when the change in delegation effect takes place in the next epoch.

## min amount check

```
MIN_LOCK_AMOUNT = 1E13 wei = 0.00001 tokens
MAX_LOCK_DURATION = 728 days = 62,899,200 seconds

slope = 1E13 / 62,899,200 ≈ 158,989 wei per second
```

The minimum amount for non-zero voting power. 
Could consider increasing to 1e18 wei, 1 MOCA token.


## unlock does not bother with delegation management

**Not necessary**

- the moment unlock() is called, the lock is already expired.
- therefore, the veBalance (voting power) is already calculated as 0 by the system.
- Updating the delegate's history at this specific moment is effectively updating them with a "zero change" event, which wastes gas.

**Why update msg.sender instead?**

- owner is initiating the txn and paying the gas for it 
- so we update their state


1. Voting Power Decays Automatically (Lazy Evaluation) 
- The core mechanic of the ve system is that voting power is not manually removed when a lock expires; it mathematically decays to zero based on time.

- Slope Changes: When the lock was originally delegated (or created), a slopeChange was scheduled for the specific expiry timestamp

- Automatic Expiry: When the expiry time is passed, any function reading the delegate's balance (like balanceOfAt or _updateAccount...) will automatically trigger _subtractExpired

Result: The delegate's voting power associated with that lock is removed automatically by the contract's math as soon as the epoch passes. You do not need to explicitly touch the delegate's account in unlock() to "clear" the votes.


## getSpecificDelegatedBalanceAtEpochEnd

- no need to bother with `_viewAccountAndGlobalAndPendingDeltas()` to update user or delegate
- focus strictly on the User-Delegate Pair Mappings

- utilizes a "Quad-Accounting" system where the state of a specific (user, delegate) relationship is tracked in its own isolated set of mappings. 
- these user-delegate pair mappings form a completely independent tracking system. 
- allows the VotingController to accurately determine reward distribution based on the specific user-delegate relationship without needing to reconstruct the entire state.

### The Two Parallel Streams

**1. Stream A: The Aggregate Stream (Global Account State)**

- Purpose: Tracks the total voting power of an account (User or Delegate) for voting and total supply calculations.
- Mappings: `userHistory`, `delegateHistory`, `slopeChanges`, `userSlopeChanges`, `userPendingDeltas`.
- Used By: `balanceOf()`, `totalSupply()`, and `_viewAccountAndGlobalAndPendingDeltas`.


**2. Stream B: The Parallel Stream (Pair-Specific State)**

- Purpose: Tracks specifically how much voting power User A has contributed to Delegate B.
- Mappings: `delegatedAggregationHistory`, `userDelegatedSlopeChanges`, `userPendingDeltasForDelegate`.
- Used By: `getSpecificDelegatedBalanceAtEpochEnd` (for calculating the user's share of a delegate's rewards).

```solidity
// These mappings track the user-delegate relationship independently:
delegatedAggregationHistory[user][delegate][timestamp]     // Historical veBalance for this pair
userDelegatedSlopeChanges[user][delegate][timestamp]       // Slope changes for this pair  
userPendingDeltasForDelegate[user][delegate][timestamp]    // Pending deltas for this pair
userDelegatedPairLastUpdatedTimestamp[user][delegate]      // Last update for this pair
```