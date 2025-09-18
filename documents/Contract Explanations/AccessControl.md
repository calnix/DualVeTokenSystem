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