// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {IAirKit} from "./interfaces/IAirKit.sol";
import {Constants} from "./Constants.sol";

contract MocaVotingController is AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable esMOCA;
    IERC20 public immutable veMOCA;
    IERC20 public immutable MOCA;       // MOCA token for registration fees
    IAirKit public immutable AIRKIT;    // airkit contract: books verification payments by verifiers
        
    // epoch anchor
    uint128 public immutable EPOCH_ZERO_TIMESTAMP;
    // CURRENT_EPOCH note: needed ? for external contract calls?

    // safety check
    uint128 public totalNumberOfPools;

    // incentives
    uint256 public INCENTIVE_FACTOR;
    uint256 public TOTAL_INCENTIVES_DEPOSITED;
    uint256 public TOTAL_INCENTIVES_CLAIMED;

    // delegate
    uint256 public REGISTRATION_FEE;
    uint256 public MAX_DELEGATE_FEE_PCT; // 100%: 100, 1%: 1 | no decimal places
    uint256 public TOTAL_REGISTRATION_FEES;
    
    
    // voting epoch data
    struct EpochData {
        uint128 epochStart;
        uint128 totalVotes;
        uint128 totalIncentives;
        uint128 incentivePerVote;
        uint128 totalClaimed;
        // safety check
        uint128 poolsFinalized;
        bool isFullyFinalized;
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
        uint256 totalVotes;
        uint256 totalIncentives;
        uint256 totalClaimed;
    }

    // user data | perEpoch | perPoolPerEpoch
    struct User {
        uint128 totalVotesSpent;
        uint128 totalRewards;
        uint128 totalClaimed;
        
        // delegation
        uint128 totalDelegated;
        address delegate;
    }

    struct DelegateData {
        bool isActive;             
        address delegate;
        uint128 currentFeePct;    // 100%: 100, 1%: 1 | no decimal places
        
        uint128 totalDelegated;   // total voting power delegated 
        
        // fee change
        uint128 nextFeePct;       // to be in effect for next epoch
        uint128 nextFeePctEpoch;  // epoch of next fee change
    }

//-------------------------------mapping------------------------------------------

    // epoch data
    mapping(uint128 epoch => EpochData epochData) public epochs;    //note: does it help to use uint128 instead of uint256?

    // pool data
    mapping(bytes32 poolId => Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => PoolEpoch poolEpoch)) public epochPools;

    // user data
    mapping(uint256 epoch => mapping(address user => User userEpochData)) public userEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => User userPoolData))) public userEpochPoolData;
    
    // delegation
    mapping(address delegateAgent => DelegateData delegateData) public delegateData;          
    

    // verifier
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => uint256 claimed))) public verifierClaimedSubsidies;

//-------------------------------constructor------------------------------------------

    constructor(address veMoca_, address esMoca_, address airKit, address owner) {
        
        veMOCA = IERC20(veMoca_);
        MOCA = IERC20(moca_);
        esMOCA = IERC20(esMoca_);
        AIRKIT = IAirKit(airKit);

        // epoch: epoch 0 will start in the future | in-line with veMoca's 4 week bucket
        EPOCH_ZERO_TIMESTAMP = CURRENT_EPOCH_START_TIME = epochs[0].epochStart = WeekMath.getNextEpochStart(uint128(block.timestamp));
        
        //CURRENT_EPOCH = 0;
        //CURRENT_EPOCH_END_TIME = EPOCH_ZERO_TIMESTAMP + Constants.EPOCH_DURATION;
        
        // roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }


//-------------------------------veHolder functions------------------------------------------

    function vote(bytes32[] calldata poolIds, uint128[] calldata weights) external {
        require(poolIds.length > 0, "Invalid Array");
        require(poolIds.length == weights.length, "Mismatched input lengths");

        // for seamless voting across epochs
        uint128 epoch = getCurrentEpoch(); // based on timestamp
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        uint128 epochStart = getEpochStartTimestamp(epoch);

        // Get snapshot voting power
        uint128 votingPower = veMOCA.balanceOfAt(msg.sender, epochStart); // based on epochStart
        uint128 usedVotes = userEpochData[epoch][msg.sender].totalVotesSpent;
        require(votingPower > usedVotes, "No unused votes");


        // Tally up this batch's weight
        uint128 totalNewVotes = 0;

        for (uint256 i = 0; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 weight = weights[i];

            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            require(pools[poolId].isActive, "Pool inactive");
            require(pools[poolId].isWhitelisted, "Pool is not whitelisted");
            require(weight > 0, "Zero weight");

            userEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent += weight;
            epochPools[epoch][poolId].totalVotes += weight;
            pools[poolId].totalVotes += weight;
            epochs[epoch].totalVotes += weight;

            totalNewVotes += weight;
        }

        require(usedVotes + totalNewVotes <= votingPower, "Exceeds available voting power");

        userEpochData[epoch][msg.sender].totalVotesSpent += totalNewVotes;

        //emit Voted(msg.sender, epoch, poolIds, weights);
    }


    function migrateVotes(bytes32 fromPoolId, bytes32 toPoolId, uint128 amount) external {
        require(fromPoolId != toPoolId, "Cannot migrate to same pool");
        require(amount > 0, "Zero amount");

        require(pools[fromPoolId].poolId != bytes32(0), "Source pool does not exist");
        require(pools[toPoolId].poolId != bytes32(0), "Destination pool does not exist");
        require(pools[toPoolId].isActive, "Destination pool is not active");
        require(pools[toPoolId].isWhitelisted, "Destination pool is not whitelisted");

        uint128 epoch = getCurrentEpoch();
        EpochData storage epochData = epochs[epoch];
        require(!epochData.isFullyFinalized, "Epoch finalized");

        // get user's existing votes in the fromPool
        User storage userFrom = userEpochPoolData[epoch][fromPoolId][msg.sender];
        require(userFrom.totalVotesSpent >= amount, "Insufficient votes to migrate");

        // Deduct from old pool
        userFrom.totalVotesSpent -= amount;
        epochPools[epoch][fromPoolId].totalVotes -= amount;
        pools[fromPoolId].totalVotes -= amount;
        epochData.totalVotes -= amount;

        // Add to new pool
        User storage userTo = userEpochPoolData[epoch][toPoolId][msg.sender];
        userTo.totalVotesSpent += amount;
        epochPools[epoch][toPoolId].totalVotes += amount;
        pools[toPoolId].totalVotes += amount;
        epochData.totalVotes += amount;

        //     emit VotesMigrated(msg.sender, epoch, fromPoolId, toPoolId, amount);
    }

    //note: create internal function _vote to be used in both vote(), migrateVotes(), delegateVotes()
    function delegateVotes(address delegate) external {
        // delegator checks:
        require(delegate != msg.sender, "Cannot delegate to self");
        require(delegate != address(0), "Invalid address");

        // delegate agent checks:
        DelegateData storage delegateInfo = delegateData[delegate];
        require(delegateInfo.delegate != address(0), "Not registered");
        require(delegateInfo.active, "Not active");

        // get current epoch and epoch start
        uint128 epoch = getCurrentEpoch();
        uint128 epochStart = getEpochStartTimestamp(epoch);
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        // get user's available voting power at the start of the current epoch
        uint128 availableVotes = veMOCA.balanceOfAt(msg.sender, epochStart);
        require(availableVotes > 0, "No voting power");

        // check if user has already delegated in this epoch
        require(userEpochData[epoch][msg.sender].totalDelegated == 0, "Already delegated");

        // record delegation for the user
        userEpochData[epoch][msg.sender].totalDelegated = availableVotes;
        userEpochData[epoch][msg.sender].delegate = delegate;

        // Update delegate's total delegated voting power
        delegateInfo.totalDelegated += availableVotes;

        // Emit event
        //emit Delegated(msg.sender, delegate, epoch, availableVotes);
    }

//-------------------------------delegator functions------------------------------------------

    // active on registration
    function registerAsDelegate(uint128 feePct) external {
        require(feePct > 0, "Invalid fee: zero");
        require(feePct <= MAX_DELEGATE_FEE_PCT, "Fee must be < MAX_DELEGATE_FEE_PCT");

        DelegateData storage delegate = delegateData[msg.sender];
        require(delegate.delegate == address(0), "Already registered");

        // collect registration fee | note: may want to transfer directly to treasury
        MOCA.safeTransferFrom(msg.sender, address(this), REGISTRATION_FEE);
        TOTAL_REGISTRATION_FEES += REGISTRATION_FEE;

        // storage: create delegate
        delegate.isActive = true;
        delegate.delegate = msg.sender;
        delegate.currentFeePct = feePct;
        
        // event
    }

    // if increase, only applicable currentEpoch+2
    // if decrease, applicable immediately        
    function updateDelegateFee(uint128 feePct) external {
        require(feePct > 0, "Invalid fee: zero");
        require(feePct <= MAX_DELEGATE_FEE_PCT, "Fee must be < MAX_DELEGATE_FEE_PCT");

        DelegateData storage delegate = delegateData[msg.sender];
        require(delegate.isActive, "Not active");
        require(delegate.delegate != address(0), "Not registered");
        
        // if increase, only applicable currentEpoch+2
        if(feePct > delegate.currentFeePct) {
            delegate.nextFeePct = feePct;
            delegate.nextFeePctEpoch = getCurrentEpoch() + 2;  // buffer of 2 epochs to prevent last-minute fee increases
        } else {
            // if decrease, applicable immediately
            delegate.currentFeePct = feePct;
        }

        // event
        //emit DelegateFeeUpdated(msg.sender, feePct, delegate.nextFeePctEpoch);
    }

    function resignAsDelegate() external {
        Delegate storage delegate = delegateData[msg.sender];
        
        require(delegate.delegate == msg.sender, "Not registered as delegate");
        require(delegate.active, "Not active");

        // remove delegation
        delete delegate.active;
        delete delegate.nextFeePct;
        delete delegate.nextFeePctEpoch;
        
        //note: registration fee?

        // event
    }


/*
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
*/
    // for veHolders tt voted get esMoca -> from verification fee split
    function claimRewards(uint256 epochNumber, bytes32 poolId) external {
        // check epoch
        _checkEpoch();
        
        // can only claim rewards for epoch that has ended
        require(epochNumber < CURRENT_EPOCH, "Cannot claim rewards for current or future epochs");

        // get veHolder's total votes spent for the epoch
        uint256 userTotalVotesSpent = userEpochData[epochNumber][msg.sender].totalVotesSpent;
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

//-------------------------------view functions------------------------------------------

    // returns start time of specified epoch number
    function getEpochStartTimestamp(uint128 epoch) internal view returns (uint128) {
        return EPOCH_ZERO_TIMESTAMP + (epoch * Constants.EPOCH_DURATION);
    }

    // returns end time of specified epoch number
    function getEpochEndTimestamp(uint128 epoch) internal view returns (uint128) {
        return EPOCH_ZERO_TIMESTAMP + ((epoch + 1) * Constants.EPOCH_DURATION);
    }

    //returns current epoch number
    function getCurrentEpoch() internal view returns (uint128) {
        return getEpochNumber(uint128(block.timestamp));
    }

    //returns epoch number for a given timestamp
    function getEpochNumber(uint128 timestamp) internal view returns (uint128) {
        require(timestamp >= EPOCH_ZERO_TIMESTAMP, "Before epoch 0");
        return (timestamp - EPOCH_ZERO_TIMESTAMP) / Constants.EPOCH_DURATION;
    }

    //returns current epoch start timestamp
    function getCurrentEpochStart() internal view returns (uint128) {
        return getEpochStartTimestamp(getCurrentEpoch());
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
        if(epochPool.totalIncentives == 0) {
            // non-zero votes: else division by zero
            require(epochPool.totalVotes > 0, "No votes in pool");

            // book pool incentives for the epoch
            epochPool.totalIncentives = epoch.incentivePerVote * epochPool.totalVotes;

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
        epochPools[epochNumber][poolId].totalClaimed += incentives;

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


    //subsidies for {epoch, pool}: for verifiers to claim
    function setEpochIncentives(uint128 epoch, uint128 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // sanity: future epoch + no incentives set yet
        require(epoch > CURRENT_EPOCH, "Cannot set incentives for current or past epochs");
        require(epochs[epoch].totalIncentives == 0, "Incentives already set for this epoch");
        
        epochs[epoch].totalIncentives += amount;

        TOTAL_INCENTIVES_DEPOSITED += amount;

        // event

        // transfer esMoca to voting contract
        esMOCA.transfer(address(this), amount);
    }

    //note: instead of passing epoch, pass timestamp and get epoch from that?
    //note: maybe haev CURRENT_EPOCH to pass to this>?  or somet other way
    function finalizeEpoch(uint128 epoch, bytes32[] calldata poolIds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EpochData storage epochData = epochs[epoch];
        require(epochData.incentivePerVote == 0, "Epoch already finalized");

        uint128 epochStart = getEpochStartTimestamp(epoch);
        require(block.timestamp >= epochStart + Constants.EPOCH_DURATION, "Epoch not ended");

        uint256 totalVotes = epochData.totalVotes;
        uint256 totalIncentives = epochData.totalIncentives;

        if (totalVotes > 0 && totalIncentives > 0) {
            epochData.incentivePerVote = (totalIncentives * 1e18) / totalVotes;

            for (uint256 i = 0; i < poolIds.length; ++i) {
                bytes32 poolId = poolIds[i];
                uint256 poolVotes = epochPools[epoch][poolId].totalVotes;

                if (poolVotes > 0) {
                    uint256 poolIncentives = (poolVotes * totalIncentives) / totalVotes;
                    epochPools[epoch][poolId].totalIncentives = poolIncentives;
                    pools[poolId].totalIncentives += poolIncentives;
                }
            }

            // event

        } else {
            epochData.incentivePerVote = 0;

            // event
        }

        //emit EpochFinalizedSlice(epoch, poolIds, data.incentivePerVote);

        epochData.poolsFinalized += uint128(poolIds.length);
        if(epochData.poolsFinalized == totalNumberOfPools) {
            epochData.isFullyFinalized = true;

            // emit
        }

    }

    //withdraw surplus incentives


    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxFeePct > 0, "Invalid fee: zero");
        require(maxFeePct <= MAX_DELEGATE_FEE_PCT, "Fee must be < MAX_DELEGATE_FEE_PCT");

        MAX_DELEGATE_FEE_PCT = maxFeePct;
    }
}


/** NOTE:

## auto-staking

Users can opt for rewards to be auto-staked to the same lock

1. claim on a per lock basis and autocompound
2. claimAll()
 */



 /*
    function vote(bytes32 poolId, uint128 weight) external {
        // get pool
        Pool memory pool = pools[poolId];

        // check pool
        require(pool.poolId != bytes32(0), "Pool does not exist");
        require(pool.isActive, "Inactive pool");
        require(pool.isWhitelisted, "Not whitelisted pool");

        uint128 epoch = getCurrentEpoch();
        uint128 epochStart = getEpochStartTimestamp(epoch);

        // Get user's total veMOCA voting power at start of epoch
        uint128 votingPower = veMOCA.balanceOfAt(msg.sender, epochStart);
        require(votingPower > 0, "Zero veMoca");

        // check user's total votes spent for this epoch
        uint128 userTotalVotesSpent = userEpochData[epoch][msg.sender].totalVotesSpent;
        require(userTotalVotesSpent + weight < votingPower, "No unused votes");

        // Record the vote
        userEpochData[epoch][msg.sender].totalVotesSpent += weight;
        userEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent += weight;

        // event

        // Update pool and global aggregates
        epochPools[epoch][poolId].totalVotes += weight;
        pools[poolId].totalVotes += weight;
        epochs[epoch].totalVotes += weight;

        // event
    }
*/