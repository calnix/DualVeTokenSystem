// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

//import {VotingEscrowTokenBase} from "./VotingEscrowTokenBase.sol";
import {WeekMath} from "./WeekMath.sol";
import {Constants} from "./Constants.sol";
import {DataTypes} from "./DataTypes.sol";

import {MocaVotingController} from "./MocaVotingController.sol";

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
    - Stake MOCA tokens to receive veMOCA (voting power)
    - Longer lock periods result in higher veMOCA allocation
    - veMOCA decays linearly over time, reducing voting power
    - Formula-based calculation determines veMOCA amount based on stake amount and duration
 */

contract VotingEscrowMoca is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    MocaVotingController public votingController;

    IERC20 public immutable mocaToken;
    IERC20 public immutable esMocaToken;
    address public treasury;

    // global principal
    uint256 public totalLockedMoca;
    uint256 public totalLockedEsMoca;

    // global veBalance
    DataTypes.VeBalance public veGlobal;
    uint128 public lastUpdatedTimestamp;  
    
    // delegate fees
    uint256 public DELEGATE_REGISTRATION_FEE;
    uint256 public TOTAL_DELEGATE_REGISTRATION_FEES;

//-------------------------------mapping------------------------------------------

    // lock
    mapping(bytes32 lockId => DataTypes.Lock lock) public locks;
    // Checkpoints are added upon every state transition; not weekly. use binary search to find the checkpoint at any wTime
    mapping(bytes32 lockId => DataTypes.Checkpoint[] checkpoints) public lockHistory;


    // scheduled global slope changes
    mapping(uint128 wTime => uint128 slopeChange) public slopeChanges;
    // saving totalSupply checkpoint for each week
    mapping(uint128 wTime => uint128 totalSupply) public totalSupplyAt;

    // user data: cannot use array as likely will get very large
    mapping(address user => mapping(uint128 wTime => uint128 slopeChange)) public userSlopeChanges;
    mapping(address user => mapping(uint128 wTime => DataTypes.VeBalance veBalance)) public userHistory; // aggregated user veBalance
    mapping(address user => uint128 lastUpdatedTimestamp) public userLastUpdatedTimestamp;

    // delegation data
    mapping(address delegate => bool isRegistered) public isRegisteredDelegate;                             // note: payment to treasury
    mapping(address delegate => mapping(uint128 wTime => uint128 slopeChange)) public delegateSlopeChanges;
    mapping(address delegate => mapping(uint128 wTime => DataTypes.VeBalance veBalance)) public delegateHistory; // aggregated delegate veBalance
    mapping(address delegate => uint128 lastUpdatedTimestamp) public delegateLastUpdatedTimestamp;



//-------------------------------constructor------------------------------------------

    constructor(address mocaToken_, address esMocaToken_, address owner_, address treasury_) ERC20("veMoca", "veMOCA") {
        mocaToken = IERC20(mocaToken_);
        esMocaToken = IERC20(esMocaToken_);

        treasury = treasury_;

        // roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);

    }

//-------------------------------user functions------------------------------------------


    function createLock(uint256 amount, uint128 expiry, bool isMoca) external returns (bytes32) {
        return _createLockFor(msg.sender, amount, expiry, isMoca);
    }

    function increaseAmount(bytes32 lockId, uint128 mocaToIncrease, uint128 esMocaToIncrease) external {
        DataTypes.Lock memory oldLock = locks[lockId];
        require(oldLock.lockId != bytes32(0), "NoLockFound");
        require(oldLock.creator == msg.sender, "Only the creator can increase the amount");
        require(oldLock.expiry > block.timestamp, "Lock has expired");

        //note: check delegation

        // UPDATE GLOBAL & USER
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

        // copy old lock: update amount
        DataTypes.Lock memory newLock = oldLock;
            newLock.moca += mocaToIncrease;
            newLock.esMoca += esMocaToIncrease;
            
        // calc. delta and book new veBalance + schedule slope changes
        DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veUser, oldLock, newLock, currentWeekStart);

        // storage: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newVeBalance, currentWeekStart);        

        // emit event

        // transfer tokens to contract
        if(mocaToIncrease > 0) mocaToken.safeTransferFrom(msg.sender, address(this), mocaToIncrease);
        if(esMocaToIncrease > 0) esMocaToken.safeTransferFrom(msg.sender, address(this), esMocaToIncrease);
    }

    function increaseDuration(bytes32 lockId, uint128 durationToIncrease) external {
        DataTypes.Lock memory oldLock = locks[lockId];
        require(oldLock.lockId != bytes32(0), "NoLockFound");
        require(oldLock.creator == msg.sender, "Only the creator can increase the duration");
        require(oldLock.expiry > block.timestamp, "Lock has expired");

        require(WeekMath.isValidWTime(oldLock.expiry + durationToIncrease), "Expiry must be a valid week beginning");

        //note: for extending lock duration: must meet min duration
        require(oldLock.expiry + durationToIncrease >= block.timestamp + Constants.MIN_LOCK_DURATION, "Lock duration too short");

        //note: check delegation

        // UPDATE GLOBAL & USER
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

        // copy old lock: update amount and/or duration
        DataTypes.Lock memory newLock = oldLock;
            newLock.expiry += durationToIncrease;

        // calc. delta and book new veBalance + schedule slope changes
        DataTypes.VeBalance memory newVeBalance = _modifyPosition(veGlobal_, veUser, oldLock, newLock, currentWeekStart);

        // storage: update lock + checkpoint lock
        locks[lockId] = newLock;
        _pushCheckpoint(lockHistory[lockId], newVeBalance, currentWeekStart);        

        // emit event
    }

    // Withdraws an expired lock position, returning the principal and veMoca
    function withdraw(bytes32 lockId) external {
        DataTypes.Lock memory lock = locks[lockId];
        require(lock.lockId != bytes32(0), "NoLockFound");
        require(lock.creator == msg.sender, "Only the creator can withdraw");
        require(lock.expiry < block.timestamp, "Lock has not expired");
        require(lock.isWithdrawn == false, "Lock has already been withdrawn");

        // UPDATE GLOBAL & USER
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

        // get old veBalance
        DataTypes.VeBalance memory veBalance = _convertToVeBalance(lock);
        require(veBalance.bias == 0, "No veMoca to withdraw");

        // storage: update lock + checkpoint lock
        lock.isWithdrawn = true;    
        locks[lockId] = lock;
        _pushCheckpoint(lockHistory[lockId], veBalance, currentWeekStart);  // book final checkpoint, since we do not delete the lock

        // burn originally issued veMoca
        _burn(msg.sender, veBalance.bias);

        // emit event

        // transfer tokens to user
        if(lock.moca > 0) mocaToken.safeTransfer(msg.sender, lock.moca);
        if(lock.esMoca > 0) esMocaToken.safeTransfer(msg.sender, lock.esMoca);        
    }


    /** 
     * @notice Early redemption with penalty (partial redemption allowed)
     * @param lockId ID of the lock to redeem early
     * @param amountToRedeem Amount of principal to redeem
     * @param isMoca True to redeem MOCA tokens, false to redeem esMOCA tokens
     */
    function earlyRedemption(bytes32 lockId, uint128 amountToRedeem, bool isMoca) external {

        // check lock exists
        DataTypes.Lock memory lock = locks[lockId];
        require(lock.lockId != bytes32(0), "NoLockFound");
        require(lock.creator == msg.sender, "Only the creator can redeem early");
        require(lock.expiry > block.timestamp, "Lock has not expired");
        require(lock.isWithdrawn == false, "Lock has already been withdrawn");

        // Get the amount of the selected token type
        uint256 selectedPrincipalAmount = isMoca ? lock.moca : lock.esMoca;
        require(selectedPrincipalAmount > 0, "No principal in lock");

        uint256 totalBase = lock.moca + lock.esMoca;

        // get veBalance
        DataTypes.VeBalance memory veBalance = _convertToVeBalance(lock);   // veBalance.bias = initialVotingPower
        require(veBalance.bias > 0, "No veMoca to redeem");

        // get currentVotingPower
        uint256 currentBias = _getValueAt(veBalance, uint128(block.timestamp));
        
        /** Calculate penalty based on current veMoca value relative to original veMoca value;
            this is a proxy for time passed since lock was created.

            penalty = [1 - (currentVotingPower/initialVotingPower)] * MAX_PENALTY_PCT 
                    = [initialVotingPower/initialVotingPower - (currentVotingPower/initialVotingPower)] * MAX_PENALTY_PCT 
                    = [(initialVotingPower - currentVotingPower) / initialVotingPower] * MAX_PENALTY_PCT
                    = [(veBalance.bias - currentBias) / veBalance.bias] * MAX_PENALTY_PCT
        */
        uint256 penaltyPct = (Constants.MAX_PENALTY_PCT * (veBalance.bias - currentBias)) / veBalance.bias;   
        
        // calculate total penalty based on total base amount (both MOCA and esMOCA contribute to veMoca)
        uint256 totalPenaltyInTokens = totalBase * penaltyPct / Constants.PRECISION_BASE;
        
        // user gets their selected token type minus the total penalty
        uint256 remainingSelectedPrincipalAmount = selectedPrincipalAmount - totalPenaltyInTokens; //note: if insufficient, will revert
        
        // storage: update lock
        if(isMoca) {
            locks[lockId].moca = remainingSelectedPrincipalAmount;
        } else {
            locks[lockId].esMoca = remainingSelectedPrincipalAmount;
        }
        
        // storage: lock checkpoint
        //_pushCheckpoint(lockHistory[lockId], veBalance, currentWeekStart);

        // storage: update global & user | is this necessary?
        //(DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

        // burn veMoca    
        uint256 veMocaToBurn = amountToRedeem * veBalance.bias / totalBase;
        _burn(msg.sender, veMocaToBurn);

        // event?
        
        // transfer the selected token type to user
        if (isMoca) {
            mocaToken.safeTransfer(msg.sender, amountToReturn);
        } else {
            esMocaToken.safeTransfer(msg.sender, amountToReturn);
        }
        
        // emit event
    }


//-------------------------------delegate functions------------------------------------------
   
    //note: registration fees were collected by VotingController
    function registerAsDelegate(address delegate) external {
        require(msg.sender == address(votingController), "Only voting controller can register delegates");
        //require(delegate != address(0), "Invalid address"); note: should not be needed since external contract call
        require(!isRegisteredDelegate[delegate], "Already registered");

        // storage: register delegate
        isRegisteredDelegate[delegate] = true;

        // event
        //emit DelegateRegistered(delegate);
    }

//-------------------------------admin functions------------------------------------------


    function createLockFor(address user, uint256 amount, uint128 expiry, bool isMoca) external onlyRole(Constants.CRON_JOB_ROLE) returns (bytes32) { 
        return _createLockFor(user, amount, expiry, isMoca);
    }




//-------------------------------internal-----------------------------------------------------

    // delegate can be address(0)
    function _createLockFor(address user, uint256 amount, uint128 expiry, bool isMoca, address delegate) internal returns (bytes32) {
        require(amount > 0, "Amount must be greater than zero");
        require(WeekMath.isValidWTime(expiry), "Expiry must be a valid week beginning");

        require(expiry >= block.timestamp + Constants.MIN_LOCK_DURATION, "Lock duration too short");
        require(expiry <= block.timestamp + Constants.MAX_LOCK_DURATION, "Lock duration too long");

        // Validate delegate if specified
        if (delegate != address(0)) {
            require(isRegisteredDelegate[delegate], "Delegate not registered");
            require(delegate != user, "Cannot delegate to self");
        }

        // update global and user veBalance
        //(DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

        // --------- create lock ---------

            // vaultId generation
            bytes32 lockId;
            {
                uint256 salt = block.number;
                lockId = _generateVaultId(salt, msg.sender);
                while (locks[lockId].lockId != bytes32(0)) lockId = _generateVaultId(--salt, msg.sender);      // If lockId exists, generate new random Id
            }

            DataTypes.Lock memory newLock;
                newLock.lockId = lockId; 
                newLock.creator = msg.sender;
                newLock.delegate = delegate;        //note: we might be setting this to zero; but no point doing if(delegate != address(0))
                if (isMoca) newLock.moca = uint128(amount);
                else newLock.esMoca = uint128(amount);
                newLock.expiry = expiry;
            // storage: book lock
            locks[lockId] = newLock;

            // get lock's veBalance
            DataTypes.VeBalance memory veIncoming = _convertToVeBalance(newLock);
            // update lock history
            _pushCheckpoint(lockHistory[lockId], veIncoming, currentWeekStart);

            // EMIT LOCK CREATED

        
        // --------- conditional updates based on delegation ---------

        if(delegate != address(0)) {
        
            // DELEGATED LOCK: update delegate and global
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veDelegate, uint128 currentWeekStart) = _updateDelegateAndGlobal(delegate);
        
            // add new lock to global state
            veGlobal_.bias += veIncoming.bias;
            veGlobal_.slope += veIncoming.slope;

            // STORAGE: book updated veGlobal & schedule slope change
            veGlobal = veGlobal_;
            slopeChanges[expiry] += veIncoming.slope;

            // add new lock to delegate's aggregated veBalance
            veDelegate.bias += veIncoming.bias;
            veDelegate.slope += veIncoming.slope;
            
            // STORAGE: book updated veDelegate & schedule slope change
            delegateHistory[delegate][currentWeekStart] = veDelegate;
            delegateSlopeChanges[delegate][expiry] += veIncoming.slope;

            // Mint to delegate
            _mint(delegate, veIncoming.bias);

        } else {
            // PERSONAL LOCK: update user and global
            (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(user);
            
            // add new lock to global state
            veGlobal_.bias += veIncoming.bias;
            veGlobal_.slope += veIncoming.slope;
            
            // STORAGE: book updated veGlobal & schedule slope change
            veGlobal = veGlobal_;
            slopeChanges[expiry] += veIncoming.slope;

            // add new lock to user's aggregated veBalance
            veUser.bias += veIncoming.bias;
            veUser.slope += veIncoming.slope;
            
            // STORAGE: book updated veUser & schedule slope change
            userHistory[user][currentWeekStart] = veUser;
            userSlopeChanges[user][expiry] += veIncoming.slope;

            // MINT to user
            _mint(user, veIncoming.bias);
        }

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

    // does not update veGlobal. updates lastUpdatedTimestamp, totalSupplyAt[]
    function _updateGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentWeekStart) internal returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current week 
        if(lastUpdatedAt >= currentWeekStart) return (veGlobal_); // no new week, no new checkpoint

        // first time: no prior updates | set global lastUpdatedTimestamp
        if(lastUpdatedAt == 0) {
            lastUpdatedTimestamp = currentWeekStart;   // move forward the anchor point to skip empty weeks
            return veGlobal_;
        }

        // update global veBalance
        while (lastUpdatedAt < currentWeekStart) {
            // advance 1 week/epoch
            lastUpdatedAt += Constants.WEEK;                  

            // decrement decay for this week & remove any scheduled slope changes 
            veGlobal_ = subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);

            // book ve state for the new week
            totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);
        }

        // set final lastUpdatedTimestamp
        lastUpdatedTimestamp = currentWeekStart;

        return (veGlobal_);
    }

    /**
        - user.lastUpdatedAt either matches the global.lastUpdatedAt OR is behind it
        - the global never lags behind the user
     */
    function _updateAccountAndGlobal(address account, bool isDelegate) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory, uint128) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init account veBalance
        DataTypes.VeBalance memory veAccount;

        // Get the appropriate last updated timestamp based on account type
        uint128 accountLastUpdatedAt = isDelegate ? 
            delegateLastUpdatedTimestamp[account] : 
            userLastUpdatedTimestamp[account];
        
        // get current week start
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); 

        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // set account's lastUpdatedTimestamp and veBalance
            if (isDelegate) {
                delegateLastUpdatedTimestamp[account] = currentWeekStart;
            } else {
                userLastUpdatedTimestamp[account] = currentWeekStart;
            }
            veAccount = DataTypes.VeBalance(0, 0);

            // update global: updates lastUpdatedTimestamp | may or may not have updates
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentWeekStart);

            return (veGlobal_, veAccount, currentWeekStart);
        }
                
        // load account's previous veBalance: if both global and account are up to date, return
        veAccount = isDelegate ? 
            delegateHistory[account][accountLastUpdatedAt] : 
            userHistory[account][accountLastUpdatedAt];
        
        if(accountLastUpdatedAt >= currentWeekStart) return (veGlobal_, veAccount, currentWeekStart); 

        // update both global and account veBalance to current week
        while (accountLastUpdatedAt < currentWeekStart) {

            // advance 1 week
            accountLastUpdatedAt += Constants.WEEK;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply decay for this week && remove any scheduled slope changes from expiring locks
                veGlobal_ = subtractExpired(veGlobal_, slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve state for the new week
                totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: decrement decay for this week & remove any scheduled slope changes from expiring locks
            uint128 expiringSlope = isDelegate ? 
                delegateSlopeChanges[account][accountLastUpdatedAt] : 
                userSlopeChanges[account][accountLastUpdatedAt];
            
            veAccount = subtractExpired(veAccount, expiringSlope, accountLastUpdatedAt);
            
            // book account checkpoint 
            if (isDelegate) {
                delegateHistory[account][accountLastUpdatedAt] = veAccount;
            } else {
                userHistory[account][accountLastUpdatedAt] = veAccount;
            }
        }

        // set final lastUpdatedTimestamp
        lastUpdatedTimestamp = accountLastUpdatedAt;
        if (isDelegate) {
            delegateLastUpdatedTimestamp[account] = accountLastUpdatedAt;
        } else {
            userLastUpdatedTimestamp[account] = accountLastUpdatedAt;
        }
        
        // return
        return (veGlobal_, veAccount, currentWeekStart);
    }

    // note: any possible rounding errors due to calc. of delta; instead of removed old then add new?
    function _modifyPosition(
        DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, DataTypes.Lock memory oldLock, DataTypes.Lock memory newLock, uint128 currentWeekStart) internal returns (DataTypes.VeBalance memory) {

        // get delta btw old and new
        DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(oldLock);
        DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(newLock);

        // get delta
        DataTypes.VeBalance memory increaseInVeBalance = _sub(newVeBalance, oldVeBalance);

        // update global
        veGlobal_ = _add(veGlobal_, increaseInVeBalance);
        slopeChanges[newLock.expiry] += increaseInVeBalance.slope;

        // update user
        veUser = _add(veUser, increaseInVeBalance);
        userSlopeChanges[msg.sender][newLock.expiry] += increaseInVeBalance.slope;

        // storage
        veGlobal = veGlobal_;
        userHistory[msg.sender][currentWeekStart] = veUser;

        // NOTE: do you want to overhaaful this to handle early redemption as well?
        // mint the delta (difference between old and new veBalance)
        if (newVeBalance.bias > oldVeBalance.bias) {
            _mint(msg.sender, newVeBalance.bias - oldVeBalance.bias);
        } else if (oldVeBalance.bias > newVeBalance.bias) {
            _burn(msg.sender, oldVeBalance.bias - newVeBalance.bias);
        }

        return newVeBalance;
    }

//-------------------------------internal: view-----------------------------------------------------


    function _viewGlobal(DataTypes.VeBalance memory veGlobal_, uint128 lastUpdatedAt, uint128 currentWeekStart) internal view returns (DataTypes.VeBalance memory) {       
        // nothing to update: lastUpdate was within current week 
        if(lastUpdatedAt >= currentWeekStart) return (veGlobal_); // no new week, no new checkpoint

        // skip first time: no prior updates needed | set lastUpdatedAt | return
        if(lastUpdatedAt == 0) {
            veGlobal_.lastUpdatedAt = currentWeekStart;   // move forward the anchor point to skip empty weeks
            return veGlobal_;
        }

        // update global veBalance
        while (lastUpdatedAt < currentWeekStart) {
            // advance 1 week/epoch
            lastUpdatedAt += Constants.WEEK;                  

            // decrement decay for this week | remove any scheduled slope changes from expiring locks
            veGlobal_ = subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);
        }

        // return
        return (veGlobal_);
    }

    function _viewUserAndGlobal(address user) internal view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory, uint128) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init user veUser
        DataTypes.VeBalance memory veUser;

        // user's lastUpdatedTimestamp either matches global or lags behind it
        uint128 userLastUpdatedAt = userLastUpdatedTimestamp[user];

        // get current week start
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); 


        // user's first time: no prior updates to execute 
        if (userLastUpdatedAt == 0) {
            userLastUpdatedTimestamp[user] = currentWeekStart;
            veUser = DataTypes.VeBalance(0, 0);

            // if global also not started: set lastUpdatedAt to now
            if (lastUpdatedTimestamp_ == 0) {
                //lastUpdatedTimestamp = currentWeekStart;
            } else{
                // note: global started; update and return
                veGlobal_ = _viewGlobal(veGlobal_, lastUpdatedTimestamp_, currentWeekStart);
            }

            return (veGlobal_, veUser, currentWeekStart);
        }

        // load user's previous veBalance: if both global and user are up to date, return
        veUser = userHistory[user][userLastUpdatedAt];
        if(userLastUpdatedAt >= currentWeekStart) return (veGlobal_, veUser, currentWeekStart); 

        // update both global and user veBalance to current week
        while (userLastUpdatedAt < currentWeekStart) {

            // advance 1 week
            userLastUpdatedAt += Constants.WEEK;

            // update global: if needed 
            if(lastUpdatedTimestamp_ < userLastUpdatedAt) {
                
                // apply decay for this week && remove any scheduled slope changes from expiring locks
                veGlobal_ = subtractExpired(veGlobal_, slopeChanges[userLastUpdatedAt], userLastUpdatedAt);
            }

            // update user: decrement decay for this week & remove any scheduled slope changes from expiring locks
            veUser = subtractExpired(veUser, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
        }
        
        return (veGlobal_, veUser, currentWeekStart);
    }

    function _viewAccount(address account, bool forDelegate) internal view returns (DataTypes.VeBalance memory) {
        // init account veBalance
        DataTypes.VeBalance memory veBalance;

        // Get the appropriate last updated timestamp based on account type
        uint128 lastUpdatedAt = forDelegate ? delegateLastUpdatedTimestamp[account] : userLastUpdatedTimestamp[account];
        
        // if account's first time: no prior updates to execute 
        if(lastUpdatedAt == 0) return veBalance;

        // load account's previous veBalance from appropriate history
        veBalance = forDelegate ? delegateHistory[account][lastUpdatedAt] : userHistory[account][lastUpdatedAt];
        
        // get current week start
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); 
        
        // already up to date: return
        if(lastUpdatedAt >= currentWeekStart) return veBalance;

        // update account veBalance to current week
        while (lastUpdatedAt < currentWeekStart) {
            lastUpdatedAt += Constants.WEEK;
            // Use appropriate slope changes mapping based on account type
            uint128 expiringSlope = forDelegate ? 
                delegateSlopeChanges[account][lastUpdatedAt] : 
                userSlopeChanges[account][lastUpdatedAt];
            
            veBalance = subtractExpired(veBalance, expiringSlope, lastUpdatedAt);
        }

        return veBalance;
    }

    function _viewUser(address user) internal view returns (DataTypes.VeBalance memory) {
        return _viewAccount(user, false);
    }

    function _viewDelegate(address delegate) internal view returns (DataTypes.VeBalance memory) {
        return _viewAccount(delegate, true);
    }
    
    /**
     * @notice Generic function to view account balance (either user or delegate)
     * @param account The address to view
     * @param accountType The type of account (0 for user, 1 for delegate)
     * @return veBalance The voting escrow balance
     */
    function _viewAccountByType(address account, uint8 accountType) internal view returns (DataTypes.VeBalance memory) {
        return _viewAccount(account, accountType == 1);
    }

// ---- my original ref: before combining. -------

    function _viewUserOld(address user) internal view returns (DataTypes.VeBalance memory) {
        // init user veUser
        DataTypes.VeBalance memory veUser;

        uint128 userLastUpdatedAt = userLastUpdatedTimestamp[user];
        // if user's first time: no prior updates to execute 
        if(userLastUpdatedAt == 0) return veUser;

        // load user's previous veBalance
        veUser = userHistory[user][userLastUpdatedAt];
        
        // get current week start
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); 
        // already up to date: return
        if(userLastUpdatedAt >= currentWeekStart) return veUser;

        // update user veBalance to current week
        while (userLastUpdatedAt < currentWeekStart) {
            userLastUpdatedAt += Constants.WEEK;
            veUser = subtractExpired(veUser, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
        }

        return veUser;
    }

    function _viewDelegateOld(address delegate) internal view returns (DataTypes.VeBalance memory) {
        // init account veBalance
        DataTypes.VeBalance memory veBalance;

        // Get the appropriate last updated timestamp based on account type
        uint128 lastUpdatedAt = delegateLastUpdatedTimestamp[delegate];
        
        // if account's first time: no prior updates to execute 
        if(lastUpdatedAt == 0) return veBalance;

        // load account's previous veBalance from appropriate history
        veBalance = delegateHistory[delegate][lastUpdatedAt];
        
        // get current week start
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); 
        
        // already up to date: return
        if(lastUpdatedAt >= currentWeekStart) return veBalance;

        // update account veBalance to current week
        while (lastUpdatedAt < currentWeekStart) {
            lastUpdatedAt += Constants.WEEK;
            // Use appropriate slope changes mapping based on account type
            uint128 expiringSlope = delegateSlopeChanges[delegate][lastUpdatedAt];
            
            veBalance = subtractExpired(veBalance, expiringSlope, lastUpdatedAt);
        }

        return veBalance;
    }

//-------------------------------lib-----------------------------------------------------

    // removed expired locks from veBalance | does not set lastUpdatedAt
    function subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint128 bias = a.bias - (expiringSlope * expiry);       // remove decayed ve
        uint128 slope = a.slope - expiringSlope;                 // remove expiring slope

        DataTypes.VeBalance memory res;
            res.bias = bias;
            res.slope = slope;

        return res;
    }

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

    // time is timestamp, not duration | forward-lookingl; not historical search
    function _getValueAt(DataTypes.VeBalance memory a, uint128 time) internal pure returns (uint128) {
        if(a.bias < (a.slope * time)) {
            return 0;
        }

        return a.bias - (a.slope * time);
    }

    // calc. veBalance{bias,slope} from lock; based on expiry time
    function _convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;

        uint128 totalAmount = lock.moca + lock.esMoca;

        veBalance.slope = totalAmount / Constants.MAX_LOCK_DURATION;
        veBalance.bias = veBalance.slope * lock.expiry;

        return veBalance;
    }

    function _pushCheckpoint(DataTypes.Checkpoint[] storage lockHistory_, DataTypes.VeBalance memory veBalance, uint128 currentWeekStart) internal {
        uint256 length = lockHistory_.length;

        // if last checkpoint is in the same week as incoming; overwrite
        if(length > 0 && lockHistory_[length - 1].lastUpdatedAt == currentWeekStart) {
            lockHistory_[length - 1].veBalance = veBalance;
        } else {
            // new checkpoint for new week: set lastUpdatedAt
            lockHistory_.push(DataTypes.Checkpoint(veBalance, currentWeekStart));
        }
    }


//-------------------------------block: transfer/transferFrom -----------------------------------------

    //note: white-list transfers?

    function transfer(address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

//-------------------------------view functions-----------------------------------------

    // totalSupplyCurrent: update from last to now; return current veBalance
    // override: ERC20 totalSupply()
    function totalSupply() public view override returns (uint256) {
        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, WeekMath.getWeekStartTimestamp(uint128(block.timestamp)));
        return _getValueAt(veGlobal_, uint128(block.timestamp));
    }

    // note: do we really needs this?
    // forward-looking; not historical search | for historical search, use totalSupplyAt[]; limited to weekly checkpoints
    function totalSupplyInFuture(uint128 time) public view returns (uint256) {
        require(time <= block.timestamp, "Timestamp is in the future");

        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, WeekMath.getWeekStartTimestamp(time));
        return _getValueAt(veGlobal_, time);
    }


    // override: ERC20 balanceOf() | use _viewUser to save gas when Voting.sol calls this
    function balanceOf(address user) public view override returns (uint128) {

        DataTypes.VeBalance memory veUser = _viewUser(user);
        if(veUser.bias == 0) return 0; 

        // calculate current voting power based on bias and slope at current timestamp
        return _getValueAt(veUser, uint128(block.timestamp));
    }

    // historical search. since veBalances are stored weekly, find the closest week boundary to the timestamp and interpolate from there
    function balanceOfAt(address user, uint128 time) external view returns (uint128) {
        require(time <= block.timestamp, "Timestamp is in the future");

        // find the closest weekly boundary (wTime) that is not larger than the input time
        uint128 wTime = WeekMath.getWeekStartTimestamp(time);
        
        // get the user's veBalance at that weekly boundary
        DataTypes.VeBalance memory veUser = userHistory[user][wTime];
        
        // calculate the voting power at the exact timestamp using the veBalance from the closest past weekly boundary
        return _getValueAt(veUser, time);
    }


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


/**
    function _increasePosition(DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, DataTypes.Lock memory lock, uint128 amountToIncrease, uint128 durationToIncrease, uint128 currentWeekStart) internal returns (DataTypes.VeBalance memory) {
        
        // ---- remove the old veBalance: global + user ----
        DataTypes.VeBalance memory oldVeBalance = _convertToVeBalance(lock);
        
        veGlobal_ = _sub(veGlobal_, oldVeBalance);
        slopeChanges[lock.expiry] -= oldVeBalance.slope;
        
        veUser = _sub(veUser, oldVeBalance);
        userSlopeChanges[msg.sender][lock.expiry] -= oldVeBalance.slope;

        // ---- recalculate the new veBalance ----
        DataTypes.Lock memory newLock;
            newLock.amount = lock.amount + amountToIncrease;
            newLock.expiry = lock.expiry + durationToIncrease;

        DataTypes.VeBalance memory newVeBalance = _convertToVeBalance(newLock);

        // ---- add the new veBalance: global + user ----
        veGlobal_ = _add(veGlobal_, newVeBalance);
        slopeChanges[newLock.expiry] += newVeBalance.slope;
        
        veUser = _add(veUser, newVeBalance);
        userSlopeChanges[msg.sender][newLock.expiry] += newVeBalance.slope;

        // storage
        veGlobal = veGlobal_;
        userHistory[msg.sender][currentWeekStart] = veUser;
        lockHistory[lock.lockId].push(DataTypes.Checkpoint(newVeBalance, currentWeekStart));

        return newVeBalance;
    }
 */