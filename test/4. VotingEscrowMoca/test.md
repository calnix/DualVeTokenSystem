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


# veDelegation Test Sequence


```
StateD1_Deploy
  └── StateD1_SetupDelegate1 [Register delegates, create lock1]
        └── StateD2_User1_DelegatesLock1_ToDelegate1 [Delegation initiated]
              └── StateD3_DelegationTakesEffect [Warp to next epoch]
                    └── StateD3_User1_IncreaseAmountOnDelegatedLock
                          └── StateD4_User1_SwitchDelegate_ToDelegate2
                                └── StateD5_SwitchTakesEffect
                                      └── StateD6_User1_Undelegate
                                            └── StateD7_UndelegateTakesEffect
                                                  └── StateD8_MultipleUsersToSameDelegate
                                                        └── StateD9_UnlockDelegatedLock
```

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