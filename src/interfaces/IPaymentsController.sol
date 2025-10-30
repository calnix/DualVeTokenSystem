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
        uint256 epoch,
        bytes32 poolId,
        bytes32 verifierId,
        address caller
    ) external view returns (uint256, uint256);

    function getIssuer(bytes32 issuerId) external view returns (DataTypes.Issuer memory);

    function getSchema(bytes32 schemaId) external view returns (DataTypes.Schema memory);

    function getVerifier(bytes32 verifierId) external view returns (DataTypes.Verifier memory);

    function getVerifierNonce(address signerAddress) external view returns (uint256);

    function getVerifierSubsidyPercentage(uint256 mocaStaked) external view returns (uint256);

    function getEpochPoolSubsidies(uint256 epoch, bytes32 poolId) external view returns (uint256);

    function getEpochPoolVerifierSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId) external view returns (uint256);

    function getEpochPoolFeesAccrued(uint256 epoch, bytes32 poolId) external view returns (DataTypes.FeesAccrued memory);

    function getEpochFeesAccrued(uint256 epoch) external view returns (DataTypes.FeesAccrued memory);

    // ----- AssetManager: deposit/withdraw for verifiers -----
    function deposit(bytes32 verifierId, uint128 amount) external;

    function withdraw(bytes32 verifierId, uint128 amount) external;

    // ----- Staking (MOCA) for verifiers -----
    function stakeMoca(bytes32 verifierId) external payable;

    function unstakeMoca(bytes32 verifierId, uint128 amount) external payable;

    // ----- Admin/Updater functions -----
    function updateSignerAddress(bytes32 verifierId, address signerAddress) external;

    function updateAssetManagerAddress(bytes32 id, address newAssetManagerAddress) external returns (address);

    // ----- Schema Fee Management -----
    function updateSchemaFee(bytes32 issuerId, bytes32 schemaId, uint128 newFee) external returns (uint256);

    // ----- Universal Verification: deduct verifier's balance -----
    function deductBalance(
        bytes32 issuerId,
        bytes32 verifierId,
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
    function emergencyExitVerifiers(bytes32[] calldata verifierIds) external payable;
    function emergencyExitIssuers(bytes32[] calldata issuerIds) external;
    function emergencyExitFees() external;
}
