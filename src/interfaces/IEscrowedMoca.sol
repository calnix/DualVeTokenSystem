// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {DataTypes} from "../libraries/DataTypes.sol";

/**
 * @title IEscrowedMoca
 * @author Calnix
 * @notice Interface for core EscrowedMoca actions and admin functions.
 */
interface IEscrowedMoca {
    // ----------- User Functions -----------

    /**
     * @notice Converts native Moca to esMoca by sending native Moca (msg.value).
     */
    function escrowMoca() external payable;

    /**
     * @notice Redeems esMoca for Moca using a specified redemption option. 
     * Transfers native Moca or wMoca if transfer fails (redemption irreversible).
     * @param redemptionOption Redemption option index.
     * @param expectedOption The expected redemption option struct (for front-running protection).
     * @param redemptionAmount Amount of esMoca to redeem.
     */
    function selectRedemptionOption(uint256 redemptionOption, DataTypes.RedemptionOption calldata expectedOption, uint256 redemptionAmount) external;

    /**
     * @notice Claims the redeemed MOCA tokens after the lock period has elapsed.
     * @param redemptionTimestamps The timestamps at which the redemptions become available for claim.
     */
    function claimRedemptions(uint256[] calldata redemptionTimestamps) external payable;

    // ----------- Admin Functions -----------

    /**
     * @notice Updates the percentage of penalty allocated to voters.
     * @param votersPenaltyPct The new penalty percentage for voters (2dp precision, e.g., 100 = 1%).
     */
    function setVotersPenaltyPct(uint256 votersPenaltyPct) external;

    /**
     * @notice Sets the gas limit for moca transfers.
     * @param newMocaTransferGasLimit The new gas limit.
     */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external;

    /**
     * @notice Updates/creates a redemption option.
     * @param redemptionOption The redemption option index.
     * @param lockDuration The lock duration for the option.
     * @param receivablePct The receivable percentage (2dp precision).
     */
    function setRedemptionOption(uint256 redemptionOption, uint128 lockDuration, uint128 receivablePct) external;

    /**
     * @notice Enables or disables a redemption option.
     * @param redemptionOption The redemption option index.
     * @param enable True to enable, false to disable.
     */
    function setRedemptionOptionStatus(uint256 redemptionOption, bool enable) external;

    /**
     * @notice Updates whitelist status for an address for esMoca transfer permissions.
     * @param addr The address to update.
     * @param isWhitelisted True to whitelist, false to remove.
     */
    function setWhitelistStatus(address addr, bool isWhitelisted) external;

    // ----------- CronJob/AssetManager Functions -----------

    /**
     * @notice Escrows native Moca on behalf of multiple users (batch mint).
     * @param users Array of user addresses.
     * @param amounts Array of amounts per user.
     */
    function escrowMocaOnBehalf(address[] calldata users, uint256[] calldata amounts) external payable;

    /**
     * @notice Claims accrued penalty amounts for voters and treasury.
     */
    function claimPenalties() external payable;

    /**
     * @notice Releases esMoca to Moca (admin emergency/manual release).
     * @param amount Amount to release.
     */
    function releaseEscrowedMoca(uint256 amount) external payable;

    // ----------- Emergency Exit Functions ------------

    /**
     * @notice Exfiltrate esMoca for a list of users during emergency exit.
     * @param users Addresses to exit for.
     */
    function emergencyExit(address[] calldata users) external payable;

    /**
     * @notice Exfiltrate all accrued penalties to the esMoca treasury during emergency.
     */
    function emergencyExitPenalties() external payable;
}
