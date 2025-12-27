// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {DataTypes} from "../../../src/libraries/DataTypes.sol";

/**
 * @title MockPaymentsControllerVC
 * @notice Standalone mock PaymentsController for VotingController tests
 * @dev Implements only the interface needed by VotingController without inheriting from PaymentsController
 */
contract MockPaymentsControllerVC {
    
    // Storage for mocked verifier and pool accrued subsidies
    // epoch => poolId => verifier => accruedSubsidies
    mapping(uint128 => mapping(uint128 => mapping(address => uint256))) private _mockedVerifierAccruedSubsidies;
    // epoch => poolId => poolAccruedSubsidies  
    mapping(uint128 => mapping(uint128 => uint256)) private _mockedPoolAccruedSubsidies;
    // verifier => assetManagerAddress
    mapping(address => address) private _verifierAssetManagers;

    // ═══════════════════════════════════════════════════════════════════
    // Mock Setters for Testing
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Sets mocked verifier accrued subsidies for a specific epoch, pool, and verifier
     * @param epoch The epoch number
     * @param poolId The pool ID
     * @param verifier The verifier address
     * @param amount The accrued subsidy amount
     */
    function setMockedVerifierAccruedSubsidies(
        uint128 epoch,
        uint128 poolId,
        address verifier,
        uint256 amount
    ) external {
        _mockedVerifierAccruedSubsidies[epoch][poolId][verifier] = amount;
    }

    /**
     * @notice Sets mocked pool accrued subsidies for a specific epoch and pool
     * @param epoch The epoch number
     * @param poolId The pool ID
     * @param amount The total pool accrued subsidy amount
     */
    function setMockedPoolAccruedSubsidies(
        uint128 epoch,
        uint128 poolId,
        uint256 amount
    ) external {
        _mockedPoolAccruedSubsidies[epoch][poolId] = amount;
    }

    /**
     * @notice Sets the asset manager address for a verifier
     * @param verifier The verifier address
     * @param assetManager The asset manager address
     */
    function setVerifierAssetManager(address verifier, address assetManager) external {
        _verifierAssetManagers[verifier] = assetManager;
    }

    /**
     * @notice Batch set mocked subsidies for multiple verifiers in a pool
     * @param epoch The epoch number
     * @param poolId The pool ID
     * @param verifiers Array of verifier addresses
     * @param amounts Array of subsidy amounts for each verifier
     * @param totalPoolSubsidies The total pool subsidies
     */
    function batchSetMockedSubsidies(
        uint128 epoch,
        uint128 poolId,
        address[] calldata verifiers,
        uint256[] calldata amounts,
        uint256 totalPoolSubsidies
    ) external {
        require(verifiers.length == amounts.length, "Array length mismatch");
        
        for (uint256 i = 0; i < verifiers.length; ++i) {
            _mockedVerifierAccruedSubsidies[epoch][poolId][verifiers[i]] = amounts[i];
        }
        _mockedPoolAccruedSubsidies[epoch][poolId] = totalPoolSubsidies;
    }

    // ═══════════════════════════════════════════════════════════════════
    // IPaymentsController Interface Implementation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Returns mocked subsidy values for testing
     * @dev Validates caller is the verifier's asset manager
     */
    function getVerifierAndPoolAccruedSubsidies(
        uint128 epoch,
        uint128 poolId,
        address verifier,
        address caller
    ) external view returns (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) {
        // Validate caller is the verifier's asset manager
        require(_verifierAssetManagers[verifier] == caller, "Caller is not verifier's asset manager");
        
        verifierAccruedSubsidies = _mockedVerifierAccruedSubsidies[epoch][poolId][verifier];
        poolAccruedSubsidies = _mockedPoolAccruedSubsidies[epoch][poolId];
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Getters for Tests
    // ═══════════════════════════════════════════════════════════════════

    function getMockedVerifierSubsidies(uint128 epoch, uint128 poolId, address verifier) external view returns (uint256) {
        return _mockedVerifierAccruedSubsidies[epoch][poolId][verifier];
    }

    function getMockedPoolSubsidies(uint128 epoch, uint128 poolId) external view returns (uint256) {
        return _mockedPoolAccruedSubsidies[epoch][poolId];
    }

    function getVerifierAssetManager(address verifier) external view returns (address) {
        return _verifierAssetManagers[verifier];
    }
}
