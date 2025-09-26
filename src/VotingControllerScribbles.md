
//----------

```solidity
// update pool claimed
epochPools[epoch][poolId].totalClaimedRewards += userRewards;
```

```solidity
// When sweeping unclaimed rewards:
//   unclaimed = epochPools[epoch][poolId].totalRewards - epochPools[epoch][poolId].totalClaimedRewards
//   This calculation uses gross user rewards.
//   However, after applying delegate fees, users may receive zero net rewards. 
//   As a result, totalClaimedRewards is overstated (since only netUserRewards are actually paid out).
//   Sweeping then uses this inflated totalClaimedRewards, leaving residual rewards in the contract.
//   Therefore, after sweeping, leftover rewards remain on the contract.
```

<i think i only addressed rewards here. and did not address subsidies>

//----------
# Execution process

1. depositEpochSubsidies
2. finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards)


# life

## On calculating rewards to users

Voting rewards are financed based on verification fees accrued for a pool
- i.e. rewards are strictly per-pool (unique to each pool's accrued verification fees, including possible 0 for some pools)

**Problem:**
- Calculating rewards for users can lead to precision loss due to integer arithmetic, 
- Especially for users with fewer votes, potentially resulting in zero rewards due to rounding.

**There are 2 approaches:**

*1) Precompute `rewardsPerVote` for each pool, when depositing rewards. [suboptimal]*

-  `rewardsPerVote` would be multiplied by a user's votes in `claimRewards()`. 
- This can cause early truncation, rounding small rewards to zero for users with fewer votes.


*2) Calculate rewards directly in `claimRewards()` using (`userPoolVotes` * `totalRewards`) / `poolTotalVotes`*

- This performs multiplication before division, preserving precision and reducing the chance of rewards rounding to zero.


**Why Approach 2 is Better:**
- by multiplying first, approach 2 minimizes truncation errors in integer arithmetic
- this emphatizes users with fewer votes, as they are more likely to receive non-zero rewards, improving fairness and accuracy.

TLDR: With approach 2, we have done our best wrt to fairness and supporting the smaller fishes.

### Addressing residuals as a consequence of solidity

While, approach 2 preserves more precision in the intermediate calculation, making it less likely for small vote shares to result in zero rewards; it does not eliminate the possibility entirely due to integer division.
This is an unfortunate aspect of solidity math.

> so, finalizeEpochRewardsSubsidies() will only set: epochPools[epoch][poolId].totalRewards = poolRewards

*Example:*

```bash
- Assume: totalRewards=5, totalVotes=10:
    - User A with 3 votes: (3*5)/10 = 15/10 = 1 (floored from 1.5).
    - User B with 1 vote: (1*5)/10 = 5/10 = 0 (floored from 0.5).

UserB has no rewards to claim.
``` 

Approach 2 reduces the likelihood and degree of this issue compared to Approach 1.
But since this cannot be completely eliminated, we introduce a function to sweep residual rewards: `sweepUnclaimedRewards()`

- Sweep is per pool-epoch, for any unclaimed remainders (e.g., from flooring or unclaimed users) after 1 year.


## On calculating subsidies to verifiers

Subsidies are global per epoch (deposited as a lump sum for the entire epoch, not per pool). 

- Distributed proportionally to pools based on their votes poolSubsidies = (poolVotes * subsidyPerVote) / 1e18. [in finalize()]
- From there, verifiers claim based on their relative accrued subsidies within each pool verifierShare = (verifierAccrued / poolAccrued) * poolSubsidies [in claimSubsidies()]. 

However, the pre-calc of `subsidyPerVote` introduces a similar truncation issue to the rewardsPerVote problem we discussed earlier.

**Issue with precomputing subsidyPerVote in finalize()**
- `(subsidies * 1e18) / totalVotes` risks flooring to 0 in integer division, especially with small subsidies relative to large totalVotes.
- e.g., subsidies=5e18, totalVotes=10e18+1 → subsidyPerVote=0
- This could leave small subsidies undistributable, especially in epochs with high totalVotes or low subsidy budgets. 

**Why Not Ideal:** 
- Pre-calculating subsidyPerVote globally assumes even distribution without flooring loss
- Integer division can waste small amounts entirely at the global level; blocks valid low-subsidy scenarios.

**Proposed Approach:**
- To make it more robust (allowing for low-subsidy scenarios), we can adapt the direct proportional calc from the rewards fix:
- Remove subsidyPerVote Pre-Calc: In depositSubsidies, just set epochPtr.totalSubsidies = subsidies if subsidies>0 and totalVotes>0 (transfer esMoca), without calculating/requiring subsidyPerVote>0. Set the flag unconditionally.

--- 
In epoch
- totalSubsidies: deposit amt
- totalSubsidiesClaimed: as per claimed; floored amts
-> does not specifically track residuals/non-distributable subsidies
-> meaning, we could have deposited 5e18 of subs, but only 4e18 could distributable after finalize is called. [due to poolSubsidies calc.]

So we add `totalSubsidiesDistributable` into epoch struct, to reflect what is actually distributable.
Regardless, `withdrawUnclaimedSubsidies()` will sweep unclaimed + residuals: `epochs[epoch].totalSubsidies - epochs[epoch].totalClaimed;`

# ---- Problems to fix:

1. ClaimSubsidies: Uses uint128 for totalSubsidiesClaimed but calcs in uint256—safe, but ensure no overflow on +=.
2. Gas Inefficiencies: Multiple loops in claimRewardsFromDelegate (one for calc, one for prorate)—combine if possible. Views like getUserDelegatePoolGrossRewards allocate arrays—optimize.

3. Delegate Fee Manipulation: updateDelegateFee allows 0, but increases delayed—good, but no cap on decreases; potential griefing if delegate sets high then low post-claims.
- because fees are charged at prevailing?

// ... existing code ...
function registerAsDelegate(uint128 feePct) external {
    // ... existing checks/sets (require, register on veMoca, fee transfer) ...

    // storage: register delegate + set fee percentage
    delegate.isRegistered = true;
    delegate.currentFeePct = feePct;

    // New: Populate historical fees for current epoch
    uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
    delegateHistoricalFees[msg.sender][currentEpoch] = feePct;

    emit Events.DelegateRegistered(msg.sender, feePct);
}
// ... existing code ...


  // ... existing code ...
  function updateDelegateFee(uint128 feePct) external {
      // ... existing checks/sets ...
      uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

      if(feePct > currentFeePct) {
          // ... existing delay logic ...
          delegateHistoricalFees[msg.sender][delegate.nextFeePctEpoch] = feePct;  // Populate for the future epoch when it takes effect
      } else {
          // Immediate decrease: populate for current epoch
          delegateHistoricalFees[msg.sender][currentEpoch] = feePct;
      }
      // For ongoing epochs, optionally backfill if needed (e.g., loop from current to nextFeePctEpoch setting old fee), but minimal if changes infrequent
      // ... emits ...
  }
  // ... existing code ...



  // ... existing code ...
  function claimRewardsFromDelegate(uint256 epoch, bytes32[] calldata poolIds, address delegate) external {
      // ... existing ...
      // Lookup historical fee for the vote epoch
      uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];  // Fee at the time of voting (epoch)
      if(delegateFeePct == 0) {  // Fallback if not set (e.g., pre-change epochs)
          delegateFeePct = delegates[delegate].currentFeePct;  // Or revert if strict
      }
      if(delegateFeePct > 0) {
          delegateFee = userTotalRewards * delegateFeePct / Constants.PRECISION_BASE;
          // ... rest ...
      }
      // ... existing ...
  }
  // ... existing code ...


# Delegate Fee Manipulation

1. *when a delegate votes, log his currentFee into delegateHistoricalFees if it has not been done.*
    vote(...isDelegated=true){
        if (isDelegated) {
            ....
            if(delegateHistoricalFees[delegate][epoch] == 0) delegateHistoricalFees[delegate][epoch] = delegate.currentFeePct
        }
    }   

2. updateDelegateFee(newFeePct)
- delegateHistoricalFees[delegate][epoch] = newFeePct

For scenarios where a delegate may not update his fee for many epochs, his fee for the epoch is booked into 


- It's best to add a flag if a epoch fee has been updated for a delegator
- Instead of relying on 0 to be not updated
- Since 0 can be a valid update value


# on nested mapping in UserDelegateAccount

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