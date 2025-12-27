// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

// External: OZ
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AccessControlEnumerable, AccessControl} from "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable, IAccessControl} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

// Core contract
import {VotingController} from "../../src/VotingController.sol";

// Standalone mock contracts for VC testing
import {MockPaymentsControllerVC} from "./mocks/MockPaymentsControllerVC.sol";
import {MockEscrowedMocaVC} from "./mocks/MockEscrowedMocaVC.sol";
import {MockVotingEscrowMocaVC} from "./mocks/MockVotingEscrowMocaVC.sol";

// Mocks from existing test utils
import {MockWMoca} from "../utils/MockWMoca.sol";

// Libraries
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {EpochMath} from "../../src/libraries/EpochMath.sol";

/**
 * @title VotingControllerHarness
 * @notice Base test harness for VotingController tests
 * @dev Deploys VotingController with mock external contracts and provides helper functions
 */
abstract contract VotingControllerHarness is Test {
    using stdStorage for StdStorage;

    // ═══════════════════════════════════════════════════════════════════
    // Contracts
    // ═══════════════════════════════════════════════════════════════════
    
    VotingController public votingController;
    MockPaymentsControllerVC public mockPaymentsController;
    MockEscrowedMocaVC public mockEsMoca;
    MockVotingEscrowMocaVC public mockVeMoca;
    MockWMoca public mockWMoca;

    // ═══════════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════════
    
    uint128 public constant EPOCH_DURATION = 14 days;
    uint128 public constant MIN_LOCK_DURATION = 28 days;
    uint128 public constant MAX_LOCK_DURATION = 728 days;
    uint256 public constant MOCA_TRANSFER_GAS_LIMIT = 2300;
    uint128 public constant PRECISION_BASE = 10_000;

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Privileged Roles
    // ═══════════════════════════════════════════════════════════════════
    
    address public globalAdmin = makeAddr("globalAdmin");
    address public votingControllerAdmin = makeAddr("votingControllerAdmin");
    address public monitorAdmin = makeAddr("monitorAdmin");
    address public cronJobAdmin = makeAddr("cronJobAdmin");
    address public monitor = makeAddr("monitor");
    address public cronJob = makeAddr("cronJob");
    address public emergencyExitHandler = makeAddr("emergencyExitHandler");
    address public assetManager = makeAddr("assetManager");
    
    // Admin addresses for mock contracts
    address public paymentsControllerAdmin = makeAddr("paymentsControllerAdmin");
    address public escrowedMocaAdmin = makeAddr("escrowedMocaAdmin");
    address public votingEscrowMocaAdmin = makeAddr("votingEscrowMocaAdmin");

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Treasuries
    // ═══════════════════════════════════════════════════════════════════
    
    address public votingControllerTreasury = makeAddr("votingControllerTreasury");
    address public paymentsControllerTreasury = makeAddr("paymentsControllerTreasury");
    address public esMocaTreasury = makeAddr("esMocaTreasury");

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Users (Personal Voters)
    // ═══════════════════════════════════════════════════════════════════
    
    address public voter1 = makeAddr("voter1");
    address public voter2 = makeAddr("voter2");
    address public voter3 = makeAddr("voter3");

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Delegates
    // ═══════════════════════════════════════════════════════════════════
    
    address public delegate1 = makeAddr("delegate1");
    address public delegate2 = makeAddr("delegate2");
    address public delegate3 = makeAddr("delegate3");

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Delegators (users who delegate to delegates)
    // ═══════════════════════════════════════════════════════════════════
    
    address public delegator1 = makeAddr("delegator1");
    address public delegator2 = makeAddr("delegator2");
    address public delegator3 = makeAddr("delegator3");

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Verifiers
    // ═══════════════════════════════════════════════════════════════════
    
    address public verifier1 = makeAddr("verifier1");
    address public verifier1Asset = makeAddr("verifier1Asset");
    address public verifier2 = makeAddr("verifier2");
    address public verifier2Asset = makeAddr("verifier2Asset");
    address public verifier3 = makeAddr("verifier3");
    address public verifier3Asset = makeAddr("verifier3Asset");

    // ═══════════════════════════════════════════════════════════════════
    // VotingController Parameters
    // ═══════════════════════════════════════════════════════════════════
    
    uint128 public delegateRegistrationFee = 1 ether;
    uint128 public maxDelegateFeePct = 5000; // 50%
    uint128 public feeIncreaseDelayEpochs = 2;
    uint128 public unclaimedDelayEpochs = 4;

    // ═══════════════════════════════════════════════════════════════════
    // PaymentsController Parameters
    // ═══════════════════════════════════════════════════════════════════
    
    uint256 public protocolFeePercentage = 500; // 5%
    uint256 public voterFeePercentage = 1000;   // 10%
    uint128 public feeIncreaseDelayPeriod = 14 days;

    // Dummy variable to prevent compiler optimization issues with EpochMath
    uint256 private dummy;

    // ═══════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Warp to a valid epoch (epoch 10) to avoid underflow in VotingController constructor
        // VotingController constructor does: previousEpoch = currentEpoch - 1
        // which would underflow if we're at epoch 0
        vm.warp(10 * EPOCH_DURATION + 1);

        // Deploy mock tokens
        mockWMoca = new MockWMoca();

        // Deploy standalone mock contracts
        mockEsMoca = new MockEscrowedMocaVC();
        mockVeMoca = new MockVotingEscrowMocaVC();
        mockPaymentsController = new MockPaymentsControllerVC();

        // Deploy VotingController
        votingController = new VotingController(
            address(mockWMoca),
            address(mockEsMoca),
            address(mockVeMoca),
            address(mockPaymentsController),
            votingControllerTreasury,
            globalAdmin,
            votingControllerAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler,
            assetManager,
            delegateRegistrationFee,
            maxDelegateFeePct,
            feeIncreaseDelayEpochs,
            unclaimedDelayEpochs,
            uint128(MOCA_TRANSFER_GAS_LIMIT)
        );

        // Grant CRON_JOB_ROLE to cronJob address
        vm.startPrank(cronJobAdmin);
        votingController.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();

        // Whitelist VotingController in EscrowedMoca for transfers
        address[] memory whitelist = new address[](1);
        whitelist[0] = address(votingController);
        mockEsMoca.setWhitelistStatus(whitelist, true);

        // Setup verifier asset managers in PaymentsController mock
        mockPaymentsController.setVerifierAssetManager(verifier1, verifier1Asset);
        mockPaymentsController.setVerifierAssetManager(verifier2, verifier2Asset);
        mockPaymentsController.setVerifierAssetManager(verifier3, verifier3Asset);

        // Approve esMoca for treasury to transfer to VotingController
        vm.startPrank(votingControllerTreasury);
        mockEsMoca.approve(address(votingController), type(uint256).max);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Epoch Math Helpers
    // ═══════════════════════════════════════════════════════════════════

    function getEpochNumber(uint128 timestamp) public returns (uint128) {
        dummy = 1;
        return timestamp / EPOCH_DURATION;
    }

    function getCurrentEpochNumber() public returns (uint128) {
        dummy = 1;
        return getEpochNumber(uint128(block.timestamp));
    }

    function getEpochStartForTimestamp(uint128 timestamp) public returns (uint128) {
        dummy = 1;
        return (timestamp / EPOCH_DURATION) * EPOCH_DURATION; // forge-lint: disable-line(divide-before-multiply)
    }

    function getEpochEndForTimestamp(uint128 timestamp) public returns (uint128) {
        dummy = 1;
        return getEpochStartForTimestamp(timestamp) + EPOCH_DURATION;
    }

    function getCurrentEpochStart() public returns (uint128) {
        dummy = 1;
        return getEpochStartForTimestamp(uint128(block.timestamp));
    }

    function getCurrentEpochEnd() public returns (uint128) {
        dummy = 1;
        return getEpochEndTimestamp(getCurrentEpochNumber());
    }

    function getEpochStartTimestamp(uint128 epoch) public returns (uint128) {
        dummy = 1;
        return epoch * EPOCH_DURATION;
    }

    function getEpochEndTimestamp(uint128 epoch) public returns (uint128) {
        dummy = 1;
        return (epoch + 1) * EPOCH_DURATION;
    }

    // ═══════════════════════════════════════════════════════════════════
    // State Snapshots
    // ═══════════════════════════════════════════════════════════════════

    struct EpochSnapshot {
        DataTypes.EpochState state;
        uint128 totalActivePools;
        uint128 poolsProcessed;
        uint128 totalSubsidiesAllocated;
        uint128 totalRewardsAllocated;
        uint128 totalRewardsClaimed;
        uint128 totalSubsidiesClaimed;
        uint128 totalRewardsWithdrawn;
        uint128 totalSubsidiesWithdrawn;
    }

    struct PoolSnapshot {
        bool isActive;
        uint128 totalVotes;
        uint128 totalRewardsAllocated;
        uint128 totalSubsidiesAllocated;
    }

    struct PoolEpochSnapshot {
        uint128 totalVotes;
        uint128 totalRewardsAllocated;
        uint128 totalSubsidiesAllocated;
        uint128 totalRewardsClaimed;
        uint128 totalSubsidiesClaimed;
        bool isProcessed;
    }

    struct DelegateSnapshot {
        bool isRegistered;
        uint128 currentFeePct;
        uint128 nextFeePct;
        uint128 nextFeePctEpoch;
        uint128 totalRewardsCaptured;
        uint128 totalFeesAccrued;
    }

    struct GlobalCountersSnapshot {
        uint128 currentEpochToFinalize;
        uint128 totalPoolsCreated;
        uint128 totalActivePools;
        uint128 totalSubsidiesDeposited;
        uint128 totalSubsidiesClaimed;
        uint128 totalRewardsDeposited;
        uint128 totalRewardsClaimed;
        uint128 totalRegistrationFeesCollected;
        uint128 totalRegistrationFeesClaimed;
    }

    function captureEpochState(uint128 epoch) internal view returns (EpochSnapshot memory snapshot) {
        (
            DataTypes.EpochState state,
            uint128 totalActivePools,
            uint128 poolsProcessed,
            uint128 totalSubsidiesAllocated,
            uint128 totalRewardsAllocated,
            uint128 totalRewardsClaimed,
            uint128 totalSubsidiesClaimed,
            uint128 totalRewardsWithdrawn,
            uint128 totalSubsidiesWithdrawn
        ) = votingController.epochs(epoch);

        snapshot.state = state;
        snapshot.totalActivePools = totalActivePools;
        snapshot.poolsProcessed = poolsProcessed;
        snapshot.totalSubsidiesAllocated = totalSubsidiesAllocated;
        snapshot.totalRewardsAllocated = totalRewardsAllocated;
        snapshot.totalRewardsClaimed = totalRewardsClaimed;
        snapshot.totalSubsidiesClaimed = totalSubsidiesClaimed;
        snapshot.totalRewardsWithdrawn = totalRewardsWithdrawn;
        snapshot.totalSubsidiesWithdrawn = totalSubsidiesWithdrawn;
    }

    function capturePoolState(uint128 poolId) internal view returns (PoolSnapshot memory snapshot) {
        (
            bool isActive,
            uint128 totalVotes,
            uint128 totalRewardsAllocated,
            uint128 totalSubsidiesAllocated
        ) = votingController.pools(poolId);

        snapshot.isActive = isActive;
        snapshot.totalVotes = totalVotes;
        snapshot.totalRewardsAllocated = totalRewardsAllocated;
        snapshot.totalSubsidiesAllocated = totalSubsidiesAllocated;
    }

    function capturePoolEpochState(uint128 epoch, uint128 poolId) internal view returns (PoolEpochSnapshot memory snapshot) {
        (
            uint128 totalVotes,
            uint128 totalRewardsAllocated,
            uint128 totalSubsidiesAllocated,
            uint128 totalRewardsClaimed,
            uint128 totalSubsidiesClaimed,
            bool isProcessed
        ) = votingController.epochPools(epoch, poolId);

        snapshot.totalVotes = totalVotes;
        snapshot.totalRewardsAllocated = totalRewardsAllocated;
        snapshot.totalSubsidiesAllocated = totalSubsidiesAllocated;
        snapshot.totalRewardsClaimed = totalRewardsClaimed;
        snapshot.totalSubsidiesClaimed = totalSubsidiesClaimed;
        snapshot.isProcessed = isProcessed;
    }

    function captureDelegateState(address delegate) internal view returns (DelegateSnapshot memory snapshot) {
        (
            bool isRegistered,
            uint128 currentFeePct,
            uint128 nextFeePct,
            uint128 nextFeePctEpoch,
            uint128 totalRewardsCaptured,
            uint128 totalFeesAccrued
        ) = votingController.delegates(delegate);

        snapshot.isRegistered = isRegistered;
        snapshot.currentFeePct = currentFeePct;
        snapshot.nextFeePct = nextFeePct;
        snapshot.nextFeePctEpoch = nextFeePctEpoch;
        snapshot.totalRewardsCaptured = totalRewardsCaptured;
        snapshot.totalFeesAccrued = totalFeesAccrued;
    }

    function captureGlobalCounters() internal view returns (GlobalCountersSnapshot memory snapshot) {
        snapshot.currentEpochToFinalize = votingController.CURRENT_EPOCH_TO_FINALIZE();
        snapshot.totalPoolsCreated = votingController.TOTAL_POOLS_CREATED();
        snapshot.totalActivePools = votingController.TOTAL_ACTIVE_POOLS();
        snapshot.totalSubsidiesDeposited = votingController.TOTAL_SUBSIDIES_DEPOSITED();
        snapshot.totalSubsidiesClaimed = votingController.TOTAL_SUBSIDIES_CLAIMED();
        snapshot.totalRewardsDeposited = votingController.TOTAL_REWARDS_DEPOSITED();
        snapshot.totalRewardsClaimed = votingController.TOTAL_REWARDS_CLAIMED();
        snapshot.totalRegistrationFeesCollected = votingController.TOTAL_REGISTRATION_FEES_COLLECTED();
        snapshot.totalRegistrationFeesClaimed = votingController.TOTAL_REGISTRATION_FEES_CLAIMED();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Creates pools as admin
     * @param count Number of pools to create
     */
    function _createPools(uint128 count) internal {
        vm.prank(votingControllerAdmin);
        votingController.createPools(count);
    }

    /**
     * @notice Register a delegate with the specified fee percentage
     * @param delegate The delegate address
     * @param feePct The fee percentage
     */
    function _registerDelegate(address delegate, uint128 feePct) internal {
        vm.deal(delegate, delegateRegistrationFee);
        vm.prank(delegate);
        votingController.registerAsDelegate{value: delegateRegistrationFee}(feePct);
    }

    /**
     * @notice Setup voting power for a user at an epoch
     * @param user The user address
     * @param epoch The epoch number
     * @param personalVP Personal voting power
     * @param delegatedVP Delegated voting power
     */
    function _setupVotingPower(address user, uint128 epoch, uint128 personalVP, uint128 delegatedVP) internal {
        mockVeMoca.setMockedBalanceAtEpochEnd(user, epoch, false, personalVP);
        mockVeMoca.setMockedBalanceAtEpochEnd(user, epoch, true, delegatedVP);
    }

    /**
     * @notice Setup specific delegated voting power for a user-delegate pair
     * @param user The delegator address
     * @param delegate The delegate address
     * @param epoch The epoch number
     * @param balance The delegated balance
     */
    function _setupDelegatedVotingPower(address user, address delegate, uint128 epoch, uint128 balance) internal {
        mockVeMoca.setMockedSpecificDelegatedBalance(user, delegate, epoch, balance);
    }

    /**
     * @notice Vote for pools as a user (personal votes)
     * @param user The voter address
     * @param poolIds Array of pool IDs
     * @param votes Array of vote amounts
     */
    function _vote(address user, uint128[] memory poolIds, uint128[] memory votes) internal {
        vm.prank(user);
        votingController.vote(poolIds, votes, false);
    }

    /**
     * @notice Vote for pools as a delegate (delegated votes)
     * @param delegate The delegate address
     * @param poolIds Array of pool IDs
     * @param votes Array of vote amounts
     */
    function _voteAsDelegated(address delegate, uint128[] memory poolIds, uint128[] memory votes) internal {
        vm.prank(delegate);
        votingController.vote(poolIds, votes, true);
    }

    /**
     * @notice Warp to the end of the current epoch (just past epoch end)
     */
    function _warpToEpochEnd() internal {
        uint128 epochEnd = getCurrentEpochEnd();
        vm.warp(epochEnd + 1);
    }

    /**
     * @notice Warp to a specific epoch
     * @param epoch The target epoch number
     */
    function _warpToEpoch(uint128 epoch) internal {
        uint128 epochStart = getEpochStartTimestamp(epoch);
        vm.warp(epochStart + 1);
    }

    /**
     * @notice Run through the entire epoch finalization process
     * @dev Automatically processes ALL active pools, filling in zeros for pools not in the provided arrays
     * @param poolIds Array of pool IDs with specific rewards/subsidies
     * @param rewards Array of reward amounts per pool (must match poolIds length)
     * @param subsidies Array of subsidy amounts per pool (must match poolIds length)
     */
    function _finalizeEpoch(
        uint128[] memory poolIds,
        uint128[] memory rewards,
        uint128[] memory subsidies
    ) internal {
        // Warp past epoch end first
        _warpToEpochEnd();

        // Step 1: End epoch
        vm.prank(cronJob);
        votingController.endEpoch();

        // Step 2: Process verifier checks (all cleared)
        address[] memory emptyVerifiers = new address[](0);
        vm.prank(cronJob);
        votingController.processVerifierChecks(true, emptyVerifiers);

        // Step 3: Process rewards and subsidies for ALL active pools
        // Build arrays for all active pools, using provided values where specified
        uint128 totalActivePools = votingController.TOTAL_ACTIVE_POOLS();
        uint128[] memory allPoolIds = new uint128[](totalActivePools);
        uint128[] memory allRewards = new uint128[](totalActivePools);
        uint128[] memory allSubsidies = new uint128[](totalActivePools);
        
        // Initialize all pools with zero rewards/subsidies
        for (uint128 i = 0; i < totalActivePools; ++i) {
            allPoolIds[i] = i + 1; // Pool IDs are 1-indexed
            allRewards[i] = 0;
            allSubsidies[i] = 0;
        }
        
        // Override with provided values
        for (uint256 i = 0; i < poolIds.length; ++i) {
            uint128 poolId = poolIds[i];
            if (poolId > 0 && poolId <= totalActivePools) {
                allRewards[poolId - 1] = rewards[i];
                allSubsidies[poolId - 1] = subsidies[i];
            }
        }
        
        // Calculate total esMoca needed
        uint128 totalRewards;
        uint128 totalSubsidies;
        for (uint256 i = 0; i < allRewards.length; ++i) {
            totalRewards += allRewards[i];
            totalSubsidies += allSubsidies[i];
        }
        
        // Mint esMoca to treasury
        mockEsMoca.mintForTesting(votingControllerTreasury, totalRewards + totalSubsidies);

        vm.prank(cronJob);
        votingController.processRewardsAndSubsidies(allPoolIds, allRewards, allSubsidies);

        // Step 4: Finalize epoch
        vm.prank(cronJob);
        votingController.finalizeEpoch();
    }

    /**
     * @notice Minimal finalization - ends and force finalizes epoch
     */
    function _forceFinalizeCurrentEpoch() internal {
        _warpToEpochEnd();
        vm.prank(globalAdmin);
        votingController.forceFinalizeEpoch();
    }

    /**
     * @notice Helper to create single-element arrays
     */
    function _toArray(uint128 value) internal pure returns (uint128[] memory) {
        uint128[] memory arr = new uint128[](1);
        arr[0] = value;
        return arr;
    }

    function _toArray(uint128 a, uint128 b) internal pure returns (uint128[] memory) {
        uint128[] memory arr = new uint128[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    function _toArray(uint128 a, uint128 b, uint128 c) internal pure returns (uint128[] memory) {
        uint128[] memory arr = new uint128[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        return arr;
    }

    function _toArray(uint128 a, uint128 b, uint128 c, uint128 d) internal pure returns (uint128[] memory) {
        uint128[] memory arr = new uint128[](4);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        arr[3] = d;
        return arr;
    }

    function _toArray(uint128 a, uint128 b, uint128 c, uint128 d, uint128 e) internal pure returns (uint128[] memory) {
        uint128[] memory arr = new uint128[](5);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
        arr[3] = d;
        arr[4] = e;
        return arr;
    }

    function _toAddressArray(address value) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = value;
        return arr;
    }

    function _toAddressArray(address a, address b) internal pure returns (address[] memory) {
        address[] memory arr = new address[](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }

    /**
     * @notice Helper to create nested array for delegated claims
     */
    function _toNestedArray(uint128[] memory inner) internal pure returns (uint128[][] memory) {
        uint128[][] memory arr = new uint128[][](1);
        arr[0] = inner;
        return arr;
    }

    function _toNestedArray(uint128[] memory a, uint128[] memory b) internal pure returns (uint128[][] memory) {
        uint128[][] memory arr = new uint128[][](2);
        arr[0] = a;
        arr[1] = b;
        return arr;
    }
}

