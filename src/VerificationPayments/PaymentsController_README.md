# Payments Controller

**Actors:**

1. Us
2. Issuers
3. Verifiers

## Issuers

**Onboarding Flow:**

1. New Issuer calls `setupIssuer`
2. Subsequently, call `setupSchema`, defining verification fee
3. Repeat step 2 as required

**Explanation**

The following struct defines the on-chain attributes of an issuer:

```solidity
    struct Issuer {
        bytes32 issuerId;
        address configAddress;     // for interacting w/ contract 
        address wallet;            // for claiming fees 
        
        //uint128 stakedMoca;
        
        // credentials
        uint128 totalIssuances; // incremented on each verification
        
        // USD8
        uint128 totalEarned;
        uint128 totalClaimed;
    }
```

A new issuer is required to call `setupIssuer`, wherein which a random bytes32 id will be generated for them.

```solidity
function setupIssuer(address wallet) external returns (bytes32)
```

- expected to specify `wallet` - which is address to which fees will be claimable to.
- `configAddress` will be set to `msg.sender`

**The necessity for an issuer id on-chain:**

- allows issuers to switch config addresses
- allows issuers to switch fee claim wallet address
- allows issuers to silo access control between an address that is used to handle configurations, and another for asset management

Without an issuer id, issuers are beholden to use the same address for everything; have no ability to switch addresses.

### Issuers: Schemas and Fees

Schema is a template defining the data points of a credential.
Put differently, its the blueprint for issuing credentials.

Schema layout:

```
Public inputs:
1. Title
2. Type of data source: E.g. self reported
3. Version 
4. Header/Metadata: Provides version, schema identifier (URL), title, and description
5. Footer: type of zk algo and encryption used

Private Inputs:
1. Body: Specifies the main structure—listing allowed claims, data types, constraints, relationships, and validation rules for each field.
```

Issuers are expected to setup schemas' and set associated verification fees on PaymentsController contract. 
This is done by calling `setupSchema`.

A schema's on-chain representation serves to account for fees and payment tracking; nothing more. 

**Setting up schema & fees: `setupSchema`**

The following struct defines the on-chain attributes of a schema:

```solidity
    struct Schema {
        bytes32 schemaId;
        bytes32 issuerId;
        
        // fees are expressed in USD8 terms
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       // could use epoch and epochMath?

        // counts
        uint128 totalIssued;
        uint128 totalFeesAccrued;

        // for VotingController
        bytes32 poolId;
    }
```

When `setupSchema` is called, it's purpose is two-fold:
1. create a bytes32 `schemaId`
2. store the fee set by the issuer

Thereafter, the `schemaId` is used to track fees accrued from verifications and number of issuances. 

### Schemas and Voting

The schema struct contains `bytes32 poolId`, to associate a schema with a voting pool.
- by default this is `bytes32(0)`, indicating that is it not attached to a voting pool.
- to associate it with a voting pool, the admin function `updatePoolId(bytes32 schemaId, bytes32 poolId)` is called
- use this function to add/update/remove voting pool association.

> Pools are created on VotingController.sol, so poolId should be referenced from that contract.
> VotingController has no visibility of which schemas are associated to its pools. 
> Voter rewards [cut of verification fees] will be checked on PaymentsController.sol, then deposited to their respective pools 

### Other issuer functions:

- `updateFee`
- `updateWalletAddress`
- `claimFees`

*is functionality to allow issuers to deactivate a credential needed?*

## Verifier and related processes 

**Onboarding Flow:**

1. New Verifier calls `setupVerifier`
2. Subsequently, call `deposit`, to deposit USD8 for payments
3. Repeat step 2 as required

**Explanation**

The following struct defines the on-chain attributes of a verifier:

```solidity
    struct Verifier {
        bytes32 verifierId;
        address signerAddress;
        address depositAddress;

        uint128 balance;
        uint128 totalExpenditure;
    }
```

A new verifier is required to call `setupVerifier`, wherein which a random bytes32 `verifierId` will be generated for them.
They are expect to specify both a signer and deposit address as inputs.

- signerAddress: for signature validation during verification payments 
- depositAddress: address to which deposit/withdraw is handled

Similar to the issuer, a separation of roles between signing and asset management is crucial.

**The necessity for an verifier id on-chain:**

- allows verifier to switch signing addresses
- allows verifier to switch deposit/withdraw wallet address
- allows verifier to silo access control between an address that is used to handle signature generation, and another for asset management

### Other verifier functions:

- `withdraw`
- `updateSignerAddress`
- `deductBalance`

## Integration with Universal verifier contract

Verifier contract should call `deductBalance()`, passing the following as input:

```solidity
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint256 amount, uint256 expiry, bytes calldata signature){...}
```
- all ids are to be passed as assigned by the payments contract, for the correct storage referencing and calculations
- amount is the fee deductible
- expiry is the expiry of signature

Also note that the signature expects a nonce as replay protection.


---
---

# Questions

1. Block/blacklist issuer/verifiers?

2. are subsidies calculated on the base verification fee?
- meaning, do not deduct protocol fee and voting rewards from it

**impacts deductBalance():**
- since the current process calcs. everything on the base verification fee
- there could be a scenario where all the haircuts added up together is `> amount`
-> can we streamline by just charging a single protocol fee.