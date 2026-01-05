// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {VotingController} from "../../../../src/VotingController.sol";
import {VotingEscrowMoca} from "../../../../src/VotingEscrowMoca.sol";
import {EscrowedMoca} from "../../../../src/EscrowedMoca.sol";
import {DataTypes} from "../../../../src/libraries/DataTypes.sol";
import {EpochMath} from "../../../../src/libraries/EpochMath.sol";
import {Constants} from "../../../../src/libraries/Constants.sol";

/**
 * @title VoterHandler
 * @notice Handler for vote and migrateVotes actions in invariant testing
 * @dev Tracks ghost variables for vote conservation invariants
 */
contract VoterHandler is Test {
    VotingController public vc;
    VotingEscrowMoca public veMoca;
    EscrowedMoca public esMoca;

    // ═══════════════════════════════════════════════════════════════════
    // Actor Management
    // ═══════════════════════════════════════════════════════════════════
    
    address[] public actors;
    address public currentActor;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Vote Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    // Personal votes: epoch => poolId => total votes
    mapping(uint128 => mapping(uint128 => uint128)) public ghost_poolPersonalVotes;
    
    // Delegated votes: epoch => poolId => total votes
    mapping(uint128 => mapping(uint128 => uint128)) public ghost_poolDelegatedVotes;
    
    // User votes spent: epoch => user => total spent
    mapping(uint128 => mapping(address => uint128)) public ghost_userVotesSpent;
    
    // Delegate votes spent: epoch => delegate => total spent
    mapping(uint128 => mapping(address => uint128)) public ghost_delegateVotesSpent;
    
    // Pool-level tracking: epoch => poolId => user => votes
    mapping(uint128 => mapping(uint128 => mapping(address => uint128))) public ghost_userPoolVotes;
    mapping(uint128 => mapping(uint128 => mapping(address => uint128))) public ghost_delegatePoolVotes;

    // Action counters
    uint256 public ghost_totalVoteActions;
    uint256 public ghost_totalMigrationActions;

    // ═══════════════════════════════════════════════════════════════════
    // Pool Tracking (from external source)
    // ═══════════════════════════════════════════════════════════════════
    
    uint128[] public knownPoolIds;

    // ═══════════════════════════════════════════════════════════════════
    // Modifier
    // ═══════════════════════════════════════════════════════════════════

    modifier useActor(uint256 actorSeed) {
        if (actors.length == 0) return;
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        VotingController _vc,
        VotingEscrowMoca _veMoca,
        EscrowedMoca _esMoca,
        address[] memory _actors
    ) {
        vc = _vc;
        veMoca = _veMoca;
        esMoca = _esMoca;
        
        for (uint256 i = 0; i < _actors.length; i++) {
            actors.push(_actors[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // External Setters
    // ═══════════════════════════════════════════════════════════════════

    function addKnownPool(uint128 poolId) external {
        knownPoolIds.push(poolId);
    }

    function setKnownPools(uint128[] calldata poolIds) external {
        delete knownPoolIds;
        for (uint256 i = 0; i < poolIds.length; i++) {
            knownPoolIds.push(poolIds[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Vote for pools using personal voting power
     */
    function votePersonal(
        uint256 actorSeed,
        uint256 poolIndexSeed,
        uint128 voteAmount
    ) external useActor(actorSeed) {
        if (knownPoolIds.length == 0) return;
        if (vc.paused()) return;

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Check epoch state allows voting
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(currentEpoch);
        if (state != DataTypes.EpochState.Voting) return;

        // Get available voting power
        uint128 availableVP = veMoca.balanceAtEpochEnd(currentActor, currentEpoch, false);
        (uint128 spentVotes,) = vc.usersEpochData(currentEpoch, currentActor);
        
        if (availableVP <= spentVotes) return;
        uint128 remainingVP = availableVP - spentVotes;
        
        // Bound vote amount
        voteAmount = uint128(bound(voteAmount, 1, remainingVP));
        if (voteAmount == 0) return;

        // Select pool
        uint128 poolId = knownPoolIds[bound(poolIndexSeed, 0, knownPoolIds.length - 1)];
        
        // Check pool is active
        (bool isActive,,,) = vc.pools(poolId);
        if (!isActive) return;

        // Execute vote
        uint128[] memory poolIds = new uint128[](1);
        poolIds[0] = poolId;
        uint128[] memory votes = new uint128[](1);
        votes[0] = voteAmount;

        try vc.vote(poolIds, votes, false) {
            // Update ghost variables
            ghost_poolPersonalVotes[currentEpoch][poolId] += voteAmount;
            ghost_userVotesSpent[currentEpoch][currentActor] += voteAmount;
            ghost_userPoolVotes[currentEpoch][poolId][currentActor] += voteAmount;
            ghost_totalVoteActions++;
        } catch {}
    }

    /**
     * @notice Vote for pools using delegated voting power (as delegate)
     */
    function voteDelegated(
        uint256 actorSeed,
        uint256 poolIndexSeed,
        uint128 voteAmount
    ) external useActor(actorSeed) {
        if (knownPoolIds.length == 0) return;
        if (vc.paused()) return;

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Check epoch state allows voting
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(currentEpoch);
        if (state != DataTypes.EpochState.Voting) return;

        // Must be registered delegate
        (bool isRegistered,,,,,) = vc.delegates(currentActor);
        if (!isRegistered) return;

        // Get available delegated voting power
        uint128 availableVP = veMoca.balanceAtEpochEnd(currentActor, currentEpoch, true);
        (uint128 spentVotes,) = vc.delegateEpochData(currentEpoch, currentActor);
        
        if (availableVP <= spentVotes) return;
        uint128 remainingVP = availableVP - spentVotes;
        
        // Bound vote amount
        voteAmount = uint128(bound(voteAmount, 1, remainingVP));
        if (voteAmount == 0) return;

        // Select pool
        uint128 poolId = knownPoolIds[bound(poolIndexSeed, 0, knownPoolIds.length - 1)];
        
        // Check pool is active
        (bool isActive,,,) = vc.pools(poolId);
        if (!isActive) return;

        // Execute vote
        uint128[] memory poolIds = new uint128[](1);
        poolIds[0] = poolId;
        uint128[] memory votes = new uint128[](1);
        votes[0] = voteAmount;

        try vc.vote(poolIds, votes, true) {
            // Update ghost variables
            ghost_poolDelegatedVotes[currentEpoch][poolId] += voteAmount;
            ghost_delegateVotesSpent[currentEpoch][currentActor] += voteAmount;
            ghost_delegatePoolVotes[currentEpoch][poolId][currentActor] += voteAmount;
            ghost_totalVoteActions++;
        } catch {}
    }

    /**
     * @notice Migrate votes between pools (personal)
     */
    function migrateVotesPersonal(
        uint256 actorSeed,
        uint256 srcPoolSeed,
        uint256 dstPoolSeed,
        uint128 migrateAmount
    ) external useActor(actorSeed) {
        if (knownPoolIds.length < 2) return;
        if (vc.paused()) return;

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Check epoch state
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(currentEpoch);
        if (state != DataTypes.EpochState.Voting) return;

        // Select source and destination pools
        uint256 srcIdx = bound(srcPoolSeed, 0, knownPoolIds.length - 1);
        uint256 dstIdx = bound(dstPoolSeed, 0, knownPoolIds.length - 1);
        if (srcIdx == dstIdx) dstIdx = (dstIdx + 1) % knownPoolIds.length;
        
        uint128 srcPoolId = knownPoolIds[srcIdx];
        uint128 dstPoolId = knownPoolIds[dstIdx];

        // Check destination pool is active
        (bool dstActive,,,) = vc.pools(dstPoolId);
        if (!dstActive) return;

        // Get user's votes in source pool
        (uint128 srcVotes,) = vc.usersEpochPoolData(currentEpoch, srcPoolId, currentActor);
        if (srcVotes == 0) return;

        // Bound migration amount
        migrateAmount = uint128(bound(migrateAmount, 1, srcVotes));

        // Execute migration
        uint128[] memory srcPoolIds = new uint128[](1);
        srcPoolIds[0] = srcPoolId;
        uint128[] memory dstPoolIds = new uint128[](1);
        dstPoolIds[0] = dstPoolId;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = migrateAmount;

        try vc.migrateVotes(srcPoolIds, dstPoolIds, amounts, false) {
            // Update ghost variables
            ghost_poolPersonalVotes[currentEpoch][srcPoolId] -= migrateAmount;
            ghost_poolPersonalVotes[currentEpoch][dstPoolId] += migrateAmount;
            ghost_userPoolVotes[currentEpoch][srcPoolId][currentActor] -= migrateAmount;
            ghost_userPoolVotes[currentEpoch][dstPoolId][currentActor] += migrateAmount;
            ghost_totalMigrationActions++;
        } catch {}
    }

    /**
     * @notice Migrate votes between pools (delegated)
     */
    function migrateVotesDelegated(
        uint256 actorSeed,
        uint256 srcPoolSeed,
        uint256 dstPoolSeed,
        uint128 migrateAmount
    ) external useActor(actorSeed) {
        if (knownPoolIds.length < 2) return;
        if (vc.paused()) return;

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Check epoch state
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(currentEpoch);
        if (state != DataTypes.EpochState.Voting) return;

        // Must be registered delegate
        (bool isRegistered,,,,,) = vc.delegates(currentActor);
        if (!isRegistered) return;

        // Select source and destination pools
        uint256 srcIdx = bound(srcPoolSeed, 0, knownPoolIds.length - 1);
        uint256 dstIdx = bound(dstPoolSeed, 0, knownPoolIds.length - 1);
        if (srcIdx == dstIdx) dstIdx = (dstIdx + 1) % knownPoolIds.length;
        
        uint128 srcPoolId = knownPoolIds[srcIdx];
        uint128 dstPoolId = knownPoolIds[dstIdx];

        // Check destination pool is active
        (bool dstActive,,,) = vc.pools(dstPoolId);
        if (!dstActive) return;

        // Get delegate's votes in source pool
        (uint128 srcVotes,) = vc.delegatesEpochPoolData(currentEpoch, srcPoolId, currentActor);
        if (srcVotes == 0) return;

        // Bound migration amount
        migrateAmount = uint128(bound(migrateAmount, 1, srcVotes));

        // Execute migration
        uint128[] memory srcPoolIds = new uint128[](1);
        srcPoolIds[0] = srcPoolId;
        uint128[] memory dstPoolIds = new uint128[](1);
        dstPoolIds[0] = dstPoolId;
        uint128[] memory amounts = new uint128[](1);
        amounts[0] = migrateAmount;

        try vc.migrateVotes(srcPoolIds, dstPoolIds, amounts, true) {
            // Update ghost variables
            ghost_poolDelegatedVotes[currentEpoch][srcPoolId] -= migrateAmount;
            ghost_poolDelegatedVotes[currentEpoch][dstPoolId] += migrateAmount;
            ghost_delegatePoolVotes[currentEpoch][srcPoolId][currentActor] -= migrateAmount;
            ghost_delegatePoolVotes[currentEpoch][dstPoolId][currentActor] += migrateAmount;
            ghost_totalMigrationActions++;
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function getKnownPoolIds() external view returns (uint128[] memory) {
        return knownPoolIds;
    }

    function getGhostPoolTotalVotes(uint128 epoch, uint128 poolId) external view returns (uint128) {
        return ghost_poolPersonalVotes[epoch][poolId] + ghost_poolDelegatedVotes[epoch][poolId];
    }
}

