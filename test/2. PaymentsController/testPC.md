# PaymentsController Test Flow Documentation

Structured similar to EscrowedMoca overview: state-style checkpoints with covered behaviors and negative cases.

## State 0: Deployment & Roles (PaymentsController.t.sol)
- Deploy controller, set core roles/treasuries, whitelist deduct callers in harness.
- Admin sets initial subsidy tiers (validation on lengths/order/percentages).

## State 1: Profiles & Schemas
- Create issuers/verifiers (asset/signer recorded).
- Create schemas: fee-bearing (issuer1/2) and zero-fee (issuer3).

## State 2: Funding Paths
- Verifier deposit/withdraw USD8 (caller must be asset manager).
- Balances updated and events emitted.

## State 3: deductBalance (fee > 0)
- Negative matrix: expired sig, zero amount, invalid schema, invalid signature, mismatched fee, no deposit, invalid caller (must be user or whitelisted).
- Positive: valid call books protocol/voter fees, updates balances/counters, emits events.
- Signature hash recorded in `_usedSignatureHashes`; nonce increments; user self-call (non-whitelisted) allowed and tracked.

## State 4: Fee Changes & Signers
- Signer address update works with new signatures.
- Fee decrease (instant) honored in deductBalance.
- Fee increase (delayed) honored; post-delay deductions use new fee; zero-fee path reverts once increase effective.

## State 5: deductBalanceZeroFee
- Zero-fee success when pending increase not yet active; counters increment.
- Revert when increase effective; state unchanged after revert.
- Caller gate mirrored (rogue rejected; user self-call allowed) and signature hash logged.

## State 6: Subsidies
- Stake MOCA, book subsidies per tier on deductions; tier eligibility checked.
- Unstake negative checks (amount, caller) covered; unstake flow TBD.

## State 7: Claiming & Asset Managers
- Issuer fee claims (happy + invalid caller/zero-claimable).
- Update assetManagerAddress for issuer/verifier; event includes role flag; new addresses honored for claims/withdraws.

## State 8: Admin Updates
- Protocol fee pct, voting fee pct, subsidy tiers, fee increase delay period, poolId updates (auth + validation).
- Role changes (admin addresses) with old/new caller checks.

## State 9: Risk & Emergency Exit
- EmergencyExitVerifiers/Issuers: invalid arrays, auth, zero-balance skip, multi-exit, event emission.
- Pause/freeze gating around emergency exit verified.

## State 10: Transfer Gas Limit (PCTransferGasLimitChanged.t.sol)
- Gas limit update paths and validations.

## State 11: Treasury Address (SetPCTreasuryAddress.t.sol)
- Treasury set/update scenarios and validations.
