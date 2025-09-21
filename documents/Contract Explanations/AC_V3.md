# AccessController: Frequency-Based Role Architecture

## Executive Summary

The AccessController implements a role-based access control system that organizes permissions according to operational frequency rather than traditional security hierarchies. This approach enables rapid response for routine operations while maintaining strict governance over strategic decisions.

**Core Innovation**: Administrative authority is distributed based on how frequently roles need to be updated—high-frequency operational roles get dedicated administrators to avoid bottlenecks, while low-frequency strategic roles remain under direct executive oversight.

Key Benefits:
- Operational teams can manage routine tasks without executive delays
- Strategic decisions receive appropriate governance review
- Security risks are contained through role isolation
- Emergency procedures remain available under all circumstances

## The Challenge of Secure Operations

Every decentralized protocol faces a fundamental tension: how do you enable rapid operational responses while maintaining strict security controls? 
- Too much bureaucracy creates dangerous delays. 
- Too little oversight invites catastrophic mistakes.

Traditional access control systems force an difficult choice:
- Grant broad permissions to operators (fast but risky)
- Require executive approval for everything (secure but slow)

**Understanding the challenge**

Traditional access control systems create operational bottlenecks by requiring executive approval for all privileged operations. 
When monitoring systems detect anomalies and need immediate response, or when automated systems require routine maintenance, the approval process can introduce dangerous delays.

Consider a scenario where automated monitoring detects a potential security issue at 2 AM. The team needs to rotate monitoring addresses or pause contracts immediately, but must wait for executive approval. This delay could allow problems to escalate.

The AccessController system addresses this tension through a simple observation that reshapes how we think about permissions.
It recognizes that not all privileged operations carry the same risk, or require the same level of oversight.

**Core Insight**
Not all administrative tasks are created equal.

*Some actions happen daily:*
- Rotating monitoring bots
- Processing scheduled operations
- Responding to alerts

*Others happen rarely:*
- Changing protocol fees
- Updating voting parameters
- Recovering emergency funds

The frequency of an action should determine its approval process.
This insight drives our entire security architecture. By matching administrative overhead to operational frequency, we achieve both speed and security without compromise.

## The Frequency-Based Approach
The system organizes roles according to how frequently they need to be managed, creating two distinct paths:

**High-Frequency Operations**
- Monitoring and pause functions: enable immediate response to issues
- Automated system management: support routine maintenance
- Bot rotation: ensure operational reliability
- All require dedicated administrators for rapid, bottleneck-free action

**Low-Frequency Strategic Operations**
- Protocol parameter updates: Economic decisions requiring careful consideration
- Asset management: Treasury operations with financial implications
- Emergency procedures: Crisis response requiring ultimate authority
These operations benefit from centralized executive oversight.
This separation creates operational efficiency while maintaining appropriate governance controls.


| High-Frequency Operations                | Strategic Operations            |
|------------------------------------------|---------------------------------|
| Bot rotation, monitoring                 | Protocol parameter changes      |
| Epoch processing                         | Asset management decisions      |
| Emergency responses                      | Governance modifications        |
| **Need:** Instant response               | **Need:** Deliberate review     |
| **Solution:** Dedicated admins           | **Solution:** Executive control |


## Innovation and Design Philosophy

The old way—forcing all privileged ops through executive approval—creates bottlenecks, slows routine work, and delays emergency response. 

Our frequency-based model fixes this: high-frequency roles (like bot rotation and monitoring) get dedicated admins for rapid, frictionless ops; low-frequency, high-impact roles (like protocol changes and asset management) stay under executive control. 

Emergency powers are always available, not stuck in red tape.

This structure lets teams handle daily ops fast, keeps critical decisions under tight review, and ensures the global admin can always override if needed. The result: scalable permissions, strong security boundaries, and governance that actually fits how protocols run.

The AccessController introduces a fundamental shift from traditional role-based access control by recognizing that administrative overhead should match operational frequency.

**Traditional Approach Limitations:**
- All privileged operations require executive approval
- Routine maintenance becomes governance bottleneck
- Security hierarchy doesn't reflect operational reality
- Emergency response may be delayed by approval processes
**Frequency-Based Innovation:**
- High-frequency operational roles get dedicated administrators
- Low-frequency strategic roles remain under direct executive oversight
- Administrative authority matches operational needs
- Emergency capabilities remain immediately available

This approach creates a system that is both operationally efficient and strategically controlled. Teams can manage routine operations without bureaucratic delays, while critical decisions receive appropriate governance review. The global admin retains ultimate override capability, ensuring no operational issue can permanently compromise system control.

The result is a permission system that scales with operational complexity while maintaining security boundaries, providing the foundation for sustainable protocol governance.

**Core principles:**
- Practical hierarchy: Roles that change frequently have dedicated admins
- Strategic oversight: Rare, high-impact decisions remain with executives
- Override safety: Global admin retains ultimate control
- Multi-sig everything: No single points of failure

**Key Benefits:**
- Operational teams manage routine tasks without executive delays
- Strategic decisions undergo rigorous governance review
- Role isolation compartmentalizes security risks
- Emergency procedures are always accessible

```
*TLDR: The system is optimized for two key factors:*
1. How frequently roles (and their related fns) need to be called
2. How often privileged/admin actions are performed
```

# Role Architecture Structure

The system organizes roles into four tiers based on their operational frequency and risk profile:

```lua
DEFAULT_ADMIN_ROLE (Global Admin)
├── MONITOR_ADMIN_ROLE ──────────► MONITOR_ROLE
├── CRON_JOB_ADMIN_ROLE ─────────► CRON_JOB_ROLE
├── PAYMENTS_CONTROLLER_ADMIN_ROLE
├── VOTING_CONTROLLER_ADMIN_ROLE
├── ASSET_MANAGER_ROLE
└── EMERGENCY_EXIT_HANDLER_ROLE
```

```lua
DEFAULT_ADMIN_ROLE          (GlobalAdmin: Senior Leadership)     
├── Operational Admins      (Manage frequent tasks)
│   ├── MONITOR_ADMIN_ROLE  (Controls pause bots)               [DevOps: 2/3 Multi-sig]
│   │   └── MONITOR_ROLE    (Calls pause across contracts)
│   └── CRON_JOB_ADMIN_ROLE (Controls automation)   
│       └── CRON_JOB_ROLE   (Periodic epoch ops & pool management)
│   
└── Strategic Roles         
    ├── PAYMENTS_CONTROLLER_ADMIN_ROLE  [Parameter updates]
    ├── VOTING_CONTROLLER_ADMIN_ROLE    [Parameter updates]
    ├── ASSET_MANAGER_ROLE              [Asset management]
    └── EMERGENCY_EXIT_HANDLER_ROLE     [Emergency functions]

```

Admin roles can add and remove addresses for the corresponding roles they govern.

**Why dedicated admins**
- These operations happen frequently and can't wait for executives.
- Risk Mitigation 

## Risk Mitigation Example
If an operational admin key is compromised:
- Attacker gains control of bot management.
- Protocol parameters remain inaccessible due to role isolation.
- Executive override cannot be blocked because of enforced hierarchy.
- Attack impact is limited to operational disruption; funds remain secure.
- Global admin can revoke compromised access and restore normal service.

<span style="color:red">__The blast radius is contained by design.__</span>

## Multi-sig config

```lua
DEFAULT_ADMIN_ROLE                                  (SeniorLeadership: 4/7 Multi-sig)
├── MONITOR_ADMIN_ROLE ──────────► MONITOR_ROLE     (DevOps1: 2/3 Multi-sig)
├── CRON_JOB_ADMIN_ROLE ─────────► CRON_JOB_ROLE    (DevOps2: 2/3 Multi-sig)
├── PAYMENTS_CONTROLLER_ADMIN_ROLE                  (DevOps3: 2/3 Multi-sig)
├── VOTING_CONTROLLER_ADMIN_ROLE                    (DevOps4: 2/3 Multi-sig)                                               
├── ASSET_MANAGER_ROLE                              (DatTeam: 2/3 Multi-sig)
└── EMERGENCY_EXIT_HANDLER_ROLE                     (DevOps5: 2/3 Multi-sig) 
```

Cannot have a common DevOps multi-sig address across the board, as thay would concentrate risk - not silo it.

EMERGENCY_EXIT_HANDLER_ROLE
- needs to be a script to make repeatedly calls of relevant emergency exit functions
- the DEFAULT_ADMIN_ROLE will grant EMERGENCY_EXIT_HANDLER_ROLE to a EOA address attached for to a script.
- the script executes till completion
- then remove it [or address can revoke itself]

```
Executive Team → DEFAULT_ADMIN_ROLE → Grant/Revoke strategic roles
DAT Team       → ASSET_MANAGER_ROLE → Execute asset withdrawals
DevOps Team    → PAYMENTS_CONTROLLER_ADMIN_ROLE → Update protocol parameters
DevOps Team    → VOTING_CONTROLLER_ADMIN_ROLE → Update voting parameters
DevOps Team    → EMERGENCY_EXIT_HANDLER_ROLE → Emergency asset recovery
```

## Security Model & Risk Matrix

### Defense Layers

**Layer 1: Role Isolation**
- Operational roles can't touch strategic functions 
- Strategic roles can't interfere with operations
- Clean boundaries prevent cascade failures
I.e. monitor/cron admins are siloed from contract admins, and vice versa.

**Layer 2: Multi-signature Protection**
- Every admin role requires multi-sig 
- Thresholds match risk levels

Exception: multi-sig would add EOA addresses to execute automated tasks.
- For example, emergencyExit, or batch creation of pools.
- But these would be added and then removed. Multi-sig remains constant. 

**Layer 3: Override Mechanisms**
- Global admin can intervene anywhere
- Emergency procedures bypass normal flow
- No permanent lockouts possible

### Attack Vectors

| Attack Vector         | Likelihood | Impact    | Mitigation                        |
|-----------------------|------------|-----------|-----------------------------------|
| Bot compromise        | Medium     | Limited   | Role isolation, quick rotation    |
| Admin key loss        | Low        | High      | Multi-sig, global override        |
| Governance capture    | Low        | Critical  | Executive override, timelock      |
| Operational delay     | Medium     | Medium    | Dedicated admins, automation      |

### **Risk Level Matrix**

                    RISK LEVEL: LOW ◄────────────────────────────────► HIGH
┌─────────────────┬─────────────────┬─────────────────┬─────────────────┐
│ OPERATIONAL     │ ADMINISTRATIVE  │ STRATEGIC       │ EMERGENCY       │
│ (High Freq)     │ (Med Freq)      │ (Low Freq)      │ (Crisis Only)   │
├─────────────────┼─────────────────┼─────────────────┼─────────────────┤
│ MONITOR_ROLE    │ MONITOR_ADMIN   │ GLOBAL_ADMIN    │ EMERGENCY_EXIT  │
│ • pause()       │ • Manage        │ • unpause()     │ • emergencyExit │
│ • Automated     │   monitors      │ • freeze()      │ • Asset exfil   │
│   alerts        │ • Role mgmt     │ • Ultimate      │ • Kill switch   │
│                 │                 │   authority     │                 │
├─────────────────┼─────────────────┼─────────────────┤                 │
│ CRON_JOB_ROLE   │ CRON_JOB_ADMIN  │ ASSET_MANAGER   │                 │
│ • createPool()  │ • Manage cron   │ • withdrawUncl- │                 │
│ • finalizeEpoch │   jobs          │   aimed()       │                 │
│ • createLockFor │ • Role mgmt     │ • Asset ops     │                 │
│ • Automated     │                 │                 │                 │
│   operations    │                 │                 │                 │
├─────────────────┼─────────────────┼─────────────────┤                 │
│                 │                 │ PAYMENTS_ADMIN  │                 │
│                 │                 │ • Config mgmt   │                 │
│                 │                 │ • Fee settings  │                 │
│                 │                 │                 │                 │
│                 │                 │ VOTING_ADMIN    │                 │
│                 │                 │ • Voting config │                 │
│                 │                 │ • Pool mgmt     │                 │
└─────────────────┴─────────────────┴─────────────────┴─────────────────┘

**System Architecture Flow**

┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            MOCA VALIDATOR ECOSYSTEM                                 │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐                  │
│  │   AddressBook   │◄───┤ AccessController │───►│ All Contracts  │                  │
│  │  (Immutable)    │    │  (Upgradeable)  │    │  (Query ACL)    │                  │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘                  │
│           │                       │                                                 │
│           ▼                       ▼                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐                  │
│  │PaymentsController│   │ VotingController │   │VotingEscrowMoca │                  │
│  │                 │◄──►│                 │◄──►│                 │                  │
│  │ • Verification  │    │ • Vote Mgmt     │    │ • Lock Mgmt     │                  │
│  │ • Fee Mgmt      │    │ • Reward Dist   │    │ • Delegation    │                  │
│  │ • Subsidy Calc  │    │ • Epoch Mgmt    │    │ • veToken       │                  │
│  └─────────────────┘    └─────────────────┘    └─────────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────────────┘

## Detailed Role Specifications

🔴 **Tier 1: Supreme Governance**
`DEFAULT_ADMIN_ROLE` (Global Admin)
- Override Power: Can override ANY role decision
- Purpose: Final authority and emergency failsafe
- Frequency: Very rare (emergencies, hierarchy changes)

*Why this matters*: This role serves as the ultimate authority, ensuring no operational issue can permanently lock out executive control.

`EMERGENCY_EXIT_HANDLER_ROLE`
- Purpose: Last-resort asset recovery when system is frozen
- Holders: Emergency response team (2-of-3 multi-sig)
- Activation: Only after system freeze by global admin
Rationale: Emergency functions must be available but tightly controlled

🟡 **Tier 2: Strategic Roles (Low Frequency, High Impact)**

`PAYMENTS_CONTROLLER_ADMIN_ROLE`
- Controls: protocol fees, subsidy percentages, and payment configurations
- Impact: Direct economic parameters
- Updates: Governance proposals only
Rationale: Economic parameters require deliberate review and approval

`VOTING_CONTROLLER_ADMIN_ROLE`
- Controls: Voting parameters, delegate fees, registration requirements
- Impact: Governance mechanics
- Updates: Following community decisions
Rationale: Voting mechanics affect protocol governance; require careful consideration

`ASSET_MANAGER_ROLE`
- Function: Withdraw protocol fees and unclaimed assets
- Schedule: Monthly/quarterly treasury operations
Rationale: Asset movements require treasury oversight and approval

__**The innovation: Dedicated admins for frequent operations eliminate governance bottlenecks while maintaining multi-sig security.**__


🟢 **Tier 3: High-Frequency Operational Admin Roles**
*High-frequency operational needs demand dedicated admins*

`MONITOR_ADMIN_ROLE` → `MONITOR_ROLE`
- Admin controls: Bot address rotation
- Frequency: High (bot rotation, address management)
- Security: Multiple redundant bots prevent single failure
Rationale: Bots need frequent updates without executive delays

`CRON_JOB_ADMIN_ROLE` → `CRON_JOB_ROLE`
- Admin controls: Automation address management
- Automation functions:
    - Epoch finalization (bi-weekly)
    - Subsidy deposits
    - Pool creation/removal
Rationale: Routine operations can't wait for executives; hence dedicated admins.

🟢 **TIER 4: High-Frequency Operational Roles**
*Direct execution roles for automated systems*

**`MONITOR_ROLE`**
- Functions: pause() across all contracts
- Addresses: Multiple monitoring bots (EOAs)
- Frequency: Rare but critical (emergency pause)
- Security: Monitored by multiple independent bots for redundancy

**`CRON_JOB_ROLE`**
- Functions:
    - VotingEscrowMoca: createLockFor()
    - VotingController: depositEpochSubsidies(), finalizeEpochRewardsSubsidies()
    - VotingController: createPool(), removePool()
- Addresses: Automation EOAs (bi-weekly rotation)
- Frequency: High (every 2 weeks for epoch operations)
- Security: Addresses added temporarily, then removed after operations

**Quick Reference**

| Frequency      | Role Type     | Example Functions                | Management         |
|----------------|---------------|----------------------------------|--------------------|
| Daily/Weekly   | Operational   | Bot rotation, monitoring         | Dedicated admins   |
| Bi-weekly      | Automated     | Epoch operations                 | Dedicated admins   |
| Monthly        | Administrative| Asset withdrawals                | Global admin       |
| Rare           | Strategic     | Parameter updates                | Global admin       |
| Emergency      | Crisis        | System freeze, recovery          | Global admin       |



# Operational Model + Workflows

## Three-Tiered Operational Model

1. **Autonomous Operations**
   - Monitoring bots pause contracts on anomalies
   - Automated scripts handle bi-weekly epochs
   - Bot addresses rotate frequently
   - *No executive sign-off needed*

2. **Governed Strategic Actions**
   - Fee changes, voting updates, treasury withdrawals
   - *Require executive multi-signature approval*

3. **Protected Emergency Controls**
   - System-wide freeze, asset recovery, overrides
   - *Strictly limited, rarely used*

**Frequency Principle in Action**

- *Bot Replacement*: Ops team swaps monitoring bots instantly—no executive delay.
- *Fee Adjustment*: Proposals undergo executive review and multi-sig approval before changes.

This structure ensures fast routine ops, deliberate governance, and robust emergency safeguards—no bottlenecks, no unchecked power.

## **Routine Epoch Processing (Every 2 Weeks)**

>*TODO: missing the bit about withdrawing from PaymentsController*

```bash
Time T-1: Preparation
└── Dev team adds EOA address to `CRON_JOB_ROLE`

Time T: Execution
├── Bot calls `depositEpochSubsidies()`
├── Bot calls `finalizeEpochRewardsSubsidies()`
└── Dev team revokes role from EOA address

Time T+1: Verification
└── Back-end confirms successful execution
```
No executive involvement required; no delays or bottlenecks.

## **Contract Parameter Updates**

```bash
Step 1: Deliberation
└── Discussion on updates to contract parameters

Step 2: Review
├── Technical analysis
└── Economic modeling

Step 3: Approval + Execution
├── Relevant contact admin multi-sig coordination (e.g. VOTING_CONTROLLER_ADMIN_ROLE)
└── Parameter update execution

Step 4: Assessment 
└── Verify changes are in-line with original intention
```
Deliberate process for high-impact changes.

## **Emergency Response (If Needed)**

```bash
Detection → Pause → Assessment → Resolution 

1. Monitor bot detects anomaly
2. Automatic pause (MONITOR_ROLE)
3. Team investigates issue
4. Executive decision on response 
5. Normal operations resume or emergency procedures activate [`freeze` + `emergencyExit`]
```

## **Other ad-hoc operations (No Executive approval required)**
```
Dev/Ops Team → MONITOR_ADMIN_ROLE → Add/Remove monitor bots
Dev/Ops Team → CRON_JOB_ADMIN_ROLE → Add/Remove automation addresses
Monitor Bots → MONITOR_ROLE → Pause contracts if issues detected
Automation Scripts → CRON_JOB_ROLE → Execute bi-weekly epoch operations
```



# Why This Design Works [Benefits and Impact]

The traditional approach forces every permission change through executive approval. This creates dangerous bottlenecks - imagine waiting for 4 executives to coordinate just to rotate a monitoring bot that detected suspicious activity.

Our frequency-based hierarchy solves this elegantly. High-frequency operations get nimble management. Strategic decisions get appropriate oversight. The system self-organizes around actual operational needs rather than theoretical security models.

Operational Efficiency
✅ No Bottlenecks: High-frequency operations proceed without executive approval [Bot rotation in minutes]
✅ Automated Operations: Epoch operations proceed without delays [Epoch operations run automatically]
✅ Clear Boundaries: Chinese walls between operational and strategic functions

Security Robustness
✅ Role Isolation: Compromise of one admin doesn't affect other functions
✅ Override Capability: Global admin retains ultimate control
✅ Appropriate Oversight: Strategic decisions require executive review
✅ Multi-signature Protection: All roles require distributed approval

Governance Clarity
✅ Frequency-Based Logic: Administrative authority matches operational needs
✅ Clear Responsibilities: Each role has specific, limited permissions
✅ Audit Trail: All role changes tracked through events
✅ Operational Transparency: Clear workflows for different operation types

# Summary: Elegant Security Through Operational Reality

The AccessController represents a fundamental rethink of access control. Instead of forcing operations into a rigid hierarchy, it molds permissions around actual usage patterns.

The result:
- Daily operations flow without friction
- Strategic decisions receive appropriate oversight
- Security remains uncompromised
- The system scales with the protocol
By aligning administrative overhead with operational frequency, we've created a security model that teams actually want to use—because it makes their jobs easier, not harder.

# Deployment Process
1. Deploy AddressBook → Set globalAdmin (executive multisig)
2. Deploy AccessController → Retrieves globalAdmin from AddressBook
3. Deploy other contracts → Reference AccessController for permissions
4. Initial role assignment:
    - Grant MONITOR_ADMIN_ROLE to dev/ops multisig
    - Grant CRON_JOB_ADMIN_ROLE to dev/ops multisig
    - Grant strategic roles directly to appropriate multi-sigs


# Appendix

## Function-to-Role Mapping

**VotingEscrowMoca Contract**
- pause(): MONITOR_ROLE
- unpause(), freeze(): DEFAULT_ADMIN_ROLE (Global Admin)
- createLockFor(): CRON_JOB_ROLE
- emergencyExit(): EMERGENCY_EXIT_HANDLER_ROLE

**VotingController Contract**
- pause(): MONITOR_ROLE
- unpause(), freeze(): DEFAULT_ADMIN_ROLE (Global Admin)
- createPool(), removePool(): CRON_JOB_ROLE
- depositEpochSubsidies(), finalizeEpochRewardsSubsidies(): CRON_JOB_ROLE
- Parameter setters: VOTING_CONTROLLER_ADMIN_ROLE
- Asset withdrawals: ASSET_MANAGER_ROLE
- emergencyExit(): EMERGENCY_EXIT_HANDLER_ROLE

**PaymentsController Contract**
- pause(): MONITOR_ROLE
- unpause(), freeze(): DEFAULT_ADMIN_ROLE (Global Admin)
- Parameter updates: PAYMENTS_CONTROLLER_ADMIN_ROLE
- Fee withdrawals: ASSET_MANAGER_ROLE
- Emergency exits: EMERGENCY_EXIT_HANDLER_ROLE