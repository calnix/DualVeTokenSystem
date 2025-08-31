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
    uint128 public TOTAL_NUMBER_OF_POOLS;

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
    struct Epoch {
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

        uint128 totalRewards;           // depositRewardsForEpoch(), at epoch end | esMoca

        // global metrics
        uint128 totalVotes;             // total votes pool accrued throughout all epochs
        uint128 totalSubsidies;         // allocated esMOCA subsidies: based on EpochData.subsidyPerVote
        uint128 totalClaimed;           // total esMOCA subsidies claimed; for both base and bonus subsidies
    }

    // pool data [epoch]
    // a pool is a collection of similar credentials
    struct PoolEpoch {
        // voter data
        uint128 totalVotes;
        uint128 totalRewards;           // depositRewardsForEpoch(), at epoch end | esMoca
        uint128 rewardsPerVote;         // depositRewardsForEpoch(), at epoch end | esMoca

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

        uint128 totalRewardsCaptured;      // total gross voting rewards accrued by delegate [from delegated votes]
        uint128 totalFees;                 // total fees accrued by delegate
    }


    // user data     | perEpoch | perPoolPerEpoch
    // delegate data | perEpoch | perPoolPerEpoch
    struct Account {
        // personal
        uint128 totalVotesSpent;
        uint128 totalRewards;       // total accrued rewards
        uint128 totalClaimed;       // @follow-up : convert to bool?
        
        // delegated
        //uint128 totalVotesDelegated; --> votes are booked under delegate's name
        //uint128 rewardsFromDelegations;
        //uint128 claimedFromDelegations;
    }

//-------------------------------mapping------------------------------------------

    // epoch data
    mapping(uint256 epoch => Epoch epoch) public epochs;    
    
    // pool data
    mapping(bytes32 poolId => Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => PoolEpoch poolEpoch)) public epochPools;

    // user personal data: perEpoch | perPoolPerEpoch
    mapping(uint256 epoch => mapping(address user => Account user)) public usersEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account user))) public usersEpochPoolData;
    
    // Delegate registration data + fee data
    mapping(address delegate => Delegate delegate) public delegates;           
    mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFees;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)


    // Delegate aggregated data (delegated votes spent, totalRewardsCaptured, fees)
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


    // for veHolders tt voted get esMoca -> from verification fee split
    // vote at epoch:N, get the pool verification fees of the next epoch:N+1
    function claimRewards(uint256 epoch, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, Errors.InvalidArray());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint256 totalClaimableRewards;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            
            //sanity check: pool exists + user has not claimed rewards yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(usersEpochPoolData[epoch][poolId][msg.sender].totalClaimed == 0, Errors.RewardsAlreadyClaimed());    

            //require(pools[poolId].isActive, "Pool inactive");  ---> pool could be currently inactive but have unclaimed prior rewards 

            // get pool's rewardsPerVote + user's pool votes 
            uint256 rewardsPerVote = epochPools[epoch][poolId].rewardsPerVote;          
            uint256 userPoolVotes = usersEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent;

            // calc. user's rewards for the pool
            uint256 userRewards = userPoolVotes * rewardsPerVote;
            require(userRewards > 0, Errors.NoRewardsToClaim());

            // STORAGE: update user's .totalRewards & .totalClaimed
            usersEpochPoolData[epoch][poolId][msg.sender].totalRewards = userRewards;
            usersEpochPoolData[epoch][poolId][msg.sender].totalClaimed = userRewards;

            // update counter
            totalClaimableRewards += userRewards;
        }

        // update user's total claimed+rewards for all pools
        usersEpochData[epoch][msg.sender].totalRewards += totalClaimableRewards;
        usersEpochData[epoch][msg.sender].totalClaimed += totalClaimableRewards;
        
        // transfer esMoca to user
        _esMoca().safeTransfer(msg.sender, totalClaimableRewards);

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, totalClaimableRewards);
    }


    //TODO: review the delegate mappings
    // user claims rewards on votes tt were delegated to a delegate
    // user could have multiple delegates; must specify which delegate he is claiming from
    function claimRewardsFromDelegate(uint256 epoch, bytes32[] calldata poolIds, address delegate) external {
        // sanity check: delegate
        require(delegate > address(0), Errors.InvalidAddress());
        require(delegates[delegate].isRegistered, Errors.DelegateNotRegistered());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint256 totalClaimableRewards;
        uint256 totalDelegateFee;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
        
            //sanity check: pool exists + user has not claimed rewards yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(userDelegateAccounting[epoch][poolId][msg.sender].totalClaimed == 0, Errors.RewardsAlreadyClaimed());   

            //require(pools[poolId].isActive, "Pool inactive");  ---> pool could be currently inactive but have unclaimed prior rewards 

            // get pool's rewardsPerVote
            uint256 rewardsPerVote = epochPools[epoch][poolId].rewardsPerVote;      
            
            // get delegate's votes for specified pool + calc. delegate's total pool rewards 
            uint256 delegatePoolVotes = delegateEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
            uint256 delegatePoolRewards = delegatePoolVotes * rewardsPerVote;

            // get user's delegated votes; for this delegate | user's endEpoch voting power
            uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(msg.sender, delegate, epoch);


            // calc. user's rewards, from delegating to the delegate [for specified pool]
            uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;
            require(delegateTotalVotesForEpoch > 0, Errors.NoVotesAllocatedByDelegate());

            // userVotesAllocatedToDelegateForEpoch & delegatePoolRewards could be 0; no need to check individually
            uint256 userRewards = userVotesAllocatedToDelegateForEpoch * delegatePoolRewards / delegateTotalVotesForEpoch; // all expressed in 1e18 precision
            require(userRewards > 0, Errors.NoRewardsToClaim());


            // calc. delegation fee + net rewards
            uint256 delegateFee = userRewards * delegates[delegate].currentFeePct / Constants.PRECISION_BASE;
            uint256 netUserRewards = userRewards - delegateFee;                 // fee would be rounded down by division
            //require(netUserRewards > 0, "No rewards after fees to claim");      --> don't check to avoid futility check

            totalDelegateFee += delegateFee;
            totalClaimableRewards += netUserRewards;

            delegateEpochData[epoch][delegate].totalRewardsCaptured += netUserRewards;
            delegateEpochData[epoch][delegate].totalFees += delegateFee;
        }

        // increment user's rewards + claimed [global-delegate lvl]
        userDelegateAccounting[epoch][msg.sender][delegate].totalRewards += totalClaimableRewards;
        userDelegateAccounting[epoch][msg.sender][delegate].totalClaimed += totalClaimableRewards;

        // increment delegate's fees + gross rewards captured [global profile]
        delegates[delegate].totalFees += totalDelegateFee;
        delegates[delegate].totalRewardsCaptured += totalClaimableRewards;
        // @follow-up : maybe don't need this
        delegateEpochData[epoch][delegate].totalRewards += totalDelegateFee;


        emit Events.RewardsClaimedFromDelegate(epoch, msg.sender, delegate, poolIds, totalClaimableRewards);

        // transfer esMoca to user | note: must whitelist this contract for transfers
        _esMoca().safeTransfer(msg.sender, totalClaimableRewards);
    }

    //TODO: claimAndLock - but via router.

//-------------------------------verifiers: claiming subsidies-----------------------------------------

    //TODO: subsidies claimable based off their expenditure accrued for a pool-epoch
    // called by verifiers: subsidies received as esMoca
    function claimSubsidies(uint128 epoch, bytes32 verifierId, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, Errors.InvalidArray());
        
        // epoch must be finalized
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
                // reverts if msg.sender is not the verifier's asset address
                = IPaymentsController(IAddressBook.getPaymentsController()).getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifierId, msg.sender);
            
            // calculate subsidy receivable 
            // verifierAccruedSubsidies & poolAccruedSubsidies (USD8), 1e6 precision | poolAllocatedSubsidies (esMOCA), 1e18 precision
            // subsidyReceivable (esMOCA), 1e18 precision
            uint256 subsidyReceivable = (verifierAccruedSubsidies * poolAllocatedSubsidies) / poolAccruedSubsidies;  // @follow-up : is Math.muldiv required here for potential overflow?
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
        _esMoca().transfer(msg.sender, totalSubsidiesClaimed);      
    }


//-------------------------------admin: finalize, deposit, withdraw subsidies-----------------------------------------

    // to be called at the end of an epoch
    // @follow-up what if subsidies are 0 for an epoch? intentionally?
    function finalizeEpoch(uint128 epoch, bytes32[] calldata poolIds) external onlyVotingControllerAdmin {
        require(poolIds.length > 0, Errors.InvalidArray());

        // sanity check: epoch must not be finalized
        EpochData storage epochData = epochs[epoch];
        require(epochData.subsidyPerVote == 0, Errors.EpochFinalized());

        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // if either votes or subsidies are 0; subsidyPerVote is 0 or txn reverts on division by 0 
        // --> we not bother individually checking for 0 
        uint256 subsidyPerVote;

        // calc. subsidy per vote on 1st call | on subsequent calls, subsidy per vote is already set
        if(epochData.subsidyPerVote == 0) {
            // calc. subsidy per vote | subsidies are esMoca, expressed in 1e18 | votes are 1e18 [_veMoca().balanceAtEpochEnd]
            subsidyPerVote = (epochData.totalSubsidies * 1e18) / epochData.totalVotes;
            require(subsidyPerVote > 0, Errors.SubsidyPerVoteZero());

            // STORAGE: update subsidy per vote
            epochData.subsidyPerVote = subsidyPerVote;
            emit Events.EpochSubsidyPerVoteSet(epoch, subsidyPerVote);
        }

        // cac. pool subsidies for each pool
        if(subsidyPerVote > 0) {

            // subsidies are esMoca, expressed in 1e18 | votes are 1e18 [_veMoca().balanceAtEpochEnd]
            for (uint256 i; i < poolIds.length; ++i) {
                bytes32 poolId = poolIds[i];
                uint256 poolVotes = epochPools[epoch][poolId].totalVotes;

                if (poolVotes > 0) {
                    uint256 poolSubsidies = (poolVotes * subsidyPerVote) / 1e18;
                    
                    // STORAGE: pool epoch + pool global
                    epochPools[epoch][poolId].totalSubsidies = poolSubsidies;
                    pools[poolId].totalSubsidies += poolSubsidies;
                }
            }
        }

        emit Events.EpochPartiallyFinalized(epoch, poolIds);

        // STORAGE: increment count of pools finalized
        epochData.poolsFinalized += uint128(poolIds.length);

        // check if epoch is fully finalized
        if(epochData.poolsFinalized == TOTAL_NUMBER_OF_POOLS) {
            epochData.isFullyFinalized = true;
            emit Events.EpochFullyFinalized(epoch);
        }
    }

    // rewards are referenced from PaymentsController
    // subsidy is referenced from epochs[epoch].totalSubsidies | set by admin at the start
    function finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards) external onlyVotingControllerAdmin {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == rewards.length, Errors.MismatchedArrayLengths());

        // sanity check: epoch must not be finalized
        EpochData storage epochPtr = epochs[epoch];
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // sanity check: epoch must have ended
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(epoch < currentEpoch, Errors.EpochNotEnded());

        // only need to calc. subsidy per vote on 1st call 
        uint256 subsidyPerVote;
        if(epochPtr.subsidyPerVote == 0) {
            // there are subsidies allocated to this epoch
            if(epochPtr.totalSubsidies > 0) {
            
                // subsidies (esMoca) & votes(veMoca) are 1e18 precision 
                subsidyPerVote = (epochPtr.totalSubsidies * 1e18) / epochPtr.totalVotes;    // if totalVotes is 0, reverts on division by 0
                
                // @follow-up subsidies allocated; but rounded to zero | admin should deploy more subsidies; since tt was the initial intention
                require(subsidyPerVote > 0, Errors.SubsidyPerVoteZero());                     

                epochPtr.subsidyPerVote = subsidyPerVote;
                emit Events.EpochSubsidyPerVoteSet(epoch, subsidyPerVote);
            }

            // else: subsidyPerVote remains 0
        }
        
        // ---- at this point subsidyPerVote could be 0 ----

        uint256 totalAmount;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 poolRewards = rewards[i];

            // sanity check: pool + rewards
            require(poolRewards > 0, Errors.InvalidAmount());
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());


        }



        // cac. pool subsidies for each pool
        if(subsidyPerVote > 0) {

            // subsidies (esMoca) & votes(veMoca) are 1e18 precision 
            for (uint256 i; i < poolIds.length; ++i) {
                bytes32 poolId = poolIds[i];
                uint256 poolVotes = epochPools[epoch][poolId].totalVotes;

                if (poolVotes > 0) {
                    uint256 poolSubsidies = (poolVotes * subsidyPerVote) / 1e18;
                    
                    // STORAGE: pool epoch + pool global
                    epochPools[epoch][poolId].totalSubsidies = poolSubsidies;
                    pools[poolId].totalSubsidies += poolSubsidies;
                }
            }
        }

        emit Events.EpochPartiallyFinalized(epoch, poolIds);

        // STORAGE: increment count of pools finalized
        epochData.poolsFinalized += uint128(poolIds.length);

        // check if epoch is fully finalized
        if(epochData.poolsFinalized == TOTAL_NUMBER_OF_POOLS) {
            epochData.isFullyFinalized = true;
            emit Events.EpochFullyFinalized(epoch);
        }
    }


    // to be called at the end of an epoch
    // subsidies for verifiers, for an epoch. to be distributed amongst pools based on votes
    // REVIEW: instead onlyVotingControllerAdmin, DEPOSITOR role?
    function depositSubsidies(uint256 epoch, uint256 depositSubsidies) external onlyVotingControllerAdmin {
        require(epoch > EpochMath.getCurrentEpochNumber(), Errors.CanOnlySetSubsidiesForFutureEpochs());

        epochs[epoch].totalSubsidies += depositSubsidies;
        TOTAL_SUBSIDIES_DEPOSITED += depositSubsidies;

        // transfer esMoca to depositor
        _esMoca().transferFrom(msg.sender, address(this), depositSubsidies);

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
        _esMoca().transfer(msg.sender, withdrawSubsidies);

        // event
        emit Events.SubsidiesWithdrawn(msg.sender, epoch, withdrawSubsidies, epochs[epoch].totalSubsidies);
    }

    //REVIEW: withdraw unclaimed subsidies | after 6 epochs?
    function withdrawUnclaimedSubsidies(uint256 epoch) external onlyVotingControllerAdmin {
        require(epoch >= EpochMath.getCurrentEpochNumber() + UNCLAIMED_SUBSIDIES_DELAY, Errors.CanOnlyWithdrawUnclaimedSubsidiesAfterDelay());

        uint256 unclaimedSubsidies = epochs[epoch].totalSubsidies - epochs[epoch].totalClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // transfer esMoca to depositor
        _esMoca().transfer(msg.sender, unclaimedSubsidies);

        // event
        emit Events.UnclaimedSubsidiesWithdrawn(msg.sender, epoch, unclaimedSubsidies);
    }
    
//-------------------------------admin: setters -----------------------------------------

    // note: implicitly minimum of 1 epoch delay
    function setUnclaimedSubsidiesDelay(uint256 delay) external onlyVotingControllerAdmin {
        require(delay > 0, "Delay must be positive");
        UNCLAIMED_SUBSIDIES_DELAY = delay;

        // event
        emit Events.UnclaimedSubsidiesDelaySet(delay);
    }

    // 0 accepted
    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyVotingControllerAdmin {
        //require(maxFeePct > 0, "Invalid fee: zero");
        require(maxFeePct < Constants.PRECISION_BASE, Errors.InvalidFeePct());

        MAX_DELEGATE_FEE_PCT = maxFeePct;

        emit Events.MaxDelegateFeePctUpdated(maxFeePct);
    }


//-------------------------------admin: deposit voting rewards-----------------------------------------

    /** deposit rewards for a pool
        - rewards are deposited in esMoca; 
        - so cannot reference PaymentsController to get each pool's rewards
        - since PaymentsController tracks feesAccruedToVoters in USD8 terms
        
        Process:
        1. manually reference PaymentsController.getPoolVotingFeesAccrued(uint256 epoch, bytes32 poolId)
        2. withdraw that amount, convert to esMoca [off-chain]
        3. deposit the total esMoca to the 
    */
    ///@dev update pool's PoolEpoch.totalRewards and PoolEpoch.rewardsPerVote
    function depositRewardsForEpoch(uint256 epoch, bytes32[] calldata poolIds, uint256[] calldata amounts) external onlyVotingControllerAdmin {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == amounts.length, Errors.MismatchedArrayLengths());

        // sanity check: epoch | can only deposit for ended epochs
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(epoch < currentEpoch, Errors.InvalidEpoch());

        uint256 totalAmount;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 amount = amounts[i];

            require(amount > 0, Errors.InvalidAmount());

            // sanity checks: pool
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());

            /** update pool's rewardsPerVote:
                - no need to check if totalVotes > 0 | txn reverts if totalVotes == 0
                - both rewards(esMoca) and totalVotes(veMoca) are expressed in 1e18 precision
            */
            uint256 rewardsPerVote = amount * 1E18 / epochPools[epoch][poolId].totalVotes;
            // note: pool has rewards, but no votes, 
        
            // STORAGE: update epoch-pool & pool global
            epochPools[epoch][poolId].rewardsPerVote = rewardsPerVote;
            epochPools[epoch][poolId].totalRewards += amount;
            pools[poolId].totalRewards += amount;
           
            totalAmount += amount;
        }
    
        emit Events.RewardsDeposited(epoch, poolIds, totalAmount);

        // deposit esMoca | TODO: whitelist VotingController on esMoca
        _esMoca().transferFrom(msg.sender, address(this), totalAmount);
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