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
```

Example: Lock 100 MOCA for 6 months: 100 MOCA * (6 months / 2 years) = 25 veMOCA

## Decay: decay linearly every second

- lock for 2 years: your veMOCA starts at full power and gradually reduces to 0 over 2 years.
- If you **extend the lock**, you maintain your veMOCA.

*Unclear*

- smlj extend your lock - what happens to veMOCA?