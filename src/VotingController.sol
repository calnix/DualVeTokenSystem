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
    uint256 public TOTAL_REGISTRATION_FEES;    // total registration fees collected

//-------------------------------mapping------------------------------------------

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
    mapping(uint256 epoch => mapping(address user => mapping(address delegate => DataTypes.UserDelegateAccount userDelegateAccount))) public userDelegateAccounting;


    // Delegate registration data + fee data
    mapping(address delegate => DataTypes.Delegate delegate) public delegates;     
    // if 0: fee not set for that epoch      
    mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFees;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)


    // verifier | note: optional: drop verifierData | verifierEpochData | if we want to streamline storage. only verifierEpochPoolData is mandatory
    // epoch is epoch number, not timestamp
    mapping(address verifier => uint256 totalSubsidies) public verifierData;                  
    mapping(uint256 epoch => mapping(address verifier => uint256 totalSubsidies)) public verifierEpochData;
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifier => uint256 totalSubsidies))) public verifierEpochPoolData;
    

//-------------------------------constructor------------------------------------------

    constructor(address addressBook) {
        ADDRESS_BOOK = IAddressBook(addressBook);

        // initial unclaimed delay set to 6 epochs [review: make immutable?]
        UNCLAIMED_DELAY_EPOCHS = EpochMath.EPOCH_DURATION() * 6;
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
    function vote(bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external {

        // sanity check: poolIds & poolVotes must be non-empty and have the same length
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == poolVotes.length, Errors.MismatchedArrayLengths());

        // epoch should not be finalized
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();          
        require(!epochs[currentEpoch].isFullyFinalized, Errors.EpochFinalized());

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
            if(delegateHistoricalFees[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                if(!pendingFeeApplied) {
                    delegateHistoricalFees[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
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
            require(votes > 0, Errors.ZeroVote()); 
            
            // sanity checks: pool exists, is active
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(pools[poolId].isActive, Errors.PoolInactive());
            
            // sanity check: available votes should not be exceeded
            totalNewVotes += votes;
            require(totalNewVotes <= availableVotes, Errors.InsufficientVotes());

            // increment votes at a pool+epoch level | account:{personal,delegate}
            accountEpochPoolData[currentEpoch][poolId][msg.sender].totalVotesSpent += votes;
            epochPools[currentEpoch][poolId].totalVotes += votes;
            epochs[currentEpoch].totalVotes += votes;

            //increment pool votes at a global level
            pools[poolId].totalVotes += votes;       
        }

        // update account's epoch totalVotesSpent counter
        accountEpochData[currentEpoch][msg.sender].totalVotesSpent += totalNewVotes;
        
        emit Events.Voted(currentEpoch, msg.sender, poolIds, poolVotes, isDelegated);
    }

    //TODO: router friendly
    /**
     * @notice Migrate votes from one or more source pools to destination pools within the current epoch.
     * @dev Allows users to move their votes between pools before the epoch is finalized.
     *      Supports both partial and full vote migration. Can migrate from inactive to active pools, but not vice versa.
     * @param srcPoolIds Array of source pool IDs from which votes will be migrated.
     * @param dstPoolIds Array of destination pool IDs to which votes will be migrated.
     * @param poolVotes Array of vote amounts to migrate for each pool pair.
     * @param isDelegated Boolean indicating if the migration is for delegated votes.
     * If isDelegated: true, caller must be registered as delegate
     * Emits a {VotesMigrated} event on success.
     * Reverts if input array lengths mismatch, pools do not exist, destination pool is not active,
     * insufficient votes in source pool, or epoch is finalized.
     */
    function migrateVotes(bytes32[] calldata srcPoolIds, bytes32[] calldata dstPoolIds, uint128[] calldata poolVotes, bool isDelegated) external {
        require(srcPoolIds.length > 0, Errors.InvalidArray());
        require(srcPoolIds.length == dstPoolIds.length, Errors.MismatchedArrayLengths());
        require(srcPoolIds.length == poolVotes.length, Errors.MismatchedArrayLengths());

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
            if(delegateHistoricalFees[msg.sender][currentEpoch] == 0) {
                bool pendingFeeApplied = _applyPendingFeeIfNeeded(msg.sender, currentEpoch);
                if(!pendingFeeApplied) {
                    delegateHistoricalFees[msg.sender][currentEpoch] = delegates[msg.sender].currentFeePct;
                }
            }

        } else {
            accountEpochData = usersEpochData;
            accountEpochPoolData = usersEpochPoolData;
        }

        // can migrate votes from inactive pool to active pool; but not vice versa
        for(uint256 i; i < srcPoolIds.length; ++i) {
            bytes32 srcPoolId = srcPoolIds[i];
            bytes32 dstPoolId = dstPoolIds[i];
            uint128 votesToMigrate = poolVotes[i];

            // sanity check: both pools exist + dstPool is active
            require(pools[srcPoolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(pools[dstPoolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(pools[dstPoolId].isActive, Errors.PoolInactive());

            // get user's existing votes in srcPool | must be greater than or equal to votesToMigrate
            uint128 votesInSrcPool = accountEpochPoolData[epoch][srcPoolId][msg.sender].totalVotesSpent;
            require(votesInSrcPool >= votesToMigrate, Errors.InsufficientVotes());

            // deduct from old pool
            accountEpochPoolData[epoch][srcPoolId][msg.sender].totalVotesSpent -= votesToMigrate;
            epochPools[epoch][srcPoolId].totalVotes -= votesToMigrate;
            pools[srcPoolId].totalVotes -= votesToMigrate;

            // add to new pool
            accountEpochPoolData[epoch][dstPoolId][msg.sender].totalVotesSpent += votesToMigrate;
            epochPools[epoch][dstPoolId].totalVotes += votesToMigrate;
            pools[dstPoolId].totalVotes += votesToMigrate;

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
    function registerAsDelegate(uint128 feePct) external {
        require(feePct > 0, Errors.InvalidFeePct());
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());    // 0 allowed

        Delegate storage delegate = delegates[msg.sender];
        require(!delegate.isRegistered, Errors.DelegateAlreadyRegistered());

        // register on VotingEscrowMoca | if delegate is already registered on VotingEscrowMoca -> reverts
        _veMoca().registerAsDelegate(msg.sender);

        // collect registration fee & increment global counter
        _moca().safeTransferFrom(msg.sender, address(this), REGISTRATION_FEE);
        TOTAL_REGISTRATION_FEES += REGISTRATION_FEE;

        // storage: register delegate + set fee percentage
        delegate.isRegistered = true;
        delegate.currentFeePct = feePct;
        delegateHistoricalFees[msg.sender][currentEpoch] = feePct;

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
    function updateDelegateFee(uint128 feePct) external {
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
            delegateHistoricalFees[msg.sender][delegate.nextFeePctEpoch] = feePct;  

            emit Events.DelegateFeeIncreased(msg.sender, currentFeePct, feePct, delegate.nextFeePctEpoch);

        } else {
            // fee decreased: apply immediately
            delegate.currentFeePct = feePct;
            delegateHistoricalFees[msg.sender][currentEpoch] = feePct;

            // delete pending
            delete delegate.nextFeePct;
            delete delegate.nextFeePctEpoch;

            emit Events.DelegateFeeDecreased(msg.sender, currentFeePct, feePct);
        }
    }


    /**
     * @dev Internal function to apply pending fee increase if the epoch has arrived.
     * Updates currentFeePct and clears next* fields.
     * Also sets historical for the current epoch if not set.
     * @return bool True if pending was applied and historical set, false otherwise.
     */
    function _applyPendingFeeIfNeeded(address delegateAddr, uint256 currentEpoch) internal returns (bool) {
        Delegate storage delegatePtr = delegates[delegateAddr];

        // if pending fee increase, apply it
        if (delegatePtr.nextFeePctEpoch > 0) {
            if(currentEpoch >= delegatePtr.nextFeePctEpoch) {
                
                // update currentFeePct
                delegatePtr.currentFeePct = delegatePtr.nextFeePct;
                delegateHistoricalFees[delegateAddr][currentEpoch] = delegatePtr.currentFeePct;  // Ensure set for claims
                
                // reset
                delete delegatePtr.nextFeePct;
                delete delegatePtr.nextFeePctEpoch;
            
                return true;
            }
        }

        return false;
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

    function claimDelegateFees() external {
        DataTypes.Delegate storage delegate = delegates[msg.sender];
        require(delegate.isRegistered, Errors.DelegateNotRegistered());

        uint128 feesToClaim = delegate.totalFees - delegate.totalFeesClaimed;
        require(feesToClaim > 0, Errors.NoFeesToClaim());

        delegate.totalFeesClaimed += feesToClaim;

        // Transfer esMoca to delegate
        _esMoca().safeTransfer(msg.sender, feesToClaim);

        emit Events.DelegateFeesClaimed(msg.sender, feesToClaim);
    }

//-------------------------------voters: claiming rewards----------------------------------------------


    /**
     * @notice Claim esMoca rewards for specified pools in a given epoch.
     * @dev For veHolders who voted, allows claiming esMoca rewards derived from the verification fee split.
     *      Users who voted in epoch N can claim the pool verification fees for epoch N+1.
     *      Pools with zero rewards can be repeatedly claimed, but will be skipped gracefully.
     *      No explicit "claimed" flag is used to avoid added complexity and maintain Account struct compatibility across mappings.
     * @param epoch The epoch number for which to claim rewards.
     * @param poolIds Array of pool identifiers for which to claim rewards.
     */
    function claimRewards(uint256 epoch, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, Errors.InvalidArray());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint256 userTotalRewards;
        for(uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            
            //sanity check: pool exists + user has not claimed rewards yet
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(usersEpochPoolData[epoch][poolId][msg.sender].totalRewards == 0, Errors.RewardsAlreadyClaimed());    

            //require(pools[poolId].isActive, "Pool inactive");  ---> pool could be currently inactive but have unclaimed prior rewards 

            // get user's pool votes + pool totals
            uint256 userPoolVotes = usersEpochPoolData[epoch][poolId][msg.sender].totalVotesSpent;
            uint256 poolTotalVotes = epochPools[epoch][poolId].totalVotes;
            uint256 totalRewards = epochPools[epoch][poolId].totalRewards;
            
            // poolTotalVotes == 0 is implicitly checked via userPoolVotes
            if(totalRewards == 0 || userPoolVotes == 0) continue;  // skip 0-reward pools gracefully

            // calc. user's rewards for the pool (direct proportion, per-pool)
            uint256 userRewards = (userPoolVotes * totalRewards) / poolTotalVotes;    // all expressed in 1e18 precision
            if(userRewards == 0) continue;  // skip if floored to 0
            
            // set user's totalRewards for this pool
            usersEpochPoolData[epoch][poolId][msg.sender].totalRewards = userRewards;

            // increment pool's total claimed rewards
            epochPools[epoch][poolId].totalRewardsClaimed += userRewards;
            pools[poolId].totalRewardsClaimed += userRewards;

            // update counter
            userTotalRewards += userRewards;
        }

        if(userTotalRewards == 0) revert Errors.NoRewardsToClaim();

        // increment user's total rewards, for this epoch
        usersEpochData[epoch][msg.sender].totalRewards += userTotalRewards;

        // increment global: epoch + pool
        epochs[epoch].totalRewardsClaimed += userTotalRewards;

        // transfer esMoca to user
        _esMoca().safeTransfer(msg.sender, userTotalRewards);

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, userTotalRewards);
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
    function claimRewardsFromDelegate(uint256 epoch, bytes32[] calldata poolIds, address delegate) external {
        // sanity check: delegate
        //require(delegate > address(0), Errors.InvalidAddress());
        require(delegates[delegate].isRegistered, Errors.DelegateNotRegistered());

        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        uint256 userTotalRewards;
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
            if(delegatePoolRewards == 0) continue;  // skip if floored to 0

            // fetch the number of votes the user delegated to this delegate
            uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(msg.sender, delegate, epoch);
            
            uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;
            //require(delegateTotalVotesForEpoch > 0, Errors.NoVotesAllocatedByDelegate());  --> not needed since delegatePoolVotes > 0

            uint256 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
            if(userGrossRewards == 0) continue;  // skip if floored to 0

            //STORAGE: set per-pool gross rewards [user-delegate pair]
            userDelegateAccounting[epoch][msg.sender][delegate].userPoolGrossRewards[poolId] = userGrossRewards;  // flagged as claimed

            //note: add gross to pool claimed [transfer to delegate will be made post-loop]
            epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
            pools[poolId].totalRewardsClaimed += userGrossRewards;

            userTotalRewards += userGrossRewards;
        }

        if(userTotalRewards == 0) revert Errors.NoRewardsToClaim();

        // calc. delegation fee + net rewards | note: could be floored to 0
        uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];
        uint256 delegateFee = userTotalRewards * delegateFeePct / Constants.PRECISION_BASE;
        uint256 userTotalNetRewards = userTotalRewards - delegateFee;                           
        // sanity check: unlikely to trigger, but just in case
        require(userTotalNetRewards > 0, Errors.NoRewardsToClaim());
        
        
        // -------- accounting updates --------

        // increment user's aggregate net claimed
        userDelegateAccounting[epoch][msg.sender][delegate].totalNetClaimed += uint128(userTotalNetRewards);

        // increment delegate's gross rewards captured + fees accrued [global profile]
        delegates[delegate].totalRewardsCaptured += userTotalRewards;

        // increment delegate's total rewards captured for this epoch 
        delegateEpochData[epoch][delegate].totalRewards += delegateFee;

        // global: increment epoch & pool total claimed 
        epochs[epoch].totalRewardsClaimed += userTotalRewards;


        emit Events.RewardsClaimedFromDelegate(epoch, msg.sender, delegate, poolIds, userTotalNetRewards);

        // transfer esMoca to user | note: must whitelist this contract for transfers
        _esMoca().safeTransfer(msg.sender, userTotalNetRewards);
        
        // pay fees to delegate [to honour the loop update: epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards]
        if(delegateFee > 0){
            delegates[delegate].totalFees += delegateFee;
            delegates[delegate].totalFeesClaimed += delegateFee;
            _esMoca().safeTransfer(delegate, delegateFee);
        }
    }        


//-------------------------------verifiers: claiming subsidies-----------------------------------------

    //TODO: subsidies claimable based off their expenditure accrued for a pool-epoch
    //REVIEW: Subsidies are paid out to the `assetAddress` of the verifier, so it is required that, `assetAddress` calls `VotingController.claimSubsidies`
    function claimSubsidies(uint128 epoch, bytes32 verifierId, bytes32[] calldata poolIds) external {
        require(poolIds.length > 0, Errors.InvalidArray());
        
        // epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        //TODO[maybe]: epoch: calculate subsidies if not already done; so can front-run/incorporate finalizeEpoch()

        uint256 totalSubsidiesClaimed;  
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
        epochs[epoch].totalClaimed += totalSubsidiesClaimed;

        // event
        emit Events.SubsidiesClaimed(msg.sender, epoch, poolIds, totalSubsidiesClaimed);

        // transfer esMoca to verifier
        // note: must whitelist VotingController on esMoca for transfers
        _esMoca().transfer(msg.sender, totalSubsidiesClaimed);      
    }


//-------------------------------admin: finalize, deposit, withdraw subsidies-----------------------------------------

    // REVIEW: instead onlyVotingControllerAdmin, DEPOSITOR role?
    /**
     * @notice Deposits esMOCA subsidies for a completed epoch to be distributed among pools based on votes.
     * @dev Callable only by VotingController admin. Calculates and sets subsidy per vote for the epoch.
     *      Transfers esMOCA from the caller to the contract if subsidies > 0 and votes > 0.
     *      Can only be called after the epoch has ended and before it is finalized.
     * @param epoch The epoch number for which to deposit subsidies.
     * @param subsidies The total amount of esMOCA subsidies to deposit (1e18 precision).
     */
    function depositEpochSubsidies(uint256 epoch, uint256 subsidies) external onlyVotingControllerAdmin {
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
            epochPtr.totalSubsidiesAllocated = subsidies;
            TOTAL_SUBSIDIES_DEPOSITED += subsidies;

            emit Events.SubsidiesDeposited(msg.sender, epoch, subsidies);
        } // else: subsidies = 0 or no votes -> no-op, flag still set

        //STORAGE: set flag
        epochPtr.isSubsidiesSet = true;
        emit Events.SubsidiesSet(epoch, subsidies);
    }

    //Note: only callable once for each pool | rewards are referenced from PaymentsController | subsidies are referenced from PaymentsController
    //Review: str vs mem | uint128 vs uint256
    function finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards) external onlyVotingControllerAdmin {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == rewards.length, Errors.MismatchedArrayLengths());

        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized + depositEpochSubsidies() must have been called
        EpochData storage epochPtr = epochs[epoch];
        require(epochPtr.isSubsidiesSet, Errors.SubsidiesNotSet());
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // iterate through pools
        uint256 totalSubsidies;
        uint256 totalRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 poolRewards = rewards[i];       // can be 0

            // sanity check: pool exists + not processed
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(!epochPools[epoch][poolId].isProcessed, Errors.PoolAlreadyProcessed());

            uint256 poolVotes = epochPools[epoch][poolId].totalVotes;
            
            // Calc. subsidies for each pool | if there are subsidies for epoch + pool has votes
            if(epochPtr.totalSubsidiesAllocated > 0 && poolVotes > 0) {
                
                uint256 poolSubsidies = (poolVotes * epochPtr.totalSubsidies) / epochPtr.totalVotes;
                
                // sanity check: poolSubsidies > 0; skip if floored to 0
                if(poolSubsidies > 0) { 
                    epochPools[epoch][poolId].totalSubsidiesAllocated = uint128(poolSubsidies);
                    pools[poolId].totalSubsidiesAllocated += poolSubsidies;

                    totalSubsidies += poolSubsidies;
                }
            }

            // Set totalRewards for each pool | only if rewards >0 and votes >0 (avoids undistributable)
            if(poolRewards > 0 && poolVotes > 0) {

                epochPools[epoch][poolId].totalRewardsAllocated = poolRewards;
                pools[poolId].totalRewardsAllocated += poolRewards;

                totalRewards += poolRewards;
            } // else skip, rewards effectively 0 for this pool

            // mark processed
            epochPools[epoch][poolId].isProcessed = true;
        }

        //STORAGE update epoch global | do not overwrite subsidies; was set in depositEpochSubsidies()
        epochPtr.totalRewardsAllocated += totalRewards;
        epochPtr.totalSubsidiesDistributable += totalSubsidies;

        emit Events.EpochPartiallyFinalized(epoch, poolIds);

        // STORAGE: increment count of pools finalized
        epochs[epoch].poolsFinalized += uint128(poolIds.length);

        // check if epoch is fully finalized
        if(epochPtr.poolsFinalized == TOTAL_NUMBER_OF_POOLS) {
            epochPtr.isFullyFinalized = true;
            emit Events.EpochFullyFinalized(epoch);
        }
    }


    //REVIEW: ROLE 
    /**
     * @notice Sweep all unclaimed voting rewards for specified pools in a given epoch to the treasury.
     * @dev Requires the epoch to be fully finalized and a 6-epoch delay.
     *      Sums and transfers all unclaimed esMoca rewards for the provided poolIds in the specified epoch to the treasury.
     *      Emits an {UnclaimedRewardsSwept} event on success.
     *      Reverts if the epoch is not finalized, the treasury address is unset, or there are no unclaimed rewards to sweep.
     * @param epoch The epoch number for which to sweep unclaimed rewards.
     */
    function withdrawUnclaimedRewards(uint128 epoch) external onlyVotingControllerAdmin {
        require(EpochMath.getCurrentEpochNumber() >= epoch + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlySweepUnclaimedRewardsAfterDelay());
        
        // sanity check: epoch must be finalized [pool exists implicitly]
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());


        uint256 unclaimed = epochs[epoch].totalRewardsAllocated - epochs[epoch].totalRewardsClaimed;
        require(unclaimed > 0, Errors.NoUnclaimedRewardsToSweep());

        address treasury = IAddressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());
        
        _esMoca().safeTransfer(treasury, unclaimed);

        emit Events.UnclaimedRewardsWithdrawn(treasury, epoch, unclaimed);
    }

    //REVIEW: ROLE and recipient
    // withdraw unclaimed subsidies + residuals | after 6 epochs[~3months]
    function withdrawUnclaimedSubsidies(uint256 epoch) external onlyVotingControllerAdmin {
        // sanity check: epoch must be finalized
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        // sanity check: withdraw delay must have passed
        require(epoch >= EpochMath.getCurrentEpochNumber() + UNCLAIMED_SUBSIDIES_DELAY, Errors.CanOnlyWithdrawUnclaimedSubsidiesAfterDelay());
        
        // sanity check: there must be unclaimed subsidies
        uint256 unclaimedSubsidies = epochs[epoch].totalSubsidiesDistributable - epochs[epoch].totalClaimed;
        require(unclaimedSubsidies > 0, Errors.NoSubsidiesToClaim());

        // transfer esMoca to admin/deposit(?)
        _esMoca().transfer(msg.sender, unclaimedSubsidies);

        // event
        emit Events.UnclaimedSubsidiesWithdrawn(msg.sender, epoch, unclaimedSubsidies);
    }


    /**
     * @notice Immediately sweeps residual subsidies (allocated - distributable) for an epoch to the admin/treasury.
     * @dev Admin-only, post-finalization, no delay. Residuals are unclaimable flooring losses.
     * @param epoch The epoch to sweep residuals for.
     */
    function withdrawResidualSubsidies(uint256 epoch) external onlyVotingControllerAdmin {
        Epoch storage epochPtr = epochs[epoch];
        // sanity check: epoch must be finalized
        require(epochPtr.isFullyFinalized, Errors.EpochNotFinalized());
        require(!epochPtr.residualsWithdrawn, Errors.ResidualsAlreadyWithdrawn());

        uint256 residuals = epochPtr.totalSubsidiesAllocated - epochPtr.totalSubsidiesDistributable;
        require(residuals > 0, Errors.NoResidualsToSweep());

        // Flag to prevent double-sweep
        epochPtr.residualsWithdrawn = true;  

        address treasury = IAddressBook.getTreasury();  // Or msg.sender if to admin
        require(treasury != address(0), Errors.InvalidAddress());
        _esMoca().safeTransfer(treasury, residuals);

        emit Events.ResidualSubsidiesWithdrawn(treasury, epoch, residuals);
    }

    
//-------------------------------admin: setters ---------------------------------------------------------

    /**
     * @notice Sets the maximum delegate fee percentage.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and less than PRECISION_BASE.
     * @param maxFeePct The new maximum delegate fee percentage (2 decimal precision, e.g., 100 = 1%).
     */
    function setMaxDelegateFeePct(uint128 maxFeePct) external onlyVotingControllerAdmin {
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
    function setFeeIncreaseDelayEpochs(uint256 delayEpochs) external onlyVotingControllerAdmin {
        require(delayEpochs > 0, Errors.InvalidDelayEpochs());
        require(delayEpochs % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayEpochs());
       
        FEE_INCREASE_DELAY_EPOCHS = delayEpochs;
        emit Events.FeeIncreaseDelayEpochsUpdated(delayEpochs);
    }

    /**
     * @notice Sets the unclaimed delay epochs.
     * @dev Only callable by VotingController admin. Value must be greater than 0 and a multiple of EpochMath.EPOCH_DURATION.
     * @param delayEpochs The new unclaimed delay epochs.
     */
    function setUnclaimedDelay(uint256 delayEpochs) external onlyVotingControllerAdmin {
        require(delayEpochs > 0, Errors.InvalidDelay());
        require(delayEpochs % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelay());

        UNCLAIMED_DELAY_EPOCHS = delayEpochs;

        emit Events.UnclaimedDelayUpdated(delayEpochs);
    }

//-------------------------------admin: pool functions----------------------------------------------------

    function createPool(bytes32 poolId, bool isActive) external onlyVotingControllerAdmin {
        require(poolId != bytes32(0), Errors.InvalidPoolId());
        require(pools[poolId].poolId == bytes32(0), Errors.PoolAlreadyExists());
        
        pools[poolId].poolId = poolId;
        pools[poolId].isActive = isActive;

        ++TOTAL_NUMBER_OF_POOLS;

        emit Events.PoolCreated(poolId, isActive);
    }

    //TODO: what exactly is the point of this? just to remove from circualtion and finalize can ignore?
    function removePool(bytes32 poolId) external onlyVotingControllerAdmin {
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
        require(pools[poolId].totalSubsidiesAllocated == 0, Errors.PoolHasSubsidies());
        
        delete pools[poolId];

        --TOTAL_NUMBER_OF_POOLS;    

        emit Events.PoolRemoved(poolId);
    }

    /**
     * @notice Set the active status of a pool, enabling selective pausing during an epoch.
     * @dev Allows the VotingController admin to set the active status of a pool at any time.
     *      Useful for risk mitigation or operational control without affecting other pools.
     * @param poolId The identifier of the pool to update.
     * @param isActive Boolean indicating whether the pool should be active (true) or inactive (false).
     */
    function setPoolStatus(bytes32 poolId, bool isActive) external onlyVotingControllerAdmin {
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());

        pools[poolId].isActive = isActive;

        emit Events.PoolStatusSet(poolId, isActive);
    }

//-------------------------------internal functions------------------------------------------------------


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

//-------------------------------view functions----------------------------------------------------------

    //TODO: update logic
    function getEligibleSubsidy(address verifier, uint128 epoch, bytes32[] calldata poolIds) external view returns (uint128[] memory) {
        require(poolIds.length > 0, "No pools specified");
        require(epoch < getCurrentEpoch(), "Cannot query for current or future epochs");
        
        require(epochs[epoch].isFullyFinalized, "Epoch not finalized");
            
        eligibleSubsidies = new uint128[](poolIds.length);
        
    }

    // function previewRewards??


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
     * @return grossRewards Array of gross rewards for each poolId.
     */
    function getUserDelegatePoolGrossRewards(uint256 epoch, address user, address delegate, bytes32[] calldata poolIds) external view returns (uint128[] memory grossRewards) {
        grossRewards = new uint128[](poolIds.length);
        for (uint256 i; i < poolIds.length; ++i) {
            grossRewards[i] = userDelegateAccounting[epoch][user][delegate].poolGrossRewards[poolIds[i]];
        }
    }

}