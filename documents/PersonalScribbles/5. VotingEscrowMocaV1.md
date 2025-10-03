# VotingEscrowMoca [veMoca]

## Table of Contents

- [Executive Summary](#executive-summary)
  - [Important Note: Lock Liveliness](#important-note-on-locks-liveliness)
- [Core Functions](#core-functions)
  - [Creating Locks](#creating-locks)
  - [Delegating Locks](#delegating-locks)
  - [Increasing Amount](#increaseamount)
  - [Increasing Duration](#increaseduration)
  - [Unlocking](#unlock)
- [Technical Implementation](#technical-implementation)
  - [Locking Tokens](#locking-tokens)
  - [Why Divide Slope by MAXTIME](#why-divide-slope-by-maxtime-not-lock-duration)
  - [Using Expiry Instead of Duration](#locks-using-expiry-instead-of-duration)
- [Epoch Mechanics](#epoch-mechanics)
  - [Freezing Intra-Epoch Decay](#freezing-intra-epoch-decay)
  - [Mid-Epoch Lock Creations](#handling-mid-epoch-lock-creations-in-tandem-w-freezing-intra-epoch-decay)
- [Additional Considerations](#others)
  - [Lock Duration Constraints](#allowing-for-lock-minduration--7-days)
  - [Mid-Epoch Created Locks](#mid-epoch-created-locks)

## Executive Summary

This is a dual-token Ve system, with dual-accounting system for multi-party delegation.

- Users lock Moca or esMoca tokens to mint veMoca, granting them voting power within the protocol.
- The amount of veMoca received increases with both the amount locked and the length of the lock period (up to a 2-year maximum).
- veMoca voting power decays linearly every second from the moment of locking until the lock expires.
- veMoca is non-transferable and can only be redeemed for Moca after the lock expires; early redemption of locks is not possible.
- Delegation to multiple parties is possible, but on a per lock basis; locks cannot be split.

> All calculations and updates are optimized for efficiency by aligning lock expiries to epoch boundaries and standardizing decay rates.

### Important Note: on lock's liveliness 

In `VotingController`, voting power within an epoch is fixed; there is no intra-epoch decay. 
This allows users to vote at any time during an epoch without rushing. 

This is achieved by benchmarking voting power to the end of said epoch; i.e. everyone gets decayed forward.
Put differently, users vote with the voting power they would have at the end of the Epoch.

**Due to forward-decay, the last meaningful epoch of a lock is one less than its actual:**

- Assume a lock ends at epoch N; it would have 0 veMoca at the end of epoch N. (would have non-zero veMoca at start of epoch N)
- It cannot vote in epoch N, since per `VotingController`, it has 0 votes [forward-decay].
- It can vote last in Epoch N-1, where it would have a non-zero bias for that epochEnd.

This means that the last meaningful voting epoch of a lock is `N-1` [where N is its final epoch].

**Thus to prevents ineffective delegations, increases, or extensions where the added value decays to zero before usable in future voting, we implement the following check:**

```solidity
            // must have at least 2 Epoch left to increase amount: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            require(oldLock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");
```

This check (in some variation) is found in the following functions:
- _createLockFor
- increaseAmount
- increaseDuration
- delegateLock
- switchDelegate

## Creating Locks 

- When a user locks the principal assets, they are creating a lock, each with a unique lockId.
- Each lock grants veMoca proportional to the amount locked and the chosen lock duration (up to 2 years).
- Locks are tracked as unique positions, and users can have multiple locks with different amounts, expiries and delegates.

## Delegating Locks

- Users can delegate individual locks to another address (delegate)
- This is to allow delegated voting, which will be handled by `VotingController.sol`
- Target Delegate must be registered through `VotingController.sol`, as there is a registration fee to be paid.
- Delegated voting power is tracked per lock and per delegate, and can be re-delegated or revoked by the lock owner.

The dual-accounting system works via the following mappings:

**Tracking personal locks**
```solidity
    // user personal data: perEpoch | perPoolPerEpoch
    mapping(address user => mapping(uint256 eTime => uint256 slopeChange)) public userSlopeChanges;
    mapping(address user => mapping(uint256 eTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
    mapping(address user => uint256 lastUpdatedTimestamp) public userLastUpdatedTimestamp;
```

**Tracking delegated locks**
```solidity
    // delegation data
    mapping(address delegate => bool isRegistered) public isRegisteredDelegate;                             // note: payment to treasury
    mapping(address delegate => mapping(uint256 eTime => uint256 slopeChange)) public delegateSlopeChanges;
    mapping(address delegate => mapping(uint256 eTime => DataTypes.VeBalance veBalance)) public delegateHistory; // aggregated delegate veBalance
    mapping(address delegate => uint256 lastUpdatedTimestamp) public delegateLastUpdatedTimestamp;
```

In short, any address has two 'pockets', one aggregating for their own personal locks, and another aggregating that which has been delegated to them.

Not only does this allow any address to be a delegate, it also allows them to vote with their personal holdings independently of that which has been delegated to them.

## increaseAmount 

Users can lock additional principal assets into a pre-existing lock, to increase its veBalance; no change to its expiry will be made. 

- Requires that lock.expiry > 2 Epochs
- This ensures that locks maintain at least two full epochs of duration, guaranteeing non-zero voting power for the next epoch after accounting for forward-decay benchmarking to epoch ends.
- It prevents ineffective delegations, increases, or extensions where the added value decays to zero before usable in future voting,
- otherwise, the increase would add principal to a lock that's already too close to expiry, making the additional veBalance ineffective for next-epoch voting


## increaseDuration

- Allows users to extend the expiry of an existing lock, increasing its duration
- Ensures the lock maintains at least two full epochs of duration after extension, preserving non-zero voting power for the next epoch (see "increaseAmount" rationale above).
- Updates the lock's expiry and recalculates veBalance

## unlock

- Users can withdraw principal assets from a lock only after it has expired.
- Unlocking fully burns the associated veMoca tokens. 


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

# Others

## Allowing for lock minDuration = 7 days

We cannot do 7-day locks when the system operates on 28 day epochs.
- min lock duration must always match the duration of an epoch.

Reason being that 1 core component of the system is a while loop that loops through all the lock expiry checkpoints to remove them from the system and user/delegate aggregation.
- That's why locks must start and end exactly on epoch boundaries.
- so that the while loop can increment as a step-wise function to process calculations
- this keeps it gas efficient and scalable

## Mid-epoch created locks

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