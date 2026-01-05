// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

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
 * @title InvariantHarness
 * @notice Base harness for VotingController invariant testing with real contracts
 * @dev Extends the integration test approach with actor management and ghost variable support
 */
abstract contract InvariantHarness is Test {
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
    uint128 public constant MIN_LOCK_AMOUNT = 1e18;

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Privileged Roles
    // ═══════════════════════════════════════════════════════════════════
    
    address public globalAdmin;
    address public votingControllerAdmin;
    address public votingEscrowMocaAdmin;
    address public escrowedMocaAdmin;
    address public monitorAdmin;
    address public cronJobAdmin;
    address public monitor;
    address public cronJob;
    address public emergencyExitHandler;
    address public assetManager;

    // ═══════════════════════════════════════════════════════════════════
    // Actors: Treasuries
    // ═══════════════════════════════════════════════════════════════════
    
    address public votingControllerTreasury;
    address public esMocaTreasury;

    // ═══════════════════════════════════════════════════════════════════
    // Actor Pools for Invariant Testing
    // ═══════════════════════════════════════════════════════════════════
    
    address[] public voters;      // Personal voters
    address[] public delegates;   // Registered delegates
    address[] public delegators;  // Users who delegate to delegates
    address[] public verifiers;   // Subsidy claimers
    address[] public verifierAssets; // Verifier asset managers
    address[] public allActors;   // Combined list

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

    // ═══════════════════════════════════════════════════════════════════
    // Tracking: Created Locks
    // ═══════════════════════════════════════════════════════════════════
    
    bytes32[] public activeLockIds;
    mapping(bytes32 => address) public lockOwners;
    mapping(address => bytes32[]) public userLocks;

    // ═══════════════════════════════════════════════════════════════════
    // Tracking: Active Pools
    // ═══════════════════════════════════════════════════════════════════
    
    uint128[] public activePoolIds;

    // ═══════════════════════════════════════════════════════════════════
    // Tracking: Finalized Epochs
    // ═══════════════════════════════════════════════════════════════════
    
    uint128[] public finalizedEpochs;
    mapping(uint128 => bool) public epochFinalized;

    // Dummy variable to prevent compiler optimization issues
    uint256 private dummy;

    // ═══════════════════════════════════════════════════════════════════
    // Setup
    // ═══════════════════════════════════════════════════════════════════

    function setUp() public virtual {
        // Create admin addresses first
        globalAdmin = makeAddr("globalAdmin");
        votingControllerAdmin = makeAddr("votingControllerAdmin");
        votingEscrowMocaAdmin = makeAddr("votingEscrowMocaAdmin");
        escrowedMocaAdmin = makeAddr("escrowedMocaAdmin");
        monitorAdmin = makeAddr("monitorAdmin");
        cronJobAdmin = makeAddr("cronJobAdmin");
        monitor = makeAddr("monitor");
        cronJob = makeAddr("cronJob");
        emergencyExitHandler = makeAddr("emergencyExitHandler");
        assetManager = makeAddr("assetManager");
        votingControllerTreasury = makeAddr("votingControllerTreasury");
        esMocaTreasury = makeAddr("esMocaTreasury");

        // Warp to a valid epoch (epoch 10) to avoid underflow
        vm.warp(10 * EPOCH_DURATION + 1);

        // 1. Deploy mock wMoca
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

        // 4. Deploy mock PaymentsController
        mockPaymentsController = new MockPaymentsControllerVC();

        // 5. Deploy VotingController
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

        // 6. Whitelist VotingEscrowMoca in EscrowedMoca
        vm.startPrank(escrowedMocaAdmin);
        address[] memory veMocaWhitelist = new address[](1);
        veMocaWhitelist[0] = address(veMoca);
        esMoca.setWhitelistStatus(veMocaWhitelist, true);
        vm.stopPrank();

        // 7. Whitelist VotingController in EscrowedMoca
        vm.startPrank(escrowedMocaAdmin);
        address[] memory vcWhitelist = new address[](1);
        vcWhitelist[0] = address(votingController);
        esMoca.setWhitelistStatus(vcWhitelist, true);
        vm.stopPrank();

        // 8. Set VotingController address in VotingEscrowMoca
        vm.startPrank(votingEscrowMocaAdmin);
        veMoca.setVotingController(address(votingController));
        vm.stopPrank();

        // 9. Grant CRON_JOB_ROLE
        vm.startPrank(cronJobAdmin);
        votingController.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        veMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        esMoca.grantRole(Constants.CRON_JOB_ROLE, cronJob);
        vm.stopPrank();

        // 10. Whitelist and setup treasury
        vm.startPrank(escrowedMocaAdmin);
        address[] memory treasuryWhitelist = new address[](1);
        treasuryWhitelist[0] = votingControllerTreasury;
        esMoca.setWhitelistStatus(treasuryWhitelist, true);
        vm.stopPrank();

        vm.startPrank(votingControllerTreasury);
        esMoca.approve(address(votingController), type(uint256).max);
        vm.stopPrank();

        // ═══════════════════════════════════════════════════════════════════
        // Initialize Actor Pools
        // ═══════════════════════════════════════════════════════════════════
        _initializeActors();
    }

    function _initializeActors() internal {
        // Create voters (5)
        for (uint256 i = 0; i < 5; i++) {
            address voter = makeAddr(string(abi.encodePacked("voter", i)));
            voters.push(voter);
            allActors.push(voter);
            _fundAndSetupActor(voter);
        }

        // Create delegates (3)
        for (uint256 i = 0; i < 3; i++) {
            address delegate = makeAddr(string(abi.encodePacked("delegate", i)));
            delegates.push(delegate);
            allActors.push(delegate);
            _fundAndSetupActor(delegate);
        }

        // Create delegators (3)
        for (uint256 i = 0; i < 3; i++) {
            address delegator = makeAddr(string(abi.encodePacked("delegator", i)));
            delegators.push(delegator);
            allActors.push(delegator);
            _fundAndSetupActor(delegator);
        }

        // Create verifiers (2) with asset managers
        for (uint256 i = 0; i < 2; i++) {
            address verifier = makeAddr(string(abi.encodePacked("verifier", i)));
            address verifierAsset = makeAddr(string(abi.encodePacked("verifierAsset", i)));
            verifiers.push(verifier);
            verifierAssets.push(verifierAsset);
            allActors.push(verifier);
            allActors.push(verifierAsset);
            
            // Setup verifier in mock payments controller
            mockPaymentsController.setVerifierAssetManager(verifier, verifierAsset);
        }
    }

    function _fundAndSetupActor(address actor) internal {
        // Fund with native MOCA
        vm.deal(actor, 100_000_000 ether);
        
        // Get esMoca by escrowing
        vm.startPrank(actor);
        esMoca.escrowMoca{value: 10_000_000 ether}();
        esMoca.approve(address(veMoca), type(uint256).max);
        vm.stopPrank();

        // Whitelist actor in esMoca for transfers
        vm.startPrank(escrowedMocaAdmin);
        address[] memory whitelist = new address[](1);
        whitelist[0] = actor;
        esMoca.setWhitelistStatus(whitelist, true);
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

    function getCurrentEpochStart() public returns (uint128) {
        dummy = 1;
        return (uint128(block.timestamp) / EPOCH_DURATION) * EPOCH_DURATION;
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
    // Lock Creation Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _createLockForActor(
        address actor,
        uint128 mocaAmount,
        uint128 esMocaAmount,
        uint128 expiry
    ) internal returns (bytes32 lockId) {
        vm.startPrank(actor);
        lockId = veMoca.createLock{value: mocaAmount}(expiry, esMocaAmount);
        vm.stopPrank();

        activeLockIds.push(lockId);
        lockOwners[lockId] = actor;
        userLocks[actor].push(lockId);
    }

    // ═══════════════════════════════════════════════════════════════════
    // Pool Helpers
    // ═══════════════════════════════════════════════════════════════════

    function _createPoolsAdmin(uint128 count) internal {
        vm.prank(votingControllerAdmin);
        votingController.createPools(count);

        uint128 startId = votingController.TOTAL_POOLS_CREATED() - count + 1;
        for (uint128 i = 0; i < count; i++) {
            activePoolIds.push(startId + i);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Accessor Functions
    // ═══════════════════════════════════════════════════════════════════

    function getVoters() external view returns (address[] memory) {
        return voters;
    }

    function getDelegates() external view returns (address[] memory) {
        return delegates;
    }

    function getDelegators() external view returns (address[] memory) {
        return delegators;
    }

    function getVerifiers() external view returns (address[] memory) {
        return verifiers;
    }

    function getVerifierAssets() external view returns (address[] memory) {
        return verifierAssets;
    }

    function getAllActors() external view returns (address[] memory) {
        return allActors;
    }

    function getActiveLockIds() external view returns (bytes32[] memory) {
        return activeLockIds;
    }

    function getActivePoolIds() external view returns (uint128[] memory) {
        return activePoolIds;
    }

    function getFinalizedEpochs() external view returns (uint128[] memory) {
        return finalizedEpochs;
    }

    function getUserLocks(address user) external view returns (bytes32[] memory) {
        return userLocks[user];
    }

    // ═══════════════════════════════════════════════════════════════════
    // Array Helpers
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

    function _toAddressArray(address value) internal pure returns (address[] memory) {
        address[] memory arr = new address[](1);
        arr[0] = value;
        return arr;
    }

    function _toNestedArray(uint128[] memory inner) internal pure returns (uint128[][] memory) {
        uint128[][] memory arr = new uint128[][](1);
        arr[0] = inner;
        return arr;
    }
}

