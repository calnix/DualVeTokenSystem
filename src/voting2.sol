// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControlEnumerable, AccessControl} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {Constants} from "./libraries/Constants.sol";
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";

// interfaces
import {IPaymentsController} from "./interfaces/IPaymentsController.sol";
import {IVotingEscrowMoca} from "./interfaces/IVotingEscrowMoca.sol";
import {IEscrowedMoca} from "./interfaces/IEscrowedMoca.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
 * @title VotingController
 * @author Calnix [@cal_nix]
 * @notice Central contract managing voting, delegation, and related reward distribution.
 * @dev Coordinates voting, delegation, pool management, and reward/subsidy flows. 
 *      Integrates with external controllers and enforces protocol-level access and safety checks.
 */

contract voting2 is Pausable, LowLevelWMoca, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    // Immutable Contracts
    IVotingEscrowMoca public immutable VEMOCA;
    address public immutable WMOCA;

    // mutable contracts
    IERC20 public ESMOCA;
    IPaymentsController public PAYMENTS_CONTROLLER;
    address public VOTING_CONTROLLER_TREASURY;

    // pools
    uint128 public TOTAL_POOLS_CREATED;
    uint128 public TOTAL_ACTIVE_POOLS;

    // subsidies
    uint128 public TOTAL_SUBSIDIES_DEPOSITED;
    uint128 public TOTAL_SUBSIDIES_CLAIMED;

    // rewards
    uint128 public TOTAL_REWARDS_DEPOSITED;
    uint128 public TOTAL_REWARDS_CLAIMED;

    // delegate 
    uint128 public DELEGATE_REGISTRATION_FEE;           // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint128 public MAX_DELEGATE_FEE_PCT;                // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint128 public FEE_INCREASE_DELAY_EPOCHS;           // in epochs
    
    // registration fees [native MOCA]
    uint128 public TOTAL_REGISTRATION_FEES_COLLECTED;    
    uint128 public TOTAL_REGISTRATION_FEES_CLAIMED;

    // Number of epochs that must pass before unclaimed rewards or subsidies can be withdrawn
    uint128 public UNCLAIMED_DELAY_EPOCHS;

    // gas limit for moca transfer
    uint128 public MOCA_TRANSFER_GAS_LIMIT;

    // risk management
    uint128 public isFrozen;

//-------------------------------Mappings-------------------------------------------------

    // global data
    mapping(uint128 epochNum => DataTypes.Epoch epoch) public epochs;    
    mapping(uint128 poolId => DataTypes.Pool pool) public pools;

    // pool data [epoch]
    mapping(uint128 epochNum => mapping(uint128 poolId => DataTypes.PoolEpoch poolEpoch)) public epochPools;

    // user data: perEpoch & perPoolPerEpoch
    mapping(uint128 epochNum => mapping(address userAddr => DataTypes.Account userAccount)) public usersEpochData;
    mapping(uint128 epochNum => mapping(uint128 poolId => mapping(address user => DataTypes.Account userAccount))) public usersEpochPoolData;

    // delegate aggregated data: perEpoch & perPoolPerEpoch [mirror of usersEpochData & usersEpochPoolData]
    mapping(uint128 epochNum => mapping(address delegateAddr => DataTypes.Account delegate)) public delegateEpochData;
    mapping(uint128 epochNum => mapping(uint128 poolId => mapping(address delegate => DataTypes.Account delegateAccount))) public delegatesEpochPoolData;


    // User-Delegate pair tracking [for this user-delegate pair, what was the user's {rewards,claimed}]
    mapping(uint128 epochNum => mapping(address user => mapping(address delegate => DataTypes.UserDelegateAccount userDelegateAccount))) public userDelegateAccounting;


    // Delegate registration data + fee data
    mapping(address delegateAddr => DataTypes.Delegate delegate) public delegates;     
    mapping(address delegate => mapping(uint128 epoch => uint128 currentFeePct)) public delegateHistoricalFeePcts;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)


    // updated in claimSubsidies()
    mapping(address verifier => uint128 totalSubsidies) public verifierSubsidies;                  
    mapping(uint128 epoch => mapping(address verifier => uint128 totalSubsidies)) public verifierEpochSubsidies;
    mapping(uint128 epoch => mapping(uint128 poolId => mapping(address verifier => uint128 totalSubsidies))) public verifierEpochPoolSubsidies;


//------------------------------- Constructor -------------------------------------------------------------------

    constructor(
        uint128 maxDelegateFeePct, uint128 feeDelayEpochs, uint128 unclaimedDelayEpochs, address wMoca_, uint128 mocaTransferGasLimit, 
        address votingEscrowMoca_, address escrowedMoca_, address votingControllerTreasury_, address paymentsController_,
        address globalAdmin, address votingControllerAdmin, address monitorAdmin, address cronJobAdmin,
        address monitorBot, address emergencyExitHandler, address assetManager, uint128 delegateRegistrationFee
    ) {

        // check: voting controller treasury is set
        require(votingControllerTreasury_ != address(0), Errors.InvalidAddress());
        VOTING_CONTROLLER_TREASURY = votingControllerTreasury_;
        // check: payments controller is set
        require(paymentsController_ != address(0), Errors.InvalidAddress());
        PAYMENTS_CONTROLLER = IPaymentsController(paymentsController_);
        // check: voting escrow moca is set
        require(votingEscrowMoca_ != address(0), Errors.InvalidAddress());
        VEMOCA = IVotingEscrowMoca(votingEscrowMoca_);
        // check: escrowed moca is set
        require(escrowedMoca_ != address(0), Errors.InvalidAddress());
        ESMOCA = IERC20(escrowedMoca_);
        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;


        // set fee increase delay
        require(feeDelayEpochs > 0, Errors.InvalidDelayPeriod());
        FEE_INCREASE_DELAY_EPOCHS = feeDelayEpochs;

        // set unclaimed delay
        require(unclaimedDelayEpochs > 0, Errors.InvalidDelayPeriod());
        UNCLAIMED_DELAY_EPOCHS = unclaimedDelayEpochs;

        // set max delegate fee percentage
        require(maxDelegateFeePct > 0 && maxDelegateFeePct < Constants.PRECISION_BASE, Errors.InvalidFeePct());
        MAX_DELEGATE_FEE_PCT = maxDelegateFeePct;

        // set delegate registration fee
        DELEGATE_REGISTRATION_FEE = delegateRegistrationFee;

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;

        // roles
        _setupRoles(globalAdmin, votingControllerAdmin, monitorAdmin, cronJobAdmin, monitorBot, emergencyExitHandler, assetManager);

        // finalize previous epoch [to unblock: createPools(), removePools(), depositEpochSubsidies()]
        uint128 previousEpoch = EpochMath.getCurrentEpochNumber() - 1;
        epochs[previousEpoch].isSubsidiesSet = true;
        epochs[previousEpoch].isFullyProcessed = true;
        epochs[previousEpoch].isEpochFinalized = true;
    }

    function _setupRoles(
        address globalAdmin, address votingControllerAdmin, address monitorAdmin, address cronJobAdmin,
        address monitorBot, address emergencyExitHandler, address assetManager
    ) internal {
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(votingControllerAdmin != address(0), Errors.InvalidAddress());
        require(monitorAdmin != address(0), Errors.InvalidAddress());
        require(cronJobAdmin != address(0), Errors.InvalidAddress());
        require(monitorBot != address(0), Errors.InvalidAddress());
        require(emergencyExitHandler != address(0), Errors.InvalidAddress());
        require(assetManager != address(0), Errors.InvalidAddress());
        
        // grant roles to addresses
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);    
        _grantRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE, votingControllerAdmin);
        _grantRole(Constants.MONITOR_ADMIN_ROLE, monitorAdmin);
        _grantRole(Constants.CRON_JOB_ADMIN_ROLE, cronJobAdmin);
        _grantRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler);
        _grantRole(Constants.ASSET_MANAGER_ROLE, assetManager);

        // there should at least 1 bot address for monitoring at deployment
        _grantRole(Constants.MONITOR_ROLE, monitorBot);

        // --------------- Set role admins ------------------------------
        // Operational role administrators managed by global admin
        _setRoleAdmin(Constants.VOTING_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(Constants.EMERGENCY_EXIT_HANDLER_ROLE, DEFAULT_ADMIN_ROLE);

        _setRoleAdmin(Constants.MONITOR_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(Constants.CRON_JOB_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        // High-frequency roles managed by their dedicated admins
        _setRoleAdmin(Constants.MONITOR_ROLE, Constants.MONITOR_ADMIN_ROLE);
        _setRoleAdmin(Constants.CRON_JOB_ROLE, Constants.CRON_JOB_ADMIN_ROLE);
    }

//------------------------------- Voting functions --------------------------------------------------------------

    /**
     * @notice Cast votes for one or more pools using either personal or delegated voting power.
     * @dev If `isDelegated` is true, the caller's delegated voting power is used; otherwise, personal voting power is used.
     *      If `isDelegated` is true, caller must be registered as delegate
     * @param poolIds Array of pool IDs to vote for.
     * @param poolVotes Array of votes corresponding to each pool.
     * @param isDelegated Boolean flag indicating whether to use delegated voting power.

     */
    function vote(uint128[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external whenNotPaused {
        // sanity check: poolIds & poolVotes must be non-empty and have the same length
        uint256 length = poolIds.length;
        require(length > 0, Errors.InvalidArray());
        require(length == poolVotes.length, Errors.MismatchedArrayLengths());

        // get current epoch & cache epoch pointer
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // epoch is being finalized: no more votes allowed
        require(!epochPtr.isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        ( mapping(uint128 => mapping(address => DataTypes.Account)) storage accountEpochData,
          mapping(uint128 => mapping(uint128 => mapping(address => DataTypes.Account))) storage accountEpochPoolData 
        ) 
        = isDelegated ? (delegateEpochData, delegatesEpochPoolData) : (usersEpochData, usersEpochPoolData);

        // executed each time, since delegate fee decreases are instantly applied
        if (isDelegated) _validateDelegateAndRecordFee(currentEpoch);

        // get account's total voting power: benchmarked to end of epoch [forward-decay]
        uint128 totalVotes = VEMOCA.balanceAtEpochEnd(msg.sender, currentEpoch, isDelegated);
        
        // get account's spent votes
        uint128 spentVotes = accountEpochData[currentEpoch][msg.sender].totalVotesSpent; 

        // check: account has available votes 
        uint128 availableVotes = totalVotes - spentVotes;
        require(availableVotes > 0, Errors.NoAvailableVotes());

        // update votes at a pool+epoch level
        // does not check for duplicate poolIds in the array; users can vote repeatedly for the same pool
        uint128 totalNewVotes;
        for(uint256 i; i < length; ++i) {
            uint128 poolId = poolIds[i];
            uint128 votes = poolVotes[i];

            // do not skip on 0 vote, as it likely indicates incorrect array inputs
            require(votes > 0, Errors.ZeroVotes()); 
            
            // cache pool pointer
            DataTypes.Pool storage poolPtr = pools[poolId];

            // pool must be active
            require(poolPtr.isActive, Errors.PoolNotActive());
            
            // increment counter & check: cannot exceed available votes
            totalNewVotes += votes; 
            require(totalNewVotes <= availableVotes, Errors.InsufficientVotes());

            // increment account's votes [epoch-pool]
            accountEpochPoolData[currentEpoch][poolId][msg.sender].totalVotesSpent += votes;

            // increment pool votes [epoch, pool]
            epochPools[currentEpoch][poolId].totalVotes += votes;
            poolPtr.totalVotes += votes;       
        }

        // increment epoch totalVotes 
        epochPtr.totalVotes += totalNewVotes;

        // increment account's votes [epoch]
        accountEpochData[currentEpoch][msg.sender].totalVotesSpent += totalNewVotes;
        
        emit Events.Voted(currentEpoch, msg.sender, poolIds, poolVotes, isDelegated);
    }

    /**
     * @notice Migrate votes from one or more source pools to destination pools within the current epoch.
     * @dev Allows users to move their votes between pools before the epoch is finalized.
     *      Supports both partial and full vote migration. Can migrate from inactive to active pools, but not vice versa.
     * @param srcPoolIds Array of source pool IDs from which votes will be migrated.
     * @param dstPoolIds Array of destination pool IDs to which votes will be migrated.
     * @param votesToMigrate Array of vote amounts to migrate for each pool pair.
     * @param isDelegated Boolean indicating if the migration is for delegated votes.
     * If isDelegated: true, caller must be registered as delegate
     * Reverts if input array lengths mismatch, pools do not exist, destination pool is not active, insufficient votes in source pool, or epoch is finalized.
     */
    function migrateVotes(uint128[] calldata srcPoolIds, uint128[] calldata dstPoolIds, uint128[] calldata votesToMigrate, bool isDelegated) external whenNotPaused {
        // input check: array lengths must be non-empty and match
        uint256 length = srcPoolIds.length;
        require(length > 0, Errors.InvalidArray());
        require(length == dstPoolIds.length, Errors.MismatchedArrayLengths());
        require(length == votesToMigrate.length, Errors.MismatchedArrayLengths());

        // get current epoch
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // if epoch is being finalized: no more votes allowed
        require(!epochPtr.isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // validate delegate and record fee: executed each time, since delegate fee decreases are instantly applied
        if (isDelegated) _validateDelegateAndRecordFee(currentEpoch);


        // mapping lookups: account:{personal,delegate}
        mapping(uint128 => mapping(uint128 => mapping(address => DataTypes.Account))) storage accountEpochPoolData  
        = isDelegated ? delegatesEpochPoolData : usersEpochPoolData;
   

        // can migrate votes from inactive pool to active pool; but not vice versa
        for(uint256 i; i < length; ++i) {
            
            uint128 srcPoolId = srcPoolIds[i];
            uint128 dstPoolId = dstPoolIds[i];
            uint128 votes = votesToMigrate[i];

            // do not skip on 0 vote, as it likely indicates incorrect array inputs
            require(votes > 0, Errors.ZeroVotes());
            
            // check: source and destination pools are different
            require(srcPoolId != dstPoolId, Errors.InvalidPoolPair());

            // cache storage pointers
            DataTypes.Pool storage srcPoolPtr = pools[srcPoolId];
            DataTypes.Pool storage dstPoolPtr = pools[dstPoolId];
            DataTypes.PoolEpoch storage srcEpochPoolPtr = epochPools[currentEpoch][srcPoolId];
            DataTypes.PoolEpoch storage dstEpochPoolPtr = epochPools[currentEpoch][dstPoolId];

            // check: dstPool is active [src pool can be inactive]
            require(dstPoolPtr.isActive, Errors.PoolNotActive());

            // ensure user has enough votes in source pool for migration
            uint128 votesInSrcPool = accountEpochPoolData[currentEpoch][srcPoolId][msg.sender].totalVotesSpent;
            require(votesInSrcPool >= votes, Errors.InsufficientVotes());

            // deduct from source pool
            accountEpochPoolData[currentEpoch][srcPoolId][msg.sender].totalVotesSpent -= votes;
            srcEpochPoolPtr.totalVotes -= votes;
            srcPoolPtr.totalVotes -= votes;

            // add to destination pool
            accountEpochPoolData[currentEpoch][dstPoolId][msg.sender].totalVotesSpent += votes;
            dstEpochPoolPtr.totalVotes += votes;
            dstPoolPtr.totalVotes += votes;

            // if migrating from an INACTIVE pool, restore votes to epoch.totalVotes
            if (!srcPoolPtr.isActive) epochPtr.totalVotes += votes;

            // no need to update mappings accountEpochData; as its a migration of votes within the same epoch.
        }

        emit Events.VotesMigrated(currentEpoch, msg.sender, srcPoolIds, dstPoolIds, votesToMigrate, isDelegated);
    }

//------------------------------- Delegate functions ------------------------------------------

    /**
     * @notice Registers the caller as a delegate and activates their status.
     * @dev Requires payment of the registration fee in Native Moca. 
     *      Calls VotingEscrowMoca.registerAsDelegate() to mark the delegate as active.
     * @param feePct The fee percentage to be applied to the delegate's rewards.
     */
    function registerAsDelegate(uint128 feePct) external payable whenNotPaused {
        require(msg.value == DELEGATE_REGISTRATION_FEE, Errors.InvalidAmount());

        // fee percentage cannot exceed MAX_DELEGATE_FEE_PCT
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidPercentage());

        // check: delegate is not already registered
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];
        require(!delegatePtr.isRegistered, Errors.DelegateAlreadyRegistered());
        
        // register on VotingEscrowMoca [if delegate is already registered on VotingEscrowMoca: reverts]
        VEMOCA.delegateRegistrationStatus(msg.sender, true);

        // storage: register delegate & set fee percentage
        delegatePtr.isRegistered = true;
        delegatePtr.currentFeePct = feePct;
        delegateHistoricalFeePcts[msg.sender][EpochMath.getCurrentEpochNumber()] = feePct;
        
        // update total registration fees collected
        TOTAL_REGISTRATION_FEES_COLLECTED += uint128(msg.value);

        emit Events.DelegateRegistered(msg.sender, feePct);
    }

    /**
     * @notice Called by delegate to update their fee percentage.
     * @dev If the fee is increased, the new fee takes effect from currentEpoch + FEE_INCREASE_DELAY_EPOCHS to prevent last-minute increases.
     *      If the fee is decreased, the new fee takes effect immediately.
     * @param newFeePct The new fee percentage to be applied to the delegate's rewards.
     */
    function updateDelegateFee(uint128 newFeePct) external whenNotPaused {
        // fee percentage cannot exceed MAX_DELEGATE_FEE_PCT
        require(newFeePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());   
        
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];
        
        // check: delegate is registered
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint128 currentFeePct = delegatePtr.currentFeePct;
        
        // check: new fee is different from current fee
        require(newFeePct != currentFeePct, Errors.InvalidFeePct()); 

        // if new fee is less than current fee: decrease fee immediately
        if(newFeePct < currentFeePct) {

            // set new fee immediately
            delegatePtr.currentFeePct = newFeePct;
            delegateHistoricalFeePcts[msg.sender][currentEpoch] = newFeePct;

            // delete pending
            delete delegatePtr.nextFeePct;
            delete delegatePtr.nextFeePctEpoch;

            emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, newFeePct);

        } else { // fee increased: schedule increase for future epoch

            delegatePtr.nextFeePct = newFeePct;
            delegatePtr.nextFeePctEpoch = currentEpoch + FEE_INCREASE_DELAY_EPOCHS;

            emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, newFeePct, delegatePtr.nextFeePctEpoch);
        }
    }

    /**
     * @notice Unregisters the caller as a delegate.
     * @dev Removes delegate status and sets them as inactive in VotingEscrowMoca. Registration fee is non-refundable.
     */
    function unregisterAsDelegate() external whenNotPaused {
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];
        
        // check: delegate is registered
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        // check: delegate has no active votes
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(delegateEpochData[currentEpoch][msg.sender].totalVotesSpent == 0, Errors.CannotUnregisterWithActiveVotes());
 
        // storage: unregister delegate
        delete delegatePtr.isRegistered;

        emit Events.DelegateUnregistered(msg.sender);

        // mark as unregistered on VotingEscrowMoca
        VEMOCA.delegateRegistrationStatus(msg.sender, false);
    }

//------------------------------- Claiming rewards & fees functions ----------------------------------------------

    /**
     * @notice Claims esMoca rewards for selected pools in a finalized epoch.
     * @dev Users claim rewards from pools they voted in during a past epoch. 
     *      Pools with zero rewards or zero user votes are ignored. 
     *      Double claims are prevented by checking usersEpochPoolData[epoch][poolId][msg.sender].totalRewards.
     * @param epoch Epoch number for which rewards are claimed.
     * @param poolIds Array of pool IDs to claim rewards from.
     */
    function claimPersonalRewards(uint128 epoch, uint128[] calldata poolIds) external whenNotPaused {
        // input validation
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());

        // cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // epoch must be finalized
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());

        // rewards must not have been withdrawn for this epoch
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());


        uint128 userTotalRewards;

        for(uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            // cache pointers             
            DataTypes.Account storage userPoolAccountPtr = usersEpochPoolData[epoch][poolId][msg.sender];
            DataTypes.PoolEpoch storage poolEpochPtr = epochPools[epoch][poolId];

            // prevent double claiming
            require(userPoolAccountPtr.totalRewards == 0, Errors.AlreadyClaimedOrNoRewardsToClaim()); 

            uint128 userVotes = userPoolAccountPtr.totalVotesSpent;
            uint128 poolRewards = poolEpochPtr.totalRewardsAllocated;
            
            // Skip pools with zero rewards or zero user votes
            if(poolRewards == 0 || userVotes == 0) continue;

            uint128 poolTotalVotes = poolEpochPtr.totalVotes;

            // Calculate user's rewards for the pool [all in 1e18 precision]
            uint128 userRewards = uint128((uint256(userVotes) * poolRewards) / poolTotalVotes);
            if(userRewards == 0) continue;
            
            // Storage: set user's totalRewards for this pool
            userPoolAccountPtr.totalRewards = userRewards;

            // Update counter
            userTotalRewards += userRewards;
        }

        require(userTotalRewards > 0, Errors.NoRewardsToClaim());
        
        // Increment user's total rewards for this epoch
        usersEpochData[epoch][msg.sender].totalRewards += userTotalRewards;

        // Increment epoch & global total claimed
        epochPtr.totalRewardsClaimed += userTotalRewards;
        TOTAL_REWARDS_CLAIMED += userTotalRewards;

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, userTotalRewards);

        // transfer esMoca to user
        ESMOCA.safeTransfer(msg.sender, userTotalRewards);
    }

    /**
     * @notice Claims net rewards earned via delegation of votes, across multiple delegates, for a given epoch.
     * @dev Processes rewards in batches by delegates and their respective pools. 
     *      Net rewards are aggregated and transferred to the user at the end.
     *      The function should be called with poolIds selected to maximize net rewards per claim.
     * @param epoch The epoch for which rewards are being claimed.
     * @param delegateList Array of delegate addresses from whom the user is claiming rewards.
     * @param poolIds Array of poolId arrays, each corresponding to the pools voted by a specific delegate.
     */
    function claimRewardsFromDelegates(uint128 epoch, address[] calldata delegateList, uint128[][] calldata poolIds) external whenNotPaused {
        // input validation
        uint256 numOfDelegates = delegateList.length;
        require(numOfDelegates > 0, Errors.InvalidArray());
        require(numOfDelegates == poolIds.length, Errors.MismatchedArrayLengths());

        // cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // check: epoch is finalized
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        
        // check: rewards have not been withdrawn for this epoch
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());

        
        uint128 totalClaimable;
        
        for (uint256 i; i < numOfDelegates; ++i) {

            address delegate = delegateList[i];
            require(delegate != address(0), Errors.InvalidAddress());

            // Skip delegates who did not vote in this epoch
            if (delegateEpochData[epoch][delegate].totalVotesSpent == 0) continue;

            uint128[] calldata poolIdsForDelegate = poolIds[i];
            if (poolIdsForDelegate.length == 0) continue;
            
            totalClaimable += _claimRewardsInternal(
                epoch, 
                msg.sender,           // delegator = caller
                delegate, 
                poolIdsForDelegate, 
                true                  // isUserClaiming = true
            );
        }
        
        require(totalClaimable > 0, Errors.NoRewardsToClaim());
        
        // Update epoch-level tracking (for withdrawUnclaimedRewards)
        epochPtr.totalRewardsClaimed += totalClaimable;
        TOTAL_REWARDS_CLAIMED += totalClaimable;
        
        emit Events.RewardsClaimedFromDelegates(epoch, msg.sender, delegateList, poolIds, totalClaimable);
        
        ESMOCA.safeTransfer(msg.sender, totalClaimable);
    }

    /**
     * @notice Allows a delegate to claim fees earned from multiple delegators for a specified epoch and pools.
     * @param epoch Epoch for which fees are being claimed.
     * @param delegators List of delegators to claim fees from.
     * @param poolIds Arrays of pool IDs for each delegator.
     */
    function delegateClaimFees(uint128 epoch, address[] calldata delegators, uint128[][] calldata poolIds) external whenNotPaused {
        // input validation
        uint256 numOfDelegators = delegators.length;
        require(numOfDelegators > 0, Errors.InvalidArray());
        require(numOfDelegators == poolIds.length, Errors.MismatchedArrayLengths());

        // cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // check: epoch is finalized
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());

        // check: rewards have not been withdrawn for this epoch
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());
        
        // delegate must have voted in this epoch to claim fees
        require(delegateEpochData[epoch][msg.sender].totalVotesSpent > 0, Errors.NoFeesToClaim());

        
        uint128 totalClaimable;
        
        for (uint256 i; i < numOfDelegators; ++i) {
            
            address delegator = delegators[i];
            require(delegator != address(0), Errors.InvalidAddress());

            uint128[] calldata poolIdsForDelegator = poolIds[i];
            
            if (poolIdsForDelegator.length == 0) continue;
            
            totalClaimable += _claimRewardsInternal(
                epoch, 
                delegator, 
                msg.sender,           // delegate = caller
                poolIdsForDelegator, 
                false                 // isUserClaiming = false
            );
        }
        
        require(totalClaimable > 0, Errors.NoFeesToClaim());
        
        // Update epoch-level tracking
        epochPtr.totalRewardsClaimed += totalClaimable;
        TOTAL_REWARDS_CLAIMED += totalClaimable;
        
        emit Events.DelegateFeesClaimed(epoch, msg.sender, delegators, poolIds, totalClaimable);
        
        ESMOCA.safeTransfer(msg.sender, totalClaimable);
    }


//------------------------------- Verifier: claimSubsidies function ----------------------------------------------
    
    /**
     * @notice Claim subsidies for a verifier in the specified pools for a given epoch.
     * @dev Can only be called by the verifier's asset address (as set in PaymentsController). 
     *      Subsidies can be claimed once per pool per epoch per verifier.
     * @param epoch Target epoch to claim subsidies from.
     * @param verifier Verifier address to claim for.
     * @param poolIds List of pool IDs to claim subsidies from.
     */
    function claimSubsidies(uint128 epoch, address verifier, uint128[] calldata poolIds) external whenNotPaused {
        // Input validation
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());
        require(verifier != address(0), Errors.InvalidAddress());

        // Epoch must be finalized
        require(epochs[epoch].isEpochFinalized, Errors.EpochNotFinalized());

        // Subsidies must not have been withdrawn for this epoch
        require(!epochs[epoch].isSubsidiesWithdrawn, Errors.SubsidiesAlreadyWithdrawn());


        uint128 totalSubsidiesClaimed; 
        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            // pool must have subsidies allocated
            uint128 poolAllocatedSubsidies = epochPools[epoch][poolId].totalSubsidiesAllocated;
            require(poolAllocatedSubsidies > 0, Errors.NoSubsidiesForPool());

            // verifier must not have claimed subsidies for this pool
            require(verifierEpochPoolSubsidies[epoch][poolId][verifier] == 0, Errors.SubsidyAlreadyClaimed());

            // get verifier's accrued subsidies for {pool, epoch} & pool's accrued subsidies [AccruedSubsidies in 1e6 precision]
            // reverts if msg.sender is not the verifier's asset address
            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies)
                = PAYMENTS_CONTROLLER.getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifier, msg.sender);                

            // skip if poolAccruedSubsidies == 0 [also implies that verifierAccruedSubsidies == 0]
            if(poolAccruedSubsidies == 0) continue;
            
            // calculate ratio and rebase it to 18dp in single step [ratio is in 18dp precision]
            uint256 ratio = (verifierAccruedSubsidies * 1E18) / poolAccruedSubsidies; 

            // Safe downcast: ratio ∈ [0, 1e18] since verifierAccrued ≤ poolAccrued by definition.
            // therefore: (ratio * poolAllocatedSubsidies) / 1e18 ≤ poolAllocatedSubsidies (uint128)

            // Calculate esMoca subsidy receivable [poolAllocatedSubsidies in 1e18 precision]
            uint128 subsidyReceivable = uint128((ratio * poolAllocatedSubsidies) / 1E18); 
            if(subsidyReceivable == 0) continue;  

            // update counter
            totalSubsidiesClaimed += subsidyReceivable;

            // book verifier's subsidy receivable for the {pool, epoch}
            verifierEpochPoolSubsidies[epoch][poolId][verifier] = subsidyReceivable;
        }

        if(totalSubsidiesClaimed == 0) revert Errors.NoSubsidiesToClaim();

        // update verifier's epoch & global total claimed
        verifierSubsidies[verifier] += totalSubsidiesClaimed;
        verifierEpochSubsidies[epoch][verifier] += totalSubsidiesClaimed;

        // update global & epoch total claimed
        TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
        epochs[epoch].totalSubsidiesClaimed += totalSubsidiesClaimed;
        
        emit Events.SubsidiesClaimed(verifier, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier's asset address
        ESMOCA.safeTransfer(msg.sender, totalSubsidiesClaimed);      
    }


//------------------------------- VotingControllerAdmin: create/remove pools ----------------------------------------------------

    /**
     * @notice Creates multiple voting pools in a single transaction.
     * @dev Callable only by VotingController admin.
     *      Pool creation is blocked during active end-of-epoch operations.
     * @param count Number of pools to create (max 50 per call).
     */
    function createPools(uint128 count) external whenNotPaused onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(count > 0 && count <= 50, Errors.InvalidAmount());
        
        // Prevent pool creation during current epoch finalization
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(!epochs[currentEpoch].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // Ensure previous epoch is finalized
        require(epochs[currentEpoch - 1].isEpochFinalized, Errors.EpochNotFinalized());


        uint128 startPoolId = TOTAL_POOLS_CREATED + 1;
        uint128 endPoolId = TOTAL_POOLS_CREATED + count;
        
        // Batch update counters
        TOTAL_POOLS_CREATED = endPoolId;
        TOTAL_ACTIVE_POOLS += count;

        // Set pools as active
        
        for (uint128 i = startPoolId; i <= endPoolId; ++i) {
            pools[i].isActive = true;
        }

        emit Events.PoolsCreated(startPoolId, endPoolId, count);
    }


    /**
     * @notice Removes multiple voting pools in a single transaction.
     * @dev Callable only by VotingController admin.
     *      Pool removal is blocked during active end-of-epoch operations.
     * @param poolIds Array of pool IDs to remove (max 50 per call).
     */
    function removePools(uint128[] calldata poolIds) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());

        // Prevent pool removal during current epoch finalization
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(!epochs[currentEpoch].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // Ensure previous epoch is finalized
        require(epochs[currentEpoch - 1].isEpochFinalized, Errors.EpochNotFinalized());

        uint128 votesToRemove;

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            require(pools[poolId].isActive, Errors.PoolNotActive());

            // accumulate votes in removed pools for this epoch
            votesToRemove += epochPools[currentEpoch][poolId].totalVotes;

            // remove pool
            delete pools[poolId].isActive;
        }

        // Batch update counter
        TOTAL_ACTIVE_POOLS -= uint128(numOfPools);

        // Reduce epoch totalVotes by votes in removed pools
        if (votesToRemove > 0) epochs[currentEpoch].totalVotes -= votesToRemove;

        emit Events.PoolsRemoved(poolIds, votesToRemove);
    }

//------------------------------- CronJob Role: depositEpochSubsidies, finalizeEpochRewardsSubsidies -----------------------------------------
    

    /**
     * @notice Deposit esMOCA subsidies to be distributed for a specific epoch.
     * @dev Only callable by CRON_JOB_ROLE after the epoch ends and before it is finalized.
     *      Transfers esMOCA from the treasury if `subsidies` > 0 and the epoch has votes.
     *      Instantly finalizes the epoch if no active pools exist.
     *      Subsidies can be 0; set by protocol; discretionary.
     * @param epoch Epoch number to deposit subsidies for.
     * @param subsidies Total esMOCA subsidies to deposit (1e18 precision).
     */
    function depositEpochSubsidies(uint128 epoch, uint128 subsidies) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        // Previous epoch must be finalized
        require(epochs[epoch - 1].isEpochFinalized, Errors.PreviousEpochNotFinalized());

        // Epoch must have ended
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp > epochEndTimestamp, Errors.EpochNotEnded());

        // Current epoch must not be finalized
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        require(!epochPtr.isEpochFinalized, Errors.EpochFinalized());

        // Subsidies can only be set once per epoch
        require(!epochPtr.isSubsidiesSet, Errors.SubsidiesAlreadySet());

        // Set flag & log total active pools
        epochPtr.isSubsidiesSet = true;
        epochPtr.totalActivePools = TOTAL_ACTIVE_POOLS;

        emit Events.SubsidiesSet(epoch, subsidies);

        // If no active pools, epoch is fully processed [skip processEpochRewardsSubsidies() and finalizeEpoch()]
        // all flags set to true & events emitted
        if (TOTAL_ACTIVE_POOLS == 0) {
            epochPtr.isFullyProcessed = true;
            epochPtr.isEpochFinalized = true;
            emit Events.EpochFullyProcessed(epoch);
            emit Events.EpochFinalized(epoch);
            return;
        }
    
        // Deposit subsidies: if subsidies > 0 and epoch.totalVotes > 0
        if(subsidies > 0 && epochPtr.totalVotes > 0) {

            // get treasury address
            address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
            require(votingControllerTreasury != address(0), Errors.InvalidAddress());

            // update total subsidies deposited for epoch + global
            epochPtr.totalSubsidiesAllocated = subsidies;
            TOTAL_SUBSIDIES_DEPOSITED += subsidies;

            emit Events.SubsidiesDeposited(votingControllerTreasury, epoch, subsidies);

            ESMOCA.safeTransferFrom(votingControllerTreasury, address(this), subsidies);
        } 
    }


    /**
     * @notice Allocates rewards and subsidies for specified pools in an epoch.
     * @dev Can only be called by CRON_JOB_ROLE. Each pool can only be processed once per epoch.
     *      Inactive pools are skipped. Only pools with votes and rewards/subsidies > 0 can be allocated rewards/subsidies.
     * @param epoch The epoch to process.
     * @param poolIds List of pool IDs to process.
     * @param rewards Rewards (1e18 precision) allocated to each pool.
     * Requirements:
     *  - The specified epoch must have ended.
     *  - Epoch must not be finalized.
     *  - Subsidies must have already been set for the epoch.
     *  - Each pool must be active and not previously processed for the epoch.
     *  - Rewards can be 0; set by protocol; discretionary.
     */
    function processEpochRewardsSubsidies(uint128 epoch, uint128[] calldata poolIds, uint128[] calldata rewards) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
       
        // Input validation
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());
        require(numOfPools == rewards.length, Errors.MismatchedArrayLengths());

        // Epoch must have ended
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp > epochEndTimestamp, Errors.EpochNotEnded());

        // Cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // depositEpochSubsidies() must have been called prior
        require(epochPtr.isSubsidiesSet, Errors.SubsidiesNotSet());

        // check: epoch must not be finalized yet
        require(!epochPtr.isEpochFinalized, Errors.EpochFinalized());

        // cache: both can be 0: so do not check for >0
        uint128 epochTotalSubsidiesAllocated = epochPtr.totalSubsidiesAllocated;    
        uint128 epochTotalVotes = epochPtr.totalVotes;

        uint128 totalRewards;

        // iterate through all active pools for the epoch: to mark pools as processed
        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            uint128 poolRewards = rewards[i];       // can be 0

            // cache: pool & epoch pool pointers
            DataTypes.Pool storage poolPtr = pools[poolId];
            DataTypes.PoolEpoch storage epochPoolPtr = epochPools[epoch][poolId];

            // sanity check: pool is active & not processed 
            require(poolPtr.isActive, Errors.PoolNotActive());
            require(!epochPoolPtr.isProcessed, Errors.PoolAlreadyProcessed());

            // get pool's total votes for the epoch
            uint128 poolVotes = epochPoolPtr.totalVotes;
            bool hasVotes = poolVotes > 0;  

            // if pool has votes: calc. subsidies & update rewards allocated
            if(hasVotes) {
                
                // poolSubsidies = 0, if epochTotalSubsidiesAllocated = 0
                uint128 poolSubsidies = uint128((uint256(poolVotes) * epochTotalSubsidiesAllocated) / epochTotalVotes);
                
                // update pool & epochpool: totalSubsidiesAllocated
                if(poolSubsidies > 0) { 
                    // storage updates
                    poolPtr.totalSubsidiesAllocated += poolSubsidies;
                    epochPoolPtr.totalSubsidiesAllocated = poolSubsidies;                    
                }

                // update pool & epochpool: totalRewardsAllocated
                if(poolRewards > 0) {
                    // storage updates
                    poolPtr.totalRewardsAllocated += poolRewards;
                    epochPoolPtr.totalRewardsAllocated = poolRewards;
                    
                    // increment counter
                    totalRewards += poolRewards;
                }
            }

            // mark pool as processed
            epochPoolPtr.isProcessed = true;
        }

        // STORAGE: update epoch global rewards 
        epochPtr.totalRewardsAllocated += totalRewards;

        // check if epoch will be fully processed
        uint128 totalPoolsProcessed = epochPtr.poolsProcessed += uint128(numOfPools);
        bool isFullyProcessed = totalPoolsProcessed == epochPtr.totalActivePools;

        if(isFullyProcessed) {
            // set flag & emit events
            epochPtr.isFullyProcessed = true;
            emit Events.PoolsProcessed(epoch, poolIds);
            emit Events.EpochFullyProcessed(epoch);

        } else{           
            emit Events.PoolsProcessed(epoch, poolIds);
        }
    }

    
    function finalizeEpoch(uint128 epoch) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        // cache: epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        
        // epoch must be fully processed
        require(epochPtr.isFullyProcessed, Errors.EpochNotProcessed());
        
        // epoch must not be finalized
        require(!epochPtr.isEpochFinalized, Errors.EpochFinalized());

        // cache: total rewards
        uint128 totalRewards = epochPtr.totalRewardsAllocated;
        emit Events.RewardsSetForEpoch(epoch, totalRewards);

        // transfer rewards from treasury to contract
        if(totalRewards > 0){

            // get treasury address
            address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
            require(votingControllerTreasury != address(0), Errors.InvalidAddress());

            TOTAL_REWARDS_DEPOSITED += totalRewards;         
            emit Events.RewardsDeposited(votingControllerTreasury, epoch, totalRewards);

            ESMOCA.safeTransferFrom(votingControllerTreasury, address(this), totalRewards);
        }

        // set flag: epoch finalized
        epochPtr.isEpochFinalized = true;
        emit Events.EpochFinalized(epoch); 
    }

    // force finalize an epoch in case of any unexpected conditions
    function forceFinalizeEpoch(uint128 epoch) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {

        epochs[epoch].isSubsidiesSet = true;
        epochs[epoch].isFullyProcessed = true;
        epochs[epoch].isEpochFinalized = true;
        emit Events.EpochFinalized(epoch); 
    }

//------------------------------- AssetManager Role: withdrawUnclaimedRewards, withdrawUnclaimedSubsidies -----------------------------------------
    
    /**
     * @notice Transfers all unclaimed and residual rewards for an epoch to the treasury.
     * @dev Only callable by Asset Manager after UNCLAIMED_DELAY_EPOCHS. 
     *      Requires the epoch to be finalized, rewards not yet withdrawn, treasury address set, and unclaimed rewards present.
     * @param epoch Epoch number to withdraw unclaimed rewards from.
     */
    function withdrawUnclaimedRewards(uint128 epoch) external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // Withdraw delay must have passed
        require(EpochMath.getCurrentEpochNumber() > epoch + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // Cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // Epoch must be finalized & rewards must not have been withdrawn yet
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());  

        // Unclaimed rewards must be greater than 0
        uint128 unclaimedRewards = epochPtr.totalRewardsAllocated - epochPtr.totalRewardsClaimed;
        require(unclaimedRewards > 0, Errors.NoUnclaimedRewardsToWithdraw());

        // Book unclaimed rewards
        epochPtr.totalRewardsUnclaimed = unclaimedRewards;
        
        // Set flag to block future claims
        epochPtr.isRewardsWithdrawn = true;

        // Get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        emit Events.UnclaimedRewardsWithdrawn(votingControllerTreasury, epoch, unclaimedRewards);

        ESMOCA.safeTransfer(votingControllerTreasury, unclaimedRewards);
    }

    /**
     * @notice Transfers all unclaimed subsidies for an epoch to the treasury after the required delay.
     * @dev Only callable by Asset Manager after UNCLAIMED_DELAY_EPOCHS. 
     *      Requires the epoch to be finalized, subsidies not yet withdrawn, and nonzero unclaimed subsidies.
     * @param epoch Epoch to withdraw unclaimed subsidies from.
     */
    function withdrawUnclaimedSubsidies(uint128 epoch) external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // Withdraw delay must have passed
        require(EpochMath.getCurrentEpochNumber() > epoch + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // Cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // Epoch must be finalized & subsidies must not have been withdrawn yet
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.isSubsidiesWithdrawn, Errors.SubsidiesAlreadyWithdrawn());

        // Unclaimed subsidies must be greater than 0
        uint128 unclaimedSubsidies = epochPtr.totalSubsidiesAllocated - epochPtr.totalSubsidiesClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // Book unclaimed subsidies
        epochPtr.totalSubsidiesUnclaimed = unclaimedSubsidies;
        
        // Set flag to block future claims
        epochPtr.isSubsidiesWithdrawn = true;

        // Get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        emit Events.UnclaimedSubsidiesWithdrawn(votingControllerTreasury, epoch, unclaimedSubsidies);

        ESMOCA.safeTransfer(votingControllerTreasury, unclaimedSubsidies);
    }

    // note: treasury address should be able to handle both wMoca and Moca
    /**
     * @notice Transfers all unclaimed registration fees to the treasury.
     * @dev Only callable by Asset Manager. Reverts if treasury address is unset or no unclaimed fees.
     */
    function withdrawRegistrationFees() external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // Unclaimed registration fees must be greater than 0
        uint128 unclaimedRegistrationFees = TOTAL_REGISTRATION_FEES_COLLECTED - TOTAL_REGISTRATION_FEES_CLAIMED;
        require(unclaimedRegistrationFees > 0, Errors.NoRegistrationFeesToWithdraw());

        // Book unclaimed registration fees
        TOTAL_REGISTRATION_FEES_CLAIMED = TOTAL_REGISTRATION_FEES_COLLECTED;

        // Get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        emit Events.RegistrationFeesWithdrawn(votingControllerTreasury, unclaimedRegistrationFees);

        // Transfer Moca to user [wraps if transfer fails within gas limit] 
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, votingControllerTreasury, unclaimedRegistrationFees, MOCA_TRANSFER_GAS_LIMIT);
    }
    
//------------------------------- VotingControllerAdmin: setters ---------------------------------------------------------

    /**
     * @notice Sets the esMoca address.
     * @dev Only callable by VotingController admin.
     * @param newEsMoca The new esMoca address.
     */
    function setEsMoca(address newEsMoca) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(newEsMoca != address(0), Errors.InvalidAddress());
        require(address(ESMOCA) != newEsMoca, Errors.InvalidAddress());

        address oldEsMoca = address(ESMOCA);
        ESMOCA = IERC20(newEsMoca);

        emit Events.EsMocaUpdated(oldEsMoca, newEsMoca);
    }

    function setPaymentController(address newPaymentController) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(newPaymentController != address(0), Errors.InvalidAddress());
        require(address(PAYMENTS_CONTROLLER) != newPaymentController, Errors.InvalidAddress());

        address oldPaymentController = address(PAYMENTS_CONTROLLER);
        PAYMENTS_CONTROLLER = IPaymentsController(newPaymentController);

        emit Events.PaymentControllerUpdated(oldPaymentController, newPaymentController);
    }

    function setVotingControllerTreasury(address newVotingControllerTreasury) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(newVotingControllerTreasury != address(0), Errors.InvalidAddress());
        require(VOTING_CONTROLLER_TREASURY != newVotingControllerTreasury, Errors.InvalidAddress());

        address oldVotingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        VOTING_CONTROLLER_TREASURY = newVotingControllerTreasury;

        emit Events.VotingControllerTreasuryUpdated(oldVotingControllerTreasury, newVotingControllerTreasury);
    }


    // 0 allowed
    function setDelegateRegistrationFee(uint128 newRegistrationFee) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        DELEGATE_REGISTRATION_FEE = newRegistrationFee;
        emit Events.DelegateRegistrationFeeUpdated(newRegistrationFee);
    }

    /**
     * @notice Sets the maximum delegate fee percentage.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and less than PRECISION_BASE.
     * @param maxFeePct The new maximum delegate fee percentage (2 decimal precision, e.g., 100 = 1%).
     */
    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(maxFeePct > 0, Errors.InvalidFeePct());
        require(maxFeePct < Constants.PRECISION_BASE, Errors.InvalidFeePct());

        MAX_DELEGATE_FEE_PCT = maxFeePct;

        emit Events.MaxDelegateFeePctUpdated(maxFeePct);
    }

    /**
     * @notice Sets the fee increase delay epochs.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and a multiple of EpochMath.EPOCH_DURATION.
     * @param delayEpochs The number of epochs for the fee increase delay.
     */
    function setFeeIncreaseDelayEpochs(uint128 delayEpochs) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(delayEpochs > 0, Errors.InvalidDelayPeriod());
       
        FEE_INCREASE_DELAY_EPOCHS = delayEpochs;
        emit Events.FeeIncreaseDelayEpochsUpdated(delayEpochs);
    }


    /**
     * @notice Sets the unclaimed delay epochs.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and a multiple of EpochMath.EPOCH_DURATION.
     * @param newDelayEpoch The new unclaimed delay epochs.
     * This delay applied to both withdrawUnclaimedRewards and withdrawUnclaimedSubsidies
     */
    function setUnclaimedDelay(uint128 newDelayEpoch) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(newDelayEpoch > 0, Errors.InvalidDelayPeriod());

        // cache old + update to new unclaimed delay
        uint128 oldUnclaimedDelay = UNCLAIMED_DELAY_EPOCHS;
        UNCLAIMED_DELAY_EPOCHS = newDelayEpoch;


        emit Events.UnclaimedDelayUpdated(oldUnclaimedDelay, newDelayEpoch);
    }

    /**
     * @notice Sets the gas limit for moca transfer.
     * @dev Only callable by the IssuerStakingController admin.
     * @param newMocaTransferGasLimit The new gas limit for moca transfer.
     */
    function setMocaTransferGasLimit(uint128 newMocaTransferGasLimit) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint128 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }

//------------------------------- Internal functions ------------------------------------------------------

    /**
     * @notice Validates delegate registration and ensures historical fee is recorded for the epoch
     * @dev Called when a delegate performs voting actions (vote, migrateVotes)
     *      - Reverts if caller is not a registered delegate
     *      - Applies any pending fee increase if the scheduled epoch has arrived
     *      - Records fee for the epoch if not already set
     * @param currentEpoch The current epoch number
     */
    function _validateDelegateAndRecordFee(uint128 currentEpoch) internal {
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];
        
        // sanity check: delegate must be registered
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        // fee check: if not set for this epoch, determine and record the fee
        if (delegateHistoricalFeePcts[msg.sender][currentEpoch] == 0) {
            
            // check if there's a pending fee increase to apply
            if (delegatePtr.nextFeePctEpoch > 0 && currentEpoch >= delegatePtr.nextFeePctEpoch) {
               
                uint128 oldFeePct = delegatePtr.currentFeePct;

                // update current fee percentage
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;               
                
                // reset pending fields
                delete delegatePtr.nextFeePct;
                delete delegatePtr.nextFeePctEpoch;

                emit Events.DelegateFeeApplied(msg.sender, oldFeePct, delegatePtr.currentFeePct, currentEpoch);
            }
            
            // record current fee for this epoch (whether just updated or existing)
            delegateHistoricalFeePcts[msg.sender][currentEpoch] = delegatePtr.currentFeePct;
        }
    }


    /**
     * @notice Internal function to process pools and claim rewards
     * @dev Processing phase: calculates and stores rewards for unprocessed pools
     *      Claiming phase: transfers delta between total and already-claimed
     *      Delegate's pool rewards are calculated once and cached for reuse by all delegators.
     * @param epoch The epoch to claim from
     * @param user The user who delegated
     * @param delegate The delegate who voted
     * @param poolIds Array of pool IDs to process
     * @param isUserClaiming True if user claiming NET, false if delegate claiming FEES
     * @return totalClaimable Amount to transfer to caller
     */
    function _claimRewardsInternal(uint128 epoch, address user, address delegate, uint128[] calldata poolIds, bool isUserClaiming) internal returns (uint128) {
        
        // ExtCall: user's delegated voting power & delegate's total voting power
        uint128 userDelegatedVP = VEMOCA.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, epoch);
        uint128 delegateTotalVP = VEMOCA.balanceAtEpochEnd(delegate, epoch, true);
        if (delegateTotalVP == 0) return 0;  // early return if delegate has no voting power [implicitly userDelegatedVP = 0]

        // get delegate fee percentage [0: if delegate did not vote this epoch, or has 0 feePct]
        uint128 delegateFeePct = delegateHistoricalFeePcts[delegate][epoch];
        
        // cache user-delegate pair accounting pointer
        DataTypes.UserDelegateAccount storage pairAccountPtr = userDelegateAccounting[epoch][user][delegate];  
        
        // Track newly processed amounts in this call
        uint128 newGrossProcessed;
        uint128 newFeesProcessed;
        
       // ═══════════════════════════════════════════════════════════════════
       // PROCESSING PHASE: Calculate rewards for unprocessed pools
       // ═══════════════════════════════════════════════════════════════════
        uint256 numOfPools = poolIds.length; // confirmed to be non-zero in top-level function

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            
            // Skip if pool already processed for this user-delegate pair
            if (pairAccountPtr.poolProcessed[poolId]) continue;
            
            // Mark pool as processed (prevents re-processing if gross = 0)
            pairAccountPtr.poolProcessed[poolId] = true;
            
            // Pool must have rewards & votes; else skip
            uint128 totalPoolRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            uint128 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            if (totalPoolVotes == 0) continue;  // [implicitly totalPoolRewards: 0; rewards not allocated to pools w/ 0 votes]
            
            // Cache delegate's pool account pointer
            DataTypes.Account storage delegatePoolAccountPtr = delegatesEpochPoolData[epoch][poolId][delegate];

            // Skip: if delegate has not voted in this pool
            uint128 delegatePoolVotes = delegatePoolAccountPtr.totalVotesSpent;
            if (delegatePoolVotes == 0) continue;

            // Get or calculate delegate's share of pool rewards 
            uint128 delegatePoolRewards = delegatePoolAccountPtr.totalRewards;
            // if not previously calculated, compute
            if (delegatePoolRewards == 0) {
                
                delegatePoolRewards = uint128((uint256(delegatePoolVotes) * totalPoolRewards) / totalPoolVotes);
                if (delegatePoolRewards == 0) continue;
                
                // store: delegate's rewards for this {pool, epoch} - done once, reused by subsequent callers
                delegatePoolAccountPtr.totalRewards = delegatePoolRewards;
            }
           
            // calc. user's gross rewards for the pool
            uint128 userGrossRewardsForPool = uint128((uint256(userDelegatedVP) * delegatePoolRewards) / delegateTotalVP);
            if (userGrossRewardsForPool == 0) continue;
            
            // book user's gross rewards for this {pool, epoch}
            pairAccountPtr.userPoolGrossRewards[poolId] = userGrossRewardsForPool;
            
            // calc. delegate's fee for this pool [could be 0 if delegate did not vote this epoch]
            uint128 delegateFeeForPool = uint128((uint256(userGrossRewardsForPool) * delegateFeePct) / Constants.PRECISION_BASE);
            
            // update counters
            newGrossProcessed += userGrossRewardsForPool;
            newFeesProcessed += delegateFeeForPool;
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // UPDATE AGGREGATE TOTALS (for newly processed pools only)
        // ═══════════════════════════════════════════════════════════════════
        if (newGrossProcessed > 0) {
            // update user-delegate account aggregates
            pairAccountPtr.totalGrossRewards += newGrossProcessed;
            pairAccountPtr.totalDelegateFees += newFeesProcessed;
            pairAccountPtr.totalNetRewards += (newGrossProcessed - newFeesProcessed);
            
            // update delegate global stats
            delegates[delegate].totalFeesAccrued += newFeesProcessed;
            delegates[delegate].totalRewardsCaptured += newGrossProcessed;
            delegateEpochData[epoch][delegate].totalRewards += newGrossProcessed;
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // CLAIMING PHASE: Transfer delta between total and already-claimed
        // ═══════════════════════════════════════════════════════════════════
        uint128 totalClaimable;

        if (isUserClaiming) {
            // calc. user's total net rewards - already claimed
            totalClaimable = pairAccountPtr.totalNetRewards - pairAccountPtr.userClaimed;
            if (totalClaimable > 0) pairAccountPtr.userClaimed = pairAccountPtr.totalNetRewards;
                
        } else {

            // calc. delegate's total fees - already claimed
            totalClaimable = pairAccountPtr.totalDelegateFees - pairAccountPtr.delegateClaimed;
            if (totalClaimable > 0) pairAccountPtr.delegateClaimed = pairAccountPtr.totalDelegateFees;
        }
        
        return totalClaimable;
    }

//------------------------------- Risk functions----------------------------------------------------------

    /**
     * @notice Pause the contract.
     * @dev Only callable by the Monitor [bot script].
     */
    function pause() external whenNotPaused onlyRole(Constants.MONITOR_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     */
    function unpause() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
     * @notice Freeze the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     *      This is a kill switch function
     */
    function freeze() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        require(isFrozen == 0, Errors.IsFrozen());
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
    function emergencyExit() external payable onlyRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE) {
        require(isFrozen == 1, Errors.NotFrozen());

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        // exfil esMoca [rewards + subsidies]
        ESMOCA.safeTransfer(votingControllerTreasury, ESMOCA.balanceOf(address(this)));


        // exfil moca [registration fees]
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, votingControllerTreasury, address(this).balance, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.EmergencyExit(votingControllerTreasury);
    }

//------------------------------- View functions ----------------------------------------------------------
    
    /**
     * @notice Returns the claimable personal rewards for a user across multiple pools.
     * @dev Returns 0 for pools already claimed or with no rewards.
     * @param epoch The epoch to query.
     * @param poolIds Array of pool IDs to check.
     * @param user The user address.
     * @return totalClaimable Total claimable rewards across all pools.
     * @return perPoolClaimable Array of claimable amounts per pool (same order as poolIds).
    */
    function viewClaimablePersonalRewards(uint128 epoch, address user, uint128[] calldata poolIds) external view returns (uint128, uint128[] memory) {
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());

        // counters
        uint128 totalClaimable;
        uint128[] memory perPoolClaimable = new uint128[](numOfPools);      

        // sanity check: epoch must be finalized and rewards not withdrawn
        if (!epochs[epoch].isEpochFinalized || epochs[epoch].isRewardsWithdrawn) return (0, perPoolClaimable);
       
        // calculate claimable rewards for each pool
        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            
            // Skip if already claimed
            if (usersEpochPoolData[epoch][poolId][user].totalRewards > 0) continue;
            
            uint128 poolRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            uint128 userVotes = usersEpochPoolData[epoch][poolId][user].totalVotesSpent;
            
            if (poolRewards == 0 || userVotes == 0) continue;
            
            uint128 poolTotalVotes = epochPools[epoch][poolId].totalVotes;
            uint128 userRewards = uint128((uint256(userVotes) * poolRewards) / poolTotalVotes);
            
            perPoolClaimable[i] = userRewards;
            totalClaimable += userRewards;
        }

        return (totalClaimable, perPoolClaimable);
    }

    /**
     * @notice Returns the claimable delegated rewards for a user from a specific delegate.
     * @dev Mirrors the calculation logic in _claimRewardsInternal.
     * @param epoch The epoch to query.
     * @param user The delegator address.
     * @param delegate The delegate address.
     * @param poolIds Array of pool IDs to check.
     * @return netClaimable Total net rewards claimable by user (after delegate fees).
     * @return feeClaimable Total fees claimable by delegate.
    */
    function viewClaimableDelegatedRewards(uint128 epoch, address user, address delegate, uint128[] calldata poolIds) external view returns (uint128, uint128) {
        
        // sanity check: epoch must be finalized and rewards not withdrawn
        if (!epochs[epoch].isEpochFinalized || epochs[epoch].isRewardsWithdrawn) return (0, 0);
        
        // sanity check: delegate must have voted in this epoch
        if (delegateEpochData[epoch][delegate].totalVotesSpent == 0) return (0, 0);
        
        // get delegate fee percentage [0: if delegate did not vote this epoch, or has 0 feePct]
        uint128 delegateFeePct = delegateHistoricalFeePcts[delegate][epoch];
        // get user-delegate pair accounting
        DataTypes.UserDelegateAccount storage pairAccount = userDelegateAccounting[epoch][user][delegate];
        
        // get delegate's total voting power
        uint128 delegateTotalVP = VEMOCA.balanceAtEpochEnd(delegate, epoch, true);
        if (delegateTotalVP == 0) return (0, 0);
        
        // get user's delegated voting power
        uint128 userDelegatedVP = VEMOCA.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, epoch);
        if (userDelegatedVP == 0) return (0, 0);
        
        uint128 newGross;
        uint128 newFees;
        
        for (uint256 i; i < poolIds.length; ++i) {
            uint128 poolId = poolIds[i];
            
            // Skip if already processed for this user-delegate pair
            if (pairAccount.poolProcessed[poolId]) continue;
            
            uint128 totalPoolRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            uint128 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            if (totalPoolRewards == 0 || totalPoolVotes == 0) continue;
            
            // Get or calculate delegate's pool rewards (use cached if available)
            DataTypes.Account storage delegatePoolAccountPtr = delegatesEpochPoolData[epoch][poolId][delegate];
            uint128 delegatePoolRewards = delegatePoolAccountPtr.totalRewards;
            
            if (delegatePoolRewards == 0) {
                // Not yet cached - calculate
                uint128 delegatePoolVotes = delegatePoolAccountPtr.totalVotesSpent;
                if (delegatePoolVotes == 0) continue;
                
                delegatePoolRewards = uint128((uint256(delegatePoolVotes) * totalPoolRewards) / totalPoolVotes);
                if (delegatePoolRewards == 0) continue;
            }
            
            uint128 userGross = uint128((uint256(userDelegatedVP) * delegatePoolRewards) / delegateTotalVP);
            if (userGross == 0) continue;
            
            uint128 delegateFee = uint128((uint256(userGross) * delegateFeePct) / Constants.PRECISION_BASE);
            
            newGross += userGross;
            newFees += delegateFee;
        }
        
        // Add already-processed but unclaimed amounts
        uint128 totalNet = pairAccount.totalNetRewards + (newGross - newFees);
        uint128 totalFees = pairAccount.totalDelegateFees + newFees;
        
        uint128 netClaimable = totalNet - pairAccount.userClaimed;
        uint128 feeClaimable = totalFees - pairAccount.delegateClaimed;

        return (netClaimable, feeClaimable);
    }

    /**
    * @notice Returns the claimable delegation fees for a delegate from multiple delegators.
    */
    function viewClaimableDelegationFees(uint128 epoch, address[] calldata delegators, uint128[][] calldata poolIds) external view returns (uint128 totalFeeClaimable, uint128[] memory perDelegatorFees) {
        uint256 numOfDelegators = delegators.length;
        require(numOfDelegators > 0, Errors.InvalidArray());
        require(numOfDelegators == poolIds.length, Errors.MismatchedArrayLengths());

        perDelegatorFees = new uint128[](numOfDelegators);

        // sanity check: epoch must be finalized and rewards not withdrawn
        if (!epochs[epoch].isEpochFinalized || epochs[epoch].isRewardsWithdrawn) {
            return (0, perDelegatorFees);
        }

        address delegate = msg.sender;

        // delegate must have voted in this epoch
        if (delegateEpochData[epoch][delegate].totalVotesSpent == 0) {
            return (0, perDelegatorFees);
        }

        // get delegate's fee percentage and total voting power
        uint128 delegateFeePct = delegateHistoricalFeePcts[delegate][epoch];
        uint128 delegateTotalVP = VEMOCA.balanceAtEpochEnd(delegate, epoch, true);

        if (delegateTotalVP == 0) return (0, perDelegatorFees);

        for (uint256 i; i < numOfDelegators; ++i) {
            uint128 claimable = _calcDelegatorFeeClaimable(
                epoch,
                delegators[i],
                delegate,
                poolIds[i],
                delegateFeePct,
                delegateTotalVP
            );
            
            perDelegatorFees[i] = claimable;
            totalFeeClaimable += claimable;
        }

        return (totalFeeClaimable, perDelegatorFees);
    }

    /**
    * @notice Calculates claimable fees for a single delegator-delegate pair
    * @dev Internal helper to reduce stack depth in viewClaimableDelegationFees
    */
    function _calcDelegatorFeeClaimable(
        uint128 epoch,
        address delegator,
        address delegate,
        uint128[] calldata poolIdsForDelegator,
        uint128 delegateFeePct,
        uint128 delegateTotalVP
    ) internal view returns (uint128) {
        if (delegator == address(0)) return 0;
        if (poolIdsForDelegator.length == 0) return 0;

        // get delegator's delegated VP to this delegate
        uint128 delegatorVP = VEMOCA.getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);
        if (delegatorVP == 0) return 0;

        // get user-delegate pair accounting
        DataTypes.UserDelegateAccount storage pairAccount = userDelegateAccounting[epoch][delegator][delegate];

        uint128 newFeesForDelegator;

        for (uint256 j; j < poolIdsForDelegator.length; ++j) {
            uint128 poolId = poolIdsForDelegator[j];

            // Skip if already processed for this user-delegate pair
            if (pairAccount.poolProcessed[poolId]) continue;

            uint128 totalPoolRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            uint128 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            if (totalPoolRewards == 0 || totalPoolVotes == 0) continue;

            // Get or calculate delegate's pool rewards
            uint128 delegatePoolRewards = _getDelegatePoolRewards(epoch, poolId, delegate, totalPoolRewards, totalPoolVotes);
            if (delegatePoolRewards == 0) continue;

            uint128 delegatorGross = uint128((uint256(delegatorVP) * delegatePoolRewards) / delegateTotalVP);
            if (delegatorGross == 0) continue;

            uint128 delegateFee = uint128((uint256(delegatorGross) * delegateFeePct) / Constants.PRECISION_BASE);
            newFeesForDelegator += delegateFee;
        }

        // Add already-processed but unclaimed fees
        uint128 totalFeesFromDelegator = pairAccount.totalDelegateFees + newFeesForDelegator;
        return totalFeesFromDelegator - pairAccount.delegateClaimed;
    }

    /**
    * @notice Gets delegate's rewards for a pool (cached or calculated)
    */
    function _getDelegatePoolRewards(
        uint128 epoch,
        uint128 poolId,
        address delegate,
        uint128 totalPoolRewards,
        uint128 totalPoolVotes
    ) internal view returns (uint128) {
        DataTypes.Account storage delegatePoolAccountPtr = delegatesEpochPoolData[epoch][poolId][delegate];
        uint128 delegatePoolRewards = delegatePoolAccountPtr.totalRewards;

        if (delegatePoolRewards == 0) {
            uint128 delegatePoolVotes = delegatePoolAccountPtr.totalVotesSpent;
            if (delegatePoolVotes == 0) return 0;

            delegatePoolRewards = uint128((uint256(delegatePoolVotes) * totalPoolRewards) / totalPoolVotes);
        }

        return delegatePoolRewards;
    }

    /**
     * @notice Returns the claimable subsidies for a verifier across multiple pools.
     * @dev Mirrors the calculation logic in claimSubsidies().
     * @param epoch The epoch to query.
     * @param poolIds Array of pool IDs to check.
     * @param verifier The verifier address.
     * @return totalClaimable Total claimable subsidies across all pools.
     * @return perPoolClaimable Array of claimable amounts per pool (same order as poolIds).
    */
    function viewClaimableSubsidies(uint128 epoch, uint128[] calldata poolIds, address verifier) external view returns (uint128 totalClaimable, uint128[] memory perPoolClaimable) {
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());

        perPoolClaimable = new uint128[](numOfPools);

        // sanity check: verifier address is valid
        if (verifier == address(0)) return (0, perPoolClaimable);

        // epoch must be finalized
        if (!epochs[epoch].isEpochFinalized) return (0, perPoolClaimable);

        // subsidies must not have been withdrawn for this epoch
        if (epochs[epoch].isSubsidiesWithdrawn) return (0, perPoolClaimable);

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            // pool must have subsidies allocated
            uint128 poolAllocatedSubsidies = epochPools[epoch][poolId].totalSubsidiesAllocated;
            if (poolAllocatedSubsidies == 0) continue;

            // verifier must not have already claimed subsidies for this pool
            if (verifierEpochPoolSubsidies[epoch][poolId][verifier] > 0) continue;

            // get verifier's accrued subsidies for {pool, epoch} & pool's accrued subsidies
            // Note: This is a view function, so we can't verify msg.sender is asset manager
            // We just show what WOULD be claimable if the correct caller invoked claimSubsidies
            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) = 
                _getVerifierAndPoolSubsidiesView(epoch, poolId, verifier);

            // skip if poolAccruedSubsidies == 0
            if (poolAccruedSubsidies == 0) continue;

            // calculate ratio and rebase it to 18dp in single step
            uint256 ratio = (verifierAccruedSubsidies * 1E18) / poolAccruedSubsidies;

            // Calculate esMoca subsidy receivable
            uint128 subsidyReceivable = uint128((ratio * poolAllocatedSubsidies) / 1E18);

            if (subsidyReceivable == 0) continue;

            perPoolClaimable[i] = subsidyReceivable;
            totalClaimable += subsidyReceivable;
        }

        return (totalClaimable, perPoolClaimable);
    }

    /**
     * @notice Internal view helper to get verifier and pool subsidies without caller validation.
     * @dev Used by viewClaimableSubsidies to avoid revert on caller check.
     * @param epoch The epoch number.
     * @param poolId The pool ID.
     * @param verifier The verifier address.
     * @return verifierAccruedSubsidies The verifier's accrued subsidies.
     * @return poolAccruedSubsidies The pool's total accrued subsidies.
    */
    function _getVerifierAndPoolSubsidiesView(uint128 epoch, uint128 poolId, address verifier) internal view returns (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) {
        // Direct call to PaymentsController's internal view data
        // Note: This bypasses the caller check in getVerifierAndPoolAccruedSubsidies
        verifierAccruedSubsidies = PAYMENTS_CONTROLLER.getEpochPoolVerifierSubsidies(epoch, poolId, verifier);
        poolAccruedSubsidies = PAYMENTS_CONTROLLER.getEpochPoolSubsidies(epoch, poolId);
    }
}
