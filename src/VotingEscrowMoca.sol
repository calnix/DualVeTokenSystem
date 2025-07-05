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
    //uint256 public constant MAX_PENALTY_PCT = 50; // Default 50% maximum penalty
    //uint256 public constant PRECISION_BASE = 100; // 100%: 100, 1%: 1 | no decimal places

//-------------------------------mapping------------------------------------------

    // lock
    mapping(bytes32 lockId => DataTypes.LockedPosition lock) public locks;
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

//-------------------------------external functions------------------------------------------


    function createLock(uint256 amount, uint128 expiry, bool isMoca) external returns (bytes32) {
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

        // create lock
        DataTypes.LockedPosition memory newLock;
            newLock.lockId = lockId;
            newLock.creator = msg.sender;
            if (isMoca) newLock.moca = uint128(amount);
            else newLock.esMoca = uint128(amount);
            newLock.expiry = expiry;
        // storage: book lock
        locks[lockId] = newLock;

        // get lock's veBalance
        DataTypes.VeBalance memory incomingVeBalance = _convertToVeBalance(newLock, isMoca);
        // update lock history
        _pushCheckpoint(lockHistory[lockId], incomingVeBalance, currentWeekStart);

        // EMIT LOCK CREATED

        // --------- newlock: increment global state ---------

        // add new position to global state
        veGlobal_.bias += incomingVeBalance.bias;
        veGlobal_.slope += incomingVeBalance.slope;
        
        // storage: book updated veGlobal & schedule slope change
        veGlobal = veGlobal_;
        slopeChanges[expiry] += incomingVeBalance.slope;

        // --------- newLock: increment user state ---------
        
        // add new position to user's aggregated veBalance
        veUser.bias += incomingVeBalance.bias;
        veUser.slope += incomingVeBalance.slope;

        // storage: book updated veUser & schedule slope change
        userHistory[msg.sender][currentWeekStart] = veUser;
        userSlopeChanges[msg.sender][expiry] += incomingVeBalance.slope;

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
        _mint(msg.sender, incomingVeBalance.bias);

        return lockId;
    }


    

//-------------------------------internal-----------------------------------------------------

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

    // time is timestamp, not duration
    function _getValueAt(DataTypes.VeBalance memory a, uint128 time) internal pure returns (uint128) {
        if(a.bias < (a.slope * time)) {
            return 0;
        }

        return a.bias - (a.slope * time);
    }

    // calc. veBalance{bias,slope} from lock; based on expiry time | note: need to update for esMoca
    function _convertToVeBalance(DataTypes.LockedPosition memory lock, bool isMoca) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;
        
        veBalance.slope = isMoca ? uint128(lock.moca / Constants.MAX_LOCK_DURATION) : uint128(lock.esMoca / Constants.MAX_LOCK_DURATION);
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


//-------------------------------token functions-----------------------------------------


    function balanceOf(address user) public view override returns (uint256) {

        (DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _viewUserAndGlobal(user);
        if(veUser.bias == 0) return 0; 

        // calculate current voting power based on bias and slope at current timestamp
        return _getValueAt(veUser, uint128(block.timestamp));
    }


    function transfer(address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

//-------------------------------view functions-----------------------------------------

    function totalSupplyCurrent() public view virtual override returns (uint256) {
        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, WeekMath.getWeekStartTimestamp(uint128(block.timestamp)));
        return _getValueAt(veGlobal_, uint128(block.timestamp));
    }


    function totalSupplyAt(uint128 time) public view virtual override returns (uint256) {
        DataTypes.VeBalance memory veGlobal_ = _viewGlobal(veGlobal, lastUpdatedTimestamp, WeekMath.getWeekStartTimestamp(time));
        return _getValueAt(veGlobal_, time);
    }
        
}


/**
        // book all prior checkpoints | veGlobal not stored
        //DataTypes.VeBalance memory veGlobal_ = _updateGlobal();

        // update user aggregated
        /**
            treat the user as 'global'. 
            must do prior updates to bring user's bias and slope to current week. [_updateGlobal]
            then add new position to user's aggregated veBalance
            then schedule slope changes for the new position

            1. bias
            2. slope
            3. scheduled slope changes
            
            note:
            could possibly skip the prior updates, and just add the new position to user's veBalance + schedule changes
            then have view fn balanceOf do the prior updates. saves gas
         */
        //DataTypes.VeBalance memory veUser = _updateUser(msg.sender);




/**
    cos' we calculate bias from T0 to Now
    the starting anchor point for the contract is T0
    meaning, 
    - the first week start is T0 
    - the second week start is T0+1 week
    - the third week start is T0+2 weeks
    - etc.

    so on user's passing expiry
    - expiry is specified timestamp representing endTime; not duration
    - expiry is sanitized isValidTime: expiry % Constants.WEEK == 0
    - this ensures that the endTime lies on a week boundary; not inbtw
    - 

    this would not be the case if our starting point was some arbitrary time; not T0
    as the weekly count would start at TX, and time checks would have to be done with respect to TX
 */
