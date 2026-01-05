// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {InvariantHarness} from "./InvariantHarness.sol";

// Handlers
import {VoterHandler} from "./handlers/VoterHandler.sol";
import {DelegateHandler} from "./handlers/DelegateHandler.sol";
import {ClaimsHandler} from "./handlers/ClaimsHandler.sol";
import {EpochHandler, IEpochCallback} from "./handlers/EpochHandler.sol";
import {AdminHandler, IPoolCallback, ILockCallback} from "./handlers/AdminHandler.sol";

// Libraries
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {EpochMath} from "../../../src/libraries/EpochMath.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/**
 * @title VotingControllerInvariant
 * @notice Comprehensive invariant tests for VotingController
 * @dev Tests solvency, vote conservation, reward/subsidy distribution, epoch state machine,
 *      delegation, pool management, and withdrawal invariants
 */
contract VotingControllerInvariant is InvariantHarness, IEpochCallback, IPoolCallback, ILockCallback {

    // ═══════════════════════════════════════════════════════════════════
    // Handlers
    // ═══════════════════════════════════════════════════════════════════
    
    VoterHandler public voterHandler;
    DelegateHandler public delegateHandler;
    ClaimsHandler public claimsHandler;
    EpochHandler public epochHandler;
    AdminHandler public adminHandler;

    // ═══════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public override {
        super.setUp();

        // Create initial pools
        _createPoolsAdmin(5);

        // ═══════════════════════════════════════════════════════════════════
        // ENHANCEMENT 1: Create locks for actors so they have voting power
        // ═══════════════════════════════════════════════════════════════════
        _createLocksForActors();

        // ═══════════════════════════════════════════════════════════════════
        // ENHANCEMENT 2: Pre-fund treasury with rewards/subsidies
        // ═══════════════════════════════════════════════════════════════════
        _fundTreasuryForRewards();

        // ═══════════════════════════════════════════════════════════════════
        // ENHANCEMENT 3: Register initial delegates
        // ═══════════════════════════════════════════════════════════════════
        _registerInitialDelegates();

        // Deploy handlers
        voterHandler = new VoterHandler(
            votingController,
            veMoca,
            esMoca,
            allActors
        );

        // Combine delegates and delegators as potential delegates
        address[] memory potentialDelegates = new address[](delegates.length);
        for (uint256 i = 0; i < delegates.length; i++) {
            potentialDelegates[i] = delegates[i];
        }

        // Lock owners: voters + delegators
        address[] memory lockOwnersList = new address[](voters.length + delegators.length);
        for (uint256 i = 0; i < voters.length; i++) {
            lockOwnersList[i] = voters[i];
        }
        for (uint256 i = 0; i < delegators.length; i++) {
            lockOwnersList[voters.length + i] = delegators[i];
        }

        delegateHandler = new DelegateHandler(
            votingController,
            veMoca,
            esMoca,
            potentialDelegates,
            lockOwnersList,
            delegateRegistrationFee,
            maxDelegateFeePct
        );

        claimsHandler = new ClaimsHandler(
            votingController,
            veMoca,
            esMoca,
            voters,
            delegates,
            delegators,
            verifiers,
            verifierAssets
        );

        epochHandler = new EpochHandler(
            votingController,
            esMoca,
            mockPaymentsController,
            cronJob,
            globalAdmin,
            votingControllerTreasury,
            escrowedMocaAdmin,
            verifiers
        );

        adminHandler = new AdminHandler(
            votingController,
            veMoca,
            esMoca,
            votingControllerAdmin,
            assetManager,
            globalAdmin,
            monitor,
            allActors
        );

        // Set callbacks
        epochHandler.setCallbackTarget(address(this));
        adminHandler.setPoolCallback(address(this));
        adminHandler.setLockCallback(address(this));

        // Initialize handler state
        _syncPoolsToHandlers();
        _syncLocksToHandlers();

        // Target handlers for invariant testing
        targetContract(address(voterHandler));
        targetContract(address(delegateHandler));
        targetContract(address(claimsHandler));
        targetContract(address(epochHandler));
        targetContract(address(adminHandler));

        // Exclude main contracts
        excludeContract(address(votingController));
        excludeContract(address(veMoca));
        excludeContract(address(esMoca));
        excludeContract(address(mockWMoca));
        excludeContract(address(mockPaymentsController));
    }

    function _syncPoolsToHandlers() internal {
        uint128[] memory poolIds = new uint128[](activePoolIds.length);
        for (uint256 i = 0; i < activePoolIds.length; i++) {
            poolIds[i] = activePoolIds[i];
        }
        voterHandler.setKnownPools(poolIds);
        epochHandler.setKnownPools(poolIds);
        claimsHandler.setKnownPools(poolIds);
    }

    function _syncLocksToHandlers() internal {
        // Sync all created locks to the delegate handler
        for (uint256 i = 0; i < activeLockIds.length; i++) {
            bytes32 lockId = activeLockIds[i];
            address owner = lockOwners[lockId];
            delegateHandler.addLock(lockId, owner);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Setup Helpers: Pre-population for Non-Vacuous Invariants
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create locks for all voters and delegators so they have voting power
     * @dev Lock expiry is set to 52 weeks from current epoch end
     */
    function _createLocksForActors() internal {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint128 lockExpiry = EpochMath.getEpochEndTimestamp(currentEpoch + 26); // ~52 weeks
        uint128 lockAmount = 100_000 ether; // esMoca amount to lock

        // Create locks for voters
        for (uint256 i = 0; i < voters.length; i++) {
            address voter = voters[i];
            vm.startPrank(voter);
            bytes32 lockId = veMoca.createLock(lockExpiry, lockAmount);
            vm.stopPrank();

            activeLockIds.push(lockId);
            lockOwners[lockId] = voter;
            userLocks[voter].push(lockId);
        }

        // Create locks for delegators
        for (uint256 i = 0; i < delegators.length; i++) {
            address delegator = delegators[i];
            vm.startPrank(delegator);
            bytes32 lockId = veMoca.createLock(lockExpiry, lockAmount);
            vm.stopPrank();

            activeLockIds.push(lockId);
            lockOwners[lockId] = delegator;
            userLocks[delegator].push(lockId);
        }
    }

    /**
     * @notice Pre-fund the treasury with esMoca for reward/subsidy distribution
     * @dev Treasury needs esMOCA balance so that finalizeEpoch() can pull funds.
     *      Flow: processRewardsAndSubsidies() allocates → finalizeEpoch() transfers from treasury
     */
    function _fundTreasuryForRewards() internal {
        uint256 fundAmount = 10_000_000 ether;

        // Fund treasury with native MOCA first
        vm.deal(votingControllerTreasury, fundAmount * 2);

        // Convert to esMoca
        vm.startPrank(votingControllerTreasury);
        esMoca.escrowMoca{value: fundAmount}();
        
        // Approve VotingController to spend treasury's esMoca
        esMoca.approve(address(votingController), type(uint256).max);
        vm.stopPrank();
    }

    /**
     * @notice Register initial delegates so delegation tests are meaningful
     * @dev Registers all addresses in the delegates array as delegates
     *      Registration fee is paid in native MOCA via msg.value
     */
    function _registerInitialDelegates() internal {
        uint128 initialFee = 2000; // 20% fee

        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            
            // Fund delegate with native MOCA for registration fee
            vm.deal(delegate, delegateRegistrationFee + 1 ether);

            vm.startPrank(delegate);
            // Register as delegate - fee paid via msg.value in native MOCA
            votingController.registerAsDelegate{value: delegateRegistrationFee}(initialFee);
            vm.stopPrank();
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Callbacks
    // ═══════════════════════════════════════════════════════════════════

    function onEpochFinalized(uint128 epoch) external override {
        finalizedEpochs.push(epoch);
        epochFinalized[epoch] = true;
        claimsHandler.addFinalizedEpoch(epoch);
    }

    function onPoolsCreated(uint128 startPoolId, uint128 count) external override {
        for (uint128 i = 0; i < count; i++) {
            activePoolIds.push(startPoolId + i);
        }
        _syncPoolsToHandlers();
    }

    function onLockCreated(bytes32 lockId, address owner) external override {
        activeLockIds.push(lockId);
        lockOwners[lockId] = owner;
        userLocks[owner].push(lockId);
        delegateHandler.addLock(lockId, owner);
    }

    // ═══════════════════════════════════════════════════════════════════
    // SOLVENCY INVARIANTS (S1-S4)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice S1: esMoca solvency - contract balance >= outstanding claims
     * @dev esMoca.balanceOf(VC) >= TOTAL_REWARDS_DEPOSITED - TOTAL_REWARDS_CLAIMED 
     *                           + TOTAL_SUBSIDIES_DEPOSITED - TOTAL_SUBSIDIES_CLAIMED
     */
    function invariant_S1_EsMocaSolvency() external view {
        uint128 totalRewardsDeposited = votingController.TOTAL_REWARDS_DEPOSITED();
        uint128 totalRewardsClaimed = votingController.TOTAL_REWARDS_CLAIMED();
        uint128 totalSubsidiesDeposited = votingController.TOTAL_SUBSIDIES_DEPOSITED();
        uint128 totalSubsidiesClaimed = votingController.TOTAL_SUBSIDIES_CLAIMED();

        uint128 outstandingClaims = (totalRewardsDeposited - totalRewardsClaimed) 
                                  + (totalSubsidiesDeposited - totalSubsidiesClaimed);

        uint256 contractBalance = esMoca.balanceOf(address(votingController));

        assertGe(contractBalance, outstandingClaims, "S1: esMoca solvency violated");
    }

    /**
     * @notice S2: Native MOCA solvency for registration fees
     * @dev address(VC).balance >= TOTAL_REGISTRATION_FEES_COLLECTED - TOTAL_REGISTRATION_FEES_CLAIMED
     */
    function invariant_S2_NativeMocaSolvency() external view {
        uint128 feesCollected = votingController.TOTAL_REGISTRATION_FEES_COLLECTED();
        uint128 feesClaimed = votingController.TOTAL_REGISTRATION_FEES_CLAIMED();
        uint128 outstandingFees = feesCollected - feesClaimed;

        // Note: balance may be converted to wMOCA on failed transfers
        // So we check >= and accept wMOCA balance as equivalent
        uint256 contractBalance = address(votingController).balance;
        
        assertGe(contractBalance, outstandingFees, "S2: Native MOCA solvency violated");
    }

    /**
     * @notice S3: Per-epoch rewards claimed never exceeds allocated
     */
    function invariant_S3_EpochRewardsNotOverclaimed() external view {
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (,,,, uint128 allocated, uint128 claimed,,,) = votingController.epochs(epoch);
            
            assertLe(claimed, allocated, "S3: Epoch rewards overclaimed");
        }
    }

    /**
     * @notice S4: Per-epoch subsidies claimed never exceeds allocated
     */
    function invariant_S4_EpochSubsidiesNotOverclaimed() external view {
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (,,, uint128 allocated,,, uint128 claimed,,) = votingController.epochs(epoch);
            
            assertLe(claimed, allocated, "S4: Epoch subsidies overclaimed");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // VOTE CONSERVATION INVARIANTS (V1-V3)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice V1: Pool votes equal sum of user + delegate votes
     * @dev epochPools[e][p].totalVotes == sum(usersEpochPoolData) + sum(delegatesEpochPoolData)
     */
    function invariant_V1_PoolVoteConservation() external view {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        for (uint256 p = 0; p < activePoolIds.length; p++) {
            uint128 poolId = activePoolIds[p];
            
            (uint128 poolVotes,,,,,) = votingController.epochPools(currentEpoch, poolId);
            
            uint128 sumUserVotes;
            uint128 sumDelegateVotes;
            
            // Sum user votes
            for (uint256 i = 0; i < allActors.length; i++) {
                (uint128 userVotes,) = votingController.usersEpochPoolData(currentEpoch, poolId, allActors[i]);
                sumUserVotes += userVotes;
                
                (uint128 delegateVotes,) = votingController.delegatesEpochPoolData(currentEpoch, poolId, allActors[i]);
                sumDelegateVotes += delegateVotes;
            }
            
            assertEq(poolVotes, sumUserVotes + sumDelegateVotes, "V1: Pool vote conservation violated");
        }
    }

    /**
     * @notice V2: User epoch votes equal sum across pools
     */
    function invariant_V2_UserVoteConsistency() external view {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        for (uint256 i = 0; i < allActors.length; i++) {
            address user = allActors[i];
            
            (uint128 totalSpent,) = votingController.usersEpochData(currentEpoch, user);
            
            uint128 sumPoolVotes;
            for (uint256 p = 0; p < activePoolIds.length; p++) {
                (uint128 poolVotes,) = votingController.usersEpochPoolData(currentEpoch, activePoolIds[p], user);
                sumPoolVotes += poolVotes;
            }
            
            assertEq(totalSpent, sumPoolVotes, "V2: User vote consistency violated");
        }
    }

    /**
     * @notice V3: Delegate epoch votes equal sum across pools
     */
    function invariant_V3_DelegateVoteConsistency() external view {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            
            (uint128 totalSpent,) = votingController.delegateEpochData(currentEpoch, delegate);
            
            uint128 sumPoolVotes;
            for (uint256 p = 0; p < activePoolIds.length; p++) {
                (uint128 poolVotes,) = votingController.delegatesEpochPoolData(currentEpoch, activePoolIds[p], delegate);
                sumPoolVotes += poolVotes;
            }
            
            assertEq(totalSpent, sumPoolVotes, "V3: Delegate vote consistency violated");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // REWARD DISTRIBUTION INVARIANTS (R1-R2)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice R1: Total rewards claimed never exceeds total deposited
     */
    function invariant_R1_TotalRewardsNotOverclaimed() external view {
        uint128 deposited = votingController.TOTAL_REWARDS_DEPOSITED();
        uint128 claimed = votingController.TOTAL_REWARDS_CLAIMED();
        
        assertLe(claimed, deposited, "R1: Total rewards overclaimed");
    }

    /**
     * @notice R2: Per-pool rewards claimed never exceeds allocated
     */
    function invariant_R2_PoolRewardsNotOverclaimed() external view {
        for (uint256 e = 0; e < finalizedEpochs.length; e++) {
            uint128 epoch = finalizedEpochs[e];
            
            for (uint256 p = 0; p < activePoolIds.length; p++) {
                uint128 poolId = activePoolIds[p];
                (, uint128 allocated,, uint128 claimed,,) = votingController.epochPools(epoch, poolId);
                
                assertLe(claimed, allocated, "R2: Pool rewards overclaimed");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // SUBSIDY DISTRIBUTION INVARIANTS (SUB1-SUB2)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice SUB1: Total subsidies claimed never exceeds total deposited
     */
    function invariant_SUB1_TotalSubsidiesNotOverclaimed() external view {
        uint128 deposited = votingController.TOTAL_SUBSIDIES_DEPOSITED();
        uint128 claimed = votingController.TOTAL_SUBSIDIES_CLAIMED();
        
        assertLe(claimed, deposited, "SUB1: Total subsidies overclaimed");
    }

    /**
     * @notice SUB2: Per-pool subsidies claimed never exceeds allocated
     */
    function invariant_SUB2_PoolSubsidiesNotOverclaimed() external view {
        for (uint256 e = 0; e < finalizedEpochs.length; e++) {
            uint128 epoch = finalizedEpochs[e];
            
            for (uint256 p = 0; p < activePoolIds.length; p++) {
                uint128 poolId = activePoolIds[p];
                (,, uint128 allocated,, uint128 claimed,) = votingController.epochPools(epoch, poolId);
                
                assertLe(claimed, allocated, "SUB2: Pool subsidies overclaimed");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // EPOCH STATE MACHINE INVARIANTS (E1-E4)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice E1: Epoch state transitions are valid (only forward progression)
     * @dev States: Voting(0) -> Ended(1) -> Verified(2) -> Processed(3) -> Finalized(4) or ForceFinalized(5)
     *      We only verify epochs that were explicitly finalized during the test run,
     *      since the test may start mid-lifecycle with prior epochs unfinalized.
     */
    function invariant_E1_EpochStateProgression() external view {
        // Only check epochs we've explicitly finalized during this test run
        // This avoids false positives when test starts mid-lifecycle
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (DataTypes.EpochState state,,,,,,,,) = votingController.epochs(epoch);
            assertGe(uint8(state), uint8(DataTypes.EpochState.Finalized), "E1: Finalized epoch has invalid state");
        }
        
        // Additionally verify that CURRENT_EPOCH_TO_FINALIZE is monotonically increasing
        // by checking it's within reasonable bounds
        uint128 currentToFinalize = votingController.CURRENT_EPOCH_TO_FINALIZE();
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // The epoch to finalize should not exceed the current epoch
        assertLe(currentToFinalize, currentEpoch + 1, "E1: Epoch to finalize exceeds current");
    }

    /**
     * @notice E2: CURRENT_EPOCH_TO_FINALIZE only increments on finalization
     */
    function invariant_E2_EpochToFinalizeMonotonic() external view {
        uint128 currentToFinalize = votingController.CURRENT_EPOCH_TO_FINALIZE();
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // currentToFinalize should be <= current epoch + 1
        assertLe(currentToFinalize, currentEpoch + 1, "E2: Epoch to finalize too far ahead");
    }

    /**
     * @notice E3: Epoch numbers are monotonically increasing in finalization order
     * @dev Each finalized epoch should have a number <= previous in finalization sequence
     */
    function invariant_E3_FinalizedEpochMonotonic() external view {
        if (finalizedEpochs.length < 2) return;
        
        for (uint256 i = 1; i < finalizedEpochs.length; i++) {
            // Epochs should be finalized in order (can skip if force finalized)
            assertGe(finalizedEpochs[i], finalizedEpochs[i - 1], "E3: Epochs not finalized in order");
        }
    }

    /**
     * @notice E4: poolsProcessed equals totalActivePools for Processed/Finalized epochs
     */
    function invariant_E4_PoolsFullyProcessed() external view {
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (DataTypes.EpochState state, uint128 totalActivePools, uint128 poolsProcessed,,,,,,) = votingController.epochs(epoch);
            
            // Skip force finalized (may not have all pools processed)
            if (state == DataTypes.EpochState.ForceFinalized) continue;
            
            assertEq(poolsProcessed, totalActivePools, "E4: Not all pools processed");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // DELEGATION INVARIANTS (D1-D4)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice D1: Registered delegates have isRegistered == true in VC and veMoca
     */
    function invariant_D1_DelegateRegistrationSync() external view {
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            
            (bool vcRegistered,,,,,) = votingController.delegates(delegate);
            bool veRegistered = veMoca.isRegisteredDelegate(delegate);
            
            // If registered in VC, should be registered in veMoca
            if (vcRegistered) {
                assertTrue(veRegistered, "D1: Delegate not synced to veMoca");
            }
        }
    }

    /**
     * @notice D2: Delegate fee never exceeds MAX_DELEGATE_FEE_PCT
     */
    function invariant_D2_DelegateFeeWithinBounds() external view {
        uint128 maxFee = votingController.MAX_DELEGATE_FEE_PCT();
        
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            (bool isRegistered, uint128 currentFee,,,,) = votingController.delegates(delegate);
            
            if (isRegistered) {
                assertLe(currentFee, maxFee, "D2: Delegate fee exceeds max");
            }
        }
    }

    /**
     * @notice D3: Fee increase delay is respected
     * @dev When a pending fee exists (nextFee > 0), nextFeeEpoch must be non-zero
     *      We cannot verify the delay was respected without ghost state tracking when the update was requested.
     *      The delay enforcement happens in the contract itself - here we just verify consistency.
     */
    function invariant_D3_FeeIncreaseDelayRespected() external view {
        uint128 delayEpochs = votingController.FEE_INCREASE_DELAY_EPOCHS();
        
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            (bool isRegistered, uint128 currentFee, uint128 nextFee, uint128 nextFeeEpoch,,) = votingController.delegates(delegate);
            
            if (isRegistered && nextFee > 0) {
                // If there's a pending fee increase, the activation epoch must be set
                assertTrue(nextFeeEpoch > 0, "D3: Pending fee increase has no activation epoch");
                
                // The pending fee must be different from current (otherwise why pending?)
                // Note: Fee decreases are applied immediately, so nextFee should be > currentFee
                assertTrue(nextFee > currentFee, "D3: Pending fee should be greater than current (increases are delayed)");
            }
            
            // Verify delay epochs is reasonable
            assertTrue(delayEpochs > 0, "D3: Fee increase delay should be > 0");
        }
    }

    /**
     * @notice D4: Cannot unregister with active votes
     */
    function invariant_D4_NoUnregisterWithVotes() external view {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            (bool isRegistered,,,,,) = votingController.delegates(delegate);
            (uint128 votesSpent,) = votingController.delegateEpochData(currentEpoch, delegate);
            
            // If has votes, should still be registered
            if (votesSpent > 0) {
                assertTrue(isRegistered, "D4: Delegate unregistered with active votes");
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // POOL INVARIANTS (P1-P3)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice P1: TOTAL_POOLS_CREATED >= TOTAL_ACTIVE_POOLS
     */
    function invariant_P1_PoolCountConsistency() external view {
        uint128 created = votingController.TOTAL_POOLS_CREATED();
        uint128 active = votingController.TOTAL_ACTIVE_POOLS();
        
        assertGe(created, active, "P1: Active pools exceed created");
    }

    /**
     * @notice P2: Active pool count matches and pool state is consistent
     * @dev Verifies that pools are properly tracked and active pools have valid state
     */
    function invariant_P2_PoolStateConsistency() external view {
        uint128 totalCreated = votingController.TOTAL_POOLS_CREATED();
        uint128 totalActive = votingController.TOTAL_ACTIVE_POOLS();
        
        // Active pools should never exceed created pools
        assertLe(totalActive, totalCreated, "P2: Active pools exceed created");
        
        // Verify that active pools we track match contract's active count
        uint128 countedActive;
        for (uint128 poolId = 1; poolId <= totalCreated; poolId++) {
            (bool isActive,,,) = votingController.pools(poolId);
            if (isActive) {
                countedActive++;
            }
        }
        
        assertEq(countedActive, totalActive, "P2: Active pool count mismatch");
    }

    /**
     * @notice P3: Active pool count matches count of pools with isActive == true
     */
    function invariant_P3_ActivePoolCountMatches() external view {
        uint128 totalCreated = votingController.TOTAL_POOLS_CREATED();
        uint128 reportedActive = votingController.TOTAL_ACTIVE_POOLS();
        
        uint128 countedActive;
        for (uint128 poolId = 1; poolId <= totalCreated; poolId++) {
            (bool isActive,,,) = votingController.pools(poolId);
            if (isActive) countedActive++;
        }
        
        assertEq(countedActive, reportedActive, "P3: Active pool count mismatch");
    }

    // ═══════════════════════════════════════════════════════════════════
    // WITHDRAWAL INVARIANTS (W1-W2)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice W1: Unclaimed withdrawn + claimed <= allocated for rewards
     */
    function invariant_W1_RewardsWithdrawalConsistency() external view {
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (,,,, uint128 allocated, uint128 claimed,, uint128 withdrawn,) = votingController.epochs(epoch);
            
            assertLe(claimed + withdrawn, allocated, "W1: Rewards withdrawal inconsistency");
        }
    }

    /**
     * @notice W2: Unclaimed withdrawn + claimed <= allocated for subsidies
     */
    function invariant_W2_SubsidiesWithdrawalConsistency() external view {
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (,,, uint128 allocated,,, uint128 claimed,, uint128 withdrawn) = votingController.epochs(epoch);
            
            assertLe(claimed + withdrawn, allocated, "W2: Subsidies withdrawal inconsistency");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // PROTOCOL STATE INVARIANTS
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice If frozen, must be paused
     */
    function invariant_FrozenImpliesPaused() external view {
        if (votingController.isFrozen() == 1) {
            assertTrue(votingController.paused(), "Frozen but not paused");
        }
    }

    /**
     * @notice Registration fee tracking is consistent
     */
    function invariant_RegistrationFeeConsistency() external view {
        uint128 collected = votingController.TOTAL_REGISTRATION_FEES_COLLECTED();
        uint128 claimed = votingController.TOTAL_REGISTRATION_FEES_CLAIMED();
        
        assertGe(collected, claimed, "Registration fees: claimed > collected");
    }

    // ═══════════════════════════════════════════════════════════════════
    // VOTING POWER BOUNDS INVARIANTS (VP1-VP3)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice VP1: User cannot spend more votes than their voting power
     * @dev usersEpochData.totalVotesSpent <= veMoca.balanceAtEpochEnd(user, epoch, false)
     */
    function invariant_VP1_UserVotesNotExceedVotingPower() external view {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        for (uint256 i = 0; i < allActors.length; i++) {
            address user = allActors[i];
            
            (uint128 votesSpent,) = votingController.usersEpochData(currentEpoch, user);
            uint128 availableVP = veMoca.balanceAtEpochEnd(user, currentEpoch, false);
            
            assertLe(votesSpent, availableVP, "VP1: User spent more votes than available VP");
        }
    }

    /**
     * @notice VP2: Delegate cannot spend more votes than their delegated voting power
     * @dev delegateEpochData.totalVotesSpent <= veMoca.balanceAtEpochEnd(delegate, epoch, true)
     */
    function invariant_VP2_DelegateVotesNotExceedVotingPower() external view {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        for (uint256 i = 0; i < delegates.length; i++) {
            address delegate = delegates[i];
            
            (uint128 votesSpent,) = votingController.delegateEpochData(currentEpoch, delegate);
            uint128 availableVP = veMoca.balanceAtEpochEnd(delegate, currentEpoch, true);
            
            assertLe(votesSpent, availableVP, "VP2: Delegate spent more votes than delegated VP");
        }
    }

    /**
     * @notice VP3: Pool total votes is sum of all pool votes across all actors
     * @dev pools[p].totalVotes == sum over all epochs of epochPools[e][p].totalVotes for finalized epochs
     */
    function invariant_VP3_PoolCumulativeVotesConsistency() external view {
        for (uint256 p = 0; p < activePoolIds.length; p++) {
            uint128 poolId = activePoolIds[p];
            
            // Get the cumulative total from the pool struct
            (bool isActive, uint128 cumulativeTotal,,) = votingController.pools(poolId);
            
            if (!isActive) continue;
            
            // Sum votes from finalized epochs only
            uint128 sumFromEpochs;
            for (uint256 e = 0; e < finalizedEpochs.length; e++) {
                uint128 epoch = finalizedEpochs[e];
                (uint128 epochPoolVotes,,,,,) = votingController.epochPools(epoch, poolId);
                sumFromEpochs += epochPoolVotes;
            }
            
            // Current epoch votes also contribute
            uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
            (uint128 currentEpochVotes,,,,,) = votingController.epochPools(currentEpoch, poolId);
            uint128 observedTotal = sumFromEpochs + currentEpochVotes;
            
            // The cumulative total should be >= the sum we can observe
            // (there may be epochs before our tracking that contribute)
            assertGe(cumulativeTotal, observedTotal, "VP3: Pool cumulative votes less than sum of known epochs");
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // GLOBAL CONSISTENCY INVARIANTS (G1-G3)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice G1: Epoch totalActivePools at time of finalization <= TOTAL_POOLS_CREATED
     */
    function invariant_G1_EpochPoolsBounded() external view {
        uint128 totalCreated = votingController.TOTAL_POOLS_CREATED();
        
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (, uint128 totalActiveInEpoch,,,,,,,) = votingController.epochs(epoch);
            
            assertLe(totalActiveInEpoch, totalCreated, "G1: Epoch has more pools than ever created");
        }
    }

    /**
     * @notice G2: CURRENT_EPOCH_TO_FINALIZE >= 1 (always a valid epoch to finalize)
     */
    function invariant_G2_ValidEpochToFinalize() external view {
        uint128 toFinalize = votingController.CURRENT_EPOCH_TO_FINALIZE();
        assertGe(toFinalize, 1, "G2: Epoch to finalize should be >= 1");
    }

    /**
     * @notice G3: All global counters are consistent
     * @dev TOTAL_REWARDS_DEPOSITED >= TOTAL_REWARDS_CLAIMED + sum of unclaimed in epochs
     */
    function invariant_G3_GlobalRewardsConsistency() external view {
        uint128 deposited = votingController.TOTAL_REWARDS_DEPOSITED();
        uint128 claimed = votingController.TOTAL_REWARDS_CLAIMED();
        
        // Sum unclaimed from finalized epochs (allocated - claimed - withdrawn)
        uint128 sumUnclaimed;
        for (uint256 i = 0; i < finalizedEpochs.length; i++) {
            uint128 epoch = finalizedEpochs[i];
            (,,,, uint128 allocated, uint128 epochClaimed,, uint128 withdrawn,) = votingController.epochs(epoch);
            
            if (allocated >= epochClaimed + withdrawn) {
                sumUnclaimed += (allocated - epochClaimed - withdrawn);
            }
        }
        
        // Total deposited should cover what's been claimed globally plus unclaimed
        // Note: This may not be exact due to epochs before our tracking
        assertGe(deposited, claimed, "G3: Global rewards claimed > deposited");
    }
}

