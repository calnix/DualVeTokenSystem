// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/// @title IIssuerStakingController
/// @notice Interface for the IssuerStakingController contract managing issuer MOCA staking.
interface IIssuerStakingController {

    // --- Staking Functions ---

    /// @notice Stake native MOCA (sent via msg.value).
    function stakeMoca() external payable;

    /// @notice Initiate unstaking of staked MOCA.
    /// @param amount The amount of MOCA to unstake.
    function initiateUnstake(uint256 amount) external;

    /// @notice Claim unstaked MOCA after delay period.
    /// @param timestamps Array of unstake initiation timestamps to claim.
    function claimUnstake(uint256[] calldata timestamps) external;

    // --- Admin Functions ---

    /// @notice Set the unstake delay period.
    /// @param newUnstakeDelay The new delay period in seconds.
    function setUnstakeDelay(uint256 newUnstakeDelay) external;

    /// @notice Set the maximum single stake amount.
    /// @param newMaxStakeAmount The new maximum stake amount.
    function setMaxSingleStakeAmount(uint256 newMaxStakeAmount) external;

    /// @notice Set the gas limit for MOCA transfers.
    /// @param newMocaTransferGasLimit The new gas limit.
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external;

    // --- Risk Management ---

    /// @notice Pause the contract.
    function pause() external;

    /// @notice Unpause the contract.
    function unpause() external;

    /// @notice Freeze the contract permanently.
    function freeze() external;

    /// @notice Emergency exit - return staked MOCA to specified issuers.
    /// @param issuerAddresses Array of issuer addresses to return MOCA to.
    function emergencyExit(address[] calldata issuerAddresses) external;

    // --- View Functions ---

    /// @notice Returns the wrapped MOCA address.
    function WMOCA() external view returns (address);

    /// @notice Returns the total MOCA staked.
    function TOTAL_MOCA_STAKED() external view returns (uint256);

    /// @notice Returns the total MOCA pending unstake.
    function TOTAL_MOCA_PENDING_UNSTAKE() external view returns (uint256);

    /// @notice Returns the unstake delay period.
    function UNSTAKE_DELAY() external view returns (uint256);

    /// @notice Returns the maximum single stake amount.
    function MAX_SINGLE_STAKE_AMOUNT() external view returns (uint256);

    /// @notice Returns the MOCA transfer gas limit.
    function MOCA_TRANSFER_GAS_LIMIT() external view returns (uint256);

    /// @notice Returns the frozen state (1 = frozen, 0 = not frozen).
    function isFrozen() external view returns (uint256);

    /// @notice Returns the staked MOCA for an issuer.
    /// @param issuer The issuer address.
    function issuers(address issuer) external view returns (uint256);

    /// @notice Returns pending unstaked MOCA for an issuer at a timestamp.
    /// @param issuer The issuer address.
    /// @param timestamp The unstake initiation timestamp.
    function pendingUnstakedMoca(address issuer, uint256 timestamp) external view returns (uint256);

    /// @notice Returns total pending unstaked MOCA for an issuer.
    /// @param issuer The issuer address.
    function totalPendingUnstakedMoca(address issuer) external view returns (uint256);
}
