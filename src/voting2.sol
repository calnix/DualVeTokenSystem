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


    // global counter: subsidies
    uint128 public TOTAL_SUBSIDIES_DEPOSITED;
    uint128 public TOTAL_SUBSIDIES_CLAIMED;

    // global counter: rewards
    uint128 public TOTAL_REWARDS_DEPOSITED;
    uint128 public TOTAL_REWARDS_CLAIMED;

    // global counter: pools
    uint128 public TOTAL_POOLS_CREATED;
    uint128 public TOTAL_ACTIVE_POOLS;

    // delegate
    uint128 public DELEGATE_REGISTRATION_FEE;           // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint128 public MAX_DELEGATE_FEE_PCT;                // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint128 public FEE_INCREASE_DELAY_EPOCHS;           // in epochs
    
    // global counter: registration fees [native NOCA]
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
    mapping(address verifier => uint256 totalSubsidies) public verifierData;                  
    mapping(uint128 epoch => mapping(address verifier => uint256 totalSubsidies)) public verifierEpochSubsidies;
    mapping(uint128 epoch => mapping(uint128 poolId => mapping(address verifier => uint128 totalSubsidies))) public verifierEpochPoolSubsidies;


//-------------------------------Constructor------------------------------------------

    constructor(
        uint128 maxDelegateFeePct, uint128 feeDelayEpochs, uint128 unclaimedDelayEpochs, address wMoca_, uint128 mocaTransferGasLimit, 
        address votingEscrowMoca_, address escrowedMoca_, address votingControllerTreasury_, address paymentsController_,
        address globalAdmin, address votingControllerAdmin, address monitorAdmin, address cronJobAdmin,
        address monitorBot, address emergencyExitHandler, address assetManager
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
        require(feeDelayEpochs > 0, Errors.InvalidDelayPeriod());
        FEE_INCREASE_DELAY_EPOCHS = feeDelayEpochs;

        require(unclaimedDelayEpochs > 0, Errors.InvalidDelayPeriod());
        UNCLAIMED_DELAY_EPOCHS = unclaimedDelayEpochs;

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
        _setupRoles(globalAdmin, votingControllerAdmin, monitorAdmin, cronJobAdmin, monitorBot, emergencyExitHandler, assetManager);
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

//------------------------------- Voting functions------------------------------------------

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
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == poolVotes.length, Errors.MismatchedArrayLengths());

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

        // votingPower: benchmarked to end of epoch [forward-decay]
        // get account's voting power[personal, delegated] and used votes
        uint128 totalVotes = VEMOCA.balanceAtEpochEnd(msg.sender, currentEpoch, isDelegated);
        uint128 spentVotes = accountEpochData[currentEpoch][msg.sender].totalVotesSpent; 

        // check if account has available votes 
        uint128 availableVotes = totalVotes - spentVotes;
        require(availableVotes > 0, Errors.NoAvailableVotes());

        // update votes at a pool+epoch level | account:{personal,delegate}
        // does not check for duplicate poolIds in the array; users can vote repeatedly for the same pool
        uint128 totalNewVotes;
        for(uint256 i; i < poolIds.length; ++i) {
            uint128 poolId = poolIds[i];
            uint128 votes = poolVotes[i];

            // sanity check: do not skip on 0 vote, as it indicates incorrect array inputs
            require(votes > 0, Errors.ZeroVotes()); 
            
            // cache pool pointer
            DataTypes.Pool storage poolPtr = pools[poolId];

            // sanity checks: pool is active
            require(poolPtr.isActive, Errors.PoolNotActive());
            
            // increment counter & sanity check: cannot exceed available votes
            totalNewVotes += votes;
            require(totalNewVotes <= availableVotes, Errors.InsufficientVotes());

            // increment account's votes [epoch-pool]
            accountEpochPoolData[currentEpoch][poolId][msg.sender].totalVotesSpent += votes;

            // increment pool votes [epoch, pool]
            epochPools[currentEpoch][poolId].totalVotes += votes;
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
    function migrateVotes(uint128[] calldata srcPoolIds, uint128[] calldata dstPoolIds, uint128[] calldata poolVotes, bool isDelegated) external whenNotPaused {
        // sanity check: array lengths must be non-empty and match
        uint256 length = srcPoolIds.length;
        require(length > 0, Errors.InvalidArray());
        require(length == dstPoolIds.length, Errors.MismatchedArrayLengths());
        require(length == poolVotes.length, Errors.MismatchedArrayLengths());

        // get current epoch & cache epoch pointer
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();          
        DataTypes.Epoch storage epochPtr = epochs[currentEpoch];

        // epoch is being finalized: no more votes allowed
        require(!epochPtr.isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // executed each time, since delegate fee decreases are instantly applied
        if (isDelegated) _validateDelegateAndRecordFee(currentEpoch);


        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint128 => mapping(uint128 => mapping(address => DataTypes.Account))) storage accountEpochPoolData  
        = isDelegated ? delegatesEpochPoolData : usersEpochPoolData;
   

        // can migrate votes from inactive pool to active pool; but not vice versa
        for(uint256 i; i < length; ++i) {
            // cache: calldata access per array element
            uint128 srcPoolId = srcPoolIds[i];
            uint128 dstPoolId = dstPoolIds[i];
            uint128 votesToMigrate = poolVotes[i];

            // sanity check: do not skip on 0 vote, as it indicates incorrect array inputs
            require(votesToMigrate > 0, Errors.ZeroVotes());
            require(srcPoolId != dstPoolId, Errors.InvalidPoolPair());

            // Cache storage pointers
            DataTypes.Pool storage srcPoolPtr = pools[srcPoolId];
            DataTypes.Pool storage dstPoolPtr = pools[dstPoolId];
            DataTypes.PoolEpoch storage srcEpochPoolPtr = epochPools[currentEpoch][srcPoolId];
            DataTypes.PoolEpoch storage dstEpochPoolPtr = epochPools[currentEpoch][dstPoolId];

            // sanity check: dstPool is active [src pool can be inactive]
            require(dstPoolPtr.isActive, Errors.PoolNotActive());

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

//------------------------------- Claiming rewards & fees functions ----------------------------------------------

    //note: Pool may be inactive but still have unclaimed prior rewards
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
    function claimPersonalRewards(uint128 epoch, uint128[] calldata poolIds) external whenNotPaused {
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());

        // epoch must be finalized
        require(epochs[epoch].isEpochFinalized, Errors.EpochNotFinalized());

        // rewards must not have been withdrawn for this epoch
        require(!epochs[epoch].isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());


        uint128 userTotalRewards;

        for(uint256 i; i < numOfPools; ++i) {
            uint128 poolId = poolIds[i];
            
            // prevent double claiming
            require(usersEpochPoolData[epoch][poolId][msg.sender].totalRewards == 0, Errors.AlreadyClaimedOrNoRewardsToClaim()); 

            uint128 poolRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            uint128 userVotes = usersEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent;

            // Skip pools with zero rewards or zero user votes
            if(poolRewards == 0 || userVotes == 0) continue;

            // get total votes for the pool
            uint128 poolTotalVotes = epochPools[epoch][poolId].totalVotes;

            // Calculate user's rewards for the pool 
            uint128 userRewards = (userVotes * poolRewards) / poolTotalVotes;
            if(userRewards == 0) continue;
            
            // Set user's totalRewards for this pool
            usersEpochPoolData[epoch][poolId][msg.sender].totalRewards = userRewards;

            // Update counter
            userTotalRewards += userRewards;
        }

        require(userTotalRewards > 0, Errors.NoRewardsToClaim());
        
        // Increment user's total rewards for this epoch
        usersEpochData[epoch][msg.sender].totalRewards += userTotalRewards;

        // Increment epoch & global total claimed
        epochs[epoch].totalRewardsClaimed += userTotalRewards;
        TOTAL_REWARDS_CLAIMED += userTotalRewards;

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, userTotalRewards);

        // transfer esMoca to user
        ESMOCA.safeTransfer(msg.sender, userTotalRewards);
    }

    /**
     * @notice Claim NET rewards from delegated voting across multiple delegates
     * @param epoch The epoch to claim from
     * @param delegateList Array of delegates to claim from
     * @param poolIds 2D array of pool IDs per delegate to process
    */
    function claimRewardsFromDelegates(uint128 epoch, address[] calldata delegateList, uint128[][] calldata poolIds) external whenNotPaused {
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());
        
        uint256 numOfDelegates = delegateList.length;
        require(numOfDelegates > 0, Errors.InvalidArray());
        require(numOfDelegates == poolIds.length, Errors.MismatchedArrayLengths());
        
        uint128 totalClaimable;
        
        for (uint256 i; i < numOfDelegates; ++i) {
            address delegate = delegateList[i];
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
        
        emit Events.RewardsClaimedFromDelegateBatch(epoch, msg.sender, delegateList, poolIds, totalClaimable);
        
        ESMOCA.safeTransfer(msg.sender, totalClaimable);
    }

    /**
     * @notice Claim delegate FEES from multiple delegators
     * @param epoch The epoch to claim from
     * @param delegators Array of delegators to claim fees from
     * @param poolIds 2D array of pool IDs per delegator to process
    */
    function delegateClaimFees(uint128 epoch, address[] calldata delegators, uint128[][] calldata poolIds) external whenNotPaused {
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());
        
        uint256 numOfDelegators = delegators.length;
        require(numOfDelegators > 0, Errors.InvalidArray());
        require(numOfDelegators == poolIds.length, Errors.MismatchedArrayLengths());
        
        uint128 totalClaimable;
        
        for (uint256 i; i < numOfDelegators; ++i) {
            address delegator = delegators[i];
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
        
        // Update delegate's global claimed counter
        delegates[msg.sender].totalFeesClaimed += totalClaimable;
        
        // Update epoch-level tracking
        epochPtr.totalRewardsClaimed += totalClaimable;
        TOTAL_REWARDS_CLAIMED += totalClaimable;
        
        emit Events.DelegateFeesClaimed(epoch, msg.sender, totalClaimable);
        
        ESMOCA.safeTransfer(msg.sender, totalClaimable);
    }


//------------------------------- Verifier: claimSubsidies function ----------------------------------------------
    
    //note: subsidies can only be claimed once per pool per epoch, per verifier. 
    //      mirroring that, subsidies can only be deposited once per epoch.
    /**
     * @notice Claims verifier subsidies for specified pools in a given epoch.
     * @dev Subsidies are claimable based on the verifier's expenditure accrued for each pool-epoch.
     *      Only the `assetAddress` of the verifier (as registered in PaymentsController) can call this function.
     * @param epoch The epoch number for which subsidies are being claimed.
     * @param verifier The address of the verifier for which to claim subsidies.
     * @param poolIds Array of pool identifiers for which to claim subsidies.
     *
     * Requirements:
     * - The epoch must be fully finalized.
     * - Each poolId must exist and have allocated subsidies.
     */
    function claimSubsidies(uint128 epoch, address verifier, uint128[] calldata poolIds) external whenNotPaused {
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());
        
        // epoch must be finalized
        require(epochs[epoch].isEpochFinalized, Errors.EpochNotFinalized());
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

            // poolAccruedSubsidies == 0 will revert on division; verifierAccruedSubsidies == 0 will be skipped | no need for checks

            // calculate ratio and rebase it to 18dp in single step [ratio is in 18dp precision]
            uint256 ratio = (verifierAccruedSubsidies * 1E18) / poolAccruedSubsidies; 
            
            // calculate esMoca subsidy receivable [poolAllocatedSubsidies in 1e18 precision]
            uint128 subsidyReceivable = uint128((ratio * poolAllocatedSubsidies) / 1E18); 
            
            if(subsidyReceivable == 0) continue;  


            // update counter
            totalSubsidiesClaimed += subsidyReceivable;

            // book verifier's subsidy receivable for the {pool, epoch}
            verifierEpochPoolSubsidies[epoch][poolId][verifier] = subsidyReceivable;
        }

        if(totalSubsidiesClaimed == 0) revert Errors.NoSubsidiesToClaim();

        // update verifier's epoch & global total claimed
        verifierData[verifier] += totalSubsidiesClaimed;
        verifierEpochSubsidies[epoch][verifier] += totalSubsidiesClaimed;

        // update global & epoch total claimed
        TOTAL_SUBSIDIES_CLAIMED += totalSubsidiesClaimed;
        epochs[epoch].totalSubsidiesClaimed += totalSubsidiesClaimed;

        
        emit Events.SubsidiesClaimed(verifier, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier's asset address
        ESMOCA.safeTransfer(msg.sender, totalSubsidiesClaimed);      
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

        //fee percentage must be less than or equal to the maximum allowed fee
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidPercentage());

        // delegate must not be registered
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];
        require(!delegatePtr.isRegistered, Errors.DelegateAlreadyRegistered());
        
        // register on VotingEscrowMoca | if delegate is already registered on VotingEscrowMoca -> reverts
        VEMOCA.delegateRegistrationStatus(msg.sender, true);

        // storage: register delegate + set fee percentage
        delegatePtr.isRegistered = true;
        delegatePtr.currentFeePct = feePct;
        delegateHistoricalFeePcts[msg.sender][EpochMath.getCurrentEpochNumber()] = feePct;
        
        // update registration fees collected
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
        // fee percentage must be less than or equal to the maximum allowed fee
        require(newFeePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());   

        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];

        // delegate must be registered
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint128 currentFeePct = delegatePtr.currentFeePct;

        // if increase, only applicable from currentEpoch+FEE_INCREASE_DELAY_EPOCHS
        if(newFeePct < currentFeePct) {

            // fee decreased: apply immediately
            delegatePtr.currentFeePct = newFeePct;
            delegateHistoricalFeePcts[msg.sender][currentEpoch] = newFeePct;

            // delete pending
            delete delegatePtr.nextFeePct;
            delete delegatePtr.nextFeePctEpoch;

            emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, newFeePct);

        } else { // fee increased: schedule increase

            delegatePtr.nextFeePct = newFeePct;
            delegatePtr.nextFeePctEpoch = currentEpoch + FEE_INCREASE_DELAY_EPOCHS;

            // set for future epoch
            delegateHistoricalFeePcts[msg.sender][delegatePtr.nextFeePctEpoch] = newFeePct;  

            emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, newFeePct, delegatePtr.nextFeePctEpoch);
        }
    }

    //Note: when an delegate unregisters, we still need to be able to log his historical fees for users to claim them
    /**
     * @notice Unregister the caller as a delegate.
     * @dev Removes the delegate's registration status.
     *      Calls VotingEscrowMoca.unregisterAsDelegate() to mark the delegate as inactive.
     *      Registration fee is not refunded
     */
    function unregisterAsDelegate() external whenNotPaused {
        DataTypes.Delegate storage delegatePtr = delegates[msg.sender];
        
        // delegate must be registered
        require(delegatePtr.isRegistered, Errors.NotRegisteredAsDelegate());

        // delegate must not have active votes
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(delegateEpochData[currentEpoch][msg.sender].totalVotesSpent == 0, Errors.CannotUnregisterWithActiveVotes());
 
        // storage: unregister delegate
        delete delegatePtr.isRegistered;

        // event
        emit Events.DelegateUnregistered(msg.sender);

        // to mark as false
        VEMOCA.delegateRegistrationStatus(msg.sender, false);
    }

//------------------------------- VotingControllerAdmin: pool functions----------------------------------------------------

    /**
     * @notice Creates a new voting pool and returns its unique identifier.
     * @dev Callable only by VotingController admin. Ensures poolId uniqueness by regenerating if a collision is detected.
     *      Pool creation is blocked during active end-of-epoch operations to maintain protocol consistency.
     *      Increments the global pool counter on successful creation.
     */
    function createPool() external whenNotPaused onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) {
        // prevent pool creation during epoch finalization
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(!epochs[currentEpoch].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());

        // ensure previous epoch is finalized
        if (currentEpoch > 0) {
            uint128 previousEpoch = currentEpoch - 1;
            require(epochs[previousEpoch].isEpochFinalized, Errors.EpochNotFinalized());
        }

        // get poolId
        uint128 poolId = ++TOTAL_POOLS_CREATED;

        // set pool as active
        pools[poolId].isActive = true;

        // increment global counter
        ++TOTAL_ACTIVE_POOLS;

        // event
        emit Events.PoolCreated(poolId);
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
     * This prevents inconsistencies in `TOTAL_NUMBER_OF_ACTIVE_POOLS` during end-of-epoch operations.
     * Removing a pool after subsidies are deposited could cause the epoch finalization check
     * (`poolsFinalized == TOTAL_NUMBER_OF_ACTIVE_POOLS`) to fail, blocking epoch finalization.
     *
     * Once subsidies are deposited for the current epoch, pool removal is blocked to maintain a static pool set
     * during end-of-epoch processing.
     *
     * @param poolId Unique identifier of the pool to be removed.
     */
    function removePool(uint128 poolId) external onlyRole(Constants.VOTING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(pools[poolId].isActive, Errors.PoolNotActive());


        // prevent pool removal during epoch finalization
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        require(!epochs[currentEpoch].isSubsidiesSet, Errors.EndOfEpochOpsUnderway());


        // ensure for previous epoch, epoch is finalized
        if (currentEpoch > 0) {
            uint128 previousEpoch = currentEpoch - 1;
            require(epochs[previousEpoch].isEpochFinalized, Errors.EpochNotFinalized());
        }

        // set pool as inactive
        delete pools[poolId].isActive;

        // decrement global counter
        --TOTAL_ACTIVE_POOLS;

        emit Events.PoolRemoved(poolId);
    }

//------------------------------- CronJob Role: depositEpochSubsidies, finalizeEpochRewardsSubsidies -----------------------------------------
    
    //note: use cronjob instead of asset manager, due to frequency of calls
    //      assets are transferred from treasury directly to VotingController contract.
    //      this would require treasury address setting approvals to VotingController contract.

    /**
     * @notice Deposits esMOCA subsidies for a completed epoch to be distributed among pools based on votes.
     * @dev Callable only by CronJobRole. Calculates and sets subsidy per vote for the epoch.
     *      Transfers esMOCA from the caller to the contract if subsidies > 0 and epoch.totalVotes > 0.
     *      Can only be called after the epoch has ended and before it is finalized.
     *      Subsidies can be 0.
     * @param epoch The epoch number for which to deposit subsidies.
     * @param subsidies The total amount of esMOCA subsidies to deposit (1e18 precision).
     */
    function depositEpochSubsidies(uint128 epoch, uint128 subsidies) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        // epoch must have ended
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp > epochEndTimestamp, Errors.EpochNotEnded());

        // epoch must not be finalized
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        require(!epochPtr.isEpochFinalized, Errors.EpochFinalized());

        // subsidies can only be set once per epoch
        require(!epochPtr.isSubsidiesSet, Errors.SubsidiesAlreadySet());

        // set totalSubsidiesDeposited + transfer esMoca
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
        // else: subsidies = 0 and/or no votes, flag is still set

        // set flag & log total active pools
        epochPtr.isSubsidiesSet = true;
        epochPtr.totalActivePools = TOTAL_ACTIVE_POOLS;

        emit Events.SubsidiesSet(epoch, subsidies);
    }


   //Note: pools tt were marked inactive will not be processed. If users did not migrate votes from removed pools, this will result in lost rewards and subsidies.
    /**
     * @notice Finalizes rewards and subsidies allocation for pools in a given epoch.
     * @dev Callable only by CronJobRole.
     *   - Callable only once, per pool per epoch.
     *   - Subsidies are set from depositEpochSubsidies(). Rewards are decided by Protocol.
     *   - Only deposits rewards that can be claimed (i.e., poolRewards > 0 and poolVotes > 0).
     *   - The sum of input rewards may be less than or equal to totalRewardsAllocated.
     * @param epoch The epoch number to finalize.
     * @param poolIds Array of pool IDs to finalize for the epoch.
     * @param rewards Array of reward amounts (1e18 precision) corresponding to each pool.
     * Requirements:
     *   - Epoch must have ended and not be finalized.
     *   - Subsidies must have been set for the epoch.
     *   - Each pool must be active for the epoch, and not previously processed.
     */
    function processEpochRewardsSubsidies(uint128 epoch, uint128[] calldata poolIds, uint128[] calldata rewards) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        uint256 numOfPools = poolIds.length;
        require(numOfPools > 0, Errors.InvalidArray());
        require(numOfPools == rewards.length, Errors.MismatchedArrayLengths());

        // check: epoch must have ended
        uint128 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp > epochEndTimestamp, Errors.EpochNotEnded());

        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // check: depositEpochSubsidies() must have been called prior
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
                uint128 poolSubsidies = (poolVotes * epochTotalSubsidiesAllocated) / epochTotalVotes;
                
                // if poolSubsidies > 0: update pool & epochpool: totalSubsidiesAllocated
                if(poolSubsidies > 0) { 
                    // storage updates
                    poolPtr.totalSubsidiesAllocated += poolSubsidies;
                    epochPoolPtr.totalSubsidiesAllocated = poolSubsidies;                    
                }

                // if pool rewards > 0: update pool & epochpool: totalRewardsAllocated
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

        // check if epoch will be fully finalized
        uint128 totalPoolsFinalized = epochPtr.poolsProcessed += uint128(numOfPools);
        bool isFullyProcessed = totalPoolsFinalized == epochPtr.totalActivePools;

        if(isFullyProcessed) {
            epochPtr.isFullyProcessed = true;
            emit Events.PoolsProcessed(epoch, poolIds);
            emit Events.EpochFullyProcessed(epoch);
        } else{           
            emit Events.PoolsProcessed(epoch, poolIds);
        }
    }

    
    function depositRewards(uint128 epoch) external onlyRole(Constants.CRON_JOB_ROLE) whenNotPaused {
        // cache: epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];
        
        // epoch must be finalized
        require(epochPtr.isFullyProcessed, Errors.EpochNotFinalized());
        
        // rewards must not be deposited yet
        require(!epochPtr.isEpochFinalized, Errors.RewardsAlreadyDeposited());

        // cache: total rewards
        uint128 totalRewards = epochPtr.totalRewardsAllocated;

        // set flag: epoch finalized
        epochPtr.isEpochFinalized = true;
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
    }

//------------------------------- AssetManager Role: withdrawUnclaimedRewards, withdrawUnclaimedSubsidies -----------------------------------------
    
    /**
     * @notice Sweep all unclaimed and residual voting rewards for a given epoch to the treasury.
     * @dev Can only be called by a VotingController admin after a delay defined by UNCLAIMED_DELAY_EPOCHS epochs.
     *      Transfers both unclaimed and residual (unclaimable flooring losses) esMoca rewards to voting controller treasury.
     *      Reverts if the epoch is not finalized, the voting controller treasury address is unset, or there are no unclaimed rewards to sweep.
     * @param epoch The epoch number for which to sweep unclaimed and residual rewards.
     */
    function withdrawUnclaimedRewards(uint128 epoch) external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // sanity check: withdraw delay must have passed
        require(EpochMath.getCurrentEpochNumber() > epoch + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // cache: epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // epoch must be finalized & rewards must not have been withdrawn yet
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.isRewardsWithdrawn, Errors.RewardsAlreadyWithdrawn());  

        // unclaimed rewards must be greater than 0
        uint128 unclaimedRewards = epochPtr.totalRewardsAllocated - epochPtr.totalRewardsClaimed;
        require(unclaimedRewards > 0, Errors.NoUnclaimedRewardsToWithdraw());

        // book unclaimed rewards
        epochPtr.totalRewardsUnclaimed = unclaimedRewards;
        
        // set flag to block future claims
        epochPtr.isRewardsWithdrawn = true;

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        emit Events.UnclaimedRewardsWithdrawn(votingControllerTreasury, epoch, unclaimedRewards);

        ESMOCA.safeTransfer(votingControllerTreasury, unclaimedRewards);
    }

    /**
     * @notice Sweep all unclaimed and residual subsidies for a specified epoch to the treasury.
     * @dev Can only be called by a VotingController admin after a delay defined by UNCLAIMED_DELAY_EPOCHS epochs.
     *      Transfers both unclaimed and residual (unclaimable flooring losses) esMoca subsidies to voting controller treasury.
     *      Reverts if the epoch is not finalized, the delay has not passed, the voting controller treasury address is unset, or there are no unclaimed subsidies to sweep.
     * @param epoch The epoch number for which to sweep unclaimed and residual subsidies.
     */
    function withdrawUnclaimedSubsidies(uint128 epoch) external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        // sanity check: withdraw delay must have passed
        require(EpochMath.getCurrentEpochNumber() > epoch + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyWithdrawUnclaimedAfterDelay());

        // cache: epoch pointer
        DataTypes.Epoch storage epochPtr = epochs[epoch];

        // epoch must be finalized & subsidies must not have been withdrawn yet
        require(epochPtr.isEpochFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.isSubsidiesWithdrawn, Errors.SubsidiesAlreadyWithdrawn());

        // unclaimed subsidies must be greater than 0
        uint128 unclaimedSubsidies = epochPtr.totalSubsidiesAllocated - epochPtr.totalSubsidiesClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // book unclaimed subsidies
        epochPtr.totalSubsidiesUnclaimed = unclaimedSubsidies;
        epochPtr.isSubsidiesWithdrawn = true;

        // get treasury address
        address votingControllerTreasury = VOTING_CONTROLLER_TREASURY;
        require(votingControllerTreasury != address(0), Errors.InvalidAddress());

        emit Events.UnclaimedSubsidiesWithdrawn(votingControllerTreasury, epoch, unclaimedSubsidies);


        ESMOCA.safeTransfer(votingControllerTreasury, unclaimedSubsidies);
    }

    // note: treasury address should be able to handle both wMoca and Moca
    /**
     * @notice Withdraws all unclaimed registration fees to the voting controller treasury.
     * @dev Can only be called by a VotingController admin
     *      Reverts if the voting controller treasury address is unset, or there are no unclaimed registration fees to withdraw.
     */
    function withdrawRegistrationFees() external onlyRole(Constants.ASSET_MANAGER_ROLE) whenNotPaused {
        uint256 unclaimedRegistrationFees = TOTAL_REGISTRATION_FEES_COLLECTED - TOTAL_REGISTRATION_FEES_CLAIMED;
        require(unclaimedRegistrationFees > 0, Errors.NoRegistrationFeesToWithdraw());

        // book unclaimed registration fees
        TOTAL_REGISTRATION_FEES_CLAIMED = TOTAL_REGISTRATION_FEES_COLLECTED;

        // get treasury address
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
     * @notice Applies the pending delegate fee increase if the scheduled epoch has started.
     * @dev If the current epoch is greater than or equal to the delegate's nextFeePctEpoch,
     *      updates currentFeePct, sets the historical fee for the current epoch, and clears pending fields.
     * @param delegate The address of the delegate whose fee may be updated.
     * @param currentEpoch The current epoch number.
     * @return True if a pending fee was applied and historical fee set, false otherwise.
     */
    function _applyPendingFeeIfNeeded(address delegate, uint128 currentEpoch) internal returns (bool) {
        DataTypes.Delegate storage delegatePtr = delegates[delegate];

        // if there is a pending fee increase, apply it
        if(delegatePtr.nextFeePctEpoch > 0) {
            if(currentEpoch >= delegatePtr.nextFeePctEpoch) {
                
                // update currentFeePct and set the historical fee for the current epoch
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;
                delegateHistoricalFeePcts[delegate][currentEpoch] = delegatePtr.currentFeePct;  // Ensure set for claims
                
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
                // apply pending fee increase
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;
                
                // reset pending fields
                delete delegatePtr.nextFeePct;
                delete delegatePtr.nextFeePctEpoch;
            }
            
            // record current fee for this epoch (whether just updated or existing)
            delegateHistoricalFeePcts[msg.sender][currentEpoch] = delegatePtr.currentFeePct;
        }
    }


    /**
     * @notice Internal function to process pools and claim rewards
     * @dev Processing phase: calculates and stores rewards for unprocessed pools
     *      Claiming phase: transfers delta between total and already-claimed
     * @param epoch The epoch to claim from
     * @param user The user who delegated
     * @param delegate The delegate who voted
     * @param poolIds Array of pool IDs to process
     * @param isUserClaiming True if user claiming NET, false if delegate claiming FEES
     * @return totalClaimable Amount to transfer to caller
     */
    function _claimRewardsInternal(uint128 epoch, address user, address delegate, uint128[] calldata poolIds, bool isUserClaiming) internal returns (uint128) {
        
        // get delegate fee percentage [could be 0 if delegate did not vote this epoch]
        uint128 delegateFeePct = delegateHistoricalFeePcts[delegate][epoch];
        
        // get user-delegate pair accounting
        DataTypes.UserDelegateAccount storage pairAccount = userDelegateAccounting[epoch][user][delegate];  
        
        // Track newly processed amounts in this call
        uint128 newGrossProcessed;
        uint128 newFeesProcessed;
        
       // ═══════════════════════════════════════════════════════════════════
       // PROCESSING PHASE: Calculate rewards for unprocessed pools
       // ═══════════════════════════════════════════════════════════════════
        for (uint256 i; i < poolIds.length; ++i) {
            uint128 poolId = poolIds[i];
            
            // Skip if already processed
            if (pairAccount.poolProcessed[poolId]) continue;
            
            // Mark as processed (prevents re-processing even if gross = 0)
            pairAccount.poolProcessed[poolId] = true;
            
            // Pool must have rewards & votes; else skip
            uint128 totalPoolRewards = epochPools[epoch][poolId].totalRewardsAllocated;
            uint128 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            if (totalPoolRewards == 0 || totalPoolVotes == 0) continue;
            
            // Delegate must have voted in this pool
            uint128 delegatePoolVotes = delegatesEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
            if (delegatePoolVotes == 0) continue;
            
            // Calculate delegate's share of pool rewards
            uint128 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
            if (delegatePoolRewards == 0) continue;
            
            // book delegate's rewards for this {pool, epoch}
            delegatesEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;
            
            // Get: user's delegated voting power & delegate's total voting power
            uint128 userDelegatedVP = VEMOCA.getSpecificDelegatedBalanceAtEpochEnd(user, delegate, epoch);
            uint128 delegateTotalVP = VEMOCA.balanceAtEpochEnd(delegate, epoch, true);
            if (delegateTotalVP == 0) continue;
            
            // calc. user's gross rewards for the pool
            uint128 userGrossRewardsForPool = (userDelegatedVP * delegatePoolRewards) / delegateTotalVP;
            if (userGrossRewardsForPool == 0) continue;
            
            // book user's gross rewards for this {pool, epoch}
            pairAccount.userPoolGrossRewards[poolId] = userGrossRewardsForPool;
            
            // calc. delegate's fee for this pool [could be 0 if delegate did not vote this epoch]
            uint128 delegateFeeForPool = (userGrossRewardsForPool * delegateFeePct) / uint128(Constants.PRECISION_BASE);
            
            // update counters
            newGrossProcessed += userGrossRewardsForPool;
            newFeesProcessed += delegateFeeForPool;
        }
        
        // ═══════════════════════════════════════════════════════════════════
        // UPDATE AGGREGATE TOTALS (for newly processed pools only)
        // ═══════════════════════════════════════════════════════════════════
        if (newGrossProcessed > 0) {
            // update user-delegate account aggregates
            pairAccount.totalGrossRewards += newGrossProcessed;
            pairAccount.totalDelegateFees += newFeesProcessed;
            pairAccount.totalNetRewards += (newGrossProcessed - newFeesProcessed);
            
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
            totalClaimable = pairAccount.totalNetRewards - pairAccount.userClaimed;
            if (totalClaimable > 0) pairAccount.userClaimed = pairAccount.totalNetRewards;
                
        } else {

            // calc. delegate's total fees - already claimed
            totalClaimable = pairAccount.totalDelegateFees - pairAccount.delegateClaimed;
            if (totalClaimable > 0) pairAccount.delegateClaimed = pairAccount.totalDelegateFees;
        }
        
        return totalClaimable;
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







}
