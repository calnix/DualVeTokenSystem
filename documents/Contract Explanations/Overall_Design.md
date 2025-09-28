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