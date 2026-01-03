// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

// External: OZ
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AccessControlEnumerable, AccessControl} from "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable, IAccessControl} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

// Real contracts
import {VotingController} from "../../../src/VotingController.sol";
import {EscrowedMoca} from "../../../src/EscrowedMoca.sol";
import {VotingEscrowMoca} from "../../../src/VotingEscrowMoca.sol";

// Mock contracts (external dependencies only)
import {MockPaymentsControllerVC} from "../mocks/MockPaymentsControllerVC.sol";
import {MockWMoca} from "../../utils/MockWMoca.sol";

// Libraries
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {Events} from "../../../src/libraries/Events.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {Constants} from "../../../src/libraries/Constants.sol";
import {EpochMath} from "../../../src/libraries/EpochMath.sol";

/**
 * @title IntegrationTestHarness
 * @notice Base test harness for VotingController integration tests using REAL contracts
 * @dev Deploys real EscrowedMoca and VotingEscrowMoca contracts instead of mocks
 *      Only PaymentsController remains mocked as it's an external dependency
 */
abstract contract IntegrationTestHarness is Test {
    using stdStorage for StdStorage;

    // ═══════════════════════════════════════════════════════════════════
    // Real Contracts
    // ═══════════════════════════════════════════════════════════════════
    
    VotingController public votingController;
    EscrowedMoca public esMoca;
    VotingEscrowMoca public veMoca;

    // ═══════════════════════════════════════════════════════════════════
    // Mock Contracts (external dependencies only)
    // ═══════════════════════════════════════════════════════════════════
    
    MockPaymentsControllerVC public mockPaymentsController;
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
    address public votingEscrowMocaAdmin = makeAddr("votingEscrowMocaAdmin");
    address public escrowedMocaAdmin = makeAddr("escrowedMocaAdmin");
    address public monitorAdmin = makeAddr("monitorAdmin");
    address public cronJobAdmin = makeAddr("cronJobAdmin");
    address public monitor = makeAddr("monitor");
    address public cronJob = makeAddr("cronJob");
    address public emergencyExitHandler = makeAddr("emergencyExitHandler");
    address public assetManager = makeAddr("assetManager");

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Treasuries
    // ═══════════════════════════════════════════════════════════════════
    
    address public votingControllerTreasury = makeAddr("votingControllerTreasury");
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
    // EscrowedMoca Parameters
    // ═══════════════════════════════════════════════════════════════════
    
    uint256 public votersPenaltyPct = 1000; // 10%

    // Dummy variable to prevent compiler optimization issues with EpochMath
    uint256 private dummy;

    // ═══════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Warp to a valid epoch (epoch 10) to avoid underflow in VotingController constructor
        // VotingController constructor does: previousEpoch = currentEpoch - 1
        vm.warp(10 * EPOCH_DURATION + 1);

        // 1. Deploy mock wMoca (external dependency)
        mockWMoca = new MockWMoca();

        // 2. Deploy REAL EscrowedMoca
        esMoca = new EscrowedMoca(
            globalAdmin,
            escrowedMocaAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            esMocaTreasury,
            emergencyExitHandler,
            assetManager,
            votersPenaltyPct,
            address(mockWMoca),
            MOCA_TRANSFER_GAS_LIMIT
        );

        // 3. Deploy REAL VotingEscrowMoca
        veMoca = new VotingEscrowMoca(
            address(mockWMoca),
            address(esMoca),
            MOCA_TRANSFER_GAS_LIMIT,
            globalAdmin,
            votingEscrowMocaAdmin,
            monitorAdmin,
            cronJobAdmin,
            monitor,
            emergencyExitHandler
        );

        // 4. Deploy mock PaymentsController (external dependency)
        mockPaymentsController = new MockPaymentsControllerVC();

        // 5. Deploy VotingController with REAL esMoca and veMoca
        votingController = new VotingController(
            DataTypes.VCContractAddresses({
                wMoca: address(mockWMoca),
                esMoca: address(esMoca),
                veMoca: address(veMoca),
                paymentsController: address(mockPaymentsController),
                votingControllerTreasury: votingControllerTreasury
            }),
            DataTypes.VCRoleAddresses({
                globalAdmin: globalAdmin,
                votingControllerAdmin: votingControllerAdmin,
                monitorAdmin: monitorAdmin,
                cronJobAdmin: cronJobAdmin,
                monitorBot: monitor,
                emergencyExitHandler: emergencyExitHandler,
                assetManager: assetManager
            }),
            DataTypes.VCParams({
                delegateRegistrationFee: delegateRegistrationFee,
                maxDelegateFeePct: maxDelegateFeePct,
                feeDelayEpochs: feeIncreaseDelayEpochs,
                unclaimedDelayEpochs: unclaimedDelayEpochs,
                mocaTransferGasLimit: uint128(MOCA_TRANSFER_GAS_LIMIT)
            })
        );

        // ═══════════════════════════════════════════════════════════════════
        // Critical Integration Setup
        // ═══════════════════════════════════════════════════════════════════

        // 6. Whitelist VotingEscrowMoca in EscrowedMoca for esMoca transfers
        vm.startPrank(escrowedMocaAdmin);
        address[] memory veMocaWhitelist = new address[](1);
        veMocaWhitelist[0] = address(veMoca);
        esMoca.setWhitelistStatus(veMocaWhitelist, true);
        vm.stopPrank();

        // 7. Whitelist VotingController in EscrowedMoca for reward/subsidy transfers
        vm.startPrank(escrowedMocaAdmin);
        address[] memory vcWhitelist = new address[](1);
        vcWhitelist[0] = address(votingController);
        esMoca.setWhitelistStatus(vcWhitelist, true);
        vm.stopPrank();

        // 8. Set VotingController address in VotingEscrowMoca (for delegate registration sync)
        vm.startPrank(votingEscrowMocaAdmin);
        veMoca.setVotingController(address(votingController));
        vm.stopPrank();

        // 9. Grant CRON_JOB_ROLE to cronJob address in VotingController
        vm.startPrank(cronJobAdmin);
        votingController.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();

        // 10. Grant CRON_JOB_ROLE to cronJob address in VotingEscrowMoca
        vm.startPrank(cronJobAdmin);
        veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();

        // 11. Grant CRON_JOB_ROLE to cronJob address in EscrowedMoca
        vm.startPrank(cronJobAdmin);
        esMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();

        // 12. Setup verifier asset managers in PaymentsController mock
        mockPaymentsController.setVerifierAssetManager(verifier1, verifier1Asset);
        mockPaymentsController.setVerifierAssetManager(verifier2, verifier2Asset);
        mockPaymentsController.setVerifierAssetManager(verifier3, verifier3Asset);

        // 13. Whitelist votingControllerTreasury so it can transfer esMoca to VC
        vm.startPrank(escrowedMocaAdmin);
        address[] memory treasuryWhitelist = new address[](1);
        treasuryWhitelist[0] = votingControllerTreasury;
        esMoca.setWhitelistStatus(treasuryWhitelist, true);
        vm.stopPrank();

        // 14. Approve VotingController to spend treasury's esMoca
        vm.startPrank(votingControllerTreasury);
        esMoca.approve(address(votingController), type(uint256).max);
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

    function isValidEpochTime(uint256 timestamp) public returns (bool) {
        dummy = 1;
        return timestamp % EPOCH_DURATION == 0;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Voting Power Calculation Helpers
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Calculate expected slope from lock principal and max duration
     * @param moca MOCA amount in lock
     * @param esMocaAmt esMOCA amount in lock
     * @return slope The slope value
     */
    function calculateSlope(uint128 moca, uint128 esMocaAmt) public pure returns (uint128) {
        return (moca + esMocaAmt) / MAX_LOCK_DURATION;
    }

    /**
     * @notice Calculate expected bias from slope and expiry
     * @param slope The slope value
     * @param expiry The lock expiry timestamp
     * @return bias The bias value
     */
    function calculateBias(uint128 slope, uint128 expiry) public pure returns (uint128) {
        return slope * expiry;
    }

    /**
     * @notice Calculate voting power at a specific timestamp
     * @param bias The bias value
     * @param slope The slope value
     * @param timestamp The timestamp to calculate VP at
     * @return votingPower The voting power at timestamp
     */
    function calculateVotingPowerAt(uint128 bias, uint128 slope, uint128 timestamp) public pure returns (uint128) {
        uint128 decay = slope * timestamp;
        if (bias <= decay) return 0;
        return bias - decay;
    }

    /**
     * @notice Calculate voting power at epoch end for a lock
     * @param moca MOCA amount
     * @param esMocaAmt esMOCA amount
     * @param expiry Lock expiry
     * @param epoch Epoch number
     * @return votingPower The voting power at epoch end
     */
    function calculateVotingPowerAtEpochEnd(
        uint128 moca,
        uint128 esMocaAmt,
        uint128 expiry,
        uint128 epoch
    ) public returns (uint128) {
        uint128 epochEnd = getEpochEndTimestamp(epoch);
        if (epochEnd >= expiry) return 0;
        
        uint128 slope = calculateSlope(moca, esMocaAmt);
        return slope * (expiry - epochEnd);
    }

    // ═══════════════════════════════════════════════════════════════════
    // State Snapshots - VotingController
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

    struct UserAccountSnapshot {
        uint128 totalVotesSpent;
        uint128 totalRewards;
    }

    // ═══════════════════════════════════════════════════════════════════
    // State Snapshots - VotingEscrowMoca
    // ═══════════════════════════════════════════════════════════════════

    struct VeMocaGlobalSnapshot {
        uint128 totalLockedMoca;
        uint128 totalLockedEsMoca;
        DataTypes.VeBalance veGlobal;
        uint128 lastUpdatedTimestamp;
    }

    struct LockSnapshot {
        address owner;
        uint128 expiry;
        uint128 moca;
        uint128 esMoca;
        bool isUnlocked;
        address delegate;
        address currentHolder;
        uint128 delegationEpoch;
    }

    // ═══════════════════════════════════════════════════════════════════
    // State Snapshots - Token Balances
    // ═══════════════════════════════════════════════════════════════════

    struct TokenBalanceSnapshot {
        uint256 userMoca;
        uint256 userEsMoca;
        uint256 veMocaContractMoca;
        uint256 veMocaContractEsMoca;
        uint256 vcContractMoca;
        uint256 vcContractEsMoca;
        uint256 treasuryEsMoca;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Comprehensive Integration Snapshot
    // ═══════════════════════════════════════════════════════════════════

    struct IntegrationSnapshot {
        TokenBalanceSnapshot tokens;
        GlobalCountersSnapshot vcGlobal;
        EpochSnapshot vcEpoch;
        DelegateSnapshot vcDelegate;
        UserAccountSnapshot vcUserAccount;
        VeMocaGlobalSnapshot veMocaGlobal;
        LockSnapshot lock;
        uint128 userPersonalVP;
        uint128 userDelegatedVP;
        uint128 delegateTotalDelegatedVP;
        uint256 esMocaTotalSupply;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Capture Functions - VotingController
    // ═══════════════════════════════════════════════════════════════════

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

    function captureUserAccount(uint128 epoch, address user) internal view returns (UserAccountSnapshot memory snapshot) {
        (uint128 totalVotesSpent, uint128 totalRewards) = votingController.usersEpochData(epoch, user);
        snapshot.totalVotesSpent = totalVotesSpent;
        snapshot.totalRewards = totalRewards;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Capture Functions - VotingEscrowMoca
    // ═══════════════════════════════════════════════════════════════════

    function captureVeMocaGlobal() internal view returns (VeMocaGlobalSnapshot memory snapshot) {
        snapshot.totalLockedMoca = veMoca.TOTAL_LOCKED_MOCA();
        snapshot.totalLockedEsMoca = veMoca.TOTAL_LOCKED_ESMOCA();
        (snapshot.veGlobal.bias, snapshot.veGlobal.slope) = veMoca.veGlobal();
        snapshot.lastUpdatedTimestamp = veMoca.lastUpdatedTimestamp();
    }

    function captureLock(bytes32 lockId) internal view returns (LockSnapshot memory snapshot) {
        (
            address owner,
            uint128 expiry,
            uint128 moca,
            uint128 esMocaAmt,
            bool isUnlocked,
            address delegate,
            address currentHolder,
            uint128 delegationEpoch
        ) = veMoca.locks(lockId);

        snapshot.owner = owner;
        snapshot.expiry = expiry;
        snapshot.moca = moca;
        snapshot.esMoca = esMocaAmt;
        snapshot.isUnlocked = isUnlocked;
        snapshot.delegate = delegate;
        snapshot.currentHolder = currentHolder;
        snapshot.delegationEpoch = delegationEpoch;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Capture Functions - Token Balances
    // ═══════════════════════════════════════════════════════════════════

    function captureTokenBalances(address user) internal view returns (TokenBalanceSnapshot memory snapshot) {
        snapshot.userMoca = user.balance;
        snapshot.userEsMoca = esMoca.balanceOf(user);
        snapshot.veMocaContractMoca = address(veMoca).balance;
        snapshot.veMocaContractEsMoca = esMoca.balanceOf(address(veMoca));
        snapshot.vcContractMoca = address(votingController).balance;
        snapshot.vcContractEsMoca = esMoca.balanceOf(address(votingController));
        snapshot.treasuryEsMoca = esMoca.balanceOf(votingControllerTreasury);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Comprehensive Capture Function
    // ═══════════════════════════════════════════════════════════════════

    function captureIntegrationState(
        address user,
        address delegate,
        bytes32 lockId,
        uint128 epoch
    ) internal view returns (IntegrationSnapshot memory snapshot) {
        snapshot.tokens = captureTokenBalances(user);
        snapshot.vcGlobal = captureGlobalCounters();
        snapshot.vcEpoch = captureEpochState(epoch);
        snapshot.vcDelegate = captureDelegateState(delegate);
        snapshot.vcUserAccount = captureUserAccount(epoch, user);
        snapshot.veMocaGlobal = captureVeMocaGlobal();
        snapshot.lock = captureLock(lockId);
        snapshot.userPersonalVP = veMoca.balanceOfAt(user, uint128(block.timestamp), false);
        snapshot.userDelegatedVP = veMoca.balanceOfAt(user, uint128(block.timestamp), true);
        snapshot.delegateTotalDelegatedVP = veMoca.balanceOfAt(delegate, uint128(block.timestamp), true);
        snapshot.esMocaTotalSupply = esMoca.totalSupply();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - User Setup
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Fund a user with native MOCA and escrow it to get esMoca
     * @param user The user address
     * @param mocaAmount Amount of MOCA to escrow
     */
    function _fundUserWithEsMoca(address user, uint256 mocaAmount) internal {
        // Add to existing balance (not overwrite)
        vm.deal(user, user.balance + mocaAmount);
        vm.startPrank(user);
        esMoca.escrowMoca{value: mocaAmount}();
        vm.stopPrank();
    }

    /**
     * @notice Fund a user with native MOCA (without escrowing)
     * @param user The user address
     * @param mocaAmount Amount of MOCA
     */
    function _fundUserWithMoca(address user, uint256 mocaAmount) internal {
        // Add to existing balance (not overwrite)
        vm.deal(user, user.balance + mocaAmount);
    }

    /**
     * @notice Approve VotingEscrowMoca to spend user's esMoca
     * @param user The user address
     * @param amount Amount to approve
     */
    function _approveVeMoca(address user, uint256 amount) internal {
        vm.startPrank(user);
        esMoca.approve(address(veMoca), amount);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - Lock Creation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a lock for a user with MOCA and esMOCA
     * @param user The user address
     * @param moca MOCA amount (native token)
     * @param esMocaAmount esMOCA amount
     * @param expiry Lock expiry timestamp
     * @return lockId The created lock ID
     */
    function _createLock(
        address user,
        uint128 moca,
        uint128 esMocaAmount,
        uint128 expiry
    ) internal returns (bytes32 lockId) {
        // Approve esMoca spending
        if (esMocaAmount > 0) {
            vm.startPrank(user);
            esMoca.approve(address(veMoca), esMocaAmount);
            vm.stopPrank();
        }

        // Create lock
        vm.startPrank(user);
        lockId = veMoca.createLock{value: moca}(expiry, esMocaAmount);
        vm.stopPrank();
    }

    /**
     * @notice Create a lock with delegation to a registered delegate
     * @param user The user address
     * @param delegate The delegate address
     * @param moca MOCA amount
     * @param esMocaAmount esMOCA amount
     * @param expiry Lock expiry timestamp
     * @return lockId The created lock ID
     */
    function _createLockWithDelegation(
        address user,
        address delegate,
        uint128 moca,
        uint128 esMocaAmount,
        uint128 expiry
    ) internal returns (bytes32 lockId) {
        // First create the lock
        lockId = _createLock(user, moca, esMocaAmount, expiry);

        // Then delegate it
        vm.startPrank(user);
        veMoca.delegationAction(lockId, delegate, DataTypes.DelegationType.Delegate);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - Delegation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Delegate an existing lock to a delegate
     * @param user The lock owner
     * @param lockId The lock ID
     * @param delegate The delegate address
     */
    function _delegateLock(address user, bytes32 lockId, address delegate) internal {
        vm.startPrank(user);
        veMoca.delegationAction(lockId, delegate, DataTypes.DelegationType.Delegate);
        vm.stopPrank();
    }

    /**
     * @notice Undelegate a lock
     * @param user The lock owner
     * @param lockId The lock ID
     */
    function _undelegateLock(address user, bytes32 lockId) internal {
        vm.startPrank(user);
        veMoca.delegationAction(lockId, address(0), DataTypes.DelegationType.Undelegate);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - VotingController Operations
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

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - Epoch Management
    // ═══════════════════════════════════════════════════════════════════

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
     * @param poolIds Array of pool IDs with specific rewards/subsidies
     * @param rewards Array of reward amounts per pool
     * @param subsidies Array of subsidy amounts per pool
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
        uint128 totalActivePools = votingController.TOTAL_ACTIVE_POOLS();
        uint128[] memory allPoolIds = new uint128[](totalActivePools);
        uint128[] memory allRewards = new uint128[](totalActivePools);
        uint128[] memory allSubsidies = new uint128[](totalActivePools);
        
        // Initialize all pools with zero rewards/subsidies
        for (uint128 i = 0; i < totalActivePools; ++i) {
            allPoolIds[i] = i + 1;
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
        
        // Calculate total esMoca needed and mint to treasury
        uint128 totalRewards;
        uint128 totalSubsidies;
        for (uint256 i = 0; i < allRewards.length; ++i) {
            totalRewards += allRewards[i];
            totalSubsidies += allSubsidies[i];
        }
        
        // Mint esMoca to treasury using escrowMoca
        uint256 totalToMint = totalRewards + totalSubsidies;
        if (totalToMint > 0) {
            vm.deal(votingControllerTreasury, totalToMint);
            vm.prank(votingControllerTreasury);
            esMoca.escrowMoca{value: totalToMint}();
        }

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

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - Array Builders
    // ═══════════════════════════════════════════════════════════════════

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

    // ═══════════════════════════════════════════════════════════════════
    // Helper Functions - Lock ID Generation
    // ═══════════════════════════════════════════════════════════════════

    function generateLockId(uint256 salt, address user) public view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }
}

