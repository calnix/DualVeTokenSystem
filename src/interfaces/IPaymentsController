// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title IOmPm
 * @dev Interface for OmPm contract that tracks verification payments
 */
interface IPaymentsController {

    function feesAccruedToVoters(uint256 epoch, bytes32 credentialId) external view returns (uint256);

    function getIssuer(bytes32 issuerId) external view returns (Issuer memory);

    function getCredential(bytes32 credentialId) external view returns (Credential memory);

    function getVerifier(bytes32 verifierId) external view returns (Verifier memory);

    function getVerifierNonce(address verifier) external view returns (uint256);
}
