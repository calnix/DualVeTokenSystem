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

    // global
    address public treasury;
    uint256 public totalLockedMoca;
    uint256 public totalLockedEsMoca;
    DataTypes.VeBalance public veGlobal;

    // history
    //uint256 public EPOCH;                     // its helpful; but not needed.
    //uint128 public lastSlopeChangeAppliedAt; // timestamp of last weekly epoch update

    // early redemption penalty
    //uint256 public constant MAX_PENALTY_PCT = 50; // Default 50% maximum penalty
    //uint256 public constant PRECISION_BASE = 100; // 100%: 100, 1%: 1 | no decimal places

//-------------------------------mapping------------------------------------------

    // lock
    mapping(bytes32 lockId => DataTypes.LockedPosition lock) public locks;
    // Saving VeBalance checkpoints, for each week. use binary search to find the checkpoint at any wTime
    mapping(bytes32 lockId => DataTypes.VeBalance[] vePoints) public lockHistory;


    // scheduled global slope changes
    mapping(uint128 wTime => uint128 slopeChange) public slopeChanges;
    // saving totalSupply checkpoint for each week
    mapping(uint128 wTime => uint256 totalSupply) public totalSupplyAt; //note: do i need to save bias and slope?

    // user data
    //mapping(address user => DataTypes.User userAggregated) public users;
    mapping(address user => mapping(uint128 wTime => uint128 slopeChange)) public userSlopeChanges;
    mapping(address user => DataTypes.VeBalance[] vePoints) public userHistory;


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
        
        // book all prior checkpoints | veGlobal not stored
        DataTypes.VeBalance memory veGlobal_ = _updateGlobal();
     
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
        DataTypes.VeBalance memory veUser = _updateUser(msg.sender);



        // --------- lock creation ---------

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

        // get lock's veBalance | does not set .lastUpdatedAt
        DataTypes.VeBalance memory incomingVeBalance = _convertToVeBalance(newLock, isMoca);
        // update lock history | sets .lastUpdatedAt
        _pushCheckpoint(lockHistory[lockId], incomingVeBalance);

        // --------- increment: global state ---------

        // add new position to global state
        veGlobal_.bias += incomingVeBalance.bias;
        veGlobal_.slope += incomingVeBalance.slope;
        
        // storage: book updated veGlobal & schedule slope change
        veGlobal = veGlobal_;
        slopeChanges[expiry] += incomingVeBalance.slope;

        // --------- increment: user state ---------
        
        // add new position to user's aggregated veBalance
        veUser.bias += incomingVeBalance.bias;
        veUser.slope += incomingVeBalance.slope;

        // schedule slope change
        userSlopeChanges[msg.sender][expiry] += incomingVeBalance.slope;

        // update user history
        _pushCheckpoint(userHistory[msg.sender], veUser);

        // transfer tokens to contract
        if (isMoca) {
            mocaToken.safeTransferFrom(msg.sender, address(this), amount);
        } else {
            esMocaToken.safeTransferFrom(msg.sender, address(this), amount);
        }

        // emit event

        return lockId;
    }

//-------------------------------internal-----------------------------------------------------

    ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }


    function _updateGlobal() internal returns (DataTypes.VeBalance memory) {
        // cache global veBalance
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        
        //
        uint128 lastUpdatedAt = veGlobal_.lastUpdatedAt;
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); // express in weekly bucket
        // nothing to update: lastUpdate was within current week 
        if(lastUpdatedAt >= currentWeekStart) return (veGlobal_); // no new week, no new checkpoint

        // skip first time: no prior updates needed | set lastUpdatedAt | return
        if(lastUpdatedAt == 0) {
            veGlobal_.lastUpdatedAt = currentWeekStart;   // move forward the anchor point to skip empty weeks
            return veGlobal;
        }

        // update global veBalance
        while (lastUpdatedAt < currentWeekStart) {
            // advance 1 week/epoch
            lastUpdatedAt += Constants.WEEK;                  

            // decrement decay for this week | remove any scheduled slope changes from expiring locks
            //veGlobal.bias = _getValueAt(veGlobal, lastUpdatedAt);
            //veGlobal.slope -= slopeChanges[lastUpdatedAt];
            //veGlobal.lastUpdatedAt = lastUpdatedAt;
            veGlobal_ = subtractExpired(veGlobal_, slopeChanges[lastUpdatedAt], lastUpdatedAt);

            // book ve supply for the new week
            totalSupplyAt[lastUpdatedAt] = _getValueAt(veGlobal_, lastUpdatedAt);
        }

        // set final lastUpdatedAt
        veGlobal_.lastUpdatedAt = lastUpdatedAt;

        // return
        return (veGlobal_);
    }

    // _updateGlobal ran before this: so veGlobal.lastUpdatedAt is not stale
    function _updateUser(address user) internal returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory userVeBalance;

        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); // express in weekly bucket

        // first time: no prior updates needed | set lastUpdatedAt to latest global 
        if (userHistory[user].length == 0) {
            userVeBalance = DataTypes.VeBalance(0, 0, currentWeekStart);
            return userVeBalance;
        }

        userVeBalance = userHistory[user][userHistory[user].length - 1];
        uint128 lastUpdatedAt = userVeBalance.lastUpdatedAt;

        // nothing to update: lastUpdate was within current week epoch
        if(lastUpdatedAt >= currentWeekStart) return userVeBalance;

        // update user's veBalance to current week
        while (lastUpdatedAt < currentWeekStart) {
            // advance 1 week
            lastUpdatedAt += Constants.WEEK;

            // decrement decay for this week | remove any scheduled slope changes from expiring locks
            userVeBalance = subtractExpired(userVeBalance, userSlopeChanges[user][lastUpdatedAt], lastUpdatedAt);

            //book user state for the new week
            _pushCheckpoint(userHistory[user], userVeBalance);
        }

        return userVeBalance;
    }

    function _viewUpdateUser(address user) internal view returns (DataTypes.VeBalance memory) {
        // get user's latest veBalance
        DataTypes.VeBalance memory userVeBalance = userHistory[user][userHistory[user].length - 1];

        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); // express in weekly bucket
        
        // first time: no prior updates needed | set lastUpdatedAt to latest global 
        if (userHistory[user].length == 0) {
            userVeBalance = DataTypes.VeBalance(0, 0, currentWeekStart);
            return userVeBalance;
        }
        
        userVeBalance = userHistory[user][userHistory[user].length - 1];
        uint128 lastUpdatedAt = userVeBalance.lastUpdatedAt;

        // nothing to update: lastUpdate was within current week epoch
        if(lastUpdatedAt >= currentWeekStart) return userVeBalance;

        // update user's veBalance to current week
        while (lastUpdatedAt < currentWeekStart) {
            // advance 1 week
            lastUpdatedAt += Constants.WEEK;

            // decrement decay for this week | remove any scheduled slope changes from expiring locks
            userVeBalance = subtractExpired(userVeBalance, userSlopeChanges[user][lastUpdatedAt], lastUpdatedAt);

            //book user state for the new week
            //_pushCheckpoint(userHistory[user], userVeBalance);
        }

        return userVeBalance;
    }
    

//-------------------------------lib-----------------------------------------------------


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

    //note: this could store zero-value checkpoints?
    function _pushCheckpoint(DataTypes.VeBalance[] storage lockHistory, DataTypes.VeBalance memory veBalance) internal {
        uint256 length = lockHistory.length;
        // if last checkpoint is in the same week as incoming; overwrite
        if(length > 0 && lockHistory[length - 1].lastUpdatedAt == WeekMath.getCurrentWeekStart()) {
            lockHistory[length - 1] = veBalance;
        } else {
            // new checkpoint for new week: set lastUpdatedAt
            veBalance.lastUpdatedAt = WeekMath.getCurrentWeekStart();
            lockHistory.push(veBalance);
        }
    }


    // removed expired locks from veBalance | does not set lastUpdatedAt
    function subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint128 bias = a.bias - (expiringSlope * expiry);       // remove decayed ve
        uint128 slope = a.slope - expiringSlope;                 // remove expiring slope

        DataTypes.VeBalance memory res;
            res.bias = bias;
            res.slope = slope;

        return res;
    }


//-------------------------------token functions-----------------------------------------

    function balanceOf(address user) public view override returns (uint256) {
        // _pushCheckpoint in _updateUser makes storage updates.
        DataTypes.VeBalance memory veUser = _viewUpdateUser(user);
        if(veUser.bias == 0) return 0; 

        return _getValueAt(veUser, uint128(block.timestamp));
    }

/*
    function transfer(address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }
*/

//-------------------------------view functions-----------------------------------------

/*    function totalSupplyCurrent() public view virtual override returns (uint256) {
        DataTypes.VeBalance memory veGlobal = _updateGlobal();

        return _getValueAt(veGlobal, uint128(block.timestamp));
    }
*/

    //function totalSupplyAt(uint128 time) public view virtual override returns (uint256) {}
        
}



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