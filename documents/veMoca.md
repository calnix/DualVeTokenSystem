# veMoca

## Staking MOCA for veMOCA

- Stake MOCA tokens to receive veMOCA (voting power)
- Longer lock periods result in higher veMOCA allocation
- veMOCA decays linearly over time, reducing voting power
- Formula-based calculation determines veMOCA amount based on stake amount and duration

## moca -> veMoca formula

Lock duration: {min: 7 Days,  max: 2 years}

Formula

```bash
veMOCA = MOCA_staked * (lockTimeInSeconds / MAX_LOCK_TIME_IN_SECONDS)

lockTimeInSeconds = min. value of 7 days, max. of 2yrs
MAX_LOCK_TIME_IN_SECONDS = 2 yrs
```

**Example**

- User chooses to lock 100 MOCA for 6 months
- 100 MOCA * (6 months / 2 years) = 25 veMOCA

User receives 25 veMOCA.

## Decay: linearly every second

- If stake for 2 years: veMOCA starts at full power and gradually reduces to 0 over 2 years.
- If you **extend the lock**, you maintain your veMOCA.

*Unclear*

```smlj
- extend your lock; what happens to veMOCA?
```

## Redeeming veMoca for Moca

- Staked $MOCA is redeemable in full only after full lock expiry.
- Early redemption is allowed with a penalty


### Penalty

## Locking esMoca for veMoca

- treated as MOCA