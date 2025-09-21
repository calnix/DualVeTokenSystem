# AccessController: Frequency-Based Role Architecture

## At a Glance
- Sophisticated permission system managing access and actions across the Moca protocol
- Administrative overhead scales with operational frequency—frequent tasks have dedicated managers
- Eliminates operational bottlenecks while maintaining security through clear role separation

## Executive Summary

The AccessController implements a **frequency-based role hierarchy** that adapts administrative authority to operational reality. 
It recognizes that some roles need frequent updates (like monitoring bots), while others rarely change (like protocol parameters).

By assigning *dedicated administrators* to high-frequency roles (like monitoring bots) and reserving executive oversight for low-frequency, strategic roles (like protocol parameters), it eliminates daily bottlenecks while maintaining strict governance where it matters most.

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


## Design Philosophy

**Core Innovation**

Authority is distributed based on how frequently roles need management/execution, not just security sensitivity. 
High-frequency operational roles get dedicated administrators for rapid response, while low-frequency strategic roles remain under direct executive oversight (senior leadership).

Traditional access control creates unnecessary friction. A monitoring bot that needs daily rotation shouldn't require the same approval process as changing protocol fees. Our system recognizes this fundamental difference.

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

__*Why dedicated admin*:__
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

### Multi-sig config

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




```?
The Three Operational Layers
1. Daily Operations (Autonomous)
- Monitoring systems detect anomalies and pause contracts
- Automated scripts process bi-weekly epochs
- Bot addresses rotate regularly for security
- *No executive approval required for these actions*

2. Strategic Decisions (Governed)
Fee structure changes
-Voting mechanism updates
-Treasury withdrawals
-*Requires executive multi-signature*

3. Emergency Controls (Protected)
-System-wide freeze capabilities
-Asset recovery mechanisms
-Override functions
-*Tightly controlled, rarely used*

**Understanding the Frequency Principle**
Consider two scenarios:

Scenario A: A monitoring bot needs replacement due to key rotation
-Traditional system: Request executive approval → Wait for signatures → Deploy new bot
-Our system: Operations team updates immediately → System continues uninterrupted

Scenario B: Protocol fees need adjustment
-Traditional system: Admin makes change → Hope it was reviewed
-Our system: Proposal submitted → Executive review → Multi-signature approval → Implementation

The architecture naturally enforces appropriate oversight without creating bottlenecks.
```

**Quick Reference**

| Frequency      | Role Type     | Example Functions                | Management         |
|----------------|---------------|----------------------------------|--------------------|
| Daily/Weekly   | Operational   | Bot rotation, monitoring         | Dedicated admins   |
| Bi-weekly      | Automated     | Epoch operations                 | Dedicated admins   |
| Monthly        | Administrative| Asset withdrawals                | Global admin       |
| Rare           | Strategic     | Parameter updates                | Global admin       |
| Emergency      | Crisis        | System freeze, recovery          | Global admin       |


# Operational Workflows

**Routine Epoch Processing (Every 2 Weeks)**

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

**Contract Parameter Updates**

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

**Emergency Response (If Needed)**

```bash
Detection → Pause → Assessment → Resolution 

1. Monitor bot detects anomaly
2. Automatic pause (MONITOR_ROLE)
3. Team investigates issue
4. Executive decision on response 
5. Normal operations resume or emergency procedures activate [`freeze` + `emergencyExit`]
```

### Daily Operations (No Executive approval required)
```
Development Team → MONITOR_ADMIN_ROLE → Manage monitoring bots
Development Team → CRON_JOB_ADMIN_ROLE → Manage automation addresses
Monitoring Bots → MONITOR_ROLE → Emergency pause if issues detected
Automation Scripts → CRON_JOB_ROLE → Execute scheduled protocol operations
```

### Strategic Operations (Executive Approval Required)
```
Executive Team → DEFAULT_ADMIN_ROLE → Grant/revoke strategic roles
Product Team → Contract Admin Roles → Update protocol parameters
Treasury Team → ASSET_MANAGER_ROLE → Execute asset withdrawals
Emergency Team → EMERGENCY_EXIT_HANDLER_ROLE → Crisis recovery
```
### Emergency Response Flow
```
1. Monitor Detection → MONITOR_ROLE → Immediate system pause
2. Assessment Phase → MONITOR_ADMIN_ROLE → Coordinate response
3. Strategic Decision → DEFAULT_ADMIN_ROLE → Approve resolution approach
4. Recovery Execution → EMERGENCY_EXIT_HANDLER_ROLE → Asset recovery if needed
```

# Why This Design Works

**For Operations Teams**
- Immediate action: update bots and automation without waiting
- Clear boundaries: know exactly what you can and cannot do
- Reduced fatigue: no unnecessary approval requests

**For Executives**
- Focus on strategy: Executives only review high-impact decisions
- Maintain control: Override capability always available
- Reduce noise: No rubber-stamping of routine changes

**For Security**
- Principle of Least Privilege: Grant only the minimum permissions required
- Defense in Depth: Layer multiple, independent security controls
- Clear Audit Trail: Track and attribute every action for accountability

**For the Protocol**
- Operational Excellence: No delays in routine maintenance
- Strategic Governance: Important changes get proper review
- Crisis Readiness: Emergency procedures ready but protected


# Deployment Process
1. AddressBook Deployment: Establishes the global administrator address
2. AccessController Deployment: Retrieves administrator from AddressBook
3. Protocol Contract Deployment: Reference AccessController for permissions
4. Configure initial role assignments via the global admin