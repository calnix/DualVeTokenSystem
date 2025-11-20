// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// OZ
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {EpochMath} from "./libraries/EpochMath.sol";
import {Constants} from "./libraries/Constants.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
    - Stake MOCA tokens to receive veMOCA (voting power)
    - Longer lock periods result in higher veMOCA allocation
    - veMOCA decays linearly over time, reducing voting power
    - Formula-based calculation determines veMOCA amount based on stake amount and duration
 */

contract veMoca is ERC20, LowLevelWMoca, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    address public immutable WMOCA;
    IERC20 public immutable ESMOCA;

    // global principal amounts
    uint256 public TOTAL_LOCKED_MOCA;
    uint256 public TOTAL_LOCKED_ESMOCA;

    // global veBalance
    DataTypes.VeBalance public veGlobal;
    uint256 public lastUpdatedTimestamp;  

    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;

    // risk
    uint256 public isFrozen;

//------------------------------- Mappings ------------------------------------------

    // --------- Global state ---------
    // scheduled global slope changes
    mapping(uint256 eTime => uint256 slopeChange) public slopeChanges;
    // saving totalSupply checkpoint for each epoch
    mapping(uint256 eTime => uint256 totalSupply) public totalSupplyAt;


    // --------- Lock state ---------
    mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
    // Checkpoints are added upon every state transition; checkpoints timestamp will lie on epoch boundaries
    mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;

    // --------- User state ---------
    // user personal data: cannot use array as likely will get very large
    mapping(address user => mapping(uint256 eTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
    mapping(address user => mapping(uint256 eTime => uint256 slopeChange)) public userSlopeChanges;
    mapping(address user => uint256 lastUpdatedTimestamp) public userLastUpdatedTimestamp;


//------------------------------- constructor ------------------------------------------

    constructor(address wMoca_, address esMoca_, address owner_, uint256 mocaTransferGasLimit) ERC20("veMoca", "veMOCA") {
        // cannot deploy at T=0
        require(block.timestamp > 0, Errors.InvalidTimestamp());

        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // esMoca 
        require(esMoca_ != address(0), Errors.InvalidAddress());
        ESMOCA = IERC20(esMoca_);

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;

        // roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
    }

//------------------------------- External functions------------------------------------------


    // lock created is booked to currentEpochStart
    function createLock(uint128 expiry, uint128 esMoca) external payable  whenNotPaused returns (bytes32) {
        // Enforce minimum increment amount to avoid precision loss
        uint128 moca = uint128(msg.value);
        _minimumAmountCheck(moca, esMoca);

        // check: expiry is a valid epoch time [must end on an epoch boundary]
        require(EpochMath.isValidEpochTime(expiry), "Expiry must be a valid epoch beginning");

        // check: lock duration is within allowed range
        require(expiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, "Lock duration too short");
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, "Lock duration too long");


        // check: expiry is at least 2 Epochs from current epoch start [lock lasts for current epoch and expires at the end of the next epoch]
        uint256 currentEpochStart = _requireEligibleExpiry(expiry);

        // update user and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateUserAndGlobal(msg.sender, currentEpochStart);

        // --------- generate lockId ---------

            // vaultId generation
            bytes32 lockId;
            {
                uint256 salt = block.number;
                lockId = _generateVaultId(salt, msg.sender);
                while (locks[lockId].lockId != bytes32(0)) lockId = _generateVaultId(++salt, msg.sender);      // If lockId exists, generate new random Id
            }

        // --------- create lock ---------
            DataTypes.Lock memory newLock;
                newLock.lockId = lockId;
                newLock.owner = msg.sender;
                newLock.moca = moca;
                newLock.esMoca = esMoca;
                newLock.expiry = expiry;
            // STORAGE: book lock
            locks[lockId] = newLock;

            // get lock's veBalance
            DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);

            // STORAGE: book checkpoint into lock history 
            _pushCheckpoint(lockHistory[lockId], veIncoming, uint128(currentEpochStart));

            // emit: lock created
            emit Events.LockCreated(lockId, msg.sender, /*delegate*/ address(0), newLock.moca, newLock.esMoca, newLock.expiry);

        // --------- Increment global state: add veIncoming to veGlobal ---------
        
        // STORAGE: update global veBalance & schedule slope change
        veGlobal_ = _add(veGlobal_, veIncoming);
        veGlobal = veGlobal_;
        slopeChanges[newLock.expiry] += veIncoming.slope;

        // emit: global updated
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // --------- Increment user state: add veIncoming to user ---------
        
        // STORAGE: update user veBalance & schedule slope change
        veUser_ = _add(veUser_, veIncoming);
        userHistory[msg.sender][currentEpochStart] = veUser_;
        userSlopeChanges[msg.sender][newLock.expiry] += veIncoming.slope;

        // emit: user updated
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        // STORAGE: increment global TOTAL_LOCKED_MOCA
        if(moca > 0) TOTAL_LOCKED_MOCA += moca;

        // STORAGE: increment global TOTAL_LOCKED_ESMOCA & TRANSFER: esMoca to contract
        if(esMoca > 0) {
            TOTAL_LOCKED_ESMOCA += esMoca;
            ESMOCA.safeTransferFrom(msg.sender, address(this), esMoca);
        }

        return lockId;
    }

    // user to increase amount of lock
    function increaseAmount(bytes32 lockId, uint128 esMocaToAdd) external payable whenNotPaused {
        DataTypes.Lock memory oldLock = locks[lockId];

        // sanity check: lock exists & user is the owner
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());
        // sanity check: lock is not expired
        require(oldLock.expiry > block.timestamp, Errors.LockExpired());

        // check: expiry is at least 2 Epochs from current epoch start [lock lasts for current epoch and expires at the end of the next epoch]
        uint256 currentEpochStart = _requireEligibleExpiry(oldLock.expiry);

        // Enforce minimum increment amount to avoid precision loss
        uint128 mocaToAdd = uint128(msg.value);
        _minimumAmountCheck(mocaToAdd, esMocaToAdd);

        // update user and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & user]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateUserAndGlobal(msg.sender, currentEpochStart);


        // create new lock: update amounts
        DataTypes.Lock memory newLock = oldLock;
            newLock.moca += mocaToAdd;
            newLock.esMoca += esMocaToAdd;

        // STORAGE: update global and user veBalance + handle slope changes
        (DataTypes.VeBalance memory newVeBalance,) = _modifyLock(veGlobal_, veUser_, oldLock, newLock, currentEpochStart);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newVeBalance, uint128(currentEpochStart));

        // STORAGE: increment global TOTAL_LOCKED_MOCA
        if(mocaToAdd > 0) TOTAL_LOCKED_MOCA += mocaToAdd;

        // STORAGE: increment global TOTAL_LOCKED_ESMOCA & TRANSFER: esMoca to contract
        if(esMocaToAdd > 0) {
            TOTAL_LOCKED_ESMOCA += esMocaToAdd;
            ESMOCA.safeTransferFrom(msg.sender, address(this), esMocaToAdd);
        }

        // emit event
        emit Events.LockAmountIncreased(lockId, msg.sender, mocaToAdd, esMocaToAdd);
    }


    // user to increase duration of lock
    function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external whenNotPaused {
        // get lock
        DataTypes.Lock memory oldLock = locks[lockId];

        // sanity check: lock exists, user is the owner, lock is not expired
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());
        require(oldLock.expiry > block.timestamp, Errors.LockExpired());

        // check: new expiry is a valid epoch time & within allowed range
        uint128 newExpiry = oldLock.expiry + durationToIncrease;
        require(EpochMath.isValidEpochTime(newExpiry), Errors.InvalidEpochTime());
        require(newExpiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidExpiry());

        // check: expiry is at least 2 Epochs from current epoch start [lock lasts for current epoch and expires at the end of the next epoch]
        uint256 currentEpochStart = _requireEligibleExpiry(newExpiry);
        
        // update user and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & user]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateUserAndGlobal(msg.sender, currentEpochStart);


        // copy old lock: update duration
        DataTypes.Lock memory newLock = oldLock;
        newLock.expiry = newExpiry;


        // STORAGE: update global and user veBalance + handle slope changes
        (DataTypes.VeBalance memory newVeBalance,) = _modifyLock(veGlobal_, veUser_, oldLock, newLock, currentEpochStart);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newVeBalance, uint128(currentEpochStart));

        // emit event
        emit Events.LockDurationIncreased(lockId, msg.sender, oldLock.expiry, newLock.expiry);
    }


    /**
     * @notice Withdraws principals of an expired lock 
     * @dev ve will be burnt, altho veBalance will return 0 on expiry
     * @dev Only the lock owner can call this function.
     * @param lockId The unique identifier of the lock to unlock.
     */
    function unlock(bytes32 lockId) external whenNotPaused {
        DataTypes.Lock memory lock = locks[lockId];

        // sanity check: lock exists + user is the owner
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        // sanity check: lock is expired 
        require(lock.expiry <= block.timestamp, Errors.InvalidExpiry());
        // sanity check: lock is not already unlocked
        require(lock.isUnlocked == false, Errors.InvalidLockState());

        // get current epoch start
        uint256 currentEpochStart = EpochMath.getCurrentEpochStart();

        // update user and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & user]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateUserAndGlobal(msg.sender, currentEpochStart);

        // STORAGE: push final checkpoint into lock history
        _pushCheckpoint(lockHistory[lockId], _convertToVeBalance(lock), uint128(currentEpochStart));

        // STORAGE: decrement global totalLocked counters
        TOTAL_LOCKED_MOCA -= lock.moca;
        TOTAL_LOCKED_ESMOCA -= lock.esMoca;

        // cache principals + delete from lock
        uint256 cachedMoca = lock.moca;
        uint256 cachedEsMoca = lock.esMoca;
        delete lock.moca;
        delete lock.esMoca;

        // storage: update lock
        lock.isUnlocked = true;    
        locks[lockId] = lock;

        emit Events.LockUnlocked(lockId, lock.owner, lock.moca, lock.esMoca);

        // return principals to lock.owner
        if(cachedEsMoca > 0) ESMOCA.safeTransfer(lock.owner, cachedEsMoca);        
        if(cachedMoca > 0) _transferMocaAndWrapIfFailWithGasLimit(WMOCA, lock.owner, cachedMoca, MOCA_TRANSFER_GAS_LIMIT);
    }


//-------------------------------internal: update functions-----------------------------------------------------


    // does not update veGlobal. updates lastUpdatedTimestamp, totalSupplyAt[]
    function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint256 lastUpdatedAt, uint256 currentEpochStart) internal returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current epoch [already up to date]
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // 1st call: no prior updates [global lastUpdatedTimestamp is set to currentEpochStart]
        if(lastUpdatedAt == 0) {
            lastUpdatedTimestamp = currentEpochStart;   // move forward the anchor point to skip empty epochs
            return veGlobal_;
        }

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);

            // book ve supply for this epoch
            totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);
        }

        // set final lastUpdatedTimestamp
        lastUpdatedTimestamp = lastUpdatedAt;

        return (veGlobal_);
    }

    /**
        - user.lastUpdatedAt either matches the global.lastUpdatedAt OR is behind it
        - the global never lags behind the user
     */
    function _updateUserAndGlobal(address user, uint256 currentEpochStart) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint256 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init user veUser
        DataTypes.VeBalance memory veUser_;

        // get user's lastUpdatedTimestamp [either matches global or lags behind it]
        uint256 userLastUpdatedAt = userLastUpdatedTimestamp[user];
        

        // user's first time: no prior updates to execute 
        if (userLastUpdatedAt == 0) {
            
            // set user's lastUpdatedTimestamp
            userLastUpdatedTimestamp[user] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veUser_);
        }
                
        // get user's previous veBalance: if both global and user are up to date, return
        veUser_ = userHistory[user][userLastUpdatedAt];
        if(userLastUpdatedAt >= currentEpochStart) return (veGlobal_, veUser_); 

        // update both global and user veBalance to current epoch
        while (userLastUpdatedAt < currentEpochStart) {

            // advance 1 epoch
            userLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < userLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[userLastUpdatedAt], userLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[userLastUpdatedAt] = _getValueAt(veGlobal_, userLastUpdatedAt);
            }

            // update user: apply scheduled slope reductions and decrement bias for expiring locks
            veUser_ = _subtractExpired(veUser_, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
            // book user checkpoint 
            userHistory[user][userLastUpdatedAt] = veUser_;
        }

        // set final lastUpdatedTimestamp: for global & user
        lastUpdatedTimestamp = userLastUpdatedTimestamp[user] = userLastUpdatedAt;
        
        // return
        return (veGlobal_, veUser_);
    }

    /**
     * @dev Internal function to handle lock modifications (amount or duration changes)
     * @param veGlobal_ Current global veBalance (already updated to currentEpochStart)
     * @param veUser_ Current user veBalance (already updated to currentEpochStart)
     * @param oldLock The lock before modification
     * @param newLock The lock after modification
     * @param currentEpochStart The current epoch start timestamp
     * @return newVeBalance The new veBalance calculated from newLock
     * @return increaseInVeBalance The delta between new and old veBalance
     */
    function _modifyLock(
        DataTypes.VeBalance memory veGlobal_,
        DataTypes.VeBalance memory veUser_,
        DataTypes.Lock memory oldLock,
        DataTypes.Lock memory newLock,
        uint256 currentEpochStart
    ) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        
        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(oldLock);
        DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(newLock);

        // get delta btw veBalance of old and new lock
        DataTypes.VeBalance memory increaseInVeBalance = _sub(newVeBalance, oldVeBalance);

        // handle slope changes: global + user
        if(newLock.expiry != oldLock.expiry) {
            // SCENARIO: increaseDuration() - expiry changed

            // global slope changes
            slopeChanges[oldLock.expiry] -= oldVeBalance.slope;
            slopeChanges[newLock.expiry] += newVeBalance.slope;
            
            // user slope changes
            userSlopeChanges[msg.sender][oldLock.expiry] -= oldVeBalance.slope;
            userSlopeChanges[msg.sender][newLock.expiry] += newVeBalance.slope;
        } else {
            // SCENARIO: increaseAmount() - only amounts changed
            
            // global slope changes
            slopeChanges[newLock.expiry] += increaseInVeBalance.slope;
            // user slope changes
            userSlopeChanges[msg.sender][newLock.expiry] += increaseInVeBalance.slope;
        }


        // STORAGE: update global veBalance
        veGlobal_ = _add(veGlobal_, increaseInVeBalance);
        veGlobal = veGlobal_;

        // emit: global updated
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);


        // STORAGE: update user veBalance
        veUser_ = _add(veUser_, increaseInVeBalance);
        userHistory[msg.sender][currentEpochStart] = veUser_;

        // emit: user updated
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);

        return (newVeBalance, increaseInVeBalance);
    }

//-------------------------------internal: helper functions-----------------------------------------------------

    ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }

    function _minimumAmountCheck(uint128 moca, uint128 esMoca) internal pure {
        uint128 totalAmount = moca + esMoca;
        require(totalAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());
    }
    
    /*  must have at least 2 Epoch left to increase amount: to meaningfully vote for the current epoch.
        - non-zero voting power in the current epoch. 
        - 0 voting power in the next epoch.
        this is a result of forward-decay: benchmarking voting power to the end of the epoch [to freeze intra-epoch decay] 
    */  
    function _requireEligibleExpiry(uint256 expiry) internal view returns (uint256) {
        // get current epoch start
        uint256 currentEpochStart = EpochMath.getCurrentEpochStart();

        // check: expiry is at least 2 Epochs from current epoch start [lock lasts for current epoch and expires at the end of the next epoch]
        require(expiry >= currentEpochStart + (2 * EpochMath.EPOCH_DURATION), Errors.LockExpiresTooSoon());

        return currentEpochStart;
    }


//-------------------------------internal: lib-----------------------------------------------------
   
    /**
     * @notice Removes expired locks from a veBalance.
     * @dev Overflow is only possible if 100% of MOCA is locked at the same expiry, which is infeasible in practice.
     *      No SafeCast required as only previously added values are subtracted; 8.89B MOCA supply ensures overflow is impossible.
     *      Does not update global parameter: lastUpdatedAt.
     * @param a The veBalance to update.
     * @param expiringSlope The slope value expiring at the given expiry.
     * @param expiry The timestamp at which the slope expires.
     * @return The updated veBalance with expired values removed.
     */
    function _subtractExpired(DataTypes.VeBalance memory a, uint256 expiringSlope, uint256 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint256 biasReduction = expiringSlope * expiry;

        // defensive: to prevent underflow [should not be possible in practice]
        a.bias = a.bias > biasReduction ? a.bias - uint128(biasReduction) : 0;      // remove decayed ve
        a.slope = a.slope > expiringSlope ? a.slope - uint128(expiringSlope) : 0; // remove expiring slopes
        return a;
    }

    // calc. veBalance{bias,slope} from lock; based on expiry time | inception offset is handled by balanceOf() queries
    function _convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;

        veBalance.slope = (lock.moca + lock.esMoca) / uint128(EpochMath.MAX_LOCK_DURATION);
        veBalance.bias = veBalance.slope * lock.expiry;

        return veBalance;
    }

    
    function _pushCheckpoint(DataTypes.Checkpoint[] storage lockHistory_, DataTypes.VeBalance memory veBalance, uint128 currentEpochStart) internal {
        uint256 length = lockHistory_.length;

        // if last checkpoint is in the same epoch as incoming; overwrite
        if(length > 0 && lockHistory_[length - 1].lastUpdatedAt == currentEpochStart) {
            lockHistory_[length - 1].veBalance = veBalance;
        } else {
            // new checkpoint for new epoch: set lastUpdatedAt to currentEpochStart
            lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
        }
    }




    // subtracts b from a: a - b
    function _sub(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory res;
            res.bias = a.bias - b.bias;
            res.slope = a.slope - b.slope;

        return res;
    }

    function _add(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory res;
            res.bias = a.bias + b.bias;
            res.slope = a.slope + b.slope;

        return res;
    }

    // time is timestamp, not duration
    function _getValueAt(DataTypes.VeBalance memory a, uint256 timestamp) internal pure returns (uint256) {
        uint256 decay = a.slope * timestamp;

        if(a.bias <= decay) return 0;

        // offset inception inflation
        return a.bias - decay;
    }

//-------------------------------internal: view functions-----------------------------------------------------


    function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint256 lastUpdatedAt, uint256 currentEpochStart) internal view returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current epoch 
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // skip first time: no prior updates needed | set lastUpdatedAt | return
        if(lastUpdatedAt == 0) {
            return veGlobal_;
        }

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch
            lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
        }

        return (veGlobal_);
    }

    function _viewUserAndGlobal(address user, uint256 currentEpochStart) internal view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint256 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init user veUser
        DataTypes.VeBalance memory veUser_;

        // get user's lastUpdatedTimestamp [either matches global or lags behind it]
        uint256 userLastUpdatedAt = userLastUpdatedTimestamp[user];
        

        // user's first time: no prior updates to execute 
        if (userLastUpdatedAt == 0) {

            // view global: may or may not have updates
            veGlobal_ = _viewGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veUser_);
        }
                
        // get user's previous veBalance: if both global and user are up to date, return
        veUser_ = userHistory[user][userLastUpdatedAt];
        if(userLastUpdatedAt >= currentEpochStart) return (veGlobal_, veUser_); 

        // update both global and user veBalance to current epoch
        while (userLastUpdatedAt < currentEpochStart) {

            // advance 1 epoch
            userLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // view global: if needed 
            if(lastUpdatedTimestamp_ < userLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[userLastUpdatedAt], userLastUpdatedAt);
            }

            // view user: apply scheduled slope reductions and decrement bias for expiring locks
            veUser_ = _subtractExpired(veUser_, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
        }

        return (veGlobal_, veUser_);
    }

//-------------------------------External: View functions-----------------------------------------

    function totalSupplyAtTimestamp(uint256 timestamp) public view returns (uint256) {
        require(timestamp >= block.timestamp, Errors.InvalidTimestamp());

        // get target epoch start
        uint256 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, targetEpochStartTime);
        return _getValueAt(veGlobal_, timestamp);
    }


    // returns user's voting power at given timestamp [ignores freezing of voting power in an epoch]
    function balanceOfAt(address user, uint128 timestamp) public view returns (uint256) {
        require(user != address(0), Errors.InvalidAddress());
        require(timestamp >= block.timestamp, Errors.InvalidTimestamp());

        // get target epoch start
        uint256 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        (/*DataTypes.VeBalance memory veGlobal_*/, DataTypes.VeBalance memory veUser_) = _viewUserAndGlobal(user, targetEpochStartTime);
        if(veUser_.bias == 0) return 0; 

        // return user's voting power at given timestamp
        return _getValueAt(veUser_, timestamp);
    }

    // note: used by VotingController for vote()
    function balanceAtEpochEnd(address user, uint256 epoch) external view returns (uint256) {
        require(user != address(0), Errors.InvalidAddress());

        uint256 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
        require(epochStartTime >= EpochMath.getCurrentEpochStart(), Errors.InvalidTimestamp());  // New: restrict to current/future epochs

        (/*veGlobal_*/, DataTypes.VeBalance memory veUser_) = _viewUserAndGlobal(user, epochStartTime);
        if (veUser_.bias == 0) return 0;

        uint256 epochEndTime = epochStartTime + EpochMath.EPOCH_DURATION;
        return _getValueAt(veUser_, epochEndTime);
    }
}
