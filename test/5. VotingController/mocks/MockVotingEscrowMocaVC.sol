// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {DataTypes} from "../../../src/libraries/DataTypes.sol";

/**
 * @title MockVotingEscrowMocaVC
 * @notice Standalone mock VotingEscrowMoca for VotingController tests
 * @dev Implements only the interface needed by VotingController without inheriting from VotingEscrowMoca
 */
contract MockVotingEscrowMocaVC {

    // Storage for mocked balances
    // user => epoch => isDelegated => balance
    mapping(address => mapping(uint128 => mapping(bool => uint128))) private _mockedBalanceAtEpochEnd;
    // user => delegate => epoch => specificDelegatedBalance
    mapping(address => mapping(address => mapping(uint128 => uint128))) private _mockedSpecificDelegatedBalance;
    
    // Delegate registration tracking
    mapping(address => bool) public registeredDelegates;

    // ═══════════════════════════════════════════════════════════════════
    // Mock Setters for Testing
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Sets mocked balance at epoch end for a user
     * @param user The user address
     * @param epoch The epoch number
     * @param isDelegated Whether this is delegated balance
     * @param balance The balance value
     */
    function setMockedBalanceAtEpochEnd(
        address user,
        uint128 epoch,
        bool isDelegated,
        uint128 balance
    ) external {
        _mockedBalanceAtEpochEnd[user][epoch][isDelegated] = balance;
    }

    /**
     * @notice Sets mocked specific delegated balance at epoch end
     * @param user The delegator address
     * @param delegate The delegate address
     * @param epoch The epoch number
     * @param balance The delegated balance value
     */
    function setMockedSpecificDelegatedBalance(
        address user,
        address delegate,
        uint128 epoch,
        uint128 balance
    ) external {
        _mockedSpecificDelegatedBalance[user][delegate][epoch] = balance;
    }

    /**
     * @notice Batch set mocked balances for multiple users
     * @param users Array of user addresses
     * @param epoch The epoch number
     * @param isDelegated Whether these are delegated balances
     * @param balances Array of balance values
     */
    function batchSetMockedBalances(
        address[] calldata users,
        uint128 epoch,
        bool isDelegated,
        uint128[] calldata balances
    ) external {
        require(users.length == balances.length, "Array length mismatch");
        
        for (uint256 i = 0; i < users.length; ++i) {
            _mockedBalanceAtEpochEnd[users[i]][epoch][isDelegated] = balances[i];
        }
    }

    /**
     * @notice Batch set mocked specific delegated balances
     * @param users Array of delegator addresses
     * @param delegates Array of delegate addresses
     * @param epoch The epoch number
     * @param balances Array of balance values
     */
    function batchSetMockedSpecificDelegatedBalances(
        address[] calldata users,
        address[] calldata delegates,
        uint128 epoch,
        uint128[] calldata balances
    ) external {
        require(users.length == delegates.length && users.length == balances.length, "Array length mismatch");
        
        for (uint256 i = 0; i < users.length; ++i) {
            _mockedSpecificDelegatedBalance[users[i]][delegates[i]][epoch] = balances[i];
        }
    }

    // Dummy setter for compatibility
    function setUseMockedBalances(bool) external pure {
        // No-op since this mock always uses mocked values
    }

    // ═══════════════════════════════════════════════════════════════════
    // IVotingEscrowMoca Interface Implementation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Returns mocked balance at epoch end
     */
    function balanceAtEpochEnd(address user, uint128 epoch, bool forDelegated) external view returns (uint128) {
        return _mockedBalanceAtEpochEnd[user][epoch][forDelegated];
    }

    /**
     * @notice Returns mocked specific delegated balance at epoch end
     */
    function getSpecificDelegatedBalanceAtEpochEnd(
        address user,
        address delegate,
        uint128 epoch
    ) external view returns (uint128) {
        return _mockedSpecificDelegatedBalance[user][delegate][epoch];
    }

    /**
     * @notice Updates delegate registration status
     * @dev Called by VotingController when delegate registers/unregisters
     */
    function delegateRegistrationStatus(address delegate, bool toRegister) external {
        registeredDelegates[delegate] = toRegister;
    }

    /**
     * @notice Check if delegate is registered
     */
    function isRegisteredDelegate(address delegate) external view returns (bool) {
        return registeredDelegates[delegate];
    }

    // ═══════════════════════════════════════════════════════════════════
    // Helper Getters for Tests
    // ═══════════════════════════════════════════════════════════════════

    function getMockedBalanceAtEpochEnd(address user, uint128 epoch, bool isDelegated) external view returns (uint128) {
        return _mockedBalanceAtEpochEnd[user][epoch][isDelegated];
    }

    function getMockedSpecificDelegatedBalance(address user, address delegate, uint128 epoch) external view returns (uint128) {
        return _mockedSpecificDelegatedBalance[user][delegate][epoch];
    }
}
