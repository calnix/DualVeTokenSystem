// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/**
 * @title IAirKit
 * @dev Interface for AirKit contract that tracks verification payments
 */
interface IAirKit {
    /**
     * @dev Returns the total spend by a verifier for a specific epoch and pool
     * @param verifier The address of the verifier
     * @param epoch The epoch number
     * @param credentialId The ID of the credential
     * @return The total amount spent by the verifier
     */
    function getTotalSpend(address verifier, uint256 epoch, bytes32 credentialId) external view returns (uint256);
}
