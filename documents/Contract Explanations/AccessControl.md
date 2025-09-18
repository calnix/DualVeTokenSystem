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