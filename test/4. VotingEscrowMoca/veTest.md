# Specific Edge Cases to Cover

1. The "Cliff": Create a lock that expires exactly at MAX_LOCK_DURATION.

2. The "Dust": Create locks with 1e13 (min amount). Ensure rounding doesn't zero out voting power.

3.The "Churn": A delegate receives 100 delegations, then 100 undelegations in the same epoch. Verify pendingDeltas are processed correctly in the next epoch update.

4. Circular Dependency (Social): User A delegates to B. B delegates (their personal locks) to A. Verify balanceOfAt resolves correctly (it should, as the streams are separated).Specific Edge Cases to Cover




# Other notes

Owners cannot undelegate or switch delegates during the final two epochs of a lock
- last epoch of a lock is considered to have 0 voting power, VotingController tracks voting power based on balanceOfAt(), at the end of the epoch
- also, delegation takes effect in the next epoch; not current
- as a result of these 2 points, once a lock is within 2 epochs of expiry, there is no point in switching delegate or undelegating
- the 3rd epoch from last, is the final epoch in which a lock can switch/undelegate


# veUser Test Sequence

```
StateE1_Deploy
    └── StateE1_User1_CreateLock1
            └── StateE2_CronJobUpdatesState
                    └── StateE2_User1_CreateLock2
                            └── StateE2_User1_IncreaseAmountLock2
                                    └── StateE2_User1_IncreaseDurationLock2
                                            └── StateE3_User2_CreateLock3
                                                    └── StateE4_User1_UnlocksLock1
                                                            └── StateE4_PauseContract
                                                                    └── StateE4_FreezeContract
```


# veDelegation Test Sequence (veDelegateTestV2.t.sol)


```
StateE1_Deploy
  └── StateE1_User1_CreateLock1 [lock1: 100 MOCA + 100 esMOCA, expires E3]
        └── StateE1_RegisterDelegate_User3 [Register user3 as delegate]
              └── StateE1_User1_DelegateLock1_ToUser3 [lock1 → PENDING DELEGATION]
                    └── StateE2_Lock1DelegationTakesEffect [Warp E2 + cronjob → ACTIVE]
                          └── StateE2_User1_CreatesLock2 [lock2: 200+200, expires E10, delegate to user3]
                                └── StateE2_User1_IncreaseDuration_Lock2 [E10 → E12]
                                      └── StateE2_User1_IncreaseAmount_Lock2 [+50 MOCA, +50 esMOCA]
                                            └── StateE2_User1_SwitchDelegate_Lock2 [user3 → user2]
                                                  └── StateE2_User1_Undelegates_Lock2 [user2 → none]
                                                        └── StateE4_User1_Unlocks_Lock1 [lock1 expired, unlock]
                                                              └── StateE4_User3_DelegateLock3_ToUser2 [multi-user scenarios]
                                                                    └── StateEmergencyExit [freeze + emergency exit]
```

## Three Lock Delegation States

A lock can exist in one of three delegation states:

| State | Condition | Who Holds VP | Behavior on increaseAmount/increaseDuration |
|-------|-----------|--------------|---------------------------------------------|
| **Undelegated** | `lock.delegate == address(0)` | Owner | Owner gets immediate VP increase |
| **Pending Delegation** | `lock.delegationEpoch > currentEpochStart` | Owner (until next epoch) | Owner gets immediate VP, pending deltas queued for delegate |
| **Active Delegation** | `lock.delegate != address(0)` AND `lock.delegationEpoch <= currentEpochStart` | Delegate | Delegate gets immediate VP, NO pending deltas |

### Key Insight: currentAccount vs futureAccount

```
For ACTIVE delegation:
  currentAccount = delegate
  futureAccount = delegate
  → Same account, no pending deltas needed

For PENDING delegation:
  currentAccount = owner (via lock.currentHolder)
  futureAccount = delegate
  → Different accounts, pending deltas queue the transfer
```

---

## State Inheritance Chain

```
StateE1_Deploy
  └── StateE1_User1_CreateLock1 [lock1 expires E3, UNDELEGATED]
        └── StateE1_RegisterDelegate_User3 [user3 registered as delegate]
              └── StateE1_User1_DelegateLock1_ToUser3 [lock1 → PENDING DELEGATION]
                    │
                    ├── StateE1_User1_DelegateLock1_ToUser3_Test (4 tests)
                    │
                    └── StateE2_Lock1DelegationTakesEffect [warp E2 + cronjob → ACTIVE]
                          │
                          ├── StateE2_Lock1DelegationTakesEffect_Test (4 tests)
                          │
                          └── StateE2_Lock2_ActiveDelegation [lock2 created, delegated, cronjob → ACTIVE]
                                │
                                ├── StateE2_Lock2_ActiveDelegation_Test (6 tests)
                                │
                                └── StateE3_Lock3_PendingDelegation [lock3 created + delegated, NO cronjob → PENDING]
                                      │
                                      ├── StateE3_Lock3_PendingDelegation_Test (5 tests)
                                      │
                                      └── StateE3_RegisterUser2_SwitchDelegate [user2 registered]
                                            │
                                            ├── StateE3_SwitchDelegate_Test (4 tests)
                                            ├── StateE3_Undelegate_Test (3 tests)
                                            │
                                            └── StateE4_UnlockExpiredLock1 [warp E4, lock1 expired, unlocked]
                                                  │
                                                  ├── StateE4_UnlockExpiredLock1_Test (7 tests)
                                                  │
                                                  └── StateE4_MultiUserDelegation [complex multi-user scenario]
                                                        │
                                                        ├── StateE4_MultiUserDelegation_Test (6 tests)
                                                        │
                                                        └── StateEmergencyExit [warp E20+, all locks expired]
                                                              │
                                                              └── StateEmergencyExit_Test (4 tests)
```

---

## Phase-by-Phase Breakdown

### Phase 1: Setup & Initial Delegation (E1)

**StateE1_Deploy**
- Deploy contracts, warp to start of E1
- Base state for all tests

**StateE1_User1_CreateLock1**
- User1 creates lock1 (100 MOCA + 100 esMOCA, expires E3)
- Lock is UNDELEGATED
- Grant cronJob role

**StateE1_RegisterDelegate_User3**
- Setup VotingController mock
- Register user3 as delegate

**StateE1_User1_DelegateLock1_ToUser3**
- User1 delegates lock1 to user3
- Lock enters PENDING DELEGATION state
- `lock.delegationEpoch = nextEpochStart`
- `lock.currentHolder = user1`

Tests (`StateE1_User1_DelegateLock1_ToUser3_Test`):
| Test | Validates |
|------|-----------|
| `test_DelegateLock1_ToUser3` | Full state verification via `verifyDelegateLock()` |
| `test_Lock1_InPendingDelegationState` | `delegationEpoch > currentEpochStart` |
| `test_User1_StillHasVP_InE1` | Owner retains VP during pending period |
| `test_User3_HasZeroVP_InE1` | Delegate has 0 VP during pending period |

---

### Phase 1b: Delegation Takes Effect (E2)

**StateE2_Lock1DelegationTakesEffect**
- Warp to E2 start
- Run cronjob: `updateAccountsAndPendingDeltas()` + `updateDelegatePairs()`
- Lock1 enters ACTIVE DELEGATION state

Tests (`StateE2_Lock1DelegationTakesEffect_Test`):
| Test | Validates |
|------|-----------|
| `test_Lock1_NowInActiveDelegationState` | `delegationEpoch <= currentEpochStart` |
| `test_User1_HasZeroPersonalVP_InE2` | Owner lost VP |
| `test_User3_HasDelegatedVP_InE2` | Delegate gained VP |
| `test_PendingDeltas_Cleared` | No pending deltas remain at E2 start |

---

### Phase 2: Active Delegation Operations (E3)

**StateE2_Lock2_ActiveDelegation**
- User1 creates lock2 (200 MOCA + 200 esMOCA, expires E10)
- User1 delegates lock2 to user3
- Warp to E3 + cronjob → lock2 is ACTIVE DELEGATION

Tests (`StateE2_Lock2_ActiveDelegation_Test`):
| Test | Validates |
|------|-----------|
| `test_Lock2_InActiveDelegationState` | Lock2 delegation is active |
| `test_User3_HasLock2VP` | User3 has lock2's VP |
| **`test_IncreaseDuration_ActiveDelegation_DelegateGetsImmediateVP`** | **CRITICAL: Delegate gets immediate VP, NO pending deltas** |
| **`test_IncreaseAmount_ActiveDelegation_DelegateGetsImmediateVP`** | **CRITICAL: Delegate gets immediate VP, NO pending deltas** |
| `testRevert_IncreaseDuration_NonOwner` | Only owner can increase duration |
| `testRevert_IncreaseAmount_NonOwner` | Only owner can increase amount |

**Critical Behavioral Verification (Active Delegation):**
```solidity
// After increaseDuration on ACTIVE lock:
assertEq(user3DelegatedVpAfter, user3DelegatedVpBefore + biasDelta);  // Delegate VP increased
assertFalse(hasAdd);  // NO pending addition
assertFalse(hasSub);  // NO pending subtraction
assertEq(user1VpAfter, 0);  // Owner VP still 0
```

---

### Phase 3: Pending Delegation Operations (E3)

**StateE3_Lock3_PendingDelegation**
- User1 creates lock3 (150 MOCA + 150 esMOCA, expires E12)
- User1 delegates lock3 to user3
- **NO cronjob run** → lock3 stays in PENDING DELEGATION

Tests (`StateE3_Lock3_PendingDelegation_Test`):
| Test | Validates |
|------|-----------|
| `test_Lock3_InPendingDelegationState` | `delegationEpoch > currentEpochStart` |
| `test_User1_HasLock3VP_WhilePending` | Owner has VP while pending |
| **`test_IncreaseDuration_PendingDelegation_OwnerGetsImmediateVP`** | **CRITICAL: Owner gets immediate VP, pending deltas queued** |
| **`test_IncreaseAmount_PendingDelegation_OwnerGetsImmediateVP`** | **CRITICAL: Owner gets immediate VP, pending deltas queued** |
| `test_CompareBehavior_ActiveVsPending` | Documents the behavioral difference |

**Critical Behavioral Verification (Pending Delegation):**
```solidity
// After increaseDuration on PENDING lock:
assertEq(user1VpAfter, user1VpBefore + biasDelta);  // Owner VP increased
assertEq(user3DelegatedVpAfter, user3DelegatedVpBefore);  // Delegate VP unchanged
assertTrue(user1HasSub);  // Pending subtraction queued for owner
assertTrue(user3HasAdd);  // Pending addition queued for delegate
```

---

### Phase 4: Delegation Actions

**StateE3_RegisterUser2_SwitchDelegate**
- Register user2 as delegate

**Switch Delegate Tests (`StateE3_SwitchDelegate_Test`):**
| Test | Validates |
|------|-----------|
| `test_SwitchDelegate_Lock2_FromUser3ToUser2` | Switch + pending deltas for old/new delegate |
| `testRevert_SwitchDelegate_ToSameDelegate` | Cannot switch to same delegate |
| `testRevert_SwitchDelegate_ToUnregisteredDelegate` | Target must be registered |
| `testRevert_SwitchDelegate_ToSelf` | Cannot delegate to self |

**Undelegate Tests (`StateE3_Undelegate_Test`):**
| Test | Validates |
|------|-----------|
| `test_Undelegate_Lock3` | Undelegate + pending deltas for owner/delegate |
| `testRevert_Undelegate_NotDelegated` | Cannot undelegate non-delegated lock |
| `testRevert_Undelegate_NonOwner` | Only owner can undelegate |

---

### Phase 4b: Unlock Expired Lock (E4)

**StateE4_UnlockExpiredLock1**
- Warp to E4 (past lock1 expiry at E3)
- Unlock lock1

Tests (`StateE4_UnlockExpiredLock1_Test`):
| Test | Validates |
|------|-----------|
| `test_Lock1_IsUnlocked` | `isUnlocked = true` |
| `test_User1_ReceivedPrincipals` | User1 received MOCA + esMOCA |
| `test_TotalLocked_Decreased` | Global totals updated |
| `test_Lock1_HasZeroVP` | Expired lock has 0 VP |
| `testRevert_Unlock_NonExpiredLock` | Cannot unlock active lock |
| `testRevert_Unlock_AlreadyUnlocked` | Cannot unlock twice |
| `testRevert_Unlock_NonOwner` | Only owner can unlock |

---

### Phase 5: Multi-User Complex Scenarios (E5)

**StateE4_MultiUserDelegation**
- Register user1 as delegate
- user3 creates lock4, delegates to user2
- user2 creates lock5 (personal, no delegation)
- user2 creates lock6, delegates to user1
- Warp to E5 + cronjob

**Final State:**
```
user1: personalVP = 0, delegatedVP = lock6 (from user2)
user2: personalVP = lock5, delegatedVP = lock4 (from user3)
user3: personalVP = 0 (lock4 delegated), delegatedVP = 0
```

Tests (`StateE4_MultiUserDelegation_Test`):
| Test | Validates |
|------|-----------|
| `test_User2_HasBothPersonalAndDelegatedVP` | User can have personal + delegated VP |
| `test_User1_HasDelegatedVP_FromUser2` | Cross-user delegation works |
| `test_User3_HasPersonalVP_FromLock4` | Delegator loses personal VP |
| `test_GlobalState_MatchesSumOfAllLocks` | Total supply = sum of all lock VPs |
| `test_SpecificDelegatedBalance_User3ToUser2` | Pair-specific balance is correct |
| `test_SpecificDelegatedBalance_User2ToUser1` | Pair-specific balance is correct |

---

### Phase 6: Emergency Exit (E20+)

**StateEmergencyExit**
- Warp far into future (E20+)
- All locks are expired

Tests (`StateEmergencyExit_Test`):
| Test | Validates |
|------|-----------|
| `test_EmergencyExit_AllUsersCanUnlock` | All owners can unlock their delegated locks |
| `test_EmergencyExit_DelegationDoesNotAffectUnlock` | Owner unlocks despite delegation |
| `test_EmergencyExit_DelegateCannotUnlock` | Delegate cannot unlock |
| `test_EmergencyExit_GlobalState_AllLocksCleared` | All globals = 0 after full unlock |

---

## Summary: 43 Total Tests

| Phase | Test Contract | Tests |
|-------|---------------|-------|
| 1 | `StateE1_User1_DelegateLock1_ToUser3_Test` | 4 |
| 1b | `StateE2_Lock1DelegationTakesEffect_Test` | 4 |
| 2 | `StateE2_Lock2_ActiveDelegation_Test` | 6 |
| 3 | `StateE3_Lock3_PendingDelegation_Test` | 5 |
| 4 | `StateE3_SwitchDelegate_Test` | 4 |
| 4 | `StateE3_Undelegate_Test` | 3 |
| 4b | `StateE4_UnlockExpiredLock1_Test` | 7 |
| 5 | `StateE4_MultiUserDelegation_Test` | 6 |
| 6 | `StateEmergencyExit_Test` | 4 |
| **Total** | | **43** |

---

## Helper Functions (delegateHelper.sol)

| Function | Use Case |
|----------|----------|
| `verifyDelegateLock()` | Verify state after `delegateLock()` |
| `verifySwitchDelegate()` | Verify state after `switchDelegate()` |
| `verifyUndelegateLock()` | Verify state after `undelegateLock()` |
| `verifyIncreaseAmountDelegated()` | Verify `increaseAmount` on PENDING delegated lock |
| `verifyIncreaseDurationDelegated()` | Verify `increaseDuration` on PENDING delegated lock |
| `verifyIncreaseAmountActiveDelegation()` | Verify `increaseAmount` on ACTIVE delegated lock |
| `verifyIncreaseDurationActiveDelegation()` | Verify `increaseDuration` on ACTIVE delegated lock |
| `captureAllStatesPlusDelegates()` | Capture full state snapshot for before/after comparison |

---

**1. Basic Delegation Flow**
- Register delegates
- User delegates lock to registered delegate
- Verify delegation doesn't take effect immediately (delayed to next epoch)

**2. Delegation Effect Timing**
- Verify pending deltas are booked for next epoch
- Warp to next epoch and verify delegation takes effect
- User loses VP, delegate gains VP

**3. Operations on Delegated Locks**
- `increaseAmount` on delegated lock affects delegate (not user)
- `increaseDuration` on delegated lock affects delegate
- All slopeChanges and history updates go to delegate

**4. Switch Delegate**
- Switch from delegate1 to delegate2
- Verify pending deltas booked for both old and new delegate
- Verify switch takes effect next epoch

**5. Undelegate**
- User removes delegation
- Verify pending deltas shift from delegate back to user
- User regains VP next epoch

**6. Multiple Delegators**
- Multiple users delegate to same delegate
- getSpecificDelegatedBalanceAtEpochEnd returns correct per-user contributions
- Partial undelegation only affects one user's contribution

**7. Unlock Delegated Lock**
- Unlock works on expired delegated locks
- Delegate's VP correctly reflects expiry
- User-delegate pair state cleaned up

**8. Edge Cases**
- Cannot delegate already-delegated lock
- Cannot switch to same delegate
- Cannot undelegate non-delegated lock
- Delegation action counter per epoch


--- 

# veCreateFor 

## 1. StateE1_Setup - Base setup with 4 initial locks:

- lock1_Id: user1 self-lock
- lock2_Id: user1 → user2 (delegated)
- lock3_Id: user2 self-lock
- lock4_Id: user2 → user1 (delegated)
- Helper functions _verifyLock() and _verifyEventsEmitted() moved here for reuse

## 2. StateE2_AdvanceEpoch 

- Advances to E2 with cronjob updates

## 3. StateE2_AdvanceEpoch_Test 

- Tests initial state after E2

## 4. StateE2_CreateLockFor_SameAmounts - Abstract setup:

- Captures beforeStateUser1 and beforeStateUser2 using captureAllStatesPlusDelegates
- Executes createLockFor with same amounts (50 ether each)
- Captures afterStateUser1 and afterStateUser2 with new lock IDs

## 5. StateE2_CreateLockFor_SameAmounts_Test 

- 5 verification tests

## 6. StateE2_CreateLockFor_DifferentAmounts - Abstract setup:

- Captures before states using lock5/lock6 from previous phase
- Executes createLockFor with different amounts (10/20 for user1, 30/40 for user2)
- Captures after states with new lock7/lock8 IDs

## 7. StateE2_CreateLockFor_DifferentAmounts_Test 

- 6 verification tests