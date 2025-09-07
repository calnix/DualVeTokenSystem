# Test Suggestions for Delegated Rewards in VotingController.sol

## Unit Tests
- **Multi-Pool Ratios**: Simulate delegate voting on 3 pools with varying rewardsPerVote (e.g., 10, 20, 30). User delegates 30% of total; assert claim matches 30% of aggregated rewards minus fees.
- **Fee Edge Cases**: Test 0% fee (user gets full share), 100% fee (user gets 0, delegate gets all), and mid-values (e.g., 50% with 2dp precision).
- **Zero Checks**: Attempt claim with delegatePoolVotes=0 (should revert); ensure no zero-division if totalVotes=0 post-check.
- **Incremental Deposits**: Deposit rewards twice for a pool; claim before/after second deposit; assert incremental claimable matches updated rewardsPerVote.

## Integration Tests
- **Full Epoch Flow**: Create delegation, delegate votes on multiple pools, deposit rewards, finalize epoch. Multiple users claim; verify totals match delegate's aggregated rewards and proportions.
- **Multi-Delegate**: User delegates to 2 delegates; each votes differently; assert isolated claims per delegate without interference.

## Property-Based Tests (Foundry Fuzzing)
- **Proportionality Invariant**: Fuzz user delegation ratios (1-100%), delegate votes (1-1000 across 1-5 pools), fees (0-100%); assert user's net claim == (delegation % * total gross rewards) - fee.
- **No Over-Claim**: Fuzz multiple claims in same epoch; assert total claimed <= entitled share.
- **Edge Fuzz**: Fuzz zero/min/max values for votes, rewards, delegations; ensure reverts or 0 outputs as expected.

Run with high coverage; use Slither for static analysis.


### Unit Tests
- testFinalizeWithSmallRewards: Verify finalize sets totalRewards without revert when poolRewards * 1e18 < totalVotes.
- testClaimSmallRewardsLargeVoter: Ensure user with large vote share claims >0 from small poolRewards; small voter gets 0.
- testClaimSmallRewardsDelegate: Verify delegate claim distributes small rewards proportionally without 0 truncation revert.
- testSweepUnclaimedAfterTime: Confirm admin can sweep remainder after 1 year; reverts if too early or no unclaimed.
- testFinalizeMixedPools: Verify finalize sets totalRewards only for pools with rewards>0 and votes>0; skips 0-reward pools.
- testClaimZeroRewardPool: Attempt claim on 0-reward pool skips or reverts per-pool without blocking others.

### Integration Tests
- testFullEpochCycleSmallRewards: Simulate epoch with small fees, finalize, claim partial, sweep remainder.
- testDepositAdditionalSmall: Verify additional deposit adds to totalRewards; claims use direct calc correctly.
- testMultiPoolSmallRewards: Simulate epoch with varying pool rewards (some 0, some small); confirm per-pool distributions, partial claims, sweeps.

### Coverage Tests
- testEdgeZeroRewards: Finalize/claim with poolRewards=0; no transfer.
- testEdgeZeroVotes: Revert finalize if poolRewards>0 but totalVotes=0.
- testPrecisionLoss: Fuzz small poolRewards vs varying totalVotes; verify claimed <= totalRewards, remainder sweepable.

These tests target critical paths for small rewards handling and truncation avoidance. Use Foundry for fuzzing edge cases.
// ... existing code ...