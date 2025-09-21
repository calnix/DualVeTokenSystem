# AccessController: Frequency-Based Role Architecture

## Executive Summary

The AccessController implements a **frequency-based role hierarchy** that aligns administrative authority with operational demands. This design eliminates bottlenecks in daily operations while maintaining executive oversight for strategic decisions.

**The Innovation:** 
- Rather than traditional static hierarchies, permissions are assigned as a pair-wise evaluation on frequency of calls and its corresponding impact: {Freq. function call, Impact of fn call}. 
- High-frequency operational roles have dedicated admins for instant action.
- Low-frequency, high-impact roles fall directly under global admin control.

Additionally, authority is mapped to how often roles need to be updated. High-frequency operational roles have dedicated admins to add/remove addresses [i.e. risk bots, cron jobs].

**Key Benefits:**
- Operational efficiency: Teams manage routine tasks without executive delays.
- Strategic oversight: Critical decisions undergo rigorous governance review.
- Security containment: Role isolation limits the impact of potential compromises.
- Emergency readiness: Emergency procedures remain immediately accessible.

## The Challenge of Secure Operations

Decentralized protocols often face a tension between enabling rapid responses and enforcing security controls. 
- Traditional systems typically require executive approval for all privileged operations, leading to delays in routine maintenance or emergency responses. 
- This creates bottlenecks where operational needs outpace governance processes, potentially exposing systems to risks.
- Consequently, risk updates execution always lag behind.

The core issue is the mismatch between rigid hierarchies and dynamic operational requirements.
- High-frequency and low-impact tasks such as bot management or automated processes need immediate action
- Low-frequency and high-impact changes like contract params updates benefit from deliberate review. 

A system that treats all operations uniformly can hinder efficiency without necessarily improving security.

## Core Innovation: Frequency-Based Access Control

The AccessController addresses this by organizing roles according to how frequently they need to be managed, creating distinct paths for operations:

- High-Frequency Operations: Include monitoring, automation, and routine maintenance. These are assigned dedicated administrators to avoid delays, ensuring rapid responses without compromising security.
- Low-Frequency Strategic Operations: Cover protocol parameters, asset management, and emergency procedures. These remain under executive oversight to allow for careful consideration.
- Emergency capabilities stay accessible, preventing lockouts.

**TLDR:**
- Approval friction should scale with operational frequency. Match admin overhead to how often a role is used, and you get both speed and security.
- Therefore, a frequency-based approach.

## Key Insight

The key insight is recognizing that not all administrative tasks require the same level of oversight. 
- This reshapes how we think about permissions. 
- Not all privileged actions are equal
    - Some are daily (bot rotation, scheduled ops, alert response).
    - Others are rare, ad-hoc or situational (fee changes, voting config, emergency recovery). The approval process should match the frequency and risk.

By assigning authority based on a pair-wise evaluation of frequency and impact, the system reduces friction for common operations while ensuring safeguards for critical ones. 

## The Innovation: Frequency-Based Approach

Roles are split by how often they need to be managed:

**High-Frequency Operations**
- Monitoring/pause: instant response to issues
- Automation: routine maintenance
- Bot rotation: operational reliability
- All require dedicated admins for fast, bottleneck-free action

**Low-Frequency Strategic Operations**
- Protocol parameter updates: economic/strategic decisions
- Asset management: treasury ops
- Emergency procedures: crisis response
- These stay under centralized executive oversight

This separation delivers operational efficiency and strong governance.

| High-Frequency Operations                | Strategic Operations            |
|------------------------------------------|---------------------------------|
| Bot rotation, monitoring                 | Protocol parameter changes      |
| Epoch processing                         | Asset management decisions      |
| Emergency responses                      | Governance modifications        |
| **Need:** Instant response               | **Need:** Deliberate review     |
| **Solution:** Dedicated admins           | **Solution:** Executive control |

## Design Philosophy

Old model: All privileged ops go through execs—slow, bottle-necked, risky in emergencies.

Frequency-based model:  
- High-frequency ops (bot rotation, monitoring) → dedicated admins, instant action  
- Low-frequency, high-impact ops (protocol changes, asset management) → execs only  
- Emergency powers always available, never stuck in red tape

This lets teams move fast on daily ops, keeps critical decisions under review, and ensures global admin can always override. The result: scalable, secure, and operationally realistic permissions.

**Traditional Limitations:**
- Exec approval for everything
- Routine ops bottle-necked
- Security model ignores operational reality
- Emergency response tend to be delayed or bottle-necked

**Frequency-Based Solution:**
- High-frequency roles = dedicated admins
- Strategic roles = exec oversight
- Authority matches operational need
- Emergency powers always on tap

This model is both efficient and secure. Routine ops run without bureaucracy; critical changes get real governance. Global admin always has the override.

**Core Principles:**
- Practical hierarchy: frequent-change roles = dedicated admins
- Strategic oversight: rare, high-impact = execs only
- Override safety: global admin always in control
- Multi-sig everywhere: no single point of failure

**Key Benefits:**
- Ops teams move fast, no exec bottlenecks
- Strategic changes get real review
- Role isolation contains risk
- Emergency actions always possible

---

# Role Architecture Structure

The system organizes roles into four tiers based on operational frequency and risk profile.

**Roles: Overview**
```lua
`DEFAULT_ADMIN_ROLE` 
├── MONITOR_ADMIN_ROLE ──────────► MONITOR_ROLE
├── CRON_JOB_ADMIN_ROLE ─────────► CRON_JOB_ROLE
├── PAYMENTS_CONTROLLER_ADMIN_ROLE
├── VOTING_CONTROLLER_ADMIN_ROLE
├── ASSET_MANAGER_ROLE
└── EMERGENCY_EXIT_HANDLER_ROLE
```

**Roles: Hierarchy breakdown**
```lua
DEFAULT_ADMIN_ROLE              (GlobalAdmin: Senior Leadership)     
├── Operational Admins          (Manage frequent tasks)
│   ├── MONITOR_ADMIN_ROLE      (Controls pause bots)               
│   │   └── MONITOR_ROLE        (Calls pause across contracts)
│   └── CRON_JOB_ADMIN_ROLE     (Controls automation)   
│       └── CRON_JOB_ROLE       (Periodic epoch ops & pool management)
│   
└── Strategic Roles         
    ├── PAYMENTS_CONTROLLER_ADMIN_ROLE  [Parameter updates]
    ├── VOTING_CONTROLLER_ADMIN_ROLE    [Parameter updates]
    ├── ASSET_MANAGER_ROLE              [Asset management]
    └── EMERGENCY_EXIT_HANDLER_ROLE     [Emergency functions]

```

- Admin roles have authority to add or remove addresses for the specific roles they oversee.
- Monitor and Cron roles have dedicated admins serving as structural "middle-managers"; the rest are managed directly by `DEFAULT_ADMIN_ROLE`.
- In turn, `DEFAULT_ADMIN_ROLE` supervises `MONITOR_ADMIN_ROLE` & `CRON_JOB_ADMIN_ROLE`.

**Why dedicated admins?**
- Frequent operational changes shouldn't bottleneck on executive approval. *[i.e. epoch ops, bot changes]*
- Tiering for these high-frequency roles, creates isolation to reduces risk and contain damage in the event of exploit.

## Example

If an operational admin is compromised:
- Attacker can control bot operations, but not protocol parameters.
- Role isolation prevents escalation beyond their scope.
- Executive override remains available due to enforced hierarchy.
- Impact is limited to operational disruption; funds and core settings stay protected.
- Global admin can promptly revoke access and restore normal operations.

<span style="color:red">__Blast radius is intentionally limited by design.__</span>


**Roles: Multi-sig Configuration**

```lua
DEFAULT_ADMIN_ROLE                                  (SeniorLeadership: 4/7 Multi-sig)
├── MONITOR_ADMIN_ROLE ──────────► MONITOR_ROLE     (DevOps1: 2/3 Multi-sig)
├── CRON_JOB_ADMIN_ROLE ─────────► CRON_JOB_ROLE    (DevOps2: 2/3 Multi-sig)
├── PAYMENTS_CONTROLLER_ADMIN_ROLE                  (DevOps3: 2/3 Multi-sig)
├── VOTING_CONTROLLER_ADMIN_ROLE                    (DevOps4: 2/3 Multi-sig)                                               
├── ASSET_MANAGER_ROLE                              (DatTeam: 2/3 Multi-sig)
└── EMERGENCY_EXIT_HANDLER_ROLE                     (DevOps5: 2/3 Multi-sig) 
```
Avoid using a single DevOps multi-sig address for all roles—this would centralize risk rather than isolate it.

**Roles: Responsible Actors**
```
SeniorLeadership → DEFAULT_ADMIN_ROLE → Grant/Revoke strategic roles
DAT Team         → ASSET_MANAGER_ROLE → Execute asset withdrawals
DevOps Team      → PAYMENTS_CONTROLLER_ADMIN_ROLE, VOTING_CONTROLLER_ADMIN_ROLE, EMERGENCY_EXIT_HANDLER_ROLE 
```

# Risk Matrix, Security Model, Defenses

**System Architecture Flow**
```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                            MOCA ECOSYSTEM                                           │
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
```

### **Risk Level Matrix**

```
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
```
**Attack Vectors**

```lua
| Attack Vector           | Likelihood | Impact   | Mitigation                         |
|-------------------------|------------|----------|------------------------------------|
| Bot compromise          | Medium     | Limited  | Role isolation, quick rotation     | [monitor,cron]
| Admin role compromised  | Low        | High     | Multi-sig, global override         | [unless GlobalAdmin multi-sig was infiltrated]
```

## Defense Layers

1. Role Isolation: Operational roles cannot access strategic functions, and vice versa; preventing cascade failures.
2. Multi-Signature Protection: All admin roles require distributed approval, with thresholds aligned to risk levels.
3. Override Mechanisms: Global admin can intervene in any role, ensuring no permanent lockouts.

This layered approach contains risks while allowing flexible operations, demonstrating the system's robustness in handling diverse scenarios.

**Exception:**
Some admin roles would be granted to EOA addresses *temporarily* to execute automated tasks.
- For example, emergencyExit, or batch creation of pools.
- Upon completion, EOA role to be revoked.

Regardless, each admin role will never lose it's multi-sig; which is its anchor.

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



# Operational Model + Execution Workflows

The model supports three tiers of operations, each with tailored processes.

## Three-Tiered Operational Model [*Frequency Principle in Action*]

1. **Autonomous Operations**: Monitoring bots handle alerts and pauses; automated scripts manage epochs. No executive sign-off required.
2. **Governed Strategic Actions**: Contract updates and parameter changes require review and multi-signature approval.
3. **Protected Emergency Controls**: Freezes and recoveries activate only under strict conditions.

This structure ensures fast routine ops, deliberate governance, and robust emergency safeguards; no bottlenecks or unchecked power.

## Execution flows

### 1. **Withdrawing USD8 from PaymentsController (Every 2 Weeks)**

```lua
Time T-1: Preparation
└── Dev team adds EOA address to CRON_JOB_ROLE
Time T: Execution
├── Bot calls depositEpochSubsidies()
├── Bot calls finalizeEpochRewardsSubsidies()
├── Bot withdraws protocol fees and voting fees in USD8
└── Dev team revokes role from EOA address [via dedicated admin]
Time T+1: Verification
└── Back-end confirms successful execution
```
Proceed to convert USD8 to esMoca and deposit into VotingController.

### 2. **Routine Epoch Processing (Every 2 Weeks)**

```lua
Time T-1: Preparation
└── Dev team adds EOA address to `CRON_JOB_ROLE`

Time T: Execution
├── Bot calls `depositEpochSubsidies()`
├── Bot calls `finalizeEpochRewardsSubsidies()`
└── Dev team revokes role from EOA address [via dedicated admin]

Time T+1: Verification
└── Back-end confirms successful execution
```
No executive involvement required; no delays or bottlenecks.

### 3. **Arbitrary Contract Parameter Updates**

```bash
Step 1: Deliberation
└── Discussion on updates to contract parameters

Step 2: Review
├── Technical analysis
└── Economic modeling

Step 3: Approval + Verification + Execution
├── Relevant contact admin multi-sig coordination (e.g. VOTING_CONTROLLER_ADMIN_ROLE)
├── Ensure all multi-sig signers, have signed. 
├── Internal security consultant to verify before submitting for execution
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

EMERGENCY_EXIT_HANDLER_ROLE Execution
Time T-1: Preparation
└── DEFAULT_ADMIN_ROLE grants EMERGENCY_EXIT_HANDLER_ROLE to EOA address attached to script
Time T: Execution
└── Script makes repeated calls to relevant emergency exit functions until completion
Time T+1: Verification
└── Role is revoked (by DEFAULT_ADMIN_ROLE or address self-revokes)
```

## **Other ad-hoc operations (No Executive approval required)**

```bash
Dev/Ops Team → MONITOR_ADMIN_ROLE → Add/Remove monitor bots
Dev/Ops Team → CRON_JOB_ADMIN_ROLE → Add/Remove automation addresses
Monitor Bots → MONITOR_ROLE → Pause contracts if issues detected
Automation Scripts → CRON_JOB_ROLE → Execute bi-weekly epoch operations
```

# Summary and Key Outcomes

This frequency-based role architecture addresses the limitations of traditional models by aligning administrative authority with the operational cadence of each role. 
It optimizes both efficiency and security, via a flexible governance layer that supports real-world operational demands and practical organizational structure.

**Salient Features:**

- **Operational Efficiency:**
  - High-frequency tasks (e.g., bot rotation, routine automation) are managed by dedicated admins, eliminating executive bottlenecks and enabling rapid response.
  - Automated and scheduled operations proceed without delay, supporting continuous protocol function.
  - Clear separation between operational and strategic roles ensures focused responsibility and reduces cross-functional risk.

- **Security and Risk Containment:**
  - Role isolation ensures that compromise of one admin is contained, preventing escalation across unrelated functions.
  - Global admin retains override authority, providing a robust failsafe for critical interventions.
  - Strategic actions require multi-signature approval, maintaining strong oversight for high-impact changes.

- **Governance and Transparency:**
  - Administrative authority is explicitly mapped to operational needs, clarifying responsibilities and reducing ambiguity.
  - All role changes are logged via events, supporting comprehensive audit trails and operational transparency.
  - The model is designed to scale, maintaining clarity and control as protocol complexity grows.

**Innovation Highlight:**
An RBAC based upon expected frequency and risk profile of operations, is the innovation that allows for streamlining contract administration, risk mitigation and security. 
By focusing on practicality rather than theoretical security models, the AccessController delivers a robust, operationally realistic solution for decentralized protocols.


# Deployment Process
1. Deploy AddressBook → Set globalAdmin (executive multisig)
2. Deploy AccessController → Retrieves globalAdmin from AddressBook
3. Deploy other contracts → Reference AccessController for permissions
4. Initial role assignment:
    - Grant `MONITOR_ADMIN_ROLE` to dev/ops multisig
    - Grant `CRON_JOB_ADMIN_ROLE` to dev/ops multisig
    - Grant strategic roles directly to appropriate multi-sigs
    - Assign `MONITOR_ROLE` to risk bots
    - Keep the following roles unassigned: `CRON_JOB`, `EMERGENCY_EXIT_HANDLER_ROLE`. These are only assigned temporally and removed after immediately. 

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