// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// External: OZ
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {Constants} from "./libraries/Constants.sol";
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";

// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";
import {IPaymentsController} from "./interfaces/IPaymentsController.sol";

//TODO: standardize naming conventions: {subsidy,incentive}

contract VotingController is Pausable {
    using SafeERC20 for IERC20;

    // protocol yellow pages
    IAddressBook internal immutable _addressBook;
    
    // safety check
    uint256 public TOTAL_NUMBER_OF_POOLS;

    // delay before withdrawUnclaimed fns can be called    
    uint256 public UNCLAIMED_DELAY_EPOCHS;

    // subsidies
    uint256 public TOTAL_SUBSIDIES_DEPOSITED;
    uint256 public TOTAL_SUBSIDIES_CLAIMED;
    
    // delegate
    uint256 public REGISTRATION_FEE;           // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 public MAX_DELEGATE_FEE_PCT;       // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 public FEE_INCREASE_DELAY_EPOCHS;  // in epochs
    
    uint256 public TOTAL_REGISTRATION_FEES;    // total registration fees collected [MOCA]
    uint256 public REGISTRATION_FEES_CLAIMED;  // total registration fees claimed [MOCA]
    
    // risk management
    uint256 public isFrozen;

//-------------------------------mapping----------------------------------------------

    // epoch data
    mapping(uint256 epoch => DataTypes.Epoch epoch) public epochs;    
    
    // pool data
    mapping(bytes32 poolId => DataTypes.Pool pool) public pools;
    mapping(uint256 epoch => mapping(bytes32 poolId => DataTypes.PoolEpoch poolEpoch)) public epochPools;


    // user personal data: perEpoch | perPoolPerEpoch
    mapping(uint256 epoch => mapping(address user => DataTypes.Account user)) public usersEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => DataTypes.Account userAccount))) public usersEpochPoolData;
    
    // delegate aggregated data: perEpoch | perPoolPerEpoch [mirror of userEpochData & userEpochPoolData]
    mapping(uint256 epoch => mapping(address delegate => DataTypes.Account delegate)) public delegateEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address delegate => DataTypes.Account delegateAccount))) public delegatesEpochPoolData;

    // User-Delegate tracking [for this user-delegate pair, what was the user's {rewards,claimed}]
    mapping(uint256 epoch => mapping(address user => mapping(address delegate => DataTypes.OmnibusDelegateAccount userDelegateAccount))) public userDelegateAccounting;


    // Delegate registration data + fee data
    mapping(address delegate => DataTypes.Delegate delegate) public delegates;     
    // if 0: fee not set for that epoch      
    mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFeePcts;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

    // REVIEW: only verifierEpochPoolData is mandatory. optional: drop verifierData & verifierEpochData, if we want to streamline storage. 
    // are there creative ways to have the optional mappings without the extra storage writes?
    mapping(address verifier => uint256 totalSubsidies) public verifierData;                  
    mapping(uint256 epoch => mapping(address verifier => uint256 totalSubsidies)) public verifierEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => uint256 totalSubsidies))) public verifierEpochPoolData;
    

//-------------------------------constructor------------------------------------------

    constructor(address addressBook, uint256 registrationFee, uint256 maxDelegateFeePct) {
        require(addressBook != address(0), Errors.InvalidAddress());
        require(registrationFee > 0, Errors.InvalidAmount());
        
        _addressBook = IAddressBook(addressBook);

        // initial unclaimed delay set to 6 epochs
        UNCLAIMED_DELAY_EPOCHS = FEE_INCREASE_DELAY_EPOCHS = EpochMath.EPOCH_DURATION() * 6;

        // set registration fee
        REGISTRATION_FEE = registrationFee;

        // set max delegate fee percentage
        require(maxDelegateFeePct > 0 && maxDelegateFeePct <= Constants.PRECISION_BASE, Errors.InvalidFeePct());
        MAX_DELEGATE_FEE_PCT = maxDelegateFeePct;

    }

//-------------------------------voting functions------------------------------------------

    /**
     * @notice Cast votes for one or more pools using either personal or delegated voting power.
     * @dev If `isDelegated` is true, the caller's delegated voting power is used; otherwise, personal voting power is used.
     *      If `isDelegated` is true, caller must be registered as delegate
     * @param poolIds Array of pool IDs to vote for.
     * @param poolVotes Array of votes corresponding to each pool.
     * @param isDelegated Boolean flag indicating whether to use delegated voting power.

     */
    function vote(bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external whenNotPaused {
        // sanity check: poolIds & poolVotes must be non-empty and have the same length
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == poolVotes.length, Errors.MismatchedArrayLengths());

        // Cache epoch pointer
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // epoch should not be finalized
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint256 epoch => mapping(address user => Account accountEpochData)) storage accountEpochData;
        mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account accountEpochPoolData))) storage accountEpochPoolData;

        // assign mappings
        if (isDelegated) {
            // sanity check: delegate must be registered [msg.sender is delegate]
            require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());
            accountEpochData = delegateEpochData;
            accountEpochPoolData = delegatesEpochPoolData;

            // fee check: if not set, set to current fee
            if(delegateHistoricalFeePcts[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                if(!pendingFeeApplied) {
                    delegateHistoricalFeePcts[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
                }
            }

        } else {
            accountEpochData = usersEpochData;
            accountEpochPoolData = usersEpochPoolData;
        }

        // votingPower: benchmarked to end of epoch [forward-decay]
        // get account's voting power[personal, delegated] and used votes
        uint128 totalVotes = _veMoca().balanceAtEpochEnd(msg.sender, currentEpoch, isDelegated);
        uint128 spentVotes = accountEpochData[currentEpoch][msg.sender].totalVotesSpent;

        // check if account has available votes
        uint128 availableVotes = totalVotes - spentVotes;
        require(availableVotes > 0, Errors.NoAvailableVotes());

        // update votes at a pool+epoch level | account:{personal,delegate}
        uint128 totalNewVotes;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 votes = poolVotes[i];

            // sanity check: do not skip on 0 vote, as it indicates incorrect array inputs
            require(votes > 0, Errors.ZeroVotes()); 
            
            // sanity checks: pool exists, is active
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!pools[poolId].isRemoved, Errors.PoolRemoved());
            
            // sanity check: available votes should not be exceeded
            totalNewVotes += votes;
            require(totalNewVotes <= availableVotes, Errors.InsufficientVotes());

            // increment votes at a pool+epoch level | account:{personal,delegate}
            accountEpochPoolData[currentEpoch][poolId][msg.sender].totalVotesSpent += votes;
            epochPools[currentEpoch][poolId].totalVotes += votes;

            //increment pool votes at a global level
            pools[poolId].totalVotes += votes;       
        }

        // increment epoch totalVotes
        epochPtr.totalVotes += totalNewVotes;

        // update account's epoch totalVotesSpent counter
        accountEpochData[currentEpoch][msg.sender].totalVotesSpent += totalNewVotes;
        
        
        emit Events.Voted(currentEpoch, msg.sender, poolIds, poolVotes, isDelegated);
    }

    /**
     * @notice Migrate votes from one or more source pools to destination pools within the current epoch.
     * @dev Allows users to move their votes between pools before the epoch is finalized.
     *      Supports both partial and full vote migration. Can migrate from inactive to active pools, but not vice versa.
     * @param srcPoolIds Array of source pool IDs from which votes will be migrated.
     * @param dstPoolIds Array of destination pool IDs to which votes will be migrated.
     * @param poolVotes Array of vote amounts to migrate for each pool pair.
     * @param isDelegated Boolean indicating if the migration is for delegated votes.
     * If isDelegated: true, caller must be registered as delegate
     * Reverts if input array lengths mismatch, pools do not exist, destination pool is not active, insufficient votes in source pool, or epoch is finalized.
     */
    function migrateVotes(bytes32[] calldata srcPoolIds, bytes32[] calldata dstPoolIds, uint128[] calldata poolVotes, bool isDelegated) external whenNotPaused {
        // sanity check: array lengths must be non-empty and match
        uint256 length = srcPoolIds.length;
        require(length > 0, Errors.InvalidArray());
        require(length == dstPoolIds.length, Errors.MismatchedArrayLengths());
        require(length == poolVotes.length, Errors.MismatchedArrayLengths());

        // epoch should not be finalized
        uint256 epoch = EpochMath.getCurrentEpochNumber();          
        require(!epochs[epoch].isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint256 epoch => mapping(address user => Account accountEpochData)) storage accountEpochData;
        mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account accountEpochPoolData))) storage accountEpochPoolData;

        // assign mappings
        if (isDelegated) {
            // sanity check: delegate must be registered [msg.sender is delegate]
            require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());
            accountEpochData = delegateEpochData;
            accountEpochPoolData = delegatesEpochPoolData;

            // fee check: if not set, set to current fee
            if(delegateHistoricalFeePcts[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                if(!pendingFeeApplied) {
                    delegateHistoricalFeePcts[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
                }
            }

        } else {
            accountEpochData = usersEpochData;
            accountEpochPoolData = usersEpochPoolData;
        }

        // can migrate votes from inactive pool to active pool; but not vice versa
        for(uint256 i; i < length; ++i) {
            // cache: calldata access per array element
            bytes32 srcPoolId = srcPoolIds[i];
            bytes32 dstPoolId = dstPoolIds[i];
            uint128 votesToMigrate = poolVotes[i];

            // Cache storage pointers
            DataTypes.Pool storage srcPoolPtr = pools[srcPoolId];
            DataTypes.Pool storage dstPoolPtr = pools[dstPoolId];
            DataTypes.PoolEpoch storage srcEpochPoolPtr = epochPools[epoch][srcPoolId];
            DataTypes.PoolEpoch storage dstEpochPoolPtr = epochPools[epoch][dstPoolId];

            // sanity check: both pools exist + dstPool is active + not removed [src pool can be removed]
            require(srcPoolPtr.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(dstPoolPtr.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!dstPoolPtr.isRemoved, Errors.PoolRemoved());

            // get user's existing votes in srcPool | must be greater than or equal to votesToMigrate
            uint128 votesInSrcPool = accountEpochPoolData[epoch][srcPoolId][msg.sender].totalVotesSpent;
            require(votesInSrcPool >= votesToMigrate, Errors.InsufficientVotes());

            // deduct from old pool
            accountEpochPoolData[epoch][srcPoolId][msg.sender].totalVotesSpent -= votesToMigrate;
            srcEpochPoolPtr.totalVotes -= votesToMigrate;
            srcPoolPtr.totalVotes -= votesToMigrate;

            // add to new pool
            accountEpochPoolData[epoch][dstPoolId][msg.sender].totalVotesSpent += votesToMigrate;
            dstEpochPoolPtr.totalVotes += votesToMigrate;
            dstPoolPtr.totalVotes += votesToMigrate;

            // no need to update mappings: accountEpochData and epochs.totalVotes; as its a migration of votes within the same epoch.
        }

        emit Events.VotesMigrated(epoch, msg.sender, srcPoolIds, dstPoolIds, poolVotes, isDelegated);
    }

//-------------------------------delegate functions------------------------------------------

    /**
     * @notice Registers the caller as a delegate and activates their status.
     * @dev Requires payment of the registration fee. Marks the delegate as active upon registration.
     *      Calls VotingEscrowMoca.registerAsDelegate() to mark the delegate as active.
     * @param feePct The fee percentage to be applied to the delegate's rewards.
     * Emits a {DelegateRegistered} event on success.
     * Reverts if the fee is greater than the maximum allowed fee, the caller is already registered,
     * or the registration fee cannot be transferred from the caller.
     */
    function registerAsDelegate(uint128 feePct) external whenNotPaused {
        require(feePct > 0, Errors.InvalidFeePct());
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());

        Delegate storage delegate = delegates[msg.sender];
        require(!delegate.isRegistered, Errors.DelegateAlreadyRegistered());

        // collect registration fee & increment global counter
        uint256 registrationFee = REGISTRATION_FEE;
        if(registrationFee > 0) {
            _moca().safeTransferFrom(msg.sender, address(this), REGISTRATION_FEE);
            TOTAL_REGISTRATION_FEES += registrationFee;
        }

        // register on VotingEscrowMoca | if delegate is already registered on VotingEscrowMoca -> reverts
        _veMoca().registerAsDelegate(msg.sender);

        // storage: register delegate + set fee percentage
        delegate.isRegistered = true;
        delegate.currentFeePct = feePct;
        delegateHistoricalFeePcts[msg.sender][EpochMath.getCurrentEpochNumber()] = feePct;

        emit Events.DelegateRegistered(msg.sender, feePct);
    }

    /**
     * @notice Updates the delegate fee percentage.
     * @dev If the fee is increased, the new fee takes effect from currentEpoch + FEE_INCREASE_DELAY_EPOCHS to prevent last-minute increases.
     *      If the fee is decreased, the new fee takes effect immediately.
     * @param feePct The new fee percentage to be applied to the delegate's rewards.
     * Emits a {DelegateFeeUpdated} event on success.
     * Reverts if the fee is greater than the maximum allowed fee, the caller is not registered, or the fee is not a valid percentage.
     */
    function updateDelegateFee(uint128 feePct) external whenNotPaused {
        require(feePct > 0, Errors.InvalidFeePct());
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());   

        Delegate storage delegate = delegates[msg.sender];
        require(delegate.isRegistered, Errors.DelegateNotRegistered());

        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

        // if there is an incoming pending fee increase, apply it before updating the fee
        _applyPendingFeeIfNeeded(msg.sender, currentEpoch);   

        uint256 currentFeePct = delegate.currentFeePct;

        // if increase, only applicable from currentEpoch+FEE_INCREASE_DELAY_EPOCHS
        if(feePct > currentFeePct) {
            // set new pending
            delegate.nextFeePct = feePct;
            delegate.nextFeePctEpoch = currentEpoch + FEE_INCREASE_DELAY_EPOCHS;

            // set for future epoch
            delegateHistoricalFeePcts[msg.sender][delegate.nextFeePctEpoch] = feePct;  

            emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, feePct, delegate.nextFeePctEpoch);

        } else {
            // fee decreased: apply immediately
            delegate.currentFeePct = feePct;
            delegateHistoricalFeePcts[msg.sender][currentEpoch] = feePct;

            // delete pending
            delete delegate.nextFeePct;
            delete delegate.nextFeePctEpoch;

            emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, feePct);
        }
    }

    //Note: when an delegate unregisters, we still need to be able to log his historical fees for users to claim them
    /**
     * @notice Unregister the caller as a delegate.
     * @dev Removes the delegate's registration status.
     *      Calls VotingEscrowMoca.unregisterAsDelegate() to mark the delegate as inactive.
     *      Note: registration fee is not refunded
     * Emits a {DelegateUnregistered} event on success.
     * Reverts if the caller is not registered.
     */
    function unregisterAsDelegate() external whenNotPaused {
        Delegate storage delegate = delegates[msg.sender];
        
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(delegateEpochData[currentEpoch][msg.sender].totalVotesSpent == 0, Errors.CannotUnregisterWithActiveVotes());
        require(delegate.isRegistered, Errors.DelegateNotRegistered());
        
        // storage: unregister delegate
        delete delegate.isRegistered;
        
        // to mark as false
        _veMoca().unregisterAsDelegate(msg.sender);

        // event
        emit Events.DelegateUnregistered(msg.sender);
    }

//-------------------------------claim rewards & fees functions----------------------------------------------


    /**
     * @notice Claims esMoca rewards for the caller for specified pools in a given epoch.
     * @dev For veHolders who voted directly, allows claiming esMoca rewards for each pool in the specified epoch.
     *      Users who voted in epoch N, can claim the pool verification fees accrued in epoch N+1. [bet on the future]
     *      Pools with zero rewards or zero user votes are skipped without reverting.
     *      Reverts if the user has already claimed for a pool, or if the pool does not exist.
     *      No explicit "claimed" flag is used; claim status is tracked via the Account struct: usersEpochPoolData[epoch][poolId][msg.sender].totalRewards
     * @param epoch The epoch number for which to claim rewards.
     * @param poolIds Array of pool identifiers to claim rewards from.
     *
     * Requirements:
     * - The epoch must be fully finalized.
     * - At least one poolId must be provided and exist.
     * - The caller must not have already claimed for each pool.
     * - At least one reward must be claimable.
     *
     * Emits a {RewardsClaimed} event on success.
     */
    function voterClaimRewards(uint256 epoch, bytes32[] calldata poolIds) external whenNotPaused {
        require(poolIds.length > 0, Errors.InvalidArray());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint256 userTotalRewards;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            
            // Check pool exists and user has not claimed rewards yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(usersEpochPoolData[epoch][poolId][msg.sender].totalRewards == 0, Errors.RewardsAlreadyClaimed());    

            // Pool may be inactive but still have unclaimed prior rewards

            // Get user's pool votes and pool totals
            uint256 userPoolVotes = usersEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent;
            uint256 poolTotalVotes = epochPools[epoch][poolId].totalVotes;
            uint256 totalRewards = epochPools[epoch][poolId].totalRewards;
            
            // Skip pools with zero rewards or zero user votes
            if(totalRewards == 0 || userPoolVotes == 0) continue;

            // Calculate user's rewards for the pool (pro-rata)
            uint256 userRewards = (userPoolVotes * totalRewards) / poolTotalVotes;
            if(userRewards == 0) continue;
            
            // Set user's totalRewards for this pool
            usersEpochPoolData[epoch][poolId][msg.sender].totalRewards = userRewards;

            // Increment pool's total claimed rewards
            epochPools[epoch][poolId].totalRewardsClaimed += userRewards;
            pools[poolId].totalRewardsClaimed += userRewards;

            // Update counter
            userTotalRewards += userRewards;
        }

        if(userTotalRewards == 0) revert Errors.NoRewardsToClaim();

        // Increment user's total rewards for this epoch
        usersEpochData[epoch][msg.sender].totalRewards += userTotalRewards;

        // Increment global: epoch total claimed
        epochs[epoch].totalRewardsClaimed += userTotalRewards;

        // Transfer esMoca to user
        _esMoca().safeTransfer(msg.sender, userTotalRewards);

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, userTotalRewards);
    }



    /**
        few delegates, many pools
        so iterate over delegates, then pools
    */
    /**
     * @notice Allows a user (delegator) to claim all rewards accrued from votes delegated to multiple delegates in a single transaction.
     * @dev Processes rewards in batches by delegates and their respective pools. 
     *      Net rewards are aggregated and transferred to the user at the end, while delegate fees are paid per delegate within the loop.
     *      The function should be called with poolIds selected to maximize net rewards per claim.
     * @param epoch The epoch for which rewards are being claimed.
     * @param delegateList Array of delegate addresses from whom the user is claiming rewards.
     * @param poolIdsPerDelegate Array of poolId arrays, each corresponding to the pools voted by a specific delegate.
     * 
     * Requirements:
     * - The epoch must be fully finalized.
     * - delegateList and poolIdsPerDelegate must have the same nonzero length.
     * - msg.sender must be the delegator (user).
     * - At least one net reward must be claimable.
     * 
     * Emits a {RewardsClaimedFromDelegate} event and {DelegateFeesClaimed} events for each delegate with a nonzero fee.
     */
    function claimRewardsFromDelegate(uint256 epoch, address[] calldata delegateList, bytes32[][] calldata poolIdsPerDelegate) external whenNotPaused {
        // sanity check: epoch must be finalized + delegateList & poolIdsPerDelegate must be of the same length
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());
        require(delegateList.length > 0 && delegateList.length == poolIdsPerDelegate.length, Errors.MismatchedArrayLengths());

        uint256 userTotalNetRewards;  // sum user's nets across all delegates

        for (uint256 i; i < delegateList.length; ++i) {

            address delegate = delegateList[i];
            bytes32[] calldata poolIds = poolIdsPerDelegate[i];

            if (poolIds.length == 0) continue;  // skip if no pools

            // calculate user's total rewards earned via this delegate across all specified pools
            (uint256 userTotalNetRewardsForDelegate, uint256 delegateFee) = _claimDelegateRewards(epoch, msg.sender, delegate, poolIds);

            // Transfer fee to delegate (per-delegate, as in original)
            if (delegateFee > 0) {
                _esMoca().safeTransfer(delegate, delegateFee);
                emit Events.DelegateFeesClaimed(delegate, delegateFee);
            }

            // increment counter
            userTotalNetRewards += userTotalNetRewardsForDelegate;

        }

        require(userTotalNetRewards > 0, Errors.NoRewardsToClaim());  // Check aggregate net >0

        // Single transfer of total net to user (caller)
        _esMoca().safeTransfer(msg.sender, userTotalNetRewards);
        emit Events.RewardsClaimedFromDelegateBatch(epoch, msg.sender, delegateList, poolIdsPerDelegate, userTotalNetRewards);
    }

    /**
     * @notice Called by delegates to claim accumulated fees from multiple delegators. [delegator==user tt delegated votes]
     * @dev Processes batches by delegators; each delegator's pools are specified for fee calculation and distribution.
     * @param epoch The epoch for which delegate fees are being claimed.
     * @param delegators Array of delegator addresses from whom fees are being claimed.
     * @param poolIdsPerDelegator Array of poolId arrays, each corresponding to the pools voted by a specific delegator.
     */
    function claimDelegateFees(uint256 epoch, address[] calldata delegators, bytes32[][] calldata poolIdsPerDelegator) external whenNotPaused {
        require(delegators.length > 0 && delegators.length == poolIdsPerDelegator.length, Errors.MismatchedArrayLengths());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());
        // sanity check: if delegate did not vote in the epoch, fee is not set -> nothing to claim
        require(delegateHistoricalFeePcts[msg.sender][epoch] > 0, Errors.NoFeesToClaim());

        address delegate = msg.sender;  // caller is delegate
        uint256 totalDelegateFees;      // total fees accrued by the delegate [across all delegators]

        // for each delegator [delegator==user tt delegated votes]
        for (uint256 i; i < delegators.length; ++i) {
            address delegator = delegators[i];
            bytes32[] calldata poolIds = poolIdsPerDelegator[i];

            if (poolIds.length == 0) continue;  // skip if no pools

            (uint256 userTotalNetRewards, uint256 delegateFee) = _claimDelegateRewards(epoch, delegator, delegate, poolIds);

            // No require(userTotalNetRewards>0): delegates can claim fees even if user rewards are zero. Delegates fulfilled their service. 

            // transfer net rewards to each delegator 
            if (userTotalNetRewards > 0) {
                _esMoca().safeTransfer(delegator, userTotalNetRewards);
                emit Events.RewardsClaimedFromDelegate(epoch, delegator, delegate, poolIds, userTotalNetRewards);
            }

            // increment counter
            totalDelegateFees += delegateFee;
        }

        // batch transfer all accrued fees to delegate
        if (totalDelegateFees > 0) {
            _esMoca().safeTransfer(delegate, totalDelegateFees);
            emit Events.DelegateFeesClaimed(delegate, totalDelegateFees);
        }
    }


    /**
     * @notice Claims rewards for the caller on votes that were delegated to a specific delegate for a given epoch and set of pools.
     * @dev Depending on the grouping of poolIds in each call, the user may receive zero or non-zero net rewards per claim. This is due to the application of delegate fees.
     *      Front-end should group poolIds to maximize net rewards per claim.
     * - Pools may be inactive at the time of claim, but unclaimed prior rewards are still claimable.
     * - Rewards are calculated based on the user's delegated votes, the delegate's share of pool rewards, and the total votes allocated by the delegate.
     * - Skips pools with zero rewards or zero votes gracefully.
     * - Sets per-pool gross rewards for the user-delegate pair and flags them as claimed.
     * - Prorates and subtracts delegate fee from per-pool claimed (leaves fees as unclaimed for sweep).
     * @param epoch The epoch number for which to claim rewards.
     * @param poolIds The array of pool identifiers for which to claim rewards.
     * @param delegate The address of the delegate from whom the user is claiming rewards.
     */
    /*function claimRewardsFromDelegateV1(uint256 epoch, bytes32[] calldata poolIds, address delegate) external {
        // sanity check: delegate
        //require(delegate > address(0), Errors.InvalidAddress());
        require(delegates[delegate].isRegistered, Errors.DelegateNotRegistered());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint256 userTotalGrossRewards;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
        
            //sanity check: pool exists + user has not claimed rewards from this delegate yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(userDelegateAccounting[epoch][msg.sender][delegate].poolGrossRewards[poolId] == 0, Errors.RewardsAlreadyClaimed());   // per-pool check     
            //require(pools[poolId].isActive, "Pool inactive");  ---> pool could be currently inactive but have unclaimed prior rewards 

            // get delegate's votes for specified pool + pool totals
            uint256 delegatePoolVotes = delegateEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
            uint256 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            uint256 totalPoolRewards = epochPools[epoch][poolId].totalRewards;
            
            // totalPoolVotes == 0 check is covered by delegatePoolVotes == 0 check
            if(totalPoolRewards == 0 || delegatePoolVotes == 0) continue;  // skip 0-reward pools gracefully

            // calc. delegate's share of pool rewards (direct proportion, per-pool)
            uint256 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
            if(delegatePoolRewards == 0) continue;                   // skip if floored to 0
                
            // book gross rewards accrued by a delegatee for this pool & epoch [this is not claimable by the delegate]
            delegateEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;
            delegateEpochData[epoch][delegate].totalRewards += delegatePoolRewards;
            

            // fetch number of votes user delegated, to this delegate
            uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(msg.sender, delegate, epoch);
            
            uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;
            //require(delegateTotalVotesForEpoch > 0, Errors.NoVotesAllocatedByDelegate());  --> not needed since delegatePoolVotes > 0

            // calc. user's gross rewards for the pool
            uint256 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
            if(userGrossRewards == 0) continue;  // skip if floored to 0

            //STORAGE: set per-pool gross rewards [user-delegate pair]
            userDelegateAccounting[epoch][msg.sender][delegate].userPoolGrossRewards[poolId] = userGrossRewards;  // flagged as claimed

            //note: add gross to pool claimed [transfer to delegate will be made post-loop]
            epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
            pools[poolId].totalRewardsClaimed += userGrossRewards;

            userTotalGrossRewards += userGrossRewards;
        }

        if(userTotalGrossRewards == 0) revert Errors.NoRewardsToClaim();

        // calc. delegation fee + net rewards | note: could be floored to 0
        uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];    // delegateFeePct>0 : is set when the delegate votes
        uint256 delegateFee = userTotalGrossRewards * delegateFeePct / Constants.PRECISION_BASE;
        uint256 userTotalNetRewards = userTotalGrossRewards - delegateFee;                           
        require(userTotalNetRewards > 0, Errors.NoRewardsToClaim());            // sanity check: unlikely to trigger, but just in case
        
        
        // -------- accounting updates --------

        // increment user's aggregate net claimed
        userDelegateAccounting[epoch][msg.sender][delegate].totalNetRewards += uint128(userTotalNetRewards);
    
        // increment delegate's gross rewards captured [global profile]
        delegates[delegate].totalGrossRewards += userTotalRewards;
        // pay fees to delegate [to honour the loop update: epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards]
        if(delegateFee > 0){
            delegates[delegate].totalFees += delegateFee;
            delegates[delegate].totalFeesClaimed += delegateFee;
            _esMoca().safeTransfer(delegate, delegateFee);
        }

        // global: increment epoch & pool total claimed 
        epochs[epoch].totalRewardsClaimed += userTotalRewards;

        emit Events.RewardsClaimedFromDelegate(epoch, msg.sender, delegate, poolIds, userTotalNetRewards);

        // transfer esMoca to user | note: must whitelist this contract for transfers
        _esMoca().safeTransfer(msg.sender, userTotalNetRewards);
    } */       


//-------------------------------claim subsidies functions----------------------------------------------

    //TODO: subsidies claimable based off their expenditure accrued for a pool-epoch
    //REVIEW: Subsidies are paid out to the `assetAddress` of the verifier, so it is required that, `assetAddress` calls `VotingController.claimSubsidies`
    function claimSubsidies(uint128 epoch, bytes32 verifierId, bytes32[] calldata poolIds) external whenNotPaused {
        require(poolIds.length > 0, Errors.InvalidArray());
        
        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        //TODO[maybe]: epoch: calculate subsidies if not already done; so can front-run/incorporate finalizeEpoch()

        uint256 totalSubsidiesClaimed;  
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // check if pool exists and has subsidies allocated
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            uint256 poolAllocatedSubsidies = epochPools[epoch][poolId].totalRewardsAllocated;
            require(poolAllocatedSubsidies > 0, Errors.NoSubsidiesForPool());

            // check if already claimed
            require(verifierEpochPoolData[epoch][poolId][msg.sender] == 0, Errors.SubsidyAlreadyClaimed());

            // get verifier's accrued subsidies for {pool, epoch} & pool's total accrued subsidies for the epoch
            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) 
                // reverts if msg.sender is not the verifierId's asset address
                = IPaymentsController(IAddressBook.getPaymentsController()).getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifierId, msg.sender);
            
            // calculate subsidy receivable 
            // verifierAccruedSubsidies & poolAccruedSubsidies (USD8), 1e6 precision | poolAllocatedSubsidies (esMOCA), 1e18 precision
            // subsidyReceivable (esMOCA), 1e18 precision
            uint256 subsidyReceivable = (verifierAccruedSubsidies * poolAllocatedSubsidies) / poolAccruedSubsidies; 
            if(subsidyReceivable == 0) continue;  // skip if floored to 0

            totalSubsidiesClaimed += subsidyReceivable;

            // book verifier's subsidy receivable for the epoch
            verifierEpochPoolData[epoch][poolId][msg.sender] = subsidyReceivable;
            verifierEpochData[epoch][msg.sender] += subsidyReceivable;
            verifierData[msg.sender] += subsidyReceivable;      // @follow-up : redundant, query via sum if needed

            // update pool & epoch total claimed
            pools[poolId].totalClaimed += subsidyReceivable;
            epochPools[epoch][poolId].totalClaimed += subsidyReceivable;
        }

        if(totalSubsidiesClaimed == 0) revert Errors.NoSubsidiesToClaim();

        // update epoch & pool total claimed
        TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
        epochs[epoch].totalSubsidiesClaimed += totalSubsidiesClaimed;

        // event
        emit Events.SubsidiesClaimed(msg.sender, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier
        // note: must whitelist VotingController on esMoca for transfers
        _esMoca().transfer(msg.sender, totalSubsidiesClaimed);      
    }


//-------------------------------onlyAssetManager: depositEpochSubsidies, finalizeEpochRewardsSubsidies -----------------------------------------

    /**
     * @notice Deposits esMOCA subsidies for a completed epoch to be distributed among pools based on votes.
     * @dev Callable only by VotingController admin. Calculates and sets subsidy per vote for the epoch.
     *      Transfers esMOCA from the caller to the contract if subsidies > 0 and epoch.votes > 0.
     *      Can only be called after the epoch has ended and before it is finalized.
     * @param epoch The epoch number for which to deposit subsidies.
     * @param subsidies The total amount of esMOCA subsidies to deposit (1e18 precision).
     */
    function depositEpochSubsidies(uint256 epoch, uint256 subsidies) external onlyAssetManager whenNotPaused {
        //require(subsidies > 0, Errors.InvalidAmount()); --> subsidies can be 0
        require(epoch <= EpochMath.getCurrentEpochNumber(), Errors.CannotSetSubsidiesForFutureEpochs());
        
        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized
        EpochData storage epochPtr = epochs[epoch];
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // flag check: subsidies can only be set once for an epoch; and it can be 0
        require(!epochPtr.isSubsidiesSet, Errors.SubsidiesAlreadySet());

        // if subsidies >0 and totalVotes >0: set totalSubsidies + transfer esMoca
        if(subsidies > 0 && epochPtr.totalVotes > 0) {
            // if there are no votes, we will not distribute subsidies
            _esMoca().transferFrom(msg.sender, address(this), subsidies);

            // STORAGE: update total subsidies deposited for epoch + global
            epochPtr.totalSubsidiesDeposited = subsidies;
            TOTAL_SUBSIDIES_DEPOSITED += subsidies;

            emit Events.SubsidiesDeposited(msg.sender, epoch, subsidies);
        } // else: subsidies = 0 or no votes -> no-op, flag still set

        //STORAGE: set flag
        epochPtr.isSubsidiesSet = true;
        emit Events.SubsidiesSet(epoch, subsidies);
    }

    //Note: only callable once for each pool | rewards are referenced from PaymentsController | subsidies are referenced from PaymentsController
    //Review: str vs mem | uint128 vs uint256
    //note: only deposits rewards that can be claimed[poolRewards > 0 & poolVotes > 0]. therefore, sum of input rewards could be lesser than totalRewardsAllocated
    function finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards) external onlyAssetManager whenNotPaused {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == rewards.length, Errors.MismatchedArrayLengths());

        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized + depositEpochSubsidies() must have been called
        EpochData storage epochPtr = epochs[epoch];
        require(epochPtr.isSubsidiesSet, Errors.SubsidiesNotSet());
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // cache to local so for loop does not load from storage for each iteration
        uint256 epochTotalSubsidiesDeposited = epochPtr.totalSubsidiesDeposited;

        // iterate through pools
        uint256 totalSubsidies;
        uint256 totalRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 poolRewards = rewards[i];       // can be 0  @follow-up why can it be 0?  so it can be marked processed

            // cache: Pool storage pointers
            DataTypes.Pool storage poolPtr = pools[poolId];
            DataTypes.PoolEpoch storage epochPoolPtr = epochPools[epoch][poolId];

            // sanity check: pool exists + not processed + not removed
            require(poolPtr.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!epochPoolPtr.isProcessed, Errors.PoolAlreadyProcessed());
            require(!poolPtr.isRemoved, Errors.PoolRemoved());

            uint256 poolVotes = epochPoolPtr.totalVotes;
            
            // Calc. subsidies for each pool | if there are subsidies for epoch + pool has votes
            if(epochTotalSubsidiesDeposited > 0 && poolVotes > 0) {
                
                uint256 poolSubsidies = (poolVotes * epochPtr.totalSubsidiesDeposited) / epochPtr.totalVotes;
                
                // sanity check: poolSubsidies > 0; skip if floored to 0
                if(poolSubsidies > 0) { 
                    epochPoolPtr.totalSubsidiesAllocated = uint128(poolSubsidies);
                    poolPtr.totalSubsidiesAllocated += poolSubsidies;

                    totalSubsidies += poolSubsidies;
                }
            }

            // Set totalRewards for each pool | only if rewards >0 and votes >0 (avoids undistributable)
            if(poolRewards > 0 && poolVotes > 0) {

                epochPoolPtr.totalRewardsAllocated = poolRewards;
                poolPtr.totalRewardsAllocated += poolRewards;

                totalRewards += poolRewards;
            } // else skip, rewards effectively 0 for this pool

            // mark processed
            epochPoolPtr.isProcessed = true;
        }

        //STORAGE update epoch global | do not overwrite subsidies; was set in depositEpochSubsidies()
        epochPtr.totalRewardsAllocated += totalRewards;

        emit Events.EpochPartiallyFinalized(epoch, poolIds);

        // STORAGE: increment count of pools finalized
        epochPtr.poolsFinalized += uint128(poolIds.length);

        // deposit rewards
        _esMoca().transferFrom(msg.sender, address(this), totalRewards);

        // check if epoch is fully finalized
        if(epochPtr.poolsFinalized == TOTAL_NUMBER_OF_POOLS) {
            epochPtr.isFullyFinalized = true;
            emit Events.EpochFullyFinalized(epoch);
        }
    }


//-------------------------------onlyAssetManager: withdrawUnclaimedRewards, withdrawUnclaimedSubsidies -----------------------------------------
    
    /**
     * @notice Sweep all unclaimed and residual voting rewards for a given epoch to the treasury.
     * @dev Can only be called by a VotingController admin after a delay defined by UNCLAIMED_DELAY_EPOCHS epochs.
     *      Transfers both unclaimed and residual (unclaimable flooring losses) esMoca rewards to the treasury.
     *      Emits an {UnclaimedRewardsWithdrawn} event on success.
     *      Reverts if the epoch is not finalized, the treasury address is unset, or there are no unclaimed rewards to sweep.
     * @param epoch The epoch number for which to sweep unclaimed and residual rewards.
     */
    function withdrawUnclaimedRewards(uint256 epoch) external onlyAssetManager whenNotPaused {
        // sanity check: withdraw delay must have passed
        require(epoch >= EpochMath.getCurrentEpochNumber() + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());
        
        // sanity check: epoch must be finalized [pool exists implicitly]
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        // sanity check: there must be unclaimed rewards
        uint256 unclaimed = epochs[epoch].totalRewardsAllocated - epochs[epoch].totalRewardsClaimed;
        require(unclaimed > 0, Errors.NoUnclaimedRewardsToWithdraw());

        address treasury = IAddressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());
        
        _esMoca().safeTransfer(treasury, unclaimed);

        emit Events.UnclaimedRewardsWithdrawn(treasury, epoch, unclaimed);
    }

    /**
     * @notice Sweep all unclaimed and residual subsidies for a specified epoch to the treasury.
     * @dev Can only be called by a VotingController admin after a delay defined by UNCLAIMED_DELAY_EPOCHS epochs.
     *      Transfers both unclaimed and residual (unclaimable flooring losses) esMoca subsidies to the treasury.
     *      Emits an {UnclaimedSubsidiesWithdrawn} event on success.
     *      Reverts if the epoch is not finalized, the delay has not passed, the treasury address is unset, or there are no unclaimed subsidies to sweep.
     * @param epoch The epoch number for which to sweep unclaimed and residual subsidies.
     */
    function withdrawUnclaimedSubsidies(uint256 epoch) external onlyAssetManager whenNotPaused {
        // sanity check: withdraw delay must have passed
        require(epoch >= EpochMath.getCurrentEpochNumber() + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // sanity check: epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());
        
        // sanity check: there must be unclaimed subsidies
        uint256 unclaimedSubsidies = epochs[epoch].totalSubsidiesDeposited - epochs[epoch].totalSubsidiesClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        address treasury = IAddressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());

        // transfer esMoca to admin/deposit(?)
        _esMoca().transfer(treasury, unclaimedSubsidies);

        // event
        emit Events.UnclaimedSubsidiesWithdrawn(treasury, epoch, unclaimedSubsidies);
    }

    function withdrawRegistrationFees() external onlyAssetManager whenNotPaused {
        require(TOTAL_REGISTRATION_FEES > 0, Errors.NoRegistrationFeesToWithdraw());

        uint256 claimable = TOTAL_REGISTRATION_FEES - REGISTRATION_FEES_CLAIMED;
        require(claimable > 0, Errors.InvalidAmount());

        address treasury = IAddressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());

        _moca().safeTransfer(treasury, claimable);

        emit Events.RegistrationFeesWithdrawn(treasury, claimable);
    }
    
//-------------------------------onlyVotingControllerAdmin: setters ---------------------------------------------------------

    /**
     * @notice Sets the maximum delegate fee percentage.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and less than PRECISION_BASE.
     * @param maxFeePct The new maximum delegate fee percentage (2 decimal precision, e.g., 100 = 1%).
     */
    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyVotingControllerAdmin whenNotPaused {
        require(maxFeePct > 0, Errors.InvalidFeePct());
        require(maxFeePct < Constants.PRECISION_BASE, Errors.InvalidFeePct());

        MAX_DELEGATE_FEE_PCT = maxFeePct;

        emit Events.MaxDelegateFeePctUpdated(maxFeePct);
    }


    /**
     * @notice Sets the fee increase delay epochs.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and a multiple of EpochMath.EPOCH_DURATION.
     * @param delayEpochs The new fee increase delay epochs.
     */
    function setFeeIncreaseDelayEpochs(uint256 delayEpochs) external onlyVotingControllerAdmin whenNotPaused {
        require(delayEpochs > 0, Errors.InvalidDelayPeriod());
        require(delayEpochs % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayPeriod());
       
        FEE_INCREASE_DELAY_EPOCHS = delayEpochs;
        emit Events.FeeIncreaseDelayEpochsUpdated(delayEpochs);
    }

    /**
     * @notice Sets the unclaimed delay epochs.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and a multiple of EpochMath.EPOCH_DURATION.
     * @param delayEpochs The new unclaimed delay epochs.
     * This delay applied to both withdrawUnclaimedRewards and withdrawUnclaimedSubsidies
     */
    function setUnclaimedDelay(uint256 newDelayEpoch) external onlyVotingControllerAdmin whenNotPaused {
        require(newDelayEpoch > 0, Errors.InvalidDelayPeriod());
        require(newDelayEpoch % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayPeriod());

        emit Events.UnclaimedDelayUpdated(UNCLAIMED_DELAY_EPOCHS, newDelayEpoch);
        UNCLAIMED_DELAY_EPOCHS = newDelayEpoch;
    }

    // TODO
    function setDelegateRegistrationFee(uint256 newRegistrationFee) external onlyVotingControllerAdmin whenNotPaused {
        //require(newRegistrationFee > 0, Errors.InvalidRegistrationFee());  0 is acceptable

        emit Events.DelegateRegistrationFeeUpdated(REGISTRATION_FEE, newRegistrationFee);
        REGISTRATION_FEE = newRegistrationFee;
    }


//-------------------------------onlyVotingControllerAdmin: pool functions----------------------------------------------------

    /**
     * @notice Creates a new pool with a unique poolId.
     * @dev Only callable by VotingController admin. The poolId is generated to be unique.
     * @return poolId The unique identifier assigned to the new pool.
     */
    function createPool() external onlyVotingControllerAdmin whenNotPaused returns (bytes32) {
           
        // generate issuerId
        bytes32 poolId;
        {
            uint256 salt = block.number; 
            poolId = _generatePoolId(salt, msg.sender);

            // generated id must be unique: if used by pool, generate new Id
            while (pools[poolId].poolId != bytes32(0)) {
                poolId = _generatePoolId(++salt, msg.sender); 
            }
        }

        pools[poolId].poolId = poolId;

        ++TOTAL_NUMBER_OF_POOLS;

        emit Events.PoolCreated(poolId);

        return poolId;
    }

    /**
     * @notice Removes a pool from the protocol.
     * @dev Only callable by VotingController admin.
     *
     * Pool removal is only permitted before `depositSubsidies()` is called for the current epoch.
     * 
     * This restriction prevents race conditions with `TOTAL_NUMBER_OF_POOLS` during end-of-epoch operations.
     * If a pool is removed while `finalizeEpoch` is running, the check `poolsFinalized == TOTAL_NUMBER_OF_POOLS` could fail,
     * potentially leaving the epoch in an unfinalizable state.
     *
     * To ensure protocol safety, pool removal is blocked once subsidies are deposited, signaling that end-of-epoch
     * operations are underway and pool set must remain static.
     *
     * @param poolId The unique identifier of the pool to remove.
     */
    function removePool(bytes32 poolId) external onlyVotingControllerAdmin whenNotPaused {
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
        
        // pool removal not allowed before finalizeEpochRewardsSubsidies() - else, TOTAL_NUMBER_OF_POOLS will be off and epoch will be never finalized
        require(!epochs[EpochMath.getCurrentEpochNumber()].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        pools[poolId].isRemoved = true;

        --TOTAL_NUMBER_OF_POOLS;    

        emit Events.PoolRemoved(poolId);
    }

//-------------------------------internal functions------------------------------------------------------


    /**
     * @notice Applies the pending delegate fee increase if the scheduled epoch has started.
     * @dev If the current epoch is greater than or equal to the delegate's nextFeePctEpoch,
     *      updates currentFeePct, sets the historical fee for the current epoch, and clears pending fields.
     * @param delegateAddr The address of the delegate whose fee may be updated.
     * @param currentEpoch The current epoch number.
     * @return True if a pending fee was applied and historical fee set, false otherwise.
     */
    function _applyPendingFeeIfNeeded(address delegateAddr, uint256 currentEpoch) internal returns (bool) {
        Delegate storage delegatePtr = delegates[delegateAddr];

        // if there is a pending fee increase, apply it
        if(delegatePtr.nextFeePctEpoch > 0) {
            if(currentEpoch >= delegatePtr.nextFeePctEpoch) {
                
                // update currentFeePct and set the historical fee for the current epoch
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;
                delegateHistoricalFees[delegateAddr][currentEpoch] = delegatePtr.currentFeePct;  // Ensure set for claims
                
                // reset the pending fields
                delete delegatePtr.nextFeePct;
                delete delegatePtr.nextFeePctEpoch;

                // return true if a pending fee was applied and historical fee set
                return true;
            }
        }

        // return false if there is no pending fee
        return false;
    }


    // Internal function for shared claim logic (handles one delegator) | delegator==user
    function _claimDelegateRewards(uint256 epoch, address delegator, address delegate, bytes32[] calldata poolIds) internal returns (uint256, uint256) {
        uint256 userTotalGrossRewards;
        uint256 delegateTotalPoolRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // sanity checks: pool exists + user has not claimed rewards from this delegate-pool pair yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] == 0, Errors.RewardsAlreadyClaimed());

            // calculations: delegate's votes for this pool + pool totals
            uint256 delegatePoolVotes = delegatesEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
            uint256 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            uint256 totalPoolRewards = epochPools[epoch][poolId].totalRewards;

            if (totalPoolRewards == 0 || totalPoolVotes == 0) continue;  // skip if pool has no rewards or votes

            uint256 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
            if (delegatePoolRewards == 0) continue;  // skip if floored to 0

            // book delegate's rewards for this pool & epoch
            delegatesEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;

            // fetch: number of votes user delegated, to this delegate & the total votes managed by the delegate
            uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);
            uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;

            // calc. user's gross rewards for the pool
            uint256 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
            if (userGrossRewards == 0) continue;  // skip if floored to 0

            // book user's gross rewards for this pool & epoch
            userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] = userGrossRewards;

            // update pool & epoch: total claimed rewards
            epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
            pools[poolId].totalRewardsClaimed += userGrossRewards;

            // update counters
            userTotalGrossRewards += userGrossRewards;
            delegateTotalPoolRewards += delegatePoolRewards;
        }

        if (userTotalGrossRewards == 0) return (0, 0);  // Early return if nothing to claim

        // calc. delegate fee + net rewards on total gross rewards, so as to not lose precision
        uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];           
        uint256 delegateFee = userTotalGrossRewards * delegateFeePct / Constants.PRECISION_BASE;
        uint256 userTotalNetRewards = userTotalGrossRewards - delegateFee;

        // ---- Accounting updates ----
        
        // increment user's net rewards earned via delegated votes
        userDelegateAccounting[epoch][delegator][delegate].totalNetRewards += uint128(userTotalNetRewards);

        // update delegate's captured (non-claimable) rewards for this epoch
        delegateEpochData[epoch][delegate].totalRewards = delegateTotalPoolRewards;         
        delegates[delegate].totalRewardsCaptured += userTotalGrossRewards;

        // update delegate's fees for this epoch
        if (delegateFee > 0) {
            delegates[delegate].totalFees += delegateFee;
            delegates[delegate].totalFeesClaimed += delegateFee;
        }

        // since we payout to both user and delegate, we increment by gross rewards
        epochs[epoch].totalRewardsClaimed += userTotalGrossRewards;

        return (userTotalNetRewards, delegateFee);
    }


    ///@dev Generate a poolId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generatePoolId(uint256 salt, address callerAddress) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(callerAddress, block.timestamp, salt)));
    }


    function _veMoca() internal view returns (IVotingEscrowMoca){
        return IVotingEscrowMoca(_addressBook.getVotingEscrowMoca());
    }

    function _esMoca() internal view returns (IERC20){
        return IERC20(_addressBook.getEscrowedMoca());
    }

    function _moca() internal view returns (IERC20){
        return IERC20(_addressBook.getMoca());
    }

//-------------------------------Modifiers---------------------------------------------------------------

    // for creating pools, removing pools, setting contract params
    modifier onlyVotingControllerAdmin() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isVotingControllerAdmin(msg.sender), "Only callable by Voting Controller Admin");
        _;
    }

    // for depositing/withdrawing assets [depositSubsidies(), finalizeEpoch(), withdrawUnclaimedX()]
    modifier onlyAssetManager() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isAssetManager(msg.sender), "Only callable by Asset Manager");
        _;
    }

    // pause
    modifier onlyMonitor() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isMonitor(msg.sender), "Only callable by Monitor");
        _;
    }

    // for unpause + freeze 
    modifier onlyGlobalAdmin() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isGlobalAdmin(msg.sender), "Only callable by Global Admin");
        _;
    }   
    
    // to exfil assets, when frozen
    modifier onlyEmergencyExitHandler() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isEmergencyExitHandler(msg.sender), "Only callable by Emergency Exit Handler");
        _;
    }

//-------------------------------risk functions----------------------------------------------------------

    /**
     * @notice Pause the contract.
     * @dev Only callable by the Monitor [bot script].
     */
    function pause() external whenNotPaused onlyMonitor {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _pause();
    }

    /**
     * @notice Unpause the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     */
    function unpause() external whenPaused onlyGlobalAdmin {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice Freeze the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     *      This is a kill switch function
     */
    function freeze() external whenPaused onlyGlobalAdmin {
        if(isFrozen == 1) revert Errors.IsFrozen();
        isFrozen = 1;
        emit Events.ContractFrozen();
    }

    /**
     * @notice Exfiltrate all contract-held assets (rewards + subsidies + registration fees) to the treasury.
     * @dev Disregards all outstanding claims and does not update any contract state.
     *      Intended for emergency use only when the contract is frozen.
     *      Only callable by the Emergency Exit Handler [bot script].
     *      This is a kill switch function
     */
    function emergencyExit() external onlyEmergencyExitHandler {
        if(isFrozen == 0) revert Errors.NotFrozen();

        // get treasury address
        address treasury = IAddressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());

        // exfil esMoca [rewards + subsidies]
        IERC20 esMoca = _esMoca();  
        esMoca.safeTransfer(treasury, esMoca.balanceOf(address(this)));

        // exfil moca [registration fees]
        IERC20 moca = _moca();
        moca.safeTransfer(treasury, moca.balanceOf(address(this)));

        emit Events.EmergencyExit(treasury);
    }


//-------------------------------view functions-----------------------------------------------------------

    function getAddressBook() external view returns (IAddressBook) {
        return _addressBook;
    }

    /**
     * @notice Returns the gross rewards mapping for a user-delegate pair for a given epoch.
     * @dev Returns an array of gross rewards for the specified poolIds.
     * @param epoch The epoch number.
     * @param user The address of the user.
     * @param delegate The address of the delegate.
     * @param poolIds The array of pool identifiers to query.
     * @return grossRewardsPerPool Array of gross rewards for each poolId.
     * @return totalGrossRewards Total gross rewards for the user-delegate pair.
     */
    function getUserDelegatePoolGrossRewards(uint256 epoch, address user, address delegate, bytes32[] calldata poolIds) external view returns (uint128[] memory, uint128) {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint128[] memory grossRewardsPerPool = new uint128[](poolIds.length);
        
        // fetch gross rewards for each poolId
        uint256 totalGrossRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            grossRewardsPerPool[i] = userDelegateAccounting[epoch][user][delegate].poolGrossRewards[poolIds[i]];
            totalGrossRewards += grossRewardsPerPool[i];
        }
    
        return (grossRewardsPerPool, totalGrossRewards);
    }

}