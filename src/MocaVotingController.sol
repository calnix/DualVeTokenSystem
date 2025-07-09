// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {veMoca} from "./VotingEscrowMoca.sol";
import {IAirKit} from "./interfaces/IAirKit.sol";
import {Constants} from "./Constants.sol";

contract MocaVotingController is AccessControl {
    using SafeERC20 for IERC20;

    VotingEscrowMoca public immutable veMoca;
    IAirKit public immutable AIRKIT;    // airkit contract: books verification payments by verifiers
    address public immutable TREASURY;

    //IERC20 public immutable veMOCA;
    IERC20 public immutable esMOCA;
    IERC20 public immutable MOCA;       // MOCA token for registration fees
        
    // epoch anchor
    uint128 public immutable EPOCH_ZERO_TIMESTAMP;
    // CURRENT_EPOCH note: needed ? for external contract calls?

    // safety check
    uint128 public totalNumberOfPools;

    // incentives
    uint256 public INCENTIVE_FACTOR;
    uint256 public TOTAL_INCENTIVES_DEPOSITED;
    uint256 public TOTAL_SUBSIDIES_CLAIMED;

    // delegate
    uint256 public REGISTRATION_FEE;
    uint256 public MAX_DELEGATE_FEE_PCT; // 100%: 100, 1%: 1 | no decimal places
    uint256 public TOTAL_REGISTRATION_FEES;
    
    
    // voting epoch data
    struct EpochData {
        uint128 epochStart;
        uint128 totalVotes;
        uint128 totalIncentives;    // Total esMOCA subsidies for the epoch
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
        uint256 totalIncentives;    // Pool's allocated esMOCA subsidies
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

        //uint128 totalRewards;
        //uint128 totalClaimed;

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
    
    // delegate data
    mapping(address delegateAgent => DelegateData delegateData) public delegateData;          

    // pool emissions


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

    // note: isDelegated: true = vote on behalf of delegate, false = vote on behalf of self
    function vote(bytes32[] calldata poolIds, uint128[] calldata weights, bool isDelegated) external {
        _vote(msg.sender, poolIds, weights, isDelegated);
    }

    //note: refactor to use _vote() if possible
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

    // isDelegated = true: delegate's voting power, false: voter's personal voting power
    function _vote(address voter, bytes32[] calldata poolIds, uint128[] calldata weights, bool isDelegated) internal {
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        uint128 epoch = _getCurrentEpoch(); // based on timestamp
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        uint128 epochStart = getEpochStartTimestamp(epoch);

        // Get snapshot voting power
        uint128 votingPower = veMOCA.balanceOfAt(voter, epochStart, isDelegated);
        uint128 usedVotes = userEpochData[epoch][voter].totalVotesSpent;
        require(votingPower > usedVotes, "No unused votes");

        uint128 totalNewVotes = 0;
        for (uint256 i = 0; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 weight = weights[i];

            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            require(pools[poolId].isActive, "Pool inactive");
            require(pools[poolId].isWhitelisted, "Pool is not whitelisted");
            require(weight > 0, "Zero weight");

            userEpochPoolData[epoch][poolId][voter].totalVotesSpent += weight;
            epochPools[epoch][poolId].totalVotes += weight;
            pools[poolId].totalVotes += weight;
            epochs[epoch].totalVotes += weight;

            totalNewVotes += weight;
        }

        require(usedVotes + totalNewVotes <= votingPower, "Exceeds available voting power");
        userEpochData[epoch][voter].totalVotesSpent += totalNewVotes;
        
        //emit Voted(msg.sender, epoch, poolIds, weights);
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
        
        // note: to mark as active
        veMoca.registerAsDelegate(msg.sender);
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

    // TODO: handle rewards, delegated votes
    // resign as delegate: registration fee is not refunded
    function resignAsDelegate() external {
        DelegateData storage delegate = delegateData[msg.sender];
        
        require(delegate.isActive, "Not active");
        require(delegate.delegate == msg.sender, "Not registered as delegate");
        
        // remove delegation
        delete delegate.isActive;
        delete delegate.delegate;
        //delete delegate.currentFeePct; // note: may want to keep for calc. rewards
        delete delegate.nextFeePct;
        delete delegate.nextFeePctEpoch;
        
        // update delegate's total delegated voting power
        //delegate.totalDelegated -= userEpochData[getCurrentEpoch()][msg.sender].totalDelegated;
        
        // event

        // note: to mark as inactive
        veMoca.unregisterAsDelegate(msg.sender);
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

//---------------------------claiming rewards------------------------------------------

    //TODO: handle rewards, delegated votes
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


    //TODO
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
    function _getCurrentEpoch() internal view returns (uint128) {
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

    function claimSubsidies(uint256 epochNumber, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, "No pools specified");

        uint128 currentEpoch = _getCurrentEpoch();
        // can only claim incentives for epoch that has ended
        require(epochNumber < currentEpoch, "Can only claim incentives for past epochs");

        // get epoch DATA 
        EpochData storage epoch = epochs[epochNumber];
        require(epoch.isFullyFinalized, "Epoch not finalized");

        //TODO? epoch: calculate incentives if not already done: so can front-run finalizeEpoch()

        uint128 totalClaimableSubsidies;    
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // check if pool exists and has emissions
            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            require(epochPools[epoch][poolId].totalIncentives > 0, "No emissions for pool");

            // get verifier's total spend for {pool, epoch}
            uint256 verifierTotalSpend = AIRKIT.getTotalSpend(msg.sender, epochNumber, poolId);
            require(verifierTotalSpend > 0, "No verification fees in epoch");
            
            // check if already claimed
            require(verifierClaimedSubsidies[epoch][poolId][msg.sender] == 0, "Already claimed for this pool");

            // calculate subsidies
            uint256 subsidies = verifierTotalSpend * epoch.incentivePerVote * INCENTIVE_FACTOR / PRECISION_BASE;
            totalClaimableSubsidies += subsidies;

            // book verifier's subsidies for the epoch
            verifierClaimedSubsidies[epochNumber][poolId][msg.sender] = subsidies;

            // update epoch's total claimed
            epochPools[epochNumber][poolId].totalClaimed += subsidies;
        }

        // update total claimed
        epochs[epochNumber].totalClaimed += totalClaimableSubsidies;
        TOTAL_SUBSIDIES_CLAIMED += totalClaimableSubsidies;
    
        // event
        
        // transfer esMoca to verifier: 
        // note: must whitelist this contract for transfers
        esMOCA.transfer(msg.sender, totalClaimableSubsidies);        // use vault?
    }


//-------------------------------admin functions-----------------------------------------

    function createPool(bytes32 poolId, bool isActive) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolId != bytes32(0), "Pool ID cannot be zero");
        require(pools[poolId].poolId == bytes32(0), "Pool already exists");
        
        pools[poolId].poolId = poolId;
        pools[poolId].isActive = isActive;
        pools[poolId].isWhitelisted = true;

        totalNumberOfPools += 1;

        // event
    }

    //TODO
    function removePool(bytes32 poolId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
        require(pools[poolId].totalVotes == 0, "Pool has votes");
        require(pools[poolId].totalIncentives == 0, "Pool has incentives");
        
        delete pools[poolId];
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
        require(amount > 0, "Amount must be greater than zero");
        require(epoch > _getCurrentEpoch(), "Cannot set incentives for current or past epochs");

        uint128 currentTotalIncentives = epochs[epoch].totalIncentives;

        // if no incentives set yet: set
        if(currentTotalIncentives == 0) {
            epochs[epoch].totalIncentives = amount;
            TOTAL_INCENTIVES_DEPOSITED += amount;

            // event

            // transfer esMoca to voting contract
            esMOCA.transfer(address(this), amount);
        } 

        // we want to decrease incentives
        if(currentTotalIncentives > amount) {
            // update incentives for the epoch
            epochs[epoch].totalIncentives = amount;
            
            uint256 delta = currentTotalIncentives - amount;
            TOTAL_INCENTIVES_DEPOSITED -= delta;
            
            // event
        }

        // we want to increase incentives
        if(currentTotalIncentives < amount) {
            // update incentives for the epoch
            epochs[epoch].totalIncentives = amount;
         
            uint256 delta = amount - currentTotalIncentives;
            TOTAL_INCENTIVES_DEPOSITED += delta;
            
            // event

            // transfer esMoca to voting contract
            esMOCA.transfer(address(this), delta);
        }

        // emit EpochEmissionsSet(epoch, amount);
    }


    //REVIEW
    function finalizeEpoch(uint128 epoch, bytes32[] calldata poolIds) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(poolIds.length > 0, "No pools to finalize");

        EpochData storage epochData = epochs[epoch];
        require(epochData.incentivePerVote == 0, "Epoch already finalized");

        uint128 epochStart = getEpochStartTimestamp(epoch);
        require(block.timestamp >= epochStart + Constants.EPOCH_DURATION, "Epoch not ended");

        uint256 totalVotes = epochData.totalVotes;
        uint256 totalIncentives = epochData.totalIncentives;

        uint256 incentivePerVote;
        if (totalVotes > 0 && totalIncentives > 0) {
            incentivePerVote = (totalIncentives * 1e18) / totalVotes;
            // storage update
            if(incentivePerVote > 0) epochData.incentivePerVote = incentivePerVote;
        }

        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 poolVotes = epochPools[epoch][poolId].totalVotes;

            if (poolVotes > 0) {
                uint256 poolIncentives = (poolVotes * totalIncentives) / totalVotes;
                // pool epoch
                epochPools[epoch][poolId].totalIncentives = poolIncentives;
                // pool global
                pools[poolId].totalIncentives += poolIncentives;

                // emit PoolEmissionsFinalized(epoch, poolId, poolIncentives);
            } else {
                // no votes in pool: no incentives
                //epochPools[epoch][poolId].totalIncentives = 0;
                //pools[poolId].totalIncentives = 0;
            }
        }
        

        // event
        //emit EpochFinalizedPartially(epoch, poolIds, epochData.incentivePerVote);

        // update epoch data
        epochData.poolsFinalized += uint128(poolIds.length);
        if(epochData.poolsFinalized == totalNumberOfPools) {
            epochData.isFullyFinalized = true;

            // emit EpochFinalized(epoch);
        }
    }




    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxFeePct > 0, "Invalid fee: zero");
        require(maxFeePct < Constants.PRECISION_BASE, "MAX_DELEGATE_FEE_PCT must be < 100%");

        MAX_DELEGATE_FEE_PCT = maxFeePct;

        // event
        //emit MaxDelegateFeePctUpdated(maxFeePct);
    }


    //TODO: withdraw surplus incentives

//-------------------------------view functions-----------------------------------------

    function getEligibleSubsidy(address verifier, uint128 epoch, bytes32[] calldata poolIds) external view returns (uint128[] memory eligibleSubsidies) {
        require(poolIds.length > 0, "No pools specified");
        require(epoch < getCurrentEpoch(), "Cannot query for current or future epochs");
        
        require(epochs[epoch].isFullyFinalized, "Epoch not finalized");
            
        eligibleSubsidies = new uint128[](poolIds.length);
        
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            
            // check if pool exists and epoch is finalized
            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            
            // get verifier's total spend for {pool, epoch}
            uint256 verifierTotalSpend = AIRKIT.getTotalSpend(verifier, epoch, poolId);
            if(verifierTotalSpend == 0) {
                //eligibleSubsidies[i] = 0;
                continue;
            }

            // check if already claimed
            if(verifierClaimedSubsidies[epoch][poolId][verifier] > 0) {
                //eligibleSubsidies[i] = 0;
                continue;
            }

            // calculate subsidies
            eligibleSubsidies[i] = uint128(verifierTotalSpend * epoch.incentivePerVote * INCENTIVE_FACTOR / PRECISION_BASE);
        }
        
        return eligibleSubsidies;
    }
}


/** NOTE:

## auto-staking

Users can opt for rewards to be auto-staked to the same lock

1. claim on a per lock basis and auto-compound/stack
2. claimAll()
*/

