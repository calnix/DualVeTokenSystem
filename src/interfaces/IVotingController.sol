// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/// @title IVotingController
/// @notice Interface for the VotingController contract, covering voting, delegation, reward, and subsidy claim operations.
interface IVotingController {

    // --- Voting & Migration ---

    /// @notice Cast votes for one or more pools using either personal or delegated voting power.
    /// @param poolIds Array of pool IDs to vote for.
    /// @param poolVotes Array of votes corresponding to each pool.
    /// @param isDelegated If true, caller's delegated voting power is used.
    function vote(uint128[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external;

    /// @notice Migrate votes from source pools to destination pools.
    /// @param srcPoolIds Array of source pool IDs.
    /// @param dstPoolIds Array of destination pool IDs.
    /// @param votesToMigrate Array of vote amounts to migrate.
    /// @param isDelegated If true, caller's delegated voting power is used.
    function migrateVotes(uint128[] calldata srcPoolIds, uint128[] calldata dstPoolIds, uint128[] calldata votesToMigrate, bool isDelegated) external;

    // --- Delegation ---

    /// @notice Register as a delegate with a fee percentage.
    /// @param feePct The fee percentage to charge delegators (100 = 1%).
    function registerAsDelegate(uint128 feePct) external payable;

    /// @notice Update the delegate fee percentage.
    /// @param feePct The new fee percentage.
    function updateDelegateFee(uint128 feePct) external;

    /// @notice Unregister as a delegate.
    function unregisterAsDelegate() external;

    // --- Claims ---

    /// @notice Claim personal rewards for a specific epoch and pools.
    /// @param epoch The epoch to claim rewards for.
    /// @param poolIds Array of pool IDs to claim rewards from.
    function claimPersonalRewards(uint128 epoch, uint128[] calldata poolIds) external;

    /// @notice Claim rewards delegated to various delegates.
    /// @param epoch The epoch to claim rewards for.
    /// @param delegateList Array of delegate addresses.
    /// @param poolIds 2D array of pool IDs per delegate.
    function claimDelegatedRewards(uint128 epoch, address[] calldata delegateList, uint128[][] calldata poolIds) external;

    /// @notice Claim delegation fees as a delegate.
    /// @param epoch The epoch to claim fees for.
    /// @param delegators Array of delegator addresses.
    /// @param poolIds 2D array of pool IDs per delegator.
    function claimDelegationFees(uint128 epoch, address[] calldata delegators, uint128[][] calldata poolIds) external;

    /// @notice Claim subsidies for a verifier.
    /// @param epoch The epoch to claim subsidies for.
    /// @param verifier The verifier address.
    /// @param poolIds Array of pool IDs to claim subsidies from.
    function claimSubsidies(uint128 epoch, address verifier, uint128[] calldata poolIds) external;

    // --- Epoch Management (CronJob) ---

    /// @notice End the current epoch and transition to Ended state.
    function endEpoch() external;

    /// @notice Process verifier checks for the epoch.
    /// @param allCleared True if all verifiers passed checks.
    /// @param verifiers Array of verifier addresses to block (if allCleared is false).
    function processVerifierChecks(bool allCleared, address[] calldata verifiers) external;

    /// @notice Process rewards and subsidies allocation for pools.
    /// @param poolIds Array of pool IDs to process.
    /// @param rewards Array of reward amounts per pool.
    /// @param subsidies Array of subsidy amounts per pool.
    function processRewardsAndSubsidies(uint128[] calldata poolIds, uint128[] calldata rewards, uint128[] calldata subsidies) external;

    /// @notice Finalize the epoch and enable claims.
    function finalizeEpoch() external;

    /// @notice Force finalize an epoch in emergency (blocks claims).
    function forceFinalizeEpoch() external;

    // --- Asset Manager ---

    /// @notice Withdraw unclaimed rewards after delay period.
    /// @param epoch The epoch to withdraw unclaimed rewards from.
    function withdrawUnclaimedRewards(uint128 epoch) external;

    /// @notice Withdraw unclaimed subsidies after delay period.
    /// @param epoch The epoch to withdraw unclaimed subsidies from.
    function withdrawUnclaimedSubsidies(uint128 epoch) external;

    /// @notice Withdraw collected registration fees.
    function withdrawRegistrationFees() external;

    // --- Pool Management (Admin) ---

    /// @notice Create new pools.
    /// @param count Number of pools to create.
    function createPools(uint128 count) external;

    /// @notice Remove pools.
    /// @param poolIds Array of pool IDs to remove.
    function removePools(uint128[] calldata poolIds) external;

    // --- Risk Management ---

    /// @notice Pause the contract.
    function pause() external;

    /// @notice Unpause the contract.
    function unpause() external;

    /// @notice Freeze the contract permanently.
    function freeze() external;

    /// @notice Emergency exit - transfer all assets to treasury.
    function emergencyExit() external;

    // --- View Functions ---

    /// @notice Get claimable delegation rewards for a user from a delegate.
    /// @param epoch The epoch to query.
    /// @param user The user address.
    /// @param delegate The delegate address.
    /// @param poolIds Array of pool IDs.
    /// @return grossRewardsPerPool Array of gross rewards per pool.
    /// @return totalGrossRewards Total gross rewards.
    function viewClaimableDelegationRewards(
        uint128 epoch,
        address user,
        address delegate,
        uint128[] calldata poolIds
    ) external view returns (uint128[] memory grossRewardsPerPool, uint128 totalGrossRewards);
}
