// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// OZ
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable, AccessControl} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// internal libraries
import {Constants} from "./libraries/Constants.sol";
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";

// 
import {VeMathLib} from "./libraries/VeMathLib.sol";
import {VeDelegationLib} from "./libraries/VeDelegationLib.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
    - Stake MOCA tokens to receive veMOCA (voting power)
    - Longer lock periods result in higher veMOCA allocation
    - veMOCA decays linearly over time, reducing voting power
    - Formula-based calculation determines veMOCA amount based on stake amount and duration
 */

contract VotingEscrowMoca is LowLevelWMoca, AccessControlEnumerable, Pausable {
    using SafeERC20 for IERC20;

    address public immutable WMOCA;
    IERC20 public immutable ESMOCA;
    
    address public VOTING_CONTROLLER; // mutable: can be set by VotingEscrowMocaAdmin

    // global principal amounts
    uint128 public TOTAL_LOCKED_MOCA;
    uint128 public TOTAL_LOCKED_ESMOCA;

    // global veBalance
    DataTypes.VeBalance public veGlobal;
    uint128 public lastUpdatedTimestamp;  

    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;    

    // risk
    uint256 public isFrozen;
    

//------------------------------- Mappings --------------------------------------------------------------

    // --------- Global state ---------
    // scheduled global slope changes
    mapping(uint128 eTime => uint128 slopeChange) public slopeChanges;
    // saving totalSupply checkpoint for each epoch
    mapping(uint128 eTime => uint128 totalSupply) public totalSupplyAt;


    // --------- Lock state ---------
    mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
    // Checkpoints are added upon every state transition; checkpoints timestamp will lie on epoch boundaries
    mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;

    // --------- User state [Aggregates user's veBalance & slope changes] ---------
    // user personal data: cannot use array as likely will get very large
    mapping(address user => mapping(uint128 eTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
    mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) public userSlopeChanges;
    mapping(address user => uint128 lastUpdatedTimestamp) public userLastUpdatedTimestamp;

    // ----- Delegation state [Aggregates delegate's veBalance & slope changes] -----
    mapping(address delegate => bool isRegistered) public isRegisteredDelegate;                             // called by VotingController to register a delegate
    mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) public delegateSlopeChanges;
    mapping(address delegate => mapping(uint128 eTime => DataTypes.VeBalance veBalance)) public delegateHistory; // aggregated delegate veBalance
    mapping(address delegate => uint128 lastUpdatedTimestamp) public delegateLastUpdatedTimestamp;

    // ----- Pending Delegation Queue [PEQ]: to apply to user & delegate aggregations when updating pending deltas -----
    mapping (address user => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) public userPendingDeltas;
    mapping (address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) public delegatePendingDeltas;
    // timestamps for the above mappings are based on userLastUpdatedTimestamp & delegateLastUpdatedTimestamp

    // ----- Aggregation of a specific user-delegate pair: for VotingController to determine users' share of rewards from delegates -----
    // delegatedAggregationHistory tracks how much veBalance a user has delegated out
    mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeBalance veBalance))) public delegatedAggregationHistory;   // user's aggregated delegated veBalance for a specific delegate
    mapping(address user => mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange))) public userDelegatedSlopeChanges;               // aggregated slope changes for user's delegated locks for a specific delegate
    mapping(address user => mapping(address delegate => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas))) public userPendingDeltasForDelegate;    // pending deltas for user's delegated locks for a specific delegate
    mapping(address user => mapping(address delegate => uint128 lastUpdatedTimestamp)) public userDelegatedPairLastUpdatedTimestamp;                    // last updated timestamp for user-delegate pair


    // ----- Delegate Actions Per Epoch -----
    mapping(bytes32 lockId => mapping(uint128 eTime => uint8 numOfDelegateActions)) public numOfDelegateActionsPerEpoch;

//------------------------------- Constructor -----------------------------------------------------------

    constructor(address wMoca_, address esMoca_, uint256 mocaTransferGasLimit,
        address globalAdmin, address votingEscrowMocaAdmin, address monitorAdmin, address cronJobAdmin, 
        address monitorBot, address emergencyExitHandler) {

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
        _setupRoles(globalAdmin, votingEscrowMocaAdmin, monitorAdmin, cronJobAdmin, monitorBot, emergencyExitHandler);
    }

    // cronJob is not setup here; as its preferably to not keep it persistent. I.e. add address to cronJob when needed; then revoke.
    function _setupRoles(
        address globalAdmin, address votingEscrowMocaAdmin, address monitorAdmin, address cronJobAdmin, 
        address monitorBot, address emergencyExitHandler) 
    internal {

        // sanity check: all addresses are not zero address
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(votingEscrowMocaAdmin != address(0), Errors.InvalidAddress());
        require(monitorAdmin != address(0), Errors.InvalidAddress());
        require(cronJobAdmin != address(0), Errors.InvalidAddress());
        require(monitorBot != address(0), Errors.InvalidAddress());
        require(emergencyExitHandler != address(0), Errors.InvalidAddress());

        // grant roles to addresses
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);    
        _grantRole(Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE, votingEscrowMocaAdmin);
        _grantRole(Constants.MONITOR_ADMIN_ROLE, monitorAdmin);
        _grantRole(Constants.CRON_JOB_ADMIN_ROLE, cronJobAdmin);
        _grantRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler);

        // there should at least 1 bot address for monitoring at deployment
        _grantRole(Constants.MONITOR_ROLE, monitorBot);

        // --------------- Set role admins ------------------------------
        // Operational role administrators managed by global admin
        _setRoleAdmin(Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(Constants.EMERGENCY_EXIT_HANDLER_ROLE, DEFAULT_ADMIN_ROLE);

        _setRoleAdmin(Constants.MONITOR_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(Constants.CRON_JOB_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        // High-frequency roles managed by their dedicated admins
        _setRoleAdmin(Constants.MONITOR_ROLE, Constants.MONITOR_ADMIN_ROLE);
        _setRoleAdmin(Constants.CRON_JOB_ROLE, Constants.CRON_JOB_ADMIN_ROLE);
    }

//------------------------------- User functions---------------------------------------------------------


    // lock created is booked to currentEpochStart
    function createLock(uint128 expiry, uint128 esMoca) external payable whenNotPaused returns (bytes32) {
        // Enforce minimum increment amount to avoid precision loss
        uint128 moca = uint128(msg.value);
        _minimumAmountCheck(moca, esMoca);

        // check: expiry is a valid epoch time [must end on an epoch boundary]
        require(EpochMath.isValidEpochTime(expiry), Errors.InvalidEpochTime());

        // check: lock will minimally exist for 3 epochs [current + 2 more epochs]
        uint128 currentEpochStart = VeMathLib.minimumDurationCheck(expiry);
        // check: lock duration is within allowed range [min check handled by _minimumDurationCheck]
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());

        // update user and global veBalance: [STORAGE: updates lastUpdatedTimestamp for: global, user, pending deltas]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(msg.sender, currentEpochStart, false);

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
            emit Events.LockCreated(lockId, msg.sender, newLock.moca, newLock.esMoca, newLock.expiry);

        // --------- Update global state: add veIncoming to veGlobal ---------
        
        veGlobal_ = _add(veGlobal_, veIncoming);
        veGlobal = veGlobal_;
        slopeChanges[newLock.expiry] += veIncoming.slope;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // --------- Update user state: add veIncoming to user ---------

        veUser_ = _add(veUser_, veIncoming);
        userHistory[msg.sender][currentEpochStart] = veUser_;
        userSlopeChanges[msg.sender][newLock.expiry] += veIncoming.slope;
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope);
    
        // --------- Handle asset booking & transfers ---------

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

        // sanity check: lock exists, user is the owner, lock is not expired
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());

        // check: lock has at least 3 epochs left before expiry [current + 2 more epochs]
        uint128 currentEpochStart = VeMathLib.minimumDurationCheck(oldLock.expiry);

        // Enforce minimum increment amount to avoid precision loss
        uint128 mocaToAdd = uint128(msg.value);
        _minimumAmountCheck(mocaToAdd, esMocaToAdd);

        // DELEGATED OR PERSONAL LOCK:
        bool isDelegated = oldLock.delegate != address(0);
        address account = isDelegated ? oldLock.delegate : msg.sender;

        // update account and global veBalance: [STORAGE: updates lastUpdatedTimestamp for global & account & pending deltas]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) = _updateAccountAndGlobalAndPendingDeltas(account, currentEpochStart, isDelegated);


        // ------ Handle lock state modifications -------

        // create new lock: update amounts
        DataTypes.Lock memory newLock = abi.decode(abi.encode(oldLock), (DataTypes.Lock));
            newLock.moca += mocaToAdd;
            newLock.esMoca += esMocaToAdd;

        // STORAGE: update global & update account into storage: veBalance & slopeChange
        // also handles user-delegate pair state: pending deltas & aggregated veBalance
        DataTypes.VeBalance memory newLockVeBalance = _modifyLock(veGlobal_, veAccount_, oldLock, newLock, currentEpochStart, account, isDelegated);


        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newLockVeBalance, uint128(currentEpochStart));

        // STORAGE: increment global TOTAL_LOCKED_MOCA
        if(mocaToAdd > 0) TOTAL_LOCKED_MOCA += mocaToAdd;

        // STORAGE: increment global TOTAL_LOCKED_ESMOCA & TRANSFER: esMoca to contract
        if(esMocaToAdd > 0) {
            TOTAL_LOCKED_ESMOCA += esMocaToAdd;
            ESMOCA.safeTransferFrom(msg.sender, address(this), esMocaToAdd);
        }

        // emit event
        emit Events.LockAmountIncreased(lockId, oldLock.owner, oldLock.delegate, mocaToAdd, esMocaToAdd);
    }

    // user to increase duration of lock
    function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external whenNotPaused {
        require(durationToIncrease > 0, Errors.InvalidLockDuration());

        DataTypes.Lock memory oldLock = locks[lockId];

        // sanity check: lock exists, user is the owner, lock is not expired
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());
        
        // check: lock has at least 3 epochs left before expiry [current + 2 more epochs]
        uint128 currentEpochStart = VeMathLib.minimumDurationCheck(oldLock.expiry);

        // check: new expiry is a valid epoch time & within allowed range
        uint128 newExpiry = oldLock.expiry + durationToIncrease;
        require(EpochMath.isValidEpochTime(newExpiry), Errors.InvalidEpochTime());
        require(newExpiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidExpiry());

        
        // DELEGATED OR PERSONAL LOCK:
        bool isDelegated = oldLock.delegate != address(0);
        address account = isDelegated ? oldLock.delegate : msg.sender;

        // update account and global veBalance: may or may not have updates [STORAGE: updates lastUpdatedTimestamp for global & account & pending deltas]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) = _updateAccountAndGlobalAndPendingDeltas(account, currentEpochStart, isDelegated);

        // ------ Handle lock state modifications -------

        // copy old lock: update duration
        DataTypes.Lock memory newLock = abi.decode(abi.encode(oldLock), (DataTypes.Lock));
            newLock.expiry = newExpiry;

        // STORAGE: update global + update account [veBalance & schedule slope change]
        DataTypes.VeBalance memory newLockVeBalance = _modifyLock(veGlobal_, veAccount_, oldLock, newLock, currentEpochStart, account, isDelegated);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newLockVeBalance, uint128(currentEpochStart));

        // emit event
        emit Events.LockDurationIncreased(lockId, oldLock.owner, oldLock.delegate, oldLock.expiry, newLock.expiry);
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
        // sanity check: lock must be expired 
        require(lock.expiry <= block.timestamp, Errors.InvalidExpiry());
        // sanity check: lock is not already unlocked
        require(lock.isUnlocked == false, Errors.InvalidLockState());

        // get current epoch start
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // if delegated: update and clear pending deltas for user-delegate pair [not mandatory; but kept for state hygiene]
       if(lock.delegate != address(0)) {
            // update delegate: lastUpdatedTimestamp & veBalance & slopeChange
            ( , DataTypes.VeBalance memory veDelegate_) = _updateAccountAndGlobalAndPendingDeltas(lock.delegate, currentEpochStart, true);
            // update user-delegate pair: lastUpdatedTimestamp & veBalance & slopeChange
            DataTypes.VeBalance memory veDelegatePair_ = _updatePendingForDelegatePair(msg.sender, lock.delegate, currentEpochStart);
            
            // emit events [veBalances and slopeChanges were booked in _updateAccountAndGlobalAndPendingDeltas & _updatePendingForDelegatePair]
            emit Events.DelegateUpdated(lock.delegate, veDelegate_.bias, veDelegate_.slope);           
            emit Events.DelegatedAggregationUpdated(msg.sender, lock.delegate, veDelegatePair_.bias, veDelegatePair_.slope);
       }

        // update user and global veBalance: [STORAGE: updates lastUpdatedTimestamp & veBalance & slopeChange]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(msg.sender, currentEpochStart, false);

        // STORAGE: update global veBalance 
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);
        emit Events.UserUpdated(msg.sender, veUser_.bias, veUser_.slope); // userHistory & slopeChanges were updated above


        // STORAGE: push final checkpoint into lock history
        _pushCheckpoint(lockHistory[lockId], _convertToVeBalance(lock), uint128(currentEpochStart)); 

        // STORAGE: decrement global totalLocked counters
        TOTAL_LOCKED_MOCA -= lock.moca;
        TOTAL_LOCKED_ESMOCA -= lock.esMoca;


        // cache principals + delete from lock
        uint128 cachedMoca = lock.moca;
        uint128 cachedEsMoca = lock.esMoca;
        delete lock.moca;
        delete lock.esMoca;

        // storage: update lock
        lock.isUnlocked = true;    
        locks[lockId] = lock;

        emit Events.LockUnlocked(lockId, lock.owner, cachedMoca, cachedEsMoca);

        // return principals to lock.owner
        if(cachedEsMoca > 0) ESMOCA.safeTransfer(lock.owner, cachedEsMoca);        
        if(cachedMoca > 0) _transferMocaAndWrapIfFailWithGasLimit(WMOCA, lock.owner, cachedMoca, MOCA_TRANSFER_GAS_LIMIT);
    }


//------------------------------- Delegation functions----------------------------------------------------

    function delegateLock(bytes32 lockId, address delegate) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, DataTypes.DelegationType.Delegate, delegate);

        VeDelegationLib.executeDelegateLock(
            lock, currentEpochStart, delegate, locks,
            userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges, 
            userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate
        );
    }

    function switchDelegate(bytes32 lockId, address newDelegate) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, DataTypes.DelegationType.Switch, newDelegate);


        VeDelegationLib.executeSwitchDelegateLock(
            lock, currentEpochStart, newDelegate, locks,
            delegateSlopeChanges, delegatePendingDeltas, 
            userDelegatedSlopeChanges, userPendingDeltasForDelegate
        );
    }

    function undelegateLock(bytes32 lockId) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, DataTypes.DelegationType.Undelegate, address(0));


        VeDelegationLib.executeUndelegateLock(
            lock, currentEpochStart, locks,
            userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges,
            userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate
        );
    }


    function _preDelegationChecksAndUpdates(bytes32 lockId, DataTypes.DelegationType action, address targetDelegate) internal returns (uint128, DataTypes.Lock memory){
        DataTypes.Lock memory lock = locks[lockId];
        
        // sanity check: caller must be the lock owner
        require(lock.owner == msg.sender, Errors.InvalidOwner());

        // get current and next epoch start
        uint128 currentEpochStart = VeMathLib.minimumDurationCheck(lock.expiry);

        // increment delegate action counter (reverts on 256th action via uint8 overflow)
        ++numOfDelegateActionsPerEpoch[lockId][currentEpochStart];

        // Validation per action type
        bool isDelegating = action == DataTypes.DelegationType.Delegate;
        bool isSwitching = action == DataTypes.DelegationType.Switch;

        // Current Delegation State: Delegate requires NOT delegated; Switch/Undelegate require IS delegated
        if (isDelegating) {
            require(lock.delegate == address(0), Errors.LockAlreadyDelegated());        // Delegate
        } else { 
            require(lock.delegate != address(0), Errors.LockNotDelegated());           // Switch or Undelegate
        }

        // Target validation (Delegate and Switch only)
        if (isDelegating || isSwitching) {
            require(targetDelegate != lock.owner, Errors.InvalidDelegate());
            require(isRegisteredDelegate[targetDelegate], Errors.DelegateNotRegistered());
            
            // switching check: new delegate must not be the same as the old delegate
            if (isSwitching) require(lock.delegate != targetDelegate, Errors.InvalidDelegate());
        }

        // ---- Unified account updates ----
        // determine accounts to update based on action type
        address userOrOldDelegate = isSwitching ? lock.delegate : lock.owner;
        address delegateToUpdate = isSwitching || isDelegating ? targetDelegate : lock.delegate; 
        bool updateAsDelegate = isSwitching; // Switch: update oldDelegate; Delegate/Undelegate: update user

        DataTypes.VeBalance memory veGlobal_;
        DataTypes.VeBalance memory veFirst_;
        DataTypes.VeBalance memory veSecond_;

        // Update first account (user or oldDelegate) + global [updateAsDelegate -> delegate(): false, switch(): true, undelegate(): false]
        (veGlobal_, veFirst_) = _updateAccountAndGlobalAndPendingDeltas(userOrOldDelegate, currentEpochStart, updateAsDelegate);

        // Update second account (delegate)
        (, veSecond_) = _updateAccountAndGlobalAndPendingDeltas(delegateToUpdate, currentEpochStart, true);


        // ---- Unified pair updates ----
        // First pair: user -> (Switch(): oldDelegate, Delegate(): targetDelegate, Undelegate(): delegate)
        address firstPairDelegate = isDelegating ? targetDelegate : lock.delegate;
        DataTypes.VeBalance memory vePairFirst_ = _updatePendingForDelegatePair(lock.owner, firstPairDelegate, currentEpochStart);

        // Second pair: only for Switch(): user -> targetDelegate
        DataTypes.VeBalance memory vePairSecond_;
        if (isSwitching) {
            vePairSecond_ = _updatePendingForDelegatePair(lock.owner, targetDelegate, currentEpochStart);
        }

        // ---- Storage: update veGlobal once ----
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // ---- Emit account events ----
        if (updateAsDelegate) {
            emit Events.DelegateUpdated(userOrOldDelegate, veFirst_.bias, veFirst_.slope);
        } else {
            emit Events.UserUpdated(userOrOldDelegate, veFirst_.bias, veFirst_.slope);
        }
        emit Events.DelegateUpdated(delegateToUpdate, veSecond_.bias, veSecond_.slope);

        // ---- Emit pair events ----
        emit Events.DelegatedAggregationUpdated(lock.owner, firstPairDelegate, vePairFirst_.bias, vePairFirst_.slope);
        if (isSwitching) {
            emit Events.DelegatedAggregationUpdated(lock.owner, targetDelegate, vePairSecond_.bias, vePairSecond_.slope);
        }

        return (currentEpochStart, lock);
    }


//------------------------------ CronJob: Update state functions ----------------------------------------

    /**
        Because state updates require iterating through every missed epoch,
        an account that has been inactive for a long period (e.g., several epochs) will require a transaction with a very high gas limit to update its state.
        
        To address this we have the helper functions below that will batch update stale accounts and user-delegate pairs to the current epoch.
     */


    /**
     * @notice Admin helper to batch update stale accounts to the current epoch.
     * @dev Fixes OOG risks by applying pending deltas and decay in a separate transaction.
     * @param accounts Array of addresses to update.
     * @param isDelegate True if updating delegate accounts, False for user accounts.
     */
    function updateAccountsAndPendingDeltas(address[] calldata accounts, bool isDelegate) external whenNotPaused onlyRole(Constants.CRON_JOB_ROLE){
        uint256 length = accounts.length;
        require(length > 0, Errors.InvalidArray());

        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // 1. Update Global State Explicitly (Once per batch)
        // This ensures veGlobal storage is current. Subsequent internal calls will skip global updates.
        DataTypes.VeBalance memory veGlobal_ = _updateGlobal(veGlobal, lastUpdatedTimestamp, currentEpochStart); 
        
        // STORAGE: update global veBalance
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);
  
        // 2. Iterate through accounts
        for(uint256 i; i < length; ++i) {
            address account = accounts[i];
            if (account == address(0)) continue;

            // Call internal update function. This function INTERNALLY writes to:
            // - accountHistoryMapping 
            // - accountLastUpdatedMapping 
            // - accountPendingDeltas 
            (, DataTypes.VeBalance memory veAccount_) = _updateAccountAndGlobalAndPendingDeltas(account, currentEpochStart, isDelegate);
            
            // No need to write veUser/veDelegate back to storage here; the internal function has already checkpointed the result to history
            if(isDelegate) emit Events.DelegateUpdated(account, veAccount_.bias, veAccount_.slope);
            else emit Events.UserUpdated(account, veAccount_.bias, veAccount_.slope);
        }
    }

    /**
     * @notice Admin helper to batch update stale User-Delegate pairs to the current epoch.
     * @dev Essential for delegates claiming fees if the pair interaction is stale.
     * @param users Array of user addresses.
     * @param delegates Array of delegate addresses corresponding to the users.
     */
    function updateDelegatePairs(address[] calldata users, address[] calldata delegates) external whenNotPaused onlyRole(Constants.CRON_JOB_ROLE){
        uint256 length = users.length;
        require(length > 0, Errors.InvalidArray());
        require(length == delegates.length, Errors.MismatchedArrayLengths());

        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // 1. Update Global State Explicitly (Once per batch)
        // This ensures veGlobal storage is current. Subsequent internal calls will skip global updates.
        DataTypes.VeBalance memory veGlobal_ = _updateGlobal(veGlobal, lastUpdatedTimestamp, currentEpochStart); 
        
        // STORAGE: update global veBalance
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // 2. Iterate through user-delegate pairs
        for(uint256 i; i < length; ++i) {
            address user = users[i];
            address delegate = delegates[i];
            
            if (user == address(0) || delegate == address(0)) continue;

            // Update user-delegate pair state & Clear pending deltas. Internal function writes to:
            // - userDelegatedPairLastUpdatedTimestamp 
            // - userPendingDeltasForDelegate (Deletes) 
            DataTypes.VeBalance memory veDelegatePair_ = _updatePendingForDelegatePair(user, delegate, currentEpochStart);
            
            // No need to write veDelegatePair back to storage here; the internal function has already checkpointed the result to delegatedAggregationHistory
            emit Events.DelegatedAggregationUpdated(user, delegate, veDelegatePair_.bias, veDelegatePair_.slope);
        }
    }


//------------------------------ CronJob: createLockFor()------------------------------------------------

    /** consider:

        Doing msg.value validation earlier, in a separate loop, like so:

        for(uint256 i = 0; i < length; i++) {
            totalMocaRequired += mocaAmounts[i];
            totalEsMocaRequired += esMocaAmounts[i];
        }
        require(msg.value == totalMocaRequired, Errors.InvalidAmount());
    
        reverts early, but at the cost of double for loops.
     */

    function createLockFor(address[] calldata users, uint128[] calldata esMocaAmounts, uint128[] calldata mocaAmounts, uint128 expiry) 
        external payable onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused returns (bytes32[] memory) { 

        // array validation
        uint256 length = users.length;
        require(length > 0, Errors.InvalidArray());
        require(length == esMocaAmounts.length, Errors.MismatchedArrayLengths());
        require(length == mocaAmounts.length, Errors.MismatchedArrayLengths());


        // expiry validation: expiry is a valid epoch time [must end on an epoch boundary] 
        require(EpochMath.isValidEpochTime(expiry), Errors.InvalidEpochTime());

        // check: lock will minimally exist for 3 epochs [current + 2 more epochs]
        uint128 currentEpochStart = VeMathLib.minimumDurationCheck(expiry);
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());

        // update global veBalance
        DataTypes.VeBalance memory veGlobal_ = _updateGlobal(veGlobal, lastUpdatedTimestamp, currentEpochStart);


        // Create locks and aggregate results
        (bytes32[] memory lockIds, uint128 totalMoca, uint128 totalEsMoca, uint128 totalSlopeChanges, DataTypes.VeBalance memory updatedVeGlobal_) 
            = _createLocksBatch(users, mocaAmounts, esMocaAmounts, expiry, currentEpochStart, veGlobal_);
        
        // check: msg.value matches totalMoca
        require(msg.value == totalMoca, Errors.InvalidAmount());

        // STORAGE: update global veBalance after all locks
        veGlobal = updatedVeGlobal_;
        slopeChanges[expiry] += totalSlopeChanges;
        emit Events.GlobalUpdated(updatedVeGlobal_.bias, updatedVeGlobal_.slope);

        // Update Global asset counters + esMoca transfer
        TOTAL_LOCKED_MOCA += totalMoca;
        if(totalEsMoca > 0) {
            TOTAL_LOCKED_ESMOCA += totalEsMoca;
            ESMOCA.safeTransferFrom(msg.sender, address(this), totalEsMoca);
        }

        // emit events
        emit Events.LocksCreatedFor(users, lockIds, totalMoca, totalEsMoca);
        return lockIds;
    }


    function _createLocksBatch(
        address[] memory users,
        uint128[] memory mocaAmounts,
        uint128[] memory esMocaAmounts,
        uint128 expiry,
        uint128 currentEpochStart,
        DataTypes.VeBalance memory veGlobal_
    ) internal returns (bytes32[] memory, uint128, uint128, uint128, DataTypes.VeBalance memory) {
       
        // counters: track totals
        uint128 totalEsMoca;
        uint128 totalMoca;
        uint128 totalSlopeChanges;

        // to store lockIds
        uint256 length = users.length;
        bytes32[] memory lockIds = new bytes32[](length);

        // loop through users, create locks, aggregate global stats, accumulate totals
        for(uint256 i; i < length; ++i) {
          
            DataTypes.VeBalance memory veIncoming_;
            (lockIds[i], veIncoming_) = _createSingleLock(users[i], mocaAmounts[i], esMocaAmounts[i], expiry, currentEpochStart);

            // Aggregate Global Stats in memory
            veGlobal_ = _add(veGlobal_, veIncoming_);
            totalSlopeChanges += veIncoming_.slope;
            
            // accumulate totals: for verification
            totalMoca += mocaAmounts[i];
            totalEsMoca += esMocaAmounts[i];
        }
        
        return (lockIds, totalMoca, totalEsMoca, totalSlopeChanges, veGlobal_);
    }
    
    function _createSingleLock(address user, uint128 moca, uint128 esMoca, uint128 expiry, uint128 currentEpochStart) internal returns (bytes32, DataTypes.VeBalance memory) {
        // check: not zero address
        require(user != address(0), Errors.InvalidAddress());

        // check: minimum amount
        _minimumAmountCheck(moca, esMoca);

        // update user veBalance: [STORAGE: updates userLastUpdatedTimestamp]
        (, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(user, currentEpochStart, false);

        // Generate Lock ID
        bytes32 lockId;
        {
            uint256 salt = block.number;
            lockId = _generateVaultId(salt, user);
            while (locks[lockId].lockId != bytes32(0)) lockId = _generateVaultId(++salt, user);      // If lockId exists, generate new random Id
        }

        // Create Lock
        DataTypes.Lock memory newLock;
        newLock.lockId = lockId;
        newLock.owner = user;
        newLock.moca = moca;
        newLock.esMoca = esMoca;
        newLock.expiry = expiry;

        // Convert Lock to veBalance
        DataTypes.VeBalance memory veIncoming_ = _convertToVeBalance(newLock);

        // STORAGE: book lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], veIncoming_, uint128(currentEpochStart));
    
        emit Events.LockCreated(lockId, user, newLock.moca, newLock.esMoca, newLock.expiry);

        // Update User State: add veIncoming to user
        veUser_ = _add(veUser_, veIncoming_);
        
        // Write final user state
        userHistory[user][currentEpochStart] = veUser_;
        userSlopeChanges[user][newLock.expiry] += veIncoming_.slope;
        emit Events.UserUpdated(user, veUser_.bias, veUser_.slope);

        return (lockId, veIncoming_);
    }

//------------------------------ Admin function: setMocaTransferGasLimit() ------------------------------

    /**
        * @notice Sets the gas limit for moca transfer.
        * @dev Only callable by the VotingEscrowMocaAdmin.
        * @param newMocaTransferGasLimit The new gas limit for moca transfer.
        */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyRole(Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE) whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }

    function setVotingController(address newVotingController) external onlyRole(Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE) {
        require(newVotingController != address(0), Errors.InvalidAddress());
        require(VOTING_CONTROLLER != newVotingController, Errors.InvalidAddress());
        
        VOTING_CONTROLLER = newVotingController;
        emit Events.VotingControllerUpdated(newVotingController);
    }

//------------------------------ VotingController.sol functions------------------------------------------
    
    // note combine to 1 -> update Voting Controller

    // require(delegate != address(0) not needed since external contract call
    // registration status is already checked in VotingController.sol
    function delegateRegistrationStatus(address delegate, bool toRegister) external whenNotPaused {
        require(msg.sender == VOTING_CONTROLLER, Errors.OnlyCallableByVotingControllerContract());

        isRegisteredDelegate[delegate] = toRegister;

        emit Events.DelegateRegistrationStatusUpdated(delegate, toRegister);
    }

//------------------------------ Internal: update functions----------------------------------------------


    // does not update veGlobal. updates lastUpdatedTimestamp, totalSupplyAt[]
    function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current epoch [already up to date]
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // 1st call: no prior updates [global lastUpdatedTimestamp is set to currentEpochStart]
        if(lastUpdatedAt == 0) {
            lastUpdatedTimestamp = currentEpochStart;   // move forward the anchor point to skip empty epochs
            return veGlobal_;
        }

        // cache epoch duration
        uint128 epochDuration = EpochMath.EPOCH_DURATION;

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {lastUpdatedAt += epochDuration;}                  

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
    function _updateAccountAndGlobalAndPendingDeltas(address account, uint128 currentEpochStart, bool isDelegate) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address account => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage accountPendingDeltas,
            mapping(address account => uint128 lastUpdatedTimestamp) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegatePendingDeltas, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userPendingDeltas, userLastUpdatedTimestamp);

        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init account veAccount
        DataTypes.VeBalance memory veAccount_;

        // get account's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];
        
        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // set account's lastUpdatedTimestamp
            accountLastUpdatedMapping[account] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 

        // cache epoch duration
        uint128 epochDuration = EpochMath.EPOCH_DURATION;

        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {accountLastUpdatedAt += epochDuration;}

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = _subtractExpired(veAccount_, accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

    
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];

            // apply the pending delta to the veAccount [add then sub]
            if(deltaPtr.hasAddition) veAccount_ = _add(veAccount_, deltaPtr.additions);
            if(deltaPtr.hasSubtraction) veAccount_ = _sub(veAccount_, deltaPtr.subtractions);

            // book account checkpoint 
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount_;

            // clean up after applying
            delete accountPendingDeltas[account][accountLastUpdatedAt];
        }

        // set final lastUpdatedTimestamp: for global & account
        lastUpdatedTimestamp = accountLastUpdatedMapping[account] = accountLastUpdatedAt;

        return (veGlobal_, veAccount_);
    }

    function _updatePendingForDelegatePair(address user, address delegate, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {
        uint128 pairLastUpdatedAt = userDelegatedPairLastUpdatedTimestamp[user][delegate];

        // init user veUser
        DataTypes.VeBalance memory vePair_;

        // if the pair has never been updated, return the initial aggregated veBalance
        if(pairLastUpdatedAt == 0) {
            // update the last updated timestamp
            userDelegatedPairLastUpdatedTimestamp[user][delegate] = currentEpochStart;
            return vePair_;
        }

        // copy the previous aggregated veBalance to mem [if the pair is already up to date, return]
        vePair_ = delegatedAggregationHistory[user][delegate][pairLastUpdatedAt];
        if(pairLastUpdatedAt == currentEpochStart) return vePair_; 

        // update pair's aggregated veBalance to current epoch start
        while(pairLastUpdatedAt < currentEpochStart) {

            // advance to next epoch
            pairLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // apply decay to the aggregated veBalance
            vePair_ = _subtractExpired(vePair_, userDelegatedSlopeChanges[user][delegate][pairLastUpdatedAt], pairLastUpdatedAt);
            
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
            
            // apply the pending deltas to the vePair [add then sub]
            if (deltaPtr.hasAddition) vePair_ = _add(vePair_, deltaPtr.additions);
            if (deltaPtr.hasSubtraction) vePair_ = _sub(vePair_, deltaPtr.subtractions);

            // STORAGE: book veBalance for epoch 
            delegatedAggregationHistory[user][delegate][pairLastUpdatedAt] = vePair_;

            // clean up after applying
            delete userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
        }

        // update the last updated timestamp
        userDelegatedPairLastUpdatedTimestamp[user][delegate] = pairLastUpdatedAt;

        return vePair_;
    }


    /**
     * @dev Internal function to handle lock modifications (amount or duration changes)
     * @param veGlobal_ Current global veBalance (already updated to currentEpochStart)
     * @param veAccount_ Current account veBalance (already updated to currentEpochStart)
     * @param oldLock The lock before modification
     * @param newLock The lock after modification
     * @param currentEpochStart The current epoch start timestamp
     * @param account The account address
     * @param isDelegate Whether the account is a delegate
     * @return newVeBalance The new veBalance calculated from newLock
     */
    function _modifyLock(
        DataTypes.VeBalance memory veGlobal_,
        DataTypes.VeBalance memory veAccount_,
        DataTypes.Lock memory oldLock,
        DataTypes.Lock memory newLock,
        uint128 currentEpochStart,
        address account,
        bool isDelegate
    ) internal returns (DataTypes.VeBalance memory) {
        
        // convert old and new lock to veBalance
        DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(oldLock);
        DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(newLock);

        // get delta btw veBalance of old and new lock
        DataTypes.VeBalance memory increaseInVeBalance = _sub(newVeBalance, oldVeBalance);

        // STORAGE: update global veBalance
        veGlobal_ = _add(veGlobal_, increaseInVeBalance);
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);


        // get mappings
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping
        ) = isDelegate ? (delegateHistory, delegateSlopeChanges) : (userHistory, userSlopeChanges);


        // STORAGE: update account veBalance
        veAccount_ = _add(veAccount_, increaseInVeBalance);
        accountHistoryMapping[account][currentEpochStart] = veAccount_;
        if(isDelegate) emit Events.DelegateUpdated(account, veAccount_.bias, veAccount_.slope);
        else emit Events.UserUpdated(account, veAccount_.bias, veAccount_.slope);



        // ---- Handle slopeChanges: global & account ----
        if(newLock.expiry != oldLock.expiry) {
            // SCENARIO: increaseDuration() - expiry changed

            // global slope changes
            slopeChanges[oldLock.expiry] -= oldVeBalance.slope;
            slopeChanges[newLock.expiry] += newVeBalance.slope;
            
            // account slope changes
            accountSlopeChangesMapping[account][oldLock.expiry] -= oldVeBalance.slope;
            accountSlopeChangesMapping[account][newLock.expiry] += newVeBalance.slope;

        } else {
            // SCENARIO: increaseAmount() - only amounts changed [expiry unchanged]
            
            // only need to increment slopeChanges at current expiry: global & account
            slopeChanges[newLock.expiry] += increaseInVeBalance.slope;
            accountSlopeChangesMapping[account][newLock.expiry] += increaseInVeBalance.slope;
        }


        // ---- Handle user-delegate pair state: delegatedAggregationHistory & userDelegatedSlopeChanges ----
        if(isDelegate) {

            // process pending deltas for the owner-delegate pair, till current epoch
            DataTypes.VeBalance memory veDelegatePair_ = _updatePendingForDelegatePair(oldLock.owner, oldLock.delegate, currentEpochStart);

            // update delegatedAggregationHistory[veBalance of user-delegate pair]
            veDelegatePair_ = _add(veDelegatePair_, increaseInVeBalance);
            delegatedAggregationHistory[newLock.owner][newLock.delegate][currentEpochStart] = veDelegatePair_;
            emit Events.DelegatedAggregationUpdated(newLock.owner, newLock.delegate, veDelegatePair_.bias, veDelegatePair_.slope);

            // update userDelegatedSlopeChanges depending on the scenario: increaseDuration or increaseAmount
            if(newLock.expiry != oldLock.expiry) {

                // SCENARIO: increaseDuration()
                userDelegatedSlopeChanges[oldLock.owner][oldLock.delegate][oldLock.expiry] -= oldVeBalance.slope;
                userDelegatedSlopeChanges[newLock.owner][newLock.delegate][newLock.expiry] += newVeBalance.slope;
            } else {

                // SCENARIO: increaseAmount()
                userDelegatedSlopeChanges[newLock.owner][newLock.delegate][newLock.expiry] += increaseInVeBalance.slope;
            }
        }

        return newVeBalance;
    }

 

//------------------------------ Internal: helper functions----------------------------------------------

    ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }

    function _minimumAmountCheck(uint128 moca, uint128 esMoca) internal pure {
        uint128 totalAmount = moca + esMoca;
        require(totalAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());
    }
    
//------------------------------ Internal: lib-----------------------------------------------------------   
    /** note: for _subtractExpired(), _convertToVeBalance(), _getValueAt()

        On bias & slope calculations, we can use uint128 for all calculations.

        Overflow is mathematically impossible given:
        - Total MOCA supply: 8.89 billion tokens
        - Maximum lock duration: 728 days
        - Reasonable timestamp ranges (through year 2300)

        So if someone locks the entire Moca supply for 728 days [MAX_LOCK_DURATION]:
        - slope = totalAmount / MAX_LOCK_DURATION
        - slope = (8.89 × 10^27) / (62,899,200)
        - slope ≈ 1.413 × 10^20 wei/second
        
        bias = slope × expiry:
        - bias = (1.413 × 10^20) × (4.1 × 10^9)
        - bias ≈ 5.79 × 10^29 wei

        uint128.max = 2^128 - 1 ≈ 3.402 × 10^38 wei
        - Safety Margin = uint128.max / bias
        - Safety Margin = (3.402 × 10^38) / (5.79 × 10^29)
        - Safety Margin ≈ 587 million times

        When would overflow actually occur?
        - Only if someone could lock 587 million times the entire circulating supply in a single lock, which is:
        - Economically impossible (tokens don't exist)
    */

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
    function _subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint128 biasReduction = expiringSlope * expiry;

        // defensive: to prevent underflow [should not be possible in practice]
        a.bias = a.bias > biasReduction ? a.bias - biasReduction : 0;      // remove decayed ve
        a.slope = a.slope > expiringSlope ? a.slope - expiringSlope : 0; // remove expiring slopes
        return a;
    }

    // calc. veBalance{bias,slope} from lock; based on expiry time | inception offset is handled by balanceOf() queries
    function _convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;

        // In practice, this should never overflow given MOCA supply constraints
        veBalance.slope = (lock.moca + lock.esMoca) / EpochMath.MAX_LOCK_DURATION;
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
    function _getValueAt(DataTypes.VeBalance memory a, uint128 timestamp) internal pure returns (uint128) {
        uint128 decay = a.slope * timestamp;

        if(a.bias <= decay) return 0;

        // offset inception inflation
        return a.bias - decay;
    }

//------------------------------ Internal: view functions------------------------------------------------
    // needed for totalSupplyAtTimestamp() & _viewAccountAndGlobalAndPendingDeltas
    function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal view returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current epoch 
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // skip first time: no prior updates needed | set lastUpdatedAt | return
        if(lastUpdatedAt == 0) {
            return veGlobal_;
        }

        // cache epoch duration
        uint128 epochDuration = EpochMath.EPOCH_DURATION;

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {lastUpdatedAt += epochDuration;}                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
        }

        return (veGlobal_);
    }

    function _viewAccountAndGlobalAndPendingDeltas(address account, uint128 currentEpochStart, bool isDelegate) internal view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address account => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage accountPendingDeltas,
            mapping(address account => uint128 lastUpdatedTimestamp) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegatePendingDeltas, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userPendingDeltas, userLastUpdatedTimestamp);

        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init account veAccount
        DataTypes.VeBalance memory veAccount_;

        // get account's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];

        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // view global: does not update storage
            veGlobal_ = _viewGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 

        // cache epoch duration
        uint128 epochDuration = EpochMath.EPOCH_DURATION;

        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {accountLastUpdatedAt += epochDuration;}

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                //totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = _subtractExpired(veAccount_, accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];
           
            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;

            // apply the pending delta to the veAccount [add then sub]
            if(hasAddition) veAccount_ = _add(veAccount_, deltaPtr.additions);
            if(hasSubtraction) veAccount_ = _sub(veAccount_, deltaPtr.subtractions);
        }

        return (veGlobal_, veAccount_);
    }

//------------------------------ Risk management---------------------------------------------------------

    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external whenNotPaused onlyRole(Constants.MONITOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isFrozen == 0, Errors.IsFrozen());

        isFrozen = 1;
        emit Events.ContractFrozen();
    }  

    /**
     * @notice Returns principal assets (esMoca, Moca) to users for specified locks 
     * @dev Only callable by the Emergency Exit Handler when the contract is frozen.
     *      Ignores all contract state updates except returning assets; assumes system failure.
     *      NOTE: Expectation is that VotingController is paused or undergoing emergencyExit(), to prevent phantom votes.
     *            Phantom votes since we do not update state when returning assets; too complicated and not worth the effort.
     * @param lockIds Array of lock IDs for which assets should be returned.    
     * @return totalLocksProcessed The number of locks processed.
     * @return totalMocaReturned The total amount of Moca returned.
     * @return totalEsMocaReturned The total amount of esMoca returned.
     */
    function emergencyExit(bytes32[] calldata lockIds) external onlyRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE) returns(uint256, uint256, uint256) {
        require(isFrozen == 1, Errors.NotFrozen());
        require(lockIds.length > 0, Errors.InvalidArray());

        // Track totals for single event emission
        uint128 totalMocaReturned;
        uint128 totalEsMocaReturned;
        uint128 totalLocksProcessed;

        // get user's veBalance for each lock
        for(uint256 i; i < lockIds.length; ++i) {
            DataTypes.Lock storage lockPtr = locks[lockIds[i]];
            
            // Skip invalid/already processed locks
            if(lockPtr.owner == address(0) || lockPtr.isUnlocked) continue;        

            // mark unlocked: principals to be returned
            lockPtr.isUnlocked = true;
            
            // direct storage updates - only write changed fields
            if(lockPtr.esMoca > 0) {
                
                uint128 esMocaToReturn = lockPtr.esMoca;
                delete lockPtr.esMoca;
                TOTAL_LOCKED_ESMOCA -= esMocaToReturn;
                
                // increment counter
                totalEsMocaReturned += esMocaToReturn;

                ESMOCA.safeTransfer(lockPtr.owner, esMocaToReturn);
            }

            if(lockPtr.moca > 0) {

                uint128 mocaToReturn = lockPtr.moca;
                delete lockPtr.moca;
                TOTAL_LOCKED_MOCA -= mocaToReturn;  

                // increment counter
                totalMocaReturned += mocaToReturn;

                // transfer moca [wraps if transfer fails within gas limit]
                _transferMocaAndWrapIfFailWithGasLimit(WMOCA, lockPtr.owner, mocaToReturn, MOCA_TRANSFER_GAS_LIMIT);
            }

            ++totalLocksProcessed;
        }

        if(totalLocksProcessed > 0) emit Events.EmergencyExit(lockIds, totalLocksProcessed, totalMocaReturned, totalEsMocaReturned);

        return (totalLocksProcessed, totalMocaReturned, totalEsMocaReturned);
    }
    
//------------------------------ View functions----------------------------------------------------------

    // can be for past or future queries 
    function totalSupplyAtTimestamp(uint128 timestamp) public view returns (uint128) {

        // get target epoch start
        uint128 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, targetEpochStartTime);
        return _getValueAt(veGlobal_, timestamp);
    }

    // returns either a user's personal voting power, or voting power that was delegated to him, at given timestamp 
    function balanceOfAt(address user, uint128 timestamp, bool isDelegate) public view returns (uint128) {
        require(user != address(0), Errors.InvalidAddress());
        require(timestamp <= block.timestamp, Errors.InvalidTimestamp());   // cannot query the future

        // get target epoch start
        uint128 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        (/*DataTypes.VeBalance memory veGlobal_*/, DataTypes.VeBalance memory veAccount_) = _viewAccountAndGlobalAndPendingDeltas(user, targetEpochStartTime, isDelegate);
        if(veAccount_.bias == 0) return 0; 

        // return user's voting power at given timestamp
        return _getValueAt(veAccount_, timestamp);
    }

    // ----------------------------- Lock View Functions -----------------------------------------------

    /**
     * @notice Returns the number of checkpoints in the lock's history.
     * @param lockId The ID of the lock whose history length is being queried.
     * @return The number of checkpoints in the lock's history.
     */
    function getLockHistoryLength(bytes32 lockId) external view returns (uint256) {
        return lockHistory[lockId].length;
    }

    /**
     * @notice Returns the current veBalance of a lock.
     * @dev Converts the lock's principal amounts to veBalance using _convertToVeBalance.
     * @param lockId The ID of the lock whose veBalance is being queried.
     * @return The current veBalance of the lock as a DataTypes.VeBalance struct.
     */
    function getLockVeBalance(bytes32 lockId) external view returns (DataTypes.VeBalance memory) {
        return _convertToVeBalance(locks[lockId]);
    }

    function getLockVotingPowerAt(bytes32 lockId, uint128 timestamp) external view returns (uint128) {
        DataTypes.Lock memory lockPtr = locks[lockId];
        if(lockPtr.expiry <= timestamp) return 0;

        return _getValueAt(_convertToVeBalance(lockPtr), timestamp);
    }


    // ----------------------------- Voting Controller Queries -----------------------------------------------


    // note: used by VotingController for vote()
    function balanceAtEpochEnd(address user, uint128 epoch, bool isDelegate) external view returns (uint128) {
        require(user != address(0), Errors.InvalidAddress());

        // restrict to current/past epochs | can be used by VotingController and for other general queries
        uint128 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
        require(epochStartTime <= EpochMath.getCurrentEpochStart(), Errors.InvalidTimestamp());  

        (/*veGlobal_*/, DataTypes.VeBalance memory veAccount_) = _viewAccountAndGlobalAndPendingDeltas(user, epochStartTime, isDelegate);
        if(veAccount_.bias == 0) return 0;

        // return user's voting power at the end of the epoch
        uint128 epochEndTime = epochStartTime + EpochMath.EPOCH_DURATION;
        return _getValueAt(veAccount_, epochEndTime);
    }

    //Note: used by VotingController.claimRewardsFromDelegate() | returns userVotesAllocatedToDelegateForEpoch
    function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint128 epoch) external view returns (uint128) {
        require(user != address(0), Errors.InvalidAddress());
        require(delegate != address(0), Errors.InvalidAddress());
        //require(isFrozen == 0, Errors.IsFrozen());   

        // 1. Determine time boundaries for the requested epoch
        uint128 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
        uint128 epochEndTime = epochStartTime + EpochMath.EPOCH_DURATION;
        
        // 2. Retrieve the timestamp of the last state update for this specific user-delegate pair
        uint128 lastUpdate = userDelegatedPairLastUpdatedTimestamp[user][delegate];

        // 3. If there is no history of interaction, the balance is 0
        if (lastUpdate == 0) return 0;

        // 4. Load baseline state from history
        DataTypes.VeBalance memory veBalance = delegatedAggregationHistory[user][delegate][lastUpdate]; // 

        // 5. If data is already up to date (lastUpdate >= epochStartTime), simply calculate value at epochEndTime. 
        if (lastUpdate >= epochStartTime) return _getValueAt(veBalance, epochEndTime);

        
        // 6. Simulate the state forward from the last update to the start of the requested epoch
        // This accounts for linear decay, slope changes, and pending deltas (additions/subtractions)
        // Logic mirrors _viewAccountAndGlobalAndPendingDeltas
        while (lastUpdate < epochStartTime) {

            // advance to the next epoch
            lastUpdate += EpochMath.EPOCH_DURATION;

            // Apply decay and slope changes scheduled for this epoch
            veBalance = _subtractExpired(veBalance, userDelegatedSlopeChanges[user][delegate][lastUpdate], lastUpdate);

            // Apply any pending deltas (delegations/undelegations) that were queued for this epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][lastUpdate];

            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;
            
            // apply the pending delta to the veBalance [add then sub]
            if(hasAddition) veBalance = _add(veBalance, deltaPtr.additions);
            if(hasSubtraction) veBalance = _sub(veBalance, deltaPtr.subtractions);
        }

        // if 0 bias, return 0
        if(veBalance.bias == 0) return 0;

        // return the calculated voting power at the exact end of the epoch
        return _getValueAt(veBalance, epochEndTime);
    }

}