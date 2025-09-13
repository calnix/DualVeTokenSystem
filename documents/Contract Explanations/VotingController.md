# VotingControllers


Btw, this ve system we've got going is pretty sick, engineering wise.
Dual-token ve locking with an inbuilt delegate system with a  multi-sub account structure supporting it
It's one of a kind

I can tell you for a fact that most protocols just lifted curve's ve implementation without really understanding it
And it's not even designed properly to begin with nor optimized

justify the above #1:
- curve uses block interpolation; 
- meaning they track decay and rewards based on block interpolation, to represent the passage of time,
- which means on fast chains, it wouldn't work well, as it would heavily round down the values.
- often flooring to 0 unnecessarily

The people who wrote it didn't think it through. 
Curve was wrong. they should have used time instead of block.numbers.

Block number is not reliable for fast chains like most L2, bsc, sonic.
the interpolation rounds down very quickly

justify the above #2:
- delegate system onchain + fees implemented
- typically protocols handle it offchain through some relayer service; or they point you to them

# Mappings

## **Generics**
- `epochs`      -> epoch overview
- `pools`       -> global pool overview
- `epochPools`  -> pool overview for a specific epoch


## **User/Delegate data**
- `usersEpochData` / `delegateEpochData`: Track per-epoch data for each address, separately for user and delegate roles (`Account` struct).
- `usersEpochPoolData` / `delegatesEpochPoolData`: Track per-epoch, per-pool data for each address, again split by user and delegate roles (`Account` struct).

These paired mappings implement a dual-accounting model:

- Every address has two logical accounts: a user account and a delegate account (`struct Account { uint128 totalVotesSpent, uint128 rewards, ... }`).
- When an address votes with its own voting power, its votes and rewards are recorded in `usersEpochData` and `usersEpochPoolData`.
- When an address votes using voting power delegated to it by others, its activity is recorded in `delegateEpochData` and `delegatesEpochPoolData`.

In the `vote()` function, these are abstracted as `accountEpochData` and `accountEpochPoolData`.
All voting activity—whether personal or delegated—is tracked for each address at both the {epoch, address} and {epoch, pool, address} levels.

> Additionally, votes are tracked at a global epoch, global pool, and {epoch-pool} level.
> `epochs`, `pools`, `epochPools`

### rewards

`userDelegateAccounting` -> epoch->user->delegate: [Account]
- for this {user-delegate} pair, what was the user's {rewards,claimed}
- *used where?*


---

**Delegate registration + feePct**
- `delegates`               ->  `struct Delegate{isRegistered, currentFeePct, nextFeePct, etc}`
- `delegateHistoricalFees`  -> for historical fee updates, so that users can claim against correct fee, and not prevailing.


## Voting

### 1. `vote()`

```solidity
function vote(address caller, bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated)
```

- users can only vote on the current Epoch
- current epoch should not be finalized - indicating open season.
- `isDelegated` flag indicates that the caller is allocating votes from his delegations; instead of personal votes.
- voting power is determined based on forward-decay: `_veMoca().balanceAtEpochEnd`


### 2. `migrateVotes`

- users can migrate votes from one batch of pools to another
- dstPools must be active
- srcPools do not have to be active
- partial and full migration of votes supported

----


## Delegate Leader Unregisters Mid-Epoch With Active Votes

1. Alice unregisters as delegate
2. Alice cannot accept new delegations
3. Alice cannot vote with delegated votes - effective immediately.
4. Users who delegated will not regain their voting power - they must manually call undelegate() function on VotingEscrowedMoca.sol

### delegate fees

problem on delegate fees:
- delegate changes fees in epoch N
- user claims rewards from his delegated votes, for epoch N-2
- user would be paying fees as per the latest fee update
- essentially, fees are a static reference. they aren't indexed on an epoch basis.

when claiming,
- get epoch:fee, by referencing _delegateHistoricalFees

how would _delegateHistoricalFees be populated
- register() -> _delegateHistoricalFees[currentEpoch][fee]
- updateFee() -> _delegateHistoricalFees[currentEpoch][newFee]

but what about the epochs where no fee change occurred? 
- how do we get the fee, since the mapping would return 0 for those epochs?

**FOR NOW: users are charged prevailing fee, currentFee at time of claim. simple.**

> https://www.notion.so/animocabrands/Delegate-Leader-Lifecycle-20d3f5ceb8fe80e8a9e5f9584dc1683a?d=2593f5ceb8fe804aabab001c562d3679#22a3f5ceb8fe8064b5f9eda6221acd02

## Verifiers and Subsidies

`PaymentsController.deductBalance()` books weights accrued per {verifier,schema} -> poolId
⦁	mapping on Payments: epoch => poolId => totalWeight | totalWeightPerPoolPerEpoch (++ weight=fee*tier)
⦁	mapping on Payments: epoch => poolId => verifierId => verifierTotalWeight (++ weight=fee*tier)
⦁	mapping on Payments: epoch => poolId => schemaId => schemaTotalWeight (++ weight=fee*tier)

On VotingController, when an epoch ends:
⦁	verifiers can claim based on `verifierTotalSubsidyForPool`/`totalSubsidyPerPoolPerEpoch` * `poolSubsidy`
⦁   the subsidies allocated to a pool is split amongst the verifiers, based on their total expenditure

**Will require the epoch to end before we can deposit subsidies.**

*Note*:
⦁	if we add a schema mid-epoch to a voting pool, its prior txns in the same epoch will not count for subsidies.
⦁	if we remove a schema mid-epoch from a voting pool, its weight can be removed from the pool and subsidy calculations. its prior txns in the same epoch will not receive any subsidies.

**Process**
1. setEpochSubsidies() -> total to be distributed across all pools. can be set at the start 
2. depositSubsidies() -> at the end of epoch
3. finalizeEpoch() -> to get each pool's `totalSubsidies`
4. claimSubsidies() -> verifiers claim subsidies via: `verifierTotalSubsidyAccruedForPool`/`totalSubsidyAccruedForPool` * `pool.totalSubsidies`
4i. `[verifier's portion of subsidy]` / `[total subsidies accrued by all verifiers in pool]` * `[pool's allocated subsidies; based on votes]`


`finalizeEpoch(uint128 epoch, bytes32[] calldata poolIds)`
- gets totalVotes + totalSubsidies for epoch -> calcs. `epochData.subsidyPerVote`
- for each pool, in poolId[], calc. `totalSubsidies`

> https://www.notion.so/animocabrands/Tiers-Stake-MOCA-optionally-to-be-eligible-for-subsidy-2373f5ceb8fe80ab8e9ae00f2283590e#25a3f5ceb8fe80e2baaedb42498381ec

## Voters and Rewards


    /** deposit rewards for a pool
        - rewards are deposited in esMoca; 
        - so cannot reference PaymentsController to get each pool's rewards
        - since PaymentsController tracks feesAccruedToVoters in USD8 terms
        
        Process:
        1. manually reference PaymentsController.getPoolVotingFeesAccrued(uint256 epoch, bytes32 poolId)
        2. withdraw that amount, convert to esMoca [off-chain]
        3. deposit the total esMoca to the 
    */


- voters receive rewards, as esMoca
- rewards financed by the `VOTING_FEE_PERCENTAGE` cut from PaymentsController.sol
- voters can only claim rewards on an epoch that has been finalized [admin must have called `finalizeEpoch`]
 
Voters vote on credential pools in Epoch N: 
- Voting rewards would be a portion of verification fees in the next epoch, **Epoch N+1**
- Voting is taking a bet on the future
- *Verification fees in Epoch N+1 will be rewarded to them at the **end of Epoch N+1; once the epoch is finalized***
- userPoolVotes / totalPoolVotes * poolRewards

***Note:***
- *Voters can claim fees proportion to their votes [in Epoch N], at the end of Epoch N+1.*

**PROCESS:**
0. withdraw USD8 from `PaymentsController._epochFeesAccrued[currentEpoch]`; convert to esMoca 
1. depositRewardsForEpoch() -> sets `rewardsPerVote` for each pool
2. users can call `claimRewards()`


---


# Execution flow

At the end of epoch:

## 1. Admin calls: `depositEpochSubsidies`

Why call at the end of epoch?
- `epoch.totalVotes` is finalized
- can sanity check the calculation: `subsidyPerVote` =  `subsidiesToBeDeposited` / `epoch.totalVotes`
- to ensure that we do not deposit an insufficient amount of subsidies, such that `subsidyPerVote` is rounded to `0`.
- this will prevent esMoca subsidy deposit from being stuck on the contract, and unclaimable by verifiers. 

Note:
- Subsides for each epoch are decided by the protocol and financed by the treasury.
- Some epochs may have `0` subsidies.

We have a `previewDepositSubsidies` function to get `subsidyPerVote` calc. before calling `depositSubsidies` as a convenient check.
- hence, `depositSubsidies` is only callable once for the epoch.
- it cannot be called again to make modifications/overwrites.
- protocol admin should utilize `previewDepositSubsidies` and make up their minds before calling `depositSubsidies`

**Sets `isSubsidiesSet=true` and `subsidyPerVote` in Epoch struct.**

## 2. Admin calls: `finalizeEpochRewardsSubsidies`

Called multiple times, to iterate through full list of pools

**For rewards:**
- for each pool, sets its rewards, hence `bytes32[] calldata poolIds, uint256[] calldata rewards`
- rewards financed by the `VOTING_FEE_PERCENTAGE` cut from PaymentsController
- generating `uint256[] calldata rewards`: protocol will manually refer to `PaymentsController._epochPoolFeesAccrued[epoch][poolId].feesAccruedToVoters`
- does not call the PaymentsController contract to pull the figures; to allow discretionary changes.

**For subsidies:**
- set value of pool's `subsidyPerVote` via `epochPools[epoch][poolId].totalSubsidies`
- verifiers can claim based on `verifierTotalSubsidyForPool`/`totalSubsidyPerPoolPerEpoch` * `poolSubsidy`

----

After finalizeEpochRewardsSubsidies is completed, and the flag `isFinalized` is set to `true`
- users can claim rewards
- verifiers can claim subsidies


## 3. Voters call: `claimRewards and/or `



# Design choices

## Problem: Rewards distribution + calculation

- Rewards are pool-specific and fixed based on verification fees accrued per pool (some pools may have 0 rewards if no fees).
- Original design pre-calculated rewardsPerVote = (poolRewards * 1e18) / totalVotes per pool in finalizeEpochRewardsSubsidies, requiring it >0 to avoid "invalid" values.
- If poolRewards was small relative to `totalVotes`, this floored to 0, causing a revert and blocking epoch finalization—leaving rewards undistributable and "stuck" in the contract.
- Claims multiplied `userVotes` by `rewardsPerVote` (potentially inflated or 0), risking incorrect distributions or no claims at all.
- Constraint: Could not increase rewards per pool to force non-zero `rewardsPerVote`, as this would violate pool-specific fee-based financing.

**Considerations**

- Stuck Funds: Undistributable rewards remained in the contract indefinitely, with no recovery mechanism.
- Per-Pool Isolation: Rewards must remain unique per pool (no global pooling); 0-reward pools should be handled gracefully without affecting others.
- Claim Inefficiencies: Pre-calc didn't handle flooring well; small voters might get nothing, but large ones should still claim proportionally.

**Solution**

- Remove Pre-Calculations: Eliminate `rewardsPerVote` from `depositRewards()` and finalize logic; instead, set totalRewards (or totalSubsidies) directly if >0 and totalVotes >0.
- Zero Handling: Skip calcs/transfers for 0 amounts; gracefully continue in claims (e.g., skip pools if totalRewards=0 or userVotes=0).
- Direct Proportional Calculation in Claims: Shift math to claim time:
    - For rewards: userRewards = (userVotes * totalRewards) / totalVotes per pool (integer division floors small shares to 0).
    - For subsidies: In finalize, calc poolSubsidies = (poolVotes * totalSubsidies) / totalVotes per pool; claims use existing proportional share of poolSubsidies.

**Rationale for Chosen Approach**
- Prevents Stuck Funds Without Altering Rewards: Direct calc allows partial distribution (large voters claim >0 even for small totals), with sweeps ensuring no permanent loss—addresses core issue without increasing pool rewards or mixing across pools.
- Maintains Per-Pool Uniqueness: All operations (finalize, claims) loop per pool using isolated totals; no global redistribution, preserving fee-based specificity (e.g., 0-reward pools yield 0 claims without blocking others).
- Handles Truncation Gracefully: Flooring happens at the user/pool level (not globally), enabling distribution where possible (e.g., totalRewards=5e18, totalVotes=10e18: user with 3e18 votes gets 1.5e18 floored to 1e18; remainder sweepable).
- Flexibility for Small/Zero Amounts: Avoids reverts for tiny rewards/subsidies, supporting scenarios like low-fee epochs or minimal rewards allocation better.
- Gas and Simplicity Benefits: Removes storage fields/writes (e.g., no subsidyPerVote), reduces revert risks, and parallels subsidies/rewards for consistent code.
- Consistency with Subsidies: Applied similar logic to global subsidies for uniformity, shifting flooring to per-pool level to avoid deposit blocks.

## On nested mapping in `UserDelegateAccount`

for claimRewardsFromDelegate, user is expected to call this function repeatedly: 
- for the same delegate, different pools
- for a different delegate, different pools

User could have delegated to multiple delegates; and those delegates could have voted for different pools; in some cases different delegates might have allocated to the same pool.
- that means, in `claimRewardsForDelegate`, we cannot set: `require(userDelegateAccounting[epoch][msg.sender][delegate].totalRewards == 0, Errors.RewardsAlreadyClaimed());`

Problem:
- This would only allow calling of the function once, and not repeatedly to cycle through all the pools.
- we also do not want users to be able to repeatedly claim rewards for the same pool.

Solution:

Since delegations are epoch-level (not per-pool), but claims must prevent per-pool re-claims per delegate (while allowing same pool via different delegates), we need per-pool tracking within each user-delegate-epoch entry. Users can delegate to multiple delegates, and delegates can vote in overlapping pools, so claims are independent per delegate-pool pair.

Introduce a new struct `UserDelegateAccount` for userDelegateAccounting, with:
- aggregate tracking for net claimed rewards
- nested mapping for per-pool gross rewards (set when claimed; use == 0 as "not claimed" flag).

## On Rewards calculations

Voting rewards are financed based on verification fees accrued for a pool
- i.e. rewards are strictly per-pool (unique to each pool's accrued verification fees, including possible 0 for some pools)

**Problem:**
- Calculating rewards for users can lead to precision loss due to integer arithmetic, 
- Especially for users with fewer votes, potentially resulting in zero rewards due to rounding.

**There are 2 approaches:**

*1) Precompute `rewardsPerVote` for each pool, when depositing rewards.* [suboptimal]

- `rewardsPerVote` would be multiplied by a user's votes in `claimRewards()`. 
- This can cause early truncation, rounding small rewards to zero for users with fewer votes.


*2) Calculate rewards directly in `claimRewards()` using (`userPoolVotes` * `totalRewards`) / `poolTotalVotes`*

- This performs multiplication before division, preserving precision and reducing the chance of rewards rounding to zero.


**Why Approach 2 Wins:**
- Multiplying before dividing minimizes truncation, so users with small vote shares are less likely to get zeroed out—fairer for everyone, especially smaller voters.

Bottom line: Approach 2 maximizes fairness and precision for all users.

### Handling Solidity Rounding Residuals

Approach 2 improves precision by multiplying before dividing, so small vote holders are less likely to get zeroed out. Still, integer division in Solidity means some small rewards can round down to zero—can't avoid this entirely.

> finalizeEpochRewardsSubsidies() sets: epochPools[epoch][poolId].totalRewardsAllocated = poolRewards

*Example:*

```bash
- Assume: totalRewards=5, totalVotes=10:
    - User A with 3 votes: (3*5)/10 = 15/10 = 1 (floored from 1.5).
    - User B with 1 vote: (1*5)/10 = 5/10 = 0 (floored from 0.5).

UserB has no rewards to claim.
``` 

This will result in residual rewards on the contract, that are claimable by no one.
With `withdrawUnclaimedRewards()`, we can extract both unclaimed rewards as well as residual amounts (from rounding) after a 1-year period.

> there is an inconsistency in that subsidies that can't get distributed have a specific extract fn: withdrawResidualSubsidies

## Subsidy calculation [?]

Subsidies are deposited as a single amount per epoch (not per pool).

- Pools get a share based on votes: `poolSubsidies = (poolVotes * subsidyPerVote) / 1e18` (in finalize()).
- Verifiers then claim their share: `verifierShare = (verifierAccrued / poolAccrued) * poolSubsidies` (in claimSubsidies()).

**Problem:**  
Precomputing `subsidyPerVote` in finalize() causes precision loss—small subsidies can get floored to zero if totalVotes is large.  
Example: `subsidies=5e18, totalVotes=10e18+1` → `subsidyPerVote=0`.  
This makes small subsidies undistributable in high-vote or low-subsidy epochs.

**Why this fails:**  
- Global pre-calc with integer division wastes small amounts.
- Low-subsidy scenarios get blocked entirely.

**Better approach:**  
- Skip pre-calculating `subsidyPerVote`.
- On deposit, set `epochPtr.totalSubsidies = subsidies` if `subsidies > 0 && totalVotes > 0` (transfer esMoca), no need to check `subsidyPerVote > 0`. Always set the flag.

**Residual management**

For example, `5e18` is deposited but only `4e18` is distributable (due to pool calc flooring), the rest is residual.

Per epoch:
- `totalSubsidiesAllocated`: deposited amount
- `totalSubsidiesDistributable`: claimable (floored) amounts

`withdrawUnclaimedSubsidies()` will sweep only unclaimed subsidies for an epoch; subject to delay.  
`withdrawResidualSubsidies()` will sweep only residuals; no delay requirement as this is deadweight loss.


## other math rounding stuff 

## Delegate fee tracking for proper claiming

The dumb approach is to simply charge the user the prevailing delegate fee at the time of claiming; whatever that may be.
We shall attempt at a more precise approach to charging delegate fees in a equitable manner.

For that, we introduce `delegateHistoricalFees` mapping: 

```solidity
// 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFees;  
```

We have implemented Approach 3. The others remain for reference.

### Approach #1: Use delegateHistoricalFees Mapping (Populate on Fee Changes)

```solidity

function updateDelegateFee(uint128 feePct) external {
    require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());    // 0 allowed

    Delegate storage delegate = delegates[msg.sender];
    require(delegate.isRegistered, Errors.DelegateNotRegistered());

    uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

    uint256 currentFeePct = delegate.currentFeePct;
    // if increase, only applicable from currentEpoch+FEE_INCREASE_DELAY_EPOCHS
    if(feePct > currentFeePct) {
        delegate.nextFeePct = feePct;
        delegate.nextFeePctEpoch = currentEpoch + FEE_INCREASE_DELAY_EPOCHS;

        // populate for the future epoch when it takes effect 
        delegateHistoricalFees[msg.sender][delegate.nextFeePctEpoch] = feePct;  

        emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, feePct, delegate.nextFeePctEpoch);

    } else {
        // if decrease, applicable immediately
        delegate.currentFeePct = feePct;
        // populate for the current epoch
        delegateHistoricalFees[msg.sender][currentEpoch] = feePct;

        emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, feePct);
    }

    // backfill for previous empty epochs
    // ....
}
```

When fee updates happen, book them into mapping.
For the epochs btw now and the previous update, backfill them via a loop.
But this could be result in OOG, as due to number of iterations. 

**Fail!**
 
### Approach #2: Binary search on mapping

```solidity
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
using EnumerableSet for EnumerableSet.UintSet;

    // Main mapping for delegate fees
    mapping(address => mapping(uint256 => uint256)) public delegateHistoricalFees;
    // Sorted list of epochs with non-zero fees for each delegate
    mapping(address => uint256[]) private delegateEpochs;
    
    // Update fee for a delegate
    function updateDelegateFee(uint128 feePct) external onlyRegistered {
        require(feePct <= MAX_DELEGATE_FEE_PCT, "Invalid fee percentage");

        Delegate storage delegate = delegates[msg.sender];
        uint256 currentFeePct = delegate.currentFeePct;
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber()

        if (feePct > currentFeePct) {
            // Fee increase: apply with delay (current epoch + 6)
            delegate.nextFeePct = feePct;
            delegate.nextFeePctEpoch = currentEpoch + 6;

            // Record the future fee in historical mapping
            if (feePct > 0) {
                insertSorted(msg.sender, delegate.nextFeePctEpoch);
                delegateHistoricalFees[msg.sender][delegate.nextFeePctEpoch] = feePct;
            }

            emit DelegateFeeIncreased(msg.sender, currentFeePct, feePct, delegate.nextFeePctEpoch);

        } else {
            // Fee decrease: apply immediately
            delegate.currentFeePct = feePct;

            // Record in historical mapping for current epoch
            if (feePct > 0) {
                insertSorted(msg.sender, currentEpoch);
                delegateHistoricalFees[msg.sender][currentEpoch] = feePct;
            } else {
                // If fee is set to 0, remove from historical mapping
                removeEpoch(msg.sender, currentEpoch);
                delete delegateHistoricalFees[msg.sender][currentEpoch];
            }
            emit DelegateFeeDecreased(msg.sender, currentFeePct, feePct);
        }
    }

    // Insert epoch into sorted array
    function insertSorted(address delegate, uint256 epoch) private {
        uint256[] storage epochs = delegateEpochs[delegate];
        // Binary search to find insertion point
        uint256 low = 0;
        uint256 high = epochs.length;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (epochs[mid] < epoch) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        // Insert at position 'low'
        if (low == epochs.length || epochs[low] != epoch) {
            epochs.push(); // Increase array length
            for (uint256 i = epochs.length - 1; i > low; i--) {
                epochs[i] = epochs[i - 1];
            }
            epochs[low] = epoch;
        }
    }

    // Remove epoch from sorted array
    function removeEpoch(address delegate, uint256 epoch) private {
        uint256[] storage epochs = delegateEpochs[delegate];
        // Binary search to find epoch
        uint256 index = binarySearch(delegate, epoch);
        if (index < epochs.length && epochs[index] == epoch) {
            for (uint256 i = index; i < epochs.length - 1; i++) {
                epochs[i] = epochs[i + 1];
            }
            epochs.pop();
        }
    }

    // Binary search to find epoch or the closest smaller epoch
    function binarySearch(address delegate, uint256 epoch) public view returns (uint256) {
        uint256[] storage epochs = delegateEpochs[delegate];
        if (epochs.length == 0) return type(uint256).max; // No epochs

        uint256 low = 0;
        uint256 high = epochs.length;
        uint256 closest = type(uint256).max;

        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (epochs[mid] == epoch) {
                return mid; // Exact match
            } else if (epochs[mid] < epoch) {
                closest = mid; // Track closest smaller epoch
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return closest; // Return index of closest smaller epoch
    }

    // Get fee for a delegate at a specific epoch
    function getFee(address delegate, uint256 epoch) public view returns (uint256) {
        Delegate storage del = delegates[delegate];
        if (!del.isRegistered) return 0;

        // Check if nextFeePct applies (epoch >= nextFeePctEpoch)
        if (del.nextFeePct > del.currentFeePct && epoch >= del.nextFeePctEpoch) {
            return del.nextFeePct;
        }

        // Use binary search to find the closest prior epoch with a non-zero fee
        uint256 index = binarySearch(delegate, epoch);
        if (index == type(uint256).max) {
            return del.currentFeePct; // No historical fees, use current
        }
        return delegateHistoricalFees[delegate][delegateEpochs[delegate][index]];
    }
}
```

### Approach #3: When a delegate votes, log his currentFee into `delegateHistoricalFees`, if it has not been done.

- When a delegate votes (via `vote(..., isDelegated=true)`), update `delegateHistoricalFees`
- will check for incoming fee increases via `_applyPendingFeeIfNeeded`

If a delegate does not vote for an epoch, his fee will not get booked into the mapping. But that is acceptable, as he would not be receiving rewards as he did not vote. 
So a failure to update the mapping, will result in a 0 fee value, which reflects 0 rewards receivable.

*This approach works because delegate fees cannot be 0.*

```solidity
  function vote(address caller, bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external {
      // ... existing checks ...
        if (isDelegated) {
            //...

            // fee check: if not set, set to current fee
            if(delegateHistoricalFees[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                if(!pendingFeeApplied) {
                    delegateHistoricalFees[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
                }
            }
      // ... rest of function (vote logic) ...
  }

    /**
    * @dev Internal function to apply pending fee increase if the epoch has arrived.
    * Updates currentFeePct and clears next* fields.
    * Also sets historical for the current epoch if not set.
    * @return bool True if pending was applied and historical set, false otherwise.
    */
    function _applyPendingFeeIfNeeded(address delegateAddr, uint256 currentEpoch) internal returns (bool) {
        Delegate storage delegatePtr = delegates[delegateAddr];

        // if pending fee increase, apply it
        if (delegatePtr.nextFeePctEpoch > 0) {
            if(currentEpoch >= delegatePtr.nextFeePctEpoch) {
                
                // update currentFeePct
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;
                delegateHistoricalFees[delegateAddr][currentEpoch] = delegatePtr.currentFeePct;  // Ensure set for claims
                
                // reset
                delete delegatePtr.nextFeePct;
                delete delegatePtr.nextFeePctEpoch;
            
                return true;
            }
        }

        return false;
    }

    function updateDelegateFee(uint128 feePct) external {
        require(feePct > 0, Errors.InvalidFeePct());
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());   

        Delegate storage delegate = delegates[msg.sender];
        require(delegate.isRegistered, Errors.DelegateNotRegistered());

        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

        // if there is an incoming pending fee increase, apply it before updating the fee
        _applyPendingFeeIfNeeded(msg.sender, currentEpoch);   

        uint256 currentFeePct = delegate.currentFeePct;

        // if increase, only applicable from currentEpoch+FEE_INCREASE_DELAY_EPOCHS
        if(feePct > currentFeePct) {
            // set new pending
            delegate.nextFeePct = feePct;
            delegate.nextFeePctEpoch = currentEpoch + FEE_INCREASE_DELAY_EPOCHS;

            // set for future epoch
            delegateHistoricalFees[msg.sender][delegate.nextFeePctEpoch] = feePct;  

            emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, feePct, delegate.nextFeePctEpoch);

        } else {
            // fee decreased: apply immediately
            delegate.currentFeePct = feePct;
            delegateHistoricalFees[msg.sender][currentEpoch] = feePct;

            // delete pending
            delete delegate.nextFeePct;
            delete delegate.nextFeePctEpoch;

            emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, feePct);
        }
    }
```

**Note: it is important to delete the pending in the else condition [fee decreased]**

Without these deletes in the decrease path:
- If there's a pending fee increase scheduled for a future epoch (not yet due), applyPendingFeeIfNeeded() won't touch it (noops, as epoch check fails).
- The decrease applies now, but the pending survives and kicks in later—causing an unwanted fee jump post-decrease.
- The deletes explicitly cancel any such pending, ensuring the decrease fully overrides and no old increase lingers.

**Scenario Without Deletes**
1. Increase to 20% (at epoch 1): Sets nextFeePct=20%, nextFeePctEpoch=3. Historical[3]=20%.
2. Decrease to 5% (at epoch 2): applyPendingFeeIfNeeded noops (2 < 3, not due). Updates currentFeePct=5%, historical[2]=5%. But next=20%/3 and historical[3]=20% survive.
3. At epoch 3: applyPendingFeeIfNeeded applies (3 >=3), sets currentFeePct=20%, historical[3]=20%. Fee jumps back to 20% unexpectedly—decrease didn't fully cancel the pending.

Result: Fee history: Epoch 1=10%, 2=5%, 3+=20% (bug: pending lingered)

**Scenario With Deletes**
1. Increase to 20% (at epoch 1): Same as above.
2. Decrease to 5% (at epoch 2): applyPendingFeeIfNeeded noops. But deletes clear next=0/0 (and we cleared historical[3]=0 earlier in path). Updates currentFeePct=5%, historical[2]=5%.
3. At epoch 3: No pending (deleted), so fee stays 5% (as intended).

Result: Fee history: Epoch 1=10%, 2+=5% (correct: decrease overrides fully).




# Other reference code

## Claim Streamlining for Subsidies [multi-epoch batching]

Batching: New func claimSubsidiesMultiEpoch(uint256[] calldata epochs, bytes32 verifierId, bytes32[][] calldata poolIdsPerEpoch). 
- It loops over epochs, reuses logic via an internal helper _claimSubsidiesForEpoch (avoids duplication).
- Accumulates total claimable across all, transfers once at end. Requires poolIdsPerEpoch.length == epochs.length. Skips invalid epochs gracefully.

Library Extraction: New SubsidyMath.sol with pure calculateSubsidy (handles division safely, skips zeros). Import and use in the helper—reduces main contract bytecode (~100-200 bytes saved).

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title SubsidyMath
 * @dev Library for subsidy calculations, extracted for reusability and contract size optimization.
 */
library SubsidyMath {
    /**
     * @notice Calculates subsidy receivable with safe division.
     * @dev Handles zero cases; returns 0 if denominator zero or result floors to 0.
     *      Inputs: verifierAccrued & poolAccrued in 1e6 (USD8), poolAllocated in 1e18 (esMOCA).
     * @param verifierAccrued Verifier's accrued subsidies.
     * @param poolAllocated Pool's allocated subsidies.
     * @param poolAccrued Pool's total accrued subsidies.
     * @return subsidyReceivable Calculated subsidy (1e18).
     */
    function calculateSubsidy(uint256 verifierAccrued, uint256 poolAllocated, uint256 poolAccrued) internal pure returns (uint256) {
        if (poolAccrued == 0 || verifierAccrued == 0) return 0;
        uint256 subsidy = (verifierAccrued * poolAllocated) / poolAccrued;
        return subsidy > 0 ? subsidy : 0;  // Explicit floor skip
    }
}


// UPDATES TO VOTINGCONTROLLER

// ... existing code (replace original claimSubsidies with this; uses internal helper) ...
    function claimSubsidies(uint256 epoch, bytes32 verifierId, bytes32[] calldata poolIds) external {  // Change param to uint256 for consistency with batch
        require(poolIds.length > 0, Errors.InvalidArray());

        uint256 totalClaimed = _claimSubsidiesForEpoch(epoch, verifierId, poolIds);
        if (totalClaimed == 0) revert Errors.NoSubsidiesToClaim();

        emit Events.SubsidiesClaimed(msg.sender, epoch, poolIds, totalClaimed);
        _esMoca().safeTransfer(msg.sender, totalClaimed);
    }



    /**
     * @notice Batch claims subsidies across multiple epochs in one tx.
     * @dev Loops over epochs, accumulates total, single transfer. Reuses single-epoch logic.
     *      poolIdsPerEpoch[i] corresponds to epochs[i].
     * @param epochs Array of epochs to claim for.
     * @param verifierId Verifier ID (consistent across calls).
     * @param poolIdsPerEpoch 2D array of poolIds per epoch.
     */
    function claimSubsidiesMultiEpoch(uint256[] calldata epochs, bytes32 verifierId, bytes32[][] calldata poolIdsPerEpoch) external {
        require(epochs.length > 0 && epochs.length == poolIdsPerEpoch.length, Errors.MismatchedArrayLengths());

        uint256 totalClaimed;
        for (uint256 i; i < epochs.length; ++i) {
            totalClaimed += _claimSubsidiesForEpoch(epochs[i], verifierId, poolIdsPerEpoch[i]);
        }
        if (totalClaimed == 0) revert Errors.NoSubsidiesToClaim();

        // Batch event? Or per-epoch? For simplicity, emit per-epoch inside _claim (add emit there if needed)
        // Single transfer: optimal gas
        _esMoca().safeTransfer(msg.sender, totalClaimed);
    }

    function _claimSubsidiesForEpoch(uint256 epoch, bytes32 verifierId, bytes32[] calldata poolIds) internal returns (uint256 totalSubsidiesClaimed) {
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            uint256 poolAllocatedSubsidies = epochPools[epoch][poolId].totalSubsidies;
            require(poolAllocatedSubsidies > 0, Errors.NoSubsidiesForPool());
            require(verifierEpochPoolData[epoch][poolId][msg.sender] == 0, Errors.SubsidyAlreadyClaimed());

            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) = 
                IPaymentsController(_addressBook.getPaymentsController()).getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifierId, msg.sender);

            // Use library for calc
            uint256 subsidyReceivable = SubsidyMath.calculateSubsidy(verifierAccruedSubsidies, poolAllocatedSubsidies, poolAccruedSubsidies);
            if (subsidyReceivable == 0) continue;

            totalSubsidiesClaimed += subsidyReceivable;

            // Bookkeeping (unchanged)
            verifierEpochPoolData[epoch][poolId][msg.sender] = subsidyReceivable;
            verifierEpochData[epoch][msg.sender] += subsidyReceivable;
            verifierData[msg.sender] += subsidyReceivable;

            pools[poolId].totalClaimed += subsidyReceivable;
            epochPools[epoch][poolId].totalClaimed += subsidyReceivable;
        }

        if (totalSubsidiesClaimed > 0) {
            TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
            epochs[epoch].totalClaimed += totalSubsidiesClaimed;
            // Emit per-epoch for tracking
            emit Events.SubsidiesClaimed(msg.sender, epoch, poolIds, totalSubsidiesClaimed);
        }
        return totalSubsidiesClaimed;
    }
```

**Ignoring cos i rather just build the router for batching.**