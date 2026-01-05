# VotingController Invariant Testing Suite

This document provides a comprehensive overview of the invariant testing suite for `VotingController.sol`. The suite uses Foundry's handler-based invariant testing approach to verify critical protocol properties across randomized sequences of actions.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [File Structure](#file-structure)
4. [Handlers](#handlers)
5. [Invariants](#invariants)
6. [Ghost Variables](#ghost-variables)
7. [Test Execution](#test-execution)
8. [Invariant Categories](#invariant-categories)

---

## Overview

Invariant testing differs from unit and integration testing by exploring the state space through randomized action sequences. Instead of testing specific scenarios, invariant tests verify that certain properties **always hold** regardless of the order or combination of actions performed.

### Key Differences from Other Test Types

| Aspect | Unit Tests | Integration Tests | Invariant Tests |
|--------|-----------|-------------------|-----------------|
| Approach | Specific scenarios | End-to-end flows | Randomized exploration |
| Contracts | Mocked dependencies | Real contracts | Real contracts |
| State Space | Limited paths | Specific paths | Broad coverage |
| Verification | Expected outcomes | Flow correctness | Property invariance |

### What We're Testing

The VotingController manages:
- **Voting**: Personal and delegated voting power allocation to pools
- **Delegation**: Delegate registration, fee management, vote delegation
- **Epochs**: State machine transitions (Voting → Ended → Verified → Processed → Finalized)
- **Rewards**: esMOCA reward distribution based on voting participation
- **Subsidies**: esMOCA subsidy distribution to verifiers
- **Pools**: Creation and removal of voting pools

### Pre-Population for Non-Vacuous Testing

To ensure invariants are tested with meaningful state (not just `0 <= 0`), the test suite pre-populates:

| Pre-Population | Purpose |
|----------------|---------|
| **Locks for actors** | Voters and delegators get voting power |
| **Treasury funding** | Enables reward/subsidy distribution |
| **Initial delegates** | Delegation flows can be exercised |

This prevents "vacuously true" invariants where all values are zero.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    VC_Invariants.t.sol                              │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                    Invariant Assertions                      │    │
│  │  S1-S4: Solvency | V1-V3: Votes | R1-R2: Rewards            │    │
│  │  SUB1-SUB2: Subsidies | E1-E4: Epochs | D1-D4: Delegation   │    │
│  │  P1-P3: Pools | W1-W2: Withdrawals                          │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                              ▲                                      │
│                              │ State Queries                        │
│  ┌──────────────────────────┼──────────────────────────────────┐   │
│  │                    Handler Layer                             │   │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐            │   │
│  │  │VoterHandler │ │DelegateHdlr │ │ClaimsHandler│            │   │
│  │  │ vote()      │ │ register()  │ │ claimRewards│            │   │
│  │  │ migrate()   │ │ updateFee() │ │ claimSubs() │            │   │
│  │  └─────────────┘ └─────────────┘ └─────────────┘            │   │
│  │  ┌─────────────┐ ┌─────────────┐                            │   │
│  │  │EpochHandler │ │AdminHandler │                            │   │
│  │  │ endEpoch()  │ │ createPools │                            │   │
│  │  │ finalize()  │ │ createLock()│                            │   │
│  │  └─────────────┘ └─────────────┘                            │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                      │
│                              ▼ State Mutations + Ghost Updates      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                    Real Contracts                            │   │
│  │  VotingController | VotingEscrowMoca | EscrowedMoca         │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
test/5. VotingController/invariant_testing/
├── InvariantHarness.sol          # Base harness with real contract deployment
├── handlers/
│   ├── VoterHandler.sol          # Personal + delegated voting actions
│   ├── DelegateHandler.sol       # Delegate registration, fee updates, veMoca delegation
│   ├── ClaimsHandler.sol         # Reward, fee, and subsidy claims
│   ├── EpochHandler.sol          # Epoch lifecycle transitions + time warping
│   └── AdminHandler.sol          # Pool creation/removal, lock creation
├── VC_Invariants.t.sol           # Main invariant test contract
└── InvariantTests.md             # This documentation file
```

---

## Handlers

Each handler encapsulates a category of actions and maintains ghost variables to track state independently from the contract.

### VoterHandler

**Purpose**: Execute voting and vote migration actions

| Action | Description | Ghost Variables Updated |
|--------|-------------|------------------------|
| `votePersonal()` | Cast personal votes for a pool | `ghost_poolPersonalVotes`, `ghost_userVotesSpent` |
| `voteDelegated()` | Cast delegated votes (as delegate) | `ghost_poolDelegatedVotes`, `ghost_delegateVotesSpent` |
| `migrateVotesPersonal()` | Migrate personal votes between pools | `ghost_poolPersonalVotes`, `ghost_userPoolVotes` |
| `migrateVotesDelegated()` | Migrate delegated votes between pools | `ghost_poolDelegatedVotes`, `ghost_delegatePoolVotes` |

### DelegateHandler

**Purpose**: Manage delegate lifecycle and lock delegation

| Action | Description | Ghost Variables Updated |
|--------|-------------|------------------------|
| `registerAsDelegate()` | Register as delegate with fee | `ghost_isRegistered`, `ghost_currentFeePct` |
| `updateDelegateFee()` | Update fee (immediate decrease, delayed increase) | `ghost_currentFeePct`, `ghost_nextFeePct` |
| `unregisterAsDelegate()` | Unregister (requires no active votes) | `ghost_isRegistered` |
| `delegateLock()` | Delegate a veMoca lock | `ghost_lockDelegate`, `ghost_delegationEpoch` |
| `undelegateLock()` | Remove lock delegation | `ghost_lockDelegate` |
| `switchDelegate()` | Switch lock to different delegate | `ghost_lockDelegate` |

### ClaimsHandler

**Purpose**: Execute all claim operations

| Action | Description | Ghost Variables Updated |
|--------|-------------|------------------------|
| `claimPersonalRewards()` | Claim personal voting rewards | `ghost_personalRewardsClaimed`, `ghost_poolRewardsClaimed` |
| `claimDelegatedRewards()` | Claim net rewards from delegation | `ghost_delegatedRewardsClaimed` |
| `claimDelegationFees()` | Claim fees as delegate | `ghost_delegateFeesClaimed` |
| `claimSubsidies()` | Claim verifier subsidies | `ghost_subsidiesClaimed`, `ghost_poolSubsidiesClaimed` |

### EpochHandler

**Purpose**: Manage epoch lifecycle and time

| Action | Description | Ghost Variables Updated |
|--------|-------------|------------------------|
| `endEpoch()` | Transition to Ended state | `ghost_epochState` |
| `processVerifierChecks()` | Process/block verifiers, transition to Verified | `ghost_verifierBlocked`, `ghost_epochState` |
| `processRewardsAndSubsidies()` | Allocate rewards/subsidies to pools | `ghost_epochRewardsAllocated`, `ghost_poolRewardsAllocated` |
| `finalizeEpoch()` | Complete finalization, enable claims | `ghost_isFinalized`, `ghost_totalRewardsDeposited` |
| `forceFinalizeEpoch()` | Emergency finalization | `ghost_epochState` |
| `warpTime()` | Advance blockchain time | `ghost_warpCalls` |
| `completeEpochFinalization()` | Full finalization cycle in one call | All epoch ghost variables |

### AdminHandler

**Purpose**: Administrative operations

| Action | Description | Ghost Variables Updated |
|--------|-------------|------------------------|
| `createPools()` | Create 1-10 new pools | `ghost_activePoolIds`, `ghost_totalPoolsCreated` |
| `removePools()` | Remove a pool | `ghost_poolIsActive`, `ghost_totalActivePools` |
| `createLock()` | Create veMoca lock for voting power | `ghost_activeLockIds`, `ghost_totalLockedMoca` |
| `unlockLock()` | Unlock expired lock | `ghost_totalLockedMoca` |
| `pause()` / `unpause()` | Risk management | `ghost_isPaused` |

---

## Invariants

### Solvency Invariants

These ensure the contract always has sufficient funds to cover all outstanding claims.

| ID | Invariant | Description |
|----|-----------|-------------|
| **S1** | `esMoca.balanceOf(VC) >= outstanding rewards + outstanding subsidies` | Contract holds enough esMOCA for all unclaimed rewards and subsidies |
| **S2** | `address(VC).balance >= outstanding registration fees` | Contract holds enough native MOCA for unclaimed registration fees |
| **S3** | `epoch.totalRewardsClaimed <= epoch.totalRewardsAllocated` | Per-epoch reward claims never exceed allocation |
| **S4** | `epoch.totalSubsidiesClaimed <= epoch.totalSubsidiesAllocated` | Per-epoch subsidy claims never exceed allocation |

### Vote Conservation Invariants

These ensure votes are never created or destroyed, only moved.

| ID | Invariant | Description |
|----|-----------|-------------|
| **V1** | `poolVotes == sum(userPoolVotes) + sum(delegatePoolVotes)` | Pool total equals sum of all voter contributions |
| **V2** | `user.totalVotesSpent == sum(user.poolVotes)` | User total equals sum across pools |
| **V3** | `delegate.totalVotesSpent == sum(delegate.poolVotes)` | Delegate total equals sum across pools |

### Reward Distribution Invariants

| ID | Invariant | Description |
|----|-----------|-------------|
| **R1** | `TOTAL_REWARDS_CLAIMED <= TOTAL_REWARDS_DEPOSITED` | Global rewards never overclaimed |
| **R2** | `pool.totalRewardsClaimed <= pool.totalRewardsAllocated` | Per-pool rewards never overclaimed |

### Subsidy Distribution Invariants

| ID | Invariant | Description |
|----|-----------|-------------|
| **SUB1** | `TOTAL_SUBSIDIES_CLAIMED <= TOTAL_SUBSIDIES_DEPOSITED` | Global subsidies never overclaimed |
| **SUB2** | `pool.totalSubsidiesClaimed <= pool.totalSubsidiesAllocated` | Per-pool subsidies never overclaimed |

### Epoch State Machine Invariants

| ID | Invariant | Description |
|----|-----------|-------------|
| **E1** | Prior epochs are finalized | All epochs before CURRENT_EPOCH_TO_FINALIZE have state >= Finalized |
| **E2** | Monotonic progression | CURRENT_EPOCH_TO_FINALIZE only increases |
| **E3** | Finalized state consistency | Finalized epochs have correct state enum |
| **E4** | Full processing | Finalized epochs have poolsProcessed == totalActivePools |

### Delegation Invariants

| ID | Invariant | Description |
|----|-----------|-------------|
| **D1** | Registration sync | VC and veMoca agree on delegate registration status |
| **D2** | Fee bounds | `currentFeePct <= MAX_DELEGATE_FEE_PCT` |
| **D3** | Fee delay respected | Fee increases take effect after FEE_INCREASE_DELAY_EPOCHS |
| **D4** | No unregister with votes | Delegates with active votes cannot unregister |

### Pool Invariants

| ID | Invariant | Description |
|----|-----------|-------------|
| **P1** | Count consistency | `TOTAL_POOLS_CREATED >= TOTAL_ACTIVE_POOLS` |
| **P2** | Sequential IDs | Pool IDs are 1 to TOTAL_POOLS_CREATED |
| **P3** | Active count matches | Counted active pools equals TOTAL_ACTIVE_POOLS |

### Withdrawal Invariants

| ID | Invariant | Description |
|----|-----------|-------------|
| **W1** | Reward conservation | `claimed + withdrawn <= allocated` for rewards |
| **W2** | Subsidy conservation | `claimed + withdrawn <= allocated` for subsidies |

---

## Ghost Variables

Ghost variables provide an independent tracking mechanism to verify contract state. They're updated by handlers during actions and compared against contract state in invariants.

### Key Ghost Variable Categories

```solidity
// Vote Tracking
mapping(epoch => mapping(poolId => uint128)) ghost_poolPersonalVotes;
mapping(epoch => mapping(poolId => uint128)) ghost_poolDelegatedVotes;
mapping(epoch => mapping(user => uint128)) ghost_userVotesSpent;

// Reward/Subsidy Tracking
uint128 ghost_totalRewardsDeposited;
uint128 ghost_totalSubsidiesDeposited;
mapping(epoch => mapping(poolId => uint128)) ghost_poolRewardsClaimed;

// Delegation Tracking
mapping(address => bool) ghost_isRegistered;
mapping(address => uint128) ghost_currentFeePct;

// Pool Tracking
uint128 ghost_totalPoolsCreated;
uint128 ghost_totalActivePools;
mapping(uint128 => bool) ghost_poolIsActive;

// Epoch State
mapping(uint128 => EpochState) ghost_epochState;
mapping(uint128 => bool) ghost_isFinalized;
```

---

## Test Execution

### Running All Invariant Tests

```bash
# Standard run
forge test --match-contract VotingControllerInvariant

# With detailed output
forge test --match-contract VotingControllerInvariant -vvvv

# With custom configuration
forge test --match-contract VotingControllerInvariant \
    --invariant-runs 500 \
    --invariant-depth 50
```

### Running Specific Invariant Categories

```bash
# Solvency invariants
forge test --match-test "invariant_S"

# Vote conservation
forge test --match-test "invariant_V"

# Epoch state machine
forge test --match-test "invariant_E"

# Delegation
forge test --match-test "invariant_D"
```


---

## Invariant Categories

### Category Summary

| Category | Count | Severity | Focus |
|----------|-------|----------|-------|
| Solvency (S) | 4 | Critical | Funds conservation |
| Votes (V) | 3 | High | Vote accounting |
| Rewards (R) | 2 | High | Reward distribution |
| Subsidies (SUB) | 2 | High | Subsidy distribution |
| Epochs (E) | 4 | Medium | State machine |
| Delegation (D) | 4 | Medium | Delegate lifecycle |
| Pools (P) | 3 | Low | Pool management |
| Withdrawals (W) | 2 | Medium | Unclaimed handling |

### Strictness Levels

| Level | Description | Tolerance |
|-------|-------------|-----------|
| **Strict** | Must hold exactly | 0 wei |
| **Approximate** | Allows minor rounding | 1-2 wei |
| **Conditional** | Depends on state | Context-specific |

---

## Edge Cases Covered

The invariant suite specifically tests for:

1. **Zero-vote epochs**: Epochs with no voting activity
2. **Zero-allocation pools**: Pools with votes but no rewards
3. **Force finalization**: Emergency finalization path
4. **Blocked verifiers**: Verifiers blocked during epoch processing
5. **Fee changes across epochs**: Delayed fee increases
6. **Pool removal mid-epoch**: Votes remain, new votes blocked
7. **Multiple claim attempts**: Double-claim prevention
8. **Delegation timing**: Pending vs active delegation states

---

## Integration with CI/CD

```bash
# Recommended CI command
forge test --match-contract VotingControllerInvariant \
    --invariant-runs 128 \
    --invariant-depth 25 \
    --no-match-test "skip_ci" \
    -v
```

---

## Debugging Failed Invariants

When an invariant fails:

1. **Check the call sequence**: Foundry shows the sequence of calls that led to failure
2. **Examine ghost vs contract state**: Compare ghost variable to contract getter
3. **Look for off-by-one**: Common in reward calculations due to rounding
4. **Check epoch boundaries**: Many issues occur at epoch transitions
5. **Verify preconditions**: Ensure handler's try/catch didn't mask an error

### Common Failure Patterns

| Pattern | Likely Cause | Resolution |
|---------|--------------|------------|
| Solvency mismatch | Uncounted transfer | Verify all token flows update counters |
| Vote count off | Migration bug | Check source/dest pool updates |
| Epoch state wrong | Missing transition | Verify state machine in handler |
| Fee not applied | Delay calculation | Check epoch arithmetic |

---

## References

- [VotingController.sol](../../../src/VotingController.sol) - Main contract
- [DataTypes.sol](../../../src/libraries/DataTypes.sol) - Struct definitions
- [EpochMath.sol](../../../src/libraries/EpochMath.sol) - Epoch calculations
- [Integration Tests](../integration_testing/) - End-to-end test patterns
- [VotingEscrowMoca Invariants](../../4.%20VotingEscrowMoca/Invariant/) - Reference implementation

