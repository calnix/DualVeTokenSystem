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


# Test Sequence

## E1: StateE1_User1_CreateLock1

- user1 creates lock 1
- lock1: 100 moca, 100 esMoca, expiry: end of epoch3

### StateE1_User1_CreateLock1_Test

`test_totalSupplyAt_CrossEpochBoundary_Epoch2`
- test

