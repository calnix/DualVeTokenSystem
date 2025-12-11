---
name: Delegation Test Suite V2
overview: Create a comprehensive new test file (veDelegateTestV2.t.sol) that systematically tests all three lock delegation states (undelegated, pending delegation, active delegation) with proper state transitions, covering increaseAmount/increaseDuration behavior differences, multi-user delegation scenarios, and emergency exit.
todos:
  - id: create-test-file
    content: Create veDelegateTestV2.t.sol with base state contracts (E1 setup through E2 active delegation)
    status: completed
  - id: test-active-delegation
    content: Add tests for increaseAmount/increaseDuration on ACTIVE delegated locks
    status: completed
  - id: test-pending-delegation
    content: Add tests for increaseAmount/increaseDuration on PENDING delegated locks
    status: completed
  - id: delegation-actions
    content: Add switchDelegate and undelegateLock test sequences
    status: completed
  - id: multi-user-scenarios
    content: Add complex multi-user delegation scenarios (user as both delegator and delegatee)
    status: completed
  - id: emergency-exit
    content: Add emergency exit tests verifying all users receive principals
    status: completed
  - id: helper-functions
    content: Update delegateHelper.sol with verify functions for active vs pending delegation states
    status: completed
---

# Comprehensive Delegation Test Suite V2

## Overview

Create [`test/4. VotingEscrowMoca/veDelegateTestV2.t.sol`](test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol)(test/4. VotingEscrowMoca/veDelegateTestV2.t.sol) - a new test file that systematically tests all three lock delegation states with clear state progression and verification.

## Lock States to Test

1. **Undelegated**: `lock.delegate == address(0)` - Owner holds VP
2. **Pending Delegation**: `lock.delegationEpoch > currentEpochStart` - Delegation initiated, takes effect next epoch
3. **Active Delegation**: `lock.delegate != address(0)` AND `lock.delegationEpoch <= currentEpochStart` - Delegate holds VP

## Key Behavioral Differences

For `increaseAmount`/`increaseDuration` on locks:

- **Active Delegation**: currentAccount = delegate, futureAccount = delegate - Delegate gets immediate benefit, no pending deltas
- **Pending Delegation**: currentAccount = owner, futureAccount = delegate - Owner gets immediate benefit, pending deltas queued for transfer

## State Transition Sequence

### Phase 1: Setup and Active Delegation Tests (E1-E2)

```
StateE1_Deploy
  └─ StateE1_User1_CreateLock1 (lock1 expires E3)
      └─ StateE1_RegisterDelegate_User3
          └─ StateE1_User1_DelegateLock1_ToUser3 (pending delegation)
              └─ StateE2_Lock1DelegationTakesEffect (warp to E2 + cronjob)
```

### Phase 2: Active Delegation - Modify Operations (E2)

```
StateE2_User1_CreatesLock2_DelegatesToUser3
  ├─ lock2 created in E2, delegates to user3 → enters PENDING state
  ├─ cronjob updates → lock2 enters ACTIVE state
  └─ Test: increaseAmount/increaseDuration on ACTIVE delegated lock
      
StateE2_IncreaseDuration_ActiveDelegation_Lock2
  └─ Verify: delegate gets immediate VP increase (no pending deltas)
  
StateE2_IncreaseAmount_ActiveDelegation_Lock2
  └─ Verify: delegate gets immediate VP increase (no pending deltas)
```

### Phase 3: Pending Delegation - Modify Operations (E2)

```
StateE2_User1_CreatesLock3_PendingDelegation
  ├─ lock3 created in E2, delegates to user3 → PENDING state (NO cronjob)
  └─ Test: increaseAmount/increaseDuration on PENDING delegated lock

StateE2_IncreaseDuration_PendingDelegation_Lock3
  └─ Verify: owner gets immediate VP, pending deltas queued
  
StateE2_IncreaseAmount_PendingDelegation_Lock3
  └─ Verify: owner gets immediate VP, pending deltas queued
```

### Phase 4: Delegation Actions (E2-E4)

```
StateE2_SwitchDelegate_Lock2 (switch from user3 → user2)
  └─ Verify: pending deltas for old/new delegate
  
StateE2_Undelegate_Lock3
  └─ Verify: pending addition to owner, subtraction from delegate
  
StateE4_Unlock_ExpiredLock1
  └─ Verify: principals returned, global state updated
```

### Phase 5: Multi-User Complex Scenarios (E4+)

```
StateE4_User3_CreatesLock4_DelegatesToUser2
  └─ User2 receives delegations from multiple users

StateE4_User2_CreatesLock5_Personal
  └─ User2 has both personal VP (lock5) + delegated VP (from others)
  
StateE4_User2_CreatesLock6_DelegatesToUser1
  └─ Test: user can be both delegator and delegatee

StateE5_User1_CreatesLock7_DelegatesToUser3
  └─ Complex scenario:
      - user1: personal(lock7→user3) + delegatedBy(lock6 from user2)
      - user2: personal(lock5) + delegatedTo(lock6→user1) + delegatedBy(lock4 from user3)
      - user3: personal(none) + delegatedTo(lock4→user2, lock7 from user1)
```

### Phase 6: Emergency Exit Tests

```
StateEmergencyExit
  └─ Verify: all users receive principals regardless of delegation state
```

## Helper Functions to Add

Update [`test/4. VotingEscrowMoca/delegateHelper.sol`](test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol)(test/4. VotingEscrowMoca/delegateHelper.sol):

1. `verifyIncreaseAmountActiveDelegation()` - for ACTIVE delegation state
2. `verifyIncreaseDurationActiveDelegation()` - for ACTIVE delegation state  
3. `verifyIncreaseAmountPendingDelegation()` - for PENDING delegation state (already exists as `verifyIncreaseAmountDelegated`)
4. `verifyIncreaseDurationPendingDelegation()` - for PENDING delegation state (already exists as `verifyIncreaseDurationDelegated`)

## Test Categories Per State Contract

Each state contract test should include:

1. **State Verification Tests** - Verify lock/user/delegate/global state
2. **View Function Tests** - `balanceOfAt`, `balanceAtEpochEnd`, `getLockVotingPowerAt`, `getSpecificDelegatedBalanceAtEpochEnd`
3. **Negative Tests** - Revert conditions for the current state
4. **State Transition Test** - Setup for next state

## Key Invariants to Verify Throughout

- `totalSupply = sum of all active lock VPs`
- `user.personalVP + user.delegatedVP = total VP attributable to user`  
- `delegate.delegatedVP = sum of VPs delegated to delegate`
- Global `TOTAL_LOCKED_MOCA/ESMOCA` matches sum of lock principals