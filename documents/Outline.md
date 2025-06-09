# Outline of Contracts

# Overview

This document outlines the key smart contracts that will be implemented for the Moca Chain staking system. The system consists of three main components:

1. **Validator Staking & Emissions**
   - Handles node operator staking and rewards
   - Manages validator registration and slashing
   - Distributes validator rewards

2. **Staking Moca and Voting [veMOCA]**
   - Enables users to stake MOCA tokens
   - Manages voting power and delegation
   - Handles staking rewards distribution

3. **AIR Credentials**
   - Manages verifier and referrer credentials
   - Handles credential verification and validation
   - Tracks referral relationships and rewards

Each component is designed to work together to create a secure and efficient staking ecosystem while maintaining proper separation of concerns.

Reference: https://www.notion.so/animocabrands/WIP-Moca-Chain-Staking-Product-1fb3f5ceb8fe80c5b0fbc2b372c9a325

![Overview](overview.png)

# 1. Validator Staking & Emissions

## Overview

The validator staking system balances network security with sustainable token emissions through:

- Optimized emissions that maintain >10% APR for validators after node costs
- Permissioned validator model with infrastructure partner support
- Strong alignment incentives through $veMOCA governance
- Flexible redemption options for emissions rewards

Whitelisted actors can stake MOCA for a defined period to operate a validator node.
For running said node, they receive vested rewards, esMOCA.

> Note: After the initial 18-24-month period, the network may transition to permissionless validator onboarding, delegated proof of staking

## Key Components

### Validator Whitelisting & Requirements

**Whitelisting**

- selection is offchain: select entities will be whitelisted as per BD agreements
- translating that onchain: we will whitelist an address

Whitelisted address is allowed to call access controlled functions to stake the required MOCA.

**Node Requirements**

Validators have to stake MOCA for a period to be eligible to run a node:

- Lockup period
- Minimum MOCA requirement

Both should be modifiable.
When updated, the new values would impact incoming validators, not current active validators.

*UNCLEAR*

- how would the whitelisted address go about running an actual node?

### 2. Emissions Structure

There are 2 sources of rewards for Validators

1. Direct validator emissions
2. Verification fees

Both rewards will be expressed in $esMOCA:

- esMoca is escrowed MOCA; has vesting attached
- *How are rewards received?*
- *How much rewards per validator?*
- esMOCA can be staked for $veMOCA (1:1 conversion with $MOCA)

### 3. Redemption Options

esMOCA can be redeemed for MOCA through three different redemption paths, each with different lockup periods and penalties.
See esMoca.md

### 4. Slashing Conditions

- Malicious behavior results in loss of staked $MOCA
- *how much is slashed each time? can this be a global constant?*
- *Minimum stake requirements must be maintained, so what happens when slashed?*

### 5. Delegation

Delegation of $MOCA in the validators is not permitted in this model.

## Future Considerations

- Transition to permissionless validator onboarding
- Implementation of delegated proof of stake
- Dynamic adjustment of emissions based on network activity

---

# 2. Staking Moca and Voting [veMOCA]

This section describes how $MOCA can be staked to receive $veMOCA:

- $veMOCA is used to vote on credential pools
- votes influence the amount of subsidy emissions a credential pool receives for an epoch.
- subsidies are distributed as esMOCA
- voters receive verification fee rewards for their participation in voting.

## Staking MOCA for veMOCA

- Stake MOCA tokens to receive veMOCA (voting power)
- Longer lock periods result in higher veMOCA allocation
- veMOCA decays linearly over time, reducing voting power
- Formula-based calculation determines veMOCA amount based on stake amount and duration

### veMoca receivable formula

Lock duration: {min: 7 Days,  max: 2 years}

Formula

```bash
veMOCA = MOCA_staked * (lockTimeInSeconds / MAX_LOCK_TIME_IN_SECONDS)
```

Example: Lock 100 MOCA for 6 months: 100 MOCA * (6 months / 2 years) = 25 veMOCA

### Decay: decay linearly every second

- lock for 2 years: your veMOCA starts at full power and gradually reduces to 0 over 2 years.
- If you **extend the lock**, you maintain your veMOCA.
- smlj extend your lock - what happens to veMOCA?

## Voting with veMOCA

- 28-day voting epochs
- Users can split their votes across multiple credential pools
- Users that vote, get rewards. Those that do not vote, do not get rewards.
- End-of-epoch snapshot determines veMOCA voting power distribution

### Vote Delegation

- Users can delegate veMOCA to others, who can vote on their behalf
- Open system allowing anyone to become a Delegate Leader
- Leaders earn commission (e.g. 10%) on verification fees from voted pools
- Flexible delegation allowing allocation to any available Leader

## Subsidies and esMOCA

At the end of a voting period, $esMOCA emissions will be allocated to different credential pools, as per the votes.
Verifiers will pay for verifications in full, and consequently receive $esMOCA as “cashback” from these credential pools.

- Subsidies allocated to credential pools based on voting results
- Verifiers receive verification subsidies as esMOCA

*so each pool must hold an esMOCA balance?*
*distribute based on ecdsa signatures?*

### Allocation of $esMOCA Subsidy Emissions

- Verifiers receive X% of verification fees as $esMOCA cashback from schema-specific subsidy pools
- If Verifier paid 10 $MOCA for verification, (assuming 50% subsidy) they receive 5 $esMOCA.
- Unused subsidies return to treasury at epoch end

## Credential Pool Setup

- Issuers must be whitelisted by the protocol administrators
- Multiple issuers can be authorized to issue credentials for the same schema
- Verifiers must specify (in advance) which issuer's credentials they will accept for verification

## Others

**Can validators participate in voting?**

- Yes; but only through their esMOCA
- $esMOCA emissions can be staked for $veMOCA (it is treated 1:1 as $MOCA when staking)

## Credential Pool (aka Schema)

**Example of a credential pool/scheme:**

- Proof of Personhood Schema
- Credit Score
- Proof of Income

**Credential**

- instance of data issued to a user conforming to a credential schema
- a user's proof of income is a credential

## 