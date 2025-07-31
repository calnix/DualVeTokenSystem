# IGNORE

## Credential

### CredentialId

- CredentialId is generated off-chain based on credential specs.
- Issuer has to register it on-chain and set fees via `setupCredential()`

### Credential fees

- free credentials are allowed? i.e. 0 verification fees
- precision on USD8

## Verifiers

Opting to not bother tracking expenditure at a {verifier, credentialId} level.
- can be tracked via events and displayed on dashboard

## RISK

Objective 
- facilitate verifiers to retrieve remaining deposits
- facilitate issuers to retrieve unclaimed fees

However, we cannot rely on either party to act swiftly in a time-sensitive crisis.
So we must exfil assets on their behalf, if possible.
Onus is on us to react ASAP.

# Problems

## 1. Dual Id system

For some pair of issuer & verifier they could have the same Id.
*Does this matter; can it cause conflict?*
*then emergencyExit how? can, but headache*

**Solution**

1. Assess if ids are required for both verifiers and issuers
2. Alternatively, on generation, check tt the id is not taken under both mappings

## Does EIP712/ECDSA, etc work on Moca chain

Ask Athas

# Questions

1. Block/blacklist issuer/verifiers?