# MOCA Validator Protocol: Privileged Functions & Execution Flows

## Table of Contents
1. [Initial Deployment Process](#1-initial-deployment-process)
2. [Asset Flows](#2-asset-flows)
3. [Risk Management Processes](#3-risk-management-processes)
4. [Contract-Specific Operations](#4-contract-specific-operations)
5. [Redeployment & Migration](#5-redeployment--migration)
6. [Out-of-Sync Scenarios](#6-out-of-sync-scenarios)
7. [Emergency Procedures](#7-emergency-procedures)

---

## 1. Initial Deployment Process

### 1.1 Deployment Order & Dependencies

```
1. Deploy IssuerStakingController
   ↓
2. Deploy PaymentsController
   ↓
3. Deploy EscrowedMoca
   ↓
4. Deploy VotingEscrowMoca
   ↓
5. Deploy VotingController (references VotingEscrowMoca, PaymentsController, EscrowedMoca)
   ↓
6. Post-Deployment Configuration (see Section 1.4)
```

**Roles are granted at deployment via constructor params**


### 1.2 Deployment Architecture

Each contract is self-contained with its own role management:
- No central AddressBook or AccessController
- Roles assigned via constructor params
- Each contract uses OpenZeppelin AccessControlEnumerable
- Immutable contract references set at deployment

### 1.3 Core Contract Deployment

**IssuerStakingController:**
```solidity
IssuerStakingController isc = new IssuerStakingController(
    globalAdmin,
    issuerStakingControllerAdmin,
    monitorAdmin,
    monitorBot,
    emergencyExitHandler,
    unstakeDelay,              // e.g., 14 days
    maxSingleStakeAmount,      // e.g., 1_000_000e18
    wMoca,
    mocaTransferGasLimit       // e.g., 10000
);
```

**PaymentsController:**
```solidity
PaymentsController pc = new PaymentsController(
    globalAdmin,
    paymentsControllerAdmin,
    monitorAdmin,
    cronJobAdmin,
    monitorBot,
    paymentsControllerTreasury,
    emergencyExitHandler,
    protocolFeePercentage,     // e.g., 500 (5%)
    voterFeePercentage,        // e.g., 1000 (10%)
    delayPeriod,               // e.g., 14 days (must be epoch-aligned)
    wMoca,
    usd8,
    mocaTransferGasLimit,      // e.g., 10000
    "PaymentsController",      // EIP712 name
    "1"                        // EIP712 version
);
```

**EscrowedMoca:**
```solidity
EscrowedMoca esMoca = new EscrowedMoca(
    globalAdmin,
    escrowedMocaAdmin,
    monitorAdmin,
    cronJobAdmin,
    monitorBot,
    escrowedMocaTreasury,
    emergencyExitHandler,
    assetManager,
    votersPenaltyPct,          // e.g., 5000 (50%)
    wMoca,
    mocaTransferGasLimit       // e.g., 10000
);
```

**VotingEscrowMoca:**
```solidity
VotingEscrowMoca veMoca = new VotingEscrowMoca(
    wMoca,
    esMoca,
    mocaTransferGasLimit,      // e.g., 10000
    globalAdmin,
    votingEscrowMocaAdmin,
    monitorAdmin,
    cronJobAdmin,
    monitorBot,
    emergencyExitHandler
);
```

**VotingController:**
```solidity
VotingController vc = new VotingController(
    DataTypes.VCContractAddresses({
        wMoca: wMoca,
        esMoca: esMoca,
        veMoca: veMoca,
        paymentsController: paymentsController,
        votingControllerTreasury: treasury
    }),
    DataTypes.VCRoleAddresses({
        globalAdmin: globalAdmin,
        votingControllerAdmin: vcAdmin,
        monitorAdmin: monitorAdmin,
        cronJobAdmin: cronJobAdmin,
        monitorBot: monitorBot,
        emergencyExitHandler: emergencyExitHandler,
        assetManager: assetManager
    }),
    DataTypes.VCParams({
        delegateRegistrationFee: 1000e18,
        maxDelegateFeePct: 2000,       // 20%
        feeDelayEpochs: 1,
        unclaimedDelayEpochs: 6,
        mocaTransferGasLimit: 10000
    })
);
```

### 1.4 Post-Deployment Configuration

**IssuerStakingController:**
```solidity
// No post-deployment configuration required
// Contract is fully functional after deployment
```

**PaymentsController:**
```solidity
// Set subsidy tiers (by PAYMENTS_CONTROLLER_ADMIN_ROLE)
pc.setVerifierSubsidyTiers(
    [1000e18, 5000e18, 10000e18],     // MOCA thresholds
    [500, 1000, 1500]                  // Subsidy percentages (5%, 10%, 15%)
);
```

**EscrowedMoca:**
```solidity
// Set redemption options (by ESCROWED_MOCA_ADMIN_ROLE)
esMoca.setRedemptionOption(0, 0, 10000);        // Instant: 100% return
esMoca.setRedemptionOption(1, 30 days, 5000);   // 30-day: 50% return
esMoca.setRedemptionOption(2, 90 days, 7500);   // 90-day: 75% return

// Whitelist VotingController for esMOCA transfers
esMoca.setWhitelistStatus(address(vc), true);
```

**VotingEscrowMoca:**
```solidity
// Set VotingController reference (by VOTING_ESCROW_MOCA_ADMIN_ROLE)
veMoca.setVotingController(address(vc));
```

**VotingController:**
```solidity
// Create initial pools (by VOTING_CONTROLLER_ADMIN_ROLE)
vc.createPools(10);  // Creates pools 1-10
```

**PaymentsController (after VotingController pools created):**
```solidity
// Whitelist pools for subsidy tracking (by PAYMENTS_CONTROLLER_ADMIN_ROLE)
// Must match poolIds created in VotingController
for (uint128 poolId = 1; poolId <= 10; poolId++) {
    pc.whitelistPool(poolId, true);
}
```

---

## 2. Asset Flows

### 2.1 Deposit Flows

#### MOCA Token Deposits

**Lock Creation (User → VotingEscrowMoca):**
```
1. User sends native MOCA with tx (and/or approves esMOCA)
2. User calls createLock(expiry, esMocaAmount) with msg.value for MOCA
3. Contract:
   - Accepts native MOCA / transfers esMOCA from user
   - Creates lock record with unique lockId
   - Updates user's voting power (veMOCA)
   - Updates global accounting
```

**Verifier Staking (Verifier → PaymentsController):**
```
1. Verifier sends native MOCA with tx
2. Verifier calls stakeMoca() with msg.value
3. Contract:
   - Accepts native MOCA
   - Updates verifier's staked balance
   - Updates subsidy tier eligibility
```
*Optional: if verifier wants subsidies*

#### USD8 Deposits

**Verifier Balance (Verifier → PaymentsController):**
```
1. Verifier approves USD8 to PaymentsController
2. Verifier calls depositBalance(amount)
3. Contract:
   - Transfers USD8 from verifier
   - Updates verifier's currentBalance
```
*Mandatory: else verifier cannot process verifications*

### 2.2 Withdrawal Flows

#### Principal Returns

**Lock Unlock (VotingEscrowMoca → User):**
```
1. User calls unlock(lockId) after expiry
2. Contract:
   - Verifies lock expired and not already unlocked
   - Returns MOCA (native) and/or esMOCA to user
   - Marks lock as unlocked
   - Updates global accounting
```

**Emergency Exit (VotingEscrowMoca → Users):**
```
1. EmergencyExitHandler calls emergencyExit(lockIds[])
2. Contract (must be frozen):
   - Returns MOCA/esMOCA principals to lock owners
   - Ignores expiry checks
   - No state updates beyond transfer
```

#### Fee/Reward Claims

**Issuer Fee Claims (PaymentsController → Issuer):**
```
1. Issuer's assetManager calls claimFees()
2. Contract:
   - Calculates unclaimed net fees
   - Transfers USD8 to issuer's assetManager
   - Updates totalClaimed amount
```

**Personal Reward Claims (VotingController → User):**
```
1. User calls claimPersonalRewards(epoch, poolIds[])
2. Contract:
   - Verifies epoch is Finalized
   - Calculates pro-rata rewards per pool
   - Transfers esMOCA to user
   - Updates claimed amounts
```

**Delegated Reward Claims (VotingController → User):**
```
1. User calls claimDelegatedRewards(epoch, delegateList[], poolIds[][])
2. Contract:
   - Verifies epoch is Finalized
   - Calculates net rewards (gross - delegate fees)
   - Transfers esMOCA to user
```

**Delegation Fee Claims (VotingController → Delegate):**
```
1. Delegate calls claimDelegationFees(epoch, delegators[], poolIds[][])
2. Contract:
   - Verifies epoch is Finalized
   - Calculates fees based on historical fee rate
   - Transfers esMOCA to delegate
```

**Subsidy Claims (VotingController → Verifier):**
```
1. Verifier's assetManager calls claimSubsidies(epoch, verifier, poolIds[])
2. Contract:
   - Verifies epoch is Finalized and verifier not blocked
   - Gets subsidy ratio from PaymentsController
   - Calculates claimable subsidies: (verifierAccrued/poolAccrued) × poolAllocated
   - Transfers esMOCA to verifier's assetManager
```

### 2.3 CronJob Operations

**Protocol Fee Withdrawal (PaymentsController):**
```
1. CronJob calls withdrawProtocolFees(epoch)
2. Contract:
   - Verifies epoch ended
   - Transfers USD8 to PAYMENTS_CONTROLLER_TREASURY
   - Marks as withdrawn
```

**Voter Fee Withdrawal (PaymentsController):**
```
1. CronJob calls withdrawVotersFees(epoch)
2. Contract:
   - Verifies epoch ended
   - Transfers USD8 to PAYMENTS_CONTROLLER_TREASURY
   - Marks as withdrawn
```

### 2.4 Asset Manager Operations

**Unclaimed Asset Sweeps (VotingController):**
```
1. AssetManager waits for UNCLAIMED_DELAY_EPOCHS to pass
2. Calls withdrawUnclaimedRewards(epoch) or withdrawUnclaimedSubsidies(epoch)
3. Contract:
   - Verifies delay passed and epoch finalized
   - Transfers unclaimed esMOCA to VOTING_CONTROLLER_TREASURY
   - Sets totalRewardsWithdrawn / totalSubsidiesWithdrawn to block future claims
```

**Registration Fee Withdrawal (VotingController):**
```
1. AssetManager calls withdrawRegistrationFees()
2. Contract:
   - Calculates unclaimed registration fees
   - Transfers native MOCA (or wMOCA) to VOTING_CONTROLLER_TREASURY
```

---

## 3. Risk Management Processes

### 3.1 Pause Mechanism

**Monitor-Initiated Pause:**
```
1. Monitor detects anomaly
2. Monitor calls pause() on affected contract
3. Contract:
   - Sets paused state
   - Blocks all non-admin functions
   - Emits Paused event
```

**Admin Unpause:**
```
1. Global Admin reviews situation
2. Global Admin calls unpause()
3. Contract:
   - Clears paused state
   - Re-enables functions
   - Emits Unpaused event
```

### 3.2 Freeze Process

**Permanent Freeze:**
```
1. Contract must be paused first
2. Global Admin calls freeze()
3. Contract:
   - Sets isFrozen = 1
   - Permanently disables operations
   - Enables emergency exit
   - Emits ContractFrozen event
```

### 3.3 Protocol-wide Emergency Exit Procedures

**Full Protocol Emergency Exit:**
```
Phase 1: Freeze All Contracts
1. Pause all contracts (MONITOR_ROLE on each)
2. Freeze all contracts (DEFAULT_ADMIN_ROLE on each)

Phase 2: Return User Assets (EMERGENCY_EXIT_HANDLER_ROLE)

VotingEscrowMoca:
- emergencyExit(lockIds[]) → returns MOCA/esMOCA to lock owners

PaymentsController:
- emergencyExitFees() → returns undisbursed fees
- emergencyExitVerifiers(verifiers[]) → returns staked MOCA + USD8 balances
- emergencyExitIssuers(issuers[]) → returns unclaimed fees

EscrowedMoca:
- emergencyExit(users[]) → returns staked MOCA to users
- claimPenalties() → sweeps penalty MOCA to treasury

VotingController:
- emergencyExit() → transfers all esMOCA/MOCA to treasury

IssuerStakingController:
- emergencyExit(issuerAddresses[]) → returns staked MOCA to issuers

Phase 3: Asset Recovery
- All remaining assets swept to treasury
- Protocol shutdown complete
```

---

## 4. Contract-Specific Operations

### 4.1 Role Management

Each contract manages its own roles via OpenZeppelin AccessControlEnumerable:

**Role Hierarchy (per contract):**
```
DEFAULT_ADMIN_ROLE (Global Admin)
├── *_ADMIN_ROLE (Contract-specific admin)
├── EMERGENCY_EXIT_HANDLER_ROLE
├── MONITOR_ADMIN_ROLE
│   └── MONITOR_ROLE
├── CRON_JOB_ADMIN_ROLE
│   └── CRON_JOB_ROLE
└── ASSET_MANAGER_ROLE (where applicable)
```

**Granting Roles:**
```
1. DEFAULT_ADMIN_ROLE holder calls grantRole(role, account)
2. For sub-roles: respective ADMIN role holder grants
   - MONITOR_ADMIN grants MONITOR_ROLE
   - CRON_JOB_ADMIN grants CRON_JOB_ROLE
```

### 4.2 VotingController Epoch Operations

**Epoch Lifecycle (4-Step Finalization by CronJob):**

```
1. Epoch N Active (Voting state):
   - Users vote on pools
   - Delegates vote with delegated power
   - Verifications occur on PaymentsController

2. Step 1: End Epoch
   - cronJob calls endEpoch()
   - Transitions: Voting → Ended
   - Snapshots TOTAL_ACTIVE_POOLS

3. Step 2: Process Verifier Checks
   - cronJob calls processVerifierChecks(allCleared, verifiers[])
   - Blocks specified verifiers from claiming
   - Call with allCleared=true to transition: Ended → Verified

4. Step 3: Process Rewards & Subsidies
   - cronJob calls processRewardsAndSubsidies(poolIds[], rewards[], subsidies[])
   - Allocates rewards and subsidies per pool
   - Can be called multiple times for batching
   - When all pools done: Verified → Processed

5. Step 4: Finalize Epoch
   - cronJob calls finalizeEpoch()
   - Transfers esMOCA from treasury to contract
   - Transitions: Processed → Finalized
   - Claims now open

6. Claiming Period:
   - Users: claimPersonalRewards() / claimDelegatedRewards()
   - Delegates: claimDelegationFees()
   - Verifiers: claimSubsidies()
   - After UNCLAIMED_DELAY_EPOCHS: asset manager sweeps unclaimed
```

**Edge Case: No Active Pools**
```
If TOTAL_ACTIVE_POOLS == 0 when endEpoch() called:
- Epoch instantly transitions to Finalized
- Skips steps 2-4 entirely
```

**Force Finalization (Emergency):**
```
1. DEFAULT_ADMIN_ROLE calls forceFinalizeEpoch()
2. Zeroes out all allocations (blocks claims)
3. Transitions to ForceFinalized state
4. Rewards/subsidies must be distributed off-chain
```

**Pool Management (VOTING_CONTROLLER_ADMIN_ROLE):**
```
Create Pools:
1. createPools(count) → creates count sequential pools
2. Maximum 10 pools per call
3. Must be in Voting state

Remove Pools:
1. removePools(poolIds[])
2. Must be in Voting state
3. Users can migrate votes from removed pools to active pools
```

### 4.3 Delegation Operations

**Delegate Registration:**
```
1. User calls VotingController.registerAsDelegate(feePct) with msg.value
2. VotingController:
   - Requires payment of DELEGATE_REGISTRATION_FEE (native MOCA)
   - Sets delegate as registered
   - Records initial fee percentage
   - Calls VotingEscrowMoca.delegateRegistrationStatus(delegate, true)

3. VotingEscrowMoca:
   - Marks delegate as registered
   - Enables receiving delegated voting power
```

**Fee Updates:**
```
Increase (delayed):
1. Delegate calls updateDelegateFee(newFeePct)
2. Scheduled for currentEpoch + FEE_INCREASE_DELAY_EPOCHS
3. Applied when delegate next votes

Decrease (immediate):
1. Delegate calls updateDelegateFee(newFeePct)
2. Applied immediately
3. Overwrites any pending increase
```

**Historical Fee Tracking:**
```
- When delegate votes, current fee is logged to delegateHistoricalFeePcts[delegate][epoch]
- Claims use historical fee (not current) for accurate distribution
- Prevents retroactive fee manipulation
```

**Unregistration:**
```
1. Delegate calls unregisterAsDelegate()
2. Must have 0 votes in current epoch
3. Registration fee is non-refundable
4. VotingEscrowMoca marks delegate as unregistered
```

---

## 5. Redeployment & Migration

### 5.1 Architecture Constraints

All contracts are immutable with embedded references:
- No central registry (AddressBook)
- Cross-contract references set at deployment via constructor
- Role management is per-contract (no central AccessController)

### 5.2 Contract Migration Strategy

**Preparation:**
```
1. Complete current epoch (reach Finalized state)
2. Process all pending claims (rewards, subsidies, fees)
3. Withdraw unclaimed assets via AssetManager
4. Pause old contract (MONITOR_ROLE)
```

**Migration Steps:**
```
1. Deploy new contract with updated references
2. Update dependent contracts (if setters available):
   - VotingEscrowMoca.setVotingController(newVC)
   - EscrowedMoca.setWhitelistStatus(oldVC, false)
   - EscrowedMoca.setWhitelistStatus(newVC, true)
3. Transfer any remaining assets from old contract
4. Freeze old contract (DEFAULT_ADMIN_ROLE)
5. Grant operational roles on new contract
```

### 5.3 Cross-Contract Reference Updates

**VotingController Replacement:**
```
1. PaymentsController has NO direct VotingController reference
   → Uses pool whitelisting (whitelistPool) for pool validation
   → Whitelist pools created on new VotingController
2. VotingEscrowMoca can update via setVotingController()
3. EscrowedMoca updates whitelist status
```

**PaymentsController Replacement:**
```
1. VotingController has immutable PAYMENTS_CONTROLLER reference
   → Cannot update; requires new VotingController deployment
```

**VotingEscrowMoca Replacement:**
```
1. VotingController has immutable VEMOCA reference
   → Requires new VotingController deployment
2. EscrowedMoca has no direct reference
```

### 5.4 Critical Considerations

- **User locks in VotingEscrowMoca cannot migrate** - users must wait for expiry and unlock
- Historical data remains in old contracts - claims for past epochs still work
- New epochs start fresh in new contracts
- Delegation registrations are on VotingController - require re-registration on new contract

---

## 6. Out-of-Sync Scenarios

### 6.1 Cross-Contract Role Mismatches

**Scenario:** Different admins across contracts

**Consideration:**
- Each contract has independent DEFAULT_ADMIN_ROLE
- No automatic sync between contracts
- Requires manual coordination for role changes

**Best Practice:**
```
1. Use same multisig for DEFAULT_ADMIN_ROLE across all contracts
2. Document role assignments centrally
3. Batch role updates via scripts
```

### 6.2 VotingEscrowMoca Frozen but VotingController Active

**Risk:** Phantom voting power

**Mitigation:**
```
1. VotingEscrowMoca.balanceOf() returns 0 when frozen
2. VotingController cannot read voting power
3. Votes fail naturally
```

**Proper Shutdown:**
```
1. Pause VotingController first
2. Complete epoch operations (reach Finalized)
3. Then freeze VotingEscrowMoca
```

### 6.3 Epoch Finalization Interruption

**Scenario:** Epoch stuck between states

**Protection:**
```
- Pool removal blocked once epoch is not in Voting state
- TOTAL_ACTIVE_POOLS snapshot taken at endEpoch()
- processRewardsAndSubsidies() tracks progress via poolsProcessedCount
- forceFinalizeEpoch() available as emergency fallback
```

**Recovery:**
```
If epoch stuck:
1. Identify blocking condition
2. If irrecoverable: call forceFinalizeEpoch()
3. Distribute rewards/subsidies off-chain
```

### 6.4 Delegation State Mismatch

**Scenario:** Delegate unregisters with active delegations

**Handling:**
```
1. Delegate must have 0 current epoch votes to unregister
2. VotingEscrowMoca marks delegate as unregistered
3. Users can always undelegate (no registration check on user side)
4. Historical fees from past epochs remain claimable
```

### 6.5 VotingController ↔ VotingEscrowMoca Mismatch

**Scenario:** setVotingController() called with wrong address

**Risk:**
- Delegation registration/unregistration fails
- delegateVote() calls fail

**Recovery:**
```
1. Call setVotingController() with correct address
2. Only VOTING_ESCROW_MOCA_ADMIN_ROLE can update
```

### 6.6 EscrowedMoca Whitelist Mismatch

**Scenario:** VotingController not whitelisted on EscrowedMoca

**Risk:**
- Reward/subsidy claims fail (transfer reverts)

**Recovery:**
```
1. ESCROWED_MOCA_ADMIN_ROLE calls setWhitelistStatus(vc, true)
2. No claims lost - users can retry after fix
```

---

## 7. Emergency Procedures

### 7.1 Suspected Exploit Response

**Immediate Actions (Monitor):**
```
1. Pause affected contracts
2. Alert Global Admin
3. Begin investigation
```

**Admin Assessment:**
```
If recoverable:
- Fix issue
- Unpause contracts

If critical:
- Freeze contracts
- Initiate emergency exit
```

### 7.2 Partial System Failure

**Single Contract Compromise:**
```
1. Pause compromised contract (MONITOR_ROLE)
2. Complete active operations in other contracts
3. Deploy replacement if possible
4. Update cross-contract references where setters exist
5. Freeze old contract (DEFAULT_ADMIN_ROLE)
```

**Cross-Contract Failure:**
```
1. Pause all contracts
2. Assess recovery options
3. If unrecoverable:
   - Freeze all contracts
   - Execute emergency exit on each contract
```

### 7.3 Key Operational Timelines

**Critical Delays:**
- Delegate fee increase delay: FEE_INCREASE_DELAY_EPOCHS (configurable, default 1 epoch)
- Unclaimed asset delay: UNCLAIMED_DELAY_EPOCHS (configurable, default 6 epochs)
- Epoch duration: Fixed 14 days
- Minimum lock: 14 days
- Maximum lock: 672 days (48 epochs)

**Epoch Finalization Cadence:**
- 4 steps: endEpoch → processVerifierChecks → processRewardsAndSubsidies → finalizeEpoch
- Each step requires previous step completion
- processRewardsAndSubsidies can be batched across multiple calls

**Emergency Response Times:**
- Pause: Immediate (MONITOR_ROLE)
- Unpause: Requires DEFAULT_ADMIN_ROLE
- Freeze: Permanent, requires pause first (DEFAULT_ADMIN_ROLE)
- Emergency exit: Only after freeze (EMERGENCY_EXIT_HANDLER_ROLE)

---

## Summary

The MOCA Validator Protocol implements comprehensive privileged function controls with clear separation of duties:

1. **Operational roles** (MONITOR_ROLE, CRON_JOB_ROLE) handle routine tasks
2. **Strategic roles** (Contract-specific ADMIN roles) manage parameters
3. **Global Admin** (DEFAULT_ADMIN_ROLE) controls system-wide changes and role assignments
4. **Emergency procedures** (EMERGENCY_EXIT_HANDLER_ROLE) protect user assets

The protocol prioritizes user asset safety through:
- Multi-step state transitions (4-step epoch finalization)
- Atomic operations for critical updates
- Comprehensive emergency exit paths per contract
- Clear role boundaries via OpenZeppelin AccessControlEnumerable

Each contract manages its own roles independently (no central AccessController), requiring coordinated role management across the protocol.