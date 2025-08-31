# Payments Controller

**Actors:**

1. Us
2. Issuers
3. Verifiers

## Issuers

All new issuers must create their on-chain profile on the contract to receive a unique identifying code: `issuerId`

**Onboarding Flow:**

1. New Issuer calls `createIssuer`
2. Subsequently, call `setupSchema`; which creates a schema[will have unique id: `schemaId`] and setting its verification fee
3. Repeat step 2 as required

### 1. createIssuer()

`function createIssuer(address assetAddress) external returns (bytes32)`
- returns issuerId, for better integration with middleware translation layer.

The following struct defines the on-chain attributes of an issuer:

```solidity
    struct Issuer {
        bytes32 issuerId;
        address adminAddress;            // for interacting w/ contract 
        address assetAddress;            // for claiming fees 
                
        // credentials
        uint128 totalVerified;          // incremented on each verification
        
        // USD8 | 6dp precision
        uint128 totalNetFeesAccrued;    // net of protocol and voter fees
        uint128 totalClaimed;
    }
```

- `issuerId` will be a random unique bytes32 id
- `adminAddress` = `msg.sender`
- `assetAddress` = `assetAddress`;

The `assetAddress` will be "wallet", to which issuers would claim their accrued fees.
The `adminAddress` will be the "owner" account through which the issuer will interact with the contract to createSchema, set/update fees, update addresses.

**The necessity for an issuer id on-chain:**

- allows issuers to switch admin addresses
- allows issuers to switch fee claim wallet address
- allows issuers to silo access control between an address that is used to handle configurations, and another for asset management

Without an issuer id, issuers are beholden to use the same address for everything; have no ability to switch addresses.

We cannot be sure how our issuing partners should have their addresses setup [multi-sig, etc]. 
To avoid forcing them to use a specific pattern, hence this approach.

### 2. createSchema

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

### Other issuer functions:

- `updateFee`
- `updateWalletAddress`
- `claimFees`

---

# Schemas and Voting

The schema struct contains `bytes32 poolId`, to associate a schema with a voting pool.
- by default this is `bytes32(0)`, indicating that is it not attached to a voting pool.
- to associate it with a voting pool, the admin function `updatePoolId(bytes32 schemaId, bytes32 poolId)` is called
- use this function to add/update/remove voting pool association.

> Pools are created on VotingController.sol, so poolId should be referenced from that contract.
> VotingController has no visibility of which schemas are associated to its pools. 
> Voter rewards [cut of verification fees] will be checked on PaymentsController.sol, then deposited to their respective pools 


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

## deductBalance(): Integration with Universal verifier contract

Verifier contract will call `deductBalance()`, passing the following as inputs:

```solidity
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint128 amount, uint256 expiry, bytes calldata signature){...}
```
- amount is the fee deductible
- expiry is the expiry of signature

**deductBalance process:**

1. nextFee check: checks if the schema has an incoming fee increment; if so, updates currentFee to nextFee. nextFee will apply for this txn.
2. checks that `amount` matches the schema fee exactly; else reverts.
3. checks that verifier has sufficient USD8 balance on the contract to pay for verification
4. verifies signature provided; to ensure that the verifier did indeed sign-off on this verification request
5. updates verifier nonce 
6. calculates `votingFee` and `protocolFee` based on `amount`
7. checks if schema has a non-zero `poolId` tag; if it does, `_bookSubsidy()` is executed:
    - gets subsidyPct for the verifier, based on his MOCA staked 
    - calc. subsidy applicable [could be 0]
    - if non-zero subsidy, book subsidy accrued -> `_epochPoolSubsidies` & `_epochPoolVerifierSubsidies`
    - if 0 subsidy -> skip
    - Increment protocol & voting fees, for the pool associated w/ this schema: `_epochPoolFeesAccrued:{feesAccruedToVoters,feesAccruedToProtocol}`
    - `_epochPoolFeesAccrued` mapping is needed to track how much `USD8` was accrued to each pool
    - referencing this value, to know how much `esMoca` to deposit per pool via `VotingController.depositRewards(uint256 epoch, bytes32[] calldata poolIds)`

8. Update all global states for: issuer, verifier, schemas
    - issuer: .totalNetFeesAccrued++, totalVerified++
    - verifier: .currentBalance--, totalExpenditure++
    - schema:  .totalGrossFeesAccrued++, totalVerified++
9.  Increment protocol & voting fees accrued for this epoch: `_epochFeesAccrued[currentEpoch]` updated: `.feesAccruedToProtocol` & `.feesAccruedToVoters` 
    - this mapping is required to track and enable accurate withdrawal of both fees [USD8], at the end of epoch.
    - fees would then be converted to `esMoca`

> **Crucial to keep this function as lightweight as possible, to ensure sensible gas costs, esp. during high network usage**

---

## Handling Subsidies

- For each epoch, verifier receives subsidies based on: `(verifierAccruedSubsidies / poolAccruedSubsidies) * poolAllocatedSubsidies`
- TotalSubsidies to be distributed across pools for an epoch is decided by the protocol [can be set at the start or end on `VotingController.setEpochSubsidies()`]
- subsidies are distributed proportionally based on the votes each pool receives -> `poolAllocatedSubsidies` [`VotingController.finalizeEpoch()`]
- a pool's allocated subsidies is then distributed amongst the verifiers proportionally, per the weight: `verifierAccruedSubsidies / poolAccruedSubsidies`
- where `verifierAccruedSubsidies` => total subsidies accrued based on their verification fee expenditure, for that specific pool
- where `poolAccruedSubsidies` => the sum total of subsidies accrued by all verifiers, in that pool [*schema group*]

Hence, the need for PaymentsController to have mappings: `_epochPoolSubsidies` & `_epochPoolVerifierSubsidies`; which are updated in `deductBalance`
`VotingController.claimSubsidies()` will reference these values for calculating verifier subsidies, by calling `PaymentsController.getVerifierAndPoolAccruedSubsidies()`

> **VotingController.claimSubsidies()` will handle the precision differential when calculating verifier weighted subsidies**

## Handling Voter Rewards [Voting Fee]

- voters receive rewards, financed by the `VOTING_FEE_PERCENTAGE` cut from total verification fees accrued for that epoch
- rewards are distributed to voters based on which pools they voted on, and what that pool accrued `feesAccruedToVoters`
- `userVotes/PoolTotalVotes` * `feesAccruedToVoters`
- hence we need to track `feesAccruedToVoters` on a per pool basis in PaymentsController => `_epochPoolFeesAccrued` mapping

>**The VotingController does not call PaymentsController directly, as we need to swap USD8 for esMoca**

---

## Integration with VotingController

**Should PaymentsController call VotingController to update accrued rewards/subsidies/fees?**
- No
- don't want PaymentsController to have external call dependencies to other contracts.
- may create problems when upgrading to new contracts. 
- PaymentsController should be silo-ed off as much as possible. Other contracts can call this if needed.

# Questions

1. Block/blacklist issuer/verifiers?

2. are subsidies calculated on the base verification fee?
- meaning, do not deduct protocol fee and voting rewards from it

**impacts deductBalance():**
- since the current process calcs. everything on the base verification fee
- there could be a scenario where all the haircuts added up together is `> amount`
-> can we streamline by just charging a single protocol fee.