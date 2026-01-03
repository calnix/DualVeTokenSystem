# VotingController Integration Test Suite

This integration test suite provides comprehensive end-to-end testing for the `VotingController` contract using **real** `EscrowedMoca` and `VotingEscrowMoca` contracts instead of mocks.

### Key Differences from Unit Tests

| Aspect            | Unit Tests                                     | Integration Tests                               |
|-------------------|------------------------------------------------|-------------------------------------------------|
| VotingEscrowMoca  | `MockVotingEscrowMocaVC` with mocked balances  | Real `VotingEscrowMoca` with actual locks       |
| EscrowedMoca      | `MockEscrowedMocaVC` with unlimited minting    | Real `EscrowedMoca` with actual escrow          |
| Voting Power      | Manually set via setters                       | Calculated from actual locks with decay         |
| Token Transfers   | Simple ERC20 mints                             | Real escrow/lock mechanics                      |
| Delegation        | Simulated via setters                          | Real `delegateLock()` / `undelegateLock()`      |

---

## Dir Structure

```
test/5. VotingController/integration_testing/
├── IntegrationTestHarness.sol   # Base test harness with real contract deployment
├── E2E_Voting.t.sol             # Personal voting with real locks
├── E2E_Delegation.t.sol         # Delegate registration and delegated voting
├── E2E_Claims.t.sol             # Rewards/subsidies with exact math verification
├── E2E_MultiEpoch.t.sol         # Multi-epoch scenarios with decay
├── E2E_EdgeCases.t.sol          # Boundary conditions and edge cases
└── README.md                    # This documentation file
```

---

## Timeline Overview

| #     |            File               |              Key Focus              |
|-------|-------------------------------|-------------------------------------|
|  1    | IntegrationTestHarness.sol    | Infrastructure setup                |
|  2    | E2E_Voting.t.sol              | Personal voting with real locks     |
|  3    | E2E_Delegation.t.sol          | Delegate registration + voting      |
|  4    | E2E_Claims.t.sol              | All claim types with exact math     |
|  5    | E2E_MultiEpoch.t.sol          | Cross-epoch scenarios               |
|  6    | E2E_EdgeCases.t.sol           | Boundary conditions                 |

---

## File 1: IntegrationTestHarness.sol

**Purpose**: Base test harness that deploys real contracts and provides shared utilities.

### Key Components

|      Component         |                    Description                                     |
|------------------------|------------------------------------------------------------------- |
| Contract Deployment    | Deploy real `EscrowedMoca`, `VotingEscrowMoca`, `VotingController` |
| Mock Dependencies      | `MockPaymentsController`, `MockWMoca` (external deps only)         |
| State Snapshots        | Comprehensive structs capturing all contract states                |
| Helper Functions       | Lock creation, delegation, epoch manipulation                      |
| Epoch Math             | Timestamp calculations for epoch boundaries                        |

### Critical Setup Steps

1. **Warp to valid epoch** - Avoid underflow in VC constructor (`epoch 10+`)
2. **Whitelist veMoca in esMoca** - Enable esMoca transfers to veMoca
3. **Whitelist VotingController in esMoca** - Enable reward/subsidy transfers
4. **Set VotingController address in veMoca** - Enable delegate registration sync
5. **Grant roles** - CronJob, Monitor, Admin roles for all contracts

### State Snapshot Structure

```solidity
struct IntegrationSnapshot {
    // Token Balances
    uint256 userMoca;
    uint256 userEsMoca;
    uint256 veMocaContractMoca;
    uint256 veMocaContractEsMoca;
    uint256 vcContractEsMoca;
    
    // VotingController State
    GlobalCountersSnapshot vcGlobal;
    EpochSnapshot vcEpoch;
    DelegateSnapshot vcDelegate;
    UserAccountSnapshot vcUserAccount;
    
    // VotingEscrowMoca State
    LockSnapshot lock;
    uint128 userPersonalVP;
    uint128 userDelegatedVP;
    uint128 delegateTotalDelegatedVP;
    
    // EscrowedMoca State
    uint256 esMocaTotalSupply;
}
```

---

## File 2: E2E_Voting.t.sol

**Purpose**: Test personal voting flows using real locks with actual voting power calculations.

### Epoch Timeline

```
Epoch 10: Warp and deploy contracts
Epoch 11: Create locks, vote
Epoch 12: Finalize epoch 11, verify states
```

### Test Cases

| Test Name                                   | Description                                       | Crucial Points                                 |
|---------------------------------------------|---------------------------------------------------|------------------------------------------------|
| `test_E2E_CreateLock_VotingPowerCalculation`| Create lock and verify voting power matches formula| VP = slope * (expiry - epochEnd)               |
| `test_E2E_SingleUser_SinglePool_Vote`       | User creates lock, votes for 1 pool               | Assert exact vote amounts, token transfers      |
| `test_E2E_SingleUser_MultiPool_Vote`        | User votes across multiple pools                  | Verify vote distribution, spent votes tracking  |
| `test_E2E_MultiUser_SinglePool_Vote`        | Multiple users vote for same pool                 | Pool total = sum of all user votes              |
| `test_E2E_MultiUser_MultiPool_Vote`         | Multiple users, multiple pools                    | Cross-verify all pool totals                    |
| `test_E2E_Vote_UsesEpochEndVotingPower`     | Verify `balanceAtEpochEnd()` is used              | VP at epoch end < VP at vote time (decay)       |
| `test_E2E_Vote_ExactlyAvailableVotes`       | User votes with 100% of available VP              | No remaining votes, exact match                 |
| `test_E2E_Vote_PartialVotingPower`          | User votes with portion of VP                     | Remaining VP = total - spent                    |
| `test_E2E_VoteMigration_FullAmount`         | Migrate all votes from pool A to B                | Source pool -= votes, dest pool += votes        |
| `test_E2E_VoteMigration_PartialAmount`      | Migrate partial votes                             | Exact amounts verified both pools               |
| `test_E2E_VoteMigration_FromInactivePool`   | Migrate from removed pool to active               | Allowed: inactive -> active                     |
| `test_E2E_Vote_RevertWhen_ExceedsAvailable` | Vote more than available VP                       | Reverts with `InsufficientVotes()`              |
| `test_E2E_Vote_RevertWhen_EndOfEpochOps`    | Vote during finalization                          | Reverts with `EndOfEpochOpsUnderway()`          |
| `test_E2E_Vote_RevertWhen_InactivePool`     | Vote for removed pool                             | Reverts with `PoolNotActive()`                  |

### Verification Points

For each test, verify:

- **Before/After Token Balances**: user MOCA, user esMOCA, veMoca contract balances
- **Lock State**: lock.moca, lock.esMoca, lock.expiry
- **Voting Power**: `balanceOfAt()`, `balanceAtEpochEnd()`
- **VC State**: `usersEpochData[epoch][user].totalVotesSpent`
- **Pool State**: `epochPools[epoch][poolId].totalVotes`, `pools[poolId].totalVotes`

---

## File 3: E2E_Delegation.t.sol

**Purpose**: Test complete delegation flow from registration through delegated voting.

### Epoch Timeline

```
Epoch 10: Deploy contracts
Epoch 11: Register delegate, create locks, delegate locks
Epoch 12: Delegation takes effect, delegate votes
Epoch 13: Finalize, verify reward attribution
```

### Test Cases

| Test Name                                    | Description                              | Crucial Points                                         |
|----------------------------------------------|------------------------------------------|--------------------------------------------------------|
| `test_E2E_RegisterDelegate_SyncsWithVeMoca`  | Register delegate via VC                  | VC calls `veMoca.delegateRegistrationStatus()`         |
| `test_E2E_RegisterDelegate_PaysFee`          | Registration fee collection               | Fee transferred, counter incremented                   |
| `test_E2E_DelegateLock_NextEpochEffect`      | Delegate lock, verify timing              | Delegation effective next epoch, not current           |
| `test_E2E_DelegatedVoting_UsesCorrectPower`  | Delegate votes with delegated VP          | `balanceAtEpochEnd(delegate, epoch, true)`             |
| `test_E2E_MultiDelegator_SingleDelegate`     | Multiple users delegate to same delegate  | Delegate VP = sum of all delegated locks               |
| `test_E2E_SpecificDelegatedBalance`          | Verify per-user-delegate tracking         | `getSpecificDelegatedBalanceAtEpochEnd()` exact values |
| `test_E2E_UndelegateLock_NextEpochEffect`    | Undelegate, verify timing                 | Power returns to user next epoch                       |
| `test_E2E_SwitchDelegate`                    | Switch from delegate A to B               | A loses power, B gains power (next epoch)              |
| `test_E2E_UnregisterDelegate_BlockedWithVotes`| Unregister with active votes              | Reverts: `CannotUnregisterWithActiveVotes()`           |
| `test_E2E_UnregisterDelegate_Succeeds`       | Unregister with no votes                  | Delegate storage cleared, veMoca synced                |
| `test_E2E_DelegateFee_ImmediateDecrease`     | Decrease fee, immediate effect            | New fee recorded same epoch                            |
| `test_E2E_DelegateFee_DelayedIncrease`       | Increase fee, delayed effect              | Fee applies after `FEE_INCREASE_DELAY_EPOCHS`          |
| `test_E2E_DelegateFee_RecordedOnVote`        | Fee snapshot on first vote                | `delegateHistoricalFeePcts[delegate][epoch]` set       |
| `test_E2E_DelegatedVote_Migration`           | Delegate migrates votes                   | Pool states update correctly                           |
| `test_E2E_SingleDelegator_SplitDelegation`   | User has multiple locks, delegates some   | Personal VP + delegated VP tracked separately          |

### Critical Verification Table

| State                                                    | Before Delegation        | After Delegation (Next Epoch) |
|----------------------------------------------------------|--------------------------|-------------------------------|
| `veMoca.balanceAtEpochEnd(user,     e, false)`           | Lock VP                  | 0 (if fully delegated)        |
| `veMoca.balanceAtEpochEnd(delegate, e, true)`            | 0                        | Lock VP                       |
| `veMoca.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, e)` | 0               | Lock VP                       |
| `veMoca.isRegisteredDelegate(delegate)`                  | true                     | true                          |

---

## File 4: E2E_Claims.t.sol

**Purpose**: Test all claim functions with exact mathematical verification.

### Epoch Timeline

```
Epoch 10: Deploy
Epoch 11: Create locks, vote
Epoch 12: endEpoch() -> Ended
         processVerifierChecks() -> Verified
         processRewardsAndSubsidies() -> Processed
         finalizeEpoch() -> Finalized
         Claims available
Epoch 13+: Additional scenarios
```

### Test Cases

#### Personal Rewards

| Test Name                                             | Description                        | Crucial Points                                 |
|------------------------------------------------------|------------------------------------|-------------------------------------------------|
| `test_E2E_ClaimPersonalRewards_ExactMath`            | Claim with exact amount verification| reward = (userVotes / poolVotes) * poolRewards |
| `test_E2E_ClaimPersonalRewards_ProRataMultipleUsers` | Multiple users pro-rata claim      | Each gets proportional share                    |
| `test_E2E_ClaimPersonalRewards_MultiPool`            | Claim from multiple pools          | Total = sum of per-pool rewards                 |
| `test_E2E_ClaimPersonalRewards_TokenTransfer`        | Verify esMoca transfer             | VC balance -, user balance +                    |
| `test_E2E_ClaimPersonalRewards_DoubleClaim`          | Attempt second claim               | Reverts: `AlreadyClaimed()`                     |
| `test_E2E_ClaimPersonalRewards_CounterUpdates`       | Verify all counters                | poolEpoch.claimed, epoch.claimed, global.claimed|

#### Delegated Rewards

| Test Name                                   | Description                   | Crucial Points                               |
|---------------------------------------------|-------------------------------|----------------------------------------------|
| `test_E2E_ClaimDelegatedRewards_ExactMath`  | Net rewards after fee         | net = gross - (gross * feePct / 10000)       |
| `test_E2E_ClaimDelegatedRewards_MultiDelegator` | Multiple delegators claim | Each gets pro-rata share                     |
| `test_E2E_ClaimDelegatedRewards_GrossVsNet` | Verify split                  | gross = net + fees                           |

#### Delegate Fees

|                Test Name                      |            Description                  |            Crucial Points                 |
|-----------------------------------------------|-----------------------------------------|-------------------------------------------|
| `test_E2E_ClaimDelegationFees_ExactMath`      | Fee = gross * feePct / 10000            | Verify exact fee amount                   |
| `test_E2E_ClaimDelegationFees_MultiDelegator` | Fees from multiple delegators           | Total = sum of per-delegator fees         |
| `test_E2E_ClaimDelegationFees_ZeroFee`        | Delegate with 0% fee                    | Zero fees claimable, reverts              |

#### Subsidies

|               Test Name                       |                  Description                                        |            Crucial Points             |
|-----------------------------------------------|---------------------------------------------------------------------|---------------------------------------|
| `test_E2E_ClaimSubsidies_ExactMath`           | subsidy = (verifierAccrued / poolAccrued) * poolAllocated           | Verify ratio calculation              |
| `test_E2E_ClaimSubsidies_MultiPool`           | Claim from multiple pools                                           | Sum of per-pool subsidies             |
| `test_E2E_ClaimSubsidies_MultiVerifier`       | Multiple verifiers same pool                                        | Each gets their ratio                 |

### Exact Math Verification Example

```solidity
// Personal rewards calculation
uint128 userVotes = 500 ether;
uint128 poolVotes = 2500 ether;
uint128 poolRewards = 100 ether;

// Expected: (500 / 2500) * 100 = 20 ether
uint128 expectedReward = (userVotes * poolRewards) / poolVotes;
assertEq(actualReward, 20 ether, "Exact reward match");

// Delegated rewards with 10% fee
uint128 grossReward = 30 ether;
uint128 feePct = 1000; // 10%
uint128 expectedFee = (grossReward * feePct) / 10000; // 3 ether
uint128 expectedNet = grossReward - expectedFee; // 27 ether

assertEq(delegatorReceived, 27 ether, "Net reward exact");
assertEq(delegateReceived, 3 ether, "Fee exact");
```

---

## File 5: E2E_MultiEpoch.t.sol

**Purpose**: Test scenarios spanning multiple epochs with voting power decay and state transitions.

### Epoch Timeline

```
Epoch 10: Deploy
Epoch 11: Create locks (expiry: end of epoch 14)
Epoch 12: Vote, finalize
Epoch 13: New votes, finalize
Epoch 14: Lock expires, finalize
Epoch 15: Verify expired lock handling
```

### Test Cases

|                  Test Name                            |                 Description                      |                Crucial Points                     |
|-------------------------------------------------------|--------------------------------------------------|---------------------------------------------------|
| `test_E2E_VotingPower_DecaysAcrossEpochs`             | VP decreases each epoch                          | VP_e12 > VP_e13 > VP_e14                          |
| `test_E2E_LockExpiry_VotingPowerZero`                 | VP after expiry                                  | `balanceAtEpochEnd()` = 0                         |
| `test_E2E_DelegateFeeIncrease_AppliesAfterDelay`      | Fee change across epochs                         | Old fee until delay, new fee after                |
| `test_E2E_MultiEpoch_ClaimFromPriorEpochs`            | Claim old epoch after new finalizes              | Prior epoch claims still work                     |
| `test_E2E_MultiEpoch_AccumulatedRewards`              | Claim from multiple epochs                       | Each epoch tracked independently                  |
| `test_E2E_DelegationChange_MidEpoch`                  | Delegate switch mid-epoch                        | Current epoch: old delegate, next: new            |
| `test_E2E_IncreaseDuration_ExtendsVotingPower`        | Extend lock duration                             | VP increases, new decay slope                     |
| `test_E2E_IncreaseAmount_IncreasesVotingPower`        | Add more to lock                                 | VP increases proportionally                       |
| `test_E2E_Unlock_AfterExpiry`                         | Unlock expired lock                              | Principals returned, VP = 0                       |
| `test_E2E_ForceFinalize_SkipsRewards`                 | Force finalize epoch                             | No rewards allocated, claims blocked              |
| `test_E2E_DecayVerification_ExactMath`                | Verify decay formula                             | VP = slope * (expiry - epochEnd)                  |

### Decay Verification

```solidity
// Lock: 200 ether principal, expiry at epoch 14 end
uint128 lockPrincipal = 200 ether;
uint128 expiry = getEpochEndTimestamp(14);
uint128 slope = lockPrincipal / MAX_LOCK_DURATION;

// VP at different epochs
uint128 vpAtE12End = slope * (expiry - getEpochEndTimestamp(12));
uint128 vpAtE13End = slope * (expiry - getEpochEndTimestamp(13));
uint128 vpAtE14End = 0; // Expired

assertTrue(vpAtE12End > vpAtE13End, "VP decays");
assertEq(vpAtE14End, 0, "VP zero at expiry");
```

---

## File 6: E2E_EdgeCases.t.sol

**Purpose**: Test boundary conditions, edge cases, and concurrent operations.

### Test Cases

|                Test Name                          |                    Description                              |                Crucial Points                        |
|---------------------------------------------------|-------------------------------------------------------------|------------------------------------------------------|
| `test_E2E_EpochBoundary_VoteAtEdge`               | Vote 1 second before epoch end                              | Uses current epoch, not next                         |
| `test_E2E_EpochBoundary_VoteJustAfter`            | Vote after epoch transition                                 | Uses new epoch                                       |
| `test_E2E_MinimumLockAmount`                      | Lock with MIN_LOCK_AMOUNT                                   | Exact minimum works                                  |
| `test_E2E_MinimumLockDuration`                    | Lock with minimum duration (2 epochs ahead)                 | VP calculated correctly                              |
| `test_E2E_MaximumLockDuration`                    | Lock with MAX_LOCK_DURATION                                 | Maximum VP achieved                                  |
| `test_E2E_ConcurrentVoters_SamePool`              | Many users vote same pool simultaneously                    | No race conditions                                   |
| `test_E2E_PoolRemoval_MidEpoch`                   | Remove pool after votes cast                                | Votes stay, migration allowed out                    |
| `test_E2E_DelegateUnregister_ReRegister`          | Unregister then re-register                                 | Fresh state, new fee                                 |
| `test_E2E_ZeroDelegatedVP_ClaimReverts`           | Claim with no delegation                                    | Reverts: `ZeroDelegatedVP()`                         |
| `test_E2E_PartialPoolProcessing`                  | Process pools in batches                                    | State consistent across batches                      |
| `test_E2E_UnclaimedWithdrawal_AfterDelay`         | Withdraw after UNCLAIMED_DELAY_EPOCHS                       | Exact unclaimed amount to treasury                   |
| `test_E2E_Vote_NonExistentPool_Reverts`           | Vote for pool 999                                          | Reverts: `PoolNotActive()`                           |
| `test_E2E_Vote_ZeroAmount_Reverts`                | Vote with 0 amount                                         | Reverts: `ZeroVoteAmount()`                          |
| `test_E2E_UserWithoutLock_NoVotingPower`          | User without lock tries to vote                             | Reverts: `NoAvailableVotes()`                        |
| `test_E2E_ClaimBeforeFinalized_Reverts`           | Claim before epoch finalized                                | Reverts: `EpochNotFinalized()`                       |

---

## Critical Points Summary

### Token Flow Verification

|         Flow          |      Source       |    Destination     |                Verification                   |
|-----------------------|-------------------|--------------------|-----------------------------------------------|
| Lock Creation         | User MOCA         | veMoca contract    | `veMoca.balance                     += moca`  |
| Lock Creation         | User esMoca       | veMoca contract    | `esMoca.balanceOf(veMoca)           += esMoca`|
| Delegate Registration | User MOCA         | VC contract        | `VC.balance                          += fee`  |
| Epoch Finalization    | Treasury esMoca   | VC contract        | `esMoca.balanceOf(VC)       += rewards + subsidies` |
| Claim Personal        | VC esMoca         | User               | `esMoca.balanceOf(user)          += claimable`|
| Claim Delegated       | VC esMoca         | Delegator          | `esMoca.balanceOf(delegator)         += net`  |
| Claim Fees            | VC esMoca         | Delegate           | `esMoca.balanceOf(delegate)         += fees`  |
| Claim Subsidies       | VC esMoca         | Verifier Asset     | `esMoca.balanceOf(verifierAsset)    += subsidy`|

### State Counter Verification

Always verify these counters before/after operations:

|             Counter                   | Location   |                  Updates On                                    |
|---------------------------------------|------------|---------------------------------------------------------------|
| `TOTAL_LOCKED_MOCA`                   | veMoca     | createLock, increaseAmount, unlock                            |
| `TOTAL_LOCKED_ESMOCA`                 | veMoca     | createLock, increaseAmount, unlock                            |
| `TOTAL_POOLS_CREATED`                 | VC         | createPools                                                   |
| `TOTAL_ACTIVE_POOLS`                  | VC         | createPools, removePools                                      |
| `TOTAL_REWARDS_DEPOSITED`             | VC         | finalizeEpoch                                                 |
| `TOTAL_REWARDS_CLAIMED`               | VC         | claimPersonalRewards, claimDelegatedRewards, claimDelegationFees |
| `TOTAL_SUBSIDIES_DEPOSITED`           | VC         | finalizeEpoch                                                 |
| `TOTAL_SUBSIDIES_CLAIMED`             | VC         | claimSubsidies                                                |
| `TOTAL_REGISTRATION_FEES_COLLECTED`   | VC         | registerAsDelegate                                            |

### Voting Power Formula Reference

```solidity
// VeMathLib formulas
slope = (lock.moca + lock.esMoca) / MAX_LOCK_DURATION;
bias = slope * expiry;
votingPowerAt(timestamp) = bias - (slope * timestamp);

// At epoch end
votingPowerAtEpochEnd = slope * (expiry - epochEndTimestamp);

// If timestamp >= expiry: votingPower = 0
```

---

### Key Implementation Notes

1. **Epoch Finalization Order**: Delegated reward/fee claims require the epoch to be in `Finalized` state. Tests must call `_finalizeEpoch()` for the epoch BEFORE voting, then finalize the voting epoch.
2. **Future Epoch Queries**: `veMoca.balanceAtEpochEnd()` cannot query future epochs. Tests must warp to the target epoch before querying.
3. **Arithmetic Precision**: Use `uint256` for intermediate calculations to avoid overflow when multiplying large token amounts (e.g., `100 ether * 300 ether`).
4. **Rounding Tolerance**: Pro-rata calculations may have 1-2 wei rounding differences. Use `assertApproxEqAbs()` with small tolerance where appropriate.

---


> cmd

```bash
# Run all integration tests
forge test --match-path "test/5. VotingController/integration_testing/*.t.sol" -vv

# Run specific test file
forge test --match-path "test/5. VotingController/integration_testing/E2E_Voting.t.sol" -vvv
```