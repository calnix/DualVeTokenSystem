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

### Early Redemption Penalty

The early redemption penalty is calculated based on the time elapsed since locking:

- Penalty decreases linearly as time locked increases

**Formula:**

```
    Penalty_Pct = (1 - (Elapsed Lock Time / Total Lock Time)) × Max_Penalty_Pct

    Alternatively,

    Penalty_Pct = (Time_left / Total_Lock_Time) × Max_Penalty_Pct
```

- Maximum penalty is 50% (configurable by governance)
- Penalty portion goes to treasury for future emission incentives
- Partial unlocking of veMoca is supported

**Example:**

- Lock: 1,000 MOCA for 365 days
- Early exit after 200 days
- Penalty = (1 - 200/365) × 50% = 22.6%
- User receives 774 MOCA
- Treasury receives 226 MOCA

## Locking esMoca for veMoca

- treated as MOCA