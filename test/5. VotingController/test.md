# VotingController Test Suite

## Overview

Comprehensive testing suite for `VotingController.sol` covering all functionality including voting, delegation, reward/subsidy claims, epoch lifecycle management, admin setters, risk management, and multi-actor scenarios.

## Test Files

### Mocks (`mocks/`)

| File | Description |
|------|-------------|
| `MockPaymentsControllerVC.sol` | Standalone `IPaymentsController` implementation with setters for mocked verifier/pool accrued subsidies |
| `MockEscrowedMocaVC.sol` | Standalone `IEscrowedMoca` + `IERC20` implementation with `mintForTesting` helper for direct token minting |
| `MockVotingEscrowMocaVC.sol` | Standalone `IVotingEscrowMoca` implementation with setters for mocked voting power balances |
| `MockWMoca.sol` | Simple payable fallback contract for native MOCA token |
| `MockUSD8.sol` | Simple ERC20 mock for USD8 token |

### Base Harness

| File | Description |
|------|-------------|
| `VotingControllerHarness.sol` | Base test harness that deploys VotingController with mocked contracts, provides epoch math helpers, state snapshots, and utility functions |

### Unit Tests

| File | Coverage Area | Key Test Cases |
|------|---------------|----------------|
| `VotingController_ConstructorAndRoles.t.sol` | Constructor, roles, access control | Immutable/mutable address validation, parameter bounds, role hierarchy, initial epoch state |
| `VotingController_Pools.t.sol` | Pool creation/removal | createPools (1-10 count), removePools, active pool tracking, epoch state requirements |
| `VotingController_Voting.t.sol` | vote(), migrateVotes() | Personal/delegated voting, multi-pool votes, vote migration, insufficient votes, inactive pools |
| `VotingController_Delegation.t.sol` | Delegate lifecycle | Registration, fee updates (immediate decrease, delayed increase), unregistration, historical fee tracking |
| `VotingController_ClaimsRewards.t.sol` | Reward claims | Personal rewards, delegated rewards, delegate fees, pro-rata distribution, double-claim prevention |
| `VotingController_ClaimsSubsidies.t.sol` | Subsidy claims | Verifier claims, blocked verifiers, accrued ratio calculations, multiple verifiers per pool |
| `VotingController_EpochLifecycle.t.sol` | Epoch state machine | endEpoch, processVerifierChecks, processRewardsAndSubsidies, finalizeEpoch, forceFinalizeEpoch |
| `VotingController_Withdrawals.t.sol` | Unclaimed withdrawals | withdrawUnclaimedRewards, withdrawUnclaimedSubsidies, withdrawRegistrationFees, delay enforcement |
| `VotingController_AdminSetters.t.sol` | Admin configuration | setVotingControllerTreasury, setDelegateRegistrationFee, setMaxDelegateFeePct, setFeeIncreaseDelayEpochs, setUnclaimedDelay, setMocaTransferGasLimit |
| `VotingController_RiskAndPause.t.sol` | Risk management | pause, unpause, freeze, emergencyExit, paused state blocking |
| `VotingController_Views.t.sol` | View functions | viewClaimablePersonalRewards, viewClaimableDelegationRewards (with fee changes across epochs, multiple delegators pro-rata, multiple pools), viewClaimableSubsidies, delegateHistoricalFeePcts tracking |

### Integration/Scenario Tests

| File | Description |
|------|-------------|
| `VotingController_AllActors_MultiEpoch.t.sol` | Multi-epoch scenarios with all actors (verifiers, personal voters, delegators, delegates) |

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

## Epoch State Transitions Tested

```
Voting → Ended → Verified → Processed → Finalized
                                     ↓
                              ForceFinalized
```

## Error Coverage

All errors from `Errors.sol` related to VotingController are tested:

- `InvalidAddress`, `InvalidAmount`, `InvalidArray`, `MismatchedArrayLengths`
- `InvalidPercentage`, `InvalidDelayPeriod`, `InvalidGasLimit`
- `InvalidEpochState`, `EpochNotFinalized`, `EpochNotProcessed`, `EpochAlreadyFinalized`, `EpochNotOver`
- `NoAvailableVotes`, `ZeroVotes`, `InsufficientVotes`
- `PoolNotActive`, `InvalidPoolPair`, `PoolHasNoRewards`, `PoolHasNoSubsidies`, `PoolAlreadyProcessed`
- `AlreadyClaimed`, `NoRewardsToClaim`, `NoSubsidiesToClaim`
- `ZeroDelegatedVP`, `ZeroDelegatePoolRewards`, `ZeroUserGrossRewards`
- `DelegateAlreadyRegistered`, `NotRegisteredAsDelegate`, `CannotUnregisterWithActiveVotes`
- `ClaimsBlocked`, `VerifierAccruedSubsidiesGreaterThanPool`
- `EndOfEpochOpsUnderway`, `EpochNotVerified`
- `CanOnlyWithdrawUnclaimedAfterDelay`, `RewardsAlreadyWithdrawn`, `SubsidiesAlreadyWithdrawn`
- `NoUnclaimedRewardsToWithdraw`, `NoUnclaimedSubsidiesToWithdraw`, `NoRegistrationFeesToWithdraw`
- `IsFrozen`, `NotFrozen`

## Event Coverage

All events from `Events.sol` related to VotingController are verified:

- Pool events: `PoolsCreated`, `PoolsRemoved`
- Voting events: `Voted`, `VotesMigrated`
- Delegate events: `DelegateRegistered`, `DelegateUnregistered`, `DelegateFeeDecreased`, `DelegateFeeIncreased`, `DelegateFeeApplied`
- Claim events: `RewardsClaimed`, `DelegationRewardsClaimed`, `DelegationFeesClaimed`, `SubsidiesClaimed`
- Epoch events: `EpochEnded`, `EpochVerified`, `PoolsProcessed`, `EpochFullyProcessed`, `EpochAllocationsSet`, `EpochAssetsDeposited`, `EpochFinalized`, `EpochForceFinalized`, `VerifiersClaimsBlocked`
- Withdrawal events: `UnclaimedRewardsWithdrawn`, `UnclaimedSubsidiesWithdrawn`, `RegistrationFeesWithdrawn`
- Admin events: `VotingControllerTreasuryUpdated`, `DelegateRegistrationFeeUpdated`, `MaxDelegateFeePctUpdated`, `FeeIncreaseDelayEpochsUpdated`, `UnclaimedDelayUpdated`, `MocaTransferGasLimitUpdated`
- Risk events: `ContractFrozen`, `EmergencyExit`

## Running Tests

```bash
# Run all VotingController tests
forge test --match-path "test/5. VotingController/*.t.sol" -vv

# Run specific test file
forge test --match-path "test/5. VotingController/VotingController_Voting.t.sol" -vvv

# Run with coverage
forge coverage --match-path "test/5. VotingController/*.t.sol"

# Run gas snapshot
forge snapshot --match-path "test/5. VotingController/*.t.sol"
```

## Test Dependencies

- **Mocked External Contracts**: Tests use mock versions of `PaymentsController`, `EscrowedMoca`, and `VotingEscrowMoca`
- **Epoch Time**: Tests use `vm.warp()` to manipulate block.timestamp for epoch transitions
- **Role Setup**: All required roles are granted in the harness setUp()

## Actor Types

| Actor Type | Description | Key Operations |
|------------|-------------|----------------|
| Personal Voter | Uses personal voting power | vote(), migrateVotes(), claimPersonalRewards() |
| Delegate | Registered delegate with fee | registerAsDelegate(), vote(isDelegated=true), claimDelegationFees() |
| Delegator | Delegates voting power | claimDelegatedRewards() |
| Verifier | Claims subsidies | claimSubsidies() (via asset manager) |
| Admin | VotingController admin | createPools(), removePools(), setter functions |
| CronJob | Epoch operations | endEpoch(), processVerifierChecks(), processRewardsAndSubsidies(), finalizeEpoch() |
| AssetManager | Withdrawal operations | withdrawUnclaimedRewards(), withdrawUnclaimedSubsidies(), withdrawRegistrationFees() |
| Monitor | Risk operations | pause() |
| GlobalAdmin | Emergency operations | unpause(), freeze(), forceFinalizeEpoch() |
| EmergencyExitHandler | Emergency exit | emergencyExit() |

