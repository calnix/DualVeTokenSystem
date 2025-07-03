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


    // history
    uint256 public EPOCH;   
    uint128 public lastSlopeChangeAppliedAt; // timestamp of last weekly epoch update

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
    // history | epoch0: 0 struct?
    mapping(uint256 epoch => DataTypes.VeBalance veGlobal) public veGlobalHistory;

    // user data
    mapping(address user => DataTypes.User userAggregated) public users;
    mapping(address user => mapping(uint128 wTime => uint128 slopeChange)) public userSlopeChanges;
    

//-------------------------------constructor------------------------------------------

    constructor(address mocaToken_, address esMocaToken_, address owner_, address treasury_) ERC20("veMoca", "veMOCA") {
        mocaToken = IERC20(_mocaToken);
        esMocaToken = IERC20(_esMocaToken);

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
        
        // update global state
        (DataTypes.VeBalance memory veGlobal, ) = _updateGlobal();


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
            if (isMoca) newLock.moca = amount;
            else newLock.esMoca = amount;
            newLock.expiry = expiry;
        // update storage
        locks[lockId] = newLock;

        // get user veBalance: does not set lastUpdatedAt
        DataTypes.VeBalance memory incomingVeBalance = _convertToVeBalance(newLock, isMoca);

        // update lock history
        _pushCheckpoint(lockHistory[lockId], incomingVeBalance);

        // add new position to global state
        veGlobal.bias += incomingVeBalance.bias;
        veGlobal.slope += incomingVeBalance.slope;
        // storage
        veGlobalHistory[epoch] = veGlobal;

        // schedule global slope change
        slopeChanges[expiry] += incomingVeBalance.slope;

        // update user aggregated
        DataTypes.User memory user = users[msg.sender];
            if (isMoca) user.moca += amount;
            else user.esMoca += amount;            
            user.bias += incomingVeBalance.bias;
            user.slope += incomingVeBalance.slope;
        // storage
        users[msg.sender] = user;

        return lockId;
    }

//-------------------------------internal-----------------------------------------------------

    ///@dev Generate a vaultId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateVaultId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }


    function _updateGlobal() internal returns (DataTypes.VeBalance memory, uint256) {
        // get epoch
        uint256 epoch = EPOCH;

        // cache global veBalance
        DataTypes.VeBalance memory veGlobal = veGlobalHistory[epoch];

        // epoch 0: will occur only once on the first createLock
        if(epoch == 0) {
            veGlobal.lastUpdatedAt = block.timestamp;   // starting anchor point for all future epochs
            return (veGlobal, block.timestamp);
        }

        uint128 lastUpdatedAtEpoch = veGlobal.lastUpdatedAt;
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp)); // express in weekly bucket

        // nothing to update: lastUpdate was within current week epoch | no new week, no new update
        if(lastUpdatedAtEpoch >= currentWeekStart) return (veGlobal, lastUpdatedAtEpoch);

        // update global veBalance
        while (lastUpdatedAtEpoch < currentWeekStart) {
            // advance 1 week/epoch
            lastUpdatedAtEpoch += Constants.WEEK;                  
            ++epoch;

            // decrement decay for this week | remove any scheduled slope changes from expiring locks
            veGlobal.bias = _getValueAt(veGlobal, lastUpdatedAtEpoch);
            veGlobal.slope -= slopeChanges[lastUpdatedAtEpoch];
            veGlobal.lastUpdatedAt = lastUpdatedAtEpoch;

            // book global state for the new week
            veGlobalHistory[epoch] = veGlobal;
        }

        return (veGlobal, lastUpdatedAtEpoch);
    }

    function _updateUserVeBalance(address user) internal view returns (DataTypes.VeBalance memory) {
        // get user's current state
        DataTypes.User memory userData = users[user];
        DataTypes.VeBalance memory userVeBalance = DataTypes.VeBalance({
            bias: userData.bias,
            slope: userData.slope,
            lastUpdatedAt: userData.lastUpdatedAt
        });

        // if user has no locks, return zero balance
        if (userData.moca == 0 && userData.esMoca == 0) {
            return userVeBalance;
        }

        uint128 lastUpdatedAt = userVeBalance.lastUpdatedAt;
        uint128 currentWeekStart = WeekMath.getWeekStartTimestamp(uint128(block.timestamp));

        // nothing to update: lastUpdate was within current week epoch
        if(lastUpdatedAt >= currentWeekStart) return userVeBalance;

        // update user's veBalance to current week
        while (lastUpdatedAt < currentWeekStart) {
            // advance 1 week
            lastUpdatedAt += Constants.WEEK;

            // decrement decay for this week | remove any scheduled slope changes from expiring locks
            userVeBalance.bias = _getValueAt(userVeBalance, lastUpdatedAt);
            userVeBalance.slope -= userSlopeChanges[user][lastUpdatedAt];
            userVeBalance.lastUpdatedAt = lastUpdatedAt;
        }

        // update lastUpdatedAt to current week start
        userVeBalance.lastUpdatedAt = currentWeekStart;

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
        
        veBalance.slope = isMoca ? lock.moca / Constants.MAX_LOCK_DURATION : lock.esMoca / Constants.MAX_LOCK_DURATION;
        veBalance.bias = veBalance.slope * lock.expiry;
        
        return veBalance;
    }


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


    // removed expired locks from global state | note: not used yet | was meant for while loop in _updateGlobal
    function subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint128 bias = a.bias - (expiringSlope * expiry);       // remove decayed ve
        uint128 slope = a.slope - expiringSlope;                // remove expiring slope

        return DataTypes.VeBalance({bias: bias, slope: slope});
    }


//-------------------------------token functions-----------------------------------------

    function balanceOf(address user) public view override returns (uint256) {
        DataTypes.User memory userAggregated = users[user];
        if(userAggregated.bias == 0) return 0; 

        // check scheduled changes for user
        uint128 slopeChange = userSlopeChanges[user][uint128(block.timestamp)];
        if(slopeChange > 0) {
            userAggregated.slope -= slopeChange;
            userSlopeChanges[user][uint128(block.timestamp)] = 0;
        }

       return _getValueAt(DataTypes.VeBalance({bias: userAggregated.bias, slope: userAggregated.slope}), uint128(block.timestamp));
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

    function totalSupplyCurrent() public view virtual override returns (uint256) {
        (DataTypes.VeBalance memory veGlobal, ) = _updateGlobal();

        return _getValueAt(veGlobal, uint128(block.timestamp));
    }


    //function totalSupplyAt(uint128 time) public view virtual override returns (uint256) {}
        
}