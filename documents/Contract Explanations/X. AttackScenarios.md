# Attack Scenarios and Security Analysis

## Executive Summary

Comprehensive security analysis of the Moca protocol's access control system, focusing on the interaction between AddressBook and AccessController contracts. After removing `addGlobalAdmin`/`removeGlobalAdmin` functions and adding `whenNotPaused` modifiers to all role management functions, the system demonstrates robust security with no critical vulnerabilities.

## Key Architecture Insights

### Single Global Admin Model
- One supreme admin (multi-sig) defined in AddressBook
- Synchronized with AccessController via `transferGlobalAdminFromAddressBook()`
- No multiple admin vulnerability
- Atomic ownership transfers prevent inconsistent states

### Permission Check Resilience
- All `isRole()` functions are view functions without pause modifiers
- Permission checks work even when AccessController is paused
- No circular dependencies or deadlocks possible
- Global admin can always recover the system

## Contract State Interaction Matrix

| AddressBook State | System Impact                                  | Recovery Path                |
|:-----------------:|:----------------------------------------------:|:----------------------------:|
| **Active**        | Normal operations                              | N/A                          |
| **Paused**        | All operations blocked (can't fetch AC address)| Unpause AddressBook          |
| **Frozen**        | Permanent shutdown                             | No recovery                  |

### Why AccessController is Not Pausable

Unlike operational contracts, AccessController deliberately excludes pausable functionality:

1. **Multi-sig Protection**: All role management already requires multi-sig coordination, providing inherent security
2. **Emergency Response**: During crises, the ability to revoke compromised roles is critical - pausability would block this
3. **No Deadlock Risk**: Role permission checks must remain functional for unpause/freeze operations
4. **Clear Security Model**: Fast emergency response via monitor pauses on operational contracts, while role management remains secure through multi-sig

This design ensures that even during protocol emergencies, the access control layer remains fully operational for critical role management tasks.

## Attack Scenarios Analysis

### Scenario 1: Emergency Pause Coordination ✅

Step 1: Security incident detected
Step 2: Monitor bot calls pause() on all operational contracts
Step 3: Global admin evaluates situation
Step 4: AccessController remains fully operational (not pausable)
Step 5: Global admin can add or remove emergency handlers at any time
Step 6: Role management and emergency response remain available throughout

**Result:** System secure, proper authorization hierarchy maintained

### Scenario 2: Ownership Transfer Attack Vector ✅

Step 1: Attacker identifies AddressBook ownership transfer function
Step 2: Attacker attempts to call AddressBook.transferOwnership()
Step 3: Transaction REVERTS - attacker is not the owner

**Result:** No attack vector exists

### Scenario 3: Monitor Compromise - Cascade Analysis ✅

Step 1: Monitor bot private key compromised
Step 2: Attacker uses compromised key to pause all operational contracts 
Step 3: MONITOR_ADMIN detects abnormal pause activity
Step 4: MONITOR_ADMIN calls removeMonitor() for compromised bot
Step 5: MONITOR_ADMIN adds new trusted monitor
Step 6: Normal operations resume

**Result:** Temporary DoS, but recoverable with proper procedure

### Scenario 4: Critical Role Management During Epoch Transition ✅

Step 1: Epoch N approaching end (1 hour remaining)
Step 2: Monitoring detects suspicious activity in PaymentsController
Step 3: Monitor bot pauses PaymentsController as precaution
Step 4: Primary cron job bot goes offline unexpectedly
Step 5: CRON_JOB_ADMIN (multi-sig) needs to add backup cron job
Step 6: Calls addCronJob() with new backup address - succeeds immediately
Step 7: Backup cron job executes finalizeEpochRewardsSubsidies() on time
Step 8: Epoch transitions successfully despite ongoing security investigation

**Result**: AccessController's non-pausable design ensures critical role management during emergencies. Multi-sig requirement maintains security without operational disruption.

>If AccessController were pausable and got paused during the security incident, the protocol would have missed the epoch transition deadline, causing significant operational failure. The non-pausable design with multi-sig controls provides both security and reliability.

### Scenario 5: Emergency Exit Handler During Crisis ✅

Step 1: Major exploit discovered in protocol
Step 2: All operational contracts paused as immediate response
Step 3: Global admin evaluates need for emergency exit procedures
Step 4: Decision made to freeze contracts and activate emergency exit
Step 5: Global admin adds emergency exit handler via addEmergencyExitHandler() *[assuming none was added priori]*
Step 6: Handler address successfully granted EMERGENCY_EXIT_HANDLER_ROLE
Step 7: Operational contracts frozen via freeze() calls
Step 8: Emergency exit handler executes emergencyExit() on frozen contracts
Step 9: Assets successfully recovered to designated safe address
Step 10: Protocol shutdown complete with all funds secured

**Result:**
- Non-pausable AccessController enables seamless crisis management
- No operational delays or sequencing issues
- Critical role assignments remain available when most needed
- Multi-sig requirement ensures only legitimate emergency handlers added

### Scenario 6: Cross-Contract Permission Check During Crisis ✅

Step 1: Multiple operational contracts paused due to security incident
Step 2: Monitor bot detects additional anomaly in VotingController
Step 3: Monitor bot calls VotingController.pause()
Step 4: VotingController calls addressBook.getAccessController()
Step 5: VotingController calls accessController.isMonitor(bot)
Step 6: isMonitor() returns true (permission check succeeds)
Step 7: VotingController pause succeeds
Step 8: Meanwhile, MONITOR_ADMIN can add/remove monitors as needed

**Result:** Non-pausable AccessController ensures permission infrastructure remains fully operational during emergencies, enabling coordinated response across all contracts

### Scenario 7: AddressBook as Cross-Contract Kill Switch ✅

Step 1: Critical vulnerability discovered
Step 2: AddressBook is paused immediately
Step 3: Operations that REQUIRE address lookups fail:
   - VotingController needs addressBook.getVotingEscrowMoca() → REVERTS
   - PaymentsController needs addressBook.getAccessController() → REVERTS
   - Any contract fetching addresses dynamically → REVERTS
Step 4: Operations that DON'T require address lookups continue:
   - Direct MOCA transfers between users → WORKS
   - Reading balances on token contracts → WORKS
   - Any function not needing AddressBook → WORKS

**Result:** AddressBook pause => Cross-contract communication kill switch:
- It blocks any operation that needs to look up contract addresses
- Direct operations on already-known contracts continue to function
- It's not a complete protocol freeze, just a cross-contract freeze

### Scenario 8: Freeze State Propagation ✅

Step 1: Critical vulnerability discovered requiring permanent shutdown
Step 2: Global admin initiates freeze sequence
Step 3: Pause AddressBook
Step 4: Pause all operational contracts (PaymentsController, VotingController, etc.)
Step 5: Freeze AddressBook (requires paused state)
Step 6: Freeze operational contracts (requires paused state)
Step 7: System permanently locked
Step 8: No recovery possible - freeze is one-way

**Result:** Proper one-way freeze mechanism with AccessController remaining operational for emergency role management until the end

### Scenario 10: Role Admin Hierarchy Attack ✅

Step 1: Attacker wants to bypass MONITOR_ADMIN_ROLE
Step 2: Attacker attempts to change role hierarchy
Step 3: Calls setRoleAdmin(MONITOR_ROLE, ATTACKER_CONTROLLED_ROLE)
Step 4: Call requires DEFAULT_ADMIN_ROLE
Step 5: Attacker doesn't have DEFAULT_ADMIN_ROLE
Step 6: Transaction REVERTS

**Result:** Role hierarchy protected by multi-sig requirements

### Scenario 11: Time-Based Attack During Epoch Transition ⚠️

Step 1: Epoch N has 1 minute remaining
Step 2: Attacker compromises CRON_JOB_ADMIN multisig
Step 3: Attacker rapidly adds malicious cron_job bot
Step 4: Malicious cron_job bot calls finalizeEpochRewardsSubsidies()
Step 5: Manipulated reward data submitted
Step 6: Global admin detects anomaly
Step 7: Global admin immediately removes malicious cron job
Step 8: Adds trusted cron job to correct the issue *[100% rectification of issue may not be possible]*
Step 9: System recovers due to accessible role management

**Result:** Epoch-end operational procedures must be executed with care and not automated via `set & forget`

### Scenario 12: Multi-Contract Circular Dependency Check ✅ [!!]

Step 1: VotingController needs to process epoch finalization
Step 2: VotingController calls addressBook.getAccessController()
Step 3: Receives AccessController address successfully
Step 4: VotingController calls accessController.isCronJob(msg.sender)
Step 5: AccessController is paused but permission check works
Step 6: Returns true/false based on role status
Step 7: VotingController proceeds with operation
Step 8: No circular dependency or deadlock

**Result:** No circular dependency, clean separation

### Scenario 13: Reentrancy Through Role Changes ✅ [!!]

Step 1: Malicious contract becomes MONITOR_ADMIN
Step 2: MONITOR_ADMIN calls addMonitor() with malicious contract address
Step 3: Within same transaction, malicious monitor receives role
Step 4: Malicious contract attempts callback to addMonitor()
Step 5: OpenZeppelin AccessControl prevents reentrancy
Step 6: Nested call REVERTS
Step 7: Transaction completes with single monitor added

**Result:** Protected by OZ AccessControl

### Scenario 14: Gas Griefing Through Mass Role Assignment ✅

Step 1: MONITOR_ADMIN creates malicious contract
Step 2: Contract attempts to add 1000 monitors in a loop
Step 3: Each addMonitor() consumes gas
Step 4: Gas consumption increases linearly
Step 5: Transaction hits block gas limit
Step 6: Entire transaction REVERTS
Step 7: No monitors added (atomic reversion)

**Result:** Self-limiting, no security risk

### Scenario 15: Emergency Exit Handler Race Condition ⚠️

Step 1: System frozen due to critical exploit
Step 2: Emergency exit needed immediately
Step 3: No pre-assigned emergency exit handler
Step 4: Freeze is one-way, cannot unfreeze
Step 5: Cannot add handler to frozen contract
Step 6: Funds locked permanently

**Result:** Emergency handlers must always be pre-assigned.

### Scenario 16: AddressBook Zero Address Edge Case ✅ [!!]

Step 1: AddressBook deployed
Step 2: AccessController not yet deployed/set, but core contracts are deployed and active
Step 3: User calls VotingController.vote()
Step 4: VotingController calls addressBook.getAccessController()
Step 5: Returns address(0)
Step 6: VotingController attempts IAccessController(0).isMonitor()
Step 7: Call to zero address REVERTS
Step 8: User transaction fails safely

**Result:** Natural fail-safe, operations blocked until properly configured

### Scenario 17: Privilege Escalation Through Contract Upgrade ✅ [!!]

Step 1: Protocol decides to upgrade VotingController
Step 2: New VotingController V2 deployed
Step 3: AddressBook.setAddress() called to update pointer
Step 4: Old VotingController V1 attempts operation 
Step 5: V1 calls accessController.isCronJob(address(V1)) [!!]
Step 6: Returns false - V1 no longer has privileges
Step 7: V1 operations blocked
Step 8: Clean privilege migration achieved

**Result:** Clean permission migration

### Scenario 18: Front-Running Attack on Role Assignment ✅

Step 1: MONITOR_ADMIN adds a new monitor: `addMonitor(trustedAddress)`
Step 2: Attacker observes transaction in mempool
Step 3: Attacker attempts to front-run with two strategies:
    Strategy A: Compromise trustedAddress before assignment
    Strategy B: Pause contracts before monitor added
Step 4: If Strategy A: Requires private key compromise (unlikely)
Step 5: If Strategy B: Requires monitor role (attacker doesn't have)
Step 6: Original transaction executes as intended

**Result:** Limited impact, standard front-running risks

### Scenario 19: Cross-Chain Bridge Integration Security [!!]

Step 1: Future bridge contract planned for deployment
Step 2: Evaluate permission requirements
Step 3: Consider creating BRIDGE_ROLE? No.
Step 4: Bridge uses existing ASSET_MANAGER_ROLE
Step 5: Bridge deployed and registered in AddressBook
Step 6: Bridge granted ASSET_MANAGER_ROLE
Step 7: If bridge compromised, damage limited to:
    Asset operations only
    Cannot affect voting, monitors, or governance

**Result:** Role segregation provides security boundaries

### Scenario 21: Access Control Cache Poisoning ⚠️

Step 1: Third-party integrator caches accessController address
Step 2: Time passes, AccessController needs upgrade
Step 3: New AccessController deployed
Step 4: AddressBook updated with new address
Step 5: Third-party still uses cached old address
Step 6: Old AccessController has outdated role data
Step 7: Security decisions based on stale data
Step 8: Potential unauthorized access

**Result:** Contracts must not cache addresses - use AddressBook dynamically

### Scenario 22: Composite Attack - The Perfect Storm ✅

Step 1: Attacker compromises MONITOR_ADMIN (2/3 multisig)
Step 2: Rapidly adds 10 malicious monitors
Step 3: All monitors pause contracts simultaneously
Step 4: Attacker compromises CRON_JOB_ADMIN
Step 5: Attempts to add malicious cron jobs
Step 6: AccessController likely paused - additions BLOCKED
Step 7: Global admin responds:
    Assesses situation
    Unpauses AccessController
    Removes all malicious actors
    Re-establishes security
Step 8: During unpause window, attacker attempts more additions
Step 9: Race condition resolved by atomic transactions

**Result:** Recoverable with proper incident response

**Result:** Sustainable architecture

## Critical Findings Summary

### ✅ Strengths
1. **No deadlocks** - Atomic transactions prevent inconsistent states
2. **Clean permission model** - View functions work during pause
3. **Proper hierarchy** - Single global admin with clear delegation
4. **Role isolation** - Compromised roles have limited blast radius
5. **Pause granularity** - Can pause role management without breaking operations

### ⚠️ Operational Considerations
1. **Pre-assign emergency handlers** before any deployment
2. **Never cache addresses** - always use AddressBook dynamically  
3. **Epoch-end procedures** need careful timing with pauses
4. **Monitor role rotation** should be regular practice

## Security Verdict

The system is secure with **proper operational procedures**. 

## Recommended Operational Procedures

### Role Rotation Schedule
- **Monitors**: Quarterly rotation *(& rotate to fresh set after any incident)*
- **Cron Jobs**: Per epoch         *(remove after use)*
- **Admin roles**: Quarterly security review
- **Emergency Handlers**: Quarterly review & testnet drill

### Deployment Checklist
- [ ] Deploy AddressBook with correct global admin multisig
- [ ] Deploy AccessController with AddressBook reference
- [ ] Assign emergency exit handlers BEFORE any operations
- [ ] Set all contract addresses in AddressBook
- [ ] Verify all permission flows with test transactions
- [ ] Document all multisig addresses and signers

## Key Security Properties

### Permission Persistence
- Permission checks remain functional during pause
- No lockout scenarios for legitimate admin
- Clean recovery paths from all states
- View functions always accessible

### Blast Radius Containment
- Each role has limited scope
- Compromised roles cannot escalate privileges
- Role isolation prevents cascade failures
- Temporal roles (cron jobs) minimize exposure

### Emergency Response Plan

If a security incident is detected:
1. Monitors pause operational contracts
2. Assess severity and scope
3. If severe: Global admin pauses AccessController
4. If critical: Initiate freeze sequence (irreversible)

Document all actions taken

