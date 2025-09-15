
# ---- Problems to fix:

## roles in VotingController

## risk fns

## view fns

-----

# Questions to ponder

1. do i need both usersEpochData & usersEpochPoolData
- usersEpochPoolData is sufficient for epoch level claiming, [it uses the votes from the same mapping in calc.] 
- usersEpochData is just a helpful epoch aggregation, across all pools

can the `totalRewards` in usersEpochData be diff. from sum of usersEpochPoolData? 
i.e. inconsistency in calculation

-----

## on optimal dataType structs

1. Epoch Struct - Final Optimal Layout
Key User Function Analysis:
- claimRewards(): Reads isFullyFinalized → totalRewardsAllocated → writes totalRewardsClaimed
- claimSubsidies(): Reads isFullyFinalized → totalSubsidiesAllocated → writes totalSubsidiesClaimed
- vote(): Reads isFullyFinalized → writes totalVotes

Critical Insight: isFullyFinalized is the gatekeeper for ALL user claim functions. It should be paired with the most frequently accessed data.

```solidity
struct Epoch {
    // Slot 1: CRITICAL USER PATH - Most frequent claim function optimization
    // claimRewards is the most common user action after epoch ends
    bool isFullyFinalized;          // Gate check for ALL user claims
    uint128 totalRewardsAllocated;  // Read immediately after gate check in claimRewards
    // 15 bytes padding

    // Slot 2: Rewards claim tracking (write target for claimRewards)
    uint128 totalRewardsClaimed;
    uint128 totalVotes;             // High-frequency write target for vote()

    // Slot 3: Subsidies user path (second most common claim type)
    uint128 totalSubsidiesAllocated;  // Read in claimSubsidies
    uint128 totalSubsidiesClaimed;    // Write target for claimSubsidies

    // Slot 4: Admin-only fields (lowest priority)
    uint128 totalSubsidiesDistributable;
    uint128 poolsFinalized;

    // Slot 5: Admin flags (lowest priority)
    bool isSubsidiesSet;
    bool residualsWithdrawn;
    // 30 bytes padding
}

```

2. PoolEpoch Struct - Optimal Layout

User Function Analysis:
- claimRewards(): Reads totalVotes and totalRewardsAllocated together for proportion calculation: (userVotes * totalRewards) / poolTotalVotes

```solidity
struct PoolEpoch {
    // Slot 1: CRITICAL for claimRewards calculation - accessed together
    uint128 totalVotes;
    uint128 totalRewardsAllocated;

    // Slot 2: Subsidies allocation and claims
    uint128 totalSubsidiesAllocated;
    uint128 totalRewardsClaimed;

    // Slot 3: Remaining fields
    uint128 totalSubsidiesClaimed;
    bool isProcessed;               // Admin-only flag
    // 15 bytes padding
}
```

3. Pool Struct - Optimal Layout
vote(): Reads poolId and isActive together for validation

```solidity
struct Pool {
    // Slot 1: Pool identity
    bytes32 poolId;

    // Slot 2: Vote validation path - accessed together in vote()
    bool isActive;
    uint128 totalVotes;
    // 15 bytes padding

    // Slot 3: Allocation tracking (set together in admin finalize)
    uint128 totalRewardsAllocated;
    uint128 totalSubsidiesAllocated;

    // Slot 4: Claim tracking
    uint128 totalRewardsClaimed;
    uint128 totalSubsidiesClaimed;
}
```

4. Delegate Struct - Keep Your Current Layout
Your current layout is actually optimal:
- isRegistered checked alone frequently
- currentFeePct and nextFeePct accessed in fee updates
- totalFees and totalFeesClaimed accessed together in claims
- Keeping nextFeePctEpoch as uint256 is safe (no need to risk uint128 overflow)

Why This Is The Most Optimal:
1. Slot 1 of Epoch is the killer optimization: Every user claim function starts with checking isFullyFinalized. The most common path (rewards claims) immediately needs totalRewardsAllocated. This saves 2,100 gas per claim by avoiding a second SLOAD.
2. PoolEpoch Slot 1: The claimRewards calculation (userVotes * totalRewards) / poolTotalVotes requires both values. Single SLOAD saves 2,100 gas per reward claim.
3. User-centric priority: Admin fields (poolsFinalized, isSubsidiesSet, etc.) are relegated to later slots, ensuring user functions don't load unnecessary admin state.
4. Frequency-based ordering: Rewards are more common than subsidies, so rewards get priority in slot positioning.

Total Gas Savings: Approximately 4,200+ gas saved per user claim transaction (the most frequent user interaction), with additional savings on vote transactions. This compounds significantly over the contract's lifetime.