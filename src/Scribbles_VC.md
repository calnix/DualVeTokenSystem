
# ---- Problems to fix:

## residual rewards - how to track + extract w/o delay

```solidity
// When sweeping unclaimed rewards:
//   unclaimed = epochPools[epoch][poolId].totalRewards - epochPools[epoch][poolId].totalClaimedRewards
//   This calculation uses gross user rewards.
//   However, after applying delegate fees, users may receive zero net rewards. 
//   As a result, totalClaimedRewards is overstated (since only netUserRewards are actually paid out).
//   Sweeping then uses this inflated totalClaimedRewards, leaving residual rewards in the contract.
//   Therefore, after sweeping, leftover rewards remain on the contract.
```


## on Account and delegateEpochData [!]

claimRewards:        delegateEpochData[epoch][delegate].totalRewards += userTotalRewards;

instead should be:         delegateEpochData[epoch][delegate].totalRewards += delegateFee;

think about this, and confirm.

write about it in docs, explaining clearly. how account works/reflects in a personal user context, vs when the user is acting as delegate. 

how uint128 totalRewards in account struct would mean different things, in those 2 different contexts.

-----
