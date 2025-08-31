# VotingControllers

Do we need the whitelist flag in pool struct?
- just create, remove, activate/deactivate is fine


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

- voters receive rewards, as esMoca
- rewards are based upon verification fees
 
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

# TO-FIX

0. redo so tt rewards are epoch locked, not adhoc
1. claimRewardsDelegate