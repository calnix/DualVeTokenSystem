# EscrowedMoca Overview

EscrowedMoca.sol is a token escrow contract that enables users to escrow Moca tokens in exchange for non-transferable esMoca (escrowed MOCA) tokens.
- Moca is escrowed 1:1 with esMoca 
- contract features flexible redemption mechanisms with varying {penalty, lockDuration}.
- users are able to choose between different redemption options based on their time preferences and penalty tolerance; similar to early bond redemption.
- penalty distribution is split between voters and treasury, as governed by the percentage value of `VOTERS_PENALTY_SPLIT`.
- whitelisted transfers are possible for system integration [i.e. depositing esMoca in VotingController by `ASSET_MANAGER_ROLE`]

## Wider background colour

**esMoca is given out to:**

1. validators as discretionary rewards
2. voters receive their voting rewards as esMoca [from verification fee split]
3. verifiers receive subsidies as esMoca

**Process-wise:**
1. USD8 fees must be withdrawn from PaymentsController, and converted to Moca 
2. Moca must be then converted to esMoca, via this contract, EscrowedMoca.sol
3. esMoca must then be deposited into VotingController contract to support end of epoch rewards & subsidies claims.

## Key Design Components

### 1. **Flexible Redemption Options with Penalty Structure**

- Users can select from multiple redemption options, each with distinct lock durations and penalty rates.
- Penalties are calculated as `penaltyAmount = redemptionAmount - (redemptionAmount * receivablePct / PRECISION_BASE)`
**- Redemptions without penalties is supported.**
**- Instant redemption, without any delay/lockDuration is supported.**

### 2. **Dual Penalty Distribution System**

- Penalties are split between voters and treasury
- `VOTERS_PENALTY_SPLIT` determines the percentage allocation to each party (2dp precision: 100 = 1%)
- Penalty calculation: `penaltyToVoters = penaltyAmount * VOTERS_PENALTY_SPLIT / PRECISION_BASE`
- Remainder automatically goes to treasury: `penaltyToTreasury = penaltyAmount - penaltyToVoters`

### 3. **Whitelist-Controlled Transfer Restrictions**

- esMoca tokens are non-transferable by default
- Only whitelisted addresses can transfer tokens (e.g., Asset Manager to VotingController)
- Enforced by overriding ERC20 transfer functions: `transfer()` and `transferFrom()`
- Enables controlled system integration while maintaining non-transferable property for regular users

**Note: Transfer restrictions only validate the sender, not recipient.**
- I.e. only the sender needs to be whitelisted

### 4. **Precision-Aware Penalty Prevention**

- Blocks redemptions where penalties would be floored to zero due to integer division
- Ensures users cannot abuse small amounts to bypass penalty mechanisms
- Validates `penaltyAmount > 0` when penalties are expected, preventing system abuse

### 5. **Asset Manager Integration for Bulk Operations**

- `escrowMocaOnBehalf()` allows batch escrowing for multiple users
- `claimPenalties()` enables penalty collection for distribution to voters/treasury
- `releaseEscrowedMoca()` provides emergency release mechanism for `onlyAssetManager`, in the event an immediate exchange to Moca is required.

> The reverse of `releaseEscrowedMoca()` is `escrowMoca()` which anyone can call.

### 6. **Emergency Risk Management**

- Multi-tier access control with distinct roles (`EscrowedMocaAdmin`, `AssetManager`, `Monitor`, `GlobalAdmin`)
- Pausable functionality for operational safety              
- Unpause functionality                                      
- Freeze mechanism as ultimate kill switch
- Emergency exit with asset recovery to treasury when frozen


| **Function**                   | **Description**                                     | **Role Required**       |
|--------------------------------|-----------------------------------------------------|-------------------------|
| pause()                        | Pause contract for operational safety               | Monitor                 |
| unpause()                      | Resume contract operations                          | GlobalAdmin             |
| freeze()                       | Permanently disable contract as a kill switch       | GlobalAdmin             |
| emergencyExit()                | Recover all assets to treasury when frozen          | GlobalAdmin             |
|--------------------------------|-----------------------------------------------------|-------------------------|
| setRedemptionOption()          | Configure redemption options                        | EscrowedMocaAdmin       |
| setRedemptionOptionStatus()    | Enable or disable specific redemption options       | EscrowedMocaAdmin       |
| setWhitelistStatus()           | Manage transfer whitelist                           | EscrowedMocaAdmin       |
| escrowMocaOnBehalf()           | Batch escrow MOCA for multiple users                | AssetManager            |
| releaseEscrowedMoca()          | Emergency release of escrowed MOCA                  | AssetManager            |


## Contract State and Mappings

### Core State Variables

```solidity
uint256 public TOTAL_MOCA_ESCROWED;           // Total MOCA held in escrow
uint256 public VOTERS_PENALTY_SPLIT;         // Penalty allocation to voters (2dp precision)

// Penalty tracking
uint256 public ACCRUED_PENALTY_TO_VOTERS;    // Total penalties owed to voters
uint256 public CLAIMED_PENALTY_FROM_VOTERS;  // Total penalties claimed by voters
uint256 public ACCRUED_PENALTY_TO_TREASURY;  // Total penalties owed to treasury
uint256 public CLAIMED_PENALTY_FROM_TREASURY; // Total penalties claimed by treasury

uint256 public isFrozen;                     // Emergency freeze flag
```

### Mappings

**Redemption Configuration:**
```solidity
mapping(uint256 redemptionType => DataTypes.RedemptionOption redemptionOption) public redemptionOptions;
```

**User Redemption Tracking:**
```solidity
mapping(address user => mapping(uint256 redemptionTimestamp => DataTypes.Redemption redemption)) public redemptionSchedule;
```

**Transfer Control:**
```solidity
mapping(address addr => bool isWhitelisted) public whitelist;
```

## Data Structures

### RedemptionOption
```solidity
struct RedemptionOption {
    uint128 lockDuration;    // Seconds until redemption available (0 = instant)
    uint128 receivablePct;   // Percentage received (1-10,000, where 10,000 = 100%)
    bool isEnabled;          // Whether option is currently available
}
```

### Redemption
```solidity
struct Redemption {
    uint256 mocaReceivable;  // Total MOCA claimable at redemption timestamp
    uint256 claimed;         // Amount already claimed
    uint256 penalty;         // Penalty amount applied
}
```

## Core Functions

### User Functions

#### `escrowMoca(uint256 amount)`
Converts MOCA tokens to esMOCA at 1:1 ratio.

**Process:**
1. Validates amount > 0
2. Transfers MOCA from user to contract
3. Mints equivalent esMOCA to user
4. Updates `TOTAL_MOCA_ESCROWED`
5. Emits `EscrowedMoca` event

#### `selectRedemptionOption(uint256 redemptionOption, uint128 redemptionAmount)`
Initiates redemption using specified option.

**Process:**
1. Validates redemption amount and user balance
2. Retrieves and validates redemption option is enabled
3. Calculates receivable amount and penalty:
   ```solidity
   if(option.receivablePct == Constants.PRECISION_BASE) {
       mocaReceivable = redemptionAmount;  // No penalty
   } else {
       mocaReceivable = redemptionAmount * option.receivablePct / PRECISION_BASE;
       penaltyAmount = redemptionAmount - mocaReceivable;
   }
   ```
4. For instant redemption (lockDuration = 0): transfers immediately
5. For scheduled redemption: books for future claim
6. Burns esMOCA tokens
7. Distributes penalties between voters and treasury
8. Emits appropriate events

#### `claimRedemption(uint256 redemptionTimestamp)`
Claims scheduled redemption after lock period.

**Process:**
1. Validates redemption timestamp has passed
2. Calculates claimable amount: `mocaReceivable - claimed`
3. Updates claimed amount
4. Transfers MOCA to user
5. Updates `TOTAL_MOCA_ESCROWED`
6. Emits `Redeemed` event

### Asset Manager Functions

#### `escrowMocaOnBehalf(address[] users, uint256[] amounts)`
Batch escrow operation for multiple users.

**Process:**
1. Validates array lengths match
2. Iterates through users, validating addresses and amounts
3. Mints esMOCA to each user
4. Transfers total MOCA from caller
5. Updates `TOTAL_MOCA_ESCROWED`
6. Emits `StakedOnBehalf` event

#### `claimPenalties()`
Claims all accrued penalties for distribution.

**Process:**
1. Calculates total claimable penalties
2. Updates claimed penalty tracking variables
3. Transfers total penalty amount to Asset Manager
4. Updates `TOTAL_MOCA_ESCROWED`
5. Emits `PenaltyClaimed` event

#### `releaseEscrowedMoca(uint256 amount)`
Emergency release mechanism for Asset Manager.

**Process:**
1. Validates caller has sufficient esMOCA balance
2. Burns esMOCA from caller
3. Transfers equivalent MOCA to caller
4. Updates `TOTAL_MOCA_ESCROWED`
5. Emits `EscrowedMocaReleased` event

### Admin Functions

#### `setPenaltyToVoters(uint256 penaltyToVoters)`
Updates penalty split between voters and treasury.

- Range: (0, 10,000) for 0.01% to 99.99% precision
- Only callable by EscrowedMocaAdmin
- Emits `PenaltyToVotersUpdated` event

#### `setRedemptionOption(uint256 redemptionOption, uint128 lockDuration, uint128 receivablePct)`
Configures redemption option parameters.

**Validations:**
- `receivablePct` must be > 0 and ≤ 10,000
- `lockDuration` must be ≤ 888 days (~2.46 years)
- Only callable by EscrowedMocaAdmin

#### `setRedemptionOptionStatus(uint256 redemptionOption, bool enable)`
Enables or disables redemption options.

**Logic:**
- Prevents enabling already enabled options
- Prevents disabling already disabled options
- Emits appropriate status change events

#### `setWhitelistStatus(address addr, bool isWhitelisted)`
Manages transfer whitelist for system integration.

- Validates address is not zero
- Prevents redundant status changes
- Emits `AddressWhitelisted` event

## Transfer Restrictions

### ERC20 Override Implementation

```solidity
function transfer(address recipient, uint256 amount) public override whenNotPaused returns (bool) {
    require(whitelist[msg.sender], Errors.OnlyCallableByWhitelistedAddress());
    return super.transfer(recipient, amount);
}

function transferFrom(address sender, address recipient, uint256 amount) public override whenNotPaused returns (bool) {
    require(whitelist[sender], Errors.OnlyCallableByWhitelistedAddress());
    return super.transferFrom(sender, recipient, amount);
}
```

**Key Points:**
- Only sender must be whitelisted (not recipient)
- Maintains ERC20 compatibility while adding restrictions
- Enables controlled system integration (Asset Manager → VotingController)

## Risk Management

### Access Control Hierarchy

1. **EscrowedMocaAdmin**: Contract parameter configuration
2. **AssetManager**: Asset operations and penalty management
3. **Monitor**: Pause functionality (bot-triggered)
4. **GlobalAdmin**: Unpause and freeze authority (multisig)
5. **EmergencyExitHandler**: Asset recovery when frozen (bot-triggered)

### Circuit Breakers

#### `pause()` - Monitor Role
- Halts all user operations
- Can only be called when not frozen
- Provides rapid response to detected issues
- Will be called by bots attached to EOA addresses with the Monitor role

#### `unpause()` - GlobalAdmin Role
- Restores normal operations
- Requires multisig approval
- Can only be called when paused and not frozen

#### `freeze()` - GlobalAdmin Role
- Permanent kill switch activation
- Requires contract to be paused first
- Irreversible state change

#### `emergencyExit()` - EmergencyExitHandler Role
- Transfers all Moca to treasury address [obtained from AddressBook]
- Only callable when frozen
- Resets `TOTAL_MOCA_ESCROWED` to zero
- Final asset recovery mechanism

## Penalty Economics

### Calculation Flow

1. **Redemption Selection**: User chooses option with specific `receivablePct`
2. **Penalty Calculation**: `penalty = redemptionAmount - (redemptionAmount * receivablePct / 10,000)`
3. **Distribution Split**: 

```solidity
   penaltyToVoters = penalty * VOTERS_PENALTY_SPLIT / 10,000
   penaltyToTreasury = penalty - penaltyToVoters
```

4. **Accumulation**: Penalties are tracked in global variables
5. **Claiming**: Asset Manager claims total penalties for external distribution

### Example Penalty Scenarios

**Scenario 1: Standard Redemption**
- Redemption Amount: 1,000 esMOCA
- Redemption Option: 90% receivable, 30-day lock
- Penalty: 100 MOCA (10% of redemption)
- Voter Split: 70% → 70 MOCA to voters
- Treasury Split: 30% → 30 MOCA to treasury

**Scenario 2: Instant Redemption**
- Redemption Amount: 1,000 esMOCA  
- Redemption Option: 70% receivable, 0-day lock
- Penalty: 300 MOCA (30% of redemption)
- Voter Split: 70% → 210 MOCA to voters
- Treasury Split: 30% → 90 MOCA to treasury

## Integration Points

### VotingController Integration
- Asset Manager transfers esMoca to VotingController for epoch rewards & subsidy claims
- Whitelist mechanism enables this transfer while maintaining general restrictions
- Voters receive penalty shares as additional rewards

# Appendix

## selectRedemptionOption: Precision Loss Issue [minor]

This is regarding penalty calculation. Assume that:

1. `VOTERS_PENALTY_SPLIT` = 1 (0.01%)
2. `penaltyAmount` = 99

Therefore: 
- `penaltyToVoters` = 99 * 1 / 10000 = 0 (floored)
- `penaltyToTreasury` = 99

All penalty goes to treasury despite split configuration.
Recognized and ignored, as this edge case is contingent on `VOTERS_PENALTY_SPLIT = 1`.
