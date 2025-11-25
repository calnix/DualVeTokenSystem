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


contract VotingController is Pausable, LowLevelWMoca, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    // Immutable Contracts
    IVotingEscrowMoca public immutable VEMOCA;
    IERC20 public immutable ESMOCA;
    address public immutable WMOCA;

    // mutable contracts
    IPaymentsController public PAYMENTS_CONTROLLER;

    
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
    
    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;


    // treasury address for voting controller
    address public VOTING_CONTROLLER_TREASURY;

    // risk management
    uint256 public isFrozen;

//-------------------------------Mappings-------------------------------------------------

    // epoch data
    mapping(uint128 epochNum => DataTypes.Epoch epoch) public epochs;    
    
    // pool data
    mapping(bytes32 poolId => DataTypes.Pool pool) public pools;
    mapping(uint128 epochNum => mapping(bytes32 poolId => DataTypes.PoolEpoch poolEpoch)) public epochPools;


    // user personal data: perEpoch | perPoolPerEpoch
    mapping(uint128 epochNum => mapping(address userAddr => DataTypes.Account user)) public usersEpochData;
    mapping(uint128 epochNum => mapping(bytes32 poolId => mapping(address user => DataTypes.Account userAccount))) public usersEpochPoolData;
    
    // delegate aggregated data: perEpoch | perPoolPerEpoch [mirror of userEpochData & userEpochPoolData]
    mapping(uint128 epochNum => mapping(address delegateAddr => DataTypes.Account delegate)) public delegateEpochData;
    mapping(uint128 epochNum => mapping(bytes32 poolId => mapping(address delegate => DataTypes.Account delegateAccount))) public delegatesEpochPoolData;

    // User-Delegate tracking [for this user-delegate pair, what was the user's {rewards,claimed}]
    mapping(uint128 epochNum => mapping(address user => mapping(address delegate => DataTypes.OmnibusDelegateAccount userDelegateAccount))) public userDelegateAccounting;


    // Delegate registration data + fee data
    mapping(address delegateAddr => DataTypes.Delegate delegate) public delegates;     
    // if 0: fee not set for that epoch      
    mapping(address delegate => mapping(uint128 epoch => uint128 currentFeePct)) public delegateHistoricalFeePcts;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

    // REVIEW: only verifierEpochPoolData is mandatory. optional: drop verifierData & verifierEpochData, if we want to streamline storage. 
    // are there creative ways to have the optional mappings without the extra storage writes?
    mapping(address verifier => uint256 totalSubsidies) public verifierData;                  
    mapping(uint128 epoch => mapping(address verifier => uint256 totalSubsidies)) public verifierEpochData;
    mapping(uint128 epoch => mapping(bytes32 poolId => mapping(address verifier => uint256 totalSubsidies))) public verifierEpochPoolData;
    

//-------------------------------Constructor------------------------------------------

    constructor(
        uint256 maxDelegateFeePct, uint256 delayDuration, address wMoca_, uint256 mocaTransferGasLimit, 
        address votingEscrowMoca_, address escrowedMoca_, address votingControllerTreasury_, address paymentsController_,
        address globalAdmin, address votingControllerAdmin, address monitorAdmin, address cronJobAdmin,
        address monitorBot, address emergencyExitHandler
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
        
        // initial unclaimed delay & fee increase delay
        require(delayDuration > 0, Errors.InvalidDelayPeriod());
        require(delayDuration % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayPeriod());
        UNCLAIMED_DELAY_EPOCHS = FEE_INCREASE_DELAY_EPOCHS = delayDuration;

        // set max delegate fee percentage
        require(maxDelegateFeePct > 0 && maxDelegateFeePct <= Constants.PRECISION_BASE, Errors.InvalidFeePct());
        MAX_DELEGATE_FEE_PCT = maxDelegateFeePct;

        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;

        // roles
        _setupRoles(globalAdmin, votingControllerAdmin, monitorAdmin, cronJobAdmin, monitorBot, emergencyExitHandler);
    }

    function _setupRoles(
        address globalAdmin, address votingControllerAdmin, address monitorAdmin, address cronJobAdmin,
        address monitorBot, address emergencyExitHandler
    ) internal {
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(votingControllerAdmin != address(0), Errors.InvalidAddress());
        require(monitorAdmin != address(0), Errors.InvalidAddress());
        require(cronJobAdmin != address(0), Errors.InvalidAddress());
        require(monitorBot != address(0), Errors.InvalidAddress());
        require(emergencyExitHandler != address(0), Errors.InvalidAddress());

        // grant roles to addresses
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);    
        _grantRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE, votingControllerAdmin);
        _grantRole(Constants.MONITOR_ADMIN_ROLE, monitorAdmin);
        _grantRole(Constants.CRON_JOB_ADMIN_ROLE, cronJobAdmin);
        _grantRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler);

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

        // get current epoch & cache epoch pointer
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // epoch should not be finalized
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        ( mapping(uint128 => mapping(address => DataTypes.Account)) storage accountEpochData,
          mapping(uint128 => mapping(bytes32 => mapping(address => DataTypes.Account))) storage accountEpochPoolData 
        ) 
        = isDelegated ? (delegateEpochData, delegatesEpochPoolData) : (usersEpochData, usersEpochPoolData);

        // if caller is voting as a delegate: registration + fee check
        if (isDelegated) {
            // sanity check: delegate must be registered [msg.sender is delegate]
            require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());

            // fee check: if not set, check pending; else log current fee
            if(delegateHistoricalFeePcts[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                
                // if pending fee not applied, set to current fee
                if(!pendingFeeApplied) {
                    delegateHistoricalFeePcts[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
                }
            }
        }

        // votingPower: benchmarked to end of epoch [forward-decay]
        // get account's voting power[personal, delegated] and used votes
        uint256 totalVotes = VEMOCA.balanceAtEpochEnd(msg.sender, currentEpoch, isDelegated);
        uint256 spentVotes = accountEpochData[currentEpoch][msg.sender].totalVotesSpent; // spentVotes is natively uint128, although expressed as uint256 here for ease of arithmetic

        // check if account has available votes 
        uint256 availableVotes = totalVotes - spentVotes;
        require(availableVotes > 0, Errors.NoAvailableVotes());

        // update votes at a pool+epoch level | account:{personal,delegate}
        // does not check for duplicate poolIds in the array; users can vote repeatedly for the same pool
        uint128 totalNewVotes;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 votes = poolVotes[i];

            // sanity check: do not skip on 0 vote, as it indicates incorrect array inputs
            require(votes > 0, Errors.ZeroVotes()); 
            
            // cache pool pointer
            DataTypes.Pool storage poolPtr = pools[poolId];

            // sanity checks: pool exists, is active
            require(poolPtr.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!poolPtr.isRemoved, Errors.PoolRemoved());
            
            // sanity check: available votes should not be exceeded
            totalNewVotes += votes;
            require(totalNewVotes <= availableVotes, Errors.InsufficientVotes());

            // increment votes at a pool+epoch level | account:{personal,delegate}
            accountEpochPoolData[currentEpoch][poolId][msg.sender].totalVotesSpent += votes;
            epochPools[currentEpoch][poolId].totalVotes += votes;

            //increment pool votes at a global level
            poolPtr.totalVotes += votes;       
        }

        // increment epoch totalVotes | account:{personal,delegate}
        epochPtr.totalVotes += totalNewVotes;
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

        // get current epoch & cache epoch pointer
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // epoch should not be finalized
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint128 => mapping(bytes32 => mapping(address => DataTypes.Account))) storage accountEpochPoolData  
        = isDelegated ? delegatesEpochPoolData : usersEpochPoolData;

        // if caller is voting as a delegate: registration + fee check
        if (isDelegated) {
            // sanity check: delegate must be registered [msg.sender is delegate]
            require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());

            // fee check: if not set, check pending; else log current fee
            if(delegateHistoricalFeePcts[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                
                // if pending fee not applied, set to current fee
                if(!pendingFeeApplied) {
                    delegateHistoricalFeePcts[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
                }
            }
        }

        // can migrate votes from inactive pool to active pool; but not vice versa
        for(uint256 i; i < length; ++i) {
            // cache: calldata access per array element
            bytes32 srcPoolId = srcPoolIds[i];
            bytes32 dstPoolId = dstPoolIds[i];
            uint128 votesToMigrate = poolVotes[i];

            // sanity check: do not skip on 0 vote, as it indicates incorrect array inputs
            require(votesToMigrate > 0, Errors.ZeroVotes());
            require(srcPoolId != dstPoolId, Errors.InvalidPoolPair());

            // Cache storage pointers
            DataTypes.Pool storage srcPoolPtr = pools[srcPoolId];
            DataTypes.Pool storage dstPoolPtr = pools[dstPoolId];
            DataTypes.PoolEpoch storage srcEpochPoolPtr = epochPools[currentEpoch][srcPoolId];
            DataTypes.PoolEpoch storage dstEpochPoolPtr = epochPools[currentEpoch][dstPoolId];

            // sanity check: both pools exist + dstPool is active + not removed [src pool can be removed]
            require(srcPoolPtr.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(dstPoolPtr.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!dstPoolPtr.isRemoved, Errors.PoolRemoved());

            // get user's existing votes in srcPool | must be greater than or equal to votesToMigrate
            uint128 votesInSrcPool = accountEpochPoolData[currentEpoch][srcPoolId][msg.sender].totalVotesSpent;
            require(votesInSrcPool >= votesToMigrate, Errors.InsufficientVotes());

            // deduct from old pool
            accountEpochPoolData[currentEpoch][srcPoolId][msg.sender].totalVotesSpent -= votesToMigrate;
            srcEpochPoolPtr.totalVotes -= votesToMigrate;
            srcPoolPtr.totalVotes -= votesToMigrate;

            // add to new pool
            accountEpochPoolData[currentEpoch][dstPoolId][msg.sender].totalVotesSpent += votesToMigrate;
            dstEpochPoolPtr.totalVotes += votesToMigrate;
            dstPoolPtr.totalVotes += votesToMigrate;

            // no need to update mappings: accountEpochData and epochs.totalVotes; as its a migration of votes within the same epoch.
        }

        emit Events.VotesMigrated(currentEpoch, msg.sender, srcPoolIds, dstPoolIds, poolVotes, isDelegated);
    }

//-------------------------------delegate functions------------------------------------------
    
    /**
     * @notice Registers the caller as a delegate and activates their status.
     * @dev Requires payment of the registration fee in Native Moca. 
     *      Calls VotingEscrowMoca.registerAsDelegate() to mark the delegate as active.
     * @param feePct The fee percentage to be applied to the delegate's rewards.
     */
    function registerAsDelegate(uint128 feePct) external payable whenNotPaused {
        // sanity check: fee percentage must be less than or equal to the maximum allowed fee
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidPercentage());

        // sanity check: delegate must not be registered
        DataTypes.Delegate storage delegate = delegates[msg.sender];
        require(!delegate.isRegistered, Errors.DelegateAlreadyRegistered());
        
        // register on VotingEscrowMoca | if delegate is already registered on VotingEscrowMoca -> reverts
        VEMOCA.registerAsDelegate(msg.sender);

        // storage: register delegate + set fee percentage
        delegate.isRegistered = true;
        delegate.currentFeePct = feePct;
        delegateHistoricalFeePcts[msg.sender][EpochMath.getCurrentEpochNumber()] = feePct;

        emit Events.DelegateRegistered(msg.sender, feePct);
    }

    /**
     * @notice Called by delegate to update their fee percentage.
     * @dev If the fee is increased, the new fee takes effect from currentEpoch + FEE_INCREASE_DELAY_EPOCHS to prevent last-minute increases.
     *      If the fee is decreased, the new fee takes effect immediately.
     * @param feePct The new fee percentage to be applied to the delegate's rewards.
     */
    function updateDelegateFee(uint128 feePct) external whenNotPaused {
        // sanity check: fee percentage must be less than or equal to the maximum allowed fee
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());   

        DataTypes.Delegate storage delegate = delegates[msg.sender];
        // sanity check: delegate must be registered
        require(delegate.isRegistered, Errors.DelegateNotRegistered());

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();

        // if there is an incoming pending fee increase, apply it before updating the fee
        _applyPendingFeeIfNeeded(msg.sender, currentEpoch);   

        uint128 currentFeePct = delegate.currentFeePct;

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
     */
    function unregisterAsDelegate() external whenNotPaused {
        DataTypes.Delegate storage delegate = delegates[msg.sender];
        
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();

        // sanity check: delegate must not have active votes
        require(delegateEpochData[currentEpoch][msg.sender].totalVotesSpent == 0, Errors.CannotUnregisterWithActiveVotes());
        // sanity check: delegate must be registered
        require(delegate.isRegistered, Errors.DelegateNotRegistered());
        
        // storage: unregister delegate
        delete delegate.isRegistered;
        
        // to mark as false
        VEMOCA.unregisterAsDelegate(msg.sender);

        // event
        emit Events.DelegateUnregistered(msg.sender);
    }

//-------------------------------claim rewards & fees functions----------------------------------------------


    /**
     * @notice Called by voter to claim esMoca rewards for specified pools in a given epoch.
     * @dev Users who voted in epoch N, can claim the pool verification fees accrued in epoch N+1. 
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
     */
    function voterClaimRewards(uint256 epoch, bytes32[] calldata poolIds) external whenNotPaused {
        require(poolIds.length > 0, Errors.InvalidArray());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint128 userTotalRewards;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            
            // Check pool exists and user has not claimed rewards yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(usersEpochPoolData[epoch][poolId][msg.sender].totalRewards == 0, Errors.AlreadyClaimed());    

            // Pool may be inactive but still have unclaimed prior rewards

            // Get user's pool votes and pool totals
            uint128 userPoolVotes = usersEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent;
            uint128 poolTotalVotes = epochPools[epoch][poolId].totalVotes;
            uint128 totalRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            
            // Skip pools with zero rewards or zero user votes
            if(totalRewards == 0 || userPoolVotes == 0) continue;

            // Calculate user's rewards for the pool (pro-rata)
            uint128 userRewards = (userPoolVotes * totalRewards) / poolTotalVotes;
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
        ESMOCA.safeTransfer(msg.sender, userTotalRewards);

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, userTotalRewards);
    }


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
     * - msg.sender must be the delegator (user).
     *
     * Rationale:
     * - Batch processing reduces gas costs and improves UX for users with multiple delegate relationships.
     * - Aggregating net rewards into a single transfer minimizes token transfer overhead.
     * - Per-delegate fee payments ensure accurate fee distribution and event logging.
     * - The function enforces finalized epoch and array length checks to prevent inconsistent state or under-claimed rewards.
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
                ESMOCA.safeTransfer(delegate, delegateFee);
                emit Events.DelegateFeesClaimed(delegate, delegateFee);
            }

            // increment counter
            userTotalNetRewards += userTotalNetRewardsForDelegate;

        }

        require(userTotalNetRewards > 0, Errors.NoRewardsToClaim());  // Check aggregate net >0

        // Single transfer of total net to user (caller)
        ESMOCA.safeTransfer(msg.sender, userTotalNetRewards);
        emit Events.RewardsClaimedFromDelegateBatch(epoch, msg.sender, delegateList, poolIdsPerDelegate, userTotalNetRewards);
    }

    /**
     * @notice Mirror function of {claimRewardsFromDelegate}, enabling delegates to claim accumulated fees from multiple delegators.
     * @dev Allows delegates to claim their earned fees directly, independent of user (delegator) activity, ensuring fee collection is not blocked by user inactivity.
     *      Input lists of pools and delegators should be constructed to maximize total aggregated rewards, minimizing rounding down and flooring losses.
     *      Processes batches by delegators; each delegator's pools are specified for fee calculation and distribution.
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
                ESMOCA.safeTransfer(delegator, userTotalNetRewards);
                emit Events.RewardsClaimedFromDelegate(epoch, delegator, delegate, poolIds, userTotalNetRewards);
            }

            // increment counter
            totalDelegateFees += delegateFee;
        }

        // batch transfer all accrued fees to delegate
        if (totalDelegateFees > 0) {
            ESMOCA.safeTransfer(delegate, totalDelegateFees);
            emit Events.DelegateFeesClaimed(delegate, totalDelegateFees);
        }
    }

//-------------------------------claim subsidies functions----------------------------------------------

    /**
     * @notice Claims verifier subsidies for specified pools in a given epoch.
     * @dev Subsidies are claimable based on the verifier's expenditure accrued for each pool-epoch.
     *      Only the `assetAddress` of the verifier (as registered in PaymentsController) can call this function.
     * @param epoch The epoch number for which subsidies are being claimed.
     * @param verifierAddress The address of the verifier for which to claim subsidies.
     * @param poolIds Array of pool identifiers for which to claim subsidies.
     *
     * Requirements:
     * - The epoch must be fully finalized.
     * - Each poolId must exist and have allocated subsidies.
     */
    function claimSubsidies(uint256 epoch, address verifierAddress, bytes32[] calldata poolIds) external whenNotPaused {
        require(poolIds.length > 0, Errors.InvalidArray());
        
        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint128 totalSubsidiesClaimed;  
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // check if pool exists and has subsidies allocated
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            uint128 poolAllocatedSubsidies = epochPools[epoch][poolId].totalRewardsAllocated;
            require(poolAllocatedSubsidies > 0, Errors.NoSubsidiesForPool());

            // check if already claimed
            require(verifierEpochPoolData[epoch][poolId][msg.sender] == 0, Errors.SubsidyAlreadyClaimed());

            // get verifier's accrued subsidies for {pool, epoch} & pool's total accrued subsidies for the epoch
            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) // these are in USD8, 1e6 precision
                // reverts if msg.sender is not the verifierId's asset address
                = PAYMENTS_CONTROLLER.getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifierAddress, msg.sender);

            // poolAccruedSubsidies == 0 will revert on division; verifierAccruedSubsidies == 0 will be skipped | no need for checks

            // calculate ratio and rebase it to 18dp in single step | ratio is in 18dp precision
            uint256 ratio = (verifierAccruedSubsidies * 1E18) / poolAccruedSubsidies; // subsidies in 1e6 precision
            
            // calculate subsidy receivable
            uint256 subsidyReceivable_256 = (ratio * poolAllocatedSubsidies) / 1E18; // subsidies in 1e18 precision
            require(subsidyReceivable_256 <= type(uint128).max, Errors.RebaseOverflow());


            uint128 subsidyReceivable = uint128(subsidyReceivable_256);
            if(subsidyReceivable == 0) continue;  // skip if floored to 0

            totalSubsidiesClaimed += subsidyReceivable;

            // book verifier's subsidy receivable for the epoch
            verifierEpochPoolData[epoch][poolId][msg.sender] = subsidyReceivable;
            verifierEpochData[epoch][msg.sender] += subsidyReceivable;
            verifierData[msg.sender] += subsidyReceivable;      // @follow-up : redundant, query via sum if needed

            // update pool & epoch total claimed
            pools[poolId].totalSubsidiesClaimed += subsidyReceivable;
            epochPools[epoch][poolId].totalSubsidiesClaimed += subsidyReceivable;
        }

        if(totalSubsidiesClaimed == 0) revert Errors.NoSubsidiesToClaim();

        // update epoch & pool total claimed
        TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
        epochs[epoch].totalSubsidiesClaimed += totalSubsidiesClaimed;

        // event
        emit Events.SubsidiesClaimed(msg.sender, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier
        // note: must whitelist VotingController on esMoca for transfers
        ESMOCA.safeTransfer(msg.sender, totalSubsidiesClaimed);      
    }


//-------------------------------onlyCronJob: depositEpochSubsidies, finalizeEpochRewardsSubsidies -----------------------------------------
    // TODO
    //note: use cronjob instead of asset manager, due to frequency of calls
    //note: what if i have deposit/finazlie pull assets from treasury directly?
    //      this would require treasury address setting approvals to VotingController contract.

    /**
     * @notice Deposits esMOCA subsidies for a completed epoch to be distributed among pools based on votes.
     * @dev Callable only by VotingController admin. Calculates and sets subsidy per vote for the epoch.
     *      Transfers esMOCA from the caller to the contract if subsidies > 0 and epoch.votes > 0.
     *      Can only be called after the epoch has ended and before it is finalized.
     * @param epoch The epoch number for which to deposit subsidies.
     * @param subsidies The total amount of esMOCA subsidies to deposit (1e18 precision).
     */
    function depositEpochSubsidies(uint256 epoch, uint128 subsidies) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        //require(subsidies > 0, Errors.InvalidAmount()); --> subsidies can be 0
        require(epoch <= EpochMath.getCurrentEpochNumber(), Errors.CannotSetSubsidiesForFutureEpochs());
        
        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // flag check: subsidies can only be set once for an epoch; and it can be 0
        require(!epochPtr.isSubsidiesSet, Errors.SubsidiesAlreadySet());

        // if subsidies >0 and totalVotes >0: set totalSubsidies + transfer esMoca
        if(subsidies > 0 && epochPtr.totalVotes > 0) {
            // if there are no votes, we will not distribute subsidies
            ESMOCA.safeTransferFrom(msg.sender, address(this), subsidies);

            // STORAGE: update total subsidies deposited for epoch + global
            epochPtr.totalSubsidiesDeposited = subsidies;
            TOTAL_SUBSIDIES_DEPOSITED += subsidies;

            emit Events.SubsidiesDeposited(msg.sender, epoch, subsidies);
        } // else: subsidies = 0 or no votes -> no-op, flag still set

        //STORAGE: set flag
        epochPtr.isSubsidiesSet = true;
        emit Events.SubsidiesSet(epoch, subsidies);
    }

    //Note: pools tt were removed will not be processed. If users did not migrate votes from removed pools, this will result in lost rewards and subsidies
    /**
     * @notice Finalizes rewards and subsidies allocation for pools in a given epoch.
     * @dev 
     *   - Callable only once per pool per epoch.
     *   - Subsidies are referenced from PaymentsController. Rewards are decided by Protocol.
     *   - Only deposits rewards that can be claimed (i.e., poolRewards > 0 and poolVotes > 0).
     *   - The sum of input rewards may be less than or equal to totalRewardsAllocated.
     * @param epoch The epoch number to finalize.
     * @param poolIds Array of pool IDs to finalize for the epoch.
     * @param rewards Array of reward amounts (1e18 precision) corresponding to each pool.
     * Requirements:
     *   - poolIds and rewards arrays must be non-empty and of equal length.
     *   - Epoch must have ended and not be finalized.
     *   - Subsidies must have been set for the epoch.
     *   - Each pool must exist, not be removed, and not already be processed for the epoch.
     *   - Only callable by cron job role when not paused.
     */
    function finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint128[] calldata rewards) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == rewards.length, Errors.MismatchedArrayLengths());

        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized + depositEpochSubsidies() must have been called
        DataTypes.Epoch storage epochStorage = epochs[epoch];
        require(epochStorage.isSubsidiesSet, Errors.SubsidiesNotSet());
        require(!epochStorage.isFullyFinalized, Errors.EpochFinalized());

        // cache to local so for loop does not load from storage for each iteration
        uint128 epochTotalSubsidiesDeposited = epochStorage.totalSubsidiesDeposited;    // can be 0
        uint128 epochTotalVotes = epochStorage.totalVotes;
        //require(epochTotalVotes > 0, Errors.ZeroVotes());  --> can be 0, but do not implement; else epoch finalization will be blocked

        // iterate through pools
        uint128 totalRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint128 poolRewards = rewards[i];       // can be 0 , so tt all pools can be marked processed

            // cache: Pool storage pointers
            DataTypes.Pool storage poolStorage = pools[poolId];
            DataTypes.PoolEpoch storage epochPoolStorage = epochPools[epoch][poolId];

            // sanity check: pool exists + not processed + not removed
            require(poolStorage.poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!epochPoolStorage.isProcessed, Errors.PoolAlreadyProcessed());
            require(!poolStorage.isRemoved, Errors.PoolRemoved());

            uint128 poolVotes = epochPoolStorage.totalVotes;
            
            // Calc. subsidies for each pool: if there are subsidies for epoch & pool has votes
            if(epochTotalSubsidiesDeposited > 0 && poolVotes > 0) {
                
                uint128 poolSubsidies = (poolVotes * epochTotalSubsidiesDeposited) / epochTotalVotes;
                
                // sanity check: poolSubsidies > 0; skip if floored to 0
                if(poolSubsidies > 0) { 
                    epochPoolStorage.totalSubsidiesAllocated = poolSubsidies;
                    poolStorage.totalSubsidiesAllocated += poolSubsidies;
                }
            }

            // Set totalRewards for each pool | only if rewards >0 and votes >0 (avoids undistributable)
            if(poolRewards > 0 && poolVotes > 0) {
                epochPoolStorage.totalRewardsAllocated = poolRewards;
                poolStorage.totalRewardsAllocated += poolRewards;

                totalRewards += poolRewards;
            } // else skip, rewards effectively 0 for this pool

            // mark processed
            epochPoolStorage.isProcessed = true;
        }

        // STORAGE: update epoch global rewards allocated | subsidies was set in depositEpochSubsidies()
        epochStorage.totalRewardsAllocated += totalRewards;
        // STORAGE: increment count of pools finalized
        epochStorage.poolsFinalized += uint128(poolIds.length);

        emit Events.EpochPartiallyFinalized(epoch, poolIds);

        // deposit rewards
        ESMOCA.safeTransferFrom(msg.sender, address(this), totalRewards);

        // check if epoch is fully finalized
        if(epochStorage.poolsFinalized == TOTAL_NUMBER_OF_POOLS) {
            epochStorage.isFullyFinalized = true;
            emit Events.EpochFullyFinalized(epoch);
        }
    }


//-------------------------------onlyAssetManager: withdrawUnclaimedRewards, withdrawUnclaimedSubsidies -----------------------------------------
    
    /**
     * @notice Sweep all unclaimed and residual voting rewards for a given epoch to the treasury.
     * @dev Can only be called by a VotingController admin after a delay defined by UNCLAIMED_DELAY_EPOCHS epochs.
     *      Transfers both unclaimed and residual (unclaimable flooring losses) esMoca rewards to voting controller treasury.
     *      Reverts if the epoch is not finalized, the voting controller treasury address is unset, or there are no unclaimed rewards to sweep.
     * @param epoch The epoch number for which to sweep unclaimed and residual rewards.
     */
    function withdrawUnclaimedRewards(uint256 epoch) external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // sanity check: withdraw delay must have passed
        require(epoch > EpochMath.getCurrentEpochNumber() + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        // sanity check: epoch must be finalized [pool exists implicitly]
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        // sanity check: there must be unclaimed rewards
        uint256 unclaimed = epochs[epoch].totalRewardsAllocated - epochs[epoch].totalRewardsClaimed;
        require(unclaimed > 0, Errors.NoUnclaimedRewardsToWithdraw());
        
        ESMOCA.safeTransfer(votingControllerTreasury, unclaimed);

        emit Events.UnclaimedRewardsWithdrawn(votingControllerTreasury, epoch, unclaimed);
    }

    /**
     * @notice Sweep all unclaimed and residual subsidies for a specified epoch to the treasury.
     * @dev Can only be called by a VotingController admin after a delay defined by UNCLAIMED_DELAY_EPOCHS epochs.
     *      Transfers both unclaimed and residual (unclaimable flooring losses) esMoca subsidies to voting controller treasury.
     *      Reverts if the epoch is not finalized, the delay has not passed, the voting controller treasury address is unset, or there are no unclaimed subsidies to sweep.
     * @param epoch The epoch number for which to sweep unclaimed and residual subsidies.
     */
    function withdrawUnclaimedSubsidies(uint256 epoch) external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // sanity check: withdraw delay must have passed
        require(epoch > EpochMath.getCurrentEpochNumber() + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        // sanity check: epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());
        
        // sanity check: there must be unclaimed subsidies
        uint256 unclaimedSubsidies = epochs[epoch].totalSubsidiesDeposited - epochs[epoch].totalSubsidiesClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // transfer esMoca to voting controller treasury
        ESMOCA.safeTransfer(votingControllerTreasury, unclaimedSubsidies);

        // event
        emit Events.UnclaimedSubsidiesWithdrawn(votingControllerTreasury, epoch, unclaimedSubsidies);
    }

    /**
     * @notice Withdraws all unclaimed registration fees to the voting controller treasury.
     * @dev Can only be called by a VotingController admin
     *      Reverts if the voting controller treasury address is unset, or there are no unclaimed registration fees to withdraw.
     */
    function withdrawRegistrationFees() external payable onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        require(TOTAL_REGISTRATION_FEES > 0, Errors.NoRegistrationFeesToWithdraw());

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        // sanity check: there must be registration fees to withdraw
        uint256 claimable = TOTAL_REGISTRATION_FEES - REGISTRATION_FEES_CLAIMED;
        require(claimable > 0, Errors.InvalidAmount());

        // book claimed registration fees
        REGISTRATION_FEES_CLAIMED += claimable;

        // Transfer Moca to user [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, votingControllerTreasury, claimable, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.RegistrationFeesWithdrawn(votingControllerTreasury, claimable);
    }
    
//-------------------------------onlyVotingControllerAdmin: setters ---------------------------------------------------------

    /**
     * @notice Sets the maximum delegate fee percentage.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and less than PRECISION_BASE.
     * @param maxFeePct The new maximum delegate fee percentage (2 decimal precision, e.g., 100 = 1%).
     */
    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
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
    function setFeeIncreaseDelayEpochs(uint256 delayEpochs) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(delayEpochs > 0, Errors.InvalidDelayPeriod());
        require(delayEpochs % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayPeriod());
       
        FEE_INCREASE_DELAY_EPOCHS = delayEpochs;
        emit Events.FeeIncreaseDelayEpochsUpdated(delayEpochs);
    }

    /**
     * @notice Sets the unclaimed delay epochs.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and a multiple of EpochMath.EPOCH_DURATION.
     * @param newDelayEpoch The new unclaimed delay epochs.
     * This delay applied to both withdrawUnclaimedRewards and withdrawUnclaimedSubsidies
     */
    function setUnclaimedDelay(uint256 newDelayEpoch) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newDelayEpoch > 0, Errors.InvalidDelayPeriod());
        require(newDelayEpoch % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayPeriod());

        emit Events.UnclaimedDelayUpdated(UNCLAIMED_DELAY_EPOCHS, newDelayEpoch);
        UNCLAIMED_DELAY_EPOCHS = newDelayEpoch;
    }

    // TODO
    function setDelegateRegistrationFee(uint256 newRegistrationFee) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        //require(newRegistrationFee > 0, Errors.InvalidRegistrationFee());  0 is acceptable

        emit Events.DelegateRegistrationFeeUpdated(REGISTRATION_FEE, newRegistrationFee);
        REGISTRATION_FEE = newRegistrationFee;
    }


    /**
     * @notice Sets the gas limit for moca transfer.
     * @dev Only callable by the IssuerStakingController admin.
     * @param newMocaTransferGasLimit The new gas limit for moca transfer.
     */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }

//-------------------------------onlyVotingControllerAdmin: pool functions----------------------------------------------------

    /**
     * @notice Creates a new voting pool and returns its unique identifier.
     * @dev Callable only by VotingController admin (cron job role). Ensures poolId uniqueness by regenerating if a collision is detected.
     *      Pool creation is blocked during active end-of-epoch operations to maintain protocol consistency.
     *      Increments the global pool counter on successful creation.
     * @return poolId The unique identifier assigned to the newly created pool.
     */
    function createPool() external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused returns (bytes32) {
        // prevent pool creation during active epoch finalization
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(!epochs[currentEpoch].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // ensure for previous epoch, epoch is finalized
        if (currentEpoch > 0) {
            uint256 previousEpoch = currentEpoch - 1;
            require(epochs[previousEpoch].isFullyFinalized, Errors.EndOfEpochOpsUnderway());
        }

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

   
    /** Note: If a removed pool has votes at epoch end, the following will happen, during finalization:
        - Lost Rewards: Users who voted for a removed pool forfeit their rewards *(unless they migrated their votes)*
        - Accounting Mismatch: The epoch's `totalVotes` includes votes for removed pools, but rewards and subsidies are only distributed to active pools *(unless users migrated their votes)*
        - Lost Subsidies: Verifiers for removed pools cannot claim subsidies
     */

    /**
     * @notice Removes a voting pool from the protocol.
     * @dev Callable only by cron job role.
     *
     * Pool removal is restricted to periods before `depositEpochSubsidies()` is called for the current epoch.
     * This prevents inconsistencies in `TOTAL_NUMBER_OF_POOLS` during end-of-epoch operations.
     * Removing a pool after subsidies are deposited could cause the epoch finalization check
     * (`poolsFinalized == TOTAL_NUMBER_OF_POOLS`) to fail, blocking epoch finalization.
     *
     * Once subsidies are deposited for the current epoch, pool removal is blocked to maintain a static pool set
     * during end-of-epoch processing.
     *
     * @param poolId Unique identifier of the pool to be removed.
     */
    function removePool(bytes32 poolId) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());

        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

        // pool removal not allowed before finalizeEpochRewardsSubsidies() is called
        // else, TOTAL_NUMBER_OF_POOLS will be off and epoch will be never finalized
        require(!epochs[currentEpoch].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // ensure for previous epoch, epoch is finalized
        if (currentEpoch > 0) {
            uint256 previousEpoch = currentEpoch - 1;
            require(epochs[previousEpoch].isFullyFinalized, Errors.EndOfEpochOpsUnderway());
        }

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
    function _applyPendingFeeIfNeeded(address delegateAddr, uint128 currentEpoch) internal returns (bool) {
        DataTypes.Delegate storage delegatePtr = delegates[delegateAddr];

        // if there is a pending fee increase, apply it
        if(delegatePtr.nextFeePctEpoch > 0) {
            if(currentEpoch >= delegatePtr.nextFeePctEpoch) {
                
                // update currentFeePct and set the historical fee for the current epoch
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;
                delegateHistoricalFeePcts[delegateAddr][currentEpoch] = delegatePtr.currentFeePct;  // Ensure set for claims
                
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
        uint128 userTotalGrossRewards;
        uint128 delegateTotalPoolRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // sanity checks: pool exists + user has not claimed rewards from this delegate-pool pair yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(userDelegateAccounting[epoch][delegator][delegate].userPoolGrossRewards[poolId] == 0, Errors.NoRewardsToClaim());

            // calculations: delegate's votes for this pool + pool totals
            uint128 delegatePoolVotes = delegatesEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
            uint128 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            uint128 totalPoolRewards = epochPools[epoch][poolId].totalRewardsAllocated;

            if (totalPoolRewards == 0 || totalPoolVotes == 0) continue;  // skip if pool has no rewards or votes

            uint128 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
            if (delegatePoolRewards == 0) continue;  // skip if floored to 0

            // book delegate's rewards for this pool & epoch
            delegatesEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;

            // fetch: number of votes user delegated, to this delegate & the total votes managed by the delegate
            uint128 userVotesAllocatedToDelegateForEpoch = VEMOCA.getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);
            uint128 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;

            // calc. user's gross rewards for the pool
            uint128 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
            if (userGrossRewards == 0) continue;  // skip if floored to 0

            // book user's gross rewards for this pool & epoch
            userDelegateAccounting[epoch][delegator][delegate].userPoolGrossRewards[poolId] = userGrossRewards;

            // update pool & epoch: total claimed rewards
            epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
            pools[poolId].totalRewardsClaimed += userGrossRewards;

            // update counters
            userTotalGrossRewards += userGrossRewards;
            delegateTotalPoolRewards += delegatePoolRewards;
        }

        if (userTotalGrossRewards == 0) return (0, 0);  // Early return if nothing to claim

        // calc. delegate fee + net rewards on total gross rewards, so as to not lose precision
        uint128 delegateFeePct = delegateHistoricalFeePcts[delegate][epoch];           
        uint128 delegateFee = userTotalGrossRewards * delegateFeePct / uint128(Constants.PRECISION_BASE);
        uint128 userTotalNetRewards = userTotalGrossRewards - delegateFee;

        // ---- Accounting updates ----
        
        // increment user's net rewards earned via delegated votes
        userDelegateAccounting[epoch][delegator][delegate].totalNetRewards += userTotalNetRewards;

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

//-------------------------------risk functions----------------------------------------------------------

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
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice Freeze the contract.
     * @dev Only callable by the Global Admin [multi-sig].
     *      This is a kill switch function
     */
    function freeze() external whenPaused onlyRole(DEFAULT_ADMIN_ROLE) {
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
    function emergencyExit() external payable onlyRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE) {
        if(isFrozen == 0) revert Errors.NotFrozen();

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        // exfil esMoca [rewards + subsidies]
        ESMOCA.safeTransfer(votingControllerTreasury, ESMOCA.balanceOf(address(this)));

        // exfil moca [registration fees]
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, votingControllerTreasury, address(this).balance, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.EmergencyExit(votingControllerTreasury);
    }


//-------------------------------view functions-----------------------------------------------------------

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
    function getUserDelegatePoolGrossRewards(uint256 epoch, address user, address delegate, bytes32[] calldata poolIds) external view returns (uint128[] memory, uint256) {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint128[] memory grossRewardsPerPool = new uint128[](poolIds.length);
        
        // fetch gross rewards for each poolId
        uint256 totalGrossRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            grossRewardsPerPool[i] = userDelegateAccounting[epoch][user][delegate].userPoolGrossRewards[poolIds[i]];
            totalGrossRewards += grossRewardsPerPool[i];
        }
    
        return (grossRewardsPerPool, totalGrossRewards);
    }

}