// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

//import {VotingEscrowTokenBase} from "./VotingEscrowTokenBase.sol";
import {WeekMath} from "./WeekMath.sol";
import {Constants} from "./Constants.sol";
import {DataTypes} from "./DataTypes.sol";

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
    - Stake MOCA tokens to receive veMOCA (voting power)
    - Longer lock periods result in higher veMOCA allocation
    - veMOCA decays linearly over time, reducing voting power
    - Formula-based calculation determines veMOCA amount based on stake amount and duration
 */

contract veMoca is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable mocaToken;
    IERC20 public immutable esMocaToken;
    address public treasury;

    // global principal
    uint256 public totalLockedMoca;
    uint256 public totalLockedEsMoca;

    // global veBalance
    DataTypes.VeBalance public veGlobal;
    uint128 public lastUpdatedTimestamp;  

    // early redemption penalty
    uint256 public constant MAX_PENALTY_PCT = 50; // Default 50% maximum penalty
    uint256 public constant PRECISION_BASE = 100; // 100%: 100, 1%: 1 | no decimal places

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

        // copy old lock: update amount and/or duration
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

        //note: for extending lock duration: must meet min duration?

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


    /** note: incomplete 
     * @notice Early redemption with penalty (partial redemption allowed)
     * @param lockId ID of the lock to redeem early
     * @param amountToRedeem Amount of veMoca to redeem
     */
    function earlyRedemption(bytes32 lockId, uint128 amountToRedeem) external {

        // check lock exists
        DataTypes.Lock memory lock = locks[lockId];
        require(lock.lockId != bytes32(0), "NoLockFound");
        require(lock.creator == msg.sender, "Only the creator can redeem early");
        require(lock.expiry > block.timestamp, "Lock has not expired");
        require(lock.isWithdrawn == false, "Lock has already been withdrawn");

        // get veBalance
        DataTypes.VeBalance memory veBalance = _convertToVeBalance(lock);
        require(veBalance.bias > 0, "No veMoca to redeem");

        // ratio of veMoca to base assets
        uint256 totalBase = lock.moca + lock.esMoca;
        uint256 veMocaRatio = veBalance.bias / totalBase;

        // calculate Penalty_Pct = (Time_left / Total_Lock_Time) × Max_Penalty_Pct
        uint256 timeLeft = lock.expiry - block.timestamp;
        uint256 penaltyPct = (MAX_PENALTY_PCT * timeLeft) / MAX_LOCK_DURATION;
        
        // apply penalty
        uint256 penalty = totalBase * penaltyPct / PRECISION_BASE;

        // calculate amount to return
        uint256 amountToReturn = totalBase - penalty;


        // burn ve

        // transfer tokens to user
        
        
    }


//-------------------------------admin functions------------------------------------------


    function createLockFor(address user, uint256 amount, uint128 expiry, bool isMoca) external onlyRole(Constants.CRON_JOB_ROLE) returns (bytes32) { 
        return _createLockFor(user, amount, expiry, isMoca);
    }

//-------------------------------internal-----------------------------------------------------

    function _createLockFor(address user, uint256 amount, uint128 expiry, bool isMoca) internal returns (bytes32) {
        require(amount > 0, "Amount must be greater than zero");
        require(WeekMath.isValidWTime(expiry), "Expiry must be a valid week beginning");

        require(expiry >= block.timestamp + Constants.MIN_LOCK_DURATION, "Lock duration too short");
        require(expiry <= block.timestamp + Constants.MAX_LOCK_DURATION, "Lock duration too long");
        
        // update global and user veBalance
        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

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

        // --------- newLock: increment global state ---------

        // add new position to global state
        veGlobal_.bias += veIncoming.bias;
        veGlobal_.slope += veIncoming.slope;
        
        // storage: book updated veGlobal & schedule slope change
        veGlobal = veGlobal_;
        slopeChanges[expiry] += veIncoming.slope;

        // --------- newLock: increment user state ---------
        
        // add new position to user's aggregated veBalance
        veUser.bias += veIncoming.bias;
        veUser.slope += veIncoming.slope;

        // storage: book updated veUser & schedule slope change
        userHistory[msg.sender][currentWeekStart] = veUser;
        userSlopeChanges[msg.sender][expiry] += veIncoming.slope;

        // EMIT USER UPDATED

        // transfer tokens to contract
        if (isMoca) {
            totalLockedMoca += amount;
            mocaToken.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            totalLockedEsMoca += amount;
            esMocaToken.safeTransferFrom(msg.sender, address(this), amount);
        }

        // mint veMoca
        _mint(msg.sender, veIncoming.bias);

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
    function _updateUserAndGlobal(address user) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory, uint128) {
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
            
            // set user's lastUpdatedTimestamp and veBalance
            userLastUpdatedTimestamp[user] = currentWeekStart;
            veUser = DataTypes.VeBalance(0, 0);

            // update global: updates lastUpdatedTimestamp | may or may not have updates
            veGlobal_ = _updateGlobal(veGlobal_, lastUpdatedTimestamp_, currentWeekStart);

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
                // book ve state for the new week
                totalSupplyAt[userLastUpdatedAt] = _getValueAt(veGlobal_, userLastUpdatedAt);
            }

            // update user: decrement decay for this week & remove any scheduled slope changes from expiring locks
            veUser = subtractExpired(veUser, userSlopeChanges[user][userLastUpdatedAt], userLastUpdatedAt);
            // book user checkpoint 
            userHistory[user][userLastUpdatedAt] = veUser;
        }

        // set final lastUpdatedTimestamp
        lastUpdatedTimestamp = userLastUpdatedTimestamp[user] = userLastUpdatedAt;
        
        // return
        return (veGlobal_, veUser, currentWeekStart);
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


    // override: ERC20 balanceOf()
    function balanceOf(address user) public view override returns (uint256) {

        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _viewUserAndGlobal(user);
        if(veUser.bias == 0) return 0; 

        // calculate current voting power based on bias and slope at current timestamp
        return _getValueAt(veUser, uint128(block.timestamp));
    }

    // historical search. since veBalances are stored weekly, find the closest week boundary to the timestamp and interpolate from there
    function balanceOfAt(address user, uint128 time) external view returns (uint256) {
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