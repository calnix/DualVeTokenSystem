# EscrowedMoca Test Flow Documentation

This document outlines the complete test flow for the EscrowedMoca contract, organized by state transitions. Each section represents a distinct contract state, with all tests performed in that state listed below.

---

## State 0: Initial Deployment (`StateT0_Deploy`)

**Setup:**
- Fresh deployment of EscrowedMoca contract

**Tests:**

### ✅ Constructor Tests
- `test_Constructor()` - Verifies all constructor parameters are set correctly (treasury address, wMoca, gas limits, penalty percentages, ERC20 metadata)

### ❌ Constructor Validation Tests
- `testRevert_ConstructorChecks()` - Tests all constructor parameter validations:
  - Zero address for globalAdmin
  - votersPenaltyPct > 100%
  - Invalid wMoca address
  - mocaTransferGasLimit < 2300

### ❌ Escrow Validation
- `testRevert_CannotEscrowZeroMoca_InvalidAmount()` - Cannot escrow 0 MOCA

### ✅ State Transition: Escrow MOCA
- `testCan_User_EscrowMoca()` - User successfully escrows native MOCA and receives esMOCA

---

## State 1: Users Have Escrowed MOCA (`StateT0_EscrowedMoca`)

**Setup:**
- User1 escrowed 100 ether MOCA
- User2 escrowed 200 ether MOCA
- User3 escrowed 300 ether MOCA

**Tests:**

### ❌ Escrow Validation
- `testRevert_EscrowedMoca_InvalidAmount()` - Cannot escrow 0 amount

### ❌ Admin Function Access Control
- `testRevert_UserCannot_SetRedemptionOptions()` - Only escrowedMocaAdmin can set redemption options

### ✅ State Transition: Set Redemption Options
- `testCan_EscrowedMocaAdmin_SetRedemptionOptions()` - Admin successfully sets redemption option

---

## State 2: Redemption Options Configured (`StateT0_RedemptionOptionsSet`)

**Setup:**
- Option 1: 30 days lock, 50% receivable (50% penalty)
- Option 2: 60 days lock, 100% receivable (0% penalty)
- Option 3: Instant, 20% receivable (80% penalty)

**Tests:**

### ❌ Redemption Option Validation Tests
- `testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidPercentage()` - Cannot set receivablePct > 100%
- `testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidPercentage_0()` - Cannot set 0% receivablePct
- `testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidLockDuration()` - Lock duration must be ≤ 888 days

### ❌ Claim Penalties When Empty
- `testRevert_CronJobCannot_ClaimPenalties_WhenZero()` - Cannot claim penalties when none exist

### ✅ State Transition: Select Redemption Options
- `test_User1Can_SelectRedemptionOption_30Days()` - User1 schedules partial redemption (50% of balance) with 30-day lock
- `test_User2Can_SelectRedemptionOption_60Days()` - User2 schedules full redemption with 60-day lock (no penalty)

---

## State 3: Users Have Scheduled Redemptions (`StateT0_UsersScheduleTheirRedemptions`)

**Setup:**
- User1 scheduled redemption: 50 ether with 30-day lock (50% penalty)
- User2 scheduled redemption: 200 ether with 60-day lock (0% penalty)

**Tests:**

### ❌ Select Redemption Option Validation Tests
- `testRevert_UserCannot_SelectRedemptionOption_WhenAmountsAreZero()` - Cannot redeem with 0 amounts (tests redemptionAmount=0, minExpectedReceivable=0, or both)
- `testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanBalance()` - Cannot redeem more than balance
- `testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanTotalSupply()` - Invariant check: redemption amount cannot exceed totalSupply
- `testRevert_UserCannot_SelectRedemptionOption_WhenRedemptionOptionIsDisabled()` - Cannot use disabled redemption option
- `testRevert_RedemptionOptionInput_DoesNotMatchOptionInStorage()` - Input expectedOption must match stored redemption option (lockDuration and receivablePct)

### ❌ Claim Redemptions Validation Tests
- `testRevert_User1Cannot_ClaimRedemptions_EmptyArray()` - Cannot claim with empty timestamp array
- `testRevert_User1Cannot_ClaimRedemptions_Before30Days()` - Cannot claim before lock period expires
- `testRevert_User3_NoRedemptionsScheduled_NothingToClaim()` - Cannot claim if no redemptions scheduled

### ✅ Instant Redemption Test
- `test_User3Can_SelectRedemptionOptionInstant_ReceivesMocaImmediately()` - User3 performs instant redemption (80% penalty) and receives MOCA immediately

### ✅ Multiple Redemptions Tests
- `test_User1Can_ClaimRedemptions_MultipleTimestamps()` - User1 schedules multiple redemptions at different times and claims them all together
- `test_User1Can_ClaimRedemptions_MultipleRedemptionsAtSameTimestamp()` - User1 schedules multiple redemptions at the same timestamp, verifies they aggregate, and claims them together

### ❌ Claim Penalties Access Control
- `testRevert_UserCannot_ClaimPenalties()` - Only cronJob can claim penalties

### ✅ Claim Penalties
- `test_CronJobCan_ClaimPenalties_AssetsSentToTreasury()` - CronJob successfully claims all accrued penalties to treasury

---

## State 4: T+30 Days - User1's Redemption Claimable (`StateT30Days_UserOneHasRedemptionScheduled_PenaltiesAreClaimed`)

**Setup:**
- Fast forward 30 days
- CronJob has claimed all penalties

**Tests:**

### ✅ Penalty State Verification
- `test_CronJobHas_ClaimedPenalties_AssetsWithTreasury()` - Confirms all penalties have been claimed and are with treasury

### ❌ Claim Penalties When None Available
- `test_CronJobCannot_ClaimPenalties_WhenZero()` - Cannot claim when no new penalties exist

### ❌ Release Escrowed MOCA Validation Tests
- `testRevert_UserCannot_ReleaseEscrowedMoca()` - Only assetManager can release escrowed MOCA
- `testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenZero()` - Cannot release 0 amount
- `testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenInsufficientBalance()` - Cannot release more than balance

### ✅ Release Escrowed MOCA
- `test_AssetManagerCan_ReleaseEscrowedMoca()` - AssetManager can convert esMOCA back to native MOCA

### ❌ Claim Redemptions Timing Tests
- `testRevert_User2Cannot_ClaimRedemptions_Before60Days()` - User2 cannot claim before 60-day lock expires
- `testRevert_User2Cannot_ClaimRedemptions_PassingFutureTimestamp()` - Cannot claim with future timestamp

### ✅ Claim Redemptions After Lock Period
- `test_User1Can_ClaimRedemptions_30Days()` - User1 successfully claims redemption after 30-day lock

### ❌ Escrow On Behalf Validation Tests
- `testRevert_UserCannot_EscrowMocaOnBehalf()` - Only cronJob can escrow on behalf
- `testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenMismatchedArrayLengths()` - User and amount arrays must match
- `testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenAmountIsZero()` - Cannot escrow 0 amount for any user
- `testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenUserIsZeroAddress()` - Cannot escrow for zero address
- `testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenMsgValueMismatch()` - msg.value must match total amount

### ✅ Escrow On Behalf
- `test_CronJobCan_EscrowMocaOnBehalf()` - CronJob successfully escrows MOCA for multiple users

---

## State 5: T+60 Days - User2's Redemption Claimable (`StateT60Days_UserTwoHasRedemptionScheduled`)

**Setup:**
- Fast forward another 30 days (60 days total)
- User2's 60-day redemption is now claimable

**Tests:**

### ✅ Claim Full Redemption (No Penalty)
- `test_User2Can_ClaimRedemptions_60Days()` - User2 claims full redemption with no penalty

### ❌ Penalty Configuration Access Control
- `test_UserCannot_SetPenaltyToVoters()` - Only escrowedMocaAdmin can set penalty split

### ✅ State Transition: Change Penalty Split
- `test_EscrowedMocaAdminCan_SetPenaltyToVoters()` - Admin changes votersPenaltyPct from 10% to 50%

---

## State 6: Penalty Split Changed to 50/50 (`StateT60Days_ChangePenaltySplit`)

**Setup:**
- VOTERS_PENALTY_PCT changed from 1000 (10%) to 5000 (50%)
- Penalties now split 50/50 between voters and treasury

**Tests:**

### ❌ Invalid Penalty Percentage
- `test_EscrowedMocaAdminCannot_SetInvalidVotersPenaltyPct_GreaterThan100()` - Cannot set penalty percentage > 100%

### ✅ Verify New Penalty Split
- `test_User1_CanRedeem_Quarter_WithOption1()` - User1 redeems with new 50/50 penalty split, verify correct distribution

### ❌ Disable Redemption Option Access Control
- `test_UserCannot_DisableRedemptionOption()` - Only escrowedMocaAdmin can disable redemption options

### ✅ State Transition: Disable Redemption Option
- `test_EscrowedMocaAdminCan_DisableRedemptionOption()` - Admin disables redemption option 1

### ❌ Gas Limit Configuration Tests
- `testRevert_UserCannot_SetMocaTransferGasLimit()` - Only escrowedMocaAdmin can set gas limit
- `testRevert_EscrowedMocaAdminCannot_SetMocaTransferGasLimit_BelowMinimum()` - Gas limit must be ≥ 2300

### ✅ Set Gas Limit
- `test_EscrowedMocaAdminCan_SetMocaTransferGasLimit()` - Admin sets new gas limit for MOCA transfers

---

## State 7: Redemption Option Disabled (`StateT60Days_DisableRedemptionOption`)

**Setup:**
- Redemption option 1 (30-day) is disabled

**Tests:**

### ❌ Use Disabled Redemption Option
- `testRevert_UserCannot_SelectRedemptionOption()` - Cannot select disabled redemption option
- `testRevert_EscrowedMocaAdminCannot_DisableRedemptionOptionAgain()` - Cannot disable already-disabled option

### ✅ State Transition: Enable Redemption Option
- `test_EscrowedMocaAdminCan_EnableRedemptionOption()` - Admin re-enables redemption option 1

---

## State 8: Redemption Option Re-enabled (`StateT60Days_EnableRedemptionOption`)

**Setup:**
- Redemption option 1 is re-enabled

**Tests:**

### ✅ Use Re-enabled Redemption Option
- `test_User1Can_SelectRedemptionOption1_30Days()` - User1 can now use previously disabled option

### ❌ Whitelist Access Control
- `testRevert_UserCannot_SetWhitelistStatus()` - Only escrowedMocaAdmin can set whitelist status

### ❌ Transfer Without Whitelist
- `testRevert_UserCannot_TransferEsMoca_NotWhitelisted()` - Non-whitelisted users cannot transfer esMOCA

### ✅ State Transition: Set Whitelist Status
- `test_EscrowedMocaAdminCan_SetWhitelistStatus()` - Admin whitelists user1

---

## State 9: User1 Whitelisted (`StateT60Days_SetWhitelistStatus`)

**Setup:**
- User1 is whitelisted for esMOCA transfers
- User1 has scheduled a small redemption (10% of balance) for penalty testing

**Tests:**

### ❌ Whitelist Validation Tests
- `testRevert_EscrowedMocaAdminCannot_SetWhitelistStatus_ZeroAddress()` - Cannot whitelist zero address
- `testRevert_EscrowedMocaAdminCannot_SetWhitelistStatus_WhitelistStatusUnchanged()` - Cannot set same whitelist status twice

### ✅ Remove From Whitelist
- `test_EscrowedMocaAdminCan_SetWhitelistStatus_ToFalse()` - Admin removes user1 from whitelist

### ✅ Whitelisted Transfer Tests
- `test_User1Can_TransferEsMocaToUser2()` - Whitelisted user1 can transfer esMOCA to user2

### ❌ TransferFrom Access Control
- `testRevert_User2_CannotCallTransferFromEsMoca_NotWhitelisted()` - Non-whitelisted user cannot call transferFrom

### ✅ Whitelisted TransferFrom
- `test_User1Can_TransferFromEsMocaToUser2_Whitelisted()` - Whitelisted user can use transferFrom with approval

### ❌ Pause Access Control
- `testRevert_UserCannot_Pause()` - Only monitor can pause

### ❌ Freeze Before Pause
- `testRevert_GlobalAdminCannot_Freeze_WhenContractIsNotPaused()` - Cannot freeze unpaused contract

### ✅ State Transition: Pause Contract
- `test_MonitorCan_Pause()` - Monitor successfully pauses contract

---

## State 10: Contract Paused (`StateT60Days_Paused`)

**Setup:**
- Contract is paused by monitor

**Tests:**

### ❌ Cannot Pause When Already Paused
- `testRevert_MonitorCannot_Pause_WhenContractIsPaused()` - Cannot pause already-paused contract

### ✅ Functions That Work When Paused
- `test_User1WhoIsWhitelistedCan_Transfer_WhenPaused()` - Whitelisted users can still transfer when paused
- `test_User1WhoIsWhitelistedCan_TransferFrom_WhenPaused()` - Whitelisted users can still transferFrom when paused
- `test_CronJobCan_ClaimPenalities_WhenPaused()` - CronJob can claim penalties when paused
- `test_EscrowedMocaAdminCan_SetMocaTransferGasLimit_WhenPaused()` - Admin can set gas limit when paused
- `test_EscrowedMocaAdminCan_SetWhitelistStatus_WhenPaused()` - Admin can set whitelist status when paused

### ❌ User Functions Blocked When Paused
- `testRevert_UserCannot_EscrowMoca_WhenPaused()`
- `testRevert_UserCannot_SelectRedemptionOption_WhenPaused()`
- `testRevert_UserCannot_ClaimRedemptions_WhenPaused()`

### ❌ CronJob Functions Blocked When Paused
- `testRevert_AssetManagerCannot_EscrowMocaOnBehalf_WhenPaused()`

### ❌ AssetManager Functions Blocked When Paused
- `testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenPaused()`

### ❌ Admin Functions Blocked When Paused
- `testRevert_EscrowedMocaAdminCannot_SetVotersPenaltyPct_WhenPaused()`
- `testRevert_EscrowedMocaAdminCannot_SetRedemptionOption_WhenPaused()`
- `testRevert_EscrowedMocaAdminCannot_SetRedemptionOptionStatus_WhenPaused()`

### ❌ Emergency Exit Only When Frozen
- `testRevert_EmergencyExitHandlerCannot_EmergencyExit_WhenNotFrozen()` - Can only call when frozen

### ❌ Unpause Access Control
- `test_MonitorCannot_Unpause()` - Only globalAdmin can unpause
- `testRevert_MonitorCannot_PauseAgain()` - Monitor cannot pause again

### ✅ Unpause
- `test_GlobalAdminCan_Unpause()` - GlobalAdmin can unpause contract

### ✅ State Transition: Freeze Contract
- `test_GlobalAdminCan_Freeze()` - GlobalAdmin freezes the contract

---

## State 11: Contract Frozen (`StateT60Days_Frozen`)

**Setup:**
- Contract is frozen (permanent state)
- Cannot be unpaused or unfrozen

**Tests:**

### ❌ Cannot Unpause/Freeze When Frozen
- `testRevert_GlobalAdminCannot_Unpause_WhenContractIsFrozen()` - Cannot unpause frozen contract
- `testRevert_GlobalAdminCannot_Freeze_WhenContractIsFrozen()` - Cannot freeze already-frozen contract

### ❌ Emergency Exit Validation Tests
- `testRevert_EmergencyExit_EmptyArray()` - Cannot emergency exit with empty user array
- `testRevert_EmergencyExit_NeitherEmergencyExitHandlerNorUser()` - Only emergencyExitHandler or the user themselves can call
- `testRevert_UserCannot_EmergencyExit_MultipleUsers()` - User can only exit themselves (array length must be 1)

### ✅ User Self Emergency Exit
- `test_UserCan_EmergencyExit_Themselves()` - User1 can emergency exit their own position

### ✅ Handler Emergency Exit Multiple Users
- `test_EmergencyExitHandlerCan_EmergencyExit_MultipleUsers()` - EmergencyExitHandler exits multiple users at once

### ✅ Emergency Exit With Pending Redemptions
- `test_EmergencyExitHandlerCan_EmergencyExit_WithPendingRedemptions()` - Emergency exit includes both esMOCA balance and pending redemptions

### ✅ Claim Penalties When Frozen
- `test_CronJobCan_ClaimPenalties()` - CronJob can claim accrued penalties even when frozen

---

## Alternative Branch: All Penalties to Treasury (`AllPenaltiesToTreasury`)

**Setup:**
- Inherits from `StateT60Days_UserTwoHasRedemptionScheduled`
- VOTERS_PENALTY_PCT set to 0 (100% of penalties go to treasury)

**Tests:**

### ✅ Verify 100% Treasury Penalty Split
- `test_User1_CanRedeem_Quarter_WithOption1()` - User1 redeems and verifies all penalties go to treasury (0% to voters)

---

## Test Summary Statistics

- **Total Test States:** 12 main states + 1 alternative branch
- **Total Test Functions:** ~90+ individual test cases
- **Test Coverage:**
  - Constructor validation
  - Access control for all privileged functions
  - State transitions
  - Edge cases and boundary conditions
  - Redemption options (instant, delayed, no penalty)
  - Penalty distribution mechanisms
  - Whitelist and transfer restrictions
  - Pause/unpause/freeze mechanisms
  - Emergency exit procedures
  - Multi-user scenarios
  - Functions callable when paused vs blocked
  - Multiple redemptions at same timestamp (aggregation)
  - Redemption option parameter validation (expectedOption matching)
