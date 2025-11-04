// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/// @title IVotingController
/// @notice Interface for the VotingController contract, covering voting, delegation, reward, and subsidy claim operations.
interface IVotingController {
    // --- Voting & Migration ---
    function vote(bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external;
    function migrateVotes(bytes32[] calldata srcPoolIds, bytes32[] calldata dstPoolIds, uint128[] calldata poolVotes, bool isDelegated) external;

    // --- Delegation ---
    function registerAsDelegate(uint128 feePct) external;
    function updateDelegateFee(uint128 feePct) external;

    // --- Claims ---
    function claimRewards(uint256 epoch, bytes32[] calldata poolIds) external;
    function claimRewardsFromDelegate(uint256 epoch, address[] calldata delegateList, bytes32[][] calldata poolIdsPerDelegate) external;
    function claimDelegateFees() external;
    function claimSubsidies(uint256 epoch, bytes32 verifierId, bytes32[] calldata poolIds) external;

    // --- Subsidies & Fees (admin/cron) ---
    function depositEpochSubsidies(uint256 epoch, uint128 subsidies) external;
    function finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint128[] calldata rewards) external;
    function withdrawUnclaimedSubsidies(uint256 epoch) external;
    function withdrawRegistrationFees() external payable;

    // --- Pool Management ---
    function createPool(bytes32 poolId) external returns (bytes32);
    function removePool(bytes32 poolId) external;

    // --- View/Getter Functions ---
    function getUserGrossRewardsByDelegate(uint128 epoch, address user, address delegate, bytes32[] calldata poolIds) external view returns (uint256[] memory grossRewardsPerPool, uint256 totalGrossRewards);

}
