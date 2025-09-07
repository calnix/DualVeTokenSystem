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
import {IEscrowedMoca} from "./interfaces/IEscrowedMoca.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";
import {IPaymentsController} from "./interfaces/IPaymentsController.sol";

//TODO: standardize naming conventions: {subsidy,incentive}

contract VotingController is Pausable {
    using SafeERC20 for IERC20;

    // protocol yellow pages
    IAddressBook internal immutable _addressBook;
    
    // safety check
    uint256 public TOTAL_NUMBER_OF_POOLS;

    // subsidies
    uint256 public TOTAL_SUBSIDIES_DEPOSITED;
    uint256 public TOTAL_SUBSIDIES_CLAIMED;
    uint256 public UNCLAIMED_SUBSIDIES_DELAY;

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
    mapping(address delegate => mapping(uint256 epoch => uint256 currentFeePct)) public delegateHistoricalFees;   // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

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
     * @param poolVotes Array of votes corresponding to each pool.
     * @param isDelegated Boolean flag indicating whether to use delegated voting power.

     */
    function vote(address caller, bytes32[] calldata poolIds, uint128[] calldata poolVotes, bool isDelegated) external {
        // caller is msg.sender or router
        require(caller == msg.sender || caller == _addressBook.getRouter(), Errors.InvalidCaller());

        // sanity check: poolIds & poolVotes must be non-empty and have the same length
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == poolVotes.length, Errors.MismatchedArrayLengths());

        // epoch should not be finalized
        uint256 epoch = EpochMath.getCurrentEpochNumber();          
        require(!epochs[epoch].isFullyFinalized, Errors.EpochFinalized());

        // mapping lookups based on isDelegated | account:{personal,delegate}
        mapping(uint256 epoch => mapping(address user => Account accountEpochData)) storage accountEpochData;
        mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address user => Account accountEpochPoolData))) storage accountEpochPoolData;

        // assign mappings
        if (isDelegated) {
            require(delegates[caller].isRegistered, Errors.DelegateNotRegistered());
            accountEpochData = delegateEpochData;
            accountEpochPoolData = delegatesEpochPoolData;
        } else {
            accountEpochData = usersEpochData;
            accountEpochPoolData = usersEpochPoolData;
        }

        // votingPower: benchmarked to end of epoch [forward-decay]
        // get account's voting power[personal, delegated] and used votes
        uint128 totalVotes = _veMoca().balanceAtEpochEnd(caller, epoch, isDelegated);
        uint128 spentVotes = accountEpochData[epoch][caller].totalVotesSpent;

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
            accountEpochPoolData[epoch][poolId][caller].totalVotesSpent += votes;
            epochPools[epoch][poolId].totalVotes += votes;
            epochs[epoch].totalVotes += votes;

            //increment pool votes at a global level
            pools[poolId].totalVotes += votes;       
        }

        // update account's epoch totalVotesSpent counter
        accountEpochData[epoch][caller].totalVotesSpent += totalNewVotes;
        
        emit Events.Voted(epoch, caller, poolIds, poolVotes, isDelegated);
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
     * @param feePct The fee percentage to be applied to the delegate's rewards. [0 feePct allowed]
     * Emits a {DelegateRegistered} event on success.
     * Reverts if the fee is greater than the maximum allowed fee, the caller is already registered,
     * or the registration fee cannot be transferred from the caller.
     */
    function registerAsDelegate(uint128 feePct) external {
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

        emit Events.DelegateRegistered(msg.sender, feePct);
    }

    /**
     * @notice Updates the delegate fee percentage. [0 feePct allowed]
     * @dev If the fee is increased, the new fee takes effect from currentEpoch + 2 to prevent last-minute increases.
     *      If the fee is decreased, the new fee takes effect immediately.
     * @param feePct The new fee percentage to be applied to the delegate's rewards. [0 feePct allowed]
     * Emits a {DelegateFeeUpdated} event on success.
     * Reverts if the fee is greater than the maximum allowed fee, the caller is not registered, or the fee is not a valid percentage.
     */
    function updateDelegateFee(uint128 feePct) external {
        require(feePct <= MAX_DELEGATE_FEE_PCT, Errors.InvalidFeePct());    // 0 allowed

        Delegate storage delegate = delegates[msg.sender];
        require(delegate.isRegistered, Errors.DelegateNotRegistered());
            
        uint256 currentFeePct = delegate.currentFeePct;
        // if increase, only applicable from currentEpoch+FEE_INCREASE_DELAY_EPOCHS
        if(feePct > currentFeePct) {
            delegate.nextFeePct = feePct;
            delegate.nextFeePctEpoch = EpochMath.getCurrentEpochNumber() + FEE_INCREASE_DELAY_EPOCHS;
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


    // for veHolders tt voted get esMoca -> from verification fee split
    // vote at epoch:N, get the pool verification fees of the next epoch:N+1
    /*
        for pools tt have 0 rewards, users will be able to repeatedly call this fn. 
        however, this will be skipped gracefully.
        this is preferred to having a is claimed flag, which would introduce more complexity.
        as the Account struct can no longer be used universally btw mappings: userEpochData & userEpochPoolData.
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

            // update counter
            userTotalRewards += userRewards;
        }

        if(userTotalRewards == 0) revert Errors.NoRewardsToClaim();

        // increment user's total rewards, for this epoch
        usersEpochData[epoch][msg.sender].totalRewards += userTotalRewards;

        // transfer esMoca to user
        _esMoca().safeTransfer(msg.sender, userTotalRewards);

        emit Events.RewardsClaimed(msg.sender, epoch, poolIds, userTotalRewards);
    }


    //TODO: review the delegate mappings
    // user claims rewards on votes tt were delegated to a delegate
    // user could have multiple delegates; must specify which delegate he is claiming from
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
            
            // no need check if totalPoolVotes is 0; implicitly checked via delegatePoolVotes
            if(totalPoolRewards == 0 || delegatePoolVotes == 0) continue;  // skip 0-reward pools gracefully

            // calc. delegate's share of pool rewards | TODO: camel principal: Oz's mulDiv()
            uint256 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
            if(delegatePoolRewards == 0) continue;  // skip if floored to 0

            // fetch the number of votes the user delegated to this delegate
            uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(msg.sender, delegate, epoch);
            
            uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;
            //require(delegateTotalVotesForEpoch > 0, Errors.NoVotesAllocatedByDelegate());  --> not needed since delegatePoolVotes > 0

            uint256 userRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
            if(userRewards == 0) continue;  // skip if floored to 0

            //STORAGE: set per-pool gross rewards [user-delegate pair]
            userDelegateAccounting[epoch][msg.sender][delegate].poolGrossRewards[poolId] = userRewards;  // flagged as claimed

            // Temp: add full gross to pool claimed (will adjust post-loop for fees)
            epochPools[epoch][poolId].totalClaimedRewards += userRewards;

            userTotalRewards += userRewards;
        }

        if(userTotalRewards == 0) revert Errors.NoRewardsToClaim();

        // calc. delegation fee + net rewards | note: could be floored to 0
        uint256 netUserRewards;
        uint256 delegateFee;
        uint256 delegateFeePct = delegates[delegate].currentFeePct;
        if(delegateFeePct > 0) {
            delegateFee = userTotalRewards * delegateFeePct / Constants.PRECISION_BASE;
            netUserRewards = userTotalRewards - delegateFee;                 // fee would be rounded down by division
            // dropping this to allow net=0 claims (prevents stuck pools if fee high)
            // require(netUserRewards > 0, "No rewards after fees to claim");
            // note: if user is rounded to 0, delegate fees will be 0
        } else{
            netUserRewards = userTotalRewards;
        }
        
        /**
            When sweeping unclaimed rewards:
             unclaimed = epochPools[epoch][poolId].totalRewards - epochPools[epoch][poolId].totalClaimedRewards
             This calculation uses gross user rewards.
             --------------
             However, after applying delegate fees, users may receive zero net rewards. 
             As a result, totalClaimedRewards is overstated (since only netUserRewards are actually paid out).
             Sweeping then uses this inflated totalClaimedRewards, leaving residual rewards in the contract.
             Therefore, after sweeping, leftover rewards remain on the contract.
             --------------
            Therefore, to accurately sweep, we need to adjust totalClaimedRewards based on netUserRewards.
        */

        // Prorate and subtract delegate fee from per-pool claimed (leaves fees as unclaimed for sweep)
        // Opt to have a separate loop to implement delegate fee impact on the aggregate of rewards; instead of per-pool
        if(delegateFee > 0) {
            for(uint256 i; i < poolIds.length; ++i) {
                bytes32 poolId = poolIds[i];
                uint128 poolGross = userDelegateAccounting[epoch][msg.sender][delegate].poolGrossRewards[poolId];
                if(poolGross == 0) continue; // skip unprocessed 

                // Prorate: fee_share = (poolGross / userTotalRewards) * delegateFee
                uint256 feeShare = (poolGross * delegateFee) / userTotalRewards;
                epochPools[epoch][poolId].totalClaimedRewards -= feeShare;       // adjust down (leaves fee as unclaimed)
            }
        }

        // increment user's aggregate net claimed
        userDelegateAccounting[epoch][msg.sender][delegate].totalNetClaimed += uint128(netUserRewards);

        // increment delegate's fees + gross rewards captured [global profile]
        delegates[delegate].totalFees += delegateFee;
        delegates[delegate].totalRewardsCaptured += userTotalRewards;

        // increment delegate's total rewards captured for this epoch [purely to reflect a delegate's performance]
        delegateEpochData[epoch][delegate].totalRewards += userTotalRewards;


        emit Events.RewardsClaimedFromDelegate(epoch, msg.sender, delegate, poolIds, netUserRewards);

        // transfer esMoca to user | note: must whitelist this contract for transfers
        _esMoca().safeTransfer(msg.sender, netUserRewards);
    }        


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


    // rewards are referenced from PaymentsController
    function finalizeEpochRewardsSubsidies(uint128 epoch, bytes32[] calldata poolIds, uint256[] calldata rewards) external onlyVotingControllerAdmin {
        require(poolIds.length > 0, Errors.InvalidArray());
        require(poolIds.length == rewards.length, Errors.MismatchedArrayLengths());

        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized + subsidyPerVote must have been set
        EpochData storage epochPtr = epochs[epoch];
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());
        require(epochPtr.isSubsidyPerVoteSet, Errors.SubsidyPerVoteNotSet());


        // ---- at this point subsidyPerVote could be 0 ----

        uint256 totalSubsidies;
        uint256 totalRewards;
        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];
            uint256 poolRewards = rewards[i];       // can be 0

            // sanity check: pool
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            
            // rewards can be 0 | if no verification fees were accrued on the PaymentsController, rewards are 0
            //require(poolRewards > 0, Errors.InvalidAmount());

            // Calc. subsidies for each pool | if there are subsidies for epoch + pool has votes
            if(epochPtr.subsidyPerVote > 0) {
                if(epochPools[epoch][poolId].totalVotes > 0) {
                    uint256 poolSubsidies = (epochPools[epoch][poolId].totalVotes * epochPtr.subsidyPerVote) / 1e18;
             
                    epochPools[epoch][poolId].totalSubsidies = poolSubsidies;
                    totalSubsidies += poolSubsidies;
                }
            }

            // Set totalRewards for each pool | only if rewards >0 and votes >0 (avoids undistributable)
            if(poolRewards > 0) {
                uint256 totalVotes = epochPools[epoch][poolId].totalVotes;
                if(totalVotes > 0) {
                    epochPools[epoch][poolId].totalRewards = poolRewards;
                    totalRewards += poolRewards;
                } // else skip, rewards effectively 0 for this pool
            }

        }

        // STORAGE: update pool global
        pools[poolId].totalSubsidies += totalSubsidies;
        pools[poolId].totalRewards += totalRewards;

        //STORAGE update epoch global
        epochs[epoch].totalSubsidies += totalSubsidies;
        epochs[epoch].totalRewards += totalRewards;

        emit Events.EpochPartiallyFinalized(epoch, poolIds);

        // STORAGE: increment count of pools finalized
        epochs[epoch].poolsFinalized += uint128(poolIds.length);

        // check if epoch is fully finalized
        if(epochs[epoch].poolsFinalized == TOTAL_NUMBER_OF_POOLS) {
            epochData.isFullyFinalized = true;
            emit Events.EpochFullyFinalized(epoch);
        }
    }

    // REVIEW: instead onlyVotingControllerAdmin, DEPOSITOR role?
    /**
     * @notice Deposits esMOCA subsidies for a completed epoch to be distributed among pools based on votes.
     * @dev Callable only by VotingController admin. Calculates and sets subsidy per vote for the epoch.
     *      Transfers esMOCA from the caller to the contract if subsidies > 0 and votes > 0.
     *      Can only be called after the epoch has ended and before it is finalized.
     * @param epoch The epoch number for which to deposit subsidies.
     * @param subsidies The total amount of esMOCA subsidies to deposit (1e18 precision).
     */
    function depositSubsidies(uint256 epoch, uint256 subsidies) external onlyVotingControllerAdmin {
        require(epoch <= EpochMath.getCurrentEpochNumber(), Errors.CannotSetSubsidiesForFutureEpochs());
        
        // sanity check: epoch must have ended
        uint256 epochEndTimestamp = EpochMath.getEpochEndTimestamp(epoch);
        require(block.timestamp >= epochEndTimestamp, Errors.EpochNotEnded());

        // sanity check: epoch must not be finalized
        EpochData storage epochPtr = epochs[epoch];
        require(!epochPtr.isFullyFinalized, Errors.EpochFinalized());

        // flag check:
        require(!epochPtr.isSubsidyPerVoteSet, Errors.SubsidyPerVoteAlreadySet());

        // if subsidies are distributed for this epoch: calc. subsidy per vote + update total subsidies deposited + deposit esMoca
        if(subsidies > 0) {
            // if there are no votes, we will not distribute subsidies
            if(epochPtr.totalVotes > 0) {
                
                // calc. subsidy per vote | must be non-zero, else funds will be stuck on contract
                epochPtr.subsidyPerVote = (subsidies * 1e18) / epochPtr.totalVotes;
                require(epochPtr.subsidyPerVote > 0, Errors.SubsidyPerVoteZero());
                
                _esMoca().transferFrom(msg.sender, address(this), subsidies);

                // STORAGE: update total subsidies deposited for epoch + global
                epochPtr.totalSubsidies = subsidies;
                TOTAL_SUBSIDIES_DEPOSITED += subsidies;
            }
        }

        // STORAGE: set flag 
        epochPtr.isSubsidyPerVoteSet = true;

        // event
        emit Events.SubsidiesDeposited(msg.sender, epoch, subsidies, epochPtr.totalSubsidies);
    }

    function depositRewards(uint256 epoch, uint256 rewards) external onlyVotingControllerAdmin {

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


    /**
     * @notice Sweeps unclaimed voting rewards for a specific pool and epoch to the treasury.
     * @dev Only callable by VotingController admin. Epoch must be fully finalized and pool must exist.
     *      Transfers all unclaimed esMoca rewards for the given pool and epoch to the treasury address.
     * @param epoch The epoch number for which to sweep unclaimed rewards.
     * @param poolId The identifier of the pool whose unclaimed rewards are to be swept.
     * Emits an {UnclaimedRewardsSwept} event on success.
     * Reverts if the epoch is not finalized, the pool does not exist, or there are no unclaimed rewards.
     */
    function sweepUnclaimedRewards(uint128 epoch, bytes32 poolId) external onlyVotingControllerAdmin {
        // TODO: delay before sweeping is possible -> 6 epochs?
        
        // sanity check: epoch must be finalized + pool must exist
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());

        uint256 unclaimed = epochPools[epoch][poolId].totalRewards - epochPools[epoch][poolId].totalClaimedRewards;
        require(unclaimed > 0, Errors.NoUnclaimed());

        address treasury = IAddressBook.getTreasury();
        _esMoca().safeTransfer(treasury, unclaimed);

        emit Events.UnclaimedRewardsSwept(epoch, poolId, unclaimed);
    }
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

    function setFeeIncreaseDelayEpochs(uint256 delayEpochs) external onlyVotingControllerAdmin {
        require(delayEpochs > 0, Errors.InvalidDelayEpochs());
        require(delayEpochs % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayEpochs());
        FEE_INCREASE_DELAY_EPOCHS = delayEpochs;
        emit Events.FeeIncreaseDelayEpochsUpdated(delayEpochs);
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

    //TODO: update logic
    function getEligibleSubsidy(address verifier, uint128 epoch, bytes32[] calldata poolIds) external view returns (uint128[] memory) {
        require(poolIds.length > 0, "No pools specified");
        require(epoch < getCurrentEpoch(), "Cannot query for current or future epochs");
        
        require(epochs[epoch].isFullyFinalized, "Epoch not finalized");
            
        eligibleSubsidies = new uint128[](poolIds.length);
        
    }

    /**
     * @notice Previews the subsidy per vote for a given epoch before calling depositSubsidies().
     * @dev Useful for checking if the subsidies to deposit are sufficient to avoid subsidy per vote rounding to zero.
     *      Callable by anyone, including during an ongoing epoch, to get projections.
     * @param epoch The epoch number to preview.
     * @param subsidiesToDeposit The amount of subsidies intended to deposit (in esMOCA, 1e18 precision).
     * @return The projected subsidy per vote (1e18 precision).
     */
    function previewDepositSubsidies(uint256 epoch, uint256 subsidiesToDeposit) external view returns (uint256) {
        require(epoch <= EpochMath.getCurrentEpochNumber(), Errors.CannotSetSubsidiesForFutureEpochs());

        // sanity check: epoch must have non-zero votes to avoid division by zero; and subsidies cannot be 0
        require(epochs[epoch].totalVotes > 0, Errors.ZeroVotes());
        require(subsidiesToDeposit > 0, Errors.InvalidAmount());

        // subsidiesToDeposit (esMoca) & votes(veMoca) are 1e18 precision    
        return (subsidiesToDeposit * 1e18) / epochs[epoch].totalVotes;
    }


    function getAddressBook() external view returns (IAddressBook) {
        return _addressBook;
    }

}


/**
    REMOVE EPOCH_ZERO_TIMESTAMP
    drop the anchor and have all contracts work off unix
    no need for epoch controller that way

 */