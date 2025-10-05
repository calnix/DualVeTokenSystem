// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// Inherit from existing AccessController
import {AccessController} from "../AccessController.sol";
import {IAddressBook} from "../interfaces/IAddressBook.sol";
import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";

/**
 * @title AccessControllerV2
 * @author Calnix [@cal_nix]
 * @notice Enhanced access control with two-step role transfers and multi-signature support
 * @dev Extends AccessController with secure role transfer mechanisms
 */
contract AccessControllerV2 is AccessController {
    
    // ------ TWO-STEP ROLE TRANSFER STATE ------
    struct PendingRoleTransfer {
        bytes32 role;           // The role being transferred
        address from;           // Current role holder (address(0) for new grants)
        address to;             // Proposed new role holder (address(0) for revocations)
        uint256 proposedAt;     // Timestamp of proposal
        address proposedBy;     // Who proposed the transfer
        bool exists;            // To check if transfer exists
    }
    
    // Core transfer tracking
    mapping(bytes32 => PendingRoleTransfer) public pendingTransfers;
    mapping(bytes32 => bytes32[]) public activePendingTransfers; // role => array of transfer IDs
    
    // Security parameters
    uint256 public constant ROLE_TRANSFER_DELAY = 24 hours;
    uint256 public constant ROLE_TRANSFER_EXPIRY = 7 days;
    uint256 public constant EMERGENCY_TRANSFER_DELAY = 1 hours; // Shorter delay for emergency roles
    
    // Multi-signature support for critical roles
    mapping(bytes32 => uint256) public roleTransferApprovalThreshold; // role => required approvals
    mapping(bytes32 => mapping(address => bool)) public transferApprovals; // transferId => approver => approved
    mapping(bytes32 => uint256) public transferApprovalCount; // transferId => approval count
    
    // Role-specific configurations
    mapping(bytes32 => bool) public requiresTwoStepTransfer; // Roles that must use two-step
    mapping(bytes32 => bool) public isEmergencyRole; // Roles with shorter delay
    
    // Transfer mode toggle
    bool public twoStepModeEnabled = true;
    
    // ===== EVENTS =====
    event RoleTransferProposed(
        bytes32 indexed transferId,
        bytes32 indexed role,
        address indexed from,
        address to,
        address proposedBy
    );
    
    event RoleTransferCompleted(
        bytes32 indexed transferId,
        bytes32 indexed role,
        address indexed from,
        address to
    );
    
    event RoleTransferCancelled(
        bytes32 indexed transferId,
        bytes32 indexed role,
        address cancelledBy
    );
    
    event RoleTransferApproved(
        bytes32 indexed transferId,
        address indexed approver
    );
    
    event RoleTransferThresholdSet(
        bytes32 indexed role,
        uint256 threshold
    );
    
    event RoleConfigurationUpdated(
        bytes32 indexed role,
        bool requiresTwoStep,
        bool isEmergency
    );
    
    event TwoStepModeToggled(bool enabled);
    
    // ===== ERRORS =====
    error TransferAlreadyPending();
    error TransferDoesNotExist();
    error TransferDelayNotMet();
    error TransferExpired();
    error InsufficientApprovals();
    error AlreadyApproved();
    error UnauthorizedTransferAction();
    error InvalidTransferParameters();
    error TwoStepModeDisabled();
    error TwoStepRequired();
    error SameAddress();
    error RoleNotHeld();
    error RoleAlreadyHeld();
    
    // ===== CONSTRUCTOR =====
    constructor(address addressBook) AccessController(addressBook) {
        // Initialize critical roles to require two-step transfers
        requiresTwoStepTransfer[DEFAULT_ADMIN_ROLE] = true;
        requiresTwoStepTransfer[EMERGENCY_EXIT_HANDLER_ROLE] = true;
        requiresTwoStepTransfer[ASSET_MANAGER_ROLE] = true;
        
        // Set emergency roles for faster transfers
        isEmergencyRole[MONITOR_ROLE] = true;
        isEmergencyRole[EMERGENCY_EXIT_HANDLER_ROLE] = true;
        
        // Set multi-sig requirements for critical roles
        roleTransferApprovalThreshold[DEFAULT_ADMIN_ROLE] = 2;
        roleTransferApprovalThreshold[EMERGENCY_EXIT_HANDLER_ROLE] = 2;
    }
    
    // ===== TWO-STEP ROLE TRANSFER FUNCTIONS =====
    
    /**
     * @notice Proposes a role transfer (grant, revoke, or transfer between addresses)
     * @param role The role to transfer
     * @param from Current holder (address(0) for new grant)
     * @param to New holder (address(0) for revocation)
     * @return transferId Unique identifier for this transfer proposal
     */
    function proposeRoleTransfer(
        bytes32 role,
        address from,
        address to
    ) public returns (bytes32 transferId) {
        // Validations
        if (from == to) revert SameAddress();
        if (from != address(0) && !hasRole(role, from)) revert RoleNotHeld();
        if (to != address(0) && hasRole(role, to)) revert RoleAlreadyHeld();
        
        // Check if two-step is required or enabled
        if (!twoStepModeEnabled && !requiresTwoStepTransfer[role]) {
            revert TwoStepModeDisabled();
        }
        
        // Permission checks
        bytes32 adminRole = getRoleAdmin(role);
        bool isAdmin = hasRole(adminRole, msg.sender);
        bool isSelfTransfer = (from == msg.sender && from != address(0));
        
        // Special case: DEFAULT_ADMIN_ROLE cannot self-transfer
        if (role == DEFAULT_ADMIN_ROLE && isSelfTransfer) {
            revert UnauthorizedTransferAction();
        }
        
        if (!isAdmin && !isSelfTransfer) {
            revert UnauthorizedTransferAction();
        }
        
        // Generate unique transfer ID
        transferId = keccak256(
            abi.encodePacked(role, from, to, block.timestamp, msg.sender)
        );
        
        // Check for existing pending transfer
        if (pendingTransfers[transferId].exists) {
            revert TransferAlreadyPending();
        }
        
        // Create pending transfer
        pendingTransfers[transferId] = PendingRoleTransfer({
            role: role,
            from: from,
            to: to,
            proposedAt: block.timestamp,
            proposedBy: msg.sender,
            exists: true
        });
        
        // Track active transfers for this role
        activePendingTransfers[role].push(transferId);
        
        // Auto-approve if proposer is admin and threshold is set
        if (isAdmin && roleTransferApprovalThreshold[role] > 0) {
            _approveTransfer(transferId, msg.sender);
        }
        
        emit RoleTransferProposed(transferId, role, from, to, msg.sender);
    }
    
    /**
     * @notice Accepts a pending role transfer
     * @param transferId The ID of the transfer to accept
     */
    function acceptRoleTransfer(bytes32 transferId) external {
        PendingRoleTransfer memory transfer = pendingTransfers[transferId];
        if (!transfer.exists) revert TransferDoesNotExist();
        
        // Only the recipient can accept (except for revocations)
        if (transfer.to != address(0) && transfer.to != msg.sender) {
            revert UnauthorizedTransferAction();
        }
        
        // For revocations, only admin can accept
        if (transfer.to == address(0)) {
            bytes32 adminRole = getRoleAdmin(transfer.role);
            if (!hasRole(adminRole, msg.sender)) {
                revert UnauthorizedTransferAction();
            }
        }
        
        // Check delay period
        uint256 requiredDelay = isEmergencyRole[transfer.role] 
            ? EMERGENCY_TRANSFER_DELAY 
            : ROLE_TRANSFER_DELAY;
            
        if (block.timestamp < transfer.proposedAt + requiredDelay) {
            revert TransferDelayNotMet();
        }
        
        // Check expiry
        if (block.timestamp > transfer.proposedAt + ROLE_TRANSFER_EXPIRY) {
            revert TransferExpired();
        }
        
        // Check approval threshold
        uint256 threshold = roleTransferApprovalThreshold[transfer.role];
        if (threshold > 0 && transferApprovalCount[transferId] < threshold) {
            revert InsufficientApprovals();
        }
        
        // Execute the transfer
        _executeRoleTransfer(transfer);
        
        // Cleanup
        _cleanupTransfer(transferId, transfer.role);
        
        emit RoleTransferCompleted(transferId, transfer.role, transfer.from, transfer.to);
    }
    
    /**
     * @notice Cancels a pending role transfer
     * @param transferId The ID of the transfer to cancel
     */
    function cancelRoleTransfer(bytes32 transferId) external {
        PendingRoleTransfer memory transfer = pendingTransfers[transferId];
        if (!transfer.exists) revert TransferDoesNotExist();
        
        // Check permissions
        bytes32 adminRole = getRoleAdmin(transfer.role);
        bool canCancel = (
            hasRole(adminRole, msg.sender) ||
            transfer.from == msg.sender ||
            transfer.to == msg.sender ||
            transfer.proposedBy == msg.sender
        );
        
        if (!canCancel) revert UnauthorizedTransferAction();
        
        // Cleanup
        _cleanupTransfer(transferId, transfer.role);
        
        emit RoleTransferCancelled(transferId, transfer.role, msg.sender);
    }
    
    /**
     * @notice Approves a pending role transfer (for multi-sig roles)
     * @param transferId The ID of the transfer to approve
     */
    function approveRoleTransfer(bytes32 transferId) external {
        PendingRoleTransfer memory transfer = pendingTransfers[transferId];
        if (!transfer.exists) revert TransferDoesNotExist();
        
        // Only role admins can approve
        bytes32 adminRole = getRoleAdmin(transfer.role);
        if (!hasRole(adminRole, msg.sender)) {
            revert UnauthorizedTransferAction();
        }
        
        _approveTransfer(transferId, msg.sender);
    }
    
    // ===== CONFIGURATION FUNCTIONS =====
    
    /**
     * @notice Sets the approval threshold for a role
     * @param role The role to configure
     * @param threshold Number of approvals required
     */
    function setRoleTransferApprovalThreshold(bytes32 role, uint256 threshold) 
        external 
        onlyRole(DEFAULT_ADMIN_ROLE) 
    {
        roleTransferApprovalThreshold[role] = threshold;
        emit RoleTransferThresholdSet(role, threshold);
    }
    
    /**
     * @notice Configures role transfer requirements
     * @param role The role to configure
     * @param requireTwoStep Whether role requires two-step transfer
     * @param isEmergency Whether role uses emergency timing
     */
    function configureRole(
        bytes32 role,
        bool requireTwoStep,
        bool isEmergency
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requiresTwoStepTransfer[role] = requireTwoStep;
        isEmergencyRole[role] = isEmergency;
        emit RoleConfigurationUpdated(role, requireTwoStep, isEmergency);
    }
    
    /**
     * @notice Toggles two-step mode for non-mandatory roles
     * @param enabled Whether to enable two-step mode
     */
    function setTwoStepMode(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        twoStepModeEnabled = enabled;
        emit TwoStepModeToggled(enabled);
    }
    
    // ===== OVERRIDE FUNCTIONS FOR BACKWARD COMPATIBILITY =====
    
    /**
     * @notice Grants a role with two-step process if required
     * @param role The role to grant
     * @param account The account to grant the role to
     */
    function grantRole(bytes32 role, address account) 
        public 
        virtual 
        override 
        onlyRole(getRoleAdmin(role)) 
    {
        if (requiresTwoStepTransfer[role] || twoStepModeEnabled) {
            proposeRoleTransfer(role, address(0), account);
        } else {
            super.grantRole(role, account);
        }
    }
    
    /**
     * @notice Revokes a role with two-step process if required
     * @param role The role to revoke
     * @param account The account to revoke the role from
     */
    function revokeRole(bytes32 role, address account) 
        public 
        virtual 
        override 
        onlyRole(getRoleAdmin(role)) 
    {
        if (requiresTwoStepTransfer[role] || twoStepModeEnabled) {
            proposeRoleTransfer(role, account, address(0));
        } else {
            super.revokeRole(role, account);
        }
    }
    
    /**
     * @notice Immediate role grant (bypasses two-step)
     * @dev Only for emergencies or when two-step is explicitly not required
     */
    function grantRoleImmediate(bytes32 role, address account) 
        external 
        onlyRole(getRoleAdmin(role)) 
    {
        if (requiresTwoStepTransfer[role]) revert TwoStepRequired();
        super.grantRole(role, account);
    }
    
    /**
     * @notice Immediate role revocation (bypasses two-step)
     * @dev Only for emergencies or when two-step is explicitly not required
     */
    function revokeRoleImmediate(bytes32 role, address account) 
        external 
        onlyRole(getRoleAdmin(role)) 
    {
        if (requiresTwoStepTransfer[role]) revert TwoStepRequired();
        super.revokeRole(role, account);
    }
    
    // ===== VIEW FUNCTIONS =====
    
    /**
     * @notice Gets details of a pending transfer
     * @param transferId The transfer ID to query
     */
    function getPendingTransfer(bytes32 transferId) external view returns (
        bytes32 role,
        address from,
        address to,
        uint256 proposedAt,
        address proposedBy,
        bool canAccept,
        uint256 timeUntilActive,
        uint256 approvalsNeeded,
        uint256 approvalsReceived
    ) {
        PendingRoleTransfer memory transfer = pendingTransfers[transferId];
        if (!transfer.exists) revert TransferDoesNotExist();
        
        role = transfer.role;
        from = transfer.from;
        to = transfer.to;
        proposedAt = transfer.proposedAt;
        proposedBy = transfer.proposedBy;
        
        uint256 requiredDelay = isEmergencyRole[role] 
            ? EMERGENCY_TRANSFER_DELAY 
            : ROLE_TRANSFER_DELAY;
            
        uint256 activeTime = proposedAt + requiredDelay;
        uint256 expiryTime = proposedAt + ROLE_TRANSFER_EXPIRY;
        
        approvalsNeeded = roleTransferApprovalThreshold[role];
        approvalsReceived = transferApprovalCount[transferId];
        
        timeUntilActive = block.timestamp < activeTime 
            ? activeTime - block.timestamp 
            : 0;
            
        canAccept = (
            block.timestamp >= activeTime &&
            block.timestamp <= expiryTime &&
            (approvalsNeeded == 0 || approvalsReceived >= approvalsNeeded)
        );
    }
    
    /**
     * @notice Gets all active pending transfers for a role
     * @param role The role to query
     */
    function getActivePendingTransfers(bytes32 role) 
        external 
        view 
        returns (bytes32[] memory) 
    {
        return activePendingTransfers[role];
    }
    
    /**
     * @notice Checks if an address has approved a transfer
     * @param transferId The transfer ID
     * @param approver The potential approver
     */
    function hasApprovedTransfer(bytes32 transferId, address approver) 
        external 
        view 
        returns (bool) 
    {
        return transferApprovals[transferId][approver];
    }
    
    // ===== INTERNAL FUNCTIONS =====
    
    function _executeRoleTransfer(PendingRoleTransfer memory transfer) internal {
        // Handle different transfer types
        if (transfer.from == address(0)) {
            // New grant
            _grantRole(transfer.role, transfer.to);
        } else if (transfer.to == address(0)) {
            // Revocation
            _revokeRole(transfer.role, transfer.from);
        } else {
            // Transfer between addresses
            _revokeRole(transfer.role, transfer.from);
            _grantRole(transfer.role, transfer.to);
        }
    }
    
    function _approveTransfer(bytes32 transferId, address approver) internal {
        if (transferApprovals[transferId][approver]) revert AlreadyApproved();
        
        transferApprovals[transferId][approver] = true;
        transferApprovalCount[transferId]++;
        
        emit RoleTransferApproved(transferId, approver);
    }
    
    function _cleanupTransfer(bytes32 transferId, bytes32 role) internal {
        // Remove from active transfers
        bytes32[] storage activeTransfers = activePendingTransfers[role];
        for (uint256 i = 0; i < activeTransfers.length; i++) {
            if (activeTransfers[i] == transferId) {
                activeTransfers[i] = activeTransfers[activeTransfers.length - 1];
                activeTransfers.pop();
                break;
            }
        }
        
        // Delete transfer data
        delete pendingTransfers[transferId];
        delete transferApprovalCount[transferId];
        // Note: We don't delete individual approvals to save gas
    }
}