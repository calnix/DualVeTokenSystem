// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {DataTypes} from "../libraries/DataTypes.sol";

/**
 * @title IPaymentsController
 * @author Calnix [@cal_nix]
 * @notice Interface for PaymentsController.sol - exposes core external and view functions.
 */
interface IPaymentsController {

    // ----- View Functions -----
    function getVerifierAndPoolAccruedSubsidies(
        uint128 epoch,
        uint128 poolId,
        address verifier,
        address caller
    ) external view returns (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies);

    function getIssuer(address issuer) external view returns (DataTypes.Issuer memory);
    function getSchema(bytes32 schemaId) external view returns (DataTypes.Schema memory);
    function getVerifier(address verifier) external view returns (DataTypes.Verifier memory);
    function getVerifierNonce(address signerAddress, address userAddress) external view returns (uint256);
    function getEligibleSubsidyPercentage(uint256 mocaStaked) external view returns (uint256);
    function getAllSubsidyTiers() external view returns (DataTypes.SubsidyTier[10] memory);
    function getEpochPoolSubsidies(uint128 epoch, uint128 poolId) external view returns (uint256);
    function getEpochPoolVerifierSubsidies(uint128 epoch, uint128 poolId, address verifier) external view returns (uint256);
    function getEpochPoolFeesAccrued(uint128 epoch, uint128 poolId) external view returns (DataTypes.FeesAccrued memory);
    function getEpochFeesAccrued(uint128 epoch) external view returns (DataTypes.FeesAccrued memory);
    function getIssuerSchemaNonce(address issuer) external view returns (uint256);

    // ----- AssetManager: deposit/withdraw for verifiers -----
    function deposit(address verifier, uint128 amount) external;
    function withdraw(address verifier, uint128 amount) external;

    // ----- Staking (MOCA) for verifiers -----
    function stakeMoca(address verifier) external payable;
    function unstakeMoca(address verifier, uint128 amount) external;

    // ----- Admin/Updater functions -----
    function updateSignerAddress(address newSignerAddress) external;
    function updateAssetManagerAddress(address newAssetManagerAddress, bool isIssuer) external returns (address);

    // ----- Schema Fee Management -----
    function updateSchemaFee(bytes32 schemaId, uint128 newFee) external returns (uint256);

    // ----- Universal Verification: deduct verifier's balance -----
    function deductBalance(
        address verifier,
        address userAddress,
        bytes32 schemaId,
        uint128 amount,
        uint256 expiry,
        bytes calldata signature
    ) external;

    // ----- Admin Functions -----
    function pause() external;
    function unpause() external;
    function freeze() external;

    // Emergency exit handlers
    function emergencyExitVerifiers(address[] calldata verifiers) external;
    function emergencyExitIssuers(address[] calldata issuers) external;
    function emergencyExitFees() external;

    // Pool Management (Admin)
    function updatePoolId(bytes32 schemaId, uint128 poolId) external;
    function whitelistPool(uint128 poolId, bool isWhitelisted) external;

    // Protocol Admin Config Setters
    function updateFeeIncreaseDelayPeriod(uint128 newDelayPeriod) external;
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external;
    function updateVotingFeePercentage(uint256 votingFeePercentage) external;
    function setVerifierSubsidyTiers(uint128[] calldata mocaStaked, uint128[] calldata subsidyPercentages) external;
    function clearVerifierSubsidyTiers() external;
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external;
}
