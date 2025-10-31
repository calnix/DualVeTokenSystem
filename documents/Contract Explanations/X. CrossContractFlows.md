# Cross-contract flows

## Every Epoch: PaymentsController + VotingController

1. `cronJob` calls `withdrawProtocolFees()` and `withdrawVotersFees()`. 
    - `USD8` is withdrawn and sent to `PAYMENTS_CONTROLLER_TREASURY`
    - X amount of `USD8` is then converted to `esMoca` for the VotingController's voting rewards.

2. `cronJob` calls `depositEpochSubsidies(uint256 epoch, uint128 subsidies)`, to deposit `esMoca` as subsidies for verifiers.
3. `cronJob` calls `finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint128[] calldata rewards)` to deposit `esMoca` as voting rewards for pools.
    - this comes from step 1
4. Now both verifiers can Voters can claim subsidies and rewards respectively for the prior epoch.

## Routine airdrop distribution: users + validators [EscrowedMoca.sol]

1. `cronJob` calls `escrowMocaOnBehalf(address[] calldata users, uint256[] calldata amounts)`, depositing native Moca, minting esMoca to the addresses
2. this is expected to occur on a weekly/bi-weekly basis.

--- 

## Ad-hoc: CreateLockFor [VotingEscrowMoca.sol]

1. `cronJob` calls `createLockFor(address user, uint128 expiry, uint128 moca, uint128 esMoca)`
2. allows protocol to create locks for users using either moca/esMoca or both, for a specified expiry.
3. if esMoca is used users will have to content with redemption options once lock expires. 

## Ad-hoc: claimPenalties [EscrowedMoca.sol] 

1. `AssetManager` will call `claimPenalties()` to collect accrued esMoca penalties.
2. Claimed asset will be either native moca or wrapped moca - `_transferMocaAndWrapIfFailWithGasLimit`
3. Assets are transferred to `ESCROWED_MOCA_TREASURY`


## Ad-hoc: [VotingEscrowMoca.sol]

1. `withdrawUnclaimedRewards`   ->  esMoca is transferred 
2. `withdrawUnclaimedSubsidies` ->  esMoca is transferred 
3. `withdrawRegistrationFees`   ->  native, else wrapped moca if transferred

`AssetManager` will call these functions on an ad-hoc basis to claim the respective assets listed above.
All claimed assets are sent to `VOTING_CONTROLLER_TREASURY`.

---

## EmergencyExit

1. `PaymentsController.emergencyExitFees()`

- called by `EmergencyExitHandler`; assets sent to `PAYMENTS_CONTROLLER_TREASURY`

2. `EscrowedMoca.emergencyExitPenalties()`

- called by `EmergencyExitHandler`; assets sent to `ESCROWED_MOCA_TREASURY`

3. `VotingController.emergencyExit()`

- Exfiltrate all contract-held assets (rewards + subsidies + registration fees) 
- `esMoca` and native `moca` (else `wMoca`), transferred to `VOTING_CONTROLLER_TREASURY`
- rewards & subsidies would be in esMoca
- registrations fees would be in native moca




