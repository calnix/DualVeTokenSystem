// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// libraries
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";

import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";


// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";


/**
 * @title VotingEscrowMoca
 * @author Calnix [@cal_nix]
 * @notice VotingEscrowMoca is a dual-token, quad-accounting type veToken system.
 * @dev
 *      - VotingEscrowMoca is a non-transferable token representing voting power.
 *      - The amount of veMOCA received increases with both the amount of MOCA locked and the length of the lock period, and decays linearly as the lock approaches expiry.
 *      - This contract supports delegation, historical checkpointing, and integration with protocol governance.
*/


/** NOTE
    - operates on eTime as timestamp
    - some fns call mappings via epochEndTimestamp or epochStartTimestamp
    - make sure that the timestamp is correct: start/end of epoch; inclusive, exclusive (<= or <)
 */

contract VotingEscrowMoca is ERC20, Pausable {
        using SafeERC20 for IERC20;

        // protocol yellow pages
        IAddressBook internal immutable _addressBook;


        // global principal
        uint256 public totalLockedMoca;
        uint256 public totalLockedEsMoca;

        // global veBalance
        DataTypes.VeBalance public veGlobal;
        uint256 public lastUpdatedTimestamp;  
        
        uint256 internal _isFrozen;

    //-------------------------------mapping-----------------------------------------------------

        // lock
        mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
        // Checkpoints are added upon every state transition; not by epoch. use binary search to find the checkpoint for any eTime
        mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;


        // scheduled global slope changes
        mapping(uint256 eTime => uint256 slopeChange) public slopeChanges;
        // saving totalSupply checkpoint for each epoch
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


    //-------------------------------constructor-------------------------------------------------

        constructor(address addressBook) ERC20("veMoca", "veMoca") {
            _addressBook = IAddressBook(addressBook);

            // note: has to be done on AddressBook contract after deployment
            //_addressBook.getAddress(Constants.VOTING_CONTROLLER);
        }

    //-------------------------------user functions---------------------------------------------

        // note: locks are booked to currentEpochStart
        /**
         * @notice Creates a new lock with the specified expiry, moca, esMoca, and optional delegate.
         * @dev The delegate parameter is optional and can be set to the zero address if not delegating.
         * @param expiry The timestamp when the lock will expire.
         * @param moca The amount of MOCA to lock.
         * @param esMoca The amount of esMOCA to lock.
         * @param delegate The address to delegate voting power to (optional).
         * @return lockId The unique identifier of the created lock.
        */
        function createLock(uint128 expiry, uint256 moca, uint256 esMoca, address delegate) external whenNotPaused returns (bytes32) {
            return _createLockFor(msg.sender, expiry, moca, esMoca, delegate);
        }

        // must have at least 2 Epoch left to increase amount; 
        // Users can only stake more into locks that have at least 1 Epoch left
        function increaseAmount(bytes32 lockId, uint128 mocaToIncrease, uint128 esMocaToIncrease) external whenNotPaused {
            DataTypes.Lock memory oldLock = locks[lockId];

            require(oldLock.lockId != bytes32(0), "NoLockFound");
            require(oldLock.owner == msg.sender, "Only the creator can increase the amount");
            
            // must have at least 2 Epoch left to increase amount: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            require(oldLock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");


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

            // copy old lock: update amount
            DataTypes.Lock memory updatedLock = oldLock;
                updatedLock.moca += mocaToIncrease;
                updatedLock.esMoca += esMocaToIncrease;
                
            // calc. delta: schedule slope changes + book new veBalance + mints additional veMoca to account | updates veGlobal
            DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veAccount, oldLock, updatedLock, account, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);

            // storage: update lock + checkpoint lock
            locks[lockId] = updatedLock;
            _pushCheckpoint(lockHistory[lockId], newVeBalance, uint128(currentEpochStart));  
    

            // emit event

            // STORAGE: increment global totalLockedMoca/EsMoca
            // TRANSFER: tokens to contract
            if(mocaToIncrease > 0){
                totalLockedMoca += mocaToIncrease;
                _mocaToken().safeTransferFrom(msg.sender, address(this), mocaToIncrease);
            }
            if(esMocaToIncrease > 0){
                totalLockedEsMoca += esMocaToIncrease;
                _esMocaToken().safeTransferFrom(msg.sender, address(this), esMocaToIncrease);
            }
        }
        
        // must have at least 2 Epoch left to increase duration; 
        // newExpiry must be on a epoch boundary
        function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external whenNotPaused {
            // cannot extend duration arbitrarily; must be step-wise matching epoch boundaries
            require(EpochMath.isValidEpochTime(durationToIncrease), "Duration must be on a epoch boundary");

            DataTypes.Lock memory oldLock = locks[lockId];

            require(oldLock.lockId != bytes32(0), "NoLockFound");
            require(oldLock.owner == msg.sender, "Only the creator can increase the duration");
            require(oldLock.expiry > block.timestamp, "Lock has expired");
            
            // must have at least 2 Epoch left to increase duration: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            uint256 newExpiry = oldLock.expiry + durationToIncrease;
            require(newExpiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");

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

        // Withdraws principals of an expired lock | ve will be burnt, altho veBalance will return 0 on expiry
        function unlock(bytes32 lockId) external whenNotPaused {
            DataTypes.Lock memory lock = locks[lockId];

            require(lock.lockId != bytes32(0), "LockNotFound");
            require(lock.expiry > block.timestamp, "Lock not expired");
            require(lock.isUnlocked == false, "Lock already unlocked");
            require(lock.owner == msg.sender, "Only creator can unlock");

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

            // burn originally issued veMoca
            uint256 mintedVeMoca = _convertToVeBalance(lock).bias;
            _burn(account, mintedVeMoca);

            // emit event

            // return principals to lock.owner
            if(lock.moca > 0) _mocaToken().safeTransfer(lock.owner, lock.moca);
            if(lock.esMoca > 0) _esMocaToken().safeTransfer(lock.owner, lock.esMoca);        
        }

    //-------------------------------user delegate functions-------------------------------------

        /** note: consider creating _updateAccount(). then can streamline w/ _updateGlobal, _updateAccount(user), _updateAccount(delegate) | 
            but there must be a strong case for need to have _updateAccount as a standalone beyond delegate
            as gas diff is not significant
        */


        /** Problem: user can vote, then delegate
            ⦁	sub their veBal, add to delegate veBal
            ⦁	_vote only references `veMoca.balanceOfAt(caller, epochEnd, isDelegated)`
            ⦁	so this creates a double-voting exploit
            Solution: forward-delegate. impacts on next epoch.
            This problem does not occur when users' are createLock(isDelegated) 
        */

        //note: use array for locks
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
            require(delegate != msg.sender, "Cannot delegate to self");
            require(isRegisteredDelegate[delegate], "Delegate not registered"); // implicit address(0) check: newDelegate != address(0)

            DataTypes.Lock memory lock = locks[lockId];
            
            // sanity check: lock
            require(lock.lockId != bytes32(0), "LockNotFound");
            require(lock.owner == msg.sender, "Only the creator can delegate");

            // lock must have at least 2 more epoch left, so that the delegate can vote in the next epoch [1 epoch for delegation, 1 epoch for non-zero voting power]    
            // allow the delegate to meaningfully vote for the next epoch        
            require(lock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");

            // Update user & global: account for decay since lastUpdate and any scheduled slope changes | false since lock is not yet delegated
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint256 currentEpochStart,,) = _updateAccountAndGlobal(msg.sender, false);
            uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // get the lock's current veBalance [no checkpoint required as lock attributes have not changed]
            DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 

            // Remove specified lock from user's aggregated veBalance | note: this is to prevent user from being able to vote with delegated lock
            veUser = _sub(veUser, lockVeBalance);
            userHistory[msg.sender][nextEpochStart] = veUser;
            userSlopeChanges[msg.sender][lock.expiry] -= lockVeBalance.slope;


            // Update delegate: required before adding the lock to delegate's balance [ignore global, since it was handled in earlier update]
            // true: update delegate's aggregated veBalance; not personal
            (, DataTypes.VeBalance memory veDelegate,,,) = _updateAccountAndGlobal(delegate, true);
            
            // Add the lock to delegate's delegated balance
            veDelegate = _add(veDelegate, lockVeBalance);
            delegateHistory[delegate][nextEpochStart] = veDelegate;
            delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;

            // transfer veMoca tokens from user to delegate 
            _transfer(msg.sender, delegate, lockVeBalance.bias);

            // STORAGE: mark lock as delegated
            lock.delegate = delegate;
            locks[lockId] = lock;

            // delegatedAggregationHistory tracks how much veBalance a user has delegated out; to be used for rewards accounting by VotingController
            // note: delegated veBalance booked to nextEpochStart
            delegatedAggregationHistory[msg.sender][delegate][nextEpochStart] = _add(delegatedAggregationHistory[msg.sender][delegate][nextEpochStart], lockVeBalance);


            // STORAGE: update global state
            veGlobal = veGlobal_;   

            // Emit event
            //emit LockDelegated(lockId, msg.sender, delegate);
        }

        //note: use array for locks
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
            require(lock.lockId != bytes32(0), "NoLockFound");
            require(lock.delegate != address(0), "Lock is not delegated");
            require(lock.owner == msg.sender, "Only creator can undelegate");
            require(lock.isUnlocked == false, "Principals returned");

            
            //note: intentionally not enforced: delegates may have unregistered, so users must always be able to reclaim their locks
            //require(isRegisteredDelegate[delegate], "Delegate not registered");

            //note: intentionally not enforced: expired locks should be undelegated
            //require(lock.expiry > block.timestamp, "Lock expired");

            
            // Update delegate: apply decay since lastUpdate and any scheduled slope changes [required before removing the lock from delegate's balance]
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veDelegate, uint256 currentEpochStart,,) = _updateAccountAndGlobal(lock.delegate, true);
            uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // get the lock's current veBalance [no checkpoint required as lock attributes have not changed]
            DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 

            // Remove the lock from delegate's aggregated veBalance
            veDelegate = _sub(veDelegate, lockVeBalance);
            delegateHistory[lock.delegate][nextEpochStart] = veDelegate;
            delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;

            // Update user: false: update user's personal aggregated veBalance; not delegated veBalance [required before we can book lock's veBalance to user]
            (, DataTypes.VeBalance memory veUser,,,) = _updateAccountAndGlobal(msg.sender, false);

            // Add the lock to user's personal aggregated veBalance
            veUser = _add(veUser, lockVeBalance);
            userHistory[msg.sender][nextEpochStart] = veUser;
            userSlopeChanges[msg.sender][lock.expiry] += lockVeBalance.slope;

            // transfer veMoca tokens from user to delegate 
            _transfer(lock.delegate, msg.sender, lockVeBalance.bias);

            // delegatedAggregationHistory tracks how much veBalance a user has delegated out; to be used for rewards accounting by VotingController
            // note: delegated veBalance booked to nextEpochStart
            delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart] = _sub(delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart], lockVeBalance);

            // STORAGE: update global state
            veGlobal = veGlobal_;

            // STORAGE: delete delegate address from lock
            delete lock.delegate;
            locks[lockId] = lock;

            // EMIT EVENT
            //emit LockUndelegated(lockId, msg.sender, lock.delegate);
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
            require(newDelegate != msg.sender, "Cannot delegate to self");
            require(isRegisteredDelegate[newDelegate], "New delegate not registered");      // implicit address(0) check: newDelegate != address(0)

            DataTypes.Lock memory lock = locks[lockId];

            // sanity check: lock
            require(lock.lockId != bytes32(0), "NoLockFound");
            require(lock.owner == msg.sender, "Only the creator can change delegate");
            require(lock.delegate != newDelegate, "Cannot switch to the same delegate");

            // lock must have at least 2 more epoch left, so that the delegate can vote in the next epoch [1 epoch for delegation, 1 epoch for non-zero voting power]            
            // allow the delegate to meaningfully vote for the next epoch
            require(lock.expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");

            // Update current delegate: account for decay since lastUpdate and any scheduled slope changes [required before removing the lock from the current delegate]
            // true: update current delegate's aggregated veBalance; not personal
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veCurrentDelegate, uint256 currentEpochStart,,) = _updateAccountAndGlobal(lock.delegate, true);
            uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // get lock's current veBalance [no checkpoint required as lock attributes have not changed]
            DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 
            
            // Remove lock from current delegate
            veCurrentDelegate = _sub(veCurrentDelegate, lockVeBalance);
            delegateHistory[lock.delegate][nextEpochStart] = veCurrentDelegate;
            delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;

            // Update new delegate: required before adding the lock to delegate's balance [ignore global, since it was handled in earlier update]
            // true: update new delegate's aggregated veBalance; not personal
            (, DataTypes.VeBalance memory veNewDelegate,,,) = _updateAccountAndGlobal(newDelegate, true);
            
            // Add lock to new delegate
            veNewDelegate = _add(veNewDelegate, lockVeBalance);
            delegateHistory[newDelegate][nextEpochStart] = veNewDelegate;
            delegateSlopeChanges[newDelegate][lock.expiry] += lockVeBalance.slope;

            // Transfer veMoca tokens from current delegate to new delegate
            _transfer(lock.delegate, newDelegate, lockVeBalance.bias);

            // delegatedAggregationHistory tracks how much veBalance a user has delegated out; to be used for rewards accounting by VotingController
            // note: delegated veBalance booked to nextEpochStart
            delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart] = _sub(delegatedAggregationHistory[msg.sender][lock.delegate][nextEpochStart], lockVeBalance);
            delegatedAggregationHistory[msg.sender][newDelegate][nextEpochStart] = _add(delegatedAggregationHistory[msg.sender][newDelegate][nextEpochStart], lockVeBalance);

            // STORAGE: update lock
            lock.delegate = newDelegate;
            locks[lockId] = lock;
            
            // STORAGE: update global state
            veGlobal = veGlobal_;

            // EMIT EVENT
            //emit DelegateChanged(lockId, msg.sender, lock.delegate, newDelegate);
        }


    //-------------------------------Admin function: createLockFor()---------------------------------------------

        // when creating lock onBehalfOf - we will not delegate for the user
        function createLockFor(address user, uint128 expiry, uint256 moca, uint256 esMoca) external onlyCronJobRole whenNotPaused returns (bytes32) { 
            return _createLockFor(user, expiry, moca, esMoca, address(0));
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

    //-------------------------------Internal: update functions----------------------------------------------       
        
        // delegate can be address(0)
        // lock must last for at least 2 Epochs: to meaningfully vote for the next epoch [we are sure] 
        function _createLockFor(address user, uint128 expiry, uint256 moca, uint256 esMoca, address delegate) internal returns (bytes32) {
            require(user != address(0), Errors.InvalidUser());
            require(EpochMath.isValidEpochTime(expiry), Errors.InvalidExpiry());

            // minimum total amount to avoid flooring to zero
            uint256 totalAmount = moca + esMoca;
            require(totalAmount >= Constants.MIN_LOCK_AMOUNT, Errors.InvalidAmount());

            require(expiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, Errors.InvalidLockDuration());
            require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, Errors.InvalidLockDuration());

            // must have at least 2 Epoch left to create lock: to meaningfully vote for the next epoch  
            // this is a result of VotingController.sol's forward-decay: benchmarking voting power to the end of the epoch       
            require(expiry > EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), "Lock expires too soon");

            bool isDelegated;
            // if delegate is specified: check that delegate is registered
            if (delegate > address(0)) {
                require(isRegisteredDelegate[delegate], "Delegate not registered");
                require(delegate != user, "Cannot delegate to self");
                isDelegated = true;
            }

            // --------- create lock ---------

                // vaultId generation
                bytes32 lockId;
                {
                    uint256 salt = block.number;
                    lockId = _generateVaultId(salt, user);
                    while (locks[lockId].lockId != bytes32(0)) lockId = _generateVaultId(--salt, user);      // If lockId exists, generate new random Id
                }

                DataTypes.Lock memory newLock;
                    newLock.lockId = lockId; 
                    newLock.owner = user;
                    newLock.delegate = delegate;                //note: might be setting this to zero; but no point doing if(delegate != address(0))
                    newLock.moca = uint128(moca);
                    newLock.esMoca = uint128(esMoca);
                    newLock.expiry = expiry;
                // STORAGE: book lock
                locks[lockId] = newLock;

                // STORAGE: get lock's veBalance + book checkpoint into lockHistory mapping 
                DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);
                _pushCheckpoint(lockHistory[lockId], veIncoming, EpochMath.getCurrentEpochStart()); 

                // emit
                emit Events.LockCreated(lockId, user, delegate, moca, esMoca, expiry);

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

            // MINT: veMoca to account
            _mint(account, veIncoming.bias);

            // STORAGE: increment global totalLockedMoca/EsMoca
            // TRANSFER: tokens to contract
            if (moca > 0) {
                totalLockedMoca += moca;
                _mocaToken().safeTransferFrom(msg.sender, address(this), moca);
            } 
            if (esMoca > 0) {
                totalLockedEsMoca += esMoca;
                _esMocaToken().safeTransferFrom(msg.sender, address(this), esMoca);
            } 

            return lockId;
        }

        ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
        function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
            return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
        }

        // does not update veGlobal into storage; calcs the latest veGlobal. updates lastUpdatedTimestamp, totalSupplyAt[]
        function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint256 lastUpdatedAt, uint256 currentEpochStart) internal returns (DataTypes.VeBalance memory) {       
            // nothing to update: lastUpdate was within current epoch 
            if(lastUpdatedAt >= currentEpochStart) {
                // no new epoch, no new checkpoint
                return (veGlobal_); 
            } 

            // first time: no prior updates | set global lastUpdatedTimestamp
            if(lastUpdatedAt == 0) {
                lastUpdatedTimestamp = currentEpochStart;   // move forward the anchor point to skip empty epochs
                return veGlobal_;
            }

            // there are updates to be done: update global veBalance
            while (lastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

                // apply scheduled slope reductions and handle decay for expiring locks
                veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
                // after removing expired locks, calc. and book current ve supply for the epoch
                totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);
            }

            // set final lastUpdatedTimestamp
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
                mapping(address => uint256) storage accountLastUpdatedMapping
            ) 
                = isDelegate ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);

            // CACHE: global veBalance
            DataTypes.VeBalance memory veGlobal_ = veGlobal;
            uint256 lastUpdatedTimestamp_ = lastUpdatedTimestamp;
        
            // get current epoch start
            uint256 currentEpochStart = EpochMath.getCurrentEpochStart(); 

            // get account's lastUpdatedTimestamp: {user | delegate}
            uint256 accountLastUpdatedAt = accountLastUpdatedMapping[account];

            // init empty veBalance
            DataTypes.VeBalance memory veAccount;

            // account's first time: no prior account updates | only update global
            if (accountLastUpdatedAt == 0) {
                
                // set account's lastUpdatedTimestamp
                accountLastUpdatedMapping[account] = currentEpochStart;
                //accountHistoryMapping[account][currentEpochStart] = veAccount;  // DataTypes.VeBalance(0, 0)

                // update global: updates lastUpdatedTimestamp | may or may not have updates
                veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart);

                return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
            }
                    
            // LOAD: account's previous veBalance
            veAccount = accountHistoryMapping[account][accountLastUpdatedAt];

            // RETURN: if both global and account are up to date
            if(accountLastUpdatedAt >= currentEpochStart)
                return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);

            // Updating needed: global and account veBalance to current epoch
            while (accountLastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                accountLastUpdatedAt += EpochMath.EPOCH_DURATION;

                // --- Update global: if required ---
                if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                    
                    // subtract decay for this epoch && remove any scheduled slope changes from expiring locks
                    veGlobal_ = _subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                    // book ve state for the new epoch
                    totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
                }
                
                // Update account: apply scheduled slope reductions & decay for this epoch | cumulative of account's expired locks
                uint256 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];    
                veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
                
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

            // STORAGE: update global
            veGlobal = _add(veGlobal_, increaseInVeBalance);
            slopeChanges[newLock.expiry] += increaseInVeBalance.slope;

            // STORAGE: update account
            veAccount = _add(veAccount, increaseInVeBalance);
            accountHistoryMapping[account][currentEpochStart] = veAccount;
            accountSlopeChangesMapping[account][newLock.expiry] += increaseInVeBalance.slope;

            // mint the delta (difference between old and new veBalance)
            _mint(account, newVeBalance.bias - oldVeBalance.bias);
            
            return newVeBalance;
        }

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

        // forward-looking; not historical search
        function _getValueAt(DataTypes.VeBalance memory a, uint256 timestamp) internal pure returns (uint256) {
            if(a.bias < (a.slope * timestamp)) {
                return 0;
            }
            // offset inception inflation
            return a.bias - (a.slope * timestamp);
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
                // new checkpoint for new epoch: set lastUpdatedAt
                // forge-lint: disable-next-line(unsafe-typecast)
                lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
            }
        }

        function _mocaToken() internal view returns (IERC20){
            return IERC20(_addressBook.getMoca());
        }

        function _esMocaToken() internal view returns (IERC20){
            return IERC20(_addressBook.getEscrowedMoca());
        }

    //-------------------------------Modifiers---------------------------------------------------------------

        // not using internal function: only 1 occurrence of this modifier
        modifier onlyMonitorRole(){
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isMonitor(msg.sender), "Caller not monitor");
            _;
        }

        // not using internal function: only 1 occurrence of this modifier
        modifier onlyCronJobRole() {
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isCronJob(msg.sender), "Caller not cron job");
            _;
        }

        // not using internal function: only 2 occurrences of this modifier
        modifier onlyGlobalAdminRole(){
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isGlobalAdmin(msg.sender), "Caller not global admin");
            _;
        }
        
        // not using internal function: only 1 occurrence of this modifier
        modifier onlyEmergencyExitHandlerRole(){
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isEmergencyExitHandler(msg.sender), "Caller not emergency exit");
            _;
        }


        // references AddressBook for contract address; not a role
        // not using internal function: only 2 occurrences of this modifier
        // forge-lint: disable-next-item(all)
        modifier onlyVotingControllerContract() {
            address votingController = _addressBook.getVotingController();
            require(msg.sender == votingController, "Caller not voting controller");
            _;
        }

    //-------------------------------Block: transfer/transferFrom -----------------------------------------

        //TODO: white-list transfers? || incorporate ACL / or new layer for token transfers

        function transfer(address, uint256) public pure override returns (bool) {
            revert("veMOCA is non-transferable");
        }

        function transferFrom(address, address, uint256) public pure override returns (bool) {
            revert("veMOCA is non-transferable");
        }


    //-------------------------------Risk management--------------------------------------------------------

        /**
        * @notice Pause contract. Cannot pause once frozen
        */
        function pause() external whenNotPaused onlyMonitorRole {
            if(_isFrozen == 1) revert Errors.IsFrozen(); 
            _pause();
        }

        /**
        * @notice Unpause pool. Cannot unpause once frozen
        */
        function unpause() external whenPaused onlyGlobalAdminRole {
            if(_isFrozen == 1) revert Errors.IsFrozen(); 
            _unpause();
        }

        /**
        * @notice To freeze the pool in the event of something untoward occurring
        * @dev Only callable from a paused state, affirming that staking should not resume
        *      Nothing to be updated. Freeze as is.
        *      Enables emergencyExit() to be called.
        */
        function freeze() external whenPaused onlyGlobalAdminRole {
            if(_isFrozen == 1) revert Errors.IsFrozen();

            _isFrozen = 1;
            emit Events.ContractFrozen();
        }  

        // return principals{esMoca,Moca} to users
        // not callable by anyone: calling this fn arbitrarily on the basis of "frozen" is not a good idea
        // only callable by emergency exit handler: timing of calling exit could be critical
        // disregard making updates to the contract: no need to update anything; system has failed. leave it as is.
        // focus purely on returning principals
        function emergencyExit(bytes32[] calldata lockIds) external onlyEmergencyExitHandlerRole {
            require(_isFrozen == 1, "Contract is not frozen");
            require(lockIds.length > 0, "No locks provided");

            // get user's veBalance for each lock
            for(uint256 i; i < lockIds.length; ++i) {
                // get lock
                DataTypes.Lock memory lock = locks[lockIds[i]];

                //sanity: lock exists + principals not returned
                require(lock.owner != address(0), "Invalid lockId");
                require(lock.isUnlocked == false, "Principals already returned");                

                // burn veMoca tokens
                _burn(lock.owner, uint256(_convertToVeBalance(lock).bias)); 

                // transfer all tokens to the users
                if(lock.moca > 0) _mocaToken().safeTransfer(lock.owner, uint256(lock.moca));
                if(lock.esMoca > 0) _esMocaToken().safeTransfer(lock.owner, uint256(lock.esMoca));

                // mark exited 
                //delete lock.moca;   --> @follow-up do we want to keep this for record?
                //delete lock.esMoca; --> @follow-up point-in-time value when exit occurred; how much was repatriated
                lock.isUnlocked = true;
    
                locks[lockIds[i]] = lock;
            }

            // emit event
            emit Events.EmergencyExit(lockIds);
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
                lastUpdatedAt += EpochMath.EPOCH_DURATION;                  

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
            
            // account has no locks created: return empty veBalance
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
                accountLastUpdatedAt += EpochMath.EPOCH_DURATION;

                // decrement decay for this epoch & apply scheduled slope changes
                uint256 expiringSlope = accountSlopeChanges[account][accountLastUpdatedAt];
                veBalance = _subtractExpired(veBalance, expiringSlope, accountLastUpdatedAt);
            }

            return veBalance;
        }

    //-------------------------------view functions-----------------------------------------
        
        /**
         * @notice Returns current total supply of voting escrowed tokens (veTokens), up to date with the latest epoch
         * @dev Overrides the ERC20 `totalSupply()` 
         * @dev Updates global veBalance to the current epoch before returning value
         * @return Updated current total supply of veTokens
         */
        function totalSupply() public view override returns (uint256) {
            // update global veBalance to current epoch
            DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, EpochMath.getCurrentEpochStart());
            // return value at current timestamp
            return _getValueAt(veGlobal_, uint128(block.timestamp));
        }

        /**
         * @notice Returns the projected total supply of voting escrowed tokens (veTokens) at a future timestamp.
         * @dev Forward-looking calculation; does not perform a historical search.
         *      For historical queries, use the totalSupplyAt[] mapping, which is limited to epoch boundaries.
         * @param time The future timestamp for which the total supply is projected.
         * @return The projected total supply of veTokens at the specified future timestamp.
         */
        function totalSupplyInFuture(uint128 time) public view returns (uint256) {
            require(time > block.timestamp, "Timestamp is in the past");

            DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, EpochMath.getEpochStartForTimestamp(time));
            return _getValueAt(veGlobal_, time);
        }

        //-------------------------------user: balanceOf, balanceOfAt -----------------------------------------

        /**
         * @notice Returns the current personal voting power (veBalance) of a user.
         * @dev Overrides the ERC20 `balanceOf()` function selector; therefore forced to return personal voting power.
         * @param user The address of the user whose veBalance is being queried.
         * @return The current personal veBalance of the user.
         */
        function balanceOf(address user) public view override returns (uint256) {
            return balanceOf(user, false);  // Only personal voting power (non-delegated locks)
        }

        /**
         * @notice Returns the current voting power (veBalance) of a user
         * @param user The address of the user whose veBalance is being queried.
         * @param forDelegated If true: delegated veBalance; if false: personal veBalance
         * @return The current veBalance of the user.
         */
        function balanceOf(address user, bool forDelegated) public view returns (uint256) {
            DataTypes.VeBalance memory veBalance = _viewAccount(user, forDelegated);
            return _getValueAt(veBalance, uint128(block.timestamp));
        }

        // note: needed?
        /**
         * @notice Historical search of a user's voting escrowed balance (veBalance) at a specific timestamp.
         * @dev veBalances are checkpointed per epoch. This function locates the closest epoch boundary to the input timestamp,
         *      then interpolates the veBalance from that checkpoint to the exact timestamp.
         * @param user The address of the user whose veBalance is being queried.
         * @param time The historical timestamp for which the veBalance is requested.
         * @param forDelegated If true: delegated veBalance; if false: personal veBalance
         * @return The user's veBalance at the specified timestamp.
         */
        function balanceOfAt(address user, uint256 time, bool forDelegated) external view returns (uint256) {
            require(time <= block.timestamp, "Timestamp is in the future");

            // find the closest epoch boundary (eTime) that is not larger than the input time
            uint256 eTime = EpochMath.getEpochStartForTimestamp(time);
            
            // get the appropriate veBalance at that epoch boundary
            DataTypes.VeBalance memory veBalance = forDelegated ? delegateHistory[user][eTime] : userHistory[user][eTime];
            
            // calc. voting power at the exact timestamp using the veBalance from the closest past epoch boundary
            return _getValueAt(veBalance, time);
        }

        // epoch: epoch Number
        function balanceAtEpochEnd(address user, uint256 epoch, bool forDelegated) external view returns (uint256) {
            uint256 epochEndTime = EpochMath.getEpochEndForTimestamp(epoch);
            
            // get the appropriate veBalance at that epoch boundary | note: is epochEndTime inclusive?
            DataTypes.VeBalance memory veBalance = forDelegated ? delegateHistory[user][epochEndTime] : userHistory[user][epochEndTime];
            
            // calc. voting power at the exact timestamp using the veBalance from the closest past epoch boundary
            return _getValueAt(veBalance, epochEndTime);
        }

        // note: used by VotingController.claimRewardsFromDelegate()
        function getSpecificDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint128) {
            uint256 epochEndTime = EpochMath.getEpochEndForTimestamp(epoch);
            return delegatedAggregationHistory[user][delegate][epochEndTime].bias;
        }


    // ------ lock: getLockHistoryLength, getLockCurrentVeBalance, getLockCurrentVotingPower, getLockVeBalanceAt ---------

        /// @notice Returns the number of checkpoints in the lock's history
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

        // note:  @follow-up should remove, since voting does not operate on point-in-time values
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

        //note: historical search. veBalances are stored epoch-wise, find the closest epoch boundary to the timestamp and interpolate from there
        function getLockVeBalanceAt(bytes32 lockId, uint128 timestamp) external view returns (uint256) {
            require(timestamp <= block.timestamp, "Timestamp is in the future");

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
            while (min < max) {
                uint256 mid = (min + max + 1) / 2;
                if(history[mid].lastUpdatedAt <= timestamp) {
                    min = mid;
                } else {
                    max = mid - 1;
                }
            }
            
            return _getValueAt(history[min].veBalance, timestamp);
        }

        function isFrozen() external view returns (uint256) {
            return _isFrozen;
        }
    }