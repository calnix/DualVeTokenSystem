// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// interfaces
import {IAddressBook} from "../interfaces/IAddressBook.sol";

// Lock Migration Function
contract VotingEscrowMocaMigratable {
    IAddressBook public immutable addressBook;

    address public migrationTarget;
    
    function setMigrationTarget(address _target) external onlyGlobalAdminRole {
        require(migrationTarget == address(0), "Already set");
        migrationTarget = _target;
    }
    
    function migrateLock(bytes32 lockId) external {
        require(migrationTarget != address(0), "No migration target");
        DataTypes.Lock memory lock = locks[lockId];
        require(lock.owner == msg.sender, "Not owner");
        require(!lock.isUnlocked, "Already unlocked");
        
        // Mark as migrated
        lock.isUnlocked = true;
        locks[lockId] = lock;
        
        // Call migration contract
        IVotingEscrowMocaV2(migrationTarget).receiveMigration(
            msg.sender,
            lockId,
            lock
        );
        
        // Transfer tokens to migration contract
        if(lock.moca > 0) _mocaToken().safeTransfer(migrationTarget, lock.moca);
        if(lock.esMoca > 0) _esMocaToken().safeTransfer(migrationTarget, lock.esMoca);
        
        emit LockMigrated(lockId, msg.sender, migrationTarget);
    }
}

/** Emergency Migration Mode Pattern

    uint256 public migrationMode;  // 0: normal, 1: migration active

    function enableMigration() external onlyGlobalAdminRole whenPaused {
        migrationMode = 1;
        emit MigrationEnabled();
    }

    function emergencyMigrate(
        bytes32[] calldata lockIds,
        address newContract
    ) external onlyEmergencyExitHandlerRole {
        require(migrationMode == 1, "Migration not enabled");
        // Batch migrate locks with signature verification
    }

 */