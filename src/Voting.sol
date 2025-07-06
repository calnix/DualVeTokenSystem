// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {IAirKit} from "./interfaces/IAirKit.sol";

contract Voting is AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable esMOCA;
    IERC20 public immutable veMOCA;
    IAirKit public immutable AIRKIT;    //airkit contract: books verification payments by verifiers
    
    uint256 public constant PRECISION_BASE = 10_000;    // 100%: 10_000, 1%: 100, 0.1%: 10 | expressed in 2dp precision (XX.yy)
    
    // voting epoch
    uint256 public CURRENT_EPOCH;
    uint256 public CURRENT_EPOCH_END_TIME;
    uint256 public EPOCH_DURATION = 28 days;

    // incentives
    uint256 public INCENTIVE_FACTOR;
    uint256 public TOTAL_INCENTIVES_DEPOSITED;
    uint256 public TOTAL_INCENTIVES_CLAIMED;
    
    // voting epoch data
    struct EpochData {
        uint256 totalVotes;
        uint256 totalIncentives;
        uint256 incentivePerVote;
        uint256 totalClaimed;
    }
    
    // Pool data - global
    struct Pool {
        bytes32 poolId;       // poolId = credentialId  
        bool isActive;        // active+inactive: pause pool
        bool isWhitelisted;   // whitelist+blacklist
        uint256 totalVotes;
        uint256 totalIncentives;
        uint256 totalClaimed;
    }

    // Pool data - epoch
    struct PoolEpoch {
        uint256 votes;
        uint256 incentives;
        uint256 claimed;
    }

    // user data
    struct User {
        uint256 votes;
        uint256 rewards;
        uint256 claimed;
    }

    // epoch data
    mapping(uint256 epoch => EpochData epochData) public epochs;

    // pool data
    mapping(bytes32 poolId => Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => PoolEpoch poolEpoch)) public epochPools;

    // user data
    mapping(uint256 epoch => mapping(address user => User userEpochData)) public userEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => User userPoolData))) public userEpochPoolData;
    
    // verifier
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => uint256 claimed))) public verifierClaimedSubsidies;

//-------------------------------constructor------------------------------------------

    constructor(address veMoca_, address airKit, address owner, uint256 epochDuration) {
        
        veMOCA = IERC20(veMoca_);
        EPOCH_DURATION = epochDuration;

        AIRKIT = IAirKit(airKit);
        
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }


//-------------------------------veHolder functions------------------------------------------

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
        epochs[CURRENT_EPOCH].totalVotes += amount;

        // update pool's total votes
        epochPools[CURRENT_EPOCH][poolId].votes += amount;
        pools[poolId].totalVotes += amount;

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
        pools[fromPoolId].totalVotes -= amount;
        epochPools[CURRENT_EPOCH][fromPoolId].votes -= amount;
        
        pools[toPoolId].totalVotes += amount;
        epochPools[CURRENT_EPOCH][toPoolId].votes += amount;
        
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
        }

        // event
    }

    // for veHolders tt voted get esMoca -> from verification fee split
    function claimRewards(uint256 epochNumber, bytes32 poolId) external {
        // check epoch
        _checkEpoch();
        
        // can only claim rewards for epoch that has ended
        require(epochNumber < CURRENT_EPOCH, "Cannot claim rewards for current or future epochs");

        // get veHolder's total votes spent for the epoch
        uint256 userTotalVotesSpent = userEpochData[epochNumber][msg.sender].votes;
        require(userTotalVotesSpent > 0, "No votes spent in epoch");

        /**
            on AIRKIT:
            - get total verification fees for {pool, epoch}
            - get how much of the verification fee is to be split to veHolders
            - get how much of the split is to be claimed by veHolder
            - transfer esMoca to veHolder
            - update veHolder's claimed
            - update veHolder's rewards
         */
    }

    function claimAndLock(uint256 amount, uint128 expiry, bool isMoca) external {
        // need to call VotingEscrowMoca.increaseAmount()
    }

//-------------------------------verifier functions------------------------------------------

    function claimIncentives(uint256 epochNumber, bytes32 poolId) external {
        // check epoch
        _checkEpoch();

        // can only claim incentives for epoch that has ended
        require(epochNumber < CURRENT_EPOCH, "Cannot claim incentives for current or future epochs");

        // get epoch
        EpochData memory epoch = epochs[epochNumber];
        
        // epoch: calculate incentives if not already done
        if(epoch.incentivePerVote == 0) {
            // non-zero votes: else division by zero
            require(epoch.totalVotes > 0, "No votes in pool");
            require(epoch.totalIncentives > 0, "No incentives in epoch");

            // calculate incentive per vote for the epoch
            epoch.incentivePerVote = epoch.totalIncentives / epoch.totalVotes;

            // storage update
            epochs[epochNumber] = epoch;

            // emit event
        }

        // get epochPool
        PoolEpoch memory epochPool = epochPools[epochNumber][poolId];

        // epochPool: book incentives if not already done
        if(epochPool.incentives == 0) {
            // non-zero votes: else division by zero
            require(epochPool.votes > 0, "No votes in pool");

            // book pool incentives for the epoch
            epochPool.incentives = epoch.incentivePerVote * epochPool.votes;

            // storage update
            epochPools[epochNumber][poolId] = epochPool;

            // emit event
        }

        // get verifier's total spend for {pool, epoch}
        uint256 verifierTotalSpend = AIRKIT.getTotalSpend(msg.sender, epochNumber, poolId);
        require(verifierTotalSpend > 0, "No spend in epoch");

        // calculate incentives
        uint256 incentives = verifierTotalSpend * epoch.incentivePerVote * INCENTIVE_FACTOR / PRECISION_BASE;

        // book verifier's incentives for the epoch
        verifierClaimedSubsidies[epochNumber][poolId][msg.sender] = incentives;

        // update epoch's total claimed
        epochs[epochNumber].totalClaimed += incentives;
        epochPools[epochNumber][poolId].claimed += incentives;

        TOTAL_INCENTIVES_CLAIMED += incentives;
        
        // event
        
        // transfer esMoca to verifier: 
        // must whitelist this contract for transfers
        esMOCA.transfer(msg.sender, incentives);        // use vault?
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


    //subsidies for {epoch, pool}: for verifiers to claim
    function setIncentives(uint256 epoch, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // sanity: future epoch + no incentives set yet
        require(epoch > CURRENT_EPOCH, "Cannot set incentives for current or past epochs");
        require(epochs[epoch].totalIncentives == 0, "Incentives already set for this epoch");
        
        epochs[epoch].totalIncentives += amount;

        TOTAL_INCENTIVES_DEPOSITED += amount;

        // event

        // transfer esMoca to voting contract
        esMOCA.transfer(address(this), amount);
    }

    //withdraw surplus incentives
}


/** NOTE:

## auto-staking

Users can opt for rewards to be auto-staked to the same lock

1. claim on a per lock basis and autocompound
2. claimAll()
 */