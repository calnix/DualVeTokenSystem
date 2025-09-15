# VotingController

VotingController.sol is a dual-token voting escrow (ve) contract for ecosystem subsidy governance and rewards. 
It supports dual accounting for each address, allowing users to act as both personal voters and delegates, enabling on-chain delegations with fee charging.
Optimized for fast chains using timestamps, it tracks both personal and delegated activity, ensuring efficient, fair, and real-time voting and reward/subsidy distribution.

- Voters potentially receive rewards per epoch, and claimable on a epoch-pool basis.
- Verifiers potentially receive subsidies per epoch, which is also claimable per epoch.

Potentially, due to issuers of flooring and integer division leading to rounding down and often to 0.
We have taken great care to address and mitigate this, with particular focus on voters with small balances.

## Key Components of Design

The system is unique in several ways, setting it apart from traditional ve implementations like Curve Finance's veCRV and other forks:

1. **Custom balanceOf Function in veToken**

- The veToken contract overrides the standard ERC20 balanceOf to return the current, decayed voting power at the query time. 
- This allows wallets to display accurate, real-time values without off-chain computation, enabling users to observe decay directly in their wallet interfaces.
- Most ve systems require external tools or dApps to calculate decayed balances, making this a user-friendly innovation.

2. **Decay Frozen Within an Epoch**

- Voting power decay is paused during an epoch, preventing continuous decay that would force users to rush votes before value drops.
- It promotes deliberate participation without time pressure. 
- However, this does not mean that user' voting power does not decay btw epochs; it simply occurs step-wise. 
- This is unprecedented in ve systems, where decay is kept continuous for simplicity. 

3. **Dual-Accounting System for Addresses**
 
- Every address maintains two logical accounts: a "user account" for personal locks and votes, and a "delegate account" for aggregated delegated power. 
- This allows seamless switching between roles without separate contracts or addresses.
- Unique because most systems use single-account models or require explicit delegate contracts, limiting flexibility. This enables advanced strategies like partial delegation.

4. **Time-Based ve.Bias Calculation via Lock.Expiry** 

- Voting power (bias) is calculated using absolute timestamps from lock.expiry, ensuring all interconnected contracts (e.g., reward distributors, gauges) align with a universal time reference. 
- This avoids discrepancies in multi-contract ecosystems.

5. **Redesign Over Curve's Block Interpolation for Decay** 

Curve's veCRV uses block-based interpolation for decay calculations, approximating time via block numbers assuming consistent block times. 
This is inherently flawed and especially made worse on fast chains.

- For fast L1s and L2s with <1s blocks, (BSC with 3s, Sonic with variable rates), interpolation rounds down aggressively, often flooring balances to 0 prematurely due to granularity issues. 
- Most protocols blindly copy Curve's design without adapting for chain specifics, leading to inaccurate voting power and unfair reward distribution. 
- This contract redesigns from the ground up using pure timestamps for precise, chain-agnostic decay, optimized for high-throughput environments. 

6. **On-Chain Delegations with Fee Charging** 

Most protocols, like Aerodrome, outsource delegation to external and off-chain relayers to handle complex fee calculations and avoid gas overhead.
Essentially, the relay provider uses a combination of on-chain contracts and off-chain scripts to handle these matters. 
Especially since they need to cater to delegates changing their fees and voting allocation.

We process delegations completely on-chain. Delegation fees are charged on-chain and split accurately btw the delegator and delegatee.

7. **The Problem with Delegate Fees in ve Systems**

- rewards are distributed on an epoch basis
- delegate fees were applied at the prevailing currentFee—the delegate's fee parameters at the time of a user's query or reward claim. 
- leads to inaccuracies because fees could have been updated any time - a user claiming for some arbitrary past epoch would be subject to the current fee
- If a delegate increased its fee mid-cycle (e.g., after your veTokens were snapshotted but before rewards were emitted), the current fee would overcharge you retroactively during claims.

TLDR: the dumb approach is to simply charge the user the prevailing delegate fee at the time of claiming; whatever that may be.

How We Solved It: Historical Fee Snapshots and Epoch-Specific Queries
- we need fee decreases to be applied instantly and logged
- we need fee increases to be applied with delay, meaning it comes into effect in some future epoch.

To ensure fees are accurately applied per epoch, we introduced a system leveraging the dual-account system. 
- supporting that introduce `delegateHistoricalFees` mapping: 

```solidity
// 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFees;  
```
There were other approaches that were tested out, see below section 'Design choices'.


## Verifiers and Subsidies

`PaymentsController` tracks subsidies for each epoch:
- `epoch => poolId => totalSubsidies`
- `epoch => poolId => verifierId => verifierTotalSubsidies`

Subsidies are calculated as: `fee × _verifiersSubsidyPercentage`

At epoch end, `VotingController`:
- Allocates pool subsidies proportionally to verifiers by their total weight in the pool.
- Verifier claim: `(verifierWeight / totalPoolWeight) × poolSubsidy`

*Subsidies can only be deposited to VotingController after epoch ends.*

```bash
Note:
⦁   if we add a schema mid-epoch to a voting pool, its prior txns in the same epoch will not count for subsidies.
⦁   if we remove a schema mid-epoch from a voting pool, its weight can be removed from the pool and subsidy calculations. its prior txns in the same epoch will not receive any subsidies.
```
*Question: if we remove scheme mid-epoch how does that impact subsidies when distributed?*

## Voting Rewards

Voting rewards are financed based on verification fees accrued for a pool
- i.e. rewards are strictly per-pool (unique to each pool's accrued verification fees, including possible 0 for some pools)

We have to reference PaymentsController to know how much rewards each pool accrued, and deposit accordingly into VotingController.
We opted to not have the VotingController and PaymentsController call each other for relevant updates, to for secure modularity, which will aid in updating contracts piecemeal.

Additionally, this gives us the freedom to deposit rewards discretionally; can increase or decrease rewards as we see fit.

----

____

# **1. Contract Overview**

## Dual-accounting model [mappings]

**Generics**
- `epochs`      -> epoch data
- `pools`       -> aggregated pool data across all epochs
- `epochPools`  -> pool data, for a specific epoch

```solidity
    // epoch data
    mapping(uint256 epoch => DataTypes.Epoch epoch) public epochs;    
    
    // pool data
    mapping(bytes32 poolId => DataTypes.Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => DataTypes.PoolEpoch poolEpoch)) public epochPools;
```

**User/Delegate data**
- `usersEpochData` / `delegateEpochData`: Track per-epoch data for each address, separately for user and delegate roles (`Account` struct).
- `usersEpochPoolData` / `delegatesEpochPoolData`: Track per-epoch, per-pool data for each address, again split by user and delegate roles (`Account` struct).

```solidity
    // address as personal: perEpoch | perPoolPerEpoch
    mapping(uint256 epoch => mapping(address user => DataTypes.Account user)) public usersEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => DataTypes.Account userAccount))) public usersEpochPoolData;

    // address as delegate: perEpoch | perPoolPerEpoch [mirror of userEpochData & userEpochPoolData]
    mapping(uint256 epoch => mapping(address delegate => DataTypes.Account delegate)) public delegateEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address delegate => DataTypes.Account delegateAccount))) public delegatesEpochPoolData;

    // user/delegate data     | perEpoch | perPoolPerEpoch
    struct Account {
        uint128 totalVotesSpent;
        uint128 totalRewards;         // user: total net rewards claimed / delegate: total gross rewards accrued
    }


    // User-Delegate tracking [for this user-delegate pair, what was the user's {rewards,claimed}]
    mapping(uint256 epoch => mapping(address user => mapping(address delegate => DataTypes.UserDelegateAccount userDelegateAccount))) public userDelegateAccounting;
    
    struct OmnibusDelegateAccount {
        uint128 totalNetRewardsClaimed;
        mapping(bytes32 poolId => uint128 grossRewards) userPoolGrossRewards; // flag: 0 = not claimed, non-zero = claimed
    }
```

These paired mappings implement a dual-accounting model.

### Voting

- Every address has two logical accounts: a user account and a delegate account (`struct Account`).
- When an address votes with its own voting power, its votes are recorded in `usersEpochData` and `usersEpochPoolData`, as `totalVotesSpent`
- When an address votes with delegated voting power from others, the portion from its aggregated total votes spent is recorded in `delegateEpochData` and `delegatesEpochPoolData`.

### Claiming rewards

**User personal rewards claim:**
- When a user claims rewards accrued from his personal voting activity, it is logged to `totalRewards`, `usersEpochPoolData` & incremented in `usersEpochData`

When a user claims rewards accrued from the votes that he delegated to a specific delegatee, it is logged under `userDelegateAccounting.totalNetClaimed`
    - we do not book these rewards to `usersEpochPoolData`, as we want to reflect a distinction btw rewards from personal actions vs delegated actions.
    - hence the need for the separate mapping `userDelegateAccounting`, for supporting metrics so support analysis such as:
        1. which delegator is more profitable,
        2. should a user delegate or continue personally managing voting activity -> which is most profitable, etc

- additionally, the delegated receivable rewards are also booked to: `delegateEpochPoolData[epoch][poolId][delegate].totalRewards` & `delegateEpochData[epoch][delegate].totalRewards += delegatePoolRewards`
        - this tracks the total gross rewards a delegate has earned for their delegators, for a given epoch and pool.
        - it serves as a performance metric for the delegate.
        - **this does not represent rewards claimable by the delegate**

Delegate fees are calculated on users' total gross rewards across multiple pools. This approach ensures that even small voters receive non-zero rewards after fees, avoiding situations where rounding or fee deductions would otherwise reduce their rewards to zero.
- which is why in `OmnibusDelegateAccount`, the mapping reflects gross rewards per pool; and not net which would be more direct and convenient. 
- `totalNetRewards` in `OmnibusDelegateAccount`, reflects the total net rewards towards a user, for a specific delegate.

**How do delegate claim their fees? Where is it logged?**

```solidity
    // Delegate registration data + fee data
    mapping(address delegate => DataTypes.Delegate delegate) public delegates;  

        // global delegate data
    struct Delegate {
        bool isRegistered;             
        
        uint128 currentFeePct;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
        uint128 nextFeePct;         
        uint256 nextFeePctEpoch;            

        uint128 totalRewardsCaptured;      // total gross voting rewards accrued by delegate [from delegated votes]
        uint128 totalFees;                 // total fees accrued by delegate
        uint128 totalFeesClaimed;          // total fees claimed by delegate
    }
```

- Delegate fees are booked under `totalFees` in the global `delegates` mapping
- This allows delegates to claim fees in totality without epoch constraints
- Global approach preferred as it allows delegates to claim when their fees add up to a significant figure; as opposed to claiming small amounts on an epoch basis.


*Why can't we do a global approach for users' claiming rewards as well?*
- users need to specify the pools they are claiming from
- where the rewards calculation is `userRewards = (userPoolVotes * totalRewards) / poolTotalVotes`
- It would be inefficient and poor design to have users call a function to calc rewards for a list of pools, and then aggregate that globally for claiming

---


---



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



# **3. Design choices**

## Rewards & Subsidies: Optimal Distribution

### The Core Challenge

Distributing rewards and subsidies in a way that is fair, precise, and robust is non-trivial. The naive approach—pre-calculating per-vote rates and distributing based on those—leads to stuck funds, unfairness for small participants, and operational headaches. We designed our system to avoid these pitfalls and ensure every token is either claimable or recoverable, with no silent losses or deadweight.

---

### The Problem with Pre-Calculation

**Rewards:**  
Traditionally, protocols pre-calculate a `rewardsPerVote` value for each pool: `rewardsPerVote = (poolRewards * 1e18) / totalVotes`
This value is then used to determine each user’s claim: `userRewards = userVotes * rewardsPerVote / 1e18`

But this approach is fundamentally flawed:
- If `poolRewards` is small relative to `totalVotes`, `rewardsPerVote` for that pool can floor to zero, blocking epoch finalization and leaving rewards stuck.
- Small voters are often zeroed out; while large voters can claim, it would be rounded down values.
- Increasing pool rewards to avoid zeroing out is not an option, as pool rewards are financed by the PaymentsController[accrued verification fees].

**Subsidies:**  
A similar issue arises with subsidies. 
Pre-calculating `subsidyPerVote` at the epoch level: `subsidyPerVote = subsidies / totalVotes`, means that small subsidies in high-vote epochs are floored to zero, making them undistributable.

*Example:*

```bash
- Assume: totalRewards=5, totalVotes=10:
    - User A with 3 votes: (3*5)/10 = 15/10 = 1 (floored from 1.5).
    - User B with 1 vote: (1*5)/10 = 5/10 = 0 (floored from 0.5).

UserB has no rewards to claim.
``` 

### Our Solution: Proportional, On-Claim Calculation

We intentionally reject pre-calculation in favor of a proportional, on-claim approach:

- **No Pre-Calculation:** We do not store or use `rewardsPerVote` or `subsidyPerVote` in storage.
- **Direct Allocation:** On deposit, we simply set `totalRewards` or `totalSubsidies` for the epoch if the value is non-zero and there are votes.
- **On-Claim Math:** All calculations are performed at claim time, maximizing precision and fairness:
    - Rewards: `userRewards = (userVotes * totalRewards) / totalVotes`
    - Subsidies: `poolSubsidies = (poolVotes * totalSubsidies) / totalVotes` [then verifiers claim their share proportionally]

**Why This Wins:**
- **No Stuck Funds:** Even if totals are small, partial distribution is always possible. Any leftovers (residuals) can be swept later.
- **Per-Pool Isolation:** Each pool is handled independently. Zero-reward pools never block others. [blocking would prevent finalization of epoch via `finalizeEpoch()`]
- **No Reverts for Small Amounts:** Tiny rewards or subsidies are handled gracefully, preventing blocking of pools from being processed [`isProcessed` flag].
- **Simplicity & Gas Efficiency:** Fewer storage writes, less risk of revert, and cheaper execution.

> This also allows for epochs to have 0 subsidies, without any issues.
---

## Residuals: Accounting and Recovery

**What are residuals?**  
Residuals are small amounts left behind due to flooring in integer division. They can arise in both rewards and subsidies flows.

### Residuals Management: Rewards & Subsidies

Residuals—small amounts left behind due to integer division—are an unavoidable reality in both rewards and subsidies flows. Our design tackles this head-on, ensuring every token is either claimable or recoverable, never lost.

- **During Finalization:** If a pool has zero votes but a nonzero reward or subsidy, we don’t deposit it. For subsidies, proportional allocation across pools can also leave tiny amounts undistributed. This prevents stuck funds and ensures only distributable amounts enter the system.
- **During Claims:** Whether users or verifiers claim, all calculations use integer division, so each claim is rounded down. Multiple layers of division (e.g., delegate → user) can amplify rounding losses. Every distributed amount is meticulously tracked—`epoch.totalRewardsClaimed` and `epoch.totalSubsidiesClaimed` are always incremented by the actual value sent out.

The result: `epoch.totalRewardsAllocated - epoch.totalRewardsClaimed` and `epoch.totalSubsidiesAllocated - epoch.totalSubsidiesClaimed` always reflect the true sum of all residuals and unclaimed funds.

- **Unified Sweeping:** We make no distinction between “residuals” and “unclaimed” funds. Both are swept together, after a set delay, using `withdrawUnclaimedRewards()` and `withdrawUnclaimedSubsidies()`. This unified, intentional approach keeps the system robust, simple, and guarantees that no value is ever lost to rounding or operational edge cases.

**Bottom line:**
By moving all calculations to claim time, tracking every distributed amount, and sweeping all leftovers, we guarantee optimal, fair, and recoverable distribution—no matter how small the pool, the voter, or the subsidy. This is intentional design for optimality, not an accident of implementation.

*For an illustrated guide, highlighting sources of residuals and rounding down due to division, please see the later section titled: Residuals Illustrated*

>Illustration of residual origination: https://app.excalidraw.com/s/ZeH3y0tOi6/4nyJOQSlGn3?element=aO2TZqM4AcQ0tqw7fV8XF

## On nested mapping in `OmnibusDelegateAccount`

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

## Accurate Delegate Fee Application: Intentional Historical Tracking

Most protocols avoid on-chain delegation due to the complexity of tracking fees and state transitions. Even major players like Aerodrome rely on off-chain relayers and bots to handle delegation, fee calculations, and asset movement. Here, we take a different approach: all delegation, fee logic, and historical tracking are handled fully on-chain, with precision and intent.

**The Challenge**

Delegate fees are dynamic—delegates can change their fee at any epoch. 

If a delegate increases their fee in epoch N, but a user claims rewards for delegated votes from epoch N-2, what fee should apply? 

Naively, most systems just use the latest fee, which is unfair and breaks the link between voting and fee accrual. Fees must be indexed by epoch, not just stored as a single value. This is why most protocols push this feature off-chain to relayers. 

**The Solution: Epoch-Indexed Fee History**

Rather than simply storing the latest fee, we implement an elegant epoch-indexed fee snapshotting mechanism. 

Every delegate fee update is logged in a mapping keyed by both delegate and epoch, ensuring that for any claim, the contract can reference the exact fee that was in effect when the relevant votes were cast and rewards accrued. 

This is not a passive log: fee increases are only activated after a mandatory delay, preventing last-minute fee hikes, while fee decreases are applied instantly for user benefit. 

This system relies on two key rules: 
1. delegate fees can never be zero, 
2. delegates are expected to vote each epoch. 

That way, every epoch has a clear, valid fee reference. If a fee is zero, it simply means the delegate didn’t vote that epoch and won’t receive fees—no ambiguity, no loopholes.

# **2. Contract Functions Walkthrough**

## Constructor

```solidity
    constructor(address addressBook) {
        ADDRESS_BOOK = IAddressBook(addressBook);

        // initial unclaimed delay set to 6 epochs [review: make immutable?]
        UNCLAIMED_DELAY_EPOCHS = EpochMath.EPOCH_DURATION() * 6;
    }
```



## Voting Functions: `vote()`, `migrateVotes()`

### 1. `vote()`

```solidity
function vote(address caller, bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated)
```

- users can only vote on the current Epoch
- current epoch should not be finalized - indicating open season.
- `isDelegated` flag indicates that the caller is allocating votes from his delegations; instead of personal votes.
- voting power is determined based on forward-decay: `_veMoca().balanceAtEpochEnd`

In the `vote()` function, these are abstracted as `accountEpochData` and `accountEpochPoolData`.
All voting activity—whether personal or delegated—is tracked for each address at both the {epoch, address} and {epoch, pool, address} levels.

> Additionally, votes are tracked at a global epoch, global pool, and {epoch-pool} level.
> `epochs`, `pools`, `epochPools`


### 2. `migrateVotes`

- users can migrate votes from one batch of pools to another
- dstPools must be active
- srcPools do not have to be active
- partial and full migration of votes supported


----






# **Execution flow**

## At the end of epoch

**Process:**
0. (Epoch must have ended)
1. depositEpochSubsidies() — Allows authorized accounts to deposit subsidies for a specific epoch. If no votes, deposit is skipped.
2. finalizeEpochRewardsSubsidies() — computes each pool’s `totalSubsidiesAllocated` + `totalRewardsAllocated`
3. claimSubsidies() — verifiers claim: (verifierWeight / totalPoolWeight) × pool.totalSubsidies

1. Admin calls: `depositEpochSubsidies`

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

2. Admin calls: `finalizeEpochRewardsSubsidies`

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


3. Voters call: `claimRewards and/or `








# *Appendix*

## Residuals Illustrated

Illustration of residual origination: https://app.excalidraw.com/s/ZeH3y0tOi6/4nyJOQSlGn3?element=aO2TZqM4AcQ0tqw7fV8XF

There are two kind of residuals that could be stuck on the contract:

1. rewards
2. subsidies

**Rewards Flow: sources of residuals**

1. `finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards)`

- The function deposits rewards for each pool, matching each pool in the pool array to its corresponding reward in the rewards array (element-wise).
- If a pool has zero votes but a non-zero reward, those rewards are not deposited. This prevents unclaimable rewards from being stuck and needing to be swept later.

2. `voterClaimRewards()`

- Rewards for a user are calculated as: `uint256 userRewards = (userPoolVotes * totalRewards) / poolTotalVotes;`.
- Integer division here causes rounding down, so some small reward amounts (residuals) can remain unclaimed in the pool.
- To prevent these from being lost, the function always increments `epoch.totalRewardsClaimed` by the actual amount distributed (after flooring).

This means: `residuals = epoch.totalRewardsAllocated - epoch.totalRewardsClaimed`, and these are reclaimed via `withdrawUnclaimedRewards(epoch)`.

Because reward residuals are swept at the epoch level, it’s critical to always update the epoch struct in every claim function. This ensures all distributed and undistributed rewards are fully accounted for, so nothing gets stuck on the contract.

3. `_claimDelegateRewards()`

This function introduces multiple layers of integer division, each amplifying rounding losses:

- First, `delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;`  
  - This calculation floors the result, so any remainder is lost.
- Next, `userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;`  
  - This step applies integer division again, compounding the rounding from the previous calculation.

To ensure no rewards are left stranded, we sum all `userGrossRewards` and record that total in `epoch.totalRewardsClaimed`.  
This guarantees that `epoch.totalRewardsClaimed` always matches the actual amount distributed, fully accounting for all rounding effects.

*Note:*

At first glance, it may look like a third source of residuals could arise in this function from the calculation: `uint256 delegateFee = userTotalGrossRewards * delegateFeePct / Constants.PRECISION_BASE;`

- Since `delegateFee` uses integer division, it is always rounded down.
- However, `userTotalNetRewards` is simply `userTotalGrossRewards` minus this floored `delegateFee`.
- Any fractional remainder lost in the fee calculation is not lost to the contract—it is effectively added back to the user's net rewards.

In other words, any rounding down in `delegateFee` directly increases `userTotalNetRewards` by the same amount, since: `userTotalNetRewards = userTotalGrossRewards - delegateFee`.

**Subsidy Flow: sources of residuals**

1. `finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards)`

- fn expects `epoch.totalSubsidies` to be set from the prior calling of `depositSubsidies`. Note that `epoch.totalSubsidies` can be 0.
- if `epochTotalSubsidiesDeposited > 0` and `poolVotes >0`, subsidies for that pool are calculated: `poolSubsidies = (poolVotes * epochPtr.totalSubsidies) / epochPtr.totalVotes`
- the division there will lead to a rounded down value of poolSubsidies and therefore, residuals.
- Due to flooring in integer division, the sum of allocated subsidies can be less than `totalSubsidiesDeposited`. This creates residuals (unallocated subsidies).

We will see this effect further compounded in the next function.

2. `claimSubsidies()`

- for a verifier, subsidy receivable: `subsidyReceivable = verifierSubsidies / PoolSubsidies * poolAllocatedSubsidies`
- `subsidyReceivable` will be subject to rounding down and flooring issues; there will be subsidy residuals. 
- however, `epoch.totalSubsidiesClaimed` is incremented by the local var `totalSubsidiesClaimed`, which is the sum `subsidyReceivable` [which is floored frm division]
- Therefore, epoch.totalSubsidiesClaimed  correctly reflects the amt transferred out. 

To extract these residuals: `epoch.totalDeposited - epoch.totalSubsidiesClaimed`, which is handled in `withdrawSubsidies`. 

**Both withdrawSubsidies & withdrawRewards, sweep residuals as well as unclaimed rewards respectively. They do not make a distinction btw residuals and unclaimed.**
**This approach is taken to reduce further complexity by not having to track residuals accrued independent of unclaimed values.**
**In short, residuals are subject to the same withdraw unclaimed delay.**

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

# *Other reference code*

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

