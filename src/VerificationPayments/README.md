# Owe Money, Pay Money [Working Title]

It is assumed that `credentialId` is unique pairwise{issuerId, credentialType}.

## Issuer and related processes

**Onboarding Flow:**

1. New Issuer calls `setupIssuer`
2. Subsequently, call `setupCredentials`, defining verification fee
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
Additionally, they are expected to specify `wallet` - which is address to which fees will be claimable to.

**The necessity for an issuer id on-chain:**

- allows issuers to switch config addresses
- allows issuers to switch fee claim wallet address
- allows issuers to silo access control between an address that is used to handle configurations, and another for asset management

Without an issuer id, issuers are beholden to use the same address for everything, have no ability to switch addresses.

**Setting up credentials & fees: `setupCredential`**

The following struct defines the on-chain attributes of a credential:

```solidity
    // each credential is unique pairwise {issuerId, credentialType}
    struct Credential {
        bytes32 credentialId;
        bytes32 issuerId;
        
        // fees are expressed in USD8 terms
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       // could use epoch and epochMath?

        // counts
        uint128 totalIssued;
        uint128 totalFeesAccrued;
    }
```

When `setupCredential` is called, its primary purpose is to create a bytes32 `credentialId` and store the fee set by the issuer.
Here on out, the struct serves to log fees accrued from verifications and number of issuances. 

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
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 credentialId, uint256 amount, uint256 expiry, bytes calldata signature){}
```
- all ids are to be passed as assigned by the payments contract, for the correct storage referencing and calculations
- amount is the fee deductible
- expiry is the expiry of signature

Also note that the signature expects a nonce as replay protection.


---
---