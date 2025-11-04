// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";
import {Constants} from "./libraries/Constants.sol";

// interfaces
import {IAccessController} from "./interfaces/IAccessController.sol";
import {IVotingController} from "./interfaces/IVotingController.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
 * @title VotingEscrowMoca
 * @author Calnix [@cal_nix]
 * @notice VotingEscrowMoca is a dual-token, quad-accounting type veToken system.
 * @dev    Users lock native MOCA or esMOCA to receive veMOCA, with voting power scaling by amount and lock duration.
 *        The amount of veMOCA received increases with both the amount of MOCA locked and the length of the lock period, and decays linearly as the lock approaches expiry.
 *        Implements quad-accounting for user, delegate, and global balances.
 *        Integrates with external controllers and enforces protocol-level access and safety checks.
*/  

/** NOTE
    - operates on eTime as timestamp
    - some fns call mappings via epochEndTimestamp or epochStartTimestamp
    - make sure that the timestamp is correct: start/end of epoch; inclusive, exclusive (<= or <)
 */

contract VotingEscrowMoca is ERC20, Pausable {
    using SafeERC20 for IERC20;

    // Contracts
    IAccessController public immutable ACCESS_CONTROLLER;
    IVotingController public immutable VOTING_CONTROLLER;
    address public immutable WMOCA;
    IERC20 public immutable ESMOCA;

    // global principal
    uint256 public TOTAL_LOCKED_MOCA;
    uint256 public TOTAL_LOCKED_ESMOCA;

    // global veBalance
    DataTypes.VeBalance public veGlobal;
    uint256 public lastUpdatedTimestamp;  
    
    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;

    uint256 public isFrozen;

// ===== TO REMOVE: DEBUGGING ONLY =====
    event Debug(string message, DataTypes.VeBalance veBalance);
    //event Debug(string message, uint128 bias, uint128 slope);
    //event Debug(string message);
    //event Debug(string message, uint256 value);

//-------------------------------Mappings-----------------------------------------------------

        // lock
        mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
        // Checkpoints are added upon every state transition; not by epoch. use binary search to find the checkpoint for any eTime
        mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;


        // scheduled global slope changes
        mapping(uint256 eTime => uint256 slopeChange) public slopeChanges;
        // saving totalSupply checkpoint for each epoch [historical queries]
        mapping(uint256 eTime => uint256 totalSupply) public totalSupplyAt;
        
        
        // user personal data
        mapping(address user => mapping(uint256 eTime => uint256 slopeChange)) public userSlopeChanges;
        mapping(address user => mapping(uint256 eTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
        mapping(address user => uint256 lastUpdatedTimestamp) public userLastUpdatedTimestamp;

        // delegation data
        mapping(address delegate => bool isRegistered) public isRegisteredDelegate;                             // note: payment to treasury
        mapping(address delegate => mapping(uint256 eTime => uint256 slopeChange)) public delegateSlopeChanges;
        mapping(address delegate => mapping(uint256 eTime => DataTypes.VeBalance veBalance)) public delegateHistory; // aggregated delegate veBalance
        mapping(address delegate => uint256 lastUpdatedTimestamp) public delegateLastUpdatedTimestamp;

        
        // delegatedAggregationHistory tracks how much veBalance a user has delegated out
        // Used by VotingController to determine users' share of rewards from delegates
        // handover aggregation | aggregated delegated veBalance
        mapping(address user => mapping(address delegate => mapping(uint256 eTime => DataTypes.VeBalance veBalance))) public delegatedAggregationHistory; 
        // slope changes for user's delegated locks [to support VotingController's claimRewardsFromDelegate()]
        mapping(address user => mapping(address delegate => mapping(uint256 eTime => uint256 slopeChange))) public userDelegateSlopeChanges; 

        // mapping to track forward-booked epochs [for locks that were loaned out via delegation related functions]
        mapping(bytes32 lockId => mapping(uint256 eTime => bool hasForwardBooking)) public lockHasForwardBooking;         // referred in increaseAmount, increaseDuration. to update forward-booked point
        mapping(address user => mapping(uint256 eTime => bool hasForwardBooking)) public userHasForwardBooking;           // for _updateAccountAndGlobal() to recognize forward-booked zero values 
        mapping(address delegate => mapping(uint256 eTime => bool hasForwardBooking)) public delegateHasForwardBooking;   // for _updateAccountAndGlobal() to recognize forward-booked zero values 

//-------------------------------Constructor-------------------------------------------------

    constructor(address accessController_, address votingController_, address esMoca_, address wMoca_, uint256 mocaTransferGasLimit) ERC20("veMoca", "veMOCA") {

        // check: access controller is set [Treasury should be non-zero]
        ACCESS_CONTROLLER = IAccessController(accessController_);
        require(ACCESS_CONTROLLER.TREASURY() != address(0), Errors.InvalidAddress());

        // check: voting controller is set [not frozen]
        VOTING_CONTROLLER = IVotingController(votingController_);
        require(VOTING_CONTROLLER.isFrozen() == 0, Errors.InvalidAddress());

        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // esMoca 
        require(esMoca_ != address(0), Errors.InvalidAddress());
        ESMOCA = IERC20(esMoca_);

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;

        // cannot deploy at T=0
        require(block.timestamp > 0, Errors.InvalidTimestamp());
    }

//-------------------------------User functions---------------------------------------------

        // note: locks are booked to currentEpochStart
        /**
         * @notice Creates a new lock with the specified expiry, moca, esMoca, and optional delegate.
         * @dev The delegate parameter is optional and can be set to the zero address if not delegating.
         * @param expiry The timestamp when the lock will expire.
         * @param esMoca The amount of esMOCA to lock.
         * @param delegate The address to delegate voting power to (optional).
         * @return lockId The unique identifier of the created lock.
        */
        function createLock(uint128 expiry, uint128 esMoca, address delegate) external payable whenNotPaused returns (bytes32) {
            return _createLockFor(msg.sender, expiry, msg.value, esMoca, delegate);
        }

        /**
         * @notice Increases the amount of MOCA and/or esMOCA staked in an existing lock.
         * @dev Users can only increase the amount for locks that have at least 2 epochs left before expiry.
         *      The function updates the lock's staked amounts, recalculates veBalance, and mints additional veMoca to the account.
         *      Only the lock owner can call this function.
         *      note: mocaToIncrease: msg.value
         * @param lockId The unique identifier of the lock to increase.
         * @param esMocaToIncrease The amount of esMOCA to add to the lock.
         */
        function increaseAmount(bytes32 lockId, uint128 esMocaToIncrease) external payable whenNotPaused {
            DataTypes.Lock memory oldLock = locks[lockId];

            require(oldLock.lockId != bytes32(0), Errors.InvalidLockId());
            require(oldLock.owner == msg.sender, Errors.InvalidOwner());
            
            // NOTE: FIX: Enforce minimum increment amount to avoid precision loss
            uint256 mocaToIncrease = msg.value;
            uint256 incrementAmount = mocaToIncrease + esMocaToIncrease;
            require(incrementAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());

            // must have at least 2 Epoch left to increase amount: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            require(oldLock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), Errors.LockExpiresTooSoon());


            // DELEGATED OR PERSONAL LOCK:
            bool isDelegated = oldLock.delegate != address(0);
            address account = isDelegated ? oldLock.delegate : msg.sender;

            // update account and global: account is either delegate or user
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint256 currentEpochStart, 
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping, 
                mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping
            
            ) = _updateAccountAndGlobal(account, isDelegated);

            /** if lock is delegated, then the lock has been loaned to the delegate
                - must update delegateSlopeChanges, delegateHistory
                - userHistory,userSlopeChanges do not track loaned locks
                so no reason to update _updateUserAndGlobal -> no bearing.
            */

            // copy old lock: update amount
            DataTypes.Lock memory updatedLock = oldLock;
                updatedLock.moca += uint128(mocaToIncrease);
                updatedLock.esMoca += uint128(esMocaToIncrease);
                
            // calc. delta: schedule slope changes + book new veBalance + mints additional veMoca to account | updates veGlobal
            DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veAccount, oldLock, updatedLock, account, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);

            // storage: update lock + checkpoint lock
            locks[lockId] = updatedLock;
            _pushCheckpoint(lockHistory[lockId], newVeBalance, uint128(currentEpochStart));  
    
            // emit event

            // STORAGE: increment global TOTAL_LOCKED_MOCA/TOTAL_LOCKED_ESMOCA + transfer tokens to contract
            if(mocaToIncrease > 0){
                TOTAL_LOCKED_MOCA += mocaToIncrease;
                _mocaToken().safeTransferFrom(msg.sender, address(this), mocaToIncrease);
            }
            if(esMocaToIncrease > 0){
                TOTAL_LOCKED_ESMOCA += esMocaToIncrease;
                esMoca.safeTransferFrom(msg.sender, address(this), esMocaToIncrease);
            }
        }
        

        /**
         * @notice Increases the duration of an existing lock.
         * @dev Users can only increase the duration for locks that have at least 2 epochs left before expiry.
         *      The function updates the lock's expiry, recalculates veBalance, and mints additional veMoca to the account.
         *      Only the lock owner can call this function.
         * @param lockId The unique identifier of the lock to increase.
         * @param durationToIncrease The additional duration to add to the lock (must be on epoch boundary).
         */
        function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external whenNotPaused {
            // cannot extend duration arbitrarily; must be step-wise matching epoch boundaries
            require(EpochMath.isValidEpochTime(durationToIncrease), Errors.InvalidEpochTime());

            DataTypes.Lock memory oldLock = locks[lockId];

            require(oldLock.lockId != bytes32(0), Errors.InvalidLockId());
            require(oldLock.owner == msg.sender, Errors.InvalidOwner());
            require(oldLock.expiry > block.timestamp, Errors.InvalidExpiry());
            
            // must have at least 2 Epoch left to increase duration: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            uint256 newExpiry = oldLock.expiry + durationToIncrease;
            require(newExpiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), Errors.LockExpiresTooSoon());

            // DELEGATED OR PERSONAL LOCK:
            bool isDelegated = oldLock.delegate != address(0);
            address account = isDelegated ? oldLock.delegate : msg.sender;

            // update account and global: account is either delegate or user
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint256 currentEpochStart, 
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping, 
                mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping
            
            ) = _updateAccountAndGlobal(account, isDelegated);

            /** if lock is delegated, then the lock has been loaned to the delegate
                - must update delegateSlopeChanges, delegateHistory
                - userHistory,userSLopeChanges do not track loaned locks
                so no reason to update _updateUserAndGlobal -> no bearing.
            */

            // copy old lock: update amount and/or duration
            DataTypes.Lock memory updatedLock = oldLock;
                updatedLock.expiry = uint128(newExpiry);

            // calc. delta: schedule slope changes + book new veBalance + mints additional veMoca to account | updates veGlobal
            DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veAccount, oldLock, updatedLock, account, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);

            // storage: update lock + checkpoint lock
            locks[lockId] = updatedLock;
            _pushCheckpoint(lockHistory[lockId], newVeBalance, uint128(currentEpochStart));        

            // emit event
        }

        //TODO: native moca flow
        /**
         * @notice Withdraws principals of an expired lock 
         * @dev ve will be burnt, altho veBalance will return 0 on expiry
         * @dev Only the lock owner can call this function.
         * @param lockId The unique identifier of the lock to unlock.
         */
        function unlock(bytes32 lockId) external payable whenNotPaused {
            DataTypes.Lock memory lock = locks[lockId];

            require(lock.lockId != bytes32(0), Errors.InvalidLockId());
            require(lock.expiry <= block.timestamp, Errors.InvalidExpiry());
            require(lock.isUnlocked == false, Errors.InvalidLockState());
            require(lock.owner == msg.sender, Errors.InvalidOwner());

            // DELEGATED OR PERSONAL LOCK:
            bool isDelegated = lock.delegate != address(0);
            address account = isDelegated ? lock.delegate : msg.sender;

            // update account and global: account is either delegate or user
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint256 currentEpochStart, 
                ,
            ) = _updateAccountAndGlobal(account, isDelegated);

            // STORAGE: update lock + book final checkpoint | note: book final checkpoint, since we do not delete the lock
            lock.isUnlocked = true;    
            locks[lockId] = lock;
            _pushCheckpoint(lockHistory[lockId], veAccount, uint128(currentEpochStart));  

            // STORAGE: update global state
            veGlobal = veGlobal_;   

            // STORAGE: decrement global totalLocked counters
            TOTAL_LOCKED_MOCA -= lock.moca;
            TOTAL_LOCKED_ESMOCA -= lock.esMoca;

            // burn originally issued veMoca
            uint256 mintedVeMoca = _convertToVeBalance(lock).bias;
            _burn(account, mintedVeMoca);

            emit Events.LockUnlocked(lockId, lock.owner, lock.moca, lock.esMoca);

            // return principals to lock.owner
            if(lock.moca > 0) _mocaToken().safeTransfer(lock.owner, lock.moca);
            if(lock.esMoca > 0) _esMocaToken().safeTransfer(lock.owner, lock.esMoca);        
        }

//-------------------------------User Delegate functions-------------------------------------

    /** Problem: user can vote, then delegate
        ⦁	sub their veBal, add to delegate veBal
        ⦁	_vote only references `veMoca.balanceOfAt(caller, epochEnd, isDelegated)`
        ⦁	so this creates a double-voting exploit
        Solution: forward-delegate. impacts on next epoch.
        This problem does not occur when users' are createLock(isDelegated) 
    */

    /**
        * @notice Delegates a lock's voting power to a registered delegate
        * @dev Only the lock creator can delegate. The lock must not be expired or already delegated
        *      Updates user and delegate veBalance, slope changes, and aggregation history
        *      Prevents double-voting by forward-booking the delegation to the next epoch 
        *      Users can vote with the delegated lock for the current epoch, but no longer from the next epoch onwards
        * @param lockId The unique identifier of the lock to delegate
        * @param delegate The address of the registered delegate to receive voting power
        */
    function delegateLock(bytes32 lockId, address delegate) external whenNotPaused {
        // sanity check: delegate
        require(delegate != address(0), Errors.InvalidAddress());
        require(delegate != msg.sender, Errors.InvalidDelegate());
        require(isRegisteredDelegate[delegate], Errors.DelegateNotRegistered()); // implicit address(0) check: newDelegate != address(0)

        DataTypes.Lock memory lock = locks[lockId];
        
        // sanity check: lock
        require(lock.lockId != bytes32(0), Errors.InvalidLockId());
        require(lock.owner == msg.sender, Errors.InvalidOwner());

        // lock must have at least 2 more epoch left, so that the delegate can vote in the next epoch [1 epoch for delegation, 1 epoch for non-zero voting power]    
        // allow the delegate to meaningfully vote for the next epoch        
        require(lock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");


        // Update user & global: account for decay since lastUpdate and any scheduled slope changes | false since lock is not yet delegated
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint256 currentEpochStart,,) = _updateAccountAndGlobal(msg.sender, false);
        
        // Update delegate: required before adding the lock to delegate's balance [global will not be updated; was handled in earlier update]
        // true: update delegate's aggregated veBalance; not personal
        (, DataTypes.VeBalance memory veDelegate,,,) = _updateAccountAndGlobal(delegate, true);

        // STORAGE: update user + delegate for current epoch
        userHistory[msg.sender][currentEpochStart] = veUser;
        delegateHistory[delegate][currentEpochStart] = veDelegate;
        // STORAGE: update global state
        veGlobal = veGlobal_;   

        // ----- accounts and global updated to currentEpoch -----


        // get nextEpoch
        uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's current veBalance
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 
        

        // STACKING FIX: Check if there's already a forward-booked value[frm a prior delegate call in the same epoch]
        DataTypes.VeBalance memory veUserNextEpoch;
        if (userHasForwardBooking[msg.sender][nextEpochStart]) {
            // Use the existing forward-booked value
            veUserNextEpoch = userHistory[msg.sender][nextEpochStart];
        } else{
            // update currentEpoch's veBal to nextEpoch by applying slope changes
            uint256 expiringSlope = userSlopeChanges[msg.sender][nextEpochStart];
            veUserNextEpoch = _subtractExpired(veUser, expiringSlope, nextEpochStart);
        }

        // STACKING FIX: Check if there's already a forward-booked value[frm a prior delegate call in the same epoch]
        DataTypes.VeBalance memory veDelegateNextEpoch;
        if (delegateHasForwardBooking[delegate][nextEpochStart]) {
            // Use the existing forward-booked value as base
            veDelegateNextEpoch = delegateHistory[delegate][nextEpochStart];
        } else{
            // update currentEpoch's veBal to nextEpoch by applying slope changes
            uint256 expiringSlope = delegateSlopeChanges[delegate][nextEpochStart];
            veDelegateNextEpoch = _subtractExpired(veDelegate, expiringSlope, nextEpochStart);
        }

        
        // Remove specified lock from user's aggregated veBalance of the next epoch [prev. forward-booked or current veBalance]
        // user cannot vote with the delegated lock in the next epoch
        veUserNextEpoch = _sub(veUserNextEpoch, lockVeBalance);
        userHistory[msg.sender][nextEpochStart] = veUserNextEpoch;
        userSlopeChanges[msg.sender][lock.expiry] -= lockVeBalance.slope;       // cancel scheduled slope change for this lock's expiry
        userHasForwardBooking[msg.sender][nextEpochStart] = true;
        
        
        // Add the lock to delegate's delegated balance
        veDelegateNextEpoch = _add(veDelegateNextEpoch, lockVeBalance);
        delegateHistory[delegate][nextEpochStart] = veDelegateNextEpoch;
        delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;
        delegateHasForwardBooking[delegate][nextEpochStart] = true;


        // transfer veMoca tokens from user to delegate 
        _transfer(msg.sender, delegate, lockVeBalance.bias);

        // STORAGE: mark lock as delegated
        lock.delegate = delegate;
        locks[lockId] = lock;

        // Update delegatedAggregationHistory to reflect that the user has delegated this lock's veBalance to the specified delegate for the next epoch.
        // This ensures the protocol can accurately account for the total veBalance a user has delegated to each delegate at every epoch, which is critical for correct rewards calculation.
        delegatedAggregationHistory[msg.sender][delegate][nextEpochStart] = _add(delegatedAggregationHistory[msg.sender][delegate][nextEpochStart], lockVeBalance);

        // Add the lock's slope to userDelegateSlopeChanges for this delegate; for _viewForwardAbsolute, to simulate the decay for user's delegated locks.
        userDelegateSlopeChanges[msg.sender][delegate][lock.expiry] += lockVeBalance.slope;


        // Emit event
        //emit LockDelegated(lockId, msg.sender, delegate);
    }

    /**
        * @notice Undelegates a lock's voting power from a registered delegate
        * @dev Only the lock creator can undelegate. The lock must be currently delegated and not expired.
        *      Updates user and delegate veBalance, slope changes, and aggregation history
        *      Prevents double-voting by forward-booking the undelegation to the next epoch 
        *      Delegate can vote with the lock for the current epoch, but no longer from the next epoch onwards
        * @param lockId The unique identifier of the lock to undelegate
        */
    function undelegateLock(bytes32 lockId) external whenNotPaused {
        DataTypes.Lock memory lock = locks[lockId];

        // sanity checks
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        require(lock.lockId != bytes32(0), Errors.InvalidLockId());
        require(lock.delegate != address(0), Errors.InvalidDelegate());
        require(lock.isUnlocked == false, Errors.PrincipalsAlreadyReturned());

        
        //note: intentionally not enforced: delegates may have unregistered, so users must always be able to reclaim their locks
        //require(isRegisteredDelegate[delegate], "Delegate not registered");

        //note: intentionally not enforced: expired locks should be undelegated
        //require(lock.expiry > block.timestamp, "Lock expired");

        
        // Update delegate: apply decay since lastUpdate and any scheduled slope changes [required before removing the lock from delegate's balance]
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veDelegate, uint256 currentEpochStart,,) = _updateAccountAndGlobal(lock.delegate, true);
        // Update user: false: update user's personal aggregated veBalance; not delegated veBalance [required before we can book lock's veBalance to user]
        (, DataTypes.VeBalance memory veUser,,,) = _updateAccountAndGlobal(msg.sender, false);

        // ----- accounts and global updated to currentEpoch -----

        // get nextEpoch
        uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get the lock's current veBalance [no checkpoint required as lock attributes have not changed]
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 


        // STACKING FIX: Check if there's already a forward-booked value[from a prior delegate/undelegate call in the same epoch]
        DataTypes.VeBalance memory veDelegateNextEpoch;
        if (delegateHasForwardBooking[lock.delegate][nextEpochStart]) {
            // Use the existing forward-booked value as base
            veDelegateNextEpoch = delegateHistory[lock.delegate][nextEpochStart];
        } else {
            // update currentEpoch's veBal to nextEpoch by applying slope changes
            uint256 expiringSlope = delegateSlopeChanges[lock.delegate][nextEpochStart];
            veDelegateNextEpoch = _subtractExpired(veDelegate, expiringSlope, nextEpochStart);
        }

        // STACKING FIX: Check if there's already a forward-booked value[from a prior delegate/undelegate call in the same epoch]
        DataTypes.VeBalance memory veUserNextEpoch;
        if (userHasForwardBooking[msg.sender][nextEpochStart]) {
            // Use the existing forward-booked value
            veUserNextEpoch = userHistory[msg.sender][nextEpochStart];
        } else {
            // update currentEpoch's veBal to nextEpoch by applying slope changes
            uint256 expiringSlope = userSlopeChanges[msg.sender][nextEpochStart];
            veUserNextEpoch = _subtractExpired(veUser, expiringSlope, nextEpochStart);
        }

        // Remove the lock from delegate's aggregated veBalance of the next epoch [prev. forward-booked or current veBalance]
        veDelegateNextEpoch = _sub(veDelegateNextEpoch, lockVeBalance);
        delegateHistory[lock.delegate][nextEpochStart] = veDelegateNextEpoch;
        delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;
        delegateHasForwardBooking[lock.delegate][nextEpochStart] = true;

        // Add the lock to user's personal aggregated veBalance of the next epoch
        veUserNextEpoch = _add(veUserNextEpoch, lockVeBalance);
        userHistory[msg.sender][nextEpochStart] = veUserNextEpoch;
        userSlopeChanges[msg.sender][lock.expiry] += lockVeBalance.slope;
        userHasForwardBooking[msg.sender][nextEpochStart] = true;

        // transfer veMoca tokens from user to delegate 
        _transfer(lock.delegate, msg.sender, lockVeBalance.bias);

        // delegatedAggregationHistory tracks how much veBalance a user has delegated out; to be used for rewards accounting by VotingController
        // note: delegated veBalance booked to nextEpochStart
        delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart] = _sub(delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart], lockVeBalance);
        
        // NOTE: FIX: Cancel scheduled dslope for this lock's expiry in user-delegate context
        userDelegateSlopeChanges[msg.sender][lock.delegate][lock.expiry] -= lockVeBalance.slope;

        // STORAGE: delete delegate address from lock
        delete lock.delegate;
        locks[lockId] = lock;

        emit Events.LockUndelegated(lockId, msg.sender, lock.delegate);
    }
    
    /**
        * @notice Switches the delegate of a lock to another registered delegate
        * @dev Only the lock creator can switch the delegate. The lock must not be expired and must be currently delegated.
        *      Updates user and delegate veBalance, slope changes, and aggregation history
        *      Prevents double-voting by forward-booking the delegation to the next epoch 
        *      Current delegate can vote with the lock for the current epoch, but no longer from the next epoch onwards
        * @param lockId The unique identifier of the lock
        * @param newDelegate The address of the new delegate
        */
    function switchDelegate(bytes32 lockId, address newDelegate) external whenNotPaused {
        // sanity check: delegate
        require(newDelegate != address(0), Errors.InvalidAddress());
        require(newDelegate != msg.sender, Errors.InvalidDelegate());
        require(isRegisteredDelegate[newDelegate], Errors.DelegateNotRegistered());      // implicit address(0) check: newDelegate != address(0)

        DataTypes.Lock memory lock = locks[lockId];

        // sanity check: lock
        require(lock.lockId != bytes32(0), Errors.InvalidLockId());
        require(lock.owner == msg.sender, Errors.InvalidOwner());
        require(lock.delegate != newDelegate, Errors.InvalidDelegate());

        // lock must have at least 2 more epoch left, so that the delegate can vote in the next epoch [1 epoch for delegation, 1 epoch for non-zero voting power]            
        // allow the delegate to meaningfully vote for the next epoch
        require(lock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");

        // Update current delegate: account for decay since lastUpdate and any scheduled slope changes [required before removing the lock from the current delegate]
        // true: update current delegate's aggregated veBalance; not personal
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veCurrentDelegate, uint256 currentEpochStart,,) = _updateAccountAndGlobal(lock.delegate, true);
        // Update new delegate: required before adding the lock to delegate's balance [ignore global, since it was handled in earlier update]
        // true: update new delegate's aggregated veBalance; not personal
        (, DataTypes.VeBalance memory veNewDelegate,,,) = _updateAccountAndGlobal(newDelegate, true);

        // STORAGE: update current delegate + new delegate for current epoch
        delegateHistory[lock.delegate][currentEpochStart] = veCurrentDelegate;
        delegateHistory[newDelegate][currentEpochStart] = veNewDelegate;
        // STORAGE: update global state
        veGlobal = veGlobal_;

        // ----- accounts and global updated to currentEpoch -----

        // get nextEpoch
        uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

        // get lock's current veBalance [no checkpoint required as lock attributes have not changed]
        DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 


        // STACKING FIX: Check if there's already a forward-booked value[from a prior delegate/switch call in the same epoch]
        DataTypes.VeBalance memory veCurrentDelegateNextEpoch;
        if (delegateHasForwardBooking[lock.delegate][nextEpochStart]) {
            // Use the existing forward-booked value as base
            veCurrentDelegateNextEpoch = delegateHistory[lock.delegate][nextEpochStart];
        } else {
            // update currentEpoch's veBal to nextEpoch by applying slope changes
            uint256 expiringSlope = delegateSlopeChanges[lock.delegate][nextEpochStart];
            veCurrentDelegateNextEpoch = _subtractExpired(veCurrentDelegate, expiringSlope, nextEpochStart);
        }

        // STACKING FIX: Check if there's already a forward-booked value[from a prior delegate/switch call in the same epoch]
        DataTypes.VeBalance memory veNewDelegateNextEpoch;
        if (delegateHasForwardBooking[newDelegate][nextEpochStart]) {
            // Use the existing forward-booked value as base
            veNewDelegateNextEpoch = delegateHistory[newDelegate][nextEpochStart];
        } else {
            // update currentEpoch's veBal to nextEpoch by applying slope changes
            uint256 expiringSlope = delegateSlopeChanges[newDelegate][nextEpochStart];
            veNewDelegateNextEpoch = _subtractExpired(veNewDelegate, expiringSlope, nextEpochStart);
        }

        
        // Remove lock from current delegate's aggregated veBalance of the next epoch [prev. forward-booked or current veBalance]
        veCurrentDelegateNextEpoch = _sub(veCurrentDelegateNextEpoch, lockVeBalance);
        delegateHistory[lock.delegate][nextEpochStart] = veCurrentDelegateNextEpoch;
        delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;
        delegateHasForwardBooking[lock.delegate][nextEpochStart] = true;

        // Add lock to new delegate's aggregated veBalance of the next epoch
        veNewDelegateNextEpoch = _add(veNewDelegateNextEpoch, lockVeBalance);
        delegateHistory[newDelegate][nextEpochStart] = veNewDelegateNextEpoch;
        delegateSlopeChanges[newDelegate][lock.expiry] += lockVeBalance.slope;
        delegateHasForwardBooking[newDelegate][nextEpochStart] = true;

        // Transfer veMoca tokens from current delegate to new delegate
        _transfer(lock.delegate, newDelegate, lockVeBalance.bias);


        // delegatedAggregationHistory tracks how much veBalance a user has delegated out; to be used for rewards accounting by VotingController
        delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart] = _sub(delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart], lockVeBalance);
        delegatedAggregationHistory[msg.sender][newDelegate][nextEpochStart] = _add(delegatedAggregationHistory[msg.sender][newDelegate][nextEpochStart], lockVeBalance);

        // NOTE: Reschedule user-delegate slope changes (cancel from old, add to new)
        userDelegateSlopeChanges[msg.sender][lock.delegate][lock.expiry] -= lockVeBalance.slope;
        userDelegateSlopeChanges[msg.sender][newDelegate][lock.expiry] += lockVeBalance.slope;

        // STORAGE: update lock
        lock.delegate = newDelegate;
        locks[lockId] = lock;
        
        emit Events.LockDelegateSwitched(lockId, msg.sender, lock.delegate, newDelegate);
    }


//-------------------------------Admin function: createLockFor()---------------------------------------------

    // when creating lock onBehalfOf - we will not delegate for the user
    function createLockFor(address user, uint128 expiry, uint128 moca, uint128 esMoca) external onlyCronJobRole whenNotPaused returns (bytes32) { 
        return _createLockFor(user, expiry, moca, esMoca, address(0));
    }

    /**
        * @notice Sets the gas limit for moca transfer.
        * @dev Only callable by the VotingEscrowMoca admin.
        * @param newMocaTransferGasLimit The new gas limit for moca transfer.
        */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyVotingEscrowMocaAdmin whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }


//-------------------------------VotingController.sol functions------------------------------------------
    
    // note: registration fees were collected by VotingController
    // require(delegate != address(0) not needed since external contract call
    function registerAsDelegate(address delegate) external onlyVotingControllerContract whenNotPaused {
        require(!isRegisteredDelegate[delegate], "Already registered");

        // storage: register delegate
        isRegisteredDelegate[delegate] = true;

        // event
        emit Events.DelegateRegistered(delegate);
    }

    function unregisterAsDelegate(address delegate) external onlyVotingControllerContract whenNotPaused {
        require(isRegisteredDelegate[delegate], "Delegate not registered");
        isRegisteredDelegate[delegate] = false;

        // event
        emit Events.DelegateUnregistered(delegate);
    }

//-------------------------------Internal: Update functions----------------------------------------------       
        
        // delegate can be address(0)
        // lock must last for at least 2 Epochs: to meaningfully vote for the next epoch [we are sure] 
        function _createLockFor(address user, uint128 expiry, uint256 mocaAmount, uint128 esMocaAmount, address delegate) internal returns (bytes32) {
            require(user != address(0), Errors.InvalidUser());
            require(EpochMath.isValidEpochTime(expiry), Errors.InvalidExpiry());

            // minimum total amount to avoid flooring to zero [mocaAmount == msg.value]
            uint256 totalAmount = mocaAmount + esMocaAmount;
            require(totalAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());

            require(expiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, Errors.InvalidLockDuration());
            require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());

            // must have at least 2 Epoch left to create lock: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            require(expiry >= EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), Errors.LockExpiresTooSoon());

            bool isDelegated;
            // if delegate is specified: check that delegate is registered
            if (delegate != address(0)) {
                require(isRegisteredDelegate[delegate], Errors.DelegateNotRegistered());
                require(delegate != user, Errors.InvalidDelegate());
                isDelegated = true;
            }

            // --------- create lock ---------

                // vaultId generation
                bytes32 lockId;
                {
                    uint256 salt = block.number;
                    lockId = _generateLockId(salt, user);
                    while (locks[lockId].lockId != bytes32(0)) lockId = _generateLockId(++salt, user);      // If lockId exists, generate new random Id
                }

                DataTypes.Lock memory newLock;
                    newLock.lockId = lockId; 
                    newLock.owner = user;
                    newLock.delegate = delegate;                //note: might be setting this to zero; but no point doing if(delegate != address(0))
                    newLock.moca = mocaAmount;
                    newLock.esMoca = esMocaAmount;
                    newLock.expiry = expiry;
                // STORAGE: book lock
                locks[lockId] = newLock;

                // STORAGE: get lock's veBalance + book checkpoint into lockHistory mapping 
                DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);
                _pushCheckpoint(lockHistory[lockId], veIncoming, EpochMath.getCurrentEpochStart()); 

                // emit
                emit Events.LockCreated(lockId, user, delegate, mocaAmount, esMocaAmount, expiry);

            // --------- Conditional update: based on delegation ---------

            // DELEGATED OR PERSONAL LOCK:
            address account = isDelegated ? delegate : user;

            // Apply scheduled slope reductions & decay up to current epoch
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint256 currentEpochStart, 
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping, 
                mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping
            ) = _updateAccountAndGlobal(account, isDelegated);

            // Add new lock to global state
            veGlobal_.bias += veIncoming.bias;
            veGlobal_.slope += veIncoming.slope;

            // STORAGE: book updated veGlobal & schedule slope change
            veGlobal = veGlobal_;
            slopeChanges[expiry] += veIncoming.slope;

            // Add new lock to account's aggregated veBalance
            veAccount.bias += veIncoming.bias;
            veAccount.slope += veIncoming.slope;

            // STORAGE: book updated veAccount & schedule slope change
            accountHistoryMapping[account][currentEpochStart] = veAccount;
            accountSlopeChangesMapping[account][expiry] += veIncoming.slope;

            //NOTE: FIX
            if (isDelegated) {
                delegatedAggregationHistory[user][delegate][currentEpochStart] = _add(delegatedAggregationHistory[user][delegate][currentEpochStart], veIncoming);
                userDelegateSlopeChanges[user][delegate][expiry] += veIncoming.slope;  // Schedule dslope
            }

            // MINT: veMoca to account
            _mint(account, veIncoming.bias);

            // STORAGE: increment global TOTAL_LOCKED_MOCA/TOTAL_LOCKED_ESMOCA + transfer tokens to contract
            if (mocaAmount > 0) {
                TOTAL_LOCKED_MOCA += mocaAmount;
                // msg.value: mocaAmount
            } 
            if (esMocaAmount > 0) {
                TOTAL_LOCKED_ESMOCA += esMocaAmount;
                ESMOCA.safeTransferFrom(msg.sender, address(this), esMocaAmount);
            } 

            return lockId;
        }

        ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
        function _generateLockId(uint256 salt, address user) internal view returns (bytes32) {
            return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
        }

        // does not update veGlobal into storage; calcs the latest veGlobal. storage updates: lastUpdatedTimestamp & totalSupplyAt[]
        function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint256 lastUpdatedAt, uint256 currentEpochStart) internal returns (DataTypes.VeBalance memory) {       
            // veGlobal_ is up to date: lastUpdate was within current epoch
            if(lastUpdatedAt >= currentEpochStart) {
                return (veGlobal_);  
            } 

            // FIRST TIME: no prior updates [global lastUpdatedTimestamp is set to currentEpochStart]
            // Note: contract cannot be deployed at T=0; and its not possible for there to be any updates at T=0.
            if(lastUpdatedAt == 0) {
                lastUpdatedTimestamp = currentEpochStart;   // move forward the anchor point to skip prior empty epochs
                return veGlobal_;
            }

            // UPDATES REQUIRED: update global veBalance to current epoch
            while (lastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

                // apply scheduled slope reductions and handle decay for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
                // after removing expired locks, calc. and book current ve supply for the epoch 
                totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);           // STORAGE: updates totalSupplyAt[]
            }

            // STORAGE: update global lastUpdatedTimestamp
            lastUpdatedTimestamp = currentEpochStart;

            return (veGlobal_);
        }

        //note: we do not call _updateGlobal() within the while loop when updating account, to reduce stacking of while loops: `while (accountLastUpdatedAt < currentEpochStart)`
        /**
            - user.lastUpdatedAt either matches the global.lastUpdatedAt OR is behind it
            - the global never lags behind the user

            returns: veGlobal_, veAccount, currentEpochStart
        */
        function _updateAccountAndGlobal(address account, bool isDelegate) internal 
            returns ( 
                    DataTypes.VeBalance memory, DataTypes.VeBalance memory, 
                    uint256,
                    mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage,  // accountHistoryMapping
                    mapping(address => mapping(uint256 => uint256)) storage               // accountSlopeChangesMapping
                )
        {

            // Streamlined mapping lookups based on account type
            (
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping,
                mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping,
                mapping(address => uint256) storage accountLastUpdatedMapping,
                mapping(address => mapping(uint256 => bool)) storage accountHasForwardBookingMapping
            ) 
                = isDelegate ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp, delegateHasForwardBooking) : (userHistory, userSlopeChanges, userLastUpdatedTimestamp, userHasForwardBooking);

            // CACHE: global veBalance + lastUpdatedTimestamp
            DataTypes.VeBalance memory veGlobal_ = veGlobal;
            uint256 lastUpdatedTimestamp_ = lastUpdatedTimestamp;
        
            // get current epoch start
            uint256 currentEpochStart = EpochMath.getCurrentEpochStart(); 

            // get account's lastUpdatedTimestamp: {user | delegate}
            uint256 accountLastUpdatedAt = accountLastUpdatedMapping[account];
            // LOAD: account's previous veBalance
            DataTypes.VeBalance memory veAccount = accountHistoryMapping[account][accountLastUpdatedAt];      // either its empty struct or the previous veBalance

            // RETURN: account is updated to current epoch; but global may not be, due to forward-booking from delegation actions
            if (accountLastUpdatedAt >= currentEpochStart) {
                // update global to current epoch
                veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart); 
                return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
            }


            // ACCOUNT'S FIRST TIME: no previous locks created: update global & set account's lastUpdatedTimestamp [global lastUpdatedTimestamp is set to currentEpochStart]
            // Note: contract cannot be deployed at T=0; and its not possible for a user to create a lock at T=0.
            if (accountLastUpdatedAt == 0) {

                // set account's lastUpdatedTimestamp
                accountLastUpdatedMapping[account] = currentEpochStart;
                //accountHistoryMapping[account][currentEpochStart] = veAccount;  // DataTypes.VeBalance(0, 0)

                // update global: may or may not have updates [STORAGE: updates global lastUpdatedTimestamp]
                veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

                return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
            }
                    

            // UPDATES REQUIRED: update global & account veBalance to current epoch
            while (accountLastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                accountLastUpdatedAt += EpochMath.EPOCH_DURATION;       // accountLastUpdatedAt will be <= global lastUpdatedTimestamp [so we use that as the counter]

                // --- UPDATE GLOBAL: if required ---
                if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                    
                    // subtract decay for this epoch && remove any scheduled slope changes from expiring locks
                    veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                    // book ve state for the new epoch
                    totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);                 // STORAGE: updates totalSupplyAt[]
                }
                
                // --- UPDATE ACCOUNT: Check for forward-booked checkpoint first ---
                if (accountHasForwardBookingMapping[account][accountLastUpdatedAt]) {
                    // Use the forward-booked value (even if zero) 
                    veAccount = accountHistoryMapping[account][accountLastUpdatedAt];
                    // Clear the forward-booking flag as we've now processed it
                    accountHasForwardBookingMapping[account][accountLastUpdatedAt] = false;

                } else {    // standard process
                    
                    // use previous epoch's value and apply slope changes for the epoch
                    uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];
                    veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
                }

                
                // book account checkpoint 
                accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
            }

            // STORAGE: update lastUpdatedTimestamp for global and account
            lastUpdatedTimestamp = accountLastUpdatedAt;
            accountLastUpdatedMapping[account] = accountLastUpdatedAt;        

            // return
            return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
        }

        // TODO: any possible rounding errors due to calc. of delta; instead of removed old then add new?
        function _modifyPosition(
            DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount, 
            DataTypes.Lock memory oldLock, DataTypes.Lock memory newLock, 
            address account, uint256 currentEpochStart,

            mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint256 => uint256)) storage accountSlopeChangesMapping
            ) internal returns (DataTypes.VeBalance memory) {

            // convert old and new lock to veBalance
            DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(oldLock);
            DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(newLock);

            // get delta btw veBalance of old and new lock
            DataTypes.VeBalance memory increaseInVeBalance = _sub(newVeBalance, oldVeBalance);

            // STORAGE: update global + account [user or delegated]
            veGlobal = _add(veGlobal_, increaseInVeBalance);
            veAccount = _add(veAccount, increaseInVeBalance);
            accountHistoryMapping[account][currentEpochStart] = veAccount;

            if(newLock.expiry != oldLock.expiry) {
                // SCENARIO: increaseDuration(): new expiry is different from old expiry
                slopeChanges[oldLock.expiry] -= oldVeBalance.slope;
                slopeChanges[newLock.expiry] += newVeBalance.slope;
                
                accountSlopeChangesMapping[account][oldLock.expiry] -= oldVeBalance.slope;
                accountSlopeChangesMapping[account][newLock.expiry] += newVeBalance.slope;
            } else {
                // SCENARIO: increaseAmount(): expiry is the same
                slopeChanges[newLock.expiry] += increaseInVeBalance.slope;
                accountSlopeChangesMapping[account][newLock.expiry] += increaseInVeBalance.slope;
            }

            // NOTE: Fix: If delegated, update delegatedAggregationHistory + userDelegateSlopeChanges
            if (oldLock.delegate != address(0)) {
                
                // 1. Increment aggregated veBalance by delta
                DataTypes.VeBalance storage agg = delegatedAggregationHistory[msg.sender][oldLock.delegate][currentEpochStart];
                agg.bias += increaseInVeBalance.bias;
                agg.slope += increaseInVeBalance.slope;
            
                // 2. Adjust Scheduled Slopes for Delegation context (userDelegateSlopeChanges)
                if (newLock.expiry != oldLock.expiry) {
                    // SCENARIO: increaseDuration(): new expiry is different from old expiry
                    // Cancel the original slope from the old expiry time
                    userDelegateSlopeChanges[msg.sender][oldLock.delegate][oldLock.expiry] -= oldVeBalance.slope;
                    // Schedule the *new* (same value, new expiry) slope at the new expiry time
                    userDelegateSlopeChanges[msg.sender][oldLock.delegate][newLock.expiry] += newVeBalance.slope;

                } else {
                    // SCENARIO: increaseAmount(): expiry is the same
                    // Only schedule the *increase in slope* (delta) at the existing expiry time
                    userDelegateSlopeChanges[msg.sender][oldLock.delegate][newLock.expiry] += increaseInVeBalance.slope;
                }
            }

            // mint the delta (difference between old and new veBalance)
            _mint(account, newVeBalance.bias - oldVeBalance.bias);
            
            return newVeBalance;
        }

        // Eager simulation (from prior)
        function _simulateAccountUpdateTo(address account, bool isDelegate, uint256 targetETime) internal view returns (DataTypes.VeBalance memory) {
            // get account's slope changes mapping and last updated timestamp
            mapping(uint256 => uint256) storage accountSlopeChangesMapping = isDelegate ? delegateSlopeChanges[account] : userSlopeChanges[account];
            uint256 accountLastUpdatedAt = isDelegate ? delegateLastUpdatedTimestamp[account] : userLastUpdatedTimestamp[account];

            // get account's previous veBalance
            DataTypes.VeBalance memory veAccount = isDelegate ? delegateHistory[account][accountLastUpdatedAt] : userHistory[account][accountLastUpdatedAt];

            // if account has no previous locks created, set accountLastUpdatedAt to current epoch start
            if (accountLastUpdatedAt == 0) accountLastUpdatedAt = EpochMath.getCurrentEpochStart();

            // update account's veBalance to targetETime
            while (accountLastUpdatedAt < targetETime) {
                // advance 1 epoch
                accountLastUpdatedAt += EpochMath.EPOCH_DURATION;
                // apply slope changes for the epoch
                uint256 expiringSlope = accountSlopeChangesMapping[accountLastUpdatedAt];
                veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
            }
            
            return veAccount;
        }
    
//-------------------------------Internal: delegate functions--------------------------------------------



//-------------------------------Internal: library functions--------------------------------------------

        /**
         * @notice Removes expired lock contributions from a veBalance.
         * @dev Overflow is only possible if 100% of MOCA is locked at the same expiry, which is infeasible in practice.
         *      No SafeCast required as only previously added values are subtracted; 8.89B MOCA supply ensures overflow is impossible.
         *      Does not update parameter: lastUpdatedAt.
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

        // subtracts b from a: a - b
        function _sub(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
            DataTypes.VeBalance memory res;
                res.bias = a.bias - b.bias;
                res.slope = a.slope - b.slope;

            return res;
        }

        // a + b
        function _add(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
            DataTypes.VeBalance memory res;
                res.bias = a.bias + b.bias;
                res.slope = a.slope + b.slope;

            return res;
        }

        /**
         * @notice Calculates the decayed voting power from an absolute veBalance at a given timestamp.
         * @dev Assumes absolute veBalance model: bias = slope * expiry (effective end timestamp).
         *      Voting power = bias - slope * timestamp.
         *      Saturates to 0 if fully decayed (timestamp >= expiry) to prevent underflow/reversion.
         * @param a The veBalance struct {uint128 bias, uint128 slope}.
         * @param timestamp The absolute timestamp for decay calculation.
         * @return The decayed voting power 
         */
        function _getValueAt(DataTypes.VeBalance memory a, uint256 timestamp) internal pure returns (uint256) {
            uint256 decay = a.slope * timestamp;

            if(a.bias <= decay) return 0;

            // offset inception inflation
            return a.bias - decay;
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

            // if last checkpoint is in the same epoch as incoming; overwrite [veBalance should be updated outside this function]
            if(length > 0 && lockHistory_[length - 1].lastUpdatedAt == currentEpochStart) {
                lockHistory_[length - 1].veBalance = veBalance;
            } else {
                // new checkpoint for new epoch: set lastUpdatedAt
                // forge-lint: disable-next-line(unsafe-typecast)
                lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
            }
        }

        /// @dev Finds the largest eTime <= targetETime with a valid VeBalance in the history mapping.
        /// @return The found eTime (0 if none).
        function _findClosestPastETime(
            mapping(uint256 => DataTypes.VeBalance) storage accountHistory,
            uint256 targetETime
        ) internal view returns (uint256) {
            uint256 epochDuration = EpochMath.EPOCH_DURATION;
            uint256 targetEpoch = targetETime / epochDuration;

            uint256 low;
            uint256 high = targetEpoch;
            uint256 latestEpoch;

            while (low <= high) {
                uint256 mid = low + (high - low) / 2;
                uint256 midETime = mid * epochDuration;

                if (accountHistory[midETime].bias > 0 || accountHistory[midETime].slope > 0) { 
                    latestEpoch = mid;
                    low = mid + 1;  // Search for a later one.
                } else {
                    if (mid == 0) break;
                    high = mid - 1;  // Search earlier.
                }
            }

            return latestEpoch * epochDuration;
        }

        /**
         * @dev Simulates forward application of slope changes in view for absolute bias systems.
         *      Loops over potential eTimes (multiples of EPOCH_DURATION) and applies adjustments if any.
         *      Assumes eTimes are aligned to multiples of EPOCH_DURATION.
         * @param ve The starting VeBalance (will be modified in memory).
         * @param startETime The starting eTime (exclusive for changes).
         * @param targetTime The target timestamp to forward to (inclusive for changes).
         * @param accountSlopeChanges The slopeChanges mapping to read from.
         * @return The updated VeBalance after simulated forwards.
         */
        function _viewForwardAbsolute(
            DataTypes.VeBalance memory ve,
            uint256 startETime,
            uint256 targetTime,
            mapping(uint256 => uint256) storage accountSlopeChanges
        ) internal view returns (DataTypes.VeBalance memory) {
            
            // calc. next eTime
            uint256 epochDuration = EpochMath.EPOCH_DURATION;
            uint256 nextETime = startETime + epochDuration;      // next eTime is always a multiple of EPOCH_DURATION

            // loop over potential eTimes and apply adjustments, if any
            while (nextETime <= targetTime) {
                // get the slope change for the next eTime
                uint256 dslope = accountSlopeChanges[nextETime];
                if (dslope > 0) {
                    ve.bias -= uint128(dslope * nextETime);  // Absolute adjustment (cast to uint128 assuming no overflow).
                    ve.slope -= uint128(dslope);
                }
                nextETime += epochDuration;
            }

            return ve;
        }

//-------------------------------Modifiers---------------------------------------------------------------

        // not using internal function: only 1 occurrence of this modifier
        modifier onlyMonitorRole(){
            require(ACCESS_CONTROLLER.isMonitor(msg.sender), Errors.OnlyCallableByMonitor());
            _;
        }

        // not using internal function: only 1 occurrence of this modifier
        modifier onlyCronJobRole() {
            require(ACCESS_CONTROLLER.isCronJob(msg.sender), Errors.OnlyCallableByCronJob());
            _;
        }

        modifier onlyVotingEscrowMocaAdmin(){
            require(ACCESS_CONTROLLER.isVotingEscrowMocaAdmin(msg.sender), Errors.OnlyCallableByVotingEscrowMocaAdmin());
            _;
        }

        // not using internal function: only 2 occurrences of this modifier
        modifier onlyGlobalAdminRole(){
            require(ACCESS_CONTROLLER.isGlobalAdmin(msg.sender), Errors.OnlyCallableByGlobalAdmin());
            _;
        }
        
        // not using internal function: only 1 occurrence of this modifier
        modifier onlyEmergencyExitHandlerRole(){
            require(ACCESS_CONTROLLER.isEmergencyExitHandler(msg.sender), Errors.OnlyCallableByEmergencyExitHandler());
            _;
        }


        // references AddressBook for contract address; not a role
        // not using internal function: only 2 occurrences of this modifier
        // forge-lint: disable-next-item(all)
        modifier onlyVotingControllerContract() {
            require(msg.sender == VOTING_CONTROLLER, Errors.OnlyCallableByVotingControllerContract());
            _;
        }

//-------------------------------Block: transfer/transferFrom -----------------------------------------

    function transfer(address, uint256) public pure override returns (bool) {
        revert Errors.IsNonTransferable();
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert Errors.IsNonTransferable();
    }

//-------------------------------Risk management--------------------------------------------------------

    /**
        * @notice Pause contract. Cannot pause once frozen
        */
    function pause() external whenNotPaused onlyMonitorRole {
        _pause();
    }

    /**
        * @notice Unpause pool. Cannot unpause once frozen
        */
    function unpause() external whenPaused onlyGlobalAdminRole {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
        * @notice To freeze the pool in the event of something untoward occurring
        * @dev Only callable from a paused state, affirming that staking should not resume
        *      Nothing to be updated. Freeze as is.
        *      Enables emergencyExit() to be called.
        */
    function freeze() external whenPaused onlyGlobalAdminRole {
        require(isFrozen == 0, Errors.IsFrozen());

        isFrozen = 1;
        emit Events.ContractFrozen();
    }  

    /**
        * @notice Returns principal tokens (esMoca, Moca) to users for specified locks during emergency exit.
        * @dev Only callable by the Emergency Exit Handler when the contract is frozen.
        *      Ignores all contract state updates except returning principals; assumes system failure.
        *      NOTE: Expectation is that VotingController is paused or undergoing emergencyExit(), to prevent phantom votes.
                    Phantom votes since we do not update state when returning principals; too complicated and not worth the effort.
        * @param lockIds Array of lock IDs for which principals should be returned.
        * @custom:security No state updates except principal return; system is assumed failed.
        */
    function emergencyExit(bytes32[] calldata lockIds) external onlyEmergencyExitHandlerRole returns(uint256, uint256, uint256){
        require(isFrozen == 1, Errors.NotFrozen());
        require(lockIds.length > 0, Errors.InvalidAmount());

        // Track totals for single event emission
        uint256 totalMocaReturned;
        uint256 totalEsMocaReturned;
        uint256 validLocks;
        
        // get user's veBalance for each lock
        for(uint256 i; i < lockIds.length; ++i) {
            DataTypes.Lock memory lock = locks[lockIds[i]];

            // Skip invalid/already processed locks
            if(lock.owner == address(0) || lock.isUnlocked) continue;            
            
            // Determine who holds the veMOCA tokens
            bool isDelegated = lock.delegate != address(0);
            address veHolder = isDelegated ? lock.delegate : lock.owner;

            // Calculate expected veMOCA to burn
            uint256 veMocaToBurn = uint256(_convertToVeBalance(lock).bias);

            // Burn veMOCA tokens
            uint256 actualBalance = balanceOf(veHolder);
            uint256 burnAmount = veMocaToBurn > actualBalance ? actualBalance : veMocaToBurn;
            if (burnAmount > 0) _burn(veHolder, burnAmount);                
            // Note: If burnAmount < veMocaToBurn, we accept the discrepancy
            // Emergency exit prioritizes returning principals over perfect accounting

            // direct storage updates - only write changed fields
            if(lock.moca > 0) {
                uint256 mocaToReturn = lock.moca;
                delete lock.moca;

                TOTAL_LOCKED_MOCA -= mocaToReturn;  
                totalMocaReturned += mocaToReturn;

                // transfer moca [wraps if transfer fails within gas limit]
                _transferMocaAndWrapIfFailWithGasLimit(WMOCA, lock.owner, mocaToReturn, MOCA_TRANSFER_GAS_LIMIT);
            }

            if(lock.esMoca > 0) {
                uint256 esMocaToReturn = lock.esMoca;
                delete lock.esMoca;

                TOTAL_LOCKED_ESMOCA -= esMocaToReturn;
                totalEsMocaReturned += esMocaToReturn;

                ESMOCA.safeTransfer(lock.owner, esMocaToReturn);
            }

            // mark exited 
            lock.isUnlocked = true;

            // STORAGE: update lock
            locks[lockIds[i]] = lock;

            ++validLocks;
        }

        if(validLocks > 0) {
            emit Events.EmergencyExit(lockIds, validLocks, totalMocaReturned, totalEsMocaReturned);
        }

        return (validLocks, totalMocaReturned, totalEsMocaReturned);
    }

//-------------------------------Internal: view-----------------------------------------------------

        // _updateGlobal, but w/o the storage changes
        function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint256 lastUpdatedAt, uint256 currentEpochStart) internal view returns (DataTypes.VeBalance memory) {       
            // if lastUpdate was within current epoch: no new epoch, no new checkpoint
            if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

            // first time: no prior updates 
            if(lastUpdatedAt == 0) {
                lastUpdatedAt = currentEpochStart;   // move forward the anchor point to skip empty epochs
                return veGlobal_;
            }

            // update global veBalance
            while (lastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                unchecked { lastUpdatedAt += EpochMath.EPOCH_DURATION; }                  

                // decrement decay for this epoch & apply scheduled slope changes
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
            }

            // return updated global veBalance
            return (veGlobal_);
        }

        // _updateAccount, but w/o the storage changes | forDelegated: user's {true:delegatedAccount, false: personalAccount}
        function _viewAccount(address account, bool forDelegated) internal view returns (DataTypes.VeBalance memory) {
            // init account veBalance
            DataTypes.VeBalance memory veBalance;

            // Select storage pointers based on account type; to avoid repeated checks
            (
                mapping(address => mapping(uint256 => DataTypes.VeBalance)) storage accountHistory,
                mapping(address => mapping(uint256 => uint256)) storage accountSlopeChanges,
                mapping(address => uint256) storage accountLastUpdatedTimestamp
            ) = forDelegated
                ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp)
                : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);

            // Get the appropriate last updated timestamp
            uint256 accountLastUpdatedAt = accountLastUpdatedTimestamp[account];
            
            // account has no locks created: return empty veBalance [contract deployed after T0: nothing can be done at T0]
            if(accountLastUpdatedAt == 0) return veBalance;

            // load account's previous veBalance from history
            veBalance = accountHistory[account][accountLastUpdatedAt];
            
            // get current epoch start
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart(); 
            
            // both global and account are already up to date: return
            if(accountLastUpdatedAt >= currentEpochStart) return veBalance;

            // update account veBalance to current epoch
            while (accountLastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                unchecked { accountLastUpdatedAt += EpochMath.EPOCH_DURATION; }

                // decrement decay for this epoch & apply scheduled slope changes
                uint256 expiringSlope = accountSlopeChanges[account][accountLastUpdatedAt];
                veBalance = _subtractExpired(veBalance, expiringSlope, accountLastUpdatedAt);
            }

            return veBalance;
        }

//-------------------------------View functions-----------------------------------------
        
        /**
         * @notice Returns the current total supply of voting escrowed tokens (veTokens), reflecting all decay and scheduled changes up to the latest epoch.
         * @dev Overrides ERC20 `totalSupply()`. 
         *      Ensures the global veBalance is updated to the current epoch before returning the value.
         *      Returns zero if the contract is frozen.
         * @return totalSupply_ The up-to-date total supply of veTokens at the current block timestamp.
         */
        function totalSupply() public view override returns (uint256) {
            require(isFrozen == 0, Errors.IsFrozen());  

            // update global veBalance to current epoch
            DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, EpochMath.getCurrentEpochStart());
            // return value at current timestamp
            return _getValueAt(veGlobal_, uint128(block.timestamp));
        }

        /**
         * @notice Returns the projected total supply of voting escrowed tokens (veTokens) at a future timestamp.
         * @dev Forward-looking calculation; does not perform a historical search.
         *      For historical queries, use the totalSupplyAt[] mapping, which is limited to epoch boundaries.
         *      Returns zero if the contract is frozen.
         * @param time The future timestamp for which the total supply is projected.
         * @return The projected total supply of veTokens at the specified future timestamp.
         */
        function totalSupplyInFuture(uint128 time) public view returns (uint256) {
            require(isFrozen == 0, Errors.IsFrozen());  
            require(time > block.timestamp, "Timestamp is in the past");

            DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, EpochMath.getEpochStartForTimestamp(time));
            return _getValueAt(veGlobal_, time);
        }

//-------------------------------user: balanceOf, balanceOfAt -----------------------------------------

        /**
         * @notice Returns the current personal voting power (veBalance) of a user.
         * @dev Overrides the ERC20 `balanceOf()` function selector; therefore forced to return personal voting power.
         *      Returns zero if the contract is frozen.
         * @param user The address of the user whose veBalance is being queried.
         * @return The current personal veBalance of the user.
         */
        function balanceOf(address user) public view override returns (uint256) {
            require(user != address(0), Errors.InvalidAddress());
            require(isFrozen == 0, Errors.IsFrozen());  

            return balanceOf(user, false);  // Only personal voting power (non-delegated locks)
        }

        /**
         * @notice Returns the current voting power (veBalance) of a user
         * @dev Returns zero if the contract is frozen.
         * @param user The address of the user whose veBalance is being queried.
         * @param forDelegated If true: delegated veBalance; if false: personal veBalance
         * @return The current veBalance of the user.
         */
        function balanceOf(address user, bool forDelegated) public view returns (uint256) {
            require(user != address(0), Errors.InvalidAddress());
            require(isFrozen == 0, Errors.IsFrozen()); 

            DataTypes.VeBalance memory veBalance = _viewAccount(user, forDelegated);
            return _getValueAt(veBalance, uint128(block.timestamp));
        }

        // note: used by VotingController for vote()
        /**
         * @notice Returns the user's voting power (veBalance) at the end of a specific epoch.
         * @dev Useful for historical queries and reward calculations. Returns zero if the contract is frozen.
         * @param user The address of the user whose veBalance is being queried.
         * @param epoch The epoch number for which the veBalance is requested.
         * @param forDelegated If true: returns delegated veBalance; if false: returns personal veBalance.
         * @return The user's veBalance at the end of the specified epoch.
         */
        function balanceAtEpochEnd(address user, uint256 epoch, bool forDelegated) external view returns (uint256) {
            require(isFrozen == 0, Errors.IsFrozen());
            require(user != address(0), Errors.InvalidAddress());

            uint256 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
            uint256 epochEndTime = EpochMath.getEpochEndTimestamp(epoch);

            mapping(uint256 => DataTypes.VeBalance) storage accountHistory = forDelegated ? delegateHistory[user] : userHistory[user];

            // Find the largest eTime <= epochStartTime with a valid checkpoint.
            uint256 foundETime = _findClosestPastETime(accountHistory, epochStartTime);

            // If no checkpoint found (foundETime == 0 and slot is unset), return 0.
            if (foundETime == 0 && accountHistory[0].bias == 0) return 0;

            // Get the VeBalance at the found eTime.
            DataTypes.VeBalance memory veBalance = accountHistory[foundETime];

            // Choose the appropriate slopeChanges mapping.
            mapping(uint256 => uint256) storage accountSlopeChanges = forDelegated ? delegateSlopeChanges[user] : userSlopeChanges[user];

            // Simulate forward application of slope changes from foundETime (exclusive) to epochEndTime (inclusive).
            veBalance = _viewForwardAbsolute(veBalance, foundETime, epochEndTime, accountSlopeChanges);

            // Calculate the value at epochEndTime (assuming _getValueAt is bias - slope * time).
            return _getValueAt(veBalance, epochEndTime);
        }

        //Note: used by VotingController for claimRewardsFromDelegate() | returns userVotesAllocatedToDelegateForEpoch
        /**
         * @notice Retrieves the delegated veBalance for a user and delegate at the end of a specific epoch.
         * @dev Used by VotingController.claimRewardsFromDelegate() to determine the user's delegated voting power for reward calculations.
         *      Uses binary search over possible epoch starts to find the closest prior checkpoint.
         *      Then simulates forward application of any scheduled slope changes up to the epoch end
         *      Returns the decayed value at epochEndTime (bias - slope * epochEndTime).
         * @param user The address of the user whose delegated veBalance is being queried.
         * @param delegate The address of the delegate to whom voting power was delegated.
         * @param epoch The epoch number for which the delegated veBalance is requested.
         * @return The delegated veBalance value at the end of the specified epoch.
        */
        function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint128) {
            require(user != address(0), Errors.InvalidAddress());
            require(delegate != address(0), Errors.InvalidAddress());
            require(isFrozen == 0, Errors.IsFrozen());  

            uint256 epochStartTime = EpochMath.getEpochStartTimestamp(epoch);
            uint256 epochEndTime = EpochMath.getEpochEndTimestamp(epoch);

            mapping(uint256 => DataTypes.VeBalance) storage accountHistory = delegatedAggregationHistory[user][delegate];

            // Find the largest eTime <= epochStartTime with a valid checkpoint.
            uint256 foundETime = _findClosestPastETime(accountHistory, epochStartTime);

            // If no checkpoint found (foundETime == 0 and slot is unset), return 0.
            if (foundETime == 0 && accountHistory[0].bias == 0) return 0;

            // Get the VeBalance at the found eTime.
            DataTypes.VeBalance memory veBalance = accountHistory[foundETime];

            // Simulate forward application of slope changes from foundETime (exclusive) to epochEndTime (inclusive).
            veBalance = _viewForwardAbsolute(veBalance, foundETime, epochEndTime, userDelegateSlopeChanges[user][delegate]);

            // Calculate the value at epochEndTime (assuming _getValueAt is bias - slope * time).
            return _getValueAt(veBalance, epochEndTime);
        }


//-------------------------------lock: getLockHistoryLength, getLockCurrentVeBalance, getLockCurrentVotingPower, getLockVeBalanceAt ---------

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
         * @dev
         *   - Converts the lock's principal amounts to veBalance using _convertToVeBalance.
         *   - Returns the veBalance at the current timestamp.
         * @param lockId The ID of the lock whose veBalance is being queried.
         * @return The current veBalance of the lock as a DataTypes.VeBalance struct.
         */
        function getLockCurrentVeBalance(bytes32 lockId) external view returns (DataTypes.VeBalance memory) {
            // equivalent to lockHistory[lockId][lockHistory.length - 1].veBalance | save on calc. array length
            return _convertToVeBalance(locks[lockId]);
        }

        /**
         * @notice Returns the current voting power of a lock.
         * @dev
         *   - Converts the lock's principal amounts to veBalance using _convertToVeBalance.
         *   - Returns the voting power at the current timestamp using _getValueAt.
         * @param lockId The ID of the lock whose voting power is being queried.
         * @return The current voting power of the lock as a uint256.
         */
        function getLockCurrentVotingPower(bytes32 lockId) external view returns (uint256) {
            return _getValueAt(_convertToVeBalance(locks[lockId]), uint128(block.timestamp));
        }

        /**
         * @notice Retrieves the veBalance of a lock at a specific timestamp.
         * @dev Performs a historical search over epoch-wise stored veBalances.
         *      Finds the checkpoint with the closest epoch boundary not exceeding the given timestamp,
         *      then interpolates the veBalance at that point.
         * @param lockId The ID of the lock to query.
         * @param timestamp The timestamp for which the veBalance is requested.
         * @return The veBalance of the lock at the specified timestamp.
         */
        function getLockVeBalanceAt(bytes32 lockId, uint128 timestamp) external view returns (uint256) {
            require(timestamp <= block.timestamp, Errors.InvalidTimestamp());

            DataTypes.Checkpoint[] storage history = lockHistory[lockId];
            uint256 length = history.length;
            if(length == 0) return 0;
            
            // binary search to find the checkpoint with timestamp closest, but not larger than the input time
            uint256 min;
            uint256 max = length - 1;
            
            // if timestamp is earlier than the first checkpoint, return zero balance
            if(timestamp < history[0].lastUpdatedAt) return 0;
            
            // if timestamp is at or after the last checkpoint, return the last checkpoint
            if(timestamp >= history[max].lastUpdatedAt) return _getValueAt(history[max].veBalance, timestamp);
            
            // binary search
            unchecked {
                while (min < max) {
                    uint256 mid = (min + max + 1) / 2; // cannot overflow: max < 2^256
                    if(history[mid].lastUpdatedAt <= timestamp) {
                        min = mid;
                    } else {
                        max = mid - 1;
                    }
                }
            }
                
            return _getValueAt(history[min].veBalance, timestamp);
        }
}