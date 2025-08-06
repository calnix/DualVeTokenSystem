// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {veMoca} from "./VotingEscrowMoca.sol";

import {Constants} from "./Constants.sol";
import {EpochMath} from "./utils/EpochMath.sol";

import {IOmPm} from "./interfaces/IOmPm.sol";
import {IAddressBook} from "../interfaces/IAddressBook.sol";
import
import {IEscrowedMoca} from "../interfaces/IEscrowedMoca.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";

//TODO: standardize naming conventions: {subsidy,incentive}

contract VotingController is AccessControl {
    using SafeERC20 for IERC20;

    VotingEscrowMoca public immutable veMoca;
    IAirKit public immutable AIRKIT;    // airkit contract: books verification payments by verifiers
    address public immutable TREASURY;

    //IERC20 public immutable veMOCA;
    IERC20 public immutable esMOCA;
    IERC20 public immutable MOCA;       // MOCA token for registration fees
        
    
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
    
        
    // Pool data [global]
    struct Pool {
        bytes32 poolId;       // poolId = credentialId  
        bool isActive;        // active+inactive: pause pool
        bool isWhitelisted;   // whitelist+blacklist
        
        // global metrics
        uint128 totalVotes;             // how many votes pool accrued throughout all epochs
        uint128 totalBaseIncentives;    // allocated esMOCA subsidies: based on EpochData.incentivePerVote
        uint128 totalBonusIncentives;   // optional: additional esMOCA subsidies tt have been granted to this pool, in totality
        uint128 totalClaimed;           // total esMOCA subsidies claimed; for both base and bonus incentives
    }

    // pool data [epoch]
    // a pool is a collection of similar credentials
    struct PoolEpoch {
        // voter data
        uint128 totalVotes;
        uint128 totalRewards;           // manually deposited weekly, at minimum 
        uint128 rewardsPerVote;         // verification fees per vote | get totol poolFees frm OmPm

        // verifier data
        uint128 totalBaseIncentives;    // allocated esMOCA subsidies: based on EpochData.incentivePerVote
        uint128 totalBonusIncentives;   // optional: any additional esMOCA subsidies granted to this pool, for this epoch
        uint128 totalClaimed;           // total esMOCA subsidies claimed; for both base and bonus incentives
    }

    struct Verifier {
        //uint256 totalSpend; -- logged on the other contract
        uint128 baseIncentivesClaimed;
        uint128 bonusIncentivesClaimed;
    }

    // global delegate data
    struct DelegateGlobal {
        bool isActive;             
        address delegate;         // indicative that delegate is registered 
        uint128 currentFeePct;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
        
        // fee change
        uint128 nextFeePct;       // to be in effect for next epoch
        uint128 nextFeePctEpoch;  // epoch of next fee change

        uint128 totalRewards;      // total gross rewards accrued by delegate
        uint128 totalCommissions;  // total commissions accrued by delegate
        //uint128 totalClaimed;
    }

    // user data     | perEpoch | perPoolPerEpoch
    // delegate data | perEpoch | perPoolPerEpoch
    struct Account {
        // personal
        uint128 totalVotesSpent;
        uint128 totalRewards;
        uint128 totalClaimed;
        
        // delegated
        //uint128 totalVotesDelegated; --> votes are booked under delegate's name
        //uint128 rewardsFromDelegations;
        //uint128 claimedFromDelegations;
    }

//-------------------------------mapping------------------------------------------

    // epoch data
    mapping(uint256 epoch => EpochData epochData) public epochs;    //note: does it help to use uint128 instead of uint256?

    // pool data
    mapping(bytes32 poolId => Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => PoolEpoch poolEpoch)) public epochPools;

    // user personal data: perEpoch | perPoolPerEpoch
    mapping(uint256 epoch => mapping(address user => Account userEpochData)) public usersEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account userPoolData))) public usersEpochPoolData;
    
    // Delegate registration data
    mapping(address delegate => DelegateGlobal delegate) public delegates;           
    // Delegate aggregated data (delegated votes spent, rewards, commissions)
    mapping(uint256 epoch => mapping(address delegate => Account delegate)) public delegateEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address delegate => Account delegate))) public delegateEpochPoolData;

    // User-Delegate tracking [for this user-delegate pair, what was the user's {rewards,claimed}]
    mapping(uint256 epoch => mapping(address user => mapping(address delegate => Account userDelegateAccounting))) public userDelegateAccounting;

    // pool emissions [TODO: maybe]

    // verifier | note: optional: drop verifierData | verifierEpochData | if we want to streamline storage. only verifierEpochPoolData is mandatory
    mapping(address verifier => Verifier verifierData) public verifierData;                  
    mapping(uint256 epoch => mapping(address verifier => Verifier verifier)) public verifierEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => Verifier verifier))) public verifierEpochPoolData;


//-------------------------------constructor------------------------------------------

    constructor(address veMoca_, address esMoca_, address airKit, address owner) {
        

        // roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }


//-------------------------------voting functions------------------------------------------

    // note: isDelegated: true = vote on behalf of delegate, false = vote on behalf of self
    function vote(bytes32[] calldata poolIds, uint128[] calldata weights, bool isDelegated) external {
        _vote(msg.sender, poolIds, weights, isDelegated);
    }

    //TODO: refactor to use _vote() if possible
    // migrate partial, migrate full, etc
    function migrateVotes(bytes32 fromPoolId, bytes32 toPoolId, uint128 amount) external {
        require(fromPoolId != toPoolId, "Cannot migrate to same pool");
        require(amount > 0, "Zero amount");

        require(pools[fromPoolId].poolId != bytes32(0), "Source pool does not exist");
        require(pools[toPoolId].poolId != bytes32(0), "Destination pool does not exist");
        require(pools[toPoolId].isActive, "Destination pool is not active");
        require(pools[toPoolId].isWhitelisted, "Destination pool is not whitelisted");

        uint256 epoch = EpochMath.getCurrentEpochNumber();
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
    // registration fee to go to treasury
    function registerAsDelegate(uint128 feePct) external {
        //require(feePct > 0, "Invalid fee: zero");
        //require(feePct <= MAX_DELEGATE_FEE_PCT, "Fee must be < MAX_DELEGATE_FEE_PCT");

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



/* TODO:

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
    // vote at epoch:N, get the pool verification fees of the next epoch:N+1
    function claimRewards(uint256 epoch, bytes32 poolId) external {
        // sanity check: epoch | can claim on epochs from past till current
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(epoch <= currentEpoch, "Cannot claim rewards for future epochs");
        //require(epochs[epoch].isFullyFinalized, "Epoch not finalized"); ---> if current, not required to be finalized, as rewards distributed weekly

        //sanity check: pool
        require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
        //require(pools[poolId].isActive, "Pool inactive"); 
        //require(pools[poolId].isWhitelisted, "Pool is not whitelisted");

        // get pool's rewardsPerVote
        uint256 latestRewardsPerVote = epochPools[epoch][poolId].rewardsPerVote;
        require(latestRewardsPerVote > 0, "No rewards per vote");     // either no deposit, or nothing earned

        // get user's total votes for the epoch
        uint256 userTotalVotesSpent = userEpochData[epoch][msg.sender].totalVotesSpent;
        require(userTotalVotesSpent > 0, "No votes in epoch");

        // calc. user's latest total rewards [accounting for new deposits made]
        uint256 userTotalRewards = userEpochData[epoch][msg.sender].totalRewards = userTotalVotesSpent * latestRewardsPerVote;

        // calc. claimable rewards + update user's total claimed
        uint256 claimableRewards = userTotalRewards - userEpochData[epoch][msg.sender].totalClaimed;

        if(claimableRewards > 0) {
            userEpochData[epoch][msg.sender].totalClaimed += claimableRewards;

            // transfer esMoca to user
            // note: must whitelist this contract for transfers
            esMOCA.transfer(msg.sender, claimableRewards);
                
            //emit Claimed(msg.sender, epoch, poolId, claimableRewards);
        }
    }

    // user claims rewards on votes tt were delegated to a delegate
    // user could have multiple delegates; must specify which delegate he is claiming from
    function claimRewardsFromDelegate(uint256 epoch, bytes32 poolId, address delegate) external {
        // sanity check: delegate
        require(delegate > address(0), "Invalid address");
        require(delegates[delegate].delegate == delegate, "Delegate not registered");

        // sanity check: epoch | can claim on epochs from past till current
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(epoch <= currentEpoch, "Cannot claim rewards for future epochs");
        //require(epochs[epoch].isFullyFinalized, "Epoch not finalized"); ---> if current, not required to be finalized, as rewards distributed weekly

        //sanity check: pool
        require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
        //require(pools[poolId].isActive, "Pool inactive"); 
        //require(pools[poolId].isWhitelisted, "Pool is not whitelisted");

        // get pool's rewardsPerVote
        uint256 latestRewardsPerVote = epochPools[epoch][poolId].rewardsPerVote;
        require(latestRewardsPerVote > 0, "No rewards per vote");     // either no deposit, or nothing earned

        // get delegate's allocation of voting power for this pool-epoch
        uint256 delegatePoolVotes = delegateEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
        require(delegatePoolVotes > 0, "No votes in pool for this epoch");
        // calc. delegate's share of the pool's rewards
        uint256 delegatePoolRewards = delegatePoolVotes * latestRewardsPerVote;

        // get portion of user's votes that were delegated to the delegate | user's endEpoch voting power
        uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getDelegatedBalanceAtEpochEnd(msg.sender, delegate, epoch);
        require(userVotesAllocatedToDelegateForEpoch > 0, "No votes allocated to delegate");

        // calc. user's share of the delegate's rewards [latest rewards per vote]
        uint256 delegateTotalVotes = delegateEpochData[epoch][delegate].totalVotesSpent;
        uint256 userDelegatedRewardsForPool = userVotesAllocatedToDelegateForEpoch * delegatePoolRewards / delegateTotalVotes;

        // calc claimable rewards 
        uint256 newGrossClaimableRewards = userDelegatedRewardsForPool - userDelegateAccounting[epoch][msg.sender][delegate].totalClaimed;
        require(newGrossClaimableRewards > 0, "No rewards to claim");
        
        uint256 delegateFee = newGrossClaimableRewards * delegates[delegate].currentFeePct / Constants.PRECISION_BASE;
        uint256 newNetClaimableRewards = newGrossClaimableRewards - delegateFee;
        require(newNetClaimableRewards > 0, "No rewards after fees to claim");      // wait for next weekly deposit to claim


        // book user's incoming rewards
        userDelegateAccounting[epoch][msg.sender][delegate].totalClaimed += newNetClaimableRewards;
        //book delegate's incoming commission + rewards earned for delegation
        delegates[delegate].totalCommissions += delegateFee;
        delegates[delegate].totalRewards += newGrossClaimableRewards;

        // transfer esMoca to user
        // note: must whitelist this contract for transfers
        esMOCA.transfer(msg.sender, newNetClaimableRewards);

        // emit
        //emit Claimed(msg.sender, epoch, poolId, claimableRewards);
    }





    /** deposit rewards for a pool
        - a pool is a collection of similar credentials
        - OmPm.sol cannot track which credentials belong to which pool; therefore it cannot aggregate rewards for a pool
        - therefore, we will refer to OmPm::feesAccruedToVoters(uint256 epoch, bytes32 credentialId), and aggregate manually
        - then deposit the total aggregated rewards to the pool for that epoch

        this could be automated by creating a query layer like ACL[explore:low priority]
    */
    ///@dev increment pool's PoolEpoch.totalRewards and PoolEpoch.rewardsPerVote
    function depositRewards(uint256 epoch, bytes32[] calldata poolIds, uint256[] calldata amounts) external onlyRole(DEPOSIT_REWARDS_ROLE) {
        require(poolIds.length > 0, "No pools specified");
        require(poolIds.length == amounts.length, "Mismatched input lengths");
        
        // sanity check: epoch | can deposit on epochs from past till current
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(epoch <= currentEpoch, "Cannot deposit rewards for future epochs");

        uint256 totalAmount;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 amount = amounts[i];

            require(amount > 0, "Amount must be positive");
           
            // sanity check: pool
            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            //require(pools[poolId].isWhitelisted, "Pool is not whitelisted"); ---> ? for past pools what is the treatment?

            // get pool's total rewards
            uint256 newPoolTotalRewards = epochPools[epoch][poolId].totalRewards += amount;

            /** increment pool's rewardsPerVote
                if epochPools[epoch][poolId].totalVotes is 0, reverts; no need to check for 0
                newPoolTotalRewards is always > 0, due to (amount > 0) check
            */
            uint256 rewardsPerVote = epochPools[epoch][poolId].rewardsPerVote = newPoolTotalRewards / epochPools[epoch][poolId].totalVotes;

            // emit
            //emit RewardsPerVoteUpdated(epoch, poolId, rewardsPerVote);
        }

        // emit deposited
        // emit Deposited(epoch, amount);

        // deposit esMoca to voting contract
        esMOCA.transferFrom(msg.sender, address(this), totalAmount);
    }


/*
    //TODO
    function claimAndLock(uint256 amount, uint128 expiry, bool isMoca) external {
        // need to call VotingEscrowMoca.increaseAmount()
    }
*/



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

    //note: isDelegated = true: caller's delegated voting power, false: caller's personal voting power
    function _vote(address caller, bytes32[] calldata poolIds, uint128[] calldata votes, bool isDelegated) internal {
        require(poolIds.length > 0, "Invalid Array");
        require(poolIds.length == votes.length, "Mismatched input lengths");

        // epoch should not be finalized
        uint256 epoch = EpochMath.getCurrentEpochNumber();          // based on block.timestamp
        require(!epochs[epoch].isFullyFinalized, "Epoch finalized");

        // votingPower: benchmarked to end of epoch [forward-decay]
        uint256 epochEnd = EpochMath.getCurrentEpochEnd();

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint256 epoch => mapping(address user => Account accountEpochData)) storage accountEpochData = isDelegated ? delegateEpochData : usersEpochData;
        mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account accountEpochPoolData))) storage accountEpochPoolData = isDelegated ? delegateEpochPoolData : usersEpochPoolData;

        // get account's voting power[personal, delegated] and used votes
        uint128 votingPower = veMoca.balanceOfAt(caller, epochEnd, isDelegated);    // note: voting power is benchmarked to end of epoch [forward-decay]
        uint128 usedVotes = accountEpochData[epoch][caller].totalVotesSpent;

        // check if account has unused votes
        uint128 spareVotes = votingPower - usedVotes;
        require(spareVotes > 0, "No unused votes");

        // update votes at a pool+epoch level | account:{personal,delegate}
        uint128 totalNewVotes;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 votes = votes[i];

            // sanity checks
            require(votes > 0, "Zero vote"); // opting to not skip on 0 vote, as tt indicates incorrect array inputs

            // TODO: check if all 3 req. are needed; streamline
            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            require(pools[poolId].isActive, "Pool inactive");
            require(pools[poolId].isWhitelisted, "Pool is not whitelisted");

            // increment votes at a pool+epoch level | account:{personal,delegate}
            accountEpochPoolData[epoch][poolId][caller].totalVotesSpent += votes;
            epochPools[epoch][poolId].totalVotes += votes;
            pools[poolId].totalVotes += votes;
            epochs[epoch].totalVotes += votes;

            totalNewVotes += votes;
            require(totalNewVotes <= spareVotes, "Exceeds available voting power");
        }

        // update account's epoch voting power counter
        accountEpochData[epoch][caller].totalVotesSpent += totalNewVotes;
        
        //emit Voted(msg.sender, epoch, poolIds, weights);
    }


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


/**
    REMOVE EPOCH_ZERO_TIMESTAMP
    drop the anchor and have all contracts work off unix
    no need for epoch controller that way

 */