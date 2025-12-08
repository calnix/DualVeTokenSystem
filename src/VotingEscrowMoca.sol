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

// logic libraries
import {VeMathLib} from "./libraries/VeMathLib.sol";
import {VeDelegationLib} from "./libraries/VeDelegationLib.sol";
import {VeViewLib} from "./libraries/VeViewLib.sol";

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
    using VeMathLib for DataTypes.VeBalance;
    using VeMathLib for DataTypes.Lock;
    using VeViewLib for DataTypes.VeBalance;

    IERC20 public immutable ESMOCA;
    address public immutable WMOCA;
    
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

        // wrapped moca & roles: sanity check all addresses are not zero address
        require(wMoca_ != address(0), Errors.InvalidAddress());
        require(esMoca_ != address(0), Errors.InvalidAddress());
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(votingEscrowMocaAdmin != address(0), Errors.InvalidAddress());
        require(monitorAdmin != address(0), Errors.InvalidAddress());
        require(cronJobAdmin != address(0), Errors.InvalidAddress());
        require(monitorBot != address(0), Errors.InvalidAddress());
        require(emergencyExitHandler != address(0), Errors.InvalidAddress());

        // wrapped moca & esMoca
        WMOCA = wMoca_;
        ESMOCA = IERC20(esMoca_);

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;    

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
        uint128 currentEpochStart = _minimumDurationCheck(expiry);
        // check: lock duration is within allowed range [min check handled by _minimumDurationCheck]
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());

        // 1. Create Lock (reuse internal logic)
        // - Handles amount validation
        // - Generates Lock ID
        // - Updates User state (history, slopes) & emits UserUpdated
        // - Updates Global timestamp (via internal _updateAccountAndGlobalAndPendingDeltas)
        (bytes32 lockId, DataTypes.VeBalance memory veIncoming) = _createSingleLock(msg.sender, moca, esMoca, expiry, currentEpochStart);


        // --------- Update global state & schedule slopes ---------

        // Retrieve current global state (guaranteed up-to-date by _createSingleLock)
        DataTypes.VeBalance memory veGlobal_ = veGlobal;

        veGlobal_ = veGlobal_.add(veIncoming);
        veGlobal = veGlobal_;
        slopeChanges[expiry] += veIncoming.slope;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);
    
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
        DataTypes.Lock storage oldLock = locks[lockId];
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());

        uint128 currentEpochStart = _minimumDurationCheck(oldLock.expiry);
        uint128 mocaToAdd = uint128(msg.value);
        _minimumAmountCheck(mocaToAdd, esMocaToAdd);

        // Resolve accounts
        (address currentAccount, address futureAccount, bool currentIsDelegate, bool futureIsDelegate)
            = _getCurrentAndFutureAccounts(oldLock, currentEpochStart);

        // Update global & account states
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) = 
            _updateAccountAndGlobalAndPendingDeltas(currentAccount, currentEpochStart, currentIsDelegate);

        // Update pending deltas for delegate pair 
        if (currentIsDelegate) _updatePendingForDelegatePair(oldLock.owner, currentAccount, currentEpochStart);

        // Execute modification via library
        // Step 1: Update history
        (DataTypes.VeBalance memory updatedVeAccount, DataTypes.VeBalance memory increaseInVeBalance, DataTypes.Lock memory newLock) = 
            VeDelegationLib.executeIncreaseAmount_UpdateHistory(
                oldLock, esMocaToAdd, mocaToAdd, veAccount_, 
                currentEpochStart,
                currentAccount, currentIsDelegate,
                userHistory, delegateHistory, delegatedAggregationHistory
            );

        // Step 2: Update slopes
        VeDelegationLib.executeIncreaseAmount_UpdateSlopes(
            oldLock.owner, futureAccount, oldLock.expiry, increaseInVeBalance.slope, futureIsDelegate,
            slopeChanges, userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges
        );

        // Step 3: Update pending deltas (if needed)
        if (oldLock.delegationEpoch > currentEpochStart) {
            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;
            VeDelegationLib.updatePendingDeltas(
                oldLock.owner, currentAccount, futureAccount, nextEpochStart, increaseInVeBalance,
                currentIsDelegate, futureIsDelegate,
                userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate
            );
        }

        // Update global
        veGlobal_ = veGlobal_.add(increaseInVeBalance);
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // Emit account event using UPDATED balance from library
        if (currentIsDelegate) emit Events.DelegateUpdated(currentAccount, updatedVeAccount.bias, updatedVeAccount.slope);
        else emit Events.UserUpdated(currentAccount, updatedVeAccount.bias, updatedVeAccount.slope);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newLock.convertToVeBalance(), uint128(currentEpochStart));

        if(mocaToAdd > 0) TOTAL_LOCKED_MOCA += mocaToAdd;

        if(esMocaToAdd > 0) {
            TOTAL_LOCKED_ESMOCA += esMocaToAdd;
            ESMOCA.safeTransferFrom(msg.sender, address(this), esMocaToAdd);
        }

        emit Events.LockAmountIncreased(lockId, oldLock.owner, oldLock.delegate, mocaToAdd, esMocaToAdd);
    }

    // user to increase duration of lock
    function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external whenNotPaused {
        require(durationToIncrease > 0, Errors.InvalidLockDuration());

        DataTypes.Lock memory oldLock = locks[lockId];
        require(oldLock.owner == msg.sender, Errors.InvalidLockId());
        
        uint128 currentEpochStart = _minimumDurationCheck(oldLock.expiry);
        uint128 newExpiry = oldLock.expiry + durationToIncrease;
        require(EpochMath.isValidEpochTime(newExpiry), Errors.InvalidEpochTime());
        require(newExpiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidExpiry());

        // Resolve accounts
        (address currentAccount, address futureAccount, bool currentIsDelegate, bool futureIsDelegate)
            = _getCurrentAndFutureAccounts(oldLock, currentEpochStart);

        // Update account and global veBalance
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) = 
            _updateAccountAndGlobalAndPendingDeltas(currentAccount, currentEpochStart, currentIsDelegate);

        // Update pending deltas for delegate pair 
        if (currentIsDelegate) _updatePendingForDelegatePair(oldLock.owner, currentAccount, currentEpochStart);

        // Execute modification via library
        // Step 1: Update history
        (DataTypes.VeBalance memory updatedVeAccount, uint128 oldSlope, uint128 newSlope, DataTypes.VeBalance memory increaseInVeBalance, DataTypes.Lock memory newLock) = 
            VeDelegationLib.executeIncreaseDuration_UpdateHistory(
                oldLock, newExpiry, veAccount_, currentEpochStart,
                currentAccount, currentIsDelegate,
                userHistory, delegateHistory, delegatedAggregationHistory
            );


        // Step 2: Update slopes
        VeDelegationLib.executeIncreaseDuration_UpdateSlopes(
                oldLock.owner, futureAccount, oldLock.expiry, newLock.expiry,
                oldSlope, newSlope, futureIsDelegate,
                slopeChanges, userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges
            );

        // Step 3: Update pending deltas (if needed)
        if (oldLock.delegationEpoch > currentEpochStart) {
            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;
            VeDelegationLib.updatePendingDeltas(
                oldLock.owner, currentAccount, futureAccount, nextEpochStart, increaseInVeBalance,
                currentIsDelegate, futureIsDelegate,
                userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate
            );
        }

        // Update global
        veGlobal_ = veGlobal_.add(increaseInVeBalance);
        veGlobal = veGlobal_;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

        // Emit account event using UPDATED balance from library
        if (currentIsDelegate) emit Events.DelegateUpdated(currentAccount, updatedVeAccount.bias, updatedVeAccount.slope);
        else emit Events.UserUpdated(currentAccount, updatedVeAccount.bias, updatedVeAccount.slope);

        // STORAGE: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newLock.convertToVeBalance(), uint128(currentEpochStart));

        emit Events.LockDurationIncreased(lockId, oldLock.owner, oldLock.delegate, oldLock.expiry, newLock.expiry);
    }

    /**
     * @notice Withdraws principals of an expired lock 
     * @dev ve will be burnt, altho veBalance will return 0 on expiry
     * @dev Only the lock owner can call this function.
     * @param lockId The unique identifier of the lock to unlock.
     */
    function unlock(bytes32 lockId) external whenNotPaused {
        DataTypes.Lock storage lockPtr = locks[lockId];

        // sanity checks
        require(lockPtr.owner == msg.sender, Errors.InvalidOwner());
        require(lockPtr.expiry <= block.timestamp, Errors.InvalidExpiry());
        require(!lockPtr.isUnlocked, Errors.InvalidLockState());

        // cache principals before clearing
        uint128 cachedMoca = lockPtr.moca;
        uint128 cachedEsMoca = lockPtr.esMoca;
        address owner = lockPtr.owner;

        // STORAGE: push final checkpoint into lock history
        _pushCheckpoint(lockHistory[lockId], lockPtr.convertToVeBalance(), EpochMath.getCurrentEpochStart()); 

        // STORAGE: decrement global totalLocked counters
        TOTAL_LOCKED_MOCA -= cachedMoca;
        TOTAL_LOCKED_ESMOCA -= cachedEsMoca;

        // STORAGE: clear principals and mark unlocked
        delete lockPtr.moca;
        delete lockPtr.esMoca;
        lockPtr.isUnlocked = true;    

        emit Events.LockUnlocked(lockId, owner, cachedMoca, cachedEsMoca);

        // return principals to owner
        if(cachedEsMoca > 0) ESMOCA.safeTransfer(owner, cachedEsMoca);        
        if(cachedMoca > 0) _transferMocaAndWrapIfFailWithGasLimit(WMOCA, owner, cachedMoca, MOCA_TRANSFER_GAS_LIMIT);
    }


//------------------------------- Delegation functions----------------------------------------------------

    function delegationAction(bytes32 lockId, address delegate, DataTypes.DelegationType action) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, action, delegate);

        if (action == DataTypes.DelegationType.Delegate) {
            VeDelegationLib.executeDelegateLock(lockId, currentEpochStart, delegate, locks, userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges, userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate);
        } 

        // delegate is new delegate
        if (action == DataTypes.DelegationType.Switch) {
            VeDelegationLib.executeSwitchDelegateLock(lockId, currentEpochStart, delegate, locks, delegateSlopeChanges, delegatePendingDeltas, userDelegatedSlopeChanges, userPendingDeltasForDelegate);
        } 

        if (action == DataTypes.DelegationType.Undelegate) {
            VeDelegationLib.executeUndelegateLock(lockId, currentEpochStart, locks, userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges, userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate);
        }
    }

    /*function delegateLock(bytes32 lockId, address delegate) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, DataTypes.DelegationType.Delegate, delegate);

        VeDelegationLib.executeDelegateLock(
            lockId, currentEpochStart, delegate, locks,
            userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges, 
            userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate
        );
    }

    function switchDelegate(bytes32 lockId, address newDelegate) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, DataTypes.DelegationType.Switch, newDelegate);


        VeDelegationLib.executeSwitchDelegateLock(
            lockId, currentEpochStart, newDelegate, locks,
            delegateSlopeChanges, delegatePendingDeltas, 
            userDelegatedSlopeChanges, userPendingDeltasForDelegate
        );
    }

    function undelegateLock(bytes32 lockId) external whenNotPaused {
        (uint128 currentEpochStart, DataTypes.Lock memory lock) 
            = _preDelegationChecksAndUpdates(lockId, DataTypes.DelegationType.Undelegate, address(0));


        VeDelegationLib.executeUndelegateLock(
            lockId, currentEpochStart, locks,
            userSlopeChanges, delegateSlopeChanges, userDelegatedSlopeChanges,
            userPendingDeltas, delegatePendingDeltas, userPendingDeltasForDelegate
        );
    }*/
    
    function _preDelegationChecksAndUpdates(bytes32 lockId, DataTypes.DelegationType action, address targetDelegate) internal returns (uint128, DataTypes.Lock memory){
        DataTypes.Lock memory lock = locks[lockId];
        
        // sanity check: caller must be the lock owner
        require(lock.owner == msg.sender, Errors.InvalidOwner());

        // get current and next epoch start
        uint128 currentEpochStart = _minimumDurationCheck(lock.expiry);

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
        uint128 currentEpochStart = _minimumDurationCheck(expiry);
        require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());

        // update global veBalance
        DataTypes.VeBalance memory veGlobal_ = _updateGlobal(veGlobal, lastUpdatedTimestamp, currentEpochStart);

        // counters: track totals
        uint128 totalEsMoca;
        uint128 totalMoca;
        uint128 totalSlopeChanges;

        // to store lockIds
        bytes32[] memory lockIds = new bytes32[](length);

        // loop through users, create locks, aggregate global stats, accumulate totals
        for(uint256 i; i < length; ++i) {
            
            DataTypes.VeBalance memory veIncoming_;
            (lockIds[i], veIncoming_) = _createSingleLock(users[i], mocaAmounts[i], esMocaAmounts[i], expiry, currentEpochStart);

            // Aggregate Global Stats in memory
            veGlobal_ = veGlobal_.add(veIncoming_);
            totalSlopeChanges += veIncoming_.slope;
            
            // accumulate totals: for verification
            totalMoca += mocaAmounts[i];
            totalEsMoca += esMocaAmounts[i];
        }
        
        // check: msg.value matches totalMoca
        require(msg.value == totalMoca, Errors.InvalidAmount());

        // STORAGE: update global veBalance after all locks
        veGlobal = veGlobal_;
        slopeChanges[expiry] += totalSlopeChanges;
        emit Events.GlobalUpdated(veGlobal_.bias, veGlobal_.slope);

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
    
    function _createSingleLock(address user, uint128 moca, uint128 esMoca, uint128 expiry, uint128 currentEpochStart) internal returns (bytes32, DataTypes.VeBalance memory) {
        // check: not zero address
        require(user != address(0), Errors.InvalidAddress());

        // check: minimum amount
        _minimumAmountCheck(moca, esMoca);

        // update user veBalance: [STORAGE: updates userLastUpdatedTimestamp]
        (, DataTypes.VeBalance memory veUser_) = _updateAccountAndGlobalAndPendingDeltas(user, currentEpochStart, false);

        // Generate Lock ID
        uint256 salt = block.number;
        bytes32 lockId = _generateLockId(salt, user);
        while (locks[lockId].owner != address(0)) lockId = _generateLockId(++salt, user);      // If lockId exists, generate new random Id

        // Create Lock
        DataTypes.Lock memory newLock;
        newLock.owner = user;
        newLock.moca = moca;
        newLock.esMoca = esMoca;
        newLock.expiry = expiry;

        // Convert Lock to veBalance
        DataTypes.VeBalance memory veIncoming_ = newLock.convertToVeBalance();

        // STORAGE: book lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], veIncoming_, uint128(currentEpochStart));
    
        emit Events.LockCreated(lockId, user, newLock.moca, newLock.esMoca, newLock.expiry);

        // Update User State: add veIncoming to user
        veUser_ = veUser_.add(veIncoming_);
        
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

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {lastUpdatedAt += EpochMath.EPOCH_DURATION;}                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = veGlobal_.subtractExpired(slopeChanges[lastUpdatedAt], lastUpdatedAt);

            // book ve supply for this epoch
            totalSupplyAt[lastUpdatedAt] = veGlobal_.getValueAt(lastUpdatedAt);
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


        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {accountLastUpdatedAt += EpochMath.EPOCH_DURATION;}

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = veGlobal_.subtractExpired(slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[accountLastUpdatedAt] = veGlobal_.getValueAt(accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = veAccount_.subtractExpired(accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

    
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];
            bool hasAdd = deltaPtr.hasAddition;
            bool hasSub = deltaPtr.hasSubtraction;
            
            // apply the pending delta to the veAccount [add then sub]
            if(hasAdd) veAccount_ = veAccount_.add(deltaPtr.additions);
            if(hasSub) veAccount_ = veAccount_.sub(deltaPtr.subtractions);

            // book account checkpoint 
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount_;

            // clear slot only when it contained something
            if (hasAdd || hasSub) {
                delete accountPendingDeltas[account][accountLastUpdatedAt];
            }
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
            unchecked {pairLastUpdatedAt += EpochMath.EPOCH_DURATION;}

            // apply decay to the aggregated veBalance
            vePair_ = vePair_.subtractExpired(userDelegatedSlopeChanges[user][delegate][pairLastUpdatedAt], pairLastUpdatedAt);
            
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
            bool hasAdd = deltaPtr.hasAddition;
            bool hasSub = deltaPtr.hasSubtraction;

            // apply the pending deltas to the vePair [add then sub]
            if (hasAdd) vePair_ = vePair_.add(deltaPtr.additions);
            if (hasSub) vePair_ = vePair_.sub(deltaPtr.subtractions);

            // STORAGE: book veBalance for epoch 
            delegatedAggregationHistory[user][delegate][pairLastUpdatedAt] = vePair_;
            
            // clear slot only when it contained something
            if (hasAdd || hasSub){
                delete userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
            }
        }

        // update the last updated timestamp
        userDelegatedPairLastUpdatedTimestamp[user][delegate] = pairLastUpdatedAt;

        return vePair_;
    }

    // used in increaseAmount & increaseDuration
    /**
     * @dev Returns who currently has voting power for this lock and whether they are a delegate.
     * 
     * This function resolves the "effective" account that should receive voting power updates
     * for a given lock, handling the complexity of pending vs active delegations.
     * 
     * Delegation State Machine:
     * - When a user delegates/switches/undelegates, the change doesn't take effect immediately
     * - Instead, it becomes effective at the START of the NEXT epoch (delegationEpoch)
     * - Until then, the previous holder (effectiveDelegate) retains voting power
     *
     * 
     * @param lock The lock struct containing delegation state
     * @param currentEpochStart The start timestamp of the current epoch
     * @return address The account that currently has voting power for this lock
     * @return bool True if the account is a delegate (not the lock owner)
     */
    function _getCurrentAndFutureAccounts(DataTypes.Lock memory lock, uint128 currentEpochStart) internal pure returns (address, address, bool, bool) {
        address futureAccount;  // next holder of voting power
        address currentAccount; // current holder of voting power
        
        // 1. Determine Future Account 
        // If delegate is 0, owner is futureAccount. Else lock.delegate is futureAccount.
        futureAccount = lock.delegate == address(0) ? lock.owner : lock.delegate;

        // 2. Determine Current Account 
        // If there's a pending delegation change, use currentHolder (the previous holder).
        // Otherwise, the delegation is already active, so currentAccount equals futureAccount.
        bool hasPending = lock.delegationEpoch > currentEpochStart;
        if (hasPending) {
            currentAccount = lock.currentHolder == address(0) ? lock.owner : lock.currentHolder;
        } else {
            currentAccount = futureAccount;
        }

        bool currentIsDelegate = currentAccount != lock.owner;
        bool futureIsDelegate = futureAccount != lock.owner; 

        return (currentAccount, futureAccount, currentIsDelegate, futureIsDelegate);
    }

//------------------------------ Internal: helper functions----------------------------------------------

    ///@dev Generate a lockId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateLockId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }

    function _minimumAmountCheck(uint128 moca, uint128 esMoca) internal pure {
        uint128 totalAmount = moca + esMoca;
        require(totalAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());
    }

    /*  lock must have at least 3 epochs `liveliness` before expiry: current + 2 more epochs
        - non-zero voting power in the current and next epoch.  
        - 0 voting power in the 3rd epoch.
        This is a result of forward-decay: benchmarking voting power to the end of the epoch [to freeze intra-epoch decay] 
        
        We also want locks created to be delegated, and since delegation takes effect in the next epoch;
        need to check that the lock has at least 3 epochs left, before expiry: current + 2 epochs.

        Example:
        - Epoch 1: User delegates lock; user still retains voting rights of lock 
        - Epoch 2: Delegation takes effect; delegate can now vote with lock
        - Epoch 3: Lock's voting power is forward decay-ed to 0

        Lock must expire at the end of Epoch3 for the above to be feasible. 
        Therefore, the minimum expiry of a lock is currentEpoch + 3 epochs [currentEpoch + 2 more epochs]
    */  
    function _minimumDurationCheck(uint128 expiry) internal view returns (uint128) {
        // get current epoch start
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // multiply start by 3, to get the end of the 3rd epoch [lock has 0 voting power in the 3rd epoch]
        require(expiry >= currentEpochStart + (3 * EpochMath.EPOCH_DURATION), Errors.LockExpiresTooSoon());

        return currentEpochStart;
    }

    // Push a checkpoint to the lock history
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


//------------------------------ Internal: view functions------------------------------------------------

    /*function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal view returns (DataTypes.VeBalance memory) {
        return VeViewLib.viewGlobal(veGlobal_, lastUpdatedAt, currentEpochStart, slopeChanges);
    }*/

    function _viewAccountAndGlobalAndPendingDeltas(address account, uint128 currentEpochStart, bool isDelegate) internal view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address account => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage accountPendingDeltas,
            mapping(address account => uint128 lastUpdatedTimestamp) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegatePendingDeltas, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userPendingDeltas, userLastUpdatedTimestamp);

        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount_) 
         = VeViewLib.viewAccountAndGlobalAndPendingDeltas(
            account, currentEpochStart, veGlobal, lastUpdatedTimestamp, 
            slopeChanges, accountHistoryMapping, accountSlopeChangesMapping, accountPendingDeltas, accountLastUpdatedMapping);
            
        return (veGlobal_, veAccount_);

/*
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

        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {accountLastUpdatedAt += EpochMath.EPOCH_DURATION;}

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = veGlobal_.subtractExpired(slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                //totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = veAccount_.subtractExpired(accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];
           
            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;

            // apply the pending delta to the veAccount [add then sub]
            if(hasAddition) veAccount_ = veAccount_.add(deltaPtr.additions);
            if(hasSubtraction) veAccount_ = veAccount_.sub(deltaPtr.subtractions);
        }

        return (veGlobal_, veAccount_);*/
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
    function totalSupplyAtTimestamp(uint128 timestamp) external view returns (uint128) {

        // get target epoch start
        uint128 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        DataTypes.VeBalance memory veGlobal_ = VeViewLib._viewGlobal(veGlobal, lastUpdatedTimestamp, targetEpochStartTime, slopeChanges);
        return veGlobal_.getValueAt(timestamp);
    }

    // returns either a user's personal voting power, or voting power that was delegated to him, at given timestamp 
    function balanceOfAt(address user, uint128 timestamp, bool isDelegate) external view returns (uint128) {
        require(user != address(0), Errors.InvalidAddress());
        require(timestamp <= block.timestamp, Errors.InvalidTimestamp());   // cannot query the future

        // get target epoch start
        uint128 targetEpochStartTime = EpochMath.getEpochStartForTimestamp(timestamp);  

        (/*DataTypes.VeBalance memory veGlobal_*/, DataTypes.VeBalance memory veAccount_) = _viewAccountAndGlobalAndPendingDeltas(user, targetEpochStartTime, isDelegate);
        if(veAccount_.bias == 0) return 0; 

        // return user's voting power at given timestamp
        return veAccount_.getValueAt(timestamp);
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
        return locks[lockId].convertToVeBalance();
    }

    function getLockVotingPowerAt(bytes32 lockId, uint128 timestamp) external view returns (uint128) {
        DataTypes.Lock storage lockPtr = locks[lockId];
        if(lockPtr.expiry <= timestamp) return 0;

        return lockPtr.convertToVeBalance().getValueAt(timestamp);
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
        return veAccount_.getValueAt(epochEndTime);
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
        if (lastUpdate >= epochStartTime) return veBalance.getValueAt(epochEndTime);

        
        // 6. Simulate the state forward from the last update to the start of the requested epoch
        // This accounts for linear decay, slope changes, and pending deltas (additions/subtractions)
        // Logic mirrors _viewAccountAndGlobalAndPendingDeltas
        while (lastUpdate < epochStartTime) {

            // advance to the next epoch
            unchecked {lastUpdate += EpochMath.EPOCH_DURATION;}

            // Apply decay and slope changes scheduled for this epoch
            veBalance = veBalance.subtractExpired(userDelegatedSlopeChanges[user][delegate][lastUpdate], lastUpdate);

            // Apply any pending deltas (delegations/undelegations) that were queued for this epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][lastUpdate];

            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;
            
            // apply the pending delta to the veBalance [add then sub]
            if(hasAddition) veBalance = veBalance.add(deltaPtr.additions);
            if(hasSubtraction) veBalance = veBalance.sub(deltaPtr.subtractions);
        }

        // if 0 bias, return 0
        if(veBalance.bias == 0) return 0;

        // return the calculated voting power at the exact end of the epoch
        return veBalance.getValueAt(epochEndTime);
    }

}