// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DataTypes} from "../libraries/DataTypes.sol";

interface IVotingEscrowMoca {

    // =============================== User Functions ===============================
    
    /**
     * @notice Creates a new lock with the specified expiry, esMoca, and optional delegate.
     * @dev MOCA amount is sent via msg.value
     * @param expiry The timestamp when the lock will expire (must be on epoch boundary).
     * @param esMoca The amount of esMOCA to lock.
     * @param delegate The address to delegate voting power to (optional, address(0) for no delegation).
     * @return lockId The unique identifier of the created lock.
     */
    function createLock(uint128 expiry, uint128 esMoca, address delegate) external payable returns (bytes32);

    /**
     * @notice Increases the amount of MOCA and/or esMOCA in an existing lock.
     * @dev MOCA amount is sent via msg.value
     * @param lockId The unique identifier of the lock to modify.
     * @param esMocaToIncrease The additional amount of esMOCA to lock.
     */
    function increaseAmount(bytes32 lockId, uint128 esMocaToIncrease) external payable;

    /**
     * @notice Increases the duration of an existing lock.
     * @param lockId The unique identifier of the lock to modify.
     * @param newExpiry The new expiry timestamp (must be on epoch boundary and greater than current expiry).
     */
    function increaseDuration(bytes32 lockId, uint128 newExpiry) external;

    /**
     * @notice Withdraws principals of an expired lock.
     * @param lockId The unique identifier of the lock to unlock.
     */
    function unlock(bytes32 lockId) external;

    // =============================== User Delegate Functions ===============================

    /**
     * @notice Delegates a lock's voting power to a registered delegate.
     * @dev Delegation impact occurs in the next epoch, not current.
     * @param lockId The unique identifier of the lock to delegate.
     * @param delegate The address of the registered delegate to receive voting power.
     */
    function delegateLock(bytes32 lockId, address delegate) external;

    /**
     * @notice Undelegates a lock's voting power from a registered delegate.
     * @dev Undelegation impact occurs in the next epoch, not current.
     * @param lockId The unique identifier of the lock to undelegate.
     */
    function undelegateLock(bytes32 lockId) external;

    /**
     * @notice Switches the delegate of a lock to another registered delegate.
     * @dev Delegation switch impact occurs in the next epoch, not current.
     * @param lockId The unique identifier of the lock.
     * @param newDelegate The address of the new delegate.
     */
    function switchDelegate(bytes32 lockId, address newDelegate) external;

    // =============================== Admin Functions ===============================

    /**
     * @notice Creates a lock on behalf of another user (admin function).
     * @dev MOCA amount is sent via msg.value
     * @param user The address to create the lock for.
     * @param expiry The timestamp when the lock will expire (must be on epoch boundary).
     * @param esMoca The amount of esMOCA to lock.
     * @return lockId The unique identifier of the created lock.
     */
    function createLockFor(address user, uint128 expiry, uint128 esMoca) external payable returns (bytes32);

    /**
     * @notice Admin helper to batch update stale accounts to the current epoch.
     * @dev Fixes OOG risks by applying pending deltas and decay in a separate transaction.
     * @param accounts Array of addresses to update.
     * @param isDelegate True if updating delegate accounts, False for user accounts.
     */
    function updateAccountsAndPendingDeltas(address[] calldata accounts, bool isDelegate) external;

    /**
     * @notice Admin helper to batch update stale user-delegate pairs to the current epoch.
     * @dev Fixes OOG risks by applying pending deltas and decay in a separate transaction.
     * @param users Array of user addresses.
     * @param delegates Array of delegate addresses (must match length of users array).
     */
    function updateDelegatePairsAndPendingDeltas(address[] calldata users, address[] calldata delegates) external;

    // =============================== VotingController Functions ===============================

    /**
     * @notice Register an address as a delegate, enabling it to receive delegated voting power.
     * @param delegate The address to register as a delegate.
     */
    function registerAsDelegate(address delegate) external;

    /**
     * @notice Unregister an address as a delegate, revoking its ability to receive delegated voting power.
     * @param delegate The address to unregister as a delegate.
     */
    function unregisterAsDelegate(address delegate) external;

    // =============================== Risk Management ===============================

    /**
     * @notice Pause the contract.
     */
    function pause() external;

    /**
     * @notice Unpause the contract.
     */
    function unpause() external;

    /**
     * @notice Freeze the contract in case of emergency.
     */
    function freeze() external;

    /**
     * @notice Emergency exit function to return principals to users when contract is frozen.
     * @param lockIds Array of lock IDs to process for emergency exit.
     */
    function emergencyExit(bytes32[] calldata lockIds) external;

    // =============================== View Functions ===============================

    /**
     * @notice Returns current total supply of voting escrowed tokens (veTokens).
     * @return Updated current total supply of veTokens.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @notice Returns the projected total supply of voting escrowed tokens at a future timestamp.
     * @param time The future timestamp for which the total supply is projected.
     * @return The projected total supply of veTokens at the specified future timestamp.
     */
    function totalSupplyInFuture(uint128 time) external view returns (uint256);

    /**
     * @notice Returns the current personal voting power (veBalance) of a user.
     * @param user The address of the user whose veBalance is being queried.
     * @return The current personal veBalance of the user.
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the current voting power (veBalance) of a user.
     * @param user The address of the user whose veBalance is being queried.
     * @param forDelegated If true: delegated veBalance; if false: personal veBalance.
     * @return The current veBalance of the user.
     */
    function balanceOf(address user, bool forDelegated) external view returns (uint256);

    /**
     * @notice Historical search of a user's voting escrowed balance (veBalance) at a specific timestamp.
     * @param user The address of the user whose veBalance is being queried.
     * @param time The historical timestamp for which the veBalance is requested.
     * @param forDelegated If true: delegated veBalance; if false: personal veBalance.
     * @return The user's veBalance at the specified timestamp.
     */
    function balanceOfAt(address user, uint256 time, bool forDelegated) external view returns (uint256);

    /**
     * @notice Returns the voting power of a user at the end of a specific epoch.
     * @param user The address of the user whose veBalance is being queried.
     * @param epoch The epoch number for which the veBalance is requested.
     * @param forDelegated If true: delegated veBalance; if false: personal veBalance.
     * @return The user's voting power at the end of the specified epoch.
     */
    function balanceAtEpochEnd(address user, uint256 epoch, bool forDelegated) external view returns (uint256);

    /**
     * @notice Returns the specific delegated balance of a user to a delegate at the end of an epoch.
     * @param user The address of the user whose delegated balance is being queried.
     * @param delegate The address of the delegate.
     * @param epoch The epoch number for which the delegated balance is requested.
     * @return The user's specific delegated balance to the delegate at the end of the specified epoch.
     */
    function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint128);

    // =============================== Lock View Functions ===============================

    /**
     * @notice Returns the number of checkpoints in the lock's history.
     * @param lockId The ID of the lock.
     * @return The number of checkpoints.
     */
    function getLockHistoryLength(bytes32 lockId) external view returns (uint256);

    /**
     * @notice Returns the current veBalance of a lock.
     * @param lockId The ID of the lock whose veBalance is being queried.
     * @return The current veBalance of the lock.
     */
    function getLockCurrentVeBalance(bytes32 lockId) external view returns (DataTypes.VeBalance memory);

    /**
     * @notice Returns the current voting power of a lock.
     * @param lockId The ID of the lock whose voting power is being queried.
     * @return The current voting power of the lock.
     */
    function getLockCurrentVotingPower(bytes32 lockId) external view returns (uint256);

    /**
     * @notice Historical search for a lock's veBalance at a specific timestamp.
     * @param lockId The ID of the lock.
     * @param timestamp The timestamp to query.
     * @return The veBalance of the lock at the specified timestamp.
     */
    function getLockVeBalanceAt(bytes32 lockId, uint128 timestamp) external view returns (uint256);

    // =============================== State Variable Getters ===============================

    /**
     * @notice Returns the total amount of MOCA locked in the contract.
     * @return The total locked MOCA amount.
     */
    function totalLockedMoca() external view returns (uint256);

    /**
     * @notice Returns the total amount of esMOCA locked in the contract.
     * @return The total locked esMOCA amount.
     */
    function totalLockedEsMoca() external view returns (uint256);

    /**
     * @notice Returns the global veBalance state.
     * @return The global veBalance.
     */
    function veGlobal() external view returns (DataTypes.VeBalance memory);

    /**
     * @notice Returns the timestamp of the last global update.
     * @return The last updated timestamp.
     */
    function lastUpdatedTimestamp() external view returns (uint256);

    /**
     * @notice Returns lock information for a given lock ID.
     * @param lockId The lock ID to query.
     * @return The lock data.
     */
    function locks(bytes32 lockId) external view returns (DataTypes.Lock memory);

    /**
     * @notice Returns checkpoint information for a lock at a specific index.
     * @param lockId The lock ID to query.
     * @param index The checkpoint index.
     * @return The checkpoint data.
     */
    function lockHistory(bytes32 lockId, uint256 index) external view returns (DataTypes.Checkpoint memory);

    /**
     * @notice Returns scheduled slope changes at a specific time.
     * @param eTime The epoch time to query.
     * @return The slope change amount.
     */
    function slopeChanges(uint256 eTime) external view returns (uint256);

    /**
     * @notice Returns the total supply at a specific epoch time.
     * @param eTime The epoch time to query.
     * @return The total supply at that time.
     */
    function totalSupplyAt(uint256 eTime) external view returns (uint256);

    /**
     * @notice Returns user slope changes at a specific time.
     * @param user The user address.
     * @param eTime The epoch time to query.
     * @return The user's slope change amount.
     */
    function userSlopeChanges(address user, uint256 eTime) external view returns (uint256);

    /**
     * @notice Returns user's veBalance history at a specific time.
     * @param user The user address.
     * @param eTime The epoch time to query.
     * @return The user's veBalance at that time.
     */
    function userHistory(address user, uint256 eTime) external view returns (DataTypes.VeBalance memory);

    /**
     * @notice Returns the last updated timestamp for a user.
     * @param user The user address.
     * @return The user's last updated timestamp.
     */
    function userLastUpdatedTimestamp(address user) external view returns (uint256);

    /**
     * @notice Returns whether an address is registered as a delegate.
     * @param delegate The delegate address.
     * @return True if registered as delegate.
     */
    function isRegisteredDelegate(address delegate) external view returns (bool);

    /**
     * @notice Returns delegate slope changes at a specific time.
     * @param delegate The delegate address.
     * @param eTime The epoch time to query.
     * @return The delegate's slope change amount.
     */
    function delegateSlopeChanges(address delegate, uint256 eTime) external view returns (uint256);

    /**
     * @notice Returns delegate's veBalance history at a specific time.
     * @param delegate The delegate address.
     * @param eTime The epoch time to query.
     * @return The delegate's veBalance at that time.
     */
    function delegateHistory(address delegate, uint256 eTime) external view returns (DataTypes.VeBalance memory);

    /**
     * @notice Returns the last updated timestamp for a delegate.
     * @param delegate The delegate address.
     * @return The delegate's last updated timestamp.
     */
    function delegateLastUpdatedTimestamp(address delegate) external view returns (uint256);

    /**
     * @notice Returns the delegated aggregation history for a user-delegate pair at a specific time.
     * @param user The user address.
     * @param delegate The delegate address.
     * @param eTime The epoch time to query.
     * @return The delegated veBalance at that time.
     */
    function delegatedAggregationHistory(address user, address delegate, uint256 eTime) external view returns (DataTypes.VeBalance memory);

    /**
     * @notice Returns the last updated timestamp for a user-delegate pair.
     * @param user The user address.
     * @param delegate The delegate address.
     * @return The user-delegate pair's last updated timestamp.
     */
    function userDelegatePairLastUpdatedTimestamp(address user, address delegate) external view returns (uint256);

    /**
     * @notice Returns whether the contract is frozen.
     * @return 1 if frozen, 0 if not frozen.
     */
    function isFrozen() external view returns (uint256);
}
