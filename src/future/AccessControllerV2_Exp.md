# AccessControllerV2 Documentation

## Overview

AccessControllerV2 is an enhanced version of the AccessController contract that introduces a two-step role transfer mechanism with multi-signature support. This upgrade significantly improves security by preventing accidental or malicious role transfers while maintaining backward compatibility and operational flexibility.

## Key Features

### 1. Two-Step Role Transfer Process

The two-step transfer process ensures that role changes are intentional and reversible:

- **Step 1: Proposal** - Current role holder or admin proposes a transfer
- **Step 2: Acceptance** - Recipient must actively accept the role after a delay period

This prevents:
- Accidental transfers to wrong addresses
- Transfers to addresses without access
- Immediate irreversible changes

### 2. Multi-Signature Support

Critical roles can require multiple approvals before transfer:
- DEFAULT_ADMIN_ROLE requires 2 approvals
- EMERGENCY_EXIT_HANDLER_ROLE requires 2 approvals
- Configurable thresholds for any role

### 3. Time-Based Security

- **Standard Delay**: 24 hours for most roles
- **Emergency Delay**: 1 hour for emergency roles
- **Expiry Period**: 7 days after proposeRoleTransfer
- Provides time to detect and prevent unauthorized transfers

### 4. Flexible Configuration

- Roles can be configured as mandatory two-step
- Emergency timing for critical operational roles
- Global toggle for two-step mode
- Backward compatibility with immediate transfers

## Role Transfer Types

### 1. New Role Grant
```
proposeRoleTransfer(role, address(0), newHolder)
```
Grants a role to a new address that doesn't currently have it.

### 2. Role Revocation
```
proposeRoleTransfer(role, currentHolder, address(0))
```
Removes a role from an address.

### 3. Role Transfer
```
proposeRoleTransfer(role, currentHolder, newHolder)
```
Transfers a role from one address to another.

## Process Flow

### Standard Role Transfer

1. **Proposal Phase**
   - Admin or current holder calls `proposeRoleTransfer()`
   - Transfer ID is generated
   - Proposal is recorded with timestamp
   - Event `RoleTransferProposed` is emitted

2. **Waiting Period**
   - 24-hour delay for standard roles
   - 1-hour delay for emergency roles
   - Multiple admins can approve if required

3. **Acceptance Phase**
   - Recipient calls `acceptRoleTransfer(transferId)`
   - System verifies delay period has passed
   - System verifies sufficient approvals (if required)
   - Role is transferred
   - Event `RoleTransferCompleted` is emitted

4. **Cancellation Option**
   - Any party can cancel before acceptance
   - Proposer, current holder, recipient, or admin
   - Event `RoleTransferCancelled` is emitted

### Multi-Signature Process

For roles requiring multiple approvals:

1. **Initial Proposal**
   - Same as standard process
   - If proposer is admin, counts as first approval

2. **Approval Collection**
   - Other admins call `approveRoleTransfer(transferId)`
   - Each approval is recorded
   - Event `RoleTransferApproved` is emitted

3. **Threshold Check**
   - Transfer cannot be accepted until threshold is met
   - Example: DEFAULT_ADMIN_ROLE requires 2 approvals

## Security Configurations

### Mandatory Two-Step Roles

These roles ALWAYS require two-step transfer:
- `DEFAULT_ADMIN_ROLE` - Supreme admin role
- `EMERGENCY_EXIT_HANDLER_ROLE` - Emergency functions access
- `ASSET_MANAGER_ROLE` - Treasury management

### Emergency Roles

These roles use 1-hour delay instead of 24 hours:
- `MONITOR_ROLE` - For quick incident response
- `EMERGENCY_EXIT_HANDLER_ROLE` - For emergency situations

### Configurable Parameters

Admins can configure:
- Approval thresholds per role
- Two-step requirements per role
- Emergency timing per role
- Global two-step mode toggle

## Usage Examples

### Example 1: Adding a New Monitor

```solidity
// Admin proposes to grant MONITOR_ROLE to newMonitor
bytes32 transferId = accessController.proposeRoleTransfer(
    MONITOR_ROLE,
    address(0),
    newMonitor
);

// After 1 hour (emergency role), newMonitor accepts
accessController.acceptRoleTransfer(transferId);
```

### Example 2: Transferring Admin Role (Multi-Sig)

```solidity
// Current admin proposes transfer
bytes32 transferId = accessController.proposeRoleTransfer(
    DEFAULT_ADMIN_ROLE,
    currentAdmin,
    newAdmin
);

// Second admin approves
accessController.approveRoleTransfer(transferId);

// After 24 hours, newAdmin accepts
accessController.acceptRoleTransfer(transferId);
```

### Example 3: Emergency Revocation

```solidity
// For non-mandatory two-step roles, immediate revocation is possible
accessController.revokeRoleImmediate(CRON_JOB_ROLE, compromisedAddress);
```

## Best Practices

### For Administrators

1. **Always Verify Addresses**: Double-check recipient addresses before proposing
2. **Monitor Events**: Set up monitoring for RoleTransferProposed events
3. **Use Multi-Sig**: Enable multi-signature for critical roles
4. **Document Transfers**: Keep records of all role changes
5. **Test First**: Test transfers on non-critical roles first

### For Recipients

1. **Verify Legitimacy**: Ensure transfer proposal is legitimate before accepting
2. **Check Timing**: Note when you can accept (after delay period)
3. **Act Promptly**: Accept before 7-day expiry
4. **Secure Access**: Ensure you have secure access to recipient address

### For Security

1. **Review Configurations**: Regularly review role configurations
2. **Audit Transfers**: Maintain audit logs of all transfers
3. **Emergency Procedures**: Have procedures for emergency situations
4. **Key Management**: Use hardware wallets for critical roles

## Emergency Procedures

### Cancelling a Transfer

If a transfer is proposed by mistake or to a compromised address:

```solidity
// Any authorized party can cancel
accessController.cancelRoleTransfer(transferId);
```

### Emergency Role Changes

For true emergencies when two-step is too slow:

1. Use `grantRoleImmediate()` or `revokeRoleImmediate()`
2. Only works for non-mandatory two-step roles
3. Requires admin privileges
4. Should be followed by investigation

### Global Two-Step Toggle

In extreme circumstances, global two-step can be disabled:

```solidity
// Only DEFAULT_ADMIN_ROLE can do this
accessController.setTwoStepMode(false);
```

## Integration Notes

### For Developers

1. **Event Monitoring**: Subscribe to role transfer events
2. **UI Integration**: Build interfaces for viewing pending transfers
3. **Notifications**: Implement alerts for transfer proposals
4. **Migration**: Plan migration from V1 to V2 carefully

### For Existing Systems

1. **Backward Compatible**: Existing role checks still work
2. **Gradual Migration**: Can enable two-step gradually
3. **No Breaking Changes**: All existing functions remain
4. **Opt-in Enhancement**: Two-step is configurable per role

## FAQ

**Q: What happens if I lose access before accepting a transfer?**
A: The transfer will expire after 7 days and can be re-proposed.

**Q: Can I have multiple pending transfers for the same role?**
A: Yes, but each must be for different from/to combinations.

**Q: What if an admin is compromised?**
A: Multi-signature requirements prevent single compromised admin from causing damage.

**Q: How do I know what transfers are pending?**
A: Use `getPendingTransfer()` and `getActivePendingTransfers()` view functions.

**Q: Can I speed up the delay period?**
A: No, delays are fixed for security. Use emergency roles for faster transfers.

## Technical Implementation Details

### State Variables

- `pendingTransfers`: Maps transfer ID to transfer details
- `activePendingTransfers`: Maps role to array of active transfer IDs
- `roleTransferApprovalThreshold`: Maps role to required approval count
- `transferApprovals`: Tracks approvals per transfer
- `requiresTwoStepTransfer`: Mandatory two-step roles
- `isEmergencyRole`: Roles with shorter delay periods

### Key Functions

#### Core Transfer Functions
- `proposeRoleTransfer(role, from, to)`: Initiates a transfer
- `acceptRoleTransfer(transferId)`: Completes a transfer
- `cancelRoleTransfer(transferId)`: Cancels a pending transfer
- `approveRoleTransfer(transferId)`: Approves multi-sig transfer

#### Configuration Functions
- `setRoleTransferApprovalThreshold(role, threshold)`: Sets multi-sig requirement
- `configureRole(role, requireTwoStep, isEmergency)`: Configures role behavior
- `setTwoStepMode(enabled)`: Toggles global two-step mode

#### Compatibility Functions
- `grantRole(role, account)`: Two-step aware grant
- `revokeRole(role, account)`: Two-step aware revoke
- `grantRoleImmediate(role, account)`: Bypass two-step
- `revokeRoleImmediate(role, account)`: Bypass two-step

### Events

- `RoleTransferProposed`: Emitted when transfer is proposed
- `RoleTransferCompleted`: Emitted when transfer is completed
- `RoleTransferCancelled`: Emitted when transfer is cancelled
- `RoleTransferApproved`: Emitted when transfer is approved
- `RoleTransferThresholdSet`: Emitted when threshold is changed
- `RoleConfigurationUpdated`: Emitted when role config changes
- `TwoStepModeToggled`: Emitted when global mode changes

### Error Codes

- `TransferAlreadyPending`: Transfer with same parameters exists
- `TransferDoesNotExist`: Invalid transfer ID
- `TransferDelayNotMet`: Too early to accept
- `TransferExpired`: Past 7-day expiry
- `InsufficientApprovals`: Need more approvals
- `UnauthorizedTransferAction`: Caller lacks permission
- `TwoStepRequired`: Cannot bypass mandatory two-step

## Migration Guide

### From AccessController V1 to V2

1. **Deploy V2**: Deploy AccessControllerV2 with same address book
2. **Copy Roles**: Migrate existing role assignments
3. **Update References**: Update all contracts to use V2
4. **Configure Requirements**: Set two-step requirements
5. **Test Thoroughly**: Test all role operations

### Gradual Rollout

1. **Phase 1**: Deploy with two-step disabled globally
2. **Phase 2**: Enable for non-critical roles
3. **Phase 3**: Enable for critical roles
4. **Phase 4**: Make mandatory for specified roles

## Conclusion

AccessControllerV2 provides a robust, secure, and flexible role management system that significantly reduces the risk of accidental or malicious role transfers while maintaining operational efficiency. The two-step process, combined with multi-signature support and configurable parameters, creates a defense-in-depth approach to access control.
