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

    // Immutables
    address public immutable WMOCA;
    IERC20 public immutable ESMOCA;
    IVotingEscrowMoca public immutable VEMOCA;
    IPaymentsController public immutable PAYMENTS_CONTROLLER;

    // Mutable Contracts
    address public VOTING_CONTROLLER_TREASURY;

    // Epoch Finalization Tracking
    uint128 public CURRENT_EPOCH_TO_FINALIZE;

    // Pools
    uint128 public TOTAL_POOLS_CREATED;
    uint128 public TOTAL_ACTIVE_POOLS;

    // Subsidies
    uint128 public TOTAL_SUBSIDIES_DEPOSITED;
    uint128 public TOTAL_SUBSIDIES_CLAIMED;

    // Rewards
    uint128 public TOTAL_REWARDS_DEPOSITED;
    uint128 public TOTAL_REWARDS_CLAIMED;

    // Delegate 
    uint128 public DELEGATE_REGISTRATION_FEE;           // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint128 public MAX_DELEGATE_FEE_PCT;                // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint128 public FEE_INCREASE_DELAY_EPOCHS;           // in epochs
    
    // Registration Fees [native MOCA]
    uint128 public TOTAL_REGISTRATION_FEES_COLLECTED;    
    uint128 public TOTAL_REGISTRATION_FEES_CLAIMED;

    // Number of epochs that must pass before unclaimed rewards or subsidies can be withdrawn
    uint128 public UNCLAIMED_DELAY_EPOCHS;

    uint128 public MOCA_TRANSFER_GAS_LIMIT; // gas limit for native MOCA transfer

    uint128 public isFrozen; // risk management

//------------------------------- Mappings ------------------------------------------------------------------

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
    mapping(uint128 epochNum => mapping(address user => mapping(address delegate => DataTypes.UserDelegateAccount userDelegateAccount))) public userDelegateAccounts;


    // Delegate registration data + fee data
    mapping(address delegateAddr => DataTypes.Delegate delegate) public delegates;     
    mapping(address delegate => mapping(uint128 epoch => uint128 currentFeePct)) public delegateHistoricalFeePcts;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)


    // updated in claimSubsidies()
    mapping(address verifier => uint128 totalSubsidies) public verifierSubsidies;                  
    mapping(uint128 epoch => mapping(address verifier => DataTypes.VerifierEpoch verifierEpochData)) public verifierEpochData;
    mapping(uint128 epoch => mapping(uint128 poolId => mapping(address verifier => uint128 totalSubsidies))) public verifierEpochPoolSubsidies;


//------------------------------- Constructor ------------------------------------------------------------------

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

        // set current epoch to finalize
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        CURRENT_EPOCH_TO_FINALIZE = currentEpoch;

        // Finalize previous epoch to unblock: createPools(), removePools(), finalizeEpoch()
        uint128 previousEpoch = currentEpoch - 1;
        epochs[previousEpoch].state = DataTypes.EpochState.Finalized;
        //emit Events.EpochFinalized(previousEpoch);

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
        _requireMatchingArrays(length, poolVotes.length);

        // get current epoch & cache epoch pointer
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // Voting only allowed in Voting state
        require(epochPtr.state == DataTypes.EpochState.Voting, Errors.EndOfEpochOpsUnderway());

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
        DataTypes.Account storage accountEpochPtr = accountEpochData[currentEpoch][msg.sender];
        uint128 spentVotes = accountEpochPtr.totalVotesSpent; 

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
        accountEpochPtr.totalVotesSpent += totalNewVotes;
        
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
        _requireMatchingArrays(length, dstPoolIds.length, votesToMigrate.length);

        // get current epoch
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // Voting only allowed in Voting state
        require(epochPtr.state == DataTypes.EpochState.Voting, Errors.EndOfEpochOpsUnderway());

        // Validate delegate and record fee: executed each time, since delegate fee decreases are instantly applied
        if (isDelegated) _validateDelegateAndRecordFee(currentEpoch);


        // mapping lookups: account:{personal,delegate}
        mapping(uint128 => mapping(uint128 => mapping(address => DataTypes.Account))) storage accountEpochPoolData  
        = isDelegated ? delegatesEpochPoolData : usersEpochPoolData;
   

        // allow migration of votes from inactive pool to active pool; but not vice versa
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

//------------------------------- Delegate functions --------------------------------------------------------------

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
     * @notice Updates the delegate's fee percentage for rewards.
     * @dev Fee decreases take effect immediately and overwrites for the current epoch; 
     * fee increases are scheduled for (currentEpoch + FEE_INCREASE_DELAY_EPOCHS).
     * After an epoch ends, fee percentages for that epoch are locked.
     * @param newFeePct New fee percentage [100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)]
     */
    function updateDelegateFee(uint128 newFeePct) external whenNotPaused {
        // fee percentage cannot exceed MAX_DELEGATE_FEE_PCT
        require(newFeePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());   
        
        // check: delegate is registered
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];      
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        // check: new fee is different from current fee
        uint128 currentFeePct = delegatePtr.currentFeePct;
        require(newFeePct != currentFeePct, Errors.InvalidFeePct()); 

        // get current epoch
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();       

        // if new fee is less than current fee: decrease fee immediately
        if(newFeePct < currentFeePct) {

            // set new fee immediately [overwrites any prior fee snapshot for this epoch]
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
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        // check: delegate has no active votes in current epoch
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(delegateEpochData[currentEpoch][msg.sender].totalVotesSpent == 0, Errors.CannotUnregisterWithActiveVotes());
 
        // storage: unregister delegate
        delete delegatePtr.isRegistered;
        delete delegatePtr.currentFeePct;
        delete delegatePtr.nextFeePct;
        delete delegatePtr.nextFeePctEpoch;

        emit Events.DelegateUnregistered(msg.sender);

        // mark as unregistered on VotingEscrowMoca
        VEMOCA.delegateRegistrationStatus(msg.sender, false);
    }

//------------------------------- Claiming rewards & fees functions ------------------------------------------------

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
        _requireNonEmptyArray(numOfPools);

        // cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // assert: epoch is finalized and rewards not withdrawn
        _assertRewardsClaimWindow(epochPtr);


        uint128 userTotalRewards;

        for(uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            // cache pointers             
            DataTypes.Account storage userPoolAccountPtr = usersEpochPoolData[epoch][poolId][msg.sender];
            DataTypes.PoolEpoch storage poolEpochPtr = epochPools[epoch][poolId];

            // prevent double claiming
            require(userPoolAccountPtr.totalRewards == 0, Errors.AlreadyClaimedOrNothingToClaim()); 

            uint128 userVotes = userPoolAccountPtr.totalVotesSpent;
            uint128 poolRewards = poolEpochPtr.totalRewardsAllocated;
            uint128 poolTotalVotes = poolEpochPtr.totalVotes;

            // Calculate user's rewards for the pool [all in 1e18 precision]
            uint128 userRewards = _mulDiv(userVotes, poolRewards, poolTotalVotes);
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
        _requireMatchingArrays(numOfDelegates, poolIds.length);

        // assert: epoch is finalized and rewards not withdrawn
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        _assertRewardsClaimWindow(epochPtr);

        
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
        _requireMatchingArrays(numOfDelegators, poolIds.length);

        // cache epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // assert: epoch is finalized and rewards not withdrawn
        _assertRewardsClaimWindow(epochPtr);
        
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


//------------------------------- Claim Subsidies Function ----------------------------------------------
    
    /**
     * @notice Claim subsidies for a verifier in the specified pools for a given epoch.
     * @dev Can only be called by the verifier's asset address (as set in PaymentsController). 
     *      Subsidies can be claimed once per pool per epoch per verifier.
     * @param epoch Target epoch to claim subsidies from.
     * @param verifier Verifier address to claim for.
     * @param poolIds List of pool IDs to claim subsidies from.
     */
    function claimSubsidies(uint128 epoch, address verifier, uint128[] calldata poolIds) external whenNotPaused {
        require(verifier != address(0), Errors.InvalidAddress());

        uint256 numOfPools = poolIds.length;
        _requireNonEmptyArray(numOfPools);

        // assert: epoch is finalized and subsidies not withdrawn
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        _assertSubsidyClaimWindow(epochPtr);

        // verifier must not be blocked
        DataTypes.VerifierEpoch storage verifierEpochPtr = verifierEpochData[epoch][verifier];
        require(!verifierEpochPtr.isBlocked, Errors.ClaimsBlocked());

        uint128 totalSubsidiesClaimed; 
        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            DataTypes.PoolEpoch storage poolEpochPtr = epochPools[epoch][poolId];

            // pool must have subsidies allocated
            uint128 poolAllocatedSubsidies = poolEpochPtr.totalSubsidiesAllocated;
            if(poolAllocatedSubsidies == 0) continue;

            // verifier must not have claimed subsidies for this pool
            require(verifierEpochPoolSubsidies[epoch][poolId][verifier] == 0, Errors.SubsidyAlreadyClaimed());

            // get verifier's accrued subsidies for {pool, epoch} & pool's accrued subsidies [AccruedSubsidies in 1e6 precision]
            // reverts if msg.sender is not the verifier's asset address
            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies)
                = PAYMENTS_CONTROLLER.getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifier, msg.sender);                

            // skip if poolAccruedSubsidies == 0 [also implies that verifierAccruedSubsidies == 0]
            if(poolAccruedSubsidies == 0) continue;
            
            // safety check: verifierAccruedSubsidies <= poolAccruedSubsidies [in case PC misbehaves]
            require(verifierAccruedSubsidies <= poolAccruedSubsidies, Errors.VerifierAccruedSubsidiesGreaterThanPool());
            

            // calculate ratio and rebase it to 18dp in single step [ratio is in 18dp precision]
            uint256 ratio = (verifierAccruedSubsidies * 1E18) / poolAccruedSubsidies; 
            

            // Safe downcast: ratio ∈ [0, 1e18] since verifierAccrued ≤ poolAccrued by definition.
            // therefore: (ratio * poolAllocatedSubsidies) / 1e18 ≤ poolAllocatedSubsidies (uint128)

            // Calculate esMoca subsidy receivable [poolAllocatedSubsidies in 1e18 precision]
            uint128 subsidyReceivable = uint128((ratio * poolAllocatedSubsidies) / 1E18); 
            if(subsidyReceivable == 0) continue; 
 
            // assert: subsidy receivable is less than or equal to remaining pool allocated subsidies
            require(subsidyReceivable <= poolAllocatedSubsidies, Errors.SubsidyReceivableGreaterThanPoolAllocation());
        

            // update counter
            totalSubsidiesClaimed += subsidyReceivable;

            // book verifier's subsidy receivable for the {pool, epoch}
            verifierEpochPoolSubsidies[epoch][poolId][verifier] = subsidyReceivable;
        }

        if(totalSubsidiesClaimed == 0) revert Errors.NoSubsidiesToClaim();

        // update verifier's epoch & global total claimed
        verifierSubsidies[verifier] += totalSubsidiesClaimed;
        verifierEpochPtr.totalSubsidiesClaimed += totalSubsidiesClaimed;

        // update global & epoch total claimed
        TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
        epochPtr.totalSubsidiesClaimed += totalSubsidiesClaimed;
        
        emit Events.SubsidiesClaimed(verifier, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier's asset address
        ESMOCA.safeTransfer(msg.sender, totalSubsidiesClaimed);      
    }


//------------------------------- VotingControllerAdmin: create/remove pools ----------------------------------------------------

    /**
     * @notice Creates several new voting pools in a single transaction.
     * @dev Can only be called by addresses with the VotingController admin role.
     *      Pool creation is only permitted when the current epoch is in the Voting state, and the previous epoch has been finalized.
     *      This function will revert if called during any end-of-epoch state operations.
     * @param count The number of pools to create in this call. [1-10]
     */
    function createPools(uint128 count) external whenNotPaused onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        require(count > 0 && count <= 10, Errors.InvalidAmount());
        
        // Pool creation only during Voting state
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();      
        require(epochs[currentEpoch].state == DataTypes.EpochState.Voting, Errors.EndOfEpochOpsUnderway());
        
        // Previous epoch must be finalized
        require(_isFinalized(epochs[currentEpoch - 1].state), Errors.EpochNotFinalized());

        uint128 startPoolId = TOTAL_POOLS_CREATED + 1;
        uint128 endPoolId = TOTAL_POOLS_CREATED + count;
        
        // Set pools as active
        for (uint128 i = startPoolId; i <= endPoolId; ++i) {
            pools[i].isActive = true;
        }

        // update global counters
        TOTAL_POOLS_CREATED = endPoolId;
        TOTAL_ACTIVE_POOLS += count;

        emit Events.PoolsCreated(startPoolId, endPoolId, count);
    }


    /**
     * @notice Removes multiple voting pools in a single transaction.
     * @dev Callable only by VotingController admin.
     *      Pool removal is blocked during active end-of-epoch operations.
     * @param poolIds Array of pool IDs to remove (max 50 per call).
     */
    function removePools(uint128[] calldata poolIds) external whenNotPaused onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        uint256 numOfPools = poolIds.length;
        _requireNonEmptyArray(numOfPools);

        // Pool removal only during Voting state
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();       
        require(epochs[currentEpoch].state == DataTypes.EpochState.Voting, Errors.EndOfEpochOpsUnderway());
        
        // Previous epoch must be finalized
        require(_isFinalized(epochs[currentEpoch - 1].state), Errors.EpochNotFinalized());

        // accumulate votes to remove
        uint128 votesToRemove;

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            require(pools[poolId].isActive, Errors.PoolNotActive());

            votesToRemove += epochPools[currentEpoch][poolId].totalVotes;

            delete pools[poolId].isActive;
        }

        // update global counters
        TOTAL_ACTIVE_POOLS -= uint128(numOfPools);

        // disregard votes from removed pools [for subsidy/rewards calculation]
        if (votesToRemove > 0) epochs[currentEpoch].totalVotes -= votesToRemove;

        emit Events.PoolsRemoved(poolIds, votesToRemove);
    }

//------------------------------- EndOfEpoch Operations -----------------------------------------
    

    // end epoch, log active pools, close voting.
    function endEpoch() external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        // ensure sequential processing
        uint128 epochToFinalize = CURRENT_EPOCH_TO_FINALIZE;

        // Full epoch duration must be honoured before voting can be closed
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epochToFinalize);
        require(block.timestamp > epochEndTimestamp, Errors.EpochNotEnded());
        
        // Validate: epoch must be in Voting state
        DataTypes.Epoch storage epochPtr = epochs[epochToFinalize];
        require(epochPtr.state == DataTypes.EpochState.Voting, Errors.VotingInProgress());

        // Snapshot: total active pools for the epoch
        epochPtr.totalActivePools = TOTAL_ACTIVE_POOLS;

        // Handle edge case: no active pools = instant finalization
        if (TOTAL_ACTIVE_POOLS == 0) {
            epochPtr.state = DataTypes.EpochState.Finalized;
            emit Events.EpochFinalized(epochToFinalize);
            ++CURRENT_EPOCH_TO_FINALIZE;
            return;
        }

        // Transition to Ended
        epochPtr.state = DataTypes.EpochState.Ended;
        emit Events.EpochEnded(epochToFinalize);
    }

    // Block verifier claims for a given epoch - guard for possible misbehavior on Payments Controller
    function processVerifierChecks(bool allChecked, address[] calldata verifiers) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {    
        // ensure sequential processing
        uint128 epochToFinalize = CURRENT_EPOCH_TO_FINALIZE;

        // Must be in Ended or Verified state (allows blocking in both phases)
        DataTypes.Epoch storage epochPtr = epochs[epochToFinalize];
        require(
            epochPtr.state == DataTypes.EpochState.Ended || epochPtr.state == DataTypes.EpochState.Verified, 
            Errors.InvalidEpochState()
        );

        // Transition to Verified
        if(allChecked) {
            epochPtr.state = DataTypes.EpochState.Verified;
            emit Events.EpochVerified(epochToFinalize);
            return;
        }

        // process verifiers to be blocked
        uint256 numOfVerifiers = verifiers.length;
        require(numOfVerifiers > 0, Errors.InvalidArray());


        for (uint256 i; i < numOfVerifiers; ++i) {
            address verifier = verifiers[i];
            if (verifier == address(0)) continue; // skip invalid addresses

            DataTypes.VerifierEpoch storage verifierEpochPtr = verifierEpochData[epochToFinalize][verifier];
            verifierEpochPtr.isBlocked = true;
        }

        emit Events.VerifiersClaimsBlocked(epochToFinalize, verifiers, numOfVerifiers);
    }


    // Process rewards & subsidies for a given epoch - allocate rewards & subsidies to pools
    // Can be called multiple times to process pools in batches. Skips already-processed pools.
    function processRewardsAndSubsidies(uint128[] calldata poolIds, uint128[] calldata rewards, uint128[] calldata subsidies) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        // INPUT VALIDATION
        uint256 numOfPools = poolIds.length;
        _requireMatchingArrays(numOfPools, rewards.length, subsidies.length);

        // ═══════════════════════════════════════════════════════════════════
        // STATE VALIDATION
        // ═══════════════════════════════════════════════════════════════════
        
        uint128 epochToFinalize = CURRENT_EPOCH_TO_FINALIZE;
        
        // Must be in Verified state (verifiers claims checked)
        DataTypes.Epoch storage epochPtr = epochs[epochToFinalize];
        require(epochPtr.state == DataTypes.EpochState.Verified, Errors.EpochNotVerified());


        // ═══════════════════════════════════════════════════════════════════
        // POOL PROCESSING
        // ═══════════════════════════════════════════════════════════════════

        // Cache: epoch total votes
        uint128 epochTotalVotes = epochPtr.totalVotes;

        uint128 totalRewardsToAllocate;
        uint128 totalSubsidiesToAllocate;

        // iterate through all active pools for the epoch: to mark pools as processed
        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            uint128 poolRewards = rewards[i];       // can be 0
            uint128 poolSubsidies = subsidies[i];   // can be 0


            // Cache: pool & epoch pool pointers
            DataTypes.Pool storage poolPtr = pools[poolId];
            DataTypes.PoolEpoch storage epochPoolPtr = epochPools[epochToFinalize][poolId];

            // Sanity check: pool must be active and not already processed
            require(poolPtr.isActive, Errors.PoolNotActive());
            require(!epochPoolPtr.isProcessed, Errors.PoolAlreadyProcessed());
            
            // mark pool as processed
            epochPoolPtr.isProcessed = true;

            // pool has 0 allocations: skip 
            if(poolRewards == 0 && poolSubsidies == 0) continue;

            // get pool's total votes for the epoch
            uint128 poolVotes = epochPoolPtr.totalVotes;
            // pool has 0 votes: skip 
            if(poolVotes == 0) continue;
                           
            // allocate rewards
            if(poolRewards > 0) {
                poolPtr.totalRewardsAllocated += poolRewards;
                epochPoolPtr.totalRewardsAllocated = poolRewards;
                totalRewardsToAllocate += poolRewards;
            }

            // allocate subsidies 
            if(poolSubsidies > 0) {
                poolPtr.totalSubsidiesAllocated += poolSubsidies;
                epochPoolPtr.totalSubsidiesAllocated = poolSubsidies;  
                totalSubsidiesToAllocate += poolSubsidies;
            }
        }

        // ═══════════════════════════════════════════════════════════════════
        // STATE UPDATES
        // ═══════════════════════════════════════════════════════════════════

        // accumulate total rewards & subsidies to allocate
        epochPtr.totalRewardsAllocated += totalRewardsToAllocate;
        epochPtr.totalSubsidiesAllocated += totalSubsidiesToAllocate;

        emit Events.PoolsProcessed(epochToFinalize, numOfPools);
    
        // increment total active pools as processed
        uint128 totalPoolsProcessed = epochPtr.poolsProcessed += uint128(numOfPools);
        bool isFullyProcessed = totalPoolsProcessed == epochPtr.totalActivePools;

        // ═══════════════════════════════════════════════════════════════════
        // Transition to Processed when all pools are done
        if (isFullyProcessed) {
            epochPtr.state = DataTypes.EpochState.Processed;
            emit Events.EpochFullyProcessed(epochToFinalize);
        }
    }

    // Finalizes an epoch by depositing rewards & subsidies from treasury and opening claims.
    // off-chain sanity checks should be executed before calling this function.
    // once this function is called, claims are open for the epoch.
    function finalizeEpoch() external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        uint128 epochToFinalize = CURRENT_EPOCH_TO_FINALIZE;

        // Must be in Processed state (all pools processed)
        DataTypes.Epoch storage epochPtr = epochs[epochToFinalize];      
        require(epochPtr.state == DataTypes.EpochState.Processed, Errors.EpochNotProcessed());

        // Cache: total rewards & subsidies
        uint128 totalRewards = epochPtr.totalRewardsAllocated;
        uint128 totalSubsidies = epochPtr.totalSubsidiesAllocated;
        
        // Update global counters
        if(totalRewards > 0) TOTAL_REWARDS_DEPOSITED += totalRewards;
        if(totalSubsidies > 0) TOTAL_SUBSIDIES_DEPOSITED += totalSubsidies;
        
        emit Events.EpochDistributionSet(epochToFinalize, totalRewards, totalSubsidies);

        // Transfer funds from treasury
        uint256 totalDistribution = totalRewards + totalSubsidies;
        if(totalDistribution > 0) {
            address treasury = _getValidatedTreasury();

            emit Events.EpochDistributionDeposited(treasury, epochToFinalize, totalDistribution);
            ESMOCA.safeTransferFrom(treasury, address(this), totalDistribution);
        }

        // Transition Epoch to Finalized 
        epochPtr.state = DataTypes.EpochState.Finalized;
        emit Events.EpochFinalized(epochToFinalize); 
        ++CURRENT_EPOCH_TO_FINALIZE;
    }

    // Force finalize an epoch in case of unexpected conditions or incorrect processing/execution
    // Subsidies and rewards are to be distributed directly to actors; claims are blocked.
    function forceFinalizeEpoch() external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused {
        uint128 epochToFinalize = CURRENT_EPOCH_TO_FINALIZE;   
        
        // Full epoch duration must be honoured before voting can be closed
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epochToFinalize);
        require(block.timestamp > epochEndTimestamp, Errors.EpochNotEnded());

        DataTypes.Epoch storage epochPtr = epochs[epochToFinalize];

        // Cannot force finalize already finalized epoch
        require(!_isFinalized(epochPtr.state), Errors.EpochAlreadyFinalized());

        // Snapshot total active pools if not already set
        if (epochPtr.totalActivePools == 0 && TOTAL_ACTIVE_POOLS > 0) {
            epochPtr.totalActivePools = TOTAL_ACTIVE_POOLS;
        }
        epochPtr.poolsProcessed = epochPtr.totalActivePools;

        // Zero out rewards & subsidies allocations (claims blocked)
        delete epochPtr.totalRewardsAllocated;
        delete epochPtr.totalSubsidiesAllocated;

        // Transition Epoch to ForceFinalized
        epochPtr.state = DataTypes.EpochState.ForceFinalized;
        
        // Advance to next epoch
        ++CURRENT_EPOCH_TO_FINALIZE;
        
        emit Events.EpochForceFinalized(epochToFinalize);
    }

//------------------------------- AssetManager Role: withdraw unclaimed rewards & subsidies, registration fees -----------------------------------------
    
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
        require(_isFinalized(epochPtr.state), Errors.EpochNotFinalized());
        require(epochPtr.totalRewardsWithdrawn == 0, Errors.RewardsAlreadyWithdrawn());  

        // Unclaimed rewards must be greater than 0
        uint128 unclaimedRewards = epochPtr.totalRewardsAllocated - epochPtr.totalRewardsClaimed;
        require(unclaimedRewards > 0, Errors.NoUnclaimedRewardsToWithdraw());

        // Book unclaimed rewards as withdrawn to treasury
        epochPtr.totalRewardsWithdrawn = unclaimedRewards;
        
        // Get treasury address
        address votingControllerTreasury = _getValidatedTreasury();
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
        require(_isFinalized(epochPtr.state), Errors.EpochNotFinalized());
        require(epochPtr.totalSubsidiesWithdrawn == 0, Errors.SubsidiesAlreadyWithdrawn());

        // Unclaimed subsidies must be greater than 0
        uint128 unclaimedSubsidies = epochPtr.totalSubsidiesAllocated - epochPtr.totalSubsidiesClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // Book unclaimed subsidies
        epochPtr.totalSubsidiesWithdrawn = unclaimedSubsidies;
        
        // Get treasury address
        address votingControllerTreasury = _getValidatedTreasury();
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
        address votingControllerTreasury = _getValidatedTreasury();
        emit Events.RegistrationFeesWithdrawn(votingControllerTreasury, unclaimedRegistrationFees);

        // Transfer Moca to user [wraps if transfer fails within gas limit] 
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, votingControllerTreasury, unclaimedRegistrationFees, MOCA_TRANSFER_GAS_LIMIT);
    }
    
//------------------------------- VotingControllerAdmin: setters ---------------------------------------------------------


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
        DataTypes.UserDelegateAccount storage pairAccountPtr = userDelegateAccounts[epoch][user][delegate];  
        
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
            DataTypes.PoolEpoch storage poolEpochPtr = epochPools[epoch][poolId];
            uint128 totalPoolRewards = poolEpochPtr.totalRewardsAllocated;
            uint128 totalPoolVotes = poolEpochPtr.totalVotes;
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
                
                delegatePoolRewards = _mulDiv(delegatePoolVotes, totalPoolRewards, totalPoolVotes);
                if (delegatePoolRewards == 0) continue;
                
                // store: delegate's rewards for this {pool, epoch} - done once, reused by subsequent callers
                delegatePoolAccountPtr.totalRewards = delegatePoolRewards;
            }
           
            // calc. user's gross rewards for the pool
            uint128 userGrossRewardsForPool = _mulDiv(userDelegatedVP, delegatePoolRewards, delegateTotalVP);
            if (userGrossRewardsForPool == 0) continue;
            
            // book user's gross rewards for this {pool, epoch}
            pairAccountPtr.userPoolGrossRewards[poolId] = userGrossRewardsForPool;
            
            // calc. delegate's fee for this pool [could be 0 if delegate did not vote this epoch]
            uint128 delegateFeeForPool = _mulDiv(userGrossRewardsForPool, delegateFeePct, uint128(Constants.PRECISION_BASE));
            
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

    // calc. in uint256 space to avoid overflow, then downcasted to uint128
    function _mulDiv(uint128 multiplicand, uint128 multiplier, uint128 divisor) internal pure returns (uint128) {
        if (multiplicand == 0 || multiplier == 0 || divisor == 0) return 0;
        return uint128((uint256(multiplicand) * multiplier) / divisor);
    }

    // createPools() & removePools() call this
    // Returns true if epoch is in a finalized or forced finalized state
    function _isFinalized(DataTypes.EpochState state) internal pure returns (bool) {
        return uint8(state) >= uint8(DataTypes.EpochState.Finalized);
    }


    function _assertRewardsClaimWindow(DataTypes.Epoch storage epochPtr) internal view {
        require(epochPtr.state == DataTypes.EpochState.Finalized, Errors.EpochNotFinalized());
        require(epochPtr.totalRewardsWithdrawn == 0, Errors.RewardsAlreadyWithdrawn());
    }

    function _assertSubsidyClaimWindow(DataTypes.Epoch storage epochPtr) internal view {
        require(epochPtr.state == DataTypes.EpochState.Finalized, Errors.EpochNotFinalized());
        require(epochPtr.totalSubsidiesWithdrawn == 0, Errors.SubsidiesAlreadyWithdrawn());
    }

    // Validates & returns treasury address
    function _getValidatedTreasury() internal view returns (address) {
        address treasury = VOTING_CONTROLLER_TREASURY;
        require(treasury != address(0), Errors.InvalidAddress());
        return treasury;
    }

    function _previewPersonalRewards(uint128 epoch, address user, uint128[] calldata poolIds) internal view returns (uint128, uint128[] memory) {
        uint256 numOfPools = poolIds.length;
        
        // counters
        uint128 totalClaimable;
        uint128[] memory perPoolClaimable = new uint128[](numOfPools);

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            DataTypes.Account storage accountPtr = usersEpochPoolData[epoch][poolId][user];

            if (accountPtr.totalRewards != 0) continue; // skip: already claimed 

            DataTypes.PoolEpoch storage poolEpochPtr = epochPools[epoch][poolId];
            uint128 claimable = _mulDiv(
                accountPtr.totalVotesSpent,
                poolEpochPtr.totalRewardsAllocated,
                poolEpochPtr.totalVotes
            );

            if (claimable == 0) continue; // skip: no rewards

            perPoolClaimable[i] = claimable;
            totalClaimable += claimable;
        }
        
        return (totalClaimable, perPoolClaimable);
    }

    function _previewDelegationRewards(uint128 epoch, address user, address delegate, uint128[] calldata poolIds) internal view returns (uint128, uint128) {
        DataTypes.UserDelegateAccount storage pairAccountPtr = userDelegateAccounts[epoch][user][delegate];
        uint128 totalNet = pairAccountPtr.totalNetRewards;
        uint128 totalFees = pairAccountPtr.totalDelegateFees;
        
        // counters
        uint128 netClaimable; 
        uint128 feeClaimable;

        if (poolIds.length > 0) {
            uint128 userDelegatedVP = VEMOCA.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, epoch);
            uint128 delegateTotalVP = VEMOCA.balanceAtEpochEnd(delegate, epoch, true);

            if (userDelegatedVP > 0 && delegateTotalVP > 0) {
                (uint128 grossDelta, uint128 feeDelta) = _simulateDelegationProcessing(
                    epoch,
                    delegate,
                    poolIds,
                    pairAccountPtr,
                    userDelegatedVP,
                    delegateTotalVP
                );

                if (grossDelta > 0) {
                    totalNet += (grossDelta - feeDelta);
                    totalFees += feeDelta;
                }
            }
        }

        if (totalNet > pairAccountPtr.userClaimed) {
            netClaimable = totalNet - pairAccountPtr.userClaimed;
        }

        if (totalFees > pairAccountPtr.delegateClaimed) {
            feeClaimable = totalFees - pairAccountPtr.delegateClaimed;
        }

        return (netClaimable, feeClaimable);
    }

    function _simulateDelegationProcessing(
        uint128 epoch, address delegate, uint128[] calldata poolIds, 
        DataTypes.UserDelegateAccount storage pairAccountPtr, 
        uint128 userDelegatedVP, uint128 delegateTotalVP
    ) internal view returns (uint128, uint128) {

        uint256 numOfPools = poolIds.length;
        uint128 delegateFeePct = delegateHistoricalFeePcts[delegate][epoch];

        // counters
        uint128 grossDelta;
        uint128 feeDelta;

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            if (pairAccountPtr.poolProcessed[poolId]) continue;

            DataTypes.Account storage delegatePoolAccountPtr = delegatesEpochPoolData[epoch][poolId][delegate];
            uint128 delegatePoolVotes = delegatePoolAccountPtr.totalVotesSpent;
            if (delegatePoolVotes == 0) continue;

            DataTypes.PoolEpoch storage poolEpochPtr = epochPools[epoch][poolId];
            uint128 totalPoolVotes = poolEpochPtr.totalVotes;
            uint128 totalPoolRewards = poolEpochPtr.totalRewardsAllocated;
            if (totalPoolVotes == 0 || totalPoolRewards == 0) continue;

            uint128 delegatePoolRewards = delegatePoolAccountPtr.totalRewards;
            if (delegatePoolRewards == 0) {
                delegatePoolRewards = _mulDiv(delegatePoolVotes, totalPoolRewards, totalPoolVotes);
                if (delegatePoolRewards == 0) continue;
            }

            uint128 userGrossRewardsForPool = _mulDiv(userDelegatedVP, delegatePoolRewards, delegateTotalVP);
            if (userGrossRewardsForPool == 0) continue;

            grossDelta += userGrossRewardsForPool;
            feeDelta += _mulDiv(userGrossRewardsForPool, delegateFeePct, uint128(Constants.PRECISION_BASE));
        }

        return (grossDelta, feeDelta);
    }

    function _requireNonEmptyArray(uint256 len) internal pure {
        require(len > 0, Errors.InvalidArray());
    }

    function _requireMatchingArrays(uint256 len1, uint256 len2) internal pure {
        require(len1 > 0, Errors.InvalidArray());
        require(len1 == len2, Errors.MismatchedArrayLengths());
    }

    function _requireMatchingArrays(uint256 len1, uint256 len2, uint256 len3) internal pure {
        require(len1 > 0, Errors.InvalidArray());
        require(len1 == len2 && len2 == len3, Errors.MismatchedArrayLengths());
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
    function emergencyExit() external onlyRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE) {
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
    
    // returns: totalClaimable, perPoolClaimable
    function viewClaimablePersonalRewards(uint128 epoch, address user, uint128[] calldata poolIds) external view returns (uint128, uint128[] memory) {
        uint256 numOfPools = poolIds.length;
        _requireNonEmptyArray(numOfPools);
        require(user != address(0), Errors.InvalidAddress());

        DataTypes.Epoch storage epochPtr = epochs[epoch];
        _assertRewardsClaimWindow(epochPtr);

        // returns: totalClaimable, perPoolClaimable
        return _previewPersonalRewards(epoch, user, poolIds);
    }

    // returns: netClaimable, feeClaimable
    function viewClaimableDelegatedRewards(uint128 epoch, address user, address delegate, uint128[] calldata poolIds) external view returns (uint128, uint128) {
        require(user != address(0) && delegate != address(0), Errors.InvalidAddress());

        DataTypes.Epoch storage epochPtr = epochs[epoch];
        _assertRewardsClaimWindow(epochPtr);

        // delegate must have voted in this epoch to have claimable rewards
        if (delegateEpochData[epoch][delegate].totalVotesSpent == 0) {
            return (0, 0);
        }

        // returns: netClaimable, feeClaimable
        return _previewDelegationRewards(epoch, user, delegate, poolIds);
    }

    // returns: totalFeeClaimable, perDelegatorFees
    function viewClaimableDelegationFees(uint128 epoch, address[] calldata delegators, uint128[][] calldata poolIds) external view returns (uint128, uint128[] memory) {
        uint256 numOfDelegators = delegators.length;
        _requireMatchingArrays(numOfDelegators, poolIds.length);

        DataTypes.Epoch storage epochPtr = epochs[epoch];
        _assertRewardsClaimWindow(epochPtr);

        require(delegateEpochData[epoch][msg.sender].totalVotesSpent > 0, Errors.NoFeesToClaim());

        // counters
        uint128 totalFeeClaimable;
        uint128[] memory perDelegatorFees = new uint128[](numOfDelegators);

        for (uint256 i; i < numOfDelegators; ++i) {
            address delegator = delegators[i];
            require(delegator != address(0), Errors.InvalidAddress());

            uint128[] calldata poolIdsForDelegator = poolIds[i];
            if (poolIdsForDelegator.length == 0) continue;

            (, uint128 feeClaimable) = _previewDelegationRewards(epoch, delegator, msg.sender, poolIdsForDelegator);
            if (feeClaimable == 0) continue;

            perDelegatorFees[i] = feeClaimable;
            totalFeeClaimable += feeClaimable;
        }

        return (totalFeeClaimable, perDelegatorFees);
    }


    // returns: totalClaimable, perPoolClaimable
    function viewClaimableSubsidies(uint128 epoch, uint128[] calldata poolIds, address verifier, address verifierAssetManager) external view returns (uint128, uint128[] memory) {
        require(verifier != address(0), Errors.InvalidAddress());
        require(verifierAssetManager != address(0), Errors.InvalidAddress());

        uint256 numOfPools = poolIds.length;
        _requireNonEmptyArray(numOfPools);

        DataTypes.Epoch storage epochPtr = epochs[epoch];
        _assertSubsidyClaimWindow(epochPtr);

        // counters
        uint128 totalClaimable;
        uint128[] memory perPoolClaimable = new uint128[](numOfPools);

        for (uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];

            if (verifierEpochPoolSubsidies[epoch][poolId][verifier] != 0) continue;

            uint128 poolAllocatedSubsidies = epochPools[epoch][poolId].totalSubsidiesAllocated;
            if (poolAllocatedSubsidies == 0) continue;

            (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) =
                PAYMENTS_CONTROLLER.getVerifierAndPoolAccruedSubsidies(epoch, poolId, verifier, verifierAssetManager);

            if (poolAccruedSubsidies == 0 || verifierAccruedSubsidies == 0) continue;
            require(verifierAccruedSubsidies <= poolAccruedSubsidies, Errors.VerifierAccruedSubsidiesGreaterThanPool());

            uint256 ratio = (verifierAccruedSubsidies * 1E18) / poolAccruedSubsidies;
            uint128 subsidyReceivable = uint128((ratio * poolAllocatedSubsidies) / 1E18);
            if (subsidyReceivable == 0) continue;

            perPoolClaimable[i] = subsidyReceivable;
            totalClaimable += subsidyReceivable;
        }

        return (totalClaimable, perPoolClaimable);
    }

}
