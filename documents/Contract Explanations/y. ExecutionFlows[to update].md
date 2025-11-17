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
1. Deploy AddressBook (with globalAdmin)
   ↓
2. Deploy AccessController (references AddressBook)
   ↓
3. Deploy Core Contracts (all reference AddressBook):
   - EscrowedMoca
   - VotingEscrowMoca
   - PaymentsController
   - VotingController
   ↓
4. Update AddressBook with all contract addresses
   ↓
5. Configure initial parameters
   ↓
6. Grant operational roles
```

### 1.2 Detailed Deployment Steps

#### Step 1: Deploy AddressBook
```solidity
// Deploy with global admin (multisig)
AddressBook addressBook = new AddressBook(globalAdminMultisig);
```

#### Step 2: Deploy AccessController
```solidity
// Deploy with AddressBook reference
AccessController accessController = new AccessController(address(addressBook));
// AccessController automatically pulls globalAdmin from AddressBook
```

#### Step 3: Deploy Core Contracts
```solidity
// Deploy EscrowedMoca
EscrowedMoca esMoca = new EscrowedMoca(
    address(addressBook),
    votersPenaltySplit // e.g., 5000 (50%)
);

// Deploy VotingEscrowMoca
VotingEscrowMoca veMoca = new VotingEscrowMoca(address(addressBook));

// Deploy PaymentsController
PaymentsController payments = new PaymentsController(
    address(addressBook),
    protocolFeePercentage,  // e.g., 500 (5%)
    voterFeePercentage,     // e.g., 1000 (10%)
    delayPeriod,            // e.g., 14 days
    "PaymentsController",
    "1"
);

// Deploy VotingController
VotingController voting = new VotingController(
    address(addressBook),
    registrationFee,        // e.g., 1000 MOCA
    maxDelegateFeePct,      // e.g., 2000 (20%)
    delayDuration          // e.g., 14 days
);
```

#### Step 4: Update AddressBook
```solidity
// Global admin executes these
addressBook.setAddress("ACCESS_CONTROLLER", address(accessController));
addressBook.setAddress("ES_MOCA", address(esMoca));
addressBook.setAddress("VOTING_ESCROW_MOCA", address(veMoca));
addressBook.setAddress("PAYMENTS_CONTROLLER", address(payments));
addressBook.setAddress("VOTING_CONTROLLER", address(voting));
addressBook.setAddress("USD8", usd8TokenAddress);
addressBook.setAddress("MOCA", mocaTokenAddress);
addressBook.setAddress("TREASURY", treasuryAddress);
```

#### Step 5: Configure Parameters

**EscrowedMoca:**
```solidity
// Set redemption options (by EscrowedMocaAdmin)
esMoca.setRedemptionOption(0, 0, 10000);        // Instant: 100% return
esMoca.setRedemptionOption(1, 30 days, 5000);   // 30-day: 50% return
esMoca.setRedemptionOption(2, 90 days, 7500);   // 90-day: 75% return

// Whitelist VotingController for transfers
esMoca.setWhitelistStatus(address(voting), true);
```

**PaymentsController:**
```solidity
// Set subsidy tiers (by PaymentsControllerAdmin)
payments.updateVerifierSubsidyPercentages(1000e18, 500);   // 1000 MOCA: 5% subsidy
payments.updateVerifierSubsidyPercentages(5000e18, 1000);  // 5000 MOCA: 10% subsidy
payments.updateVerifierSubsidyPercentages(10000e18, 1500); // 10000 MOCA: 15% subsidy
```

#### Step 6: Grant Roles
```solidity
// By Global Admin
accessController.addMonitor(monitorBot);
accessController.addCronJob(cronJobBot);
accessController.addAssetManager(assetManagerMultisig);
accessController.addEmergencyExitHandler(emergencyBot);
accessController.addPaymentsControllerAdmin(paymentsAdmin);
accessController.addVotingControllerAdmin(votingAdmin);
accessController.addEscrowedMocaAdmin(esMocaAdmin);
```

---

## 2. Asset Flows

### 2.1 Deposit Flows

#### MOCA Token Deposits

**Lock Creation (User → VotingEscrowMoca):**
```
1. User approves MOCA/esMOCA to VotingEscrowMoca
2. User calls createLock(expiry, mocaAmount, esMocaAmount, delegate)
3. Contract:
   - Transfers tokens from user
   - Creates lock record
   - Mints veMOCA to user/delegate
   - Updates global accounting
```

**Verifier Staking (Verifier → PaymentsController):**
```
1. Verifier approves MOCA to PaymentsController
2. Verifier calls stakeMoca(verifierId, amount)
3. Contract:
   - Transfers MOCA from verifier
   - Updates verifier's staked balance
   - Updates subsidy tier eligibility
```
*Optional: if verifier wants subsidies*

#### USD8 Deposits

**Verifier Balance (Verifier → PaymentsController):**
```
1. Verifier approves USD8 to PaymentsController
2. Verifier calls deposit(verifierId, amount)
3. Contract:
   - Transfers USD8 from verifier
   - Updates verifier's balance
```
*Mandatory: else verifier cannot process verifications*

### 2.2 Withdrawal Flows

#### Principal Returns

**Lock Unlock (VotingEscrowMoca → User):**
```
1. User calls unlock(lockId) after expiry
2. Contract:
   - Verifies lock expired
   - Burns veMOCA
   - Returns MOCA/esMOCA to user
   - Updates global accounting
```

**Emergency Exit (VotingEscrowMoca → Users):**
```
1. EmergencyExitHandler calls emergencyExit(lockIds[])
2. Contract (must be frozen):
   - Burns veMOCA for each lock
   - Returns principals to lock owners
   - Marks locks as exited
```

#### Fee/Reward Claims

**Issuer Fee Claims (PaymentsController → Issuer):**
```
1. Issuer calls claimFees(issuerId)
2. Contract:
   - Calculates unclaimed fees
   - Transfers USD8 to issuer
   - Updates claimed amount
```

**Voter Reward Claims (VotingController → User):**
```
1. User calls voterClaimRewards(epoch, poolIds[])
2. Contract:
   - Verifies epoch finalized
   - Calculates pro-rata rewards
   - Transfers esMOCA to user
   - Updates claimed amounts
```

**Subsidy Claims (VotingController → Verifier):**
```
1. Verifier calls claimSubsidies(epoch, verifierId, poolIds[])
2. Contract:
   - Gets subsidy data from PaymentsController
   - Calculates claimable subsidies
   - Transfers esMOCA to verifier
```

### 2.3 Asset Manager Operations

**Protocol Fee Withdrawal:**
```
1. AssetManager calls PaymentsController.withdrawProtocolFees(epoch)
2. Contract:
   - Verifies epoch ended
   - Transfers USD8 to treasury
   - Marks as withdrawn
```

**Unclaimed Asset Sweeps:**
```
1. AssetManager waits for UNCLAIMED_DELAY_EPOCHS
2. Calls withdrawUnclaimedRewards(epoch) or withdrawUnclaimedSubsidies(epoch)
3. Contract:
   - Verifies delay passed
   - Transfers unclaimed esMOCA to treasury
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
1. Pause all contracts (Monitor)
2. Freeze all contracts (Global Admin)

Phase 2: Return User Assets
VotingEscrowMoca:
- emergencyExit(lockIds[]) → returns MOCA/esMOCA

PaymentsController:
- emergencyExitVerifiers(verifierIds[]) → returns USD8 balances
- emergencyExitIssuers(issuerIds[]) → returns unclaimed fees

EscrowedMoca:
- emergencyExit() → transfers all MOCA to treasury

VotingController:
- emergencyExit() → transfers all esMOCA/MOCA to treasury

Phase 3: Asset Recovery
- All remaining assets swept to treasury
- Protocol shutdown complete
```

---

## 4. Contract-Specific Operations

### 4.1 AddressBook Operations

**Global Admin Transfer (2-Step):**
```
1. Current owner calls transferOwnership(newOwner)
2. New owner calls acceptOwnership()
3. AddressBook:
   - Updates owner
   - Calls AccessController.transferGlobalAdminFromAddressBook()
   - Syncs DEFAULT_ADMIN_ROLE
```

**Address Updates:**
```
1. Owner calls setAddress(identifier, newAddress)
2. Contract:
   - Updates registry
   - Emits AddressSet event
Note: Cannot update global admin (bytes32(0)) this way
```

### 4.2 VotingController Epoch Operations

**Epoch Lifecycle (CronJob):**
```
1. Epoch N Active:
   - Users vote
   - Verifications occur

2. Epoch N Ends:
   - depositEpochSubsidies(N, subsidyAmount)
   - Sets subsidy allocation

3. Finalization:
   - finalizeEpochRewardsSubsidies(N, poolIds[], rewards[])
   - Allocates rewards per pool
   - Marks pools processed
   - Full finalization when all pools done

4. Claiming Period:
   - Users/delegates/verifiers claim
   - After delay: unclaimed swept
```

**Pool Management (CronJob):**
```
Create Pool:
1. createPool() → generates unique poolId
2. Links to schemas in PaymentsController

Remove Pool:
1. removePool(poolId)
2. Must be before depositEpochSubsidies()
3. Decrements TOTAL_NUMBER_OF_POOLS
```

### 4.3 Delegation Operations

**Delegate Registration:**
```
1. User calls VotingController.registerAsDelegate(feePct)
2. VotingController:
   - Collects registration fee
   - Calls VotingEscrowMoca.registerAsDelegate()
   - Sets delegate active

3. VotingEscrowMoca:
   - Marks delegate registered
   - Enables delegation receipt
```

**Fee Updates:**
```
Increase (delayed):
1. Delegate calls updateDelegateFee(newFeePct)
2. Applied after FEE_INCREASE_DELAY_EPOCHS

Decrease (immediate):
1. Delegate calls updateDelegateFee(newFeePct)
2. Applied immediately
```

---

## 5. Redeployment & Migration

### 5.1 AccessController Migration

AccessController is the only upgradeable component:

```
1. Deploy new AccessController
2. Global Admin updates AddressBook:
   addressBook.setAddress("ACCESS_CONTROLLER", newAccessController)

3. New AccessController:
   - Pulls globalAdmin from AddressBook
   - Fresh role assignments needed

4. Re-grant all roles:
   - Monitors, CronJobs
   - Contract admins
   - Asset managers
   - Emergency handlers
```

### 5.2 Other Contract Migrations

Other contracts are immutable but can be replaced:

**Preparation:**
```
1. Pause old contract
2. Wait for epoch completion
3. Process all pending claims
```

**Migration Steps:**
```
1. Deploy new contract
2. Update AddressBook reference
3. Transfer any contract-held assets
4. Update dependent contracts
5. Freeze old contract
```

**Critical Considerations:**
- User locks in VotingEscrowMoca cannot migrate
- Historical data remains in old contracts
- New epochs start fresh in new contracts

---

## 6. Out-of-Sync Scenarios

### 6.1 AddressBook vs AccessController Desync

**Scenario:** Global admin mismatch

**Prevention:**
- AddressBook ownership transfer automatically syncs AccessController
- Single source of truth: AddressBook owner

**Recovery if manual intervention needed:**
```
1. AddressBook owner calls:
   accessController.transferGlobalAdminFromAddressBook(oldAdmin, newAdmin)
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
2. Complete epoch operations
3. Then freeze VotingEscrowMoca
```

### 6.3 Epoch Finalization Interruption

**Scenario:** Pool removed during finalization

**Protection:**
```
- Pool removal blocked after depositEpochSubsidies()
- TOTAL_NUMBER_OF_POOLS locked during finalization
- Ensures epoch can complete
```

### 6.4 Delegation State Mismatch

**Scenario:** Delegate unregisters with active delegations

**Handling:**
```
1. Users can always undelegate (no registration check)
2. Delegated voting power returns to user
3. Historical fees remain claimable
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
1. Pause compromised contract
2. Complete active operations in others
3. Deploy replacement if possible
4. Update AddressBook
5. Freeze old contract
```

**Cross-Contract Failure:**
```
1. Pause all contracts
2. Assess recovery options
3. If unrecoverable:
   - Full system freeze
   - Emergency exit all contracts
```

### 7.3 Key Operational Timelines

**Critical Delays:**
- Fee increase delay: Configurable (default 14 days)
- Unclaimed asset delay: Configurable (default 14 days)
- Epoch duration: Fixed 14 days
- Minimum lock: 14 days
- Maximum lock: 672 days

**Emergency Response Times:**
- Pause: Immediate (Monitor bot)
- Unpause: Requires admin review
- Freeze: Permanent, requires pause first
- Emergency exit: Only after freeze

---

## Summary

The MOCA Validator Protocol implements comprehensive privileged function controls with clear separation of duties:

1. **Operational roles** (Monitor, CronJob) handle routine tasks
2. **Strategic roles** (Admins) manage parameters
3. **Global Admin** controls system-wide changes
4. **Emergency procedures** protect user assets

The protocol prioritizes user asset safety through:
- Multi-step state transitions
- Atomic operations for critical updates
- Comprehensive emergency exit paths
- Clear role boundaries and access controls

All privileged operations emit events for transparency and maintain strict access control through the centralized AccessController pattern.