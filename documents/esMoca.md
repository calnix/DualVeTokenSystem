# esMoca

All rewards are expressed as esMOCA and subject to a common redemption structure.

- esMOCA redeemable 1:1 to MOCA; ignoring penalties.
- esMOCA is non-transferable, with the exception of contracts within our ecosystem

## esMoca and redemptions

esMOCA can be redeemed for MOCA through three different redemption paths, each with different lockup periods and penalties:

1. **Standard Redemption**
   - 60 day lockup period
   - No penalty (100% conversion)
   - Full amount becomes claimable after lockup

2. **Early Redemption**
   - 30 day lockup period
   - 50% penalty (50% conversion)
   - Half amount becomes claimable after lockup

3. **Instant Redemption**
   - No lockup period
   - 80% penalty (20% conversion)
   - Small portion becomes immediately claimable

**Redemption Process:**

1. User initiates redemption by selecting amount and redemption option
2. Selected esMOCA amount is locked for the chosen period
3. After lockup period, user can claim the converted MOCA amount
4. Redemption cannot be cancelled once initiated
5. Penalties from early/instant redemption are split:
   - 50% to treasury
   - 50% distributed to active stakers based on veMOCA holdings
   - Redemption initiator excluded from penalty distribution

*Note: Treasury/staker penalty distribution ratio must be configurable*

**Example:**
    1. User wishes to redeem 100 $esMOCA on June 1st and selects a redemption window of 15 days.
    2. 100 $esMOCA is locked for redemption period of 15 days
    3. User receives 20 $MOCA on June 16th (after 80% penalty)

$esMOCA penalties for early redemption are `redistributed` `50-50`:
    1. 50% sent to the treasury
    2. 50% distributed between all active stakers based on their $veMOCA holdings `at the time` of redemption (aka penalty redistribution)
    3. The person initiating the redemption is `excluded` from penalty redistribution

## locking esMOCA for veMOCA

- Conversion rate: 1 esMOCA = 1 MOCA when staked for veMOCA
- Basically treat esMOCA as MOCA and apply the same veMOCA formula to determine the amount of veMOCA receivable.
- However, cannot backdoor esMoca redemption options by locking esMOCA and hoping to get MOCA, through veMOCA.

