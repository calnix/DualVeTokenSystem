
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
