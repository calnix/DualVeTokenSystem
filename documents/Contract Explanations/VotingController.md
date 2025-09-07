# VotingControllers

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

\
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

## 1. Call `depositSubsidies`

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


## 2. `finalizeEpochRewardsSubsidies`


- called multiple times, to iterate through full list of pools

**For rewards:**
- for each pool, sets its rewards, hence `bytes32[] calldata poolIds, uint256[] calldata rewards`
- rewards financed by the `VOTING_FEE_PERCENTAGE` cut from PaymentsController.sol
- generating `uint256[] calldata rewards`: protocol will manually refer to `PaymentsController._epochPoolFeesAccrued[epoch][poolId].feesAccruedToVoters`

**For subsidies:**
- set value of pool's `subsidyPerVote` via `epochPools[epoch][poolId].totalSubsidies`
- verifiers can claim based on `verifierTotalSubsidyForPool`/`totalSubsidyPerPoolPerEpoch` * `

----

After finalizeEpochRewardsSubsidies is completed, and the flag isFinalized is set to true
- users can claim rewards
- verifiers can claim subsidies


# TO-FIX

0. redo so tt rewards are epoch locked, not adhoc
1. claimRewardsDelegate