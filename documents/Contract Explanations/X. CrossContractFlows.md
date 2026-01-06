# Cross-contract flows

## Every Epoch: `PaymentsController` + `VotingController` + `EscrowedMoca`

### 1. PaymentsController

```markdown
- `cronJob` calls `withdrawProtocolFees(epoch)` and `withdrawVotersFees(epoch)`. 
- `USD8` is withdrawn and sent to `PAYMENTS_CONTROLLER_TREASURY`
- X amount of `USD8` is then converted to `esMoca` for the VotingController's voting rewards.
```

### 2. VotingController

**4-Step Epoch Finalization Flow:**

```
Step 1: `cronJob` calls `endEpoch()`
        - Transitions epoch from Voting → Ended state
        - Snapshots TOTAL_ACTIVE_POOLS for the epoch

Step 2: `cronJob` calls `processVerifierChecks(allCleared, verifiers[])`
        - Blocks specified verifiers from claiming subsidies
        - Call with allCleared=true to transition Ended → Verified state

Step 3: `cronJob` calls `processRewardsAndSubsidies(poolIds[], rewards[], subsidies[])`
        - Allocates rewards and subsidies to each pool
        - Transitions Verified → Processed state when all pools done

Step 4: `cronJob` calls `finalizeEpoch()`
        - Transfers esMoca (rewards + subsidies) from treasury to contract
        - Transitions Processed → Finalized state
        - Opens claims for voters and verifiers
```

**Funding Sources:**
- esMoca subsidies: financed from treasury; incentivizes verifier participation
- esMoca rewards: financed from treasury; incentivizes voter participation

Now both Verifiers and Voters can claim subsidies and rewards respectively for the prior epoch.

### 3. EscrowedMoca

**Routine airdrop distribution [users + validators]**

- `cronJob` calls `escrowMocaOnBehalf(address[] calldata users, uint256[] calldata amounts)`, depositing native Moca, minting esMoca to the addresses
- this is expected to occur on a weekly/bi-weekly basis.

**Every epoch: `claimPenalties()`**

1. `cronJob` will call `claimPenalties()` to collect accrued penalties [in native MOCA].
2. Claimed asset will be either native moca or wrapped moca - `_transferMocaAndWrapIfFailWithGasLimit`
3. Assets are transferred to `ESCROWED_MOCA_TREASURY`

--- 

## Ad-hoc: `EscrowedMoca` + `VotingController`+ `VotingEscrowMoca`

### EscrowedMoca 

**`releaseEscrowedMoca(uint256 amount)`**

- Called by `ASSET_MANAGER_ROLE` to release esMOCA → MOCA
- Burns esMOCA and transfers native MOCA (or wMOCA) to caller
- Asset flow: esMOCA (burned) → MOCA (transferred)

### VotingEscrowMoca

**`createLockFor()`**

```
cronJob calls:
  createLockFor(address[] users, uint128[] esMocaAmounts, uint128[] mocaAmounts, uint128 expiry)
```

- Allows protocol to batch-create locks for multiple users
- Can use either MOCA, esMoca, or both per user
- If esMoca is used, users will have to contend with redemption options once lock expires

### VotingController 

**Withdraw Functions:**

| Function                          | Asset                      | Role                |
|-----------------------------------|----------------------------|---------------------|
| `withdrawUnclaimedRewards(epoch)` | esMoca                     | ASSET_MANAGER_ROLE  |
| `withdrawUnclaimedSubsidies(epoch)`| esMoca                    | ASSET_MANAGER_ROLE  |
| `withdrawRegistrationFees()`      | native MOCA (or wMOCA)     | ASSET_MANAGER_ROLE  |

- Called on an ad-hoc basis after `UNCLAIMED_DELAY_EPOCHS` has passed
- All claimed assets are sent to `VOTING_CONTROLLER_TREASURY`

---

## EmergencyExit

### IssuerStakingController

`emergencyExit(address[] calldata issuerAddresses)`

- Exfiltrates issuer staked MOCA and pending unstake amounts to issuers
- Callable by EmergencyExitHandler or issuer themselves
- Assets transferred: native MOCA (falls back to wMOCA if transfer fails)

### `PaymentsController`

1. `emergencyExitFees()`

- Called by `EMERGENCY_EXIT_HANDLER_ROLE`
- Assets sent to `PAYMENTS_CONTROLLER_TREASURY`

2. `emergencyExitVerifiers(address[] calldata verifiers)`

- Exfiltrates verifier USD8 balances + staked MOCA → verifier asset managers
- Callable by EmergencyExitHandler or verifier themselves
- Assets: USD8 + native MOCA (or wMOCA if transfer fails)

3. `emergencyExitIssuers(address[] calldata issuers)`

- Exfiltrates issuer unclaimed USD8 fees → issuer asset managers
- Callable by EmergencyExitHandler or issuer themselves
- Assets: USD8

### `EscrowedMoca`

1. `claimPenalties()` [doubles up as emergency exit as well]

- called by `cronJob`
- assets sent to `ESCROWED_MOCA_TREASURY`

2. `emergencyExit(address[] calldata users)`

- Exfiltrates user esMOCA balances + pending redemptions → users (as MOCA)
- Callable by EmergencyExitHandler or users themselves
- Assets: native MOCA (or wMOCA if transfer fails)
- Note: Returns user esMOCA + pending redemptions, not penalties

### VotingEscrowMoca

1. `emergencyExit(bytes32[] calldata lockIds)`

- Returns locked MOCA/esMOCA principals to lock owners
- Callable by `EMERGENCY_EXIT_HANDLER_ROLE` only
- Assets: native MOCA + esMOCA returned
- Note: Burns veMOCA and returns principals

### VotingController

1. `emergencyExit()`

- Callable by `EMERGENCY_EXIT_HANDLER_ROLE` only (requires contract to be frozen first)
- Exfiltrates all contract-held assets (rewards + subsidies + registration fees) 
- `esMoca` and native `moca` (else `wMoca`) transferred to `VOTING_CONTROLLER_TREASURY`
- Rewards & subsidies: esMoca
- Registration fees: native MOCA
