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
 * @title ClaimsHandler
 * @notice Handler for all claim actions: personal rewards, delegated rewards, fees, subsidies
 * @dev Tracks ghost variables for reward/subsidy conservation invariants
 */
contract ClaimsHandler is Test {
    VotingController public vc;
    VotingEscrowMoca public veMoca;
    EscrowedMoca public esMoca;

    // ═══════════════════════════════════════════════════════════════════
    // Actor Management
    // ═══════════════════════════════════════════════════════════════════
    
    address[] public voters;
    address[] public delegates;
    address[] public delegators;
    address[] public verifiers;
    address[] public verifierAssets;

    // ═══════════════════════════════════════════════════════════════════
    // Tracking Data
    // ═══════════════════════════════════════════════════════════════════
    
    uint128[] public finalizedEpochs;
    uint128[] public knownPoolIds;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Reward Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    // Personal rewards claimed: epoch => user => amount
    mapping(uint128 => mapping(address => uint128)) public ghost_personalRewardsClaimed;
    
    // Delegated rewards claimed: epoch => delegator => delegate => amount
    mapping(uint128 => mapping(address => mapping(address => uint128))) public ghost_delegatedRewardsClaimed;
    
    // Delegate fees claimed: epoch => delegate => delegator => amount
    mapping(uint128 => mapping(address => mapping(address => uint128))) public ghost_delegateFeesClaimed;
    
    // Subsidy claims: epoch => verifier => amount
    mapping(uint128 => mapping(address => uint128)) public ghost_subsidiesClaimed;

    // Totals
    uint128 public ghost_totalPersonalRewardsClaimed;
    uint128 public ghost_totalDelegatedRewardsClaimed;
    uint128 public ghost_totalDelegateFeesClaimed;
    uint128 public ghost_totalSubsidiesClaimed;

    // Per-pool tracking
    mapping(uint128 => mapping(uint128 => uint128)) public ghost_poolRewardsClaimed; // epoch => poolId => amount
    mapping(uint128 => mapping(uint128 => uint128)) public ghost_poolSubsidiesClaimed; // epoch => poolId => amount

    // Action counters
    uint256 public ghost_totalClaimAttempts;
    uint256 public ghost_successfulClaims;

    // ═══════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        VotingController _vc,
        VotingEscrowMoca _veMoca,
        EscrowedMoca _esMoca,
        address[] memory _voters,
        address[] memory _delegates,
        address[] memory _delegators,
        address[] memory _verifiers,
        address[] memory _verifierAssets
    ) {
        vc = _vc;
        veMoca = _veMoca;
        esMoca = _esMoca;
        
        for (uint256 i = 0; i < _voters.length; i++) voters.push(_voters[i]);
        for (uint256 i = 0; i < _delegates.length; i++) delegates.push(_delegates[i]);
        for (uint256 i = 0; i < _delegators.length; i++) delegators.push(_delegators[i]);
        for (uint256 i = 0; i < _verifiers.length; i++) verifiers.push(_verifiers[i]);
        for (uint256 i = 0; i < _verifierAssets.length; i++) verifierAssets.push(_verifierAssets[i]);
    }

    // ═══════════════════════════════════════════════════════════════════
    // External Setters
    // ═══════════════════════════════════════════════════════════════════

    function addFinalizedEpoch(uint128 epoch) external {
        finalizedEpochs.push(epoch);
    }

    function setKnownPools(uint128[] calldata poolIds) external {
        delete knownPoolIds;
        for (uint256 i = 0; i < poolIds.length; i++) {
            knownPoolIds.push(poolIds[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Personal Rewards
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Claim personal rewards for a user
     */
    function claimPersonalRewards(
        uint256 voterSeed,
        uint256 epochSeed,
        uint256 poolSeed
    ) external {
        if (voters.length == 0 || finalizedEpochs.length == 0 || knownPoolIds.length == 0) return;
        if (vc.paused()) return;

        address voter = voters[bound(voterSeed, 0, voters.length - 1)];
        uint128 epoch = finalizedEpochs[bound(epochSeed, 0, finalizedEpochs.length - 1)];
        uint128 poolId = knownPoolIds[bound(poolSeed, 0, knownPoolIds.length - 1)];

        ghost_totalClaimAttempts++;

        // Check epoch state
        (DataTypes.EpochState state,,,,,,,uint128 totalRewardsWithdrawn,) = vc.epochs(epoch);
        if (state != DataTypes.EpochState.Finalized) return;
        if (totalRewardsWithdrawn > 0) return;

        // Check user has votes in pool
        (uint128 userVotes,) = vc.usersEpochPoolData(epoch, poolId, voter);
        if (userVotes == 0) return;

        // Check not already claimed
        (, uint128 alreadyClaimed) = vc.usersEpochPoolData(epoch, poolId, voter);
        if (alreadyClaimed > 0) return;

        uint128[] memory poolIds = new uint128[](1);
        poolIds[0] = poolId;

        uint256 balanceBefore = esMoca.balanceOf(voter);

        vm.startPrank(voter);
        try vc.claimPersonalRewards(epoch, poolIds) {
            uint256 balanceAfter = esMoca.balanceOf(voter);
            uint128 claimed = uint128(balanceAfter - balanceBefore);
            
            ghost_personalRewardsClaimed[epoch][voter] += claimed;
            ghost_totalPersonalRewardsClaimed += claimed;
            ghost_poolRewardsClaimed[epoch][poolId] += claimed;
            ghost_successfulClaims++;
        } catch {}
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Delegated Rewards
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Claim delegated rewards for a delegator
     */
    function claimDelegatedRewards(
        uint256 delegatorSeed,
        uint256 delegateSeed,
        uint256 epochSeed,
        uint256 poolSeed
    ) external {
        if (delegators.length == 0 || delegates.length == 0) return;
        if (finalizedEpochs.length == 0 || knownPoolIds.length == 0) return;
        if (vc.paused()) return;

        address delegator = delegators[bound(delegatorSeed, 0, delegators.length - 1)];
        address delegate = delegates[bound(delegateSeed, 0, delegates.length - 1)];
        uint128 epoch = finalizedEpochs[bound(epochSeed, 0, finalizedEpochs.length - 1)];
        uint128 poolId = knownPoolIds[bound(poolSeed, 0, knownPoolIds.length - 1)];

        ghost_totalClaimAttempts++;

        // Check epoch state
        (DataTypes.EpochState state,,,,,,,uint128 totalRewardsWithdrawn,) = vc.epochs(epoch);
        if (state != DataTypes.EpochState.Finalized) return;
        if (totalRewardsWithdrawn > 0) return;

        // Check delegate voted in this epoch
        (uint128 delegateVotes,) = vc.delegateEpochData(epoch, delegate);
        if (delegateVotes == 0) return;

        // Check delegator had VP with this delegate
        uint128 delegatedVP = veMoca.getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);
        if (delegatedVP == 0) return;

        address[] memory delegateList = new address[](1);
        delegateList[0] = delegate;
        uint128[][] memory poolIds = new uint128[][](1);
        poolIds[0] = new uint128[](1);
        poolIds[0][0] = poolId;

        uint256 balanceBefore = esMoca.balanceOf(delegator);

        vm.startPrank(delegator);
        try vc.claimDelegatedRewards(epoch, delegateList, poolIds) {
            uint256 balanceAfter = esMoca.balanceOf(delegator);
            uint128 claimed = uint128(balanceAfter - balanceBefore);
            
            ghost_delegatedRewardsClaimed[epoch][delegator][delegate] += claimed;
            ghost_totalDelegatedRewardsClaimed += claimed;
            ghost_poolRewardsClaimed[epoch][poolId] += claimed;
            ghost_successfulClaims++;
        } catch {}
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Delegate Fees
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Claim delegation fees for a delegate
     */
    function claimDelegationFees(
        uint256 delegateSeed,
        uint256 delegatorSeed,
        uint256 epochSeed,
        uint256 poolSeed
    ) external {
        if (delegates.length == 0 || delegators.length == 0) return;
        if (finalizedEpochs.length == 0 || knownPoolIds.length == 0) return;
        if (vc.paused()) return;

        address delegate = delegates[bound(delegateSeed, 0, delegates.length - 1)];
        address delegator = delegators[bound(delegatorSeed, 0, delegators.length - 1)];
        uint128 epoch = finalizedEpochs[bound(epochSeed, 0, finalizedEpochs.length - 1)];
        uint128 poolId = knownPoolIds[bound(poolSeed, 0, knownPoolIds.length - 1)];

        ghost_totalClaimAttempts++;

        // Check epoch state
        (DataTypes.EpochState state,,,,,,,uint128 totalRewardsWithdrawn,) = vc.epochs(epoch);
        if (state != DataTypes.EpochState.Finalized) return;
        if (totalRewardsWithdrawn > 0) return;

        // Check delegate voted in this epoch
        (uint128 delegateVotes,) = vc.delegateEpochData(epoch, delegate);
        if (delegateVotes == 0) return;

        address[] memory delegatorList = new address[](1);
        delegatorList[0] = delegator;
        uint128[][] memory poolIds = new uint128[][](1);
        poolIds[0] = new uint128[](1);
        poolIds[0][0] = poolId;

        uint256 balanceBefore = esMoca.balanceOf(delegate);

        vm.startPrank(delegate);
        try vc.claimDelegationFees(epoch, delegatorList, poolIds) {
            uint256 balanceAfter = esMoca.balanceOf(delegate);
            uint128 claimed = uint128(balanceAfter - balanceBefore);
            
            ghost_delegateFeesClaimed[epoch][delegate][delegator] += claimed;
            ghost_totalDelegateFeesClaimed += claimed;
            ghost_poolRewardsClaimed[epoch][poolId] += claimed;
            ghost_successfulClaims++;
        } catch {}
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Subsidies
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Claim subsidies for a verifier
     */
    function claimSubsidies(
        uint256 verifierSeed,
        uint256 epochSeed,
        uint256 poolSeed
    ) external {
        if (verifiers.length == 0 || finalizedEpochs.length == 0 || knownPoolIds.length == 0) return;
        if (vc.paused()) return;

        uint256 idx = bound(verifierSeed, 0, verifiers.length - 1);
        address verifier = verifiers[idx];
        address verifierAsset = verifierAssets[idx];
        uint128 epoch = finalizedEpochs[bound(epochSeed, 0, finalizedEpochs.length - 1)];
        uint128 poolId = knownPoolIds[bound(poolSeed, 0, knownPoolIds.length - 1)];

        ghost_totalClaimAttempts++;

        // Check epoch state
        (DataTypes.EpochState state,,,,,,,,uint128 totalSubsidiesWithdrawn) = vc.epochs(epoch);
        if (state != DataTypes.EpochState.Finalized) return;
        if (totalSubsidiesWithdrawn > 0) return;

        // Check not blocked
        (bool isBlocked,) = vc.verifierEpochData(epoch, verifier);
        if (isBlocked) return;

        // Check pool has subsidies
        (,, uint128 poolSubsidies,,,) = vc.epochPools(epoch, poolId);
        if (poolSubsidies == 0) return;

        // Check not already claimed
        uint128 alreadyClaimed = vc.verifierEpochPoolSubsidies(epoch, poolId, verifier);
        if (alreadyClaimed > 0) return;

        uint128[] memory poolIds = new uint128[](1);
        poolIds[0] = poolId;

        uint256 balanceBefore = esMoca.balanceOf(verifierAsset);

        vm.startPrank(verifierAsset);
        try vc.claimSubsidies(epoch, verifier, poolIds) {
            uint256 balanceAfter = esMoca.balanceOf(verifierAsset);
            uint128 claimed = uint128(balanceAfter - balanceBefore);
            
            ghost_subsidiesClaimed[epoch][verifier] += claimed;
            ghost_totalSubsidiesClaimed += claimed;
            ghost_poolSubsidiesClaimed[epoch][poolId] += claimed;
            ghost_successfulClaims++;
        } catch {}
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    function getFinalizedEpochs() external view returns (uint128[] memory) {
        return finalizedEpochs;
    }

    function getTotalRewardsClaimed() external view returns (uint128) {
        return ghost_totalPersonalRewardsClaimed + ghost_totalDelegatedRewardsClaimed + ghost_totalDelegateFeesClaimed;
    }
}

