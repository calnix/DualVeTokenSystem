```solidity
    // High-frequency operational roles
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");
    bytes32 public constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE");
    
    // Role admins for operational roles
    bytes32 public constant MONITOR_ADMIN_ROLE = keccak256("MONITOR_ADMIN_ROLE");
    bytes32 public constant CRON_JOB_ADMIN_ROLE = keccak256("CRON_JOB_ADMIN_ROLE");
    
    // Low-frequency strategic roles (no dedicated admins)
    bytes32 public constant PAYMENTS_CONTROLLER_ADMIN_ROLE = keccak256("PAYMENTS_CONTROLLER_ADMIN_ROLE");
    bytes32 public constant VOTING_CONTROLLER_ADMIN_ROLE = keccak256("VOTING_CONTROLLER_ADMIN_ROLE");
    bytes32 public constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");
    bytes32 public constant EMERGENCY_EXIT_HANDLER_ROLE = keccak256("EMERGENCY_EXIT_HANDLER_ROLE");
```

# ROLE HIERARCHY 

DEFAULT_ADMIN_ROLE (Global Admin - Executive Multi-sig)
├── MONITOR_ADMIN_ROLE (Dev/Ops Team 2/3 Multi-sig)
│   └── MONITOR_ROLE (High frequency - pause bots across all contracts)
├── CRON_JOB_ADMIN_ROLE (Dev/Ops Team 2/3 Multi-sig)
│   └── CRON_JOB_ROLE (High frequency - epoch operations & pool management)
├── PAYMENTS_CONTROLLER_ADMIN_ROLE (Direct to Global Admin - Executive Multi-sig)
├── VOTING_CONTROLLER_ADMIN_ROLE (Direct to Global Admin - Executive Multi-sig)
├── ASSET_MANAGER_ROLE (Direct to Global Admin - Executive Multi-sig)
└── EMERGENCY_EXIT_HANDLER_ROLE (Direct to Global Admin - Executive Multi-sig)

## DETAILED ROLE BREAKDOWN:

**TIER 1: SUPREME GOVERNANCE**

`DEFAULT_ADMIN_ROLE`
├── Manages: All role admins + direct strategic roles
├── Multi-sig: 4-of-7 (Senior Leadership)
├── Frequency: Very Rare (emergency actions, role hierarchy changes)
└── Override: Can override ANY role decision

**TIER 2: OPERATIONAL ADMIN ROLES** 

MONITOR_ADMIN_ROLE
├── Manages: `MONITOR_ROLE` addresses
├── Multi-sig: 2-of-3 (Dev/Ops Team)
├── Frequency: High (bot rotation, address management)
└── Purpose: Enable rapid response without executive bottlenecks

`CRON_JOB_ADMIN_ROLE` 
├── Manages: `CRON_JOB_ROLE` addresses
├── Multi-sig: 2-of-3 (Dev/Ops Team) 
├── Frequency: Medium (EOA rotation as needed for bot management)
└── Purpose: Enable automated operations without executive approval

**TIER 3: HIGH-FREQUENCY OPERATIONAL ROLES**

`MONITOR_ROLE`
├── Functions: `pause()` across VotingEscrowMoca, VotingController, PaymentsController
├── Addresses: Multiple monitoring bots (EOAs)
├── Frequency: Rare but critical (emergency pause)
└── Management: `MONITOR_ADMIN_ROLE` can add/remove addresses

`CRON_JOB_ROLE`
├── Functions: 
│   ├── VotingEscrowMoca: `createLockFor()`
│   ├── VotingController: `depositEpochSubsidies()`, `finalizeEpochRewardsSubsidies()`
│   ├── VotingController: `createPool()`, `removePool()`
├── Addresses: Automation EOAs (addressed to be added, and then stripped after ops execution)
├── Frequency: High (every 2 weeks for epoch operations)
└── Management: `CRON_JOB_ADMIN_ROLE` can add/remove addresses

**TIER 4: STRATEGIC ROLES (Direct to Global Admin)**

`PAYMENTS_CONTROLLER_ADMIN_ROLE`
├── Functions: `updateProtocolFeePercentage()`, `updateVotingFeePercentage()`
│             `updateVerifierSubsidyPercentages()`, `updatePoolId()`
├── Multi-sig: 2-of-3 (Dev/Ops Team)
├── Frequency: Rare (governance-driven parameter updates)
└── Management: `DEFAULT_ADMIN_ROLE` only

`VOTING_CONTROLLER_ADMIN_ROLE`
├── Functions: `setMaxDelegateFeePct()`, `setFeeIncreaseDelayEpochs()`
│             `setUnclaimedDelay()`, `setDelegateRegistrationFee()`
├── Multi-sig: 2-of-3 (Dev/Ops Team)  
├── Frequency: Rare (governance-driven parameter updates)
└── Management: `DEFAULT_ADMIN_ROLE` only

`ASSET_MANAGER_ROLE`
├── Functions: `withdrawUnclaimedRewards()`, `withdrawUnclaimedSubsidies()`
│              `withdrawRegistrationFees()`, `withdrawProtocolFees()`, `withdrawVotersFees()`
├── Multi-sig: 2-of-3 (DAT Team)
├── Frequency: Medium (monthly/quarterly asset management)
└── Management: `DEFAULT_ADMIN_ROLE` only

`EMERGENCY_EXIT_HANDLER_ROLE`
├── Functions: `emergencyExit()` across VotingEscrowMoca & VotingController.
│              `emergencyExitVerifiers()`, `emergencyExitIssuers()` in PaymentsController.
├── Multi-sig: 2-of-3 (Emergency Response Team) 
               [multi-sig to freeze, then add EOA address for bot to call repeatedly]
├── Frequency: Very Rare (emergency asset recovery)
└── Management: `DEFAULT_ADMIN_ROLE` only

# OPERATIONAL WORKFLOW

**Daily Operations (No Executive Approval Needed):**
Dev/Ops Team → MONITOR_ADMIN_ROLE → Add/Remove MONITOR_ROLE bots
Dev/Ops Team → CRON_JOB_ADMIN_ROLE → Add/Remove CRON_JOB_ROLE addresses
Monitoring Bots → MONITOR_ROLE → pause() contracts if issues detected
Automation Scripts → CRON_JOB_ROLE → Bi-weekly epoch operations

**Strategic Operations (Executive Approval Required):**
Executive Team → DEFAULT_ADMIN_ROLE → Grant/Revoke strategic roles
Product Team → PAYMENTS_CONTROLLER_ADMIN_ROLE → Update protocol parameters
Governance Team → VOTING_CONTROLLER_ADMIN_ROLE → Update voting parameters  
Treasury Team → ASSET_MANAGER_ROLE → Monthly asset withdrawals
Emergency Team → EMERGENCY_EXIT_HANDLER_ROLE → Emergency asset recovery

**HIERARCHY SUMMARY:**
| Level | Role Type          | Frequency   | Management          | Multi-sig Size |
|-------|--------------------|-------------|---------------------|----------------|
| 1     | Supreme Admin      | Very Rare   | Self-managed        | 4-of-7         |
| 2     | Operational Admins | High/Medium | DEFAULT_ADMIN_ROLE  | 2-of-3         |
| 3     | Operational Roles  | High        | Dedicated Admins    | EOAs           |
| 4     | Strategic Roles    | Rare/Medium | DEFAULT_ADMIN_ROLE  | 2-of-3         |

# DEPLOYMENT & OPERATIONAL WORKFLOW
Deployment Process:
1. Deploy AddressBook → Set globalAdmin (executive multisig)
2. Deploy AccessController → Retrieves globalAdmin from AddressBook
3. Deploy other contracts → Reference AccessController for permissions
4. Initial role assignment:
    - Grant MONITOR_ADMIN_ROLE to dev/ops multisig
    - Grant CRON_JOB_ADMIN_ROLE to dev/ops multisig
    - Grant strategic roles directly to appropriate multisigs

# Daily Operations
Dev/Ops Team (via role admins):
- Add/remove monitor bots (high frequency)
- Add/remove cron job addresses (medium frequency)
- Rotate EOA addresses for epoch operations

Executive Team (via DEFAULT_ADMIN_ROLE):
- Update protocol parameters (low frequency)
- Emergency actions (rare)
- Strategic role assignments (rare)

# Production Setup:
- DEFAULT_ADMIN_ROLE: 4-of-7 (CEO, Directors, Senior Leadership)
- MONITOR_ADMIN_ROLE: 2-of-3 (Dev/Ops Team)
- CRON_JOB_ADMIN_ROLE: 2-of-3 (Dev/Ops Team)
- Strategic Roles: Individual 2-of-3 multisigs per function

# Development/Staging:
- More permissive for testing
- Single EOAs acceptable for role admins
- Clear upgrade path to production security

# SUMMARY BY FREQUENCY:

## HIGH FREQUENCY (Daily/Bi-weekly)
- Monitor bot management (MONITOR_ADMIN_ROLE manages)
- CronJob address rotation (CRON_JOB_ADMIN_ROLE manages)
- Epoch operations: create pools, deposit subsidies, finalize rewards (CRON_JOB_ROLE executes)

## MEDIUM FREQUENCY (Monthly)
-Asset withdrawals (ASSET_MANAGER_ROLE)
-Pool creation/removal (VOTING_CONTROLLER_ADMIN_ROLE → should be CRON_JOB_ROLE)

## LOW FREQUENCY (Quarterly/Governance)
-Protocol parameter updates (Contract-specific admin roles)
-Fee adjustments (Contract-specific admin roles)

## VERY RARE (Emergency/Governance)
-Role hierarchy changes (DEFAULT_ADMIN_ROLE)
-Emergency actions (DEFAULT_ADMIN_ROLE, EMERGENCY_EXIT_HANDLER_ROLE)
-Pause/unpause/freeze operations

