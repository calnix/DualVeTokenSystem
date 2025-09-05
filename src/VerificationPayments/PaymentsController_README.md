# Payments Controller

**Actors:**

1. Protocol
2. Issuers
3. Verifiers

## Issuers

All new issuers must create their on-chain profile on the contract to receive a unique identifying code: `issuerId`

**Onboarding Flow:**

1. New Issuer calls `createIssuer()`
2. Subsequently, call `createSchema()`; [generates a unique id: `schemaId` and sets its verification fee] 
3. Repeat step 2 as required

### 1. `createIssuer()`

`function createIssuer(address assetAddress) external returns (bytes32)`
- returns `issuerId`, for better integration with middleware translation layer.

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

The `assetAddress` will be the designated "wallet", to which issuers would claim their accrued fees.
The `adminAddress` will be the "owner" account through which the issuer will interact with the contract to createSchema, update fees, and update addresses.

**The necessity for an issuer id on-chain:**

- allows issuers to switch admin addresses
- allows issuers to switch fee claim wallet address
- allows issuers to silo access control between an address that is used to handle configurations, and another for asset management

Without an issuer id, issuers are beholden to use the same address for everything; have no ability to switch addresses.

We cannot be sure how our issuing partners should have their addresses setup [multi-sig, etc]. 
To avoid forcing them to use a specific pattern, hence this approach.

### 2. `createSchema()`

A schema defines the structure and rules for a credential—essentially its template.

```
Key schema fields:
- Public: title, data source type, version, metadata (header), zk/encryption info (footer)
- Private: body (allowed claims, data types, constraints, validation rules)
```

**It is important to understand that the schema itself does not exist on-chain:**
- On-chain schema IDs reference off-chain schema definitions.
- Schemas on-chain are solely for fee and payment tracking.
- Middleware maps contract schema IDs to their off-chain counterparts.

The following struct defines the on-chain attributes of a schema:

```solidity
    struct Schema {
        bytes32 schemaId;
        bytes32 issuerId;
        
        // fees are expressed in USD8 terms | 6dp precision
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       

        // counts: never decremented
        uint128 totalVerified;
        uint128 totalGrossFeesAccrued;            // disregards protocol and voting fees

        // for VotingController
        bytes32 poolId;
    }
```

**Creating schemas & fees: `createSchema`**

`function createSchema(bytes32 issuerId, uint128 fee) external returns (bytes32)`

When `setupSchema` is called, it's purpose is two-fold:
1. create a bytes32 `schemaId`
2. store the fee set by the issuer

Thereafter, the `schemaId` is used to track fees accrued from verifications and number of issuances. 

### 3. Schemas and Voting [Overlap with VotingController.sol]

The schema struct contains `bytes32 poolId`, to associate a schema with a voting pool.
- by default this is `bytes32(0)`, indicating that is it not associated to a voting pool.
- to associate it with a voting pool, the admin function `updatePoolId(bytes32 schemaId, bytes32 poolId)` is called
- use this function to add/update/remove voting pool association.

> Pools are created on VotingController.sol, so poolId must be referenced from that contract.
> VotingController has no visibility of which schemas are associated to its pools. 
> Voter rewards [VOTING_FEE_PERCENTAGE] will be checked on PaymentsController.sol, then deposited to their respective pools. 

### 4. Other issuer functions:

- `updateSchemaFee`
- `updateAssetAddress` [common to both issuers and verifiers]
- `claimFees`

---

## Verifiers 

**Onboarding Flow:**

1. New Verifier calls `createVerifier`
2. Subsequently, call `deposit`, to deposit `USD8` for verification payments
3. Repeat step 2 as required

### 1. `createVerifier`

A new verifier is required to call `createVerifier`:
`function createVerifier(address signerAddress, address assetAddress) external returns (bytes32) `
- a unique random bytes32 `verifierId` will be generated for them.
- expected to specify both a signer and asset address as inputs.

**Explanation**

The following struct defines the on-chain attributes of a verifier:

```solidity
    struct Verifier {
        bytes32 verifierId;
        address adminAddress;
        address assetAddress;   // used for both deposit/withdrawing fees + staking Moca
        address signerAddress;  

        // MOCA | 18 dp precision
        uint128 mocaStaked;

        // USD8 | 6dp precision
        uint128 currentBalance;
        uint128 totalExpenditure;  // count: never decremented
    }
```

- `signerAddress`: for signature validation during verification payments 
- `assetAddress`: address to which deposit/withdraw of USD8 balances + staking Moca

Similar to the issuer, a separation of roles between signing and asset management is crucial.

**The necessity for an verifier id on-chain:**

- allows verifier to change signing address
- allows verifier to change asset address
- allows verifier to silo access control between an address that is used to handle signature generation, and another for asset management

### 2. `deposit`

Following id creation, verifiers must deposit some balance of USD8 into the contract.
Verifier's verification txns' cost will be deducted against this balance.
It is the verifier's responsibility to maintain a non-zero balance. 

### 3. Verifier Subsidies: Staking Moca

A verifier can opt to stake Moca to enjoy subsidies on their verification payments [*staking is optional*].
The amount of Moca staked determines their subsidyPct, which is applied on each verification fee payment and booked.

This mapping determines the subsidy a verifier might receive:

```solidity
    mapping(uint256 mocaStaked => uint256 subsidyPercentage) internal _verifiersSubsidyPercentages;
```
**It is important to note that the verifier must stake the exact amount; no more, no less. Else subsidyPercentage will be 0.**

While the PaymentsController tracks subsidies accrued as per expenditure per epoch, the distribution of subsidies will be handled in VotingController.
Please see the section below `Handling Subsidies` to understand how subsidies are calculated and distributed.

### 4. Other verifier functions:

- `withdraw`
- `updateSignerAddress`
- `updateAssetAddress` [common to both issuers and verifiers]

## `deductBalance`: Integration with Universal verifier contract

Verifier contract will call `deductBalance()`, passing the following as inputs:

```solidity
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint128 amount, uint256 expiry, bytes calldata signature){...}
```
- `amount` is the fee deductible
- `expiry` is the expiry of signature

### `deductBalance` execution flow:

1. nextFee check: checks if the schema has an incoming fee increment; if so, updates `currentFee` to `nextFee`. `nextFee` will apply for this txn.
2. verifies signature provided: to ensure that the verifier did indeed sign-off on this verification request.
3. updates verifier nonce. 

**4. If the schema fee is non-zero:**
- check that `amount` matches exactly to schemaFee; else revert
- check that verifier's `currentBalance` is >= `amount`; else revert
- calc. protocol and voting fees

*4.1. For VotingController: checks if schema has a non-zero `poolId` tag; if it does, `_bookSubsidy()` is executed:*
- gets subsidyPct for the verifier, based on his MOCA staked 
- calc. subsidy applicable
- book subsidy accrued -> `_epochPoolSubsidies` & `_epochPoolVerifierSubsidies`
- Increment protocol & voting fees, for the pool associated w/ this schema: `_epochPoolFeesAccrued:{feesAccruedToVoters,feesAccruedToProtocol}`
    - `_epochPoolFeesAccrued` mapping is needed to track how much `USD8` was accrued to each pool
    - referencing this value, to know how much `esMoca` to deposit per pool via `VotingController.depositRewards(uint256 epoch, bytes32[] calldata poolIds)`

*4.2. Global Accounting: Increment/decrement the following values referencing `amount`:*
- issuer: `.totalNetFeesAccrued++`, `.totalVerified++`
- verifier: `.currentBalance--`, `totalExpenditure++`
- schema:  `.totalGrossFeesAccrued++`
    
5. Increment `++_schemas[schemaId].totalVerified;`
    - counter to track number of times a schema has been used in verification
    
> **Crucial to keep this function as lightweight as possible, to ensure sensible gas costs, esp. during high network usage**

---

## Handling Subsidies

**While distribution of subsidies are not handled on this contract, but instead on VotingController, we elaborate the process to highlight the requirements needed in PaymentsController to effectively support this. I.e.: what mappings and tracking are required.**

- For each epoch, verifier receives subsidies based on: `(verifierAccruedSubsidies / poolAccruedSubsidies) * poolAllocatedSubsidies`
- TotalSubsidies to be distributed across pools for an epoch is decided by the protocol [can be set at the start or end on `VotingController.setEpochSubsidies()`]
- Subsidies are distributed proportionally based on the votes each pool receives -> `poolAllocatedSubsidies` [`VotingController.finalizeEpoch()`]
- A pool's allocated subsidies is then distributed amongst the verifiers proportionally, per the weight: `verifierAccruedSubsidies / poolAccruedSubsidies`
- where `verifierAccruedSubsidies` => total subsidies accrued based on their verification fee expenditure, for that specific pool
- where `poolAccruedSubsidies` => the sum total of subsidies accrued by all verifiers, in that pool [*schema group*]

Hence, the need for PaymentsController to have the two mappings:
1. `_epochPoolSubsidies` 
2. `_epochPoolVerifierSubsidies`; 

which are updated in `deductBalance`.

`VotingController.claimSubsidies()` will reference these values for calculating verifier subsidies, by calling `PaymentsController.getVerifierAndPoolAccruedSubsidies()`

Subsidies are paid out to the `assetAddress` of the verifier, so it is required that, `assetAddress` calls `VotingController.claimSubsidies`

> **VotingController.claimSubsidies()` will handle the precision differential when calculating verifier weighted subsidies**

> Subsidies are calculated on the gross amount; before protocol and voting fee are deducted

## Handling Voter Rewards [Voting Fee]

- Voters receive rewards, financed by the `VOTING_FEE_PERCENTAGE` cut from total verification fees accrued for that epoch
- Rewards are distributed to voters based on which pools they voted on, and what that pool accrued `feesAccruedToVoters`
- `userVotes/PoolTotalVotes` * `feesAccruedToVoters`
- Hence we need to track `feesAccruedToVoters` on a per pool basis in PaymentsController => `_epochPoolFeesAccrued` mapping

**VotingController does not directly query PaymentsController for this mapping.**
- This mapping tracks the total USD8 accrued; which needs to be converted to esMoca.
- It determines the amount to deposit into VotingController after conversion, via `VotingController.depositRewardsForEpoch()`.

---

## Integration with VotingController

**Should PaymentsController call VotingController to update accrued rewards/subsidies/fees?**
- No
- do not want PaymentsController to have external call dependencies to other contracts.
- may create problems when upgrading to new contracts. 

PaymentsController should be standalone, as much as possible.


## Upgradability [!]

1. Deploy new `PaymentsControllerV2`
2. Setup `PaymentsControllerV2` 
    - either we expect issuers/verifiers to recreate their profiles
    - or an owner function to populate the new contract with their profile data, referencing the old contract
    - have verifiers partially migrate USD8 balances to new contract
3. Update `AddressBook` to map to `PaymentsControllerV2` address.
4. Here on out `UniversalVerifierContract` will reference the `PaymentsControllerV2`, through `AddressBook`. Old contract is defunct.
4. Verifiers to migrate remaining USD8 balances to PaymentsControllerV2.
5. Old contract will be frozen once all issuers have claimed fees and verifiers have migrated their balances.

**UniversalVerifierContract should call PaymentsController through AddressBook.**
- so that it can reference the latest contract seamlessly 
