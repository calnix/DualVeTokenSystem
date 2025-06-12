// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";


contract Voting is AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable veMOCA;

    // voting epoch
    uint256 public CURRENT_EPOCH;
    uint256 public CURRENT_EPOCH_END_TIME;
    uint256 public EPOCH_DURATION = 28 days;

    // voting epoch data
    uint256 public TOTAL_VOTES_CURRENT_EPOCH;

    // pool data
    struct Pool {
        bytes32 poolId;
        bool isActive;       // active+inactive: pause pool
        bool isWhitelisted;  // whitelist+blacklist
        uint256 totalVotes;
        uint256 totalSubsidies;
        uint256 totalClaimed;
    }

    // user data
    struct User {
        uint256 votes;
        uint256 rewards;
        uint256 claimed;
    }

    mapping(bytes32 poolId => Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => Pool pool)) public epochPools;

    mapping(uint256 epoch => mapping(address user => User userEpochData)) public userEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => User userPoolData))) public userEpochPoolData;

//-------------------------------constructor------------------------------------------

    constructor(address veMoca_, address owner) {
        veMoca = IERC20(veMoca);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }


//-------------------------------user functions------------------------------------------

    function vote(bytes32 poolId, uint256 amount) external {
        // get pool
        Pool memory pool = pools[poolId];

        // check pool
        require(pool.poolId != bytes32(0), "Pool does not exist");
        require(pool.isActive, "Pool is not active");
        require(pool.isWhitelisted, "Pool is not whitelisted");

        // check epoch
        _checkEpoch();  //note: consider moving to top, and try the rest. so contract always gets updated

        // check user's veMOCA balance
        uint256 userTotalVotes = veMOCA.balanceOf(msg.sender);
        require(userTotalVotes > 0, "No veMOCA balance");

        // check user's total votes spent per epoch
        uint256 userTotalVotesSpent = userEpochData[CURRENT_EPOCH][msg.sender].votes;
        require(userTotalVotesSpent + amount <= userTotalVotes, "User has spent all their votes");

        // book votes
        TOTAL_VOTES_CURRENT_EPOCH += amount;

        // update pool's total votes
        epochPools[CURRENT_EPOCH][poolId].totalVotes += amount;

        // update user's global data
        userEpochData[CURRENT_EPOCH][msg.sender].votes += amount;
        // update user's pool data
        userEpochPoolData[CURRENT_EPOCH][poolId][msg.sender].votes += amount;

        // event
    }

    function migrateVotes(bytes32 fromPoolId, bytes32 toPoolId, uint256 amount) external {
        // check epoch
        _checkEpoch();
        
        // get pools
        Pool memory fromPool = pools[fromPoolId];
        Pool memory toPool = pools[toPoolId];
        
        // check pools
        require(fromPool.poolId != bytes32(0), "Source pool does not exist");
        require(toPool.poolId != bytes32(0), "Destination pool does not exist");
        require(toPool.isActive, "Destination pool is not active");
        require(toPool.isWhitelisted, "Destination pool is not whitelisted");
        
        // check user's votes in the source pool
        uint256 userPoolVotes = userEpochPoolData[CURRENT_EPOCH][fromPoolId][msg.sender].votes;
        require(userPoolVotes >= amount, "Insufficient votes in source pool");
        
        // update pools' total votes
        epochPools[CURRENT_EPOCH][fromPoolId].totalVotes -= amount;
        epochPools[CURRENT_EPOCH][toPoolId].totalVotes += amount;
        
        // update user's pool data
        userEpochPoolData[CURRENT_EPOCH][fromPoolId][msg.sender].votes -= amount;
        userEpochPoolData[CURRENT_EPOCH][toPoolId][msg.sender].votes += amount;
        
        // event
    }

    // allows seamless booking of votes accurately across epochs, w/o manual epoch management
    function _checkEpoch() internal {
        // note: >= or > ?
        if(block.timestamp >= CURRENT_EPOCH_END_TIME) {
            // update epoch
            ++CURRENT_EPOCH;
            // update epoch start time
            CURRENT_EPOCH_END_TIME = block.timestamp + EPOCH_DURATION;
            // reset total votes
            TOTAL_VOTES_CURRENT_EPOCH = 0;
        }

        // event
    }

//-------------------------------admin functions-----------------------------------------

    function createPool(bytes32 poolId, bool isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolId != bytes32(0), "Pool ID cannot be zero");
        require(pools[poolId].poolId == bytes32(0), "Pool already exists");
        
        pools[poolId].poolId = poolId;
        pools[poolId].isActive = isActive;
        pools[poolId].isWhitelisted = true;

        // event
    }

    // pause or resume pool: allows for selective pausing mid-epoch
    function activatePool(bytes32 poolId, bool isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
        pools[poolId].isActive = isActive;

        // event
    }

    // white or blacklist pool
    function whitelistPool(bytes32 poolId, bool isWhitelisted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
        pools[poolId].isWhitelisted = isWhitelisted;

        // event
    }


    // EPOCH MGMT
    function setEpochDuration(uint256 duration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EPOCH_DURATION = duration;
    }

}