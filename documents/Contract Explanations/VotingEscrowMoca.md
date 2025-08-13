# VotingEscrowMoca [veMoca]

## Executive Summary

- Users lock Moca or esMoca tokens to mint veMoca, granting them voting power within the protocol.
- The amount of veMoca received increases with both the amount locked and the length of the lock period (up to a 2-year maximum).
- veMoca voting power decays linearly every second from the moment of locking until the lock expires.
- veMoca is non-transferable and can only be redeemed for Moca after the lock expires; early redemption of locks is not possible.
- Delegation to multiple parties is possible, but on a per lock basis; locks cannot be split.

> All calculations and updates are optimized for efficiency by aligning lock expiries to weekly epochs and standardizing decay rates.

## Creating Locks 

- When a user locks the principal assets, they are creating a lock, eacj with a unique lockId.
- Each lock can be thought of as a fixed-term deposit position, granting veMoca proportional to the amount locked and the chosen lock duration (up to 2 years).
- Locks are tracked as unique positions, and users can have multiple locks with different amounts, expiries and delegates.

## Delegating Locks

- Users can delegate individual locks to another address (delegate)
- Target Delegate must be registered through `VotingController.sol`, as there is a registration fee to be paid.
- Delegated voting power is tracked per lock and per delegate, and can be re-delegated or revoked by the lock owner.

This dual-accounting system works via the following mappings:

**Tracking personal locks**
```solidity
    // user personal data: perEpoch | perPoolPerEpoch
    mapping(uint256 epoch => mapping(address user => Account userEpochData)) public usersEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account userPoolData))) public usersEpochPoolData;
```

**Tracking delegated locks**
```solidity
    // Delegate registration data
    mapping(address delegate => DelegateGlobal delegate) public delegates;           
    // Delegate aggregated data (delegated votes spent, rewards, commissions)
    mapping(uint256 epoch => mapping(address delegate => Account delegate)) public delegateEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address delegate => Account delegate))) public delegateEpochPoolData;
```

In short, any address has two 'pockets', one aggregating for their own personal locks, and another aggregating that which has been delegated to them.



# Locking tokens

When someone locks tokens, they receive veTokens that decay over time.

This is defined by:

- `slope`: `amount / MAXTIME`   [*decay per second*]
- `bias`: `slope * duration`    [*initial veTokens*]

We always divide by `MAXTIME`, not the user’s lock duration.

## Why Divide Slope by MAXTIME (Not Lock Duration)?

**For Epoch Standardization:**

- Lock expiries are aligned to weekly epochs (week starts). 
- This books slope changes on an epoch basis (slopeChanges[wTime]), enabling efficient updates by looping step-wise (week-to-week) to apply decay and expiries. 
- It keeps global decay updates efficient, predictable, and scalable.

- Without this, arbitrary user-specific timestamps would require processing each unique end time, inflating complexity and gas costs.
- THis means that the update loop cannot be done in a consistent step-wise manner, but must cycle through all incoming timestamps - which is impossible.

**In short, we standardize everyone’s decay, to fit into epoch buckets, and this allows for a compact global update loop.**

## In simple terms

- We pretend the tokens are locked for the maximum time to calculate a standard decay rate (slope).
- Then, we issue veTokens (bias) based on the actual lock duration, ensuring they decay to exactly zero at the lock's end (aligned to a weekly epoch boundary for efficient processing).
- This keeps decay predictable and ensures the system only needs to update veToken balances once per epoch, not at random times.

# Locks: Using expiry, instead of duration

When calculating bias, we use expiry [an absolute timestamp] instead of duration:

- `slope = amount / MAXTIME` 
- `bias  = slope * expiryTimestamp`

This forms the veBalance:`{bias, slope}`, as if the lock started at t=0 (Unix epoch), yielding an inflated bias.

But we query the voting power via: `veBalance.bias - veBalance.slope * currentTimestamp`
alternatively expressed: `votingPower = bias - slope × currentTimestamp`

This subtraction correctly offsets the period before the lock began, ensuring accurate decay from the actual lock start time.

### Why this is an improvement 

**Better efficiency, less storage, and lower gas costs**

1. Stores less data (no need to record start time)
2. Makes vote decay and veToken queries lightweight and efficient 
3. Easy global/user aggregations (sum biases/slopes) and scheduled changes (e.g., slopeChanges[expiry]), avoiding start-time storage/queries.

# Freezing intra-epoch decay

Typically, in most ve systems, voting power is referenced at time of voting.

However, we don't want users to rush to vote: so we need a means to freeze/disregard intra-epoch decay.

**Option 1: voting power fixed within an epoch by referencing `veMoca.balanceOfAt(currenEpochStart)`**
- regardless of when users vote during an epoch, their voting power is unchanged and benchmarked to their voting power at the start of epoch.

**Option 2: voting power fixed by referencing `veMoca.balanceOfAt(endOfCurrentEpoch)`**
- apply the entire epoch's decay to everyone; i.e. forward-decay benchmarking 
- to that end "freezing" is a misnomer, but we'll live with it 

## Handling mid-epoch lock creations [in tandem w/ freezing intra-epoch decay]

**Option 1: voting power fixed within an epoch by referencing `veMoca.balanceOfAt(currenEpochStart)`**
- under this implementation option, a mid-epoch lock's voting power will be inflated
- because we are back-dating its voting power, from creation time, which would lower its bias offset
- this is the same bias offset that keeps voting power accurate by applying decay from T0 to now.

### We can solve this by making numerous changes to the system, centred around forward-booking lock creations

To solve this, update `_createLockFor` to book new locks to `userHistory[user][nextEpochStart]`, ensuring mid-epoch locks only affect the next epoch.
- **this means mid-epoch created locks can only vote next epoch**
- when voting in the next epoch, there wil be decay arising from timeDelta btw creationTime and nextEpochStart.
- e.g. lock created 15 Jan. can vote on 1 Feb[new epoch], decay from 15 Jan - 30 Jan applied. 

A minor issue of note: in the first epoch, not voting can be done, since any locks created are forward-booked. 
Therefore, the first epoch of rewards are forgone.

> *Additionally, booking a lock to nextEpochStart could require other non-obvious changes*

**Option 2: voting power fixed by referencing `veMoca.balanceOfAt(endOfCurrentEpoch)`**
- under this implementation option, a mid-epoch lock's voting power will be forward decayed, like every other lock 
- forward-decay benchmarking is consistently applied to all locks
- crucially this allows mid-epoch created locks to vote immediately in the same epoch; they need not wait for the next epoch.

**Conclusion: We will implement Option 2**

It greatly improves user experience, and requires lesser changes and introduces fewer complexities. 
Additionally, in the first epoch, locks created allow immediate voting and user participation [unlike option 1].

*The only notable downside is that, on the final epoch:*
- users would have a non-zero number of votes at epoch start.
- but due to the forward-decay benchmarking, they would not be able to vote, since its zero-ed out
- this is acceptable

# Allowing for lock minDuration = 7 days

We cannot do 7-day locks when the system operates on 28 day epochs.
- min lock duration must always match the duration of an epoch.

Reason being that 1 core component of the system is a while loop that loops through all the lock expiry checkpoints to remove them from the system and user/delegate aggregation.
- That's why locks must start and end exactly on epoch boundaries.
- so that the while loop can increment as a step-wise function to process calculations
- this keeps it gas efficient and scalable

# Mid-epoch created locks

Consider 2 identical locks, identical amount and same expiry time [lock A and lock B]

- lockA is created mid-way in Epoch 1 at 15th day.
- lockB is created 5 days after lockA; still within Epoch 1.

**Would they have the exact same veBalances?**
- Yes

```markdown
    The slope is derived as principal / MAX_LOCK_DURATION.
    The bias is derived as slope * expiry.
    Neither the bias nor the slope depends on the lock's creation timestamp—only on the principal and expiry (which are identical for both locks).

    The mid-epoch creation times (day 15 vs. day 20) do not affect the VeBalance struct, as the system does not store or factor in a creation timestamp for veBalance calculations. 
    The earlier creation of lock A means it provided voting power for those extra 5 days, but from lock B's creation onward, both locks yield identical voting power at any given time (bias - slope * t), consistent with the identical structs.

    Their voting power would not differ in epoch 2 (or any subsequent epoch). The difference in creation time does not result in a difference in the decay applied, as the veBalance for each lock (bias and slope) is derived solely from the principal amount and the absolute expiry timestamp—neither of which incorporates the creation timestamp. Consequently, at any given evaluation point (e.g., the end of epoch 2, as used for voting power benchmarking in the VotingController contract), both locks yield identical voting power values.
```

# Wishlist 

## Auto-extender

```Prakhar
What do you think of 'Auto-Max Lock' similar to what aerodrome has?
This mode when turned on lets users lock their tokens for the maximum period (2 years) while ensuring their voting power does not decay over time effectively keeping it at 100% for the full duration.

They cant withdraw their locked tokens unless they disable 'Auto-Max Lock'. Once they disable this, they can withdraw the tokens once the lock expires
Basically after every epoch, the expiry of the lock is auto-extended to 2 years
```