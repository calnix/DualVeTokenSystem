// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {DataTypes} from "../libraries/DataTypes.sol";
import {IAddressBook} from "./IAddressBook.sol";

/**
 * @title IPaymentsController
 * @author Calnix [@cal_nix]
 * @notice Defines the basic interface for PaymentsController.sol
 */

interface IPaymentsController {

    function getVerifierAndPoolAccruedSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId, address caller) external view returns (uint128, uint128);
    function getAddressBook() external view returns (IAddressBook);
    function getIssuer(bytes32 issuerId) external view returns (DataTypes.Issuer memory);
    function getSchema(bytes32 schemaId) external view returns (DataTypes.Schema memory);
    function getVerifier(bytes32 verifierId) external view returns (DataTypes.Verifier memory);
    function getVerifierNonce(address verifier) external view returns (uint256);
    function getVerifierSubsidyPercentage(uint256 mocaStaked) external view returns (uint256);
    function getEpochPoolSubsidies(uint256 epoch, bytes32 poolId) external view returns (uint256);
    function getEpochPoolVerifierSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId) external view returns (uint256);
    function getEpochPoolFeesAccrued(uint256 epoch, bytes32 poolId) external view returns (DataTypes.FeesAccrued memory);
    function getEpochFeesAccrued(uint256 epoch) external view returns (DataTypes.FeesAccrued memory);
}
