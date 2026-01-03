# VotingController Test Suite [w/ Mocks]

Comprehensive testing suite for `VotingController.sol` covering all functionality including voting, delegation, reward/subsidy claims, epoch lifecycle management, admin setters, risk management, and multi-actor scenarios.

Tests use mock versions of `PaymentsController`, `EscrowedMoca`, and `VotingEscrowMoca`.

## Epoch State Transitions Tested

```
Voting → Ended → Verified → Processed → Finalized
                                     ↓
                              ForceFinalized
```

## Actor Types

| Actor Type           | Description                     | Key Operations                                                                        |
|----------------------|---------------------------------|----------------------------------------------------------------------------------------|
| Personal Voter       | Uses personal voting power      | vote(), migrateVotes(), claimPersonalRewards()                                         |
| Delegate             | Registered delegate with fee    | registerAsDelegate(), vote(isDelegated=true), claimDelegationFees()                    |
| Delegator            | Delegates voting power          | claimDelegatedRewards()                                                                |
| Verifier             | Claims subsidies                | claimSubsidies() (via asset manager)                                                  |
| Admin                | VotingController admin          | createPools(), removePools(), setter functions                                         |
| CronJob              | Epoch operations                | endEpoch(), processVerifierChecks(), processRewardsAndSubsidies(), finalizeEpoch()     |
| AssetManager         | Withdrawal operations           | withdrawUnclaimedRewards(), withdrawUnclaimedSubsidies(), withdrawRegistrationFees()   |
| Monitor              | Risk operations                 | pause()                                                                                |
| GlobalAdmin          | Emergency operations            | unpause(), freeze(), forceFinalizeEpoch()                                              |
| EmergencyExitHandler | Emergency exit                  | emergencyExit()                                                                        |

## Test Files

### Test harness & Mocks 

`VotingControllerHarness.sol` 
- base test harness that deploys VotingController with mocked contracts 
- provides epoch math helpers, state snapshots, and utility functions

| Mocks                            | Description                                                                                                  |
|----------------------------------|--------------------------------------------------------------------------------------------------------------|
| `MockPaymentsControllerVC.sol`   | Standalone `IPaymentsController` implementation with setters for mocked verifier/pool accrued subsidies      |
| `MockEscrowedMocaVC.sol`         | Standalone `IEscrowedMoca` + `IERC20` implementation with `mintForTesting` helper for direct token minting   |
| `MockVotingEscrowMocaVC.sol`     | Standalone `IVotingEscrowMoca` implementation with setters for mocked voting power balances                  |
| `MockWMoca.sol`                  | Simple payable fallback contract for native MOCA token                                                       |
| `MockUSD8.sol`                   | Simple ERC20 mock for USD8 token                                                                             |


## Unit Tests
## 📋 Quick Look: Unit Test File Coverage

| Test File                                        | Major Areas Covered                | Example Key Scenarios (see below)              |
|--------------------------------------------------|------------------------------------|------------------------------------------------|
| **VotingController_ConstructorAndRoles.t.sol**   | Constructor, Roles, Access Control  | Address validation, Roles, Initial Epoch State  |
| **VotingController_Pools.t.sol**                 | Pool creation/removal               | Create/remove pools, Active pool tracking, Epoch requirements |
| **VotingController_Voting.t.sol**                | Voting, Vote Migration              | Personal/delegated voting, Multi-pool, Migration, Edge cases |
| **VotingController_Delegation.t.sol**            | Delegate lifecycle                  | Registration, Fees, Unregistration, History     |
| **VotingController_ClaimsRewards.t.sol**         | Reward Claims                       | Personal/Delegated, Delegate Fees, Pro-rata     |
| **VotingController_ClaimsSubsidies.t.sol**       | Subsidy Claims                      | Verifier/blocking, Accrued ratio, Multiples     |
| **VotingController_EpochLifecycle.t.sol**        | Epoch state transitions             | End/process/finalize/force finalization         |
| **VotingController_Withdrawals.t.sol**           | Withdrawals (Unclaimed, Fees)       | Unclaimed rewards/subsidies, Delay logic        |
| **VotingController_AdminSetters.t.sol**          | Admin configuration                 | Param setters for treasury, fee pct, delays     |
| **VotingController_RiskAndPause.t.sol**          | Risk/Pause/Emergency                | pause/unpause/freeze, exit, blocked contract    |
| **VotingController_Views.t.sol**                 | View/Read Functions                 | All claim views, historical tracking            |
| **VotingController_AllActors_MultiEpoch.t.sol**  | Full Multi-Actor, Multi-Epoch       | Full, mixed scenarios across epochs             |

---

**VotingController_ConstructorAndRoles.t.sol**
- *Coverage Area*: Constructor, roles, access control
- *Key Test Cases*:
   - Immutable/mutable address validation
   - Parameter bounds
   - Role hierarchy
   - Initial epoch state

**VotingController_Pools.t.sol**
- *Coverage Area*: Pool creation/removal
- *Key Test Cases*:
   - createPools (1-10 count)
   - removePools
   - Active pool tracking
   - Epoch state requirements

**VotingController_Voting.t.sol**
- *Coverage Area*: vote(), migrateVotes()
- *Key Test Cases*:
   - Personal/delegated voting
   - Multi-pool votes
   - Vote migration
   - Insufficient votes
   - Inactive pools

**VotingController_Delegation.t.sol**
- *Coverage Area*: Delegate lifecycle
- *Key Test Cases*:
   - Registration
   - Fee updates (immediate decrease, delayed increase)
   - Unregistration
   - Historical fee tracking

**VotingController_ClaimsRewards.t.sol**
- *Coverage Area*: Reward claims
- *Key Test Cases*:
   - Personal rewards
   - Delegated rewards
   - Delegate fees
   - Pro-rata distribution
   - Double-claim prevention

**VotingController_ClaimsSubsidies.t.sol**
- *Coverage Area*: Subsidy claims
- *Key Test Cases*:
   - Verifier claims
   - Blocked verifiers
   - Accrued ratio calculations
   - Multiple verifiers per pool

**VotingController_EpochLifecycle.t.sol**
- *Coverage Area*: Epoch state machine
- *Key Test Cases*:
   - endEpoch
   - processVerifierChecks
   - processRewardsAndSubsidies
   - finalizeEpoch
   - forceFinalizeEpoch

**VotingController_Withdrawals.t.sol**
- *Coverage Area*: Unclaimed withdrawals
- *Key Test Cases*:
   - withdrawUnclaimedRewards
   - withdrawUnclaimedSubsidies
   - withdrawRegistrationFees
   - Delay enforcement

**VotingController_AdminSetters.t.sol**
- *Coverage Area*: Admin configuration
- *Key Test Cases*:
   - setVotingControllerTreasury
   - setDelegateRegistrationFee
   - setMaxDelegateFeePct
   - setFeeIncreaseDelayEpochs
   - setUnclaimedDelay
   - setMocaTransferGasLimit

**VotingController_RiskAndPause.t.sol**
- *Coverage Area*: Risk management
- *Key Test Cases*:
   - pause
   - unpause
   - freeze
   - emergencyExit
   - paused state blocking

**VotingController_Views.t.sol**
- *Coverage Area*: View functions
- *Key Test Cases*:
   - viewClaimablePersonalRewards
   - viewClaimableDelegationRewards (with fee changes across epochs, multiple delegators pro-rata, multiple pools)
   - viewClaimableSubsidies
   - delegateHistoricalFeePcts tracking

**VotingController_AllActors_MultiEpoch.t.sol** 
- Multi-epoch scenarios with all actors at once (verifiers, personal voters, delegators, delegates)

## Test Scenarios

### Scenario Coverage in AllActors Tests

1. **BasicMultiActor_SingleEpoch**: All actor types participate in a single epoch with mixed rewards/subsidies. **Includes EXACT amount verification** for:
   - Personal voter rewards with pro-rata math validation
   - Delegator net rewards after fee deduction
   - Delegate fees collected
   - Verifier subsidy claims with accrued ratio calculations
   - Epoch and global counter verification
2. **MultiEpoch_DelegateFeeChanges**: Delegate fee increase scheduling and application across epochs. **Verifies fee application to actual payouts** in the post-delay epoch with exact net/fee amounts.
3. **ZeroRewardsSubsidies_Combinations**: Pools with zero/non-zero reward and subsidy combinations
4. **BlockedVerifiers_MixedPools**: Verifier blocking during epoch finalization
5. **FullLifecycle_ThreeEpochs**: Complete flow across 3 epochs including delegate unregistration and force finalization
6. **VoteMigration_MultipleActors**: Vote migration mid-epoch for both personal and delegated votes
7. **UnclaimedWithdrawals_AfterDelay**: Unclaimed reward/subsidy withdrawal after delay period




> cmd

```bash
# Run all VotingController tests
forge test --match-path "test/5. VotingController/*.t.sol" -vv

# Run specific test file
forge test --match-path "test/5. VotingController/VotingController_Voting.t.sol" -vvv

# Run with coverage
forge coverage --match-path "test/5. VotingController/*.t.sol"
```