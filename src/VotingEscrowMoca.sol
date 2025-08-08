    // SPDX-License-Identifier: BUSL-1.1
    pragma solidity 0.8.27;

    //import {VotingEscrowTokenBase} from "./VotingEscrowTokenBase.sol";
    import {WeekMath} from "./WeekMath.sol";
    import {Constants} from "./Constants.sol";
    import {DataTypes} from "./DataTypes.sol";

    import {MocaVotingController} from "./MocaVotingController.sol";

    import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
    import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
    import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

    import {EpochMath} from "./libraries/EpochMath.sol";

    /**
        - Stake MOCA tokens to receive veMOCA (voting power)
        - Longer lock periods result in higher veMOCA allocation
        - veMOCA decays linearly over time, reducing voting power
        - Formula-based calculation determines veMOCA amount based on stake amount and duration
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
        uint128 public lastUpdatedTimestamp;  
        
        // delegate fees
        uint256 public DELEGATE_REGISTRATION_FEE;
        uint256 public TOTAL_DELEGATE_REGISTRATION_FEES;

    //-------------------------------mapping-----------------------------------------------------

        // lock
        mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
        // Checkpoints are added upon every state transition; not by epoch. use binary search to find the checkpoint for any eTime
        mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;


        // scheduled global slope changes
        mapping(uint128 eTime => uint128 slopeChange) public slopeChanges;
        // saving totalSupply checkpoint for each epoch
        mapping(uint128 eTime => uint128 totalSupply) public totalSupplyAt;
        
        
        // user data: cannot use array as likely will get very large
        mapping(address user => mapping(uint128 eTime => uint128 slopeChange)) public userSlopeChanges;
        mapping(address user => mapping(uint128 eTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
        mapping(address user => uint128 lastUpdatedTimestamp) public userLastUpdatedTimestamp;

        // delegation data
        mapping(address delegate => bool isRegistered) public isRegisteredDelegate;                             // note: payment to treasury
        mapping(address delegate => mapping(uint128 eTime => uint128 slopeChange)) public delegateSlopeChanges;
        mapping(address delegate => mapping(uint128 eTime => DataTypes.VeBalance veBalance)) public delegateHistory; // aggregated delegate veBalance
        mapping(address delegate => uint128 lastUpdatedTimestamp) public delegateLastUpdatedTimestamp;

        
        // delegatedAggregationHistory tracks how much veBalance a user has delegated out
        // Used by VotingController to determine users' share of rewards from delegates
        // handover aggregation | aggregated delegated veBalance
        mapping(address user => mapping(address delegate => mapping(uint256 epoch => DataTypes.VeBalance veBalance))) public delegatedAggregationHistory; 


    //-------------------------------constructor-------------------------------------------------

        constructor(address addressBook_) ERC20("veMoca", "veMOCA") {
            _addressBook = IAddressBook(addressBook_);

            // note: has to be done on AddressBook contract after deployment
            //_addressBook.getAddress(Constants.VOTING_CONTROLLER);
        }

    //-------------------------------user functions---------------------------------------------

        // note: locks are booked to currentEpochStart
        // TODO: take in both es and moca at once
        /**
         * @notice Creates a new lock with the specified amount, expiry, token type, and optional delegate.
         * @dev The delegate parameter is optional and can be set to the zero address if not delegating.
         * @param amount The amount of tokens to lock.
         * @param expiry The timestamp when the lock will expire.
         * @param isMoca Boolean indicating whether the lock is for MOCA (true) or esMOCA (false).
         * @param delegate The address to delegate voting power to (optional).
         * @return lockId The unique identifier of the created lock.
        */
        function createLock(uint256 amount, uint128 expiry, bool isMoca, address delegate) external returns (bytes32) {
            return _createLockFor(msg.sender, amount, expiry, isMoca, delegate);
        }

        //TODO:  confirm w/ P: must have at least 1 epoch left to increase amount?
        function increaseAmount(bytes32 lockId, uint128 mocaToIncrease, uint128 esMocaToIncrease) external {
            DataTypes.Lock memory oldLock = locks[lockId];

            require(oldLock.lockId != bytes32(0), "NoLockFound");
            require(oldLock.creator == msg.sender, "Only the creator can increase the amount");
            require(oldLock.expiry > block.timestamp, "Lock has expired");      

            // DELEGATED OR PERSONAL LOCK:
            bool isDelegated = oldLock.delegate != address(0);
            address account = isDelegated ? oldLock.delegate : msg.sender;

            // update account and global: account is either delegate or user
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint128 currentEpochStart, 
                mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping, 
                mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping
            
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
                
            // calc. delta: schedule slope changes + book new veBalance 
            // MINT: additional veMoca to account
            DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veAccount, oldLock, updatedLock, account, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);

            // storage: update lock + checkpoint lock
            locks[lockId] = updatedLock;
            _pushCheckpoint(lockHistory[lockId], newVeBalance, currentEpochStart);        

            // emit event

            // STORAGE: update global totalLockedMoca/EsMoca + transfer tokens to contract
            if(mocaToIncrease){
                totalLockedMoca += mocaToIncrease;
                mocaToken.safeTransferFrom(msg.sender, address(this), mocaToIncrease);
            }
            if(esMocaToIncrease){
                totalLockedEsMoca += esMocaToIncrease;
                esMocaToken.safeTransferFrom(msg.sender, address(this), esMocaToIncrease);
            }
        }
        
        //TODO:  confirm w/ P: must have at least 1 epoch left to increase amount?
        function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external {
            // cannot extend duration arbitrarily; must be step-wise matching epoch boundaries
            require(EpochMath.isValidEpochTime(durationToIncrease), "Duration must be on a epoch boundary");

            DataTypes.Lock memory oldLock = locks[lockId];

            require(oldLock.lockId != bytes32(0), "NoLockFound");
            require(oldLock.creator == msg.sender, "Only the creator can increase the duration");
            require(oldLock.expiry > block.timestamp, "Lock has expired");
            
            // Ensure the new expiry is at least MIN_LOCK_DURATION from now
            uint256 newExpiry = oldLock.expiry + durationToIncrease;
            require(newExpiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, "New expiry too short");

            // DELEGATED OR PERSONAL LOCK:
            bool isDelegated = oldLock.delegate != address(0);
            address account = isDelegated ? oldLock.delegate : msg.sender;

            // update account and global: account is either delegate or user
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint128 currentEpochStart, 
                mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping, 
                mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping
            
            ) = _updateAccountAndGlobal(account, isDelegated);

            /** if lock is delegated, then the lock has been loaned to the delegate
                - must update delegateSlopeChanges, delegateHistory
                - userHistory,userSLopeChanges do not track loaned locks
                so no reason to update _updateUserAndGlobal -> no bearing.
            */

            // copy old lock: update amount and/or duration
            DataTypes.Lock memory updatedLock = oldLock;
                updatedLock.expiry = newExpiry;

            // calc. delta: schedule slope changes + book new veBalance + mints additional veMoca to account
            DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veAccount, oldLock, updatedLock, account, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);

            // storage: update lock + checkpoint lock
            locks[lockId] = updatedLock;
            _pushCheckpoint(lockHistory[lockId], newVeBalance, currentEpochStart);        

            // emit event
        }

        // Withdraws principals of an expired lock | ve will be burnt, altho veBalance will return 0 on expiry
        // @follow-up allowing anyone to unlock a lock.
        function unlock(bytes32 lockId) external {
            DataTypes.Lock memory lock = locks[lockId];

            require(lock.lockId != bytes32(0), "LockNotFound");
            require(lock.expiry < block.timestamp, "Lock not expired");
            require(lock.isUnlocked == false, "Lock already unlocked");

            // what if the lock is delegated?
            require(lock.delegate == address(0), "Lock is delegated");
            
            //require(lock.creator == msg.sender, "Only creator can unlock");
            
            // UPDATE GLOBAL & USER
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentEpochStart) = _updateAccountAndGlobal(lock.owner, false);

            // STORAGE: update lock + book final checkpoint | note: book final checkpoint, since we do not delete the lock
            lock.isUnlocked = true;    
            locks[lockId] = lock;
            _pushCheckpoint(lockHistory[lockId], veUser, currentEpochStart);  

            // burn originally issued veMoca
            uint256 mintedVeMoca = _convertToVeBalance(lock).bias;
            _burn(lock.owner, mintedVeMoca);

            // emit event

            // return principals to lock.owner
            if(lock.moca > 0) mocaToken.safeTransfer(lock.owner, lock.moca);
            if(lock.esMoca > 0) esMocaToken.safeTransfer(lock.owner, lock.esMoca);        
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
        function delegateLock(bytes32 lockId, address delegate) external {
            // sanity check: delegate
            require(delegate != msg.sender, "Cannot delegate to self");
            require(isRegisteredDelegate[delegate], "Delegate not registered");

            DataTypes.Lock memory lock = locks[lockId];
            
            // sanity check: lock
            require(lock.lockId != bytes32(0), "LockNotFound");
            require(lock.creator == msg.sender, "Only the creator can delegate");
            require(lock.expiry > block.timestamp, "Lock has not expired");     //@follow-up min. lock duration for delegation?
            require(lock.delegate == address(0), "Lock already delegated");   


            // update user & global: account for decay since lastUpdate and any scheduled slope changes | false since lock is not yet delegated
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentEpochStart) = _updateAccountAndGlobal(msg.sender, false);
            uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // get the lock's current veBalance [no checkpoint required as lock attributes have not changed]
            DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 

            // Remove specified lock from user's aggregated veBalance | note: this is to prevent user from being able to vote with delegated lock
            veUser = _sub(veUser, lockVeBalance);
            userHistory[msg.sender][nextEpochStart] = veUser;
            userSlopeChanges[msg.sender][lock.expiry] -= lockVeBalance.slope;


            // Update delegate's delegated voting power (required before adding the lock to delegate's balance)
            // true: update delegate's aggregated veBalance; not personal
            (, DataTypes.VeBalance memory veDelegate, ) = _updateAccountAndGlobal(delegate, true);
            
            // Add the lock to delegate's delegated balance
            veDelegate = _add(veDelegate, lockVeBalance);
            delegateHistory[delegate][nextEpochStart] = veDelegate;
            delegateSlopeChanges[delegate][lock.expiry] += lockVeBalance.slope;

            // transfer veMoca tokens from user to delegate 
            _transfer(msg.sender, delegate, lockVeBalance.bias);

            // STORAGE: update lock to mark it as delegated
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

        // a delegated lock can be expired
        function undelegateLock(bytes32 lockId) external {
            DataTypes.Lock memory lock = locks[lockId];

            // sanity checks
            require(lock.lockId != bytes32(0), "NoLockFound");
            require(lock.delegate != address(0), "Lock is not delegated");
            require(lock.creator == msg.sender, "Only creator can undelegate");
            require(lock.isUnlocked == false, "Lock has ended");

            
            //note: we do not implement this as delegate could have unregistered first; so we do not block users from clawing back
            //require(isRegisteredDelegate[delegate], "Delegate not registered");

            
            // [_updateDelegateAndGlobal]: apply decay since lastUpdate and any scheduled slope changes 
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veDelegate, uint128 currentEpochStart) = _updateAccountAndGlobal(lock.delegate, true);
            uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // get the lock's current veBalance [no checkpoint required as lock attributes have not changed]
            DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 

            // Remove the lock from delegate's aggregated veBalance
            veDelegate = _sub(veDelegate, lockVeBalance);
            delegateHistory[lock.delegate][nextEpochStart] = veDelegate;
            delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;

            // [_updateUserAndGlobal]: false: update user's personal aggregated veBalance; not delegated veBalance
            (, DataTypes.VeBalance memory veUser, ) = _updateAccountAndGlobal(msg.sender, false);

            // Add the lock to user's personal aggregated veBalance
            veUser = _add(veUser, lockVeBalance);
            userHistory[msg.sender][nextEpochStart] = veUser;
            userSlopeChanges[msg.sender][lock.expiry] += lockVeBalance.slope;

            // transfer veMoca tokens from delegate to user
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

        function switchDelegate(bytes32 lockId, address newDelegate) external {
            // sanity check: delegate
            require(newDelegate != msg.sender, "Cannot delegate to self");
            require(isRegisteredDelegate[newDelegate], "Delegate not registered");

            DataTypes.Lock memory lock = locks[lockId];

            require(lock.lockId != bytes32(0), "NoLockFound");
            require(lock.creator == msg.sender, "Only the creator can change delegate");
            require(lock.expiry > block.timestamp, "Lock has expired");     //@follow-up min. lock duration for delegation?
            
            // sanity check: delegate
            require(lock.delegate != address(0), "Lock must be delegated");
            require(lock.delegate != newDelegate, "Cannot switch to the same delegate");

            // Update current delegate's delegated veBalance (required before removing the lock from the current delegate) | true: update delegate's aggregated veBalance; not personal
            // [_updateDelegateAndGlobal]: account for decay since lastUpdate and any scheduled slope changes 
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veCurrentDelegate, uint128 currentEpochStart) = _updateAccountAndGlobal(lock.delegate, true);
            uint256 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;

            // get lock's current veBalance [no checkpoint required as lock attributes have not changed]
            DataTypes.VeBalance memory lockVeBalance = _convertToVeBalance(lock); 
            
            // Remove lock from current delegate
            veCurrentDelegate = _sub(veCurrentDelegate, lockVeBalance);
            delegateHistory[lock.delegate][nextEpochStart] = veCurrentDelegate;
            delegateSlopeChanges[lock.delegate][lock.expiry] -= lockVeBalance.slope;

            // Update new delegate's delegated veBalance (required before adding the lock to the new delegate) | true: update delegate's aggregated veBalance; not personal
            // [_updateDelegateAndGlobal]: account for decay since lastUpdate and any scheduled slope changes 
            (, DataTypes.VeBalance memory veNewDelegate, ) = _updateAccountAndGlobal(newDelegate, true);
            
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


    //-------------------------------admin functions---------------------------------------------

        // when creating lock onBehalfOf - we will not delegate for the user
        function createLockFor(address user, uint256 amount, uint128 expiry, bool isMoca) external onlyCronJobRole returns (bytes32) { 
            return _createLockFor(user, amount, expiry, isMoca, address(0));
        }

    //-------------------------------VotingController functions------------------------------------------
    
        // note: registration fees were collected by VotingController
        // require(delegate != address(0) not needed since external contract call
        function registerAsDelegate(address delegate) external onlyVotingControllerContract {
            require(!isRegisteredDelegate[delegate], "Already registered");

            // storage: register delegate
            isRegisteredDelegate[delegate] = true;

            // event
            //emit DelegateRegistered(delegate);
        }

        function unregisterAsDelegate(address delegate) external onlyVotingControllerContract {
            require(isRegisteredDelegate[delegate], "Delegate not registered");
            isRegisteredDelegate[delegate] = false;

            // event
            //emit DelegateUnregistered(delegate);
        }

    //-------------------------------internal: update functions----------------------------------------------        // delegate can be address(0)
        function _createLockFor(address user, uint256 amount, uint128 expiry, bool isMoca, address delegate) internal returns (bytes32) {
            require(user != address(0), "Invalid user");
            require(amount > 0, "Amount must be greater than zero");
            require(EpochMath.isValidEpochTime(expiry), "Expiry timestamp must lie on an epoch boundary");

            require(expiry >= block.timestamp + EpochMath.MIN_LOCK_DURATION, "Lock duration too short");
            require(expiry <= block.timestamp + EpochMath.MAX_LOCK_DURATION, "Lock duration too long");

            // Validate delegate if specified
            if (delegate != address(0)) {
                require(isRegisteredDelegate[delegate], "Delegate not registered");
                require(delegate != user, "Cannot delegate to self");
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
                    newLock.delegate = delegate;                //note: we might be setting this to zero; but no point doing if(delegate != address(0))
                    if (isMoca) newLock.moca = uint128(amount);
                    else newLock.esMoca = uint128(amount);
                    newLock.expiry = expiry;
                // STORAGE: book lock
                locks[lockId] = newLock;

                // STORAGE: get lock's veBalance + book checkpoint into lockHistory mapping 
                DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);
                _pushCheckpoint(lockHistory[lockId], veIncoming, EpochMath.getCurrentEpochStart()); 

                // EMIT LOCK CREATED
                // emit LockCreated(lockId, user, delegate, amount, expiry, isMoca);

            // --------- conditional updates based on delegation ---------

            // DELEGATED OR PERSONAL LOCK:
            bool isDelegated = delegate != address(0);
            address account = isDelegated ? delegate : user;

            // Apply scheduled slope reductions & decay up to current epoch
            (
                DataTypes.VeBalance memory veGlobal_, 
                DataTypes.VeBalance memory veAccount, 
                uint128 currentEpochStart, 
                mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping, 
                mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping
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

            // STORAGE: increment global totalLockedMoca/EsMoca
            if (isMoca) totalLockedMoca += amount;
            else totalLockedEsMoca += amount;

            // MINT to account
            _mint(account, veIncoming.bias);

            // EMIT LOCK CREATED

            // transfer tokens to contract
            if (isMoca) {
                totalLockedMoca += amount;
                mocaToken.safeTransferFrom(msg.sender, address(this), amount);
            } else {
                totalLockedEsMoca += amount;
                esMocaToken.safeTransferFrom(msg.sender, address(this), amount);
            }

            return lockId;
        }

        ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
        function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
            return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
        }

        // does not update veGlobal into storage; calcs the latest veGlobal. updates lastUpdatedTimestamp, totalSupplyAt[]
        function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {       
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
                    uint128,
                    mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage,  // accountHistoryMapping
                    mapping(address => mapping(uint128 => uint128)) storage               // accountSlopeChangesMapping
                )
        {

            // Streamlined mapping lookups based on account type
            (
                mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
                mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
                mapping(address => uint128) storage accountLastUpdatedMapping
            ) 
                = isDelegate ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);

            // CACHE: global veBalance
            DataTypes.VeBalance memory veGlobal_ = veGlobal;
            uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;
        
            // get current epoch start
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart(); 

            // get account's lastUpdatedTimestamp: {user | delegate}
            uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];

            // init empty veBalance
            DataTypes.VeBalance memory veAccount;

            // account's first time: no prior account updates to execute 
            if (accountLastUpdatedAt == 0) {
                
                // set account's lastUpdatedTimestamp and veBalance
                accountLastUpdatedMapping[account] = currentEpochStart;
                veAccount;  // DataTypes.VeBalance(0, 0)

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
                    veGlobal_ = subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                    // book ve state for the new epoch
                    totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
                }
                
                // Update account: apply scheduled slope reductions & decay for this epoch | cumulative of account's expired locks
                uint128 expiringSlope = accountSlopeChangesMapping[account][accountLastUpdatedAt];    
                veAccount = _subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
                
                // book account checkpoint 
                accountHistoryMapping[account][accountLastUpdatedAt] = veAccount;
            }

            // set final lastUpdatedTimestamp: for global and account
            lastUpdatedTimestamp = accountLastUpdatedAt;
            accountLastUpdatedMapping[account] = accountLastUpdatedAt;        

            // return
            return (veGlobal_, veAccount, currentEpochStart, accountHistoryMapping, accountSlopeChangesMapping);
        }


        // TODO: any possible rounding errors due to calc. of delta; instead of removed old then add new?
        function _modifyPosition(
            DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veAccount, 
            DataTypes.Lock memory oldLock, DataTypes.Lock memory updatedLock, 
            address account, uint128 currentEpochStart,

            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping

            ) internal returns (DataTypes.VeBalance memory) {

            // convert old and new lock to veBalance
            DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(oldLock);
            DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(updatedLock);

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

    //-------------------------------internal: library functions --------------------------------------------

        // removed expired locks from veBalance | does not set lastUpdatedAt
        function _subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlopes, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
            a.bias -= (expiringSlopes * expiry);       // remove decayed ve
            a.slope -= expiringSlopes;                 // remove expiring slopes

            return a;
        }

        // subtracts b from a
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

        // forward-looking; not historical search
        function _getValueAt(DataTypes.VeBalance memory a, uint128 timestamp) internal pure returns (uint128) {
            if(a.bias < (a.slope * timestamp)) {
                return 0;
            }
            // offset inception inflation
            return a.bias - (a.slope * timestamp);
        }

        // calc. veBalance{bias,slope} from lock; based on expiry time | inception offset is handled by balanceOf() queries
        function _convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
            DataTypes.VeBalance memory veBalance;

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
                // new checkpoint for new epoch: set lastUpdatedAt
                lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
            }
        }

    //-------------------------------Modifiers -------------------------------------------------

        modifier onlyMonitorRole(){
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isMonitor(msg.sender), "Caller not monitor");
            _;
        }

        modifier onlyCronJobRole() {
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isCronJob(msg.sender), "Caller not cron job");
            _;
        }

        modifier onlyGlobalAdminRole(){
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isGlobalAdmin(msg.sender), "Caller not global admin");
            _;
        }

        modifier onlyEmergencyExitHandlerRole(){
            IAccessController accessController = IAccessController(_addressBook.getAccessController());
            require(accessController.isEmergencyExitHandler(msg.sender), "Caller not emergency exit");
            _;
        }


        // references AddressBook for contract address; not a role
        modifier onlyVotingControllerContract() {
            address votingController = _addressBook.getVotingController();
            require(msg.sender == votingController, "Caller not voting controller");
            _;
        }

    //-------------------------------block: transfer/transferFrom -----------------------------------------

        //note: white-list transfers? || incorporate ACL / or new layer for token transfers

        function transfer(address, uint256) public pure override returns (bool) {
            revert("veMOCA is non-transferable");
        }

        function transferFrom(address, address, uint256) public pure override returns (bool) {
            revert("veMOCA is non-transferable");
        }


    //------------------------------- risk management ---------------------------------------------

        /**
        * @notice Pause contract. Cannot pause once frozen
        */
        function pause() external whenNotPaused onlyMonitorRole {
            if(isFrozen == 1) revert Errors.IsFrozen(); 
            _pause();
        }

        /**
        * @notice Unpause pool. Cannot unpause once frozen
        */
        function unpause() external whenPaused onlyGlobalAdminRole {
            if(isFrozen == 1) revert Errors.IsFrozen(); 
            _unpause();
        }

        /**
        * @notice To freeze the pool in the event of something untoward occurring
        * @dev Only callable from a paused state, affirming that staking should not resume
        *      Nothing to be updated. Freeze as is.
        *      Enables emergencyExit() to be called.
        */
        function freeze() external whenPaused onlyGlobalAdminRole {
            if(isFrozen) revert Errors.IsFrozen();

            isFrozen = 1;
            emit ContractFrozen(block.timestamp);
        }  

        // return principals{esMoca,Moca} to users
        // not callable by anyone: calling this fn arbitrarily on the basis of "frozen" is not a good idea
        // only callable by emergency exit handler: timing of calling exit could be critical
        // disregard making updates to the contract: no need to update anything; system has failed. leave it as is.
        // focus purely on returning principals
        function emergencyExit(bytes32[] calldata lockIds) external onlyEmergencyExitHandlerRole {
            require(isFrozen, "Contract is not frozen");
            require(lockIds.length > 0, "No locks provided");

            // get user's veBalance for each lock
            for(uint256 i; i < lockIds.length; ++i) {
                // get lock
                DataTypes.Lock memory lock = locks[lockIds[i]];

                //sanity: lock exists + principals not returned
                require(lock.owner != address(0), "Invalid lockId");
                require(lock.isUnlocked == false, "Principals already returned");                

                // burn veMoca
                _burn(lock.owner, lock.veMoca);

                // transfer all tokens to the users
                if(lock.moca > 0) mocaToken.safeTransfer(lock.owner, lock.moca);
                if(lock.esMoca > 0) esMocaToken.safeTransfer(lock.owner, lock.esMoca);

                // mark exited 
                //delete lock.moca;   --> @follow-up do we want to keep this for record?
                //delete lock.esMoca; --> @follow-up point-in-time value when exit occurred; how much was repatriated
                lock.isUnlocked = true;
    
                locks[lockIds[i]] = lock;
            }

            // emit event
            // emit EmergencyExit(lockIds);
        }

    //-------------------------------internal: view-----------------------------------------------------

        // _updateGlobal, but w/o the storage changes
        function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentEpochStart) internal view returns (DataTypes.VeBalance memory) {       
            // if lastUpdate was within current epoch: no new epoch, no new checkpoint
            if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

            // if first time: no prior updates needed 
            if(lastUpdatedAt == 0) {
                veGlobal_.lastUpdatedAt = currentEpochStart;   // move forward the anchor point to skip empty epochs
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
                mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistory,
                mapping(address => mapping(uint128 => uint128)) storage accountSlopeChanges,
                mapping(address => uint128) storage accountLastUpdatedTimestamp
            ) = forDelegated
                ? (delegateHistory, delegateSlopeChanges, delegateLastUpdatedTimestamp)
                : (userHistory, userSlopeChanges, userLastUpdatedTimestamp);

            // Get the appropriate last updated timestamp
            uint128 lastUpdatedAt = accountLastUpdatedTimestamp[account];
            
            // account has no locks created: return empty veBalance
            if(lastUpdatedAt == 0) return veBalance;

            // load account's previous veBalance from history
            veBalance = accountHistory[account][lastUpdatedAt];
            
            // get current epoch start
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart(); 
            
            // already up to date: return
            if(lastUpdatedAt >= currentEpochStart) return veBalance;

            // update account veBalance to current epoch
            while (lastUpdatedAt < currentEpochStart) {
                // advance 1 epoch
                lastUpdatedAt += EpochMath.EPOCH_DURATION;

                // decrement decay for this epoch & apply scheduled slope changes
                uint128 expiringSlope = accountSlopeChanges[account][lastUpdatedAt];
                veBalance = _subtractExpired(veBalance, expiringSlope, lastUpdatedAt);
            }

            return veBalance;
        }

    //-------------------------------view functions-----------------------------------------

        /**
         * @notice Returns current total supply of voting escrowed tokens (veTokens), up to date with the latest epoch
         * @dev Overrides the ERC20 `totalSupply()` and brings the global veBalance up to the current epoch before returning the value.
         * @return The current total supply of veTokens
         */
        function totalSupply() public view override returns (uint256) {
            // update global veBalance to current epoch
            DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, EpochMath.getCurrentEpochStart());
            // return value at current timestamp
            return _getValueAt(veGlobal_, uint128(block.timestamp));
        }

        // forward-looking; not historical search | for historical search, use totalSupplyAt[] mapping; limited to epoch boundaries
        function totalSupplyInFuture(uint128 time) public view returns (uint256) {
            require(time >= block.timestamp, "Timestamp is in the past");

            DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, EpochMath.getEpochStartForTimestamp(time));
            return _getValueAt(veGlobal_, time);
        }

        //-------------------------------user: balanceOf, balanceOfAt -----------------------------------------

        //note: Need to keep this fn to match and override ERC20::balanceOf() fn selector
        function balanceOf(address user) public view override returns (uint128) {
            // Only personal voting power (non-delegated locks)
            return balanceOf(user, false);
        }

        /** note: we combine balanceOf and delegatedBalanceOf into a single function; similarly w/ balanceOfAt and delegatedBalanceOfAt
            - but we need to override the ERC20 balanceOf() fn, so that wallets querying will readily display a user's personal voting power - decaying in real-time.
            - this is a bit of a hack, but it's the only way to get the desired functionality without breaking the ERC20 interface.
            - @follow-up
        */

        function balanceOf(address user, bool isDelegated) external view returns (uint128) {
            // Get the appropriate veBalance based on query type
            DataTypes.VeBalance memory veBalance = _viewAccount(user, isDelegated);
            return _getValueAt(veBalance, uint128(block.timestamp));
        }

        /// @notice historical search. veBalances are stored per epoch; find the closest epoch boundary to the timestamp and interpolate from there
        function balanceOfAt(address user, uint128 time, bool isDelegated) external view returns (uint128) {
            require(time <= block.timestamp, "Timestamp is in the future");

            // find the closest epoch boundary (eTime) that is not larger than the input time
            uint128 eTime = EpochMath.getEpochStartForTimestamp(time);
            
            // get the appropriate veBalance at that epoch boundary
            DataTypes.VeBalance memory veBalance = isDelegated ? delegateHistory[user][eTime] : userHistory[user][eTime];
            
            // calc. voting power at the exact timestamp using the veBalance from the closest past epoch boundary
            return _getValueAt(veBalance, time);
        }

        /// @notice Returns a user's total delegated balance, aggregated across all delegates
        function getUserTotalDelegatedBalance(address user, address delegate) external view returns (uint256) {
            //veBalance is valued at now
            return _getValueAt(delegatedAggregationHistory[user][delegate][uint128(block.timestamp)], uint128(block.timestamp));
        }

        /** @notice Retrieves the delegated veBalance of a user for a specific delegate at the end of a given epoch.
         *  @dev
         *   1. Gets the user's delegated veBalance for the specified epoch by referencing the epoch start time.
         *   2. Calculates the voting power at the end of the epoch using _getValueAt.
         *  @param user The address of the user whose delegated balance is being queried.
         *  @param delegate The address of the delegate to whom the balance is delegated.
         *  @param epoch The epoch number for which the delegated balance is requested.
         *  @return The delegated voting power at the end of the specified epoch.
         */
        function getDelegatedBalanceAtEpochEnd(address user, address delegate, uint256 epoch) external view returns (uint256) {
            uint256 epochStart = EpochMath.getEpochStartTimestamp(epoch);
            uint256 epochEnd = epochStart + EpochMath.EPOCH_DURATION;
            // 1. get user's delegated veBalance for specified epoch: reference epoch start time
            // 2. voting power is benchmarked to end of epoch: so _getValue to calc. on epochEnd
            return _getValueAt(delegatedAggregationHistory[user][delegate][epochStart], epochEnd);
        }

    // ------ lock: getLockHistoryLength, getLockCurrentVeBalance, getLockCurrentVotingPower, getLockVeBalanceAt ---------


        function getLockHistoryLength(bytes32 lockId) external view returns (uint256) {
            return lockHistory[lockId].length;
        }

        //note: isn't _convertToVeBalance(locks[lockId]) == lockHistory[lockId][lockHistory.length - 1].veBalance?
        function getLockCurrentVeBalance(bytes32 lockId) external view returns (DataTypes.VeBalance memory) {
            return _convertToVeBalance(locks[lockId]);
        }

        function getLockCurrentVotingPower(bytes32 lockId) external view returns (uint256) {
            return _getValueAt(_convertToVeBalance(locks[lockId]), uint128(block.timestamp));
        }

        //note: historical search. veBalances are stored weekly, find the closest week boundary to the timestamp and interpolate from there
        function getLockVeBalanceAt(bytes32 lockId, uint128 timestamp) external view returns (uint256) {
            require(timestamp <= block.timestamp, "Timestamp is in the future");

            DataTypes.Checkpoint[] storage history = lockHistory[lockId];
            uint256 length = history.length;
            if(length == 0) return 0;
            
            // binary search to find the checkpoint with timestamp closest, but not larger than the input time
            uint256 min = 0;
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
            
    }