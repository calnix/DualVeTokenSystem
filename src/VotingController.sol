// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {veMoca} from "./VotingEscrowMoca.sol";
import {IAirKit} from "./interfaces/IAirKit.sol";
import {Constants} from "./Constants.sol";

//TODO: standardize naming conventions: {subsidy,incentive}

contract VotingController is AccessControl {
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
    uint256 public TOTAL_SUBSIDIES_DEPOSITED;
    uint256 public TOTAL_SUBSIDIES_CLAIMED;

    // delegate
    uint256 public REGISTRATION_FEE;
    uint256 public MAX_DELEGATE_FEE_PCT; // 100%: 100, 1%: 1 | no decimal places
    uint256 public TOTAL_REGISTRATION_FEES;
    
    
    // epoch: overview
    struct EpochData {
        uint128 epochStart;
        uint128 totalVotes;
        
        // incentives
        uint128 totalBaseIncentives;    // Total esMOCA subsidies; disregards any special bonuses granted for this epoch
        uint128 totalBonusIncentives;   // Aggregated bonus esMOCA subsidies; tracks summation of all special bonuses granted for this epoch
        uint128 incentivePerVote;       // subsidiesPerVote: totalIncentives / totalVotes | note: bonuses are handled separately; dependent on their granularity
        uint128 totalClaimed;           // Total esMOCA subsidies claimed; serves as indicator for surplus, accounting for base and bonus incentives

        // safety check
        uint128 poolsFinalized;
        bool isFullyFinalized;
    }
    
    // pool data [global]
    struct Pool {
        bytes32 poolId;       // poolId = credentialId  
        bool isActive;        // active+inactive: pause pool
        bool isWhitelisted;   // whitelist+blacklist

        uint128 totalVotes;
        uint128 totalBaseIncentives;    // allocated esMOCA subsidies: based on EpochData.incentivePerVote
        uint128 totalBonusIncentives;   // optional: additional esMOCA subsidies tt have been granted to this pool, in totality
        uint128 totalClaimed;           // total esMOCA subsidies claimed; for both base and bonus incentives
    }

    // pool data [epoch]
    struct PoolEpoch {
        uint128 totalVotes;
        uint128 totalBaseIncentives;    // allocated esMOCA subsidies: based on EpochData.incentivePerVote
        uint128 totalBonusIncentives;   // optional: any additional esMOCA subsidies granted to this pool, for this epoch
        uint128 totalClaimed;           // total esMOCA subsidies claimed; for both base and bonus incentives
    }


    struct Verifier {
        //uint256 totalSpend; -- logged on the other contract
        uint128 baseIncentivesClaimed;
        uint128 bonusIncentivesClaimed;
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


    // verifier | note: optional: drop verifierData | verifierEpochData | if we want to streamline storage. only verifierEpochPoolData is mandatory
    mapping(address verifier => Verifier verifierData) public verifierData;                  
    mapping(uint256 epoch => mapping(address verifier => Verifier verifier)) public verifierEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => Verifier verifier))) public verifierEpochPoolData;

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

    //TODO: refactor to use _vote() if possible
    function migrateVotes(bytes32 fromPoolId, bytes32 toPoolId, uint128 amount) external {
        require(fromPoolId != toPoolId, "Cannot migrate to same pool");
        require(amount > 0, "Zero amount");

        require(pools[fromPoolId].poolId != bytes32(0), "Source pool does not exist");
        require(pools[toPoolId].poolId != bytes32(0), "Destination pool does not exist");
        require(pools[toPoolId].isActive, "Destination pool is not active");
        require(pools[toPoolId].isWhitelisted, "Destination pool is not whitelisted");

        uint128 epoch = _getCurrentEpoch();
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



/* TODO
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

//-------------------------------voters: claiming rewards----------------------------------------------

    /** NOTE:

    ## auto-staking

    Users can opt for rewards to be auto-staked to the same lock

    1. claim on a per lock basis and auto-compound/stack
    2. claimAll()
    */




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




//-------------------------------verifiers: claiming subsidies-----------------------------------------

    // called by verifiers
    function claimIncentives(uint128 epoch, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, "No pools specified");

        require(epoch < getCurrentEpoch(), "Cannot claim for current or future epochs");
        require(epochs[epoch].isFullyFinalized, "Epoch not finalized");

        //TODO[maybe]: epoch: calculate incentives if not already done; so can front-run finalizeEpoch()

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

    //note: REVIEW
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

    //-------------------------------pool functions----------------------------------------------

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

//-------------------------------incentives functions----------------------------------------------
   
    // incentives for a specific epoch
    function setEpochIncentives(uint128 epoch, uint128 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0, "Amount must be non-zero");
        require(epoch > _getCurrentEpoch(), "Can only set incentives for future epochs");

        // get current total base incentives
        uint128 currentTotalIncentives = epochs[epoch].totalBaseIncentives;
        if(currentTotalIncentives == amount) revert("Incentives already set");

        // if no base incentives set yet: set
        if(currentTotalIncentives == 0) {
            epochs[epoch].totalBaseIncentives = amount;
            TOTAL_INCENTIVES_DEPOSITED += amount;

            // event

            // transfer esMoca to voting contract
            esMOCA.transfer(address(this), amount);
        } 

        // decrease base incentives | note: there will be surplus to be withdrawn
        if(currentTotalIncentives > amount) {
            // update incentives for the epoch
            epochs[epoch].totalBaseIncentives = amount;
            
            uint256 delta = currentTotalIncentives - amount;
            TOTAL_INCENTIVES_DEPOSITED -= delta;
            
            // event
        }

        // increase base incentives
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

    //note: we do not add bonus incentives at a global level - pointless. rather just increment the totalBonusIncentives
    // hence, epoch.totalBonusIncentives is used to track the total bonus incentives for an epoch [sum of pool bonuses + verifier bonuses]
    //function setBonusIncentivesGlobal(uint128 epoch, uint128 extraAmount) external onlyRole(ADMIN_ROLE) {}

    function setPoolBonusIncentives(uint128 epoch, bytes32[] calldata poolIds, uint128[] calldata bonusAmounts) external onlyRole(ADMIN_ROLE) {
        require(poolIds.length > 0, "No pools specified");
        require(poolIds.length == bonusAmounts.length, "Array length mismatch");
        require(epoch > _getCurrentEpoch(), "Can only set incentives for future epochs");

        uint128 totalBonusAmounts;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 bonusAmount = bonusAmounts[i];

            // sanity checks
            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            require(pools[poolId].isActive, "Pool inactive");
            require(pools[poolId].isWhitelisted, "Pool is not whitelisted");
            require(bonusAmount > 0, "Bonus amount must be positive");

            // update pool's bonus incentives
            pools[poolId].totalBonusIncentives += bonusAmount;
            epochPools[epoch][poolId].totalBonusIncentives += bonusAmount;

            // increment counter 
            totalBonusAmounts += bonusAmount;

            // event
            //emit PoolBonusIncentivesSet(epoch, poolId, bonusAmount);
        }
        
        // increment global tracker for epoch
        epochs[epoch].totalBonusIncentives += totalBonusAmounts;
    }

    // TODO
    function setVerifierBonusIncentives(uint128 epoch, address verifier, uint128 bonusAmount) external onlyRole(ADMIN_ROLE) {
        require(bonusAmount > 0, "Bonus amount must be positive");
        require(epoch > _getCurrentEpoch(), "Can only set incentives for future epochs");
        
        // note: any other sanity checks for verifiers?
        require(verifier != address(0), "Verifier cannot be zero address"); 
        
        
        // update verifier's bonus incentives
        verifierEpochData[epoch][verifier].bonusIncentivesClaimed += bonusAmount;

        //TODO: continue
    }

    //TODO: withdraw unclaimed incentives
    function withdrawUnclaimedIncentives() external onlyRole(DEFAULT_ADMIN_ROLE) {}
    

//-------------------------------internal functions-----------------------------------------

    // isDelegated = true: delegate's voting power, false: voter's personal voting power
    function _vote(address voter, bytes32[] calldata poolIds, uint128[] calldata weights, bool isDelegated) internal {
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        uint128 epoch = _getCurrentEpoch(); // based on timestamp
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        uint128 epochStart = _getEpochStartTimestamp(epoch);

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

    // returns start time of specified epoch number
    function _getEpochStartTimestamp(uint128 epoch) internal view returns (uint128) {
        return EPOCH_ZERO_TIMESTAMP + (epoch * Constants.EPOCH_DURATION);
    }

    // returns end time of specified epoch number
    function _getEpochEndTimestamp(uint128 epoch) internal view returns (uint128) {
        return EPOCH_ZERO_TIMESTAMP + ((epoch + 1) * Constants.EPOCH_DURATION);
    }

    //returns current epoch number
    function _getCurrentEpoch() internal view returns (uint128) {
        return _getEpochNumber(uint128(block.timestamp));
    }

    //returns epoch number for a given timestamp
    function _getEpochNumber(uint128 timestamp) internal view returns (uint128) {
        require(timestamp >= EPOCH_ZERO_TIMESTAMP, "Before epoch 0");
        return (timestamp - EPOCH_ZERO_TIMESTAMP) / Constants.EPOCH_DURATION;
    }

    //returns current epoch start timestamp
    function _getCurrentEpochStart() internal view returns (uint128) {
        return _getEpochStartTimestamp(_getCurrentEpoch());
    }


//-------------------------------view functions-----------------------------------------

    // returns start time of specified epoch number
    function getEpochStartTimestamp(uint128 epoch) external view returns (uint128) {
        return _getEpochStartTimestamp(epoch);
    }

    // returns end time of specified epoch number
    function getEpochEndTimestamp(uint128 epoch) external view returns (uint128) {
        return _getEpochEndTimestamp(epoch);
    }

    //returns current epoch number
    function getCurrentEpoch() external view returns (uint128) {
        return _getCurrentEpoch();
    }

    //returns epoch number for a given timestamp
    function getEpochNumber(uint128 timestamp) external view returns (uint128) {
        return _getEpochNumber(timestamp);
    }

    // returns current epoch start timestamp
    function getCurrentEpochStart() external view returns (uint128) {
        return _getCurrentEpochStart();
    }



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