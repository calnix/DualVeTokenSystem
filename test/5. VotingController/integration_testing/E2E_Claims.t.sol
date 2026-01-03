// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IntegrationTestHarness} from "./IntegrationTestHarness.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {Events} from "../../../src/libraries/Events.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/**
 * @title E2E_Claims_Test
 * @notice End-to-end integration tests for all claim functions with exact math verification
 * @dev Tests personal rewards, delegated rewards, delegate fees, and subsidies
 */
contract E2E_Claims_Test is IntegrationTestHarness {

    function setUp() public override {
        super.setUp();
        // Create 5 pools for testing
        _createPools(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Personal Rewards - Exact Math
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimPersonalRewards_ExactMath() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create lock and vote
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        
        // Vote all VP for pool 1
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Define rewards
        uint128 pool1Rewards = 100 ether;

        // Finalize epoch with rewards
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // Capture before claim
        TokenBalanceSnapshot memory beforeTokens = captureTokenBalances(voter1);
        GlobalCountersSnapshot memory beforeGlobal = captureGlobalCounters();

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Reward
        // User is only voter with 100% of pool votes, gets 100% of rewards
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedReward = pool1Rewards; // User has 100% of pool votes

        // Claim personal rewards
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));

        // Capture after claim
        TokenBalanceSnapshot memory afterTokens = captureTokenBalances(voter1);
        GlobalCountersSnapshot memory afterGlobal = captureGlobalCounters();

        // ═══════════════════════════════════════════════════════════════════
        // Verify Exact Reward Amount
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterTokens.userEsMoca, beforeTokens.userEsMoca + expectedReward, "User should receive exact reward");
        assertEq(afterGlobal.totalRewardsClaimed, beforeGlobal.totalRewardsClaimed + expectedReward, "Global claimed should increase");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Personal Rewards - Multiple Users Pro-rata
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimPersonalRewards_ProRataMultipleUsers() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create locks for two voters with different amounts
        // Voter1: 100 ether principal, Voter2: 200 ether principal
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        _fundUserWithMoca(voter2, 200 ether);
        _fundUserWithEsMoca(voter2, 200 ether);
        _createLock(voter2, 200 ether, 200 ether, expiry);

        uint128 vp1 = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 vp2 = veMoca.balanceAtEpochEnd(voter2, currentEpoch, false);

        // Both vote for pool 1
        _vote(voter1, _toArray(1), _toArray(vp1));
        _vote(voter2, _toArray(1), _toArray(vp2));

        uint128 pool1Rewards = 300 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Rewards (Pro-rata)
        // Pool total = vp1 + vp2
        // Voter1: (vp1 / totalVotes) * rewards
        // Voter2: (vp2 / totalVotes) * rewards
        // Use uint256 to avoid overflow in intermediate calculation
        // ═══════════════════════════════════════════════════════════════════
        
        uint256 totalPoolVotes = uint256(vp1) + uint256(vp2);
        uint128 expectedReward1 = uint128((uint256(vp1) * uint256(pool1Rewards)) / totalPoolVotes);
        uint128 expectedReward2 = uint128((uint256(vp2) * uint256(pool1Rewards)) / totalPoolVotes);

        // Claim for voter1
        TokenBalanceSnapshot memory before1 = captureTokenBalances(voter1);
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));
        TokenBalanceSnapshot memory after1 = captureTokenBalances(voter1);

        // Claim for voter2
        TokenBalanceSnapshot memory before2 = captureTokenBalances(voter2);
        vm.prank(voter2);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));
        TokenBalanceSnapshot memory after2 = captureTokenBalances(voter2);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Pro-rata Rewards
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(after1.userEsMoca, before1.userEsMoca + expectedReward1, "Voter1 pro-rata reward");
        assertEq(after2.userEsMoca, before2.userEsMoca + expectedReward2, "Voter2 pro-rata reward");

        // Verify ratio matches principal ratio (2:1)
        // vp2/vp1 should equal 2 (since 400 ether principal vs 200 ether)
        assertTrue(vp2 > vp1, "Voter2 should have more VP");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Personal Rewards - Multiple Pools
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimPersonalRewards_MultiPool() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create lock
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        
        // Split votes across pools 1, 2, and 3
        uint128 votes1 = votingPower / 3;
        uint128 votes2 = votingPower / 3;
        uint128 votes3 = votingPower - votes1 - votes2;
        _vote(voter1, _toArray(1, 2, 3), _toArray(votes1, votes2, votes3));

        // Define different rewards per pool
        uint128 pool1Rewards = 50 ether;
        uint128 pool2Rewards = 100 ether;
        uint128 pool3Rewards = 150 ether;

        _finalizeEpoch(
            _toArray(1, 2, 3),
            _toArray(pool1Rewards, pool2Rewards, pool3Rewards),
            _toArray(uint128(0), uint128(0), uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Total (user is only voter in each pool)
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedTotal = pool1Rewards + pool2Rewards + pool3Rewards;

        // Claim from all pools at once
        TokenBalanceSnapshot memory beforeTokens = captureTokenBalances(voter1);
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1, 2, 3));
        TokenBalanceSnapshot memory afterTokens = captureTokenBalances(voter1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Total = Sum of Pool Rewards
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterTokens.userEsMoca, beforeTokens.userEsMoca + expectedTotal, "Total = sum of pool rewards");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Personal Rewards - Token Transfer Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimPersonalRewards_TokenTransfer() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        uint128 pool1Rewards = 100 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // Capture VC contract balance before claim
        uint256 vcBalanceBefore = esMoca.balanceOf(address(votingController));
        uint256 userBalanceBefore = esMoca.balanceOf(voter1);

        // Claim
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Token Transfer: VC -> User
        // ═══════════════════════════════════════════════════════════════════
        
        uint256 vcBalanceAfter = esMoca.balanceOf(address(votingController));
        uint256 userBalanceAfter = esMoca.balanceOf(voter1);

        assertEq(vcBalanceAfter, vcBalanceBefore - pool1Rewards, "VC balance decreased");
        assertEq(userBalanceAfter, userBalanceBefore + pool1Rewards, "User balance increased");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Personal Rewards - Double Claim Reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimPersonalRewards_DoubleClaim() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        _finalizeEpoch(
            _toArray(1),
            _toArray(100 ether),
            _toArray(uint128(0))
        );

        // First claim succeeds
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));

        // ═══════════════════════════════════════════════════════════════════
        // Verify Second Claim Reverts
        // ═══════════════════════════════════════════════════════════════════
        
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegated Rewards - Exact Math with Fee
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimDelegatedRewards_ExactMath() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 1000; // 10%

        // Register delegate
        _registerDelegate(delegate1, feePct);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Finalize initial epoch first (delegation takes effect next epoch)
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now we're at the epoch where delegation is effective
        uint128 voteEpoch = getCurrentEpochNumber();

        // Vote as delegate
        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        // Finalize vote epoch with rewards
        uint128 pool1Rewards = 100 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Net Rewards After Fee
        // grossReward = pool rewards (delegator has 100% of delegate's votes)
        // fee = gross * feePct / 10000
        // net = gross - fee
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 grossReward = pool1Rewards;
        uint128 expectedFee = (grossReward * feePct) / PRECISION_BASE;
        uint128 expectedNet = grossReward - expectedFee;

        // Claim delegated rewards
        TokenBalanceSnapshot memory beforeTokens = captureTokenBalances(delegator1);
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(voteEpoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        TokenBalanceSnapshot memory afterTokens = captureTokenBalances(delegator1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Net Reward After Fee Deduction
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterTokens.userEsMoca, beforeTokens.userEsMoca + expectedNet, "Delegator receives net after fee");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegated Rewards - Multiple Delegators Pro-rata
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimDelegatedRewards_MultiDelegator() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 1000; // 10%

        // Register delegate
        _registerDelegate(delegate1, feePct);

        // Create locks for multiple delegators
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        _fundUserWithMoca(delegator2, 200 ether);
        _fundUserWithEsMoca(delegator2, 200 ether);
        _createLockWithDelegation(delegator2, delegate1, 200 ether, 200 ether, expiry);

        // Finalize initial epoch first
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now at epoch where delegation is effective
        uint128 voteEpoch = getCurrentEpochNumber();

        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        uint128 pool1Rewards = 300 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // Get specific delegated balances
        uint128 d1Specific = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator1, delegate1, voteEpoch);
        uint128 d2Specific = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator2, delegate1, voteEpoch);

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Rewards
        // Each delegator's gross = (specificVP / totalDelegateVP) * poolRewards
        // Net = gross - (gross * feePct / 10000)
        // ═══════════════════════════════════════════════════════════════════
        
        // Use uint256 to avoid overflow in intermediate calculations
        uint128 d1Gross = uint128((uint256(d1Specific) * uint256(pool1Rewards)) / uint256(delegateVP));
        uint128 d1Fee = (d1Gross * feePct) / PRECISION_BASE;
        uint128 d1Net = d1Gross - d1Fee;

        uint128 d2Gross = uint128((uint256(d2Specific) * uint256(pool1Rewards)) / uint256(delegateVP));
        uint128 d2Fee = (d2Gross * feePct) / PRECISION_BASE;
        uint128 d2Net = d2Gross - d2Fee;

        // Claim for delegator1
        TokenBalanceSnapshot memory before1 = captureTokenBalances(delegator1);
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(voteEpoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        TokenBalanceSnapshot memory after1 = captureTokenBalances(delegator1);

        // Claim for delegator2
        TokenBalanceSnapshot memory before2 = captureTokenBalances(delegator2);
        vm.prank(delegator2);
        votingController.claimDelegatedRewards(voteEpoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        TokenBalanceSnapshot memory after2 = captureTokenBalances(delegator2);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Pro-rata Net Rewards
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(after1.userEsMoca, before1.userEsMoca + d1Net, "Delegator1 net reward");
        assertEq(after2.userEsMoca, before2.userEsMoca + d2Net, "Delegator2 net reward");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegated Rewards - Gross vs Net Verification
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimDelegatedRewards_GrossVsNet() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 1500; // 15%

        // Register delegate
        _registerDelegate(delegate1, feePct);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Finalize initial epoch first
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now at epoch where delegation is effective
        uint128 voteEpoch = getCurrentEpochNumber();

        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        uint128 pool1Rewards = 1000 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Gross, Fee, and Net
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 grossReward = pool1Rewards;
        uint128 expectedFee = (grossReward * feePct) / PRECISION_BASE;
        uint128 expectedNet = grossReward - expectedFee;

        // Claim delegated rewards
        TokenBalanceSnapshot memory before1 = captureTokenBalances(delegator1);
        vm.prank(delegator1);
        votingController.claimDelegatedRewards(voteEpoch, _toAddressArray(delegate1), _toNestedArray(_toArray(1)));
        TokenBalanceSnapshot memory after1 = captureTokenBalances(delegator1);

        // Claim delegate fees
        TokenBalanceSnapshot memory beforeDelegate = captureTokenBalances(delegate1);
        vm.prank(delegate1);
        votingController.claimDelegationFees(voteEpoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
        TokenBalanceSnapshot memory afterDelegate = captureTokenBalances(delegate1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify: Gross = Net + Fee
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 actualNet = uint128(after1.userEsMoca - before1.userEsMoca);
        uint128 actualFee = uint128(afterDelegate.userEsMoca - beforeDelegate.userEsMoca);

        assertEq(actualNet, expectedNet, "Net should match expected");
        assertEq(actualFee, expectedFee, "Fee should match expected");
        assertEq(actualNet + actualFee, grossReward, "Gross = Net + Fee");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegation Fees - Exact Math
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimDelegationFees_ExactMath() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 2000; // 20%

        // Register delegate
        _registerDelegate(delegate1, feePct);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Finalize initial epoch first
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now at epoch where delegation is effective
        uint128 voteEpoch = getCurrentEpochNumber();

        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        uint128 pool1Rewards = 500 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Fee
        // Fee = grossRewards * feePct / 10000
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedFee = (pool1Rewards * feePct) / PRECISION_BASE;

        // Claim fees
        TokenBalanceSnapshot memory beforeDelegate = captureTokenBalances(delegate1);
        DelegateSnapshot memory delegateStateBefore = captureDelegateState(delegate1);
        
        vm.prank(delegate1);
        votingController.claimDelegationFees(voteEpoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
        
        TokenBalanceSnapshot memory afterDelegate = captureTokenBalances(delegate1);
        DelegateSnapshot memory delegateStateAfter = captureDelegateState(delegate1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Exact Fee Amount
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterDelegate.userEsMoca, beforeDelegate.userEsMoca + expectedFee, "Delegate receives exact fee");
        assertEq(
            delegateStateAfter.totalFeesAccrued, 
            delegateStateBefore.totalFeesAccrued + expectedFee, 
            "Total fees accrued updated"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegation Fees - Multiple Delegators
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimDelegationFees_MultiDelegator() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 1000; // 10%

        // Register delegate
        _registerDelegate(delegate1, feePct);

        // Multiple delegators
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        _fundUserWithMoca(delegator2, 200 ether);
        _fundUserWithEsMoca(delegator2, 200 ether);
        _createLockWithDelegation(delegator2, delegate1, 200 ether, 200 ether, expiry);

        // Finalize initial epoch first
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now at epoch where delegation is effective
        uint128 voteEpoch = getCurrentEpochNumber();

        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        uint128 pool1Rewards = 300 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Total Fees from All Delegators
        // Each delegator's contribution to fee = their gross * feePct / 10000
        // ═══════════════════════════════════════════════════════════════════
        
        // Total fees = totalRewards * feePct / 10000
        uint128 totalExpectedFees = (pool1Rewards * feePct) / PRECISION_BASE;

        // Claim fees
        TokenBalanceSnapshot memory beforeDelegate = captureTokenBalances(delegate1);
        vm.prank(delegate1);
        votingController.claimDelegationFees(voteEpoch, _toAddressArray(delegator1, delegator2), _toNestedArray(_toArray(1), _toArray(1)));
        TokenBalanceSnapshot memory afterDelegate = captureTokenBalances(delegate1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Total Fees = Sum of All Delegator Fees
        // Allow 1-2 wei rounding error from per-delegator calculations
        // ═══════════════════════════════════════════════════════════════════
        
        assertApproxEqAbs(
            afterDelegate.userEsMoca, 
            beforeDelegate.userEsMoca + totalExpectedFees, 
            2, // 2 wei tolerance for rounding
            "Total fees from all delegators"
        );
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Delegation Fees - Zero Fee Reverts
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimDelegationFees_ZeroFee() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);
        uint128 feePct = 0; // 0% fee

        // Register delegate with 0% fee
        _registerDelegate(delegate1, feePct);

        // Create delegated lock
        _fundUserWithMoca(delegator1, 100 ether);
        _fundUserWithEsMoca(delegator1, 100 ether);
        _createLockWithDelegation(delegator1, delegate1, 100 ether, 100 ether, expiry);

        // Finalize initial epoch first
        _finalizeEpoch(_toArray(1), _toArray(uint128(0)), _toArray(uint128(0)));

        // Now at epoch where delegation is effective
        uint128 voteEpoch = getCurrentEpochNumber();

        uint128 delegateVP = veMoca.balanceAtEpochEnd(delegate1, voteEpoch, true);
        _voteAsDelegated(delegate1, _toArray(1), _toArray(delegateVP));

        uint128 pool1Rewards = 100 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // ═══════════════════════════════════════════════════════════════════
        // Verify Zero Fee Claim Reverts
        // ═══════════════════════════════════════════════════════════════════
        
        vm.expectRevert(Errors.NoFeesToClaim.selector);
        vm.prank(delegate1);
        votingController.claimDelegationFees(voteEpoch, _toAddressArray(delegator1), _toNestedArray(_toArray(1)));
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Subsidy Claims - Exact Math
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimSubsidies_ExactMath() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create lock and vote
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Define subsidies
        uint128 pool1Subsidies = 200 ether;

        // Setup mock for verifier accrued subsidy
        // Note: subsidies are set for the current epoch before finalization
        mockPaymentsController.setMockedVerifierAccruedSubsidies(currentEpoch, 1, verifier1, 50 ether);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(currentEpoch, 1, verifier2, 50 ether);
        mockPaymentsController.setMockedPoolAccruedSubsidies(currentEpoch, 1, 100 ether);

        _finalizeEpoch(
            _toArray(1),
            _toArray(uint128(0)),
            _toArray(pool1Subsidies)
        );

        // Get total pool accrued (sum of verifier accruals)
        uint128 poolTotalAccrued = 100 ether; // v1(50) + v2(50)

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Subsidy
        // subsidy = (verifierAccrued / poolTotalAccrued) * poolSubsidyAllocated
        // Use uint256 to avoid overflow
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedV1Subsidy = uint128((uint256(50 ether) * uint256(pool1Subsidies)) / uint256(poolTotalAccrued));

        // Claim subsidy
        TokenBalanceSnapshot memory beforeAsset = captureTokenBalances(verifier1Asset);
        vm.prank(verifier1Asset); // caller must be verifier's asset manager
        votingController.claimSubsidies(currentEpoch, verifier1, _toArray(1));
        TokenBalanceSnapshot memory afterAsset = captureTokenBalances(verifier1Asset);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Exact Subsidy Amount
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterAsset.userEsMoca, beforeAsset.userEsMoca + expectedV1Subsidy, "Verifier receives exact subsidy");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Subsidy Claims - Multiple Pools
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimSubsidies_MultiPool() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create lock and vote for multiple pools
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        uint128 votes1 = votingPower / 2;
        uint128 votes2 = votingPower - votes1;
        _vote(voter1, _toArray(1, 2), _toArray(votes1, votes2));

        // Define subsidies
        uint128 pool1Subsidies = 100 ether;
        uint128 pool2Subsidies = 200 ether;

        // Setup mock for verifier accrued subsidy (same verifier in both pools)
        mockPaymentsController.setMockedVerifierAccruedSubsidies(currentEpoch, 1, verifier1, 100 ether);
        mockPaymentsController.setMockedPoolAccruedSubsidies(currentEpoch, 1, 100 ether);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(currentEpoch, 2, verifier1, 200 ether);
        mockPaymentsController.setMockedPoolAccruedSubsidies(currentEpoch, 2, 200 ether);

        _finalizeEpoch(
            _toArray(1, 2),
            _toArray(uint128(0), uint128(0)),
            _toArray(pool1Subsidies, pool2Subsidies)
        );

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Total Subsidy
        // Verifier1 is only verifier, gets 100% of each pool's subsidy
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedTotal = pool1Subsidies + pool2Subsidies;

        // Claim from both pools
        TokenBalanceSnapshot memory beforeAsset = captureTokenBalances(verifier1Asset);
        vm.prank(verifier1Asset); // caller must be verifier's asset manager
        votingController.claimSubsidies(currentEpoch, verifier1, _toArray(1, 2));
        TokenBalanceSnapshot memory afterAsset = captureTokenBalances(verifier1Asset);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Sum of Pool Subsidies
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterAsset.userEsMoca, beforeAsset.userEsMoca + expectedTotal, "Total subsidy = sum of pools");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Subsidy Claims - Multiple Verifiers Same Pool
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimSubsidies_MultiVerifier() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup: Create lock and vote
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        // Define subsidies
        uint128 pool1Subsidies = 300 ether;

        // Setup: verifier1 has 60%, verifier2 has 40%
        mockPaymentsController.setMockedVerifierAccruedSubsidies(currentEpoch, 1, verifier1, 60 ether);
        mockPaymentsController.setMockedVerifierAccruedSubsidies(currentEpoch, 1, verifier2, 40 ether);
        mockPaymentsController.setMockedPoolAccruedSubsidies(currentEpoch, 1, 100 ether);

        _finalizeEpoch(
            _toArray(1),
            _toArray(uint128(0)),
            _toArray(pool1Subsidies)
        );

        uint128 poolTotalAccrued = 100 ether;

        // ═══════════════════════════════════════════════════════════════════
        // Calculate Expected Subsidies Pro-rata
        // Use uint256 to avoid overflow
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 expectedV1 = uint128((uint256(60 ether) * uint256(pool1Subsidies)) / uint256(poolTotalAccrued));
        uint128 expectedV2 = uint128((uint256(40 ether) * uint256(pool1Subsidies)) / uint256(poolTotalAccrued));

        // Claim for verifier1
        TokenBalanceSnapshot memory beforeV1 = captureTokenBalances(verifier1Asset);
        vm.prank(verifier1Asset); // caller must be verifier's asset manager
        votingController.claimSubsidies(currentEpoch, verifier1, _toArray(1));
        TokenBalanceSnapshot memory afterV1 = captureTokenBalances(verifier1Asset);

        // Claim for verifier2
        TokenBalanceSnapshot memory beforeV2 = captureTokenBalances(verifier2Asset);
        vm.prank(verifier2Asset); // caller must be verifier's asset manager
        votingController.claimSubsidies(currentEpoch, verifier2, _toArray(1));
        TokenBalanceSnapshot memory afterV2 = captureTokenBalances(verifier2Asset);

        // ═══════════════════════════════════════════════════════════════════
        // Verify Pro-rata Subsidies
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(afterV1.userEsMoca, beforeV1.userEsMoca + expectedV1, "Verifier1 pro-rata subsidy");
        assertEq(afterV2.userEsMoca, beforeV2.userEsMoca + expectedV2, "Verifier2 pro-rata subsidy");
    }

    // ═══════════════════════════════════════════════════════════════════
    // Test: Personal Rewards - Counter Updates
    // ═══════════════════════════════════════════════════════════════════

    function test_E2E_ClaimPersonalRewards_CounterUpdates() public {
        uint128 currentEpoch = getCurrentEpochNumber();
        uint128 expiry = getEpochEndTimestamp(currentEpoch + 5);

        // Setup
        _fundUserWithMoca(voter1, 100 ether);
        _fundUserWithEsMoca(voter1, 100 ether);
        _createLock(voter1, 100 ether, 100 ether, expiry);

        uint128 votingPower = veMoca.balanceAtEpochEnd(voter1, currentEpoch, false);
        _vote(voter1, _toArray(1), _toArray(votingPower));

        uint128 pool1Rewards = 100 ether;
        _finalizeEpoch(
            _toArray(1),
            _toArray(pool1Rewards),
            _toArray(uint128(0))
        );

        // Capture before
        GlobalCountersSnapshot memory globalBefore = captureGlobalCounters();
        EpochSnapshot memory epochBefore = captureEpochState(currentEpoch);
        PoolEpochSnapshot memory poolBefore = capturePoolEpochState(currentEpoch, 1);

        // Claim
        vm.prank(voter1);
        votingController.claimPersonalRewards(currentEpoch, _toArray(1));

        // Capture after
        GlobalCountersSnapshot memory globalAfter = captureGlobalCounters();
        EpochSnapshot memory epochAfter = captureEpochState(currentEpoch);
        PoolEpochSnapshot memory poolAfter = capturePoolEpochState(currentEpoch, 1);

        // ═══════════════════════════════════════════════════════════════════
        // Verify All Counter Updates
        // ═══════════════════════════════════════════════════════════════════
        
        assertEq(globalAfter.totalRewardsClaimed, globalBefore.totalRewardsClaimed + pool1Rewards, "Global claimed counter");
        assertEq(epochAfter.totalRewardsClaimed, epochBefore.totalRewardsClaimed + pool1Rewards, "Epoch claimed counter");
        assertEq(poolAfter.totalRewardsClaimed, poolBefore.totalRewardsClaimed + pool1Rewards, "Pool claimed counter");
    }
}

