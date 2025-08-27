// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// External: OZ
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// libraries
import {Constants} from "./libraries/Constants.sol";
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";


// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";
import {IEscrowedMoca} from "./interfaces/IEscrowedMoca.sol";
import {IPaymentsController} from "./interfaces/IPaymentsController.sol";

//TODO: standardize naming conventions: {subsidy,incentive}

contract VotingController is Pausable {
    using SafeERC20 for IERC20;

    // protocol yellow pages
    IAddressBook internal immutable _addressBook;
    
    // safety check
    uint128 public totalNumberOfPools;

    // incentives
    uint256 public INCENTIVE_FACTOR;
    uint256 public TOTAL_SUBSIDIES_DEPOSITED;
    uint256 public TOTAL_SUBSIDIES_CLAIMED;
    uint256 public UNCLAIMED_SUBSIDIES_DELAY;

    // delegate
    uint256 public REGISTRATION_FEE;           // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 public MAX_DELEGATE_FEE_PCT;       // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 public TOTAL_REGISTRATION_FEES;
    
    
    // epoch: overview
    struct EpochData {
        uint128 epochStart;
        uint128 totalVotes;
        
        // incentives
        uint128 totalSubsidies;        // Total esMOCA subsidies
        uint128 subsidyPerVote;        // subsidiesPerVote: totalSubsidies / totalVotes 
        uint128 totalClaimed;          // Total esMOCA subsidies claimed

        // safety check
        uint128 poolsFinalized;         // number of pools that have been finalized for this epoch
        bool isFullyFinalized;
    }
    
        
    // Pool data [global]
    struct Pool {
        bytes32 poolId;       // poolId = credentialId  
        bool isActive;        // active+inactive: pause pool
        //bool isWhitelisted;   // whitelist+blacklist
        
        // global metrics
        uint128 totalVotes;             // how many votes pool accrued throughout all epochs
        uint128 totalSubsidies;         // allocated esMOCA subsidies: based on EpochData.subsidyPerVote
        uint128 totalClaimed;           // total esMOCA subsidies claimed; for both base and bonus subsidies
    }

    // pool data [epoch]
    // a pool is a collection of similar credentials
    struct PoolEpoch {
        // voter data
        uint128 totalVotes;
        uint128 totalRewards;           // manually deposited weekly, at minimum 
        uint128 rewardsPerVote;         // verification fees per vote | get totol poolFees frm OmPm

        // verifier data
        uint128 totalSubsidies;        // allocated esMoca subsidies: based on EpochData.subsidyPerVote
        uint128 totalClaimed;          // total esMoca subsidies claimed; for both base and bonus subsidies
    }

    // delegate data
    struct Delegate {
        bool isRegistered;             
        uint128 currentFeePct;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
        
        // fee change
        uint128 nextFeePct;       // to be in effect for next epoch
        uint128 nextFeePctEpoch;  // epoch of next fee change

        uint128 totalRewards;      // total gross voting rewards accrued by delegate [from delegated votes]
        uint128 totalFees;         // total fees accrued by delegate
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
    mapping(uint256 epoch => mapping(address user => Account user)) public usersEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account user))) public usersEpochPoolData;
    
    // Delegate registration data + fee data
    mapping(address delegate => Delegate delegate) public delegates;           
    mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFees;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)


    // Delegate aggregated data (delegated votes spent, rewards, commissions)
    mapping(uint256 epoch => mapping(address delegate => Account delegate)) public delegateEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address delegate => Account delegate))) public delegatesEpochPoolData;

    // User-Delegate tracking [for this user-delegate pair, what was the user's {rewards,claimed}]
    mapping(uint256 epoch => mapping(address user => mapping(address delegate => Account userDelegateAccounting))) public userDelegateAccounting;

    // pool emissions [TODO: maybe]

    // verifier | note: optional: drop verifierData | verifierEpochData | if we want to streamline storage. only verifierEpochPoolData is mandatory
    // epoch is epoch number, not timestamp
    mapping(address verifier => uint256 totalSubsidies) public verifierData;                  
    mapping(uint256 epoch => mapping(address verifier => uint256 totalSubsidies)) public verifierEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => uint256 totalSubsidies))) public verifierEpochPoolData;
    

//-------------------------------constructor------------------------------------------

    constructor(address addressBook) {
        ADDRESS_BOOK = IAddressBook(addressBook);
    }


//-------------------------------voting functions------------------------------------------

    /**
     * @notice Cast votes for one or more pools using either personal or delegated voting power.
     * @dev If `isDelegated` is true, the caller's delegated voting power is used; otherwise, personal voting power is used.
     *      If `isDelegated` is true, caller must be registered as delegate
     * @param poolIds Array of pool IDs to vote for.
     * @param votes Array of vote weights corresponding to each pool.
     * @param isDelegated Boolean flag indicating whether to use delegated voting power.

     */
    function vote(address caller, bytes32[] calldata poolIds, uint128[] calldata votes, bool isDelegated) external {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == votes.length, Errors.MismatchedArrayLengths());

        // epoch should not be finalized
        uint256 epoch = EpochMath.getCurrentEpochNumber();          
        require(!epochs[epoch].isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint256 epoch => mapping(address user => Account accountEpochData)) storage accountEpochData;
        mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account accountEpochPoolData))) storage accountEpochPoolData;

        if (isDelegated) {
            require(delegates[caller].isRegistered, Errors.DelegateNotRegistered());
            accountEpochData = delegateEpochData;
            accountEpochPoolData = delegatesEpochPoolData;
        } else {
            accountEpochData = usersEpochData;
            accountEpochPoolData = usersEpochPoolData;
        }

        // votingPower: benchmarked to end of epoch [forward-decay]
        uint256 epochEndTime = EpochMath.getCurrentEpochEnd();

        // get account's voting power[personal, delegated] and used votes
        uint128 votingPower = _veMoca().balanceAtEpochEnd(caller, epochEndTime, isDelegated);
        uint128 spentVotes = accountEpochData[epoch][caller].totalVotesSpent;

        // check if account has spare votes
        uint128 spareVotes = votingPower - spentVotes;
        require(spareVotes > 0, Errors.NoSpareVotes());

        // update votes at a pool+epoch level | account:{personal,delegate}
        uint128 totalNewVotes;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 votes = votes[i];

            // sanity check: do not skip on 0 vote, as it indicates incorrect array inputs
            require(votes > 0, Errors.ZeroVote()); 
            
            // sanity checks: pool exists, is active
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(pools[poolId].isActive, Errors.PoolInactive());
            
            // sanity check: spare votes should not be exceeded
            totalNewVotes += votes;
            require(totalNewVotes <= spareVotes, Errors.InsufficientVotes());

            // increment votes at a pool+epoch level | account:{personal,delegate}
            accountEpochPoolData[epoch][poolId][caller].totalVotesSpent += votes;
            epochPools[epoch][poolId].totalVotes += votes;
            epochs[epoch].totalVotes += votes;
            //increment pool votes at a global level
            pools[poolId].totalVotes += votes;       
        }

        // update account's epoch voting power counter
        accountEpochData[epoch][caller].totalVotesSpent += totalNewVotes;
        
        // event
        emit Events.Voted(epoch, caller, poolIds, votes, isDelegated);
    }

    /**
     * @notice Migrate votes from one or more source pools to destination pools within the current epoch.
     * @dev Allows users to move their votes between pools before the epoch is finalized.
     *      Supports both partial and full vote migration. Can migrate from inactive to active pools, but not vice versa.
     * @param srcPoolIds Array of source pool IDs from which votes will be migrated.
     * @param dstPoolIds Array of destination pool IDs to which votes will be migrated.
     * @param votes Array of vote amounts to migrate for each pool pair.
     * @param isDelegated Boolean indicating if the migration is for delegated votes.
     * If isDelegated: true, caller must be registered as delegate
     * Emits a {VotesMigrated} event on success.
     * Reverts if input array lengths mismatch, pools do not exist, destination pool is not active,
     * insufficient votes in source pool, or epoch is finalized.
     */
    function migrateVotes(bytes32[] calldata srcPoolIds, bytes32[] calldata dstPoolIds, uint128[] calldata votes, bool isDelegated) external {
        require(srcPoolIds.length > 0, Errors.InvalidArray());
        require(srcPoolIds.length == dstPoolIds.length, Errors.MismatchedArrayLengths());
        require(srcPoolIds.length == votes.length, Errors.MismatchedArrayLengths());

        // epoch should not be finalized
        uint256 epoch = EpochMath.getCurrentEpochNumber();          
        require(!epochs[epoch].isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint256 epoch => mapping(address user => Account accountEpochData)) storage accountEpochData;
        mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account accountEpochPoolData))) storage accountEpochPoolData;

        if (isDelegated) {
            require(delegates[caller].isRegistered, Errors.DelegateNotRegistered());
            accountEpochData = delegateEpochData;
            accountEpochPoolData = delegatesEpochPoolData;
        } else {
            accountEpochData = usersEpochData;
            accountEpochPoolData = usersEpochPoolData;
        }

        // can migrate votes from inactive pool to active pool; but not vice versa
        for(uint256 i; i < srcPoolIds.length; ++i) {
            bytes32 srcPoolId = srcPoolIds[i];
            bytes32 dstPoolId = dstPoolIds[i];
            uint128 votesToMigrate = votes[i];

            // sanity check: pools exists, dstPool is active
            require(pools[srcPoolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(pools[dstPoolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(pools[dstPoolId].isActive, Errors.PoolInactive());

            // get user's existing votes in the srcPool
            uint128 votesInSrcPool = accountEpochPoolData[epoch][srcPoolId][msg.sender].totalVotesSpent;
            require(votesInSrcPool >= votesToMigrate, Errors.InsufficientVotes());

            // deduct from old pool
            accountEpochPoolData[epoch][srcPoolId][msg.sender].totalVotesSpent -= votesToMigrate;
            epochPools[epoch][srcPoolId].totalVotes -= votesToMigrate;
            pools[srcPoolId].totalVotes -= votesToMigrate;
            epochs[epoch].totalVotes -= votesToMigrate;

            // add to new pool
            accountEpochPoolData[epoch][dstPoolId][msg.sender].totalVotesSpent += votesToMigrate;
            epochPools[epoch][dstPoolId].totalVotes += votesToMigrate;
            pools[dstPoolId].totalVotes += votesToMigrate;
            epochs[epoch].totalVotes += votesToMigrate;

        }

        // event
        emit Events.VotesMigrated(epoch, msg.sender, srcPoolIds, dstPoolIds, votes, isDelegated);
    }

//-------------------------------delegate functions------------------------------------------

    /**
     * @notice Registers the caller as a delegate and activates their status.
     * @dev Requires payment of the registration fee. Marks the delegate as active upon registration.
     *      Calls VotingEscrowMoca.registerAsDelegate() to mark the delegate as active.
     * @param feePct The fee percentage to be applied to the delegate's rewards. 0 allowed.
     * Emits a {DelegateRegistered} event on success.
     * Reverts if the fee is greater than the maximum allowed fee, the caller is already registered,
     * or the registration fee cannot be transferred from the caller.
     */
    function registerAsDelegate(uint128 feePct) external {
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());

        Delegate storage delegate = delegates[msg.sender];
        require(!delegate.isRegistered, Errors.DelegateAlreadyRegistered());

        // collect registration fee & increment global counter
        _moca().safeTransferFrom(msg.sender, address(this), REGISTRATION_FEE);      // note: may want to transfer directly to treasury
        TOTAL_REGISTRATION_FEES += REGISTRATION_FEE;

        // storage: register delegate
        delegate.isRegistered = true;
        delegate.currentFeePct = feePct;

        // to mark as true
        _veMoca().registerAsDelegate(msg.sender);

        // event
        emit Events.DelegateRegistered(msg.sender, feePct);
    }

    /**
     * @notice Updates the delegate fee percentage.
     * @dev If the fee is increased, the new fee takes effect from currentEpoch + 2 to prevent last-minute increases.
     *      If the fee is decreased, the new fee takes effect immediately.
     * @param feePct The new fee percentage to be applied to the delegate's rewards.
     * Emits a {DelegateFeeUpdated} event on success.
     * Reverts if the fee is greater than the maximum allowed fee, the caller is not registered, or the fee is not a valid percentage.
     */
    function updateDelegateFee(uint128 feePct) external {
        //require(feePct > 0, "Invalid fee: zero");
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());

        Delegate storage delegate = delegates[msg.sender];
        require(delegate.isRegistered, Errors.DelegateNotRegistered());
            
        uint256 currentFeePct = delegate.currentFeePct;
        // if increase, only applicable from currentEpoch+2
        if(feePct > currentFeePct) {
            delegate.nextFeePct = feePct;
            delegate.nextFeePctEpoch = EpochMath.getCurrentEpochNumber() + 2;  // buffer of 2 epochs to prevent last-minute fee increases
            emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, feePct, delegate.nextFeePctEpoch);

        } else {
            // if decrease, applicable immediately
            delegate.currentFeePct = feePct;
            emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, feePct);
        }
    }

    /**
     * @notice Unregister the caller as a delegate.
     * @dev Removes the delegate's registration status.
     *      Calls VotingEscrowMoca.unregisterAsDelegate() to mark the delegate as inactive.
     *      Note: registration fee is not refunded
     * Emits a {DelegateUnregistered} event on success.
     * Reverts if the caller is not registered.
     */
    function unregisterAsDelegate() external {
        Delegate storage delegate = delegates[msg.sender];
        
        require(delegate.isRegistered, Errors.DelegateNotRegistered());
        
        // storage: unregister delegate
        delete delegate.isRegistered;
        
        // to mark as false
        _veMoca().unregisterAsDelegate(msg.sender);

        // event
        emit Events.DelegateUnregistered(msg.sender);
    }

//-------------------------------voters: claiming rewards----------------------------------------------


    //TODO: handle rewards, delegated votes
    // for veHolders tt voted get esMoca -> from verification fee split
    // vote at epoch:N, get the pool verification fees of the next epoch:N+1
    function claimRewards(uint256 epoch, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, Errors.InvalidArray());

        // sanity check: epoch; can claim on epochs from past till current
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(epoch <= currentEpoch, Errors.FutureEpoch());
        //require(epochs[epoch].isFullyFinalized, "Epoch not finalized"); ---> if current, not required to be finalized, as rewards distributed weekly

        uint256 totalClaimableRewards;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            
            //sanity check: pool exists
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            //require(pools[poolId].isActive, "Pool inactive");  ---> pool could be currently inactive but have unclaimed prior rewards 

            // get pool's rewardsPerVote
            uint256 latestRewardsPerVote = epochPools[epoch][poolId].rewardsPerVote;
            require(latestRewardsPerVote > 0, Errors.NoRewardsToClaim());     // either no deposit, or nothing earned
        
            // get user's pool votes for the epoch
            uint256 userPoolVotes = usersEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent;
            require(userPoolVotes > 0, Errors.NoVotesInPool());

            // calc. user's latest total rewards [accounting for new deposits made]
            uint256 userNewTotalRewards = usersEpochPoolData[epoch][poolId][msg.sender].totalRewards = userPoolVotes * latestRewardsPerVote;

            // calc. claimable rewards + update user's total claimed
            uint256 claimableRewards = userNewTotalRewards - usersEpochPoolData[epoch][poolId][msg.sender].totalClaimed;

            totalClaimableRewards += claimableRewards;
        }


        if(totalClaimableRewards > 0) {
            usersEpochData[epoch][msg.sender].totalClaimed += totalClaimableRewards;

            // transfer esMoca to user
            _esMoca().safeTransfer(msg.sender, totalClaimableRewards);

            emit Events.RewardsClaimed(msg.sender, epoch, poolIds, totalClaimableRewards);
        }
    }

    //TODO:
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

    //TODO: claimAndLock - but via router.

//-------------------------------verifiers: claiming subsidies-----------------------------------------

    //TODO: subsidies claimable based off their expenditure accrued for a pool-epoch
    // called by verifiers: subsidies received as esMoca
    function claimSubsidies(uint128 epoch, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, Errors.InvalidArray());
        
        // epoch must have ended + finalized
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.FutureEpoch());
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        //TODO[maybe]: epoch: calculate subsidies if not already done; so can front-run/incorporate finalizeEpoch()

        uint128 totalSubsidiesClaimed;    
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // check if pool exists and has subsidies allocated
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            uint256 poolAllocatedSubsidies = epochPools[epoch][poolId].totalSubsidies;
            require(poolAllocatedSubsidies > 0, Errors.NoSubsidiesForPool());

            // check if already claimed
            require(verifierEpochPoolData[epoch][poolId][msg.sender] == 0, Errors.SubsidyAlreadyClaimed());

            // get verifier's accrued subsidies for {pool, epoch} & pool's total accrued subsidies for the epoch
            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) 
                = IPaymentsController(IAddressBook.getPaymentsController()).getVerifierAndPoolAccruedSubsidies(epoch, poolId, msg.sender);
            
            // calculate subsidy receivable
            uint256 subsidyReceivable = (verifierAccruedSubsidies * poolAllocatedSubsidies) / poolAccruedSubsidies;
            require(subsidyReceivable > 0, Errors.NoSubsidiesToClaim());

            totalSubsidiesClaimed += subsidyReceivable;

            // book verifier's subsidy receivable for the epoch
            verifierEpochPoolData[epoch][poolId][msg.sender] = subsidyReceivable;
            verifierEpochData[epoch][msg.sender] += subsidyReceivable;
            verifierData[msg.sender] += subsidyReceivable;

            // update pool & epoch total claimed
            pools[poolId].totalClaimed += subsidyReceivable;
            epochPools[epoch][poolId].totalClaimed += subsidyReceivable;
        }

        // update epoch & pool total claimed
        TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
        epochs[epoch].totalClaimed += totalSubsidiesClaimed;

        // event
        emit Events.SubsidiesClaimed(msg.sender, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier
        // note: must whitelist VotingController on esMoca for transfers
        IERC20(_addressBook.getEsMoca()).transfer(msg.sender, totalSubsidiesClaimed);      
    }


//-------------------------------admin: finalize, deposit, withdraw subsidies-----------------------------------------

    //REVIEW
    function finalizeEpoch(uint128 epoch, bytes32[] calldata poolIds) external onlyVotingControllerAdmin {
        require(poolIds.length > 0, Errors.InvalidArray());

        EpochData storage epochData = epochs[epoch];
        require(epochData.subsidyPerVote == 0, "Epoch already finalized");

        uint128 epochStart = getEpochStartTimestamp(epoch);
        require(block.timestamp >= epochStart + Constants.EPOCH_DURATION, "Epoch not ended");

        uint256 totalVotes = epochData.totalVotes;
        require(totalVotes > 0, Errors.NoVotesForEpoch());

        uint256 totalSubsidies = epochData.totalSubsidies;
        require(totalSubsidies > 0, Errors.NoSubsidiesForEpoch());

        uint256 subsidyPerVote;
        if (totalVotes > 0 && totalSubsidies > 0) {
            subsidyPerVote = (totalSubsidies * 1e18) / totalVotes;
            // storage update
            if(subsidyPerVote > 0) epochData.subsidyPerVote = subsidyPerVote;
        }

        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 poolVotes = epochPools[epoch][poolId].totalVotes;

            if (poolVotes > 0) {
                uint256 poolSubsidies = (poolVotes * totalSubsidies) / totalVotes;
                // pool epoch
                epochPools[epoch][poolId].totalSubsidies = poolSubsidies;
                // pool global
                pools[poolId].totalSubsidies += poolSubsidies;

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

    // subsidies for verifiers, for an epoch. to be distributed amongst pools based on votes
    // REVIEW: instead onlyVotingControllerAdmin, DEPOSITOR role?
    function depositSubsidies(uint256 epoch, uint256 depositSubsidies) external onlyVotingControllerAdmin {
        require(epoch > EpochMath.getCurrentEpochNumber(), Errors.CanOnlySetSubsidiesForFutureEpochs());

        epochs[epoch].totalSubsidies += depositSubsidies;
        TOTAL_SUBSIDIES_DEPOSITED += depositSubsidies;

        // transfer esMoca to depositor
        IERC20(_addressBook.getEsMoca()).transferFrom(msg.sender, address(this), depositSubsidies);

        // event
        emit Events.SubsidiesDeposited(msg.sender, epoch, depositSubsidies, epochs[epoch].totalSubsidies);
    }

    // REVIEW: instead onlyVotingControllerAdmin, DEPOSITOR role?
    function withdrawSubsidies(uint256 epoch, uint256 withdrawSubsidies) external onlyVotingControllerAdmin {
        require(epoch > EpochMath.getCurrentEpochNumber(), Errors.CanOnlySetSubsidiesForFutureEpochs());
        require(epochs[epoch].totalSubsidies >= withdrawSubsidies, Errors.InsufficientSubsidies());
        
        epochs[epoch].totalSubsidies -= withdrawSubsidies;
        TOTAL_SUBSIDIES_DEPOSITED -= withdrawSubsidies;
        
        // transfer esMoca to depositor
        IERC20(_addressBook.getEsMoca()).transfer(msg.sender, withdrawSubsidies);

        // event
        emit Events.SubsidiesWithdrawn(msg.sender, epoch, withdrawSubsidies, epochs[epoch].totalSubsidies);
    }

    //REVIEW: withdraw unclaimed subsidies | after 6 epochs?
    function withdrawUnclaimedSubsidies(uint256 epoch) external onlyVotingControllerAdmin {
        require(epoch >= EpochMath.getCurrentEpochNumber() + UNCLAIMED_SUBSIDIES_DELAY, Errors.CanOnlyWithdrawUnclaimedSubsidiesAfterDelay());

        uint256 unclaimedSubsidies = epochs[epoch].totalSubsidies - epochs[epoch].totalClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // transfer esMoca to depositor
        IERC20(_addressBook.getEsMoca()).transfer(msg.sender, unclaimedSubsidies);

        // event
        emit Events.UnclaimedSubsidiesWithdrawn(msg.sender, epoch, unclaimedSubsidies);
    }
    

//-------------------------------admin: deposit voting rewards-----------------------------------------

    /** deposit rewards for a pool
        - a pool is a collection of similar credentials
        - Payments.sol cannot track which credentials belong to which pool; therefore it cannot aggregate rewards for a pool
        - therefore, we will refer to Payments.feesAccruedToVoters(uint256 epoch, bytes32 credentialId), and aggregate manually
        - then deposit the total aggregated rewards to the pool for that epoch

        this could be automated by creating a query layer like ACL[explore:low priority]
    */
    ///@dev increment pool's PoolEpoch.totalRewards and PoolEpoch.rewardsPerVote
    function depositRewards(uint256 epoch, bytes32[] calldata poolIds, uint256[] calldata amounts) external onlyVotingControllerAdmin {
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
        IERC20(_addressBook.getEsMoca()).transferFrom(msg.sender, address(this), totalAmount);
    }


    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxFeePct > 0, "Invalid fee: zero");
        require(maxFeePct < Constants.PRECISION_BASE, "MAX_DELEGATE_FEE_PCT must be < 100%");

        MAX_DELEGATE_FEE_PCT = maxFeePct;

        // event
        //emit MaxDelegateFeePctUpdated(maxFeePct);
    }

//-------------------------------admin: pool functions----------------------------------------------

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
    /*    function whitelistPool(bytes32 poolId, bool isWhitelisted) external onlyRole(DEFAULT_ADMIN_ROLE) {
            require(pools[poolId].poolId != bytes32(0), "Pool does not exist");
            pools[poolId].isWhitelisted = isWhitelisted;

            // event
        }*/


//-------------------------------internal functions-----------------------------------------


    function _veMoca() internal view returns (IVotingEscrowMoca){
        return IVotingEscrowMoca(ADDRESS_BOOK.getVotingEscrowMoca());
    }

    function _esMoca() internal view returns (IERC20){
        return IERC20(ADDRESS_BOOK.getEscrowedMoca());
    }

    function _moca() internal view returns (IERC20){
        return IERC20(ADDRESS_BOOK.getMoca());
    }

//-------------------------------Modifiers---------------------------------------------------------------

    modifier onlyVotingControllerAdmin() {
        require(hasRole(VOTING_CONTROLLER_ADMIN_ROLE, msg.sender), "Caller is not a voting controller admin");
        _;
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