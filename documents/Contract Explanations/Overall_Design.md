# Address Book and ACL

- there will only 1 single deployment of AddressBook.sol
- AccessControlLayer can be redeployed if needed, as its address on AddressBook updated

## AddressBook will track all contract addresses in our ecosystem/protocol.
- supports other contracts by providing latest address of contract type
- contract type defined by bytes32
- Known contracts are set as constants. E.g.: ` bytes32 private constant USD8 = 'USD8';`

Every time a contract is deployed it must be updated to AddressBook.

## AccessControlLayer is like a firewall handling permissioning
- contains list of roles 
- E.g.: `bytes32 private constant MONITOR_ROLE = keccak256("MONITOR_ROLE")`


When contracts need to check access priviledge:
- call AddressBook to get the latest ACL contract Address. 
- From ACL, check if msg.sender hasRole 
E.g.: 

```solidity

    modifier onlyMonitorRole(){
        //1. get AccessController addr
        IAccessController accessController = IAccessController(_addressBook.IAccessController());
        //2. check roles on AccessController
        require(accessController.isMonitor(msg.sender), "Caller not monitor");
        _;
    }
```

**TLDR:**
- if you are looking for a contract address -> retrieve from AddressBook
- if you are looking for a role -> retrieve from ACL [ACL must be gotten from AddressBook]

Example: where we want to check that caller is a specific contract. Does not involve roles.

```solidity
    modifier onlyVotingControllerContract() {
        address votingController = _addressBook.getVotingController();
        require(msg.sender == votingController, "Caller not voting controller");
        _;
    }
```

**Implementation-wise, contracts do not need to inherit AccessControl**
- they will just make external queries to ACL

## Why is AddressBook immutable but ACL can be redeployed

- useful in case we want to have a different ACL grid for another set of contracts
- i.e. there could be 2 ACL layers active in parallel servicing different set of contracts

## Global Admin Transfer Mechanism

The protocol's global admin is defined by the ownership of AddressBook. When ownership changes, the DEFAULT_ADMIN_ROLE in AccessController must be atomically transferred to maintain consistency.

### Design Principles
- **Single Source of Truth**: AddressBook ownership = Protocol global admin
- **Atomic Transfer**: No intermediate states with mismatched permissions
- **Two-Step Safety**: Uses Ownable2Step to prevent accidental transfers
- **No Lockout Risk**: New admin receives role before old admin loses it

### Implementation Details

AddressBook overrides `_transferOwnership` to:
1. Update AddressBook ownership (via parent implementation)
2. Update stored global admin at `bytes32(0)`
3. Call AccessController to atomically transfer DEFAULT_ADMIN_ROLE

AccessController provides `transferGlobalAdminFromAddressBook` which:
- Validates caller is AddressBook
- Grants role to new admin first
- Revokes role from old admin
- Emits GlobalAdminTransferred event

### Execution Flow

#### Step 1: Initiate Transfer

Current global admin calls on AddressBook: `transferOwnership(newAdminAddress)`

- Sets pending owner in AddressBook
- Emits `OwnershipTransferStarted` event
- No permissions change yet

#### Step 2: Accept Ownership

New admin calls on AddressBook: `acceptOwnership()`

This triggers the following internal flow:

1. **AddressBook._transferOwnership(newAdmin)**
   - Calls parent's `_transferOwnership` → updates owner
   - Updates `_addresses[bytes32(0)]` to newAdmin
   - Calls `AccessController.transferGlobalAdminFromAddressBook(oldAdmin, newAdmin)`
   - Emits `GlobalAdminUpdated` event

2. **AccessController.transferGlobalAdminFromAddressBook(oldAdmin, newAdmin)**
   - Verifies caller is AddressBook
   - Verifies oldAdmin has DEFAULT_ADMIN_ROLE
   - Grants DEFAULT_ADMIN_ROLE to newAdmin
   - Revokes DEFAULT_ADMIN_ROLE from oldAdmin
   - Emits `GlobalAdminTransferred` event

#### Result
- AddressBook owner: newAdmin
- AccessController DEFAULT_ADMIN_ROLE: newAdmin
- Complete atomic transfer with no intermediate inconsistent state

### Security Considerations

1. **Self-Removal Protection**: Admins cannot remove themselves via `removeGlobalAdmin`
2. **AddressBook Exclusive**: Only AddressBook can call `transferGlobalAdminFromAddressBook`
3. **Zero Address Checks**: Both old and new admin must be non-zero addresses
4. **Role Verification**: Confirms old admin actually has the role before transfer

### Deployment Requirements

1. Deploy AddressBook with initial global admin
2. Deploy AccessController with AddressBook address
3. Call `setAddress(ACCESS_CONTROLLER, accessControllerAddress)` on AddressBook
4. AccessController automatically grants DEFAULT_ADMIN_ROLE to AddressBook's owner

### Emergency Scenarios

If AccessController address is not set in AddressBook:
- Ownership transfer still succeeds
- Manual role grant required in AccessController
- Prevents blocking ownership transfer due to missing dependency

## Zero Address Handling:

Recommendation: Zero address checks should be in calling contracts, not AddressBook, because:
1.Explicit Errors: Calling contracts can provide context-specific error messages
2.Intentional Deprecation: AddressBook might legitimately return zero for deprecated contracts
3.Gas Efficiency: Avoid redundant checks if address is used multiple times

AddressBook: NO checks for regular addresses (allow zero)
AddressBook: KEEP checks for critical infrastructure (AccessController, AddressBook in constructors)
Calling Contracts: ALWAYS check with context-specific errors

# Notes

## EmergencyExits

if veMoca contract is emergencyExit(), but VotingController is not,
VotingController would be operating on an incorrect state - as we do not update locks/etc in veMoca.emergencyExit
⦁	Phantom Voting Power
⦁	when would you emergenctExit veMoca, but not VotingController?

## asset flows

Deposits + WithdrawX: Payments and Voting

in PC, USD8 is withdrawn to TREASURY [called by assetMgr]
in VC, esMoca is deposited frm msg.sender: cronJob
⦁	unclaimed is withdrawn to TREASURY

this is fine. treasury will transfer esMoca to cronjob as needed.