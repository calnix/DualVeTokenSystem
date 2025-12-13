# Test Suggestions for Delegated Rewards in VotingController.sol

## Unit Tests
- testClaimSmallRewardsDelegate: Verify delegate claim distributes small rewards proportionally without 0 truncation revert.
- testClaimSmallRewardsLargeVoter: Ensure user with large vote share claims >0 from small poolRewards; small voter gets 0.
- testClaimZeroRewardPool: Attempt claim on 0-reward pool skips or reverts per-pool without blocking others.
- testFeeEdgeCases: Test 0% fee (user gets full share), 100% fee (user gets 0, delegate gets all), and mid-values (e.g., 50% with 2dp precision).
- testFinalizeMixedPools: Verify finalize sets totalRewards only for pools with rewards>0 and votes>0; skips 0-reward pools.
- testFinalizeWithSmallRewards: Verify finalize sets totalRewards without revert when poolRewards * 1e18 < totalVotes.
- testIncrementalDeposits: Deposit rewards twice for a pool; claim before/after second deposit; assert incremental claimable matches updated rewardsPerVote.
- testMultiPoolRatios: Simulate delegate voting on 3 pools with varying rewardsPerVote (e.g., 10, 20, 30). User delegates 30% of total; assert claim matches 30% of aggregated rewards minus fees.
- testNoDoubleSweep: Call withdrawResidualSubsidies twice for same epoch; reverts on second with ResidualsAlreadyWithdrawn.
- testResidualSweepImmediate: Post-finalize, sweep residuals; assert transfer matches deposited - distributable, flag sets, event emits.
- testSubsidyFlooringResiduals: Simulate small subsidies with high votes causing flooring losses; verify residuals = deposited - distributable, and they aren't claimable.
- testSweepUnclaimedAfterTime: Confirm admin can sweep remainder after 1 year; reverts if too early or no unclaimed.
- testZeroChecks: Attempt claim with delegatePoolVotes=0 (should revert); ensure no zero-division if totalVotes=0 post-check.
- testZeroVotePoolSkip: Finalize with some pools at 0 votes; assert no allocation/subsidies set for them.

## Integration Tests
- testDepositAdditionalSmall: Verify additional deposit adds to totalRewards; claims use direct calc correctly.
- testFullCycleDepositClaimSweep: Deposit subsidies, finalize (with flooring), partial claims by verifiers, immediate residual sweep, delayed unclaimed sweep; assert totals balance.
- testFullEpochCycleSmallRewards: Simulate epoch with small fees, finalize, claim partial, sweep remainder.
- testFullEpochFlow: Create delegation, delegate votes on multiple pools, deposit rewards, finalize epoch. Multiple users claim; verify totals match delegate's aggregated rewards and proportions.
- testMultiDelegate: User delegates to 2 delegates; each votes differently; assert isolated claims per delegate without interference.
- testMultiPoolSmallRewards: Simulate epoch with varying pool rewards (some 0, some small); confirm per-pool distributions, partial claims, sweeps.
- testUnclaimedSweepAfterDelay: After delay, sweep unclaimed; assert only distributable - claimed transferred, residuals already swept separately.

## Property-Based Tests (Foundry Fuzzing)
- fuzzSubsidyDivision: Fuzz subsidies/votes/pools; assert allocated <= deposited, residuals >=0, claims <= allocated.
- testEdgeFuzz: Fuzz zero/min/max values for votes, rewards, delegations; ensure reverts or 0 outputs as expected.
- testNoOverClaim: Fuzz multiple claims in same epoch; assert total claimed <= entitled share.
- testProportionalityInvariant: Fuzz user delegation ratios (1-100%), delegate votes (1-1000 across 1-5 pools), fees (0-100%); assert user's net claim == (delegation % * total gross rewards) - fee.

## Coverage Tests
- testEdgeZeroRewards: Finalize/claim with poolRewards=0; no transfer.
- testEdgeZeroVotes: Revert finalize if poolRewards>0 but totalVotes=0.
- testPrecisionLoss: Fuzz small poolRewards vs varying totalVotes; verify claimed <= totalRewards, remainder sweepable.
- testRewardFlooringResiduals: Simulate claims with small votes causing non-zero remainders, verify they accumulate as unclaimed.
- testResidualSweep: After delay, confirm sweep transfers exact unclaimed amount and emits event.

These tests target critical paths for small rewards handling and truncation avoidance. Use Foundry for fuzzing edge cases.
Run with high coverage; use Slither for static analysis.

## PaymentsController Admin Change Tests

### Integration Tests
- testAdminTransition_FullCycle: Create issuer/verifier, change admin, verify old admin locked out while new admin has full control
- testMultipleAdminChanges: Chain multiple admin changes and verify access control at each step
- testAdminChange_WithPendingOperations: Change admin while schema fee increase is pending, verify new admin inherits control

These tests ensure proper access control during admin transitions, preventing unauthorized access while maintaining continuity of operations.

# Others

- change global admin on addressbook is applied to accesscontroller