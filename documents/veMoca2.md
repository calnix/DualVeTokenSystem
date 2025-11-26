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

## DOS-ing switchDelegate

### The Attack:

1. Create a lock with the entire supply of Moca, 8.89 billion 
2. Delegate to delegate A
3. Repeatedly call switchDelegate between A ↔ B within the same epoch
4. Each switchDelegate call accumulates lockVeBalance into the pending additions/subtractions

**Overflow Calculation**

- `uint128.max` = 2^128 - 1 ≈ 3.4 × 10^38
- `MAX_LOCK_DURATION` = 728 days = 62,899,200 seconds
- Current timestamp ≈ 1.75 × 10^9 (year 2025)
- Future expiry ≈ 1.81 × 10^9 seconds

For minimum lock amount (assuming 1e18 wei / 1 MOCA):
- slope = 1e18 / 62,899,200 ≈ 1.59 × 10^10
- bias = slope × expiry = 1.59 × 10^10 × 1.81 × 10^9 ≈ 2.88 × 10^19

Switches needed to overflow `bias` (limiting factor):
`uint128.max / bias = 3.4 × 10^38 / 2.88 × 10^19 ≈ 1.18 × 10^19`

= ≈11.8 quintillion switches (1.18 × 10^19) would be required to overflow.

**Why This Attack is Impractical:**

1. Gas Cost: ~100k gas per switch × 11.8e18 switches × 30 gwei [insufficient Moca Supply]
2. Block Gas Limit: Would require more blocks than the heat death of the universe


### The Attack under impractical scenario

- the attacker commits the entire supply of MOCA 
- the attacher also somehow has sufficient gas to execute the attack

Essentially we are allowing the attacker to break the totalSupply of MOCA, to assess feasibility.
If not possible under these conditions, then not possible at all.

1. Total MOCA supply: 8.89 × 10^9 tokens = 8.89 × 10^27 wei
2. MAX_LOCK_DURATION = 728 days = 62,899,200 seconds
3. uint128.max ≈ 3.4 × 10^38
4. Expiry ≈ 1.81 × 10^9 seconds

**For a lock with ENTIRE MOCA supply:**
```bash
slope = 8.89 × 10^27 / 62,899,200 ≈ 1.413 × 10^20
bias  = slope × expiry = 1.413 × 10^20 × 1.81 × 10^9 ≈ 2.56 × 10^29
```

**Switches needed to overflow:**
```bash
uint128.max / bias = 3.4 × 10^38 / 2.56 × 10^29 ≈ 1.33 × 10^9
```
≈ 1.33 billion switches

### Feasibility on Moca Chain

| Parameter              | Assumption       |
|------------------------|------------------|
| Block time             | 1 second         |
| Gas per switchDelegate | ~150,000 gas     |
| Block gas limit        | ~30,000,000 gas  |
| Switches per block     | ~200             |

`EPOCH_DURATION` = 14 days = 1,209,600 seconds


| Metric                              | Value          |
|-------------------------------------|----------------|
| Blocks per epoch                    | 1,209,600      |
| Switches per block (~30M gas limit) | ~200           |
| Max switches per epoch              | ~242 million   |
| Switches needed                     | ~1.33 billion  |

## Assuming block gas limit is: 200,000,000

**Recalculation with 200M Block Gas Limit**

| Parameter                    | Value           |
|------------------------------|-----------------|
| Block gas limit              | 200,000,000     |
| Gas per switchDelegate       | ~150,000        |
| Switches per block           | 1,333           |
| Blocks per epoch (14 days)   | 1,209,600       |
| Max switches per epoch       | ~1.61 billion   |
| Switches needed              | ~1.33 billion   |

Result: Attack is theoretically possible if you ignore other constraints like max txns per block.

With 200M block gas limit:
1.33B needed < 1.61B max per epoch ✓

**Attack Execution Requirements:**

| Metric        | Value                                      |
|---------------|--------------------------------------------|
| Blocks needed | ~998,000 blocks                            |
| Time required | ~11.5 days (within 14-day epoch)           |
| Gas consumed  | ~2 × 10^14 gas                             |
| Gas cost      | ~200,000 MOCA (~0.000022% of supply) @ 1 gwei |

**Sensitivity to Gas Cost**

The feasibility is on the edge depending on actual `switchDelegate` gas cost:

| Gas per switch | Switches/block | Max per epoch | Feasible?        |
|----------------|----------------|---------------|------------------|
| 125,000        | 1,600          | 1.94B         | ✅ Yes           |
| 150,000        | 1,333          | 1.61B         | ✅ Yes (barely)  |
| 175,000        | 1,142          | 1.38B         | ✅ Yes (barely)  |
| 200,000        | 1,000          | 1.21B         | ❌ No            |
| 250,000        | 800            | 0.97B         | ❌ No            |