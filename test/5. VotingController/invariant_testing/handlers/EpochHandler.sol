// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {VotingController} from "../../../../src/VotingController.sol";
import {EscrowedMoca} from "../../../../src/EscrowedMoca.sol";
import {DataTypes} from "../../../../src/libraries/DataTypes.sol";
import {EpochMath} from "../../../../src/libraries/EpochMath.sol";
import {Constants} from "../../../../src/libraries/Constants.sol";
import {MockPaymentsControllerVC} from "../../mocks/MockPaymentsControllerVC.sol";

/**
 * @title EpochHandler
 * @notice Handler for epoch lifecycle management: endEpoch, processVerifierChecks, processRewardsAndSubsidies, finalizeEpoch
 * @dev Tracks ghost variables for epoch state machine invariants
 */
contract EpochHandler is Test {
    VotingController public vc;
    EscrowedMoca public esMoca;
    MockPaymentsControllerVC public mockPC;

    // ═══════════════════════════════════════════════════════════════════
    // Role Addresses
    // ═══════════════════════════════════════════════════════════════════
    
    address public cronJob;
    address public globalAdmin;
    address public votingControllerTreasury;
    address public escrowedMocaAdmin;

    // ═══════════════════════════════════════════════════════════════════
    // Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    uint128[] public knownPoolIds;
    address[] public verifiers;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Epoch State Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    // State transitions
    mapping(uint128 => DataTypes.EpochState) public ghost_epochState;
    
    // Finalized epochs
    uint128[] public ghost_finalizedEpochs;
    mapping(uint128 => bool) public ghost_isFinalized;
    
    // Allocations tracking
    mapping(uint128 => uint128) public ghost_epochRewardsAllocated;
    mapping(uint128 => uint128) public ghost_epochSubsidiesAllocated;
    mapping(uint128 => mapping(uint128 => uint128)) public ghost_poolRewardsAllocated;
    mapping(uint128 => mapping(uint128 => uint128)) public ghost_poolSubsidiesAllocated;
    
    // Deposits tracking
    uint128 public ghost_totalRewardsDeposited;
    uint128 public ghost_totalSubsidiesDeposited;

    // Blocked verifiers
    mapping(uint128 => mapping(address => bool)) public ghost_verifierBlocked;

    // Action counters
    uint256 public ghost_endEpochCalls;
    uint256 public ghost_processVerifierChecksCalls;
    uint256 public ghost_processRewardsSubsidiesCalls;
    uint256 public ghost_finalizeEpochCalls;
    uint256 public ghost_forceFinalizeEpochCalls;
    uint256 public ghost_warpCalls;

    // Callback for notifying other handlers
    address public callbackTarget;

    // ═══════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        VotingController _vc,
        EscrowedMoca _esMoca,
        MockPaymentsControllerVC _mockPC,
        address _cronJob,
        address _globalAdmin,
        address _votingControllerTreasury,
        address _escrowedMocaAdmin,
        address[] memory _verifiers
    ) {
        vc = _vc;
        esMoca = _esMoca;
        mockPC = _mockPC;
        cronJob = _cronJob;
        globalAdmin = _globalAdmin;
        votingControllerTreasury = _votingControllerTreasury;
        escrowedMocaAdmin = _escrowedMocaAdmin;
        
        for (uint256 i = 0; i < _verifiers.length; i++) {
            verifiers.push(_verifiers[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // External Setters
    // ═══════════════════════════════════════════════════════════════════

    function setKnownPools(uint128[] calldata poolIds) external {
        delete knownPoolIds;
        for (uint256 i = 0; i < poolIds.length; i++) {
            knownPoolIds.push(poolIds[i]);
        }
    }

    function setCallbackTarget(address target) external {
        callbackTarget = target;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Epoch Lifecycle
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice End the current epoch (Step 1)
     */
    function endEpoch() external {
        if (vc.paused()) return;

        uint128 epochToFinalize = vc.CURRENT_EPOCH_TO_FINALIZE();
        
        // Check epoch has ended
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epochToFinalize);
        if (block.timestamp <= epochEndTimestamp) return;

        // Check state is Voting
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state != DataTypes.EpochState.Voting) return;

        vm.prank(cronJob);
        try vc.endEpoch() {
            ghost_epochState[epochToFinalize] = DataTypes.EpochState.Ended;
            ghost_endEpochCalls++;
        } catch {}
    }

    /**
     * @notice Process verifier checks (Step 2)
     */
    function processVerifierChecks(bool allCleared, uint256 verifierSeed) external {
        if (vc.paused()) return;

        uint128 epochToFinalize = vc.CURRENT_EPOCH_TO_FINALIZE();
        
        // Check state is Ended
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state != DataTypes.EpochState.Ended) return;

        address[] memory verifiersToBlock;
        
        if (!allCleared && verifiers.length > 0) {
            // Block a random verifier
            verifiersToBlock = new address[](1);
            verifiersToBlock[0] = verifiers[bound(verifierSeed, 0, verifiers.length - 1)];
        } else {
            verifiersToBlock = new address[](0);
        }

        vm.prank(cronJob);
        try vc.processVerifierChecks(allCleared, verifiersToBlock) {
            if (allCleared) {
                ghost_epochState[epochToFinalize] = DataTypes.EpochState.Verified;
            } else {
                for (uint256 i = 0; i < verifiersToBlock.length; i++) {
                    ghost_verifierBlocked[epochToFinalize][verifiersToBlock[i]] = true;
                }
            }
            ghost_processVerifierChecksCalls++;
        } catch {}
    }

    /**
     * @notice Process rewards and subsidies for pools (Step 3)
     */
    function processRewardsAndSubsidies(
        uint128 rewardAmount,
        uint128 subsidyAmount
    ) external {
        if (vc.paused()) return;
        if (knownPoolIds.length == 0) return;

        uint128 epochToFinalize = vc.CURRENT_EPOCH_TO_FINALIZE();
        
        // Check state is Verified
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state != DataTypes.EpochState.Verified) return;

        // Filter to only active pools
        uint128[] memory activePools = _getActivePools();
        if (activePools.length == 0) return;

        // Bound amounts
        rewardAmount = uint128(bound(rewardAmount, 0, 1000 ether));
        subsidyAmount = uint128(bound(subsidyAmount, 0, 1000 ether));

        // Prepare arrays for active pools only
        uint128[] memory rewards = new uint128[](activePools.length);
        uint128[] memory subsidies = new uint128[](activePools.length);
        
        // Distribute rewards/subsidies across pools with votes
        uint128 totalRewards;
        uint128 totalSubsidies;
        
        for (uint256 i = 0; i < activePools.length; i++) {
            (uint128 poolVotes,,,,,) = vc.epochPools(epochToFinalize, activePools[i]);
            
            if (poolVotes > 0 && totalRewards == 0) {
                // Give all to first pool with votes for simplicity
                rewards[i] = rewardAmount;
                subsidies[i] = subsidyAmount;
                totalRewards = rewardAmount;
                totalSubsidies = subsidyAmount;
            }
        }

        // Mint esMoca to treasury for finalization
        uint256 totalNeeded = totalRewards + totalSubsidies;
        if (totalNeeded > 0) {
            vm.deal(votingControllerTreasury, votingControllerTreasury.balance + totalNeeded);
            vm.prank(votingControllerTreasury);
            esMoca.escrowMoca{value: totalNeeded}();
        }

        vm.prank(cronJob);
        try vc.processRewardsAndSubsidies(activePools, rewards, subsidies) {
            ghost_epochRewardsAllocated[epochToFinalize] += totalRewards;
            ghost_epochSubsidiesAllocated[epochToFinalize] += totalSubsidies;
            
            for (uint256 i = 0; i < activePools.length; i++) {
                ghost_poolRewardsAllocated[epochToFinalize][activePools[i]] += rewards[i];
                ghost_poolSubsidiesAllocated[epochToFinalize][activePools[i]] += subsidies[i];
            }
            
            // Check if fully processed
            (,uint128 totalActivePools, uint128 poolsProcessed,,,,,,) = vc.epochs(epochToFinalize);
            if (poolsProcessed == totalActivePools) {
                ghost_epochState[epochToFinalize] = DataTypes.EpochState.Processed;
            }
            
            ghost_processRewardsSubsidiesCalls++;
        } catch {}
    }

    /**
     * @notice Get only active pools from knownPoolIds
     */
    function _getActivePools() internal view returns (uint128[] memory) {
        // Count active pools first
        uint256 activeCount;
        for (uint256 i = 0; i < knownPoolIds.length; i++) {
            (bool isActive,,,) = vc.pools(knownPoolIds[i]);
            if (isActive) activeCount++;
        }
        
        // Build array of active pools
        uint128[] memory activePools = new uint128[](activeCount);
        uint256 idx;
        for (uint256 i = 0; i < knownPoolIds.length; i++) {
            (bool isActive,,,) = vc.pools(knownPoolIds[i]);
            if (isActive) {
                activePools[idx++] = knownPoolIds[i];
            }
        }
        
        return activePools;
    }

    /**
     * @notice Finalize epoch (Step 4)
     */
    function finalizeEpoch() external {
        if (vc.paused()) return;

        uint128 epochToFinalize = vc.CURRENT_EPOCH_TO_FINALIZE();
        
        // Check state is Processed
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state != DataTypes.EpochState.Processed) return;

        vm.prank(cronJob);
        try vc.finalizeEpoch() {
            ghost_epochState[epochToFinalize] = DataTypes.EpochState.Finalized;
            ghost_isFinalized[epochToFinalize] = true;
            ghost_finalizedEpochs.push(epochToFinalize);
            
            ghost_totalRewardsDeposited += ghost_epochRewardsAllocated[epochToFinalize];
            ghost_totalSubsidiesDeposited += ghost_epochSubsidiesAllocated[epochToFinalize];
            
            ghost_finalizeEpochCalls++;
            
            // Notify callback if set
            if (callbackTarget != address(0)) {
                IEpochCallback(callbackTarget).onEpochFinalized(epochToFinalize);
            }
        } catch {}
    }

    /**
     * @notice Force finalize epoch (emergency)
     */
    function forceFinalizeEpoch() external {
        if (vc.paused()) return;

        uint128 epochToFinalize = vc.CURRENT_EPOCH_TO_FINALIZE();
        
        // Check epoch has ended
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epochToFinalize);
        if (block.timestamp <= epochEndTimestamp) return;

        // Check not already finalized
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (uint8(state) >= uint8(DataTypes.EpochState.Finalized)) return;

        vm.prank(globalAdmin);
        try vc.forceFinalizeEpoch() {
            ghost_epochState[epochToFinalize] = DataTypes.EpochState.ForceFinalized;
            ghost_isFinalized[epochToFinalize] = true;
            ghost_forceFinalizeEpochCalls++;
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Time Manipulation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Warp time forward
     */
    function warpTime(uint256 secondsToWarp) external {
        secondsToWarp = bound(secondsToWarp, 1 hours, 28 days);
        vm.warp(block.timestamp + secondsToWarp);
        ghost_warpCalls++;
    }

    /**
     * @notice Warp to end of current epoch
     */
    function warpToEpochEnd() external {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint128 epochEnd = EpochMath.getEpochEndTimestamp(currentEpoch);
        vm.warp(epochEnd + 1);
        ghost_warpCalls++;
    }

    /**
     * @notice Complete full epoch finalization cycle
     */
    function completeEpochFinalization(uint128 rewardAmount, uint128 subsidyAmount) external {
        if (vc.paused()) return;
        if (knownPoolIds.length == 0) return;

        uint128 epochToFinalize = vc.CURRENT_EPOCH_TO_FINALIZE();

        // Step 1: Warp past epoch end
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epochToFinalize);
        if (block.timestamp <= epochEndTimestamp) {
            vm.warp(epochEndTimestamp + 1);
        }

        // Step 1: End epoch
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state == DataTypes.EpochState.Voting) {
            vm.prank(cronJob);
            try vc.endEpoch() {
                ghost_epochState[epochToFinalize] = DataTypes.EpochState.Ended;
                ghost_endEpochCalls++;
            } catch { return; }
        }

        // Step 2: Process verifier checks (all cleared)
        (state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state == DataTypes.EpochState.Ended) {
            address[] memory empty = new address[](0);
            vm.prank(cronJob);
            try vc.processVerifierChecks(true, empty) {
                ghost_epochState[epochToFinalize] = DataTypes.EpochState.Verified;
                ghost_processVerifierChecksCalls++;
            } catch { return; }
        }

        // Step 3: Process rewards and subsidies
        (state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state == DataTypes.EpochState.Verified) {
            // Get only active pools
            uint128[] memory activePools = _getActivePools();
            if (activePools.length == 0) return;

            // Bound amounts
            rewardAmount = uint128(bound(rewardAmount, 0, 1000 ether));
            subsidyAmount = uint128(bound(subsidyAmount, 0, 1000 ether));

            uint128[] memory rewards = new uint128[](activePools.length);
            uint128[] memory subsidies = new uint128[](activePools.length);
            uint128 totalRewards;
            uint128 totalSubsidies;

            for (uint256 i = 0; i < activePools.length; i++) {
                (uint128 poolVotes,,,,,) = vc.epochPools(epochToFinalize, activePools[i]);
                if (poolVotes > 0) {
                    rewards[i] = rewardAmount / uint128(activePools.length);
                    subsidies[i] = subsidyAmount / uint128(activePools.length);
                    totalRewards += rewards[i];
                    totalSubsidies += subsidies[i];
                }
            }

            // Mint esMoca to treasury
            uint256 totalNeeded = totalRewards + totalSubsidies;
            if (totalNeeded > 0) {
                vm.deal(votingControllerTreasury, votingControllerTreasury.balance + totalNeeded);
                vm.prank(votingControllerTreasury);
                esMoca.escrowMoca{value: totalNeeded}();
            }

            vm.prank(cronJob);
            try vc.processRewardsAndSubsidies(activePools, rewards, subsidies) {
                ghost_epochRewardsAllocated[epochToFinalize] = totalRewards;
                ghost_epochSubsidiesAllocated[epochToFinalize] = totalSubsidies;
                ghost_epochState[epochToFinalize] = DataTypes.EpochState.Processed;
                ghost_processRewardsSubsidiesCalls++;
            } catch { return; }
        }

        // Step 4: Finalize epoch
        (state,,,,,,,,) = vc.epochs(epochToFinalize);
        if (state == DataTypes.EpochState.Processed) {
            vm.prank(cronJob);
            try vc.finalizeEpoch() {
                ghost_epochState[epochToFinalize] = DataTypes.EpochState.Finalized;
                ghost_isFinalized[epochToFinalize] = true;
                ghost_finalizedEpochs.push(epochToFinalize);
                ghost_totalRewardsDeposited += ghost_epochRewardsAllocated[epochToFinalize];
                ghost_totalSubsidiesDeposited += ghost_epochSubsidiesAllocated[epochToFinalize];
                ghost_finalizeEpochCalls++;

                if (callbackTarget != address(0)) {
                    IEpochCallback(callbackTarget).onEpochFinalized(epochToFinalize);
                }
            } catch {}
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    function getFinalizedEpochs() external view returns (uint128[] memory) {
        return ghost_finalizedEpochs;
    }

    function getKnownPoolIds() external view returns (uint128[] memory) {
        return knownPoolIds;
    }
}

interface IEpochCallback {
    function onEpochFinalized(uint128 epoch) external;
}

