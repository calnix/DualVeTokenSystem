# Attack Scenarios and Security Analysis

## Executive Summary

Comprehensive security analysis of the Moca protocol's access control system. Each contract uses OpenZeppelin's AccessControlEnumerable for independent role management. The system demonstrates robust security with no critical vulnerabilities when proper operational procedures are followed.

## Key Architecture Insights

### Per-Contract Role Management
- Each contract manages its own roles independently (no central AccessController)
- Roles are assigned at deployment via constructor parameters
- Role hierarchy uses OpenZeppelin's `_setRoleAdmin()` pattern
- DEFAULT_ADMIN_ROLE (Global Admin) is the ultimate authority per contract

### Role Hierarchy (Per Contract)
```
DEFAULT_ADMIN_ROLE (Global Admin - Multi-sig)
├── *_ADMIN_ROLE (Contract-specific admin)
├── EMERGENCY_EXIT_HANDLER_ROLE
├── ASSET_MANAGER_ROLE (where applicable)
├── MONITOR_ADMIN_ROLE
│   └── MONITOR_ROLE (can pause only)
└── CRON_JOB_ADMIN_ROLE
    └── CRON_JOB_ROLE (automated operational tasks)
```

### Role Categories

| Category | Roles | Purpose | Frequency |
|----------|-------|---------|-----------|
| High-Frequency | MONITOR_ROLE, CRON_JOB_ROLE | Automated operations | Per epoch / continuous |
| Strategic | *_ADMIN_ROLE | Configuration changes | Rare |
| Emergency | EMERGENCY_EXIT_HANDLER_ROLE | Crisis response | Emergency only |
| Asset | ASSET_MANAGER_ROLE | Fund management | Ad-hoc |

### Permission Check Resilience
- Role checks via `hasRole()` are view functions without pause modifiers
- Permission checks work even when contract is paused
- Global admin can always recover the system
- No circular dependencies between contracts

## Contract State Interaction Matrix

| Contract State | MONITOR_ROLE | CRON_JOB_ROLE | DEFAULT_ADMIN_ROLE | EMERGENCY_EXIT |
|:--------------:|:------------:|:-------------:|:------------------:|:--------------:|
| **Active** | pause() | Epoch ops | Config, roles | N/A |
| **Paused** | N/A | N/A | unpause(), freeze() | N/A |
| **Frozen** | N/A | N/A | N/A | emergencyExit() |

### State Transition Rules
```
Active → Paused (MONITOR_ROLE)
Paused → Active (DEFAULT_ADMIN_ROLE, only if not frozen)
Paused → Frozen (DEFAULT_ADMIN_ROLE, one-way)
Frozen → Emergency Exit (EMERGENCY_EXIT_HANDLER_ROLE)
```

## Attack Scenarios Analysis

### Scenario 1: Emergency Pause Coordination ✅

```
Step 1: Security incident detected
Step 2: Monitor bot calls pause() on affected contracts
Step 3: Global admin evaluates situation via multi-sig
Step 4: Role management remains available (not affected by pause)
Step 5: Global admin can add/remove emergency handlers
Step 6: Either unpause() to resume or freeze() → emergencyExit()
```

**Result:** System secure, proper authorization hierarchy maintained

### Scenario 2: Monitor Compromise - Cascade Analysis ✅

```
Step 1: Monitor bot private key compromised
Step 2: Attacker uses compromised key to pause operational contracts
Step 3: MONITOR_ADMIN detects abnormal pause activity
Step 4: MONITOR_ADMIN calls revokeRole(MONITOR_ROLE, compromisedBot)
Step 5: MONITOR_ADMIN calls grantRole(MONITOR_ROLE, newTrustedBot)
Step 6: DEFAULT_ADMIN_ROLE calls unpause() on affected contracts
Step 7: Normal operations resume
```

**Result:** Temporary DoS, but recoverable with proper procedure

> **Key Insight:** Monitors can only pause. They cannot unpause, freeze, or execute asset-outflow functions. Blast radius is limited to operational disruption.

### Scenario 3: CronJob Compromise During Epoch Transition ⚠️

```
Step 1: Epoch N approaching end (1 hour remaining)
Step 2: Attacker compromises CRON_JOB_ADMIN multisig
Step 3: Attacker adds malicious cron_job bot
Step 4: Malicious bot calls processRewardsAndSubsidies() with manipulated data
Step 5: Global admin detects anomaly via monitoring
Step 6: Global admin revokes malicious cron job role
Step 7: DEFAULT_ADMIN_ROLE calls forceFinalizeEpoch() to block claims
Step 8: Rewards/subsidies distributed off-chain
```

**Result:** Epoch-end operational procedures require careful multi-sig coordination. `forceFinalizeEpoch()` provides recovery path.

> **Mitigation:** CronJob roles should be granted per-epoch and revoked after use.

### Scenario 4: Emergency Exit Handler During Crisis ✅

```
Step 1: Major exploit discovered in protocol
Step 2: Monitor bots pause all contracts immediately
Step 3: Global admin evaluates need for emergency exit
Step 4: Decision made to freeze and activate emergency exit
Step 5: DEFAULT_ADMIN_ROLE calls freeze() on each contract
Step 6: EMERGENCY_EXIT_HANDLER_ROLE calls emergencyExit() per contract:
   - VotingEscrowMoca: emergencyExit(lockIds[]) → returns MOCA/esMOCA
   - PaymentsController: emergencyExitVerifiers/Issuers/Fees()
   - EscrowedMoca: emergencyExit(users[])
   - VotingController: emergencyExit() → sweeps to treasury
Step 7: Assets successfully recovered
```

**Result:** Clean emergency exit path with proper role separation

### Scenario 5: Cross-Contract Role Mismatch ⚠️

```
Step 1: Protocol has 5 contracts each with own role management
Step 2: Admin rotation needed - new multi-sig deployed
Step 3: Team updates DEFAULT_ADMIN_ROLE on 4 contracts
Step 4: Forgets to update 5th contract (VotingEscrowMoca)
Step 5: Old admin still controls VotingEscrowMoca
Step 6: Inconsistent security posture across protocol
```

**Mitigation:** 
- Use same multi-sig for DEFAULT_ADMIN_ROLE across all contracts
- Maintain centralized documentation of role assignments
- Batch role updates via deployment scripts
- Verify role consistency after any admin change

### Scenario 6: Role Admin Hierarchy Attack ✅

```
Step 1: Attacker wants to bypass MONITOR_ADMIN_ROLE
Step 2: Attacker attempts to change role hierarchy
Step 3: Calls _setRoleAdmin(MONITOR_ROLE, ATTACKER_CONTROLLED_ROLE)
Step 4: _setRoleAdmin is internal function - not callable externally
Step 5: Role hierarchy set at deployment is immutable
```

**Result:** Role hierarchy protected by design

### Scenario 7: VotingController ↔ VotingEscrowMoca Desync ⚠️

```
Step 1: VotingEscrowMoca.setVotingController() called with wrong address
Step 2: Delegation registration/unregistration fails silently
Step 3: Users cannot delegate properly
Step 4: Detected via monitoring or user reports
Step 5: VOTING_ESCROW_MOCA_ADMIN_ROLE fixes via setVotingController()
```

**Result:** Operational issue, not security breach. Recoverable.

### Scenario 8: EscrowedMoca Whitelist Attack ✅

```
Step 1: VotingController needs to transfer esMOCA for rewards
Step 2: VotingController not whitelisted on EscrowedMoca
Step 3: Transfer reverts - claims fail
Step 4: Users cannot claim rewards
Step 5: ESCROWED_MOCA_ADMIN_ROLE adds VotingController to whitelist
Step 6: Claims work again - no funds lost
```

**Result:** Whitelist acts as additional safety layer. Misconfiguration is recoverable.

### Scenario 9: Freeze State Without Emergency Handler ⚠️

```
Step 1: Critical exploit - contracts paused immediately
Step 2: Decision to freeze contracts permanently
Step 3: No EMERGENCY_EXIT_HANDLER_ROLE assigned
Step 4: Contracts frozen but emergencyExit() cannot be called
Step 5: DEFAULT_ADMIN_ROLE grants EMERGENCY_EXIT_HANDLER_ROLE
Step 6: Emergency exit proceeds normally
```

**Takeaway:** Emergency handlers should be pre-assigned at deployment, but can be added post-freeze if needed.

### Scenario 10: PaymentsController Pool Whitelist Manipulation ✅

```
Step 1: Attacker wants subsidies for fake pool
Step 2: Attempts to call whitelistPool(fakePoolId, true)
Step 3: Requires PAYMENTS_CONTROLLER_ADMIN_ROLE
Step 4: Attacker doesn't have role - transaction reverts
```

**Result:** Pool whitelisting protected by admin role

### Scenario 11: Epoch Finalization Manipulation ⚠️

```
Step 1: CronJob calls processRewardsAndSubsidies() with inflated values
Step 2: Contract accepts values (no on-chain validation of source data)
Step 3: Incorrect rewards/subsidies allocated
Step 4: Detection via monitoring or auditing
Step 5: If caught before finalizeEpoch(): fix data
Step 6: If caught after: forceFinalizeEpoch() + off-chain distribution
```

**Takeaway:** Off-chain reward calculation requires robust monitoring and multi-sig verification before submission.

### Scenario 12: Native MOCA Transfer Failure ✅

```
Step 1: User claims rewards with native MOCA component
Step 2: User's address is contract without receive() function
Step 3: Native transfer fails
Step 4: Fallback: Contract wraps MOCA to wMOCA and transfers ERC20
Step 5: User receives wMOCA instead
```

**Result:** LowLevelWMoca provides robust fallback mechanism

### Scenario 13: Signature Replay Attack (PaymentsController) ✅

```
Step 1: Attacker captures valid deductBalance signature
Step 2: Attempts to replay signature for additional deductions
Step 3: Contract checks nonce: _verifierNonces[signer][user]
Step 4: Nonce already incremented from first use
Step 5: Replay fails - signature invalid for incremented nonce
```

**Result:** Per-user nonce prevents signature replay

### Scenario 14: VotingEscrowMoca Frozen While VotingController Active ⚠️

```
Step 1: VotingEscrowMoca paused and frozen due to exploit
Step 2: VotingController still active
Step 3: User attempts to vote
Step 4: VotingController calls VEMOCA.balanceOf(user)
Step 5: VotingEscrowMoca returns 0 when frozen (safety check)
Step 6: Vote fails due to zero voting power
```

**Proper Shutdown Sequence:**
1. Pause VotingController first
2. Complete epoch operations (reach Finalized)
3. Then freeze VotingEscrowMoca
4. Finally freeze VotingController

### Scenario 15: Delegate Fee Manipulation ✅

```
Step 1: Delegate has 5% fee, actively receiving delegations
Step 2: Delegate calls updateDelegateFee(50%) to increase fee
Step 3: Increase scheduled for currentEpoch + FEE_INCREASE_DELAY_EPOCHS
Step 4: Historical fee recorded when delegate votes
Step 5: Claims use historical fee (5%), not pending increase (50%)
Step 6: Users protected from retroactive fee manipulation
```

**Result:** Historical fee tracking prevents bait-and-switch attacks

## Critical Findings Summary

### ✅ Strengths
1. **Per-contract isolation** - Compromise of one contract doesn't propagate
2. **Clean role hierarchy** - OpenZeppelin patterns well-implemented
3. **No single points of failure** - Multiple recovery paths
4. **Historical state tracking** - Prevents retroactive manipulation
5. **Fallback mechanisms** - LowLevelWMoca handles edge cases

### ⚠️ Operational Considerations
1. **Pre-assign emergency handlers** before any production deployment
2. **Consistent role management** across all contracts (use same multi-sig)
3. **CronJob roles** should be granted per-epoch and revoked after use
4. **Monitor role rotation** should be regular practice
5. **Off-chain data verification** for epoch finalization requires robust monitoring

## Security Verdict

The system is **secure with proper operational procedures**. The per-contract architecture provides isolation but requires coordinated role management across contracts.

## Recommended Operational Procedures

### Role Rotation Schedule
| Role | Rotation Frequency | Notes |
|------|-------------------|-------|
| MONITOR_ROLE | Quarterly | Rotate to fresh set after any incident |
| CRON_JOB_ROLE | Per epoch | Grant before epoch end, revoke after |
| *_ADMIN_ROLE | Quarterly review | Multi-sig, no routine rotation |
| EMERGENCY_EXIT_HANDLER_ROLE | Quarterly drill | Test on testnet |
| ASSET_MANAGER_ROLE | As needed | Review quarterly |

### Deployment Checklist
- [ ] All constructor role addresses are correct multi-sigs
- [ ] Same DEFAULT_ADMIN_ROLE across all contracts
- [ ] EMERGENCY_EXIT_HANDLER_ROLE assigned before mainnet
- [ ] MONITOR_ROLE assigned to monitoring bots
- [ ] VotingEscrowMoca.setVotingController() called
- [ ] EscrowedMoca.setWhitelistStatus(votingController, true) called
- [ ] PaymentsController pools whitelisted
- [ ] Test all emergency procedures on testnet

### Emergency Response Plan

```
IF security incident detected:
  1. MONITOR_ROLE pauses affected contracts
  2. Assess severity and scope
  3. IF recoverable:
     - Fix issue
     - DEFAULT_ADMIN_ROLE calls unpause()
  4. IF critical:
     - DEFAULT_ADMIN_ROLE calls freeze()
     - EMERGENCY_EXIT_HANDLER_ROLE executes emergencyExit()
  5. Document all actions taken
```

### Contract Shutdown Sequence (Planned)

```
1. Pause VotingController (block new votes)
2. Complete current epoch (finalizeEpoch)
3. Process all pending claims
4. withdrawUnclaimedRewards/Subsidies (after delay)
5. Pause remaining contracts
6. Freeze in order: VC → VE → PC → ES → ISC
7. Emergency exit assets to treasury
```

## Key Security Properties

### Blast Radius Containment
- Each role has limited scope per contract
- MONITOR_ROLE: pause only (no asset access)
- CRON_JOB_ROLE: specific operational functions
- EMERGENCY_EXIT_HANDLER_ROLE: only works when frozen
- Compromised roles cannot escalate privileges

### Permission Persistence
- Permission checks remain functional during pause
- No lockout scenarios for legitimate admin
- Clean recovery paths from all states
- View functions always accessible

### Immutable References
- Contract addresses (VEMOCA, PAYMENTS_CONTROLLER, etc.) set at deployment
- Cannot be changed post-deployment
- Requires contract migration for updates
- Prevents address substitution attacks

