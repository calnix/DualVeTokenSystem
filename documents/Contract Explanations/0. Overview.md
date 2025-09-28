# MOCA Validator Protocol Overview

## Executive Summary

The Moca tokenomics protocol is a dual verification & voting system that enables credential issuers, verifiers, and token holders to participate in a robust ecosystem. 
The protocol consists of 6 core contracts that work together to manage verification fees, voting power, rewards distribution, and governance.

## Architecture Overview

### Core Components

1. **AddressBook** - Central registry for all protocol addresses
2. **AccessController** - Centralized access control layer managing permissions
3. **PaymentsController** - Manages verification fees and subsidy distribution
4. **VotingController** - Handles voting, delegation, and reward distribution
5. **VotingEscrowMoca** - veToken system for voting power generation
6. **EscrowedMoca** - Non-transferable escrowed token with redemption options

### System Flow

```
Issuers → Create Schemas → Verifiers Pay Fees → Fees Generate Rewards
                            ↓                   ↓
                            ↓                   Voters Lock Tokens → Vote on Pools → Claim Rewards
                            ↓
                           Verifiers Receive Subsidies Based on Voting & Expenditure    
```

## Key Mechanisms

### 1. Verification System

**Participants:**
- **Issuers**: Create schemas and set verification fees
- **Verifiers**: Pay fees to verify credentials
- **Schema**: Defines fee structure and links to voting pools

**Fee Distribution:**
- Protocol fees go to treasury
- Voting fees distributed to voters
- Net fees accrue to issuers

### 2. Voting Power System (veMOCA)

**Lock Mechanism:**
- Users lock MOCA or esMOCA tokens
- Voting power = (locked amount × remaining lock time) / max lock time
- Linear decay over time
- Supports delegation to professional voters

**Key Features:**
- Dual-token support (MOCA + esMOCA)
- Quad-accounting: tracks user, delegate, global, and lock-specific balances
- Non-transferable voting tokens
- 14-day minimum to 672-day maximum lock periods

### 3. Reward Distribution

**Epoch-Based System:**
- 14-day epochs
- Rewards distributed based on votes in previous epoch
- Two reward types:
  - **Verification Rewards**: From fees collected per pool
  - **Subsidies**: Global distribution based on verifier activity

**Claiming Process:**
- Users claim after epoch finalization
- Delegates can claim fees from delegated votes
- Unclaimed rewards swept after delay period

### 4. Delegation System

**Features:**
- Professional delegates register with fee percentage
- Users delegate lock voting power to delegates
- Delegates vote on behalf of users
- Fee sharing mechanism for rewards

### 5. Access Control

**Role Hierarchy:**
- **Global Admin**: Supreme authority
- **Operational Roles**: Monitor, CronJob (high-frequency)
- **Strategic Roles**: Contract admins (low-frequency)
- **Asset Manager**: Treasury operations
- **Emergency Exit Handler**: Crisis management

## Security Architecture

### Risk Management

1. **Pause/Freeze Mechanism**
   - Monitor role can pause contracts
   - Global admin can unpause
   - Freeze is permanent kill switch

2. **Emergency Exit**
   - Activated only when frozen
   - Returns all assets to users/treasury
   - Bypasses normal accounting

3. **Signature Verification**
   - EIP-712 typed signatures
   - Nonce-based replay protection
   - Verifier-specific signer addresses

### Critical Safeguards

- Minimum lock amounts prevent precision loss
- Epoch boundaries enforce timing constraints
- Fee increase delays prevent manipulation
- Withdrawal delays for unclaimed assets

## Economic Model

### Token Flows

1. **MOCA**: Governance token locked for voting power
2. **esMOCA**: Escrowed tokens with redemption penalties
3. **veMOCA**: Non-transferable voting power representation
4. **USD8**: Payment token for verification fees

### Incentive Alignment

- Verifiers stake MOCA for subsidy tiers
- Voters lock tokens for reward share
- Delegates earn fees for professional voting
- Issuers earn from verification activity

## Operational Workflow

### Epoch Lifecycle

1. **Active Epoch**: Users vote, verifications occur
2. **Epoch End**: Subsidies deposited, rewards calculated
3. **Finalization**: Pools processed, rewards allocated
4. **Claiming Period**: Users claim rewards
5. **Cleanup**: Unclaimed assets swept after delay

### Key Operations

**For Issuers:**
1. Create issuer account
2. Create schemas with fees
3. Link schemas to voting pools
4. Claim accrued fees

**For Verifiers:**
1. Create verifier account
2. Stake MOCA for subsidies
3. Deposit USD8 balance
4. Process verifications

**For Voters:**
1. Lock MOCA/esMOCA tokens
2. Vote on pools each epoch
3. Claim rewards after finalization
4. Manage delegations if desired

## Technical Specifications

### Epoch Duration
- 14 days per epoch
- All time calculations ignore leap years/seconds

### Precision & Limits
- Fee percentages: 2 decimal precision (10,000 = 100%)
- Minimum lock: 0.00001 MOCA/esMOCA
- USD8: 6 decimal precision
- MOCA/esMOCA: 18 decimal precision

### Gas Optimizations
- Struct packing for storage efficiency
- Memory caching in hot paths
- Batch operations where possible
- Unchecked math for safe operations

## Upgrade & Maintenance

### Upgradeable Components
- AccessController can be redeployed
- Role permissions can be modified
- Fee parameters adjustable with delays

### Immutable Components
- AddressBook deployment is permanent
- Core token logic non-upgradeable
- Epoch duration fixed

## Integration Points

### External Dependencies
- OpenZeppelin contracts for standards
- EIP-712 for signature verification
- SafeERC20 for token operations

### Protocol Interfaces
- Standardized role checking via AccessController
- Address resolution through AddressBook
- Cross-contract verification via interfaces

### Known Limitations
- Precision loss in reward calculations
- Permanent freeze mechanism
- No lock migration between users

## Summary

- The MOCA Validator Protocol creates a sustainable ecosystem where verification activity funds voter rewards, creating alignment between credential issuance and token holder interests. 
- The sophisticated voting escrow mechanism ensures long-term alignment while the delegation system enables professional participation.
