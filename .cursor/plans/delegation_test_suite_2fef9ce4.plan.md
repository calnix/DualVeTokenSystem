---
name: Delegation Test Suite
overview: Build a comprehensive delegation-focused testing suite in veDelegateTest.t.sol following a state machine pattern with 14 abstract state contracts and their corresponding test contracts, covering the full delegation lifecycle from lock creation through unlock.
todos:
  - id: e2-delegation-takes-effect
    content: Add StateE2_Lock1DelegationTakesEffect + Test contracts
    status: completed
  - id: e2-creates-lock2
    content: Add StateE2_User1_CreatesLock2 + Test contracts
    status: completed
  - id: e2-increase-duration
    content: Add StateE2_User1_IncreaseDuration_Lock2 + Test contracts
    status: completed
  - id: e2-increase-amount
    content: Add StateE2_User1_IncreaseAmount_Lock2 + Test contracts
    status: completed
  - id: e2-switch-delegate
    content: Add StateE2_User1_SwitchDelegate_Lock2 + Test (register user2 in setUp)
    status: completed
  - id: e2-undelegate
    content: Add StateE2_User1_Undelegates_Lock2 + Test contracts
    status: completed
  - id: e4-unlock-lock1
    content: Add StateE4_User1_Unlocks_Lock1 + Test contracts
    status: completed
  - id: e4-delegate-lock3
    content: Add StateE4_User3_DelegateLock3_ToUser2 + Test contracts
    status: completed
  - id: e4-create-lock4
    content: Add StateE4_User2_CreatesLock4 + Test contracts
    status: completed
  - id: cleanup
    content: Remove commented-out code and specialized capture functions
    status: completed
---

# Delegation Test Suite for VotingEscrowMoca

## Overview

Extend [test/4. VotingEscrowMoca/veDelegateTest.t.sol](test/4. VotingEscrowMoca/veDelegateTest.t.sol) with a comprehensive delegation testing suite. The existing file has partial implementation through E1. We will add E2 and E4 state contracts.

## File Structure

All changes in `veDelegateTest.t.sol`. Leverages helpers from [test/4. VotingEscrowMoca/delegateHelper.sol](test/4. VotingEscrowMoca/delegateHelper.sol).

## State Contracts to Add

### Epoch 2 - Delegation Takes Effect

**1. StateE2_Lock1DelegationTakesEffect** (inherits StateE1_User1_DelegateLock1_ToUser3)

- setUp: warp to E2 start

**2. StateE2_Lock1DelegationTakesEffect_Test**

- Test cronjob functions: `updateAccountsAndPendingDeltas()` and `updateDelegatePairs()`
- Verify totalSupplyAt[E1] is finalized after crossing epoch boundary
- Verify delegation impact: user1 VP=0 (false), user3 delegated VP = lock1 VP (true)
- Verify balanceAtEpochEnd for both user1 and user3
- Negative tests:
- user1 cannot switchDelegate lock1 (only 1 action remaining before E3 expiry)
- user1 cannot undelegate lock1
- non-cronJob cannot call update functions
- Positive tests: cronJob batch updates work correctly
- State transition test: user1 creates lock2

**3. StateE2_User1_CreatesLock2** (inherits StateE2_Lock1DelegationTakesEffect)

- setUp: user1 creates lock2 with long duration (e.g., E10), delegates to user3
- Note: createLock triggers internal state updates

**4. StateE2_User1_CreatesLock2_Test**

- Verify global state with 2 locks (veGlobal, TOTAL_LOCKED_*)
- Verify user3 delegated state aggregates both locks
- Verify totalSupplyAt[E1] unchanged (already finalized)
- Verify both locks VP at epoch end via balanceAtEpochEnd
- Verify getSpecificDelegatedBalanceAtEpochEnd for user1->user3 pair
- Test getLockVotingPowerAt for both locks

**5. StateE2_User1_IncreaseDuration_Lock2** (inherits StateE2_User1_CreatesLock2)

- setUp: user1 calls increaseDuration on lock2 (extend to E12)

**6. StateE2_User1_IncreaseDuration_Lock2_Test**

- Verify state changes via `verifyIncreaseDurationDelegated()`
- Verify slopeChanges shifted from oldExpiry to newExpiry
- Verify lock history checkpoint updated
- Negative tests:
- lock1 cannot increaseDuration (MIN_LOCK_DURATION from E3)
- cannot extend past MAX_LOCK_DURATION
- non-owner cannot increaseDuration
- Positive: duration extension correctly updates delegate VP

**7. StateE2_User1_IncreaseAmount_Lock2** (inherits StateE2_User1_IncreaseDuration_Lock2)

- setUp: user1 calls increaseAmount on lock2 (add MOCA + esMOCA)

**8. StateE2_User1_IncreaseAmount_Lock2_Test**

- Verify state changes via `verifyIncreaseAmountDelegated()`
- Verify TOTAL_LOCKED_MOCA/ESMOCA increased
- Verify delegate VP increased immediately
- Verify lock history checkpoint updated
- Negative tests:
- lock1 cannot increaseAmount (near expiry)
- zero amount reverts
- non-owner cannot increaseAmount
- Positive: amount increase correctly updates all states

**9. StateE2_User1_SwitchDelegate_Lock2** (inherits StateE2_User1_IncreaseAmount_Lock2)

- setUp: register user2 as delegate, then user1 switches lock2 from user3 to user2

**10. StateE2_User1_SwitchDelegate_Lock2_Test**

- Verify state via `verifySwitchDelegate()`
- Verify user3 delegated VP decreased by lock2
- Verify user2 delegated VP increased by lock2
- Verify user1->user3 pair pendingDeltas has subtraction
- Verify user1->user2 pair pendingDeltas has addition
- Verify numOfDelegateActionsPerEpoch incremented
- Negative tests:
- cannot switchDelegate lock1 (action limit)
- cannot switch to unregistered delegate
- cannot switch to self
- non-owner cannot switch
- Positive: switch correctly reallocates VP

**11. StateE2_User1_Undelegates_Lock2** (inherits StateE2_User1_SwitchDelegate_Lock2)

- setUp: user1 undelegates lock2

**12. StateE2_User1_Undelegates_Lock2_Test**

- Verify state via `verifyUndelegateLock()`
- Verify user1 has personal VP from lock2
- Verify user2 delegated VP = 0 (lock2 was their only delegation)
- Verify user3 delegated VP = lock1 only
- Verify lock2.delegate = address(0)
- Negative tests:
- cannot undelegate already undelegated lock
- non-owner cannot undelegate
- Verify totalSupplyAt unchanged (internal reallocation)

### Epoch 4 - Lock Expiry and New Delegations

**13. StateE4_User1_Unlocks_Lock1** (inherits StateE2_User1_Undelegates_Lock2)

- setUp: warp to E4 (past lock1 expiry at E3), user1 unlocks lock1

**14. StateE4_User1_Unlocks_Lock1_Test**

- Verify lock1 removed: lock.isUnlocked = true
- Verify user1 receives MOCA + esMOCA principals
- Verify user3 delegated VP = 0 (lock1 was expired anyway)
- Verify TOTAL_LOCKED_* decreased
- Verify global veGlobal reflects only lock2
- Verify totalSupplyAt[E2], totalSupplyAt[E3] finalized correctly
- Negative tests:
- cannot unlock non-expired lock (lock2)
- cannot unlock already unlocked lock
- non-owner cannot unlock
- Verify slopeChanges[E3 expiry] = 0 after unlock

**15. StateE4_User3_DelegateLock3_ToUser2** (inherits StateE4_User1_Unlocks_Lock1)

- setUp: user3 creates lock3 (long duration), delegates to user2

**16. StateE4_User3_DelegateLock3_ToUser2_Test**

- Verify user2 has delegated VP from lock3
- Verify user3 personal VP = 0, delegated lock3 to user2
- Verify global state includes lock2 + lock3
- Verify totalSupplyAt tracking correct across epoch transitions
- Test getSpecificDelegatedBalanceAtEpochEnd for user3->user2 pair
- Negative: user3 cannot delegate to unregistered address

**17. StateE4_User2_CreatesLock4** (inherits StateE4_User3_DelegateLock3_ToUser2)

- setUp: user2 creates personal (non-delegated) lock4

**18. StateE4_User2_CreatesLock4_Test**

- Verify user2 has personal VP (lock4) via balanceOfAt(user2, false)
- Verify user2 has delegated VP (lock3) via balanceOfAt(user2, true)
- Verify global state includes lock2 + lock3 + lock4
- Verify all users' balanceAtEpochEnd values
- Final comprehensive state verification across all active locks

## Key Test Patterns

Each test contract follows the pattern:

1. Capture state via `captureAllStates()` or `captureAllStatesPlusDelegates()`
2. Execute action with event expectations
3. Verify via appropriate `verify*()` helper from DelegateHelper

## Cleanup

Remove commented-out code blocks (lines 291-367, 372-477) after implementation.