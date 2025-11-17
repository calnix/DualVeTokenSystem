# Cross-contract flows

## Every Epoch: `PaymentsController` + `VotingController  + EscrowedMoca`

### 1. PaymentsController

```markdown
    - `cronJob` calls `withdrawProtocolFees()` and `withdrawVotersFees()`. 
    - `USD8` is withdrawn and sent to `PAYMENTS_CONTROLLER_TREASURY`
    - X amount of `USD8` is then converted to `esMoca` for the VotingController's voting rewards.
```

### 2. VotingController

```
- `cronJob` calls `depositEpochSubsidies(uint256 epoch, uint128 subsidies)`, to deposit `esMoca` as subsidies for verifiers.
- `cronJob` calls `finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint128[] calldata rewards)` to deposit `esMoca` as voting rewards for pools.
- esMoca subsidies are financed from the USD8 fees paid in step 1. [verifiers get a cut of paid fees back]
- esMoca rewards are financed from treasury; these are ecosystem incentives are giving out. [users are incentivized by us bankrolling it]
```
Now both verifiers can Voters can claim subsidies and rewards respectively for the prior epoch.

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

- CronJob function to release esMOCA → MOCA
- Burns esMOCA and transfers native MOCA (or wMOCA) to caller
- Asset flow: esMOCA (burned) → MOCA (transferred)

### VotingEscrowMoca

**`createLockFor()`**

1. `cronJob` calls `createLockFor(address user, uint128 expiry, uint128 moca, uint128 esMoca)`
2. allows protocol to create locks for users using either moca/esMoca or both, for a specified expiry.
3. if esMoca is used users will have to content with redemption options once lock expires. 

**Misc:**

1. `withdrawUnclaimedRewards`   ->  esMoca is transferred 
2. `withdrawUnclaimedSubsidies` ->  esMoca is transferred 
3. `withdrawRegistrationFees`   ->  native, else wrapped moca if transferred

`AssetManager` will call these functions on an ad-hoc basis to claim the respective assets listed above.
All claimed assets are sent to `VOTING_CONTROLLER_TREASURY`.

---

## EmergencyExit

### IssuerStakingController

`emergencyExit(address[] calldata issuerAddresses)`

- Exfiltrates issuer staked MOCA and pending unstake amounts to issuers
- Callable by EmergencyExitHandler or issuer themselves
- Assets transferred: native MOCA (falls back to wMOCA if transfer fails)

### `PaymentsController`

1. `emergencyExitFees()`

- called by `EmergencyExitHandler`; assets sent to `PAYMENTS_CONTROLLER_TREASURY`

2. `emergencyExitVerifiers(bytes32[] calldata verifierIds)`

- Exfiltrates verifier USD8 balances + staked MOCA → verifier asset managers
- Callable by EmergencyExitHandler or verifier themselves
- Assets: USD8 + native MOCA (or wMOCA if transfer fails)

3. `emergencyExitIssuers(bytes32[] calldata issuerIds)`

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
- Callable by EmergencyExitHandler only
- Assets: native MOCA + esMOCA returned
- Note: Burns veMOCA and returns principals; no state updates

### VotingController

1. `emergencyExit()`

- Exfiltrate all contract-held assets (rewards + subsidies + registration fees) 
- `esMoca` and native `moca` (else `wMoca`), transferred to `VOTING_CONTROLLER_TREASURY`
- rewards & subsidies would be in esMoca
- registrations fees would be in native moca




