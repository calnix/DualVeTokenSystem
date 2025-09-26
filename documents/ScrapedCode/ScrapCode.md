# VeMoca

```solidity

    /** 
     * @notice Early redemption with penalty (partial redemption allowed)
     * @param lockId ID of the lock to redeem early
     * @param amountToRedeem Amount of principal to redeem
     * @param isMoca True to redeem MOCA tokens, false to redeem esMOCA tokens
     */
    /*function earlyRedemption(bytes32 lockId, uint128 amountToRedeem, bool isMoca) external {

        // check lock exists
        DataTypes.Lock memory lock = locks[lockId];
        require(lock.lockId != bytes32(0), "NoLockFound");
        require(lock.creator == msg.sender, "Only the creator can redeem early");
        require(lock.expiry > block.timestamp, "Lock has not expired");
        require(lock.isWithdrawn == false, "Lock has already been withdrawn");

        // Get the amount of the selected token type
        uint256 selectedPrincipalAmount = isMoca ? lock.moca : lock.esMoca;
        require(selectedPrincipalAmount > 0, "No principal in lock");

        uint256 totalBase = lock.moca + lock.esMoca;

        // get veBalance
        DataTypes.VeBalance memory veBalance = _convertToVeBalance(lock);   // veBalance.bias = initialVotingPower
        require(veBalance.bias > 0, "No veMoca to redeem");

        // get currentVotingPower
        uint256 currentBias = _getValueAt(veBalance, uint128(block.timestamp));
        
        /** Calculate penalty based on current veMoca value relative to original veMoca value;
            this is a proxy for time passed since lock was created.

            penalty = [1 - (currentVotingPower/initialVotingPower)] * MAX_PENALTY_PCT 
                    = [initialVotingPower/initialVotingPower - (currentVotingPower/initialVotingPower)] * MAX_PENALTY_PCT 
                    = [(initialVotingPower - currentVotingPower) / initialVotingPower] * MAX_PENALTY_PCT
                    = [(veBalance.bias - currentBias) / veBalance.bias] * MAX_PENALTY_PCT
        */
        /*uint256 penaltyPct = (Constants.MAX_PENALTY_PCT * (veBalance.bias - currentBias)) / veBalance.bias;   
        
        // calculate total penalty based on total base amount (both MOCA and esMOCA contribute to veMoca)
        uint256 totalPenaltyInTokens = totalBase * penaltyPct / Constants.PRECISION_BASE;
        
        // user gets their selected token type minus the total penalty
        uint256 remainingSelectedPrincipalAmount = selectedPrincipalAmount - totalPenaltyInTokens; //note: if insufficient, will revert
        
        // storage: update lock
        if(isMoca) {
            locks[lockId].moca = remainingSelectedPrincipalAmount;
        } else {
            locks[lockId].esMoca = remainingSelectedPrincipalAmount;
        }
        
        // storage: lock checkpoint
        //_pushCheckpoint(lockHistory[lockId], veBalance, currentWeekStart);

        // storage: update global & user | is this necessary?
        //(DataTypes.VeBalance memory veGlobal_, DataTypes.VeBalance memory veUser, uint128 currentWeekStart) = _updateUserAndGlobal(msg.sender);

        // burn veMoca    
        uint256 veMocaToBurn = amountToRedeem * veBalance.bias / totalBase;
        _burn(msg.sender, veMocaToBurn);

        // event?
        
        // transfer the selected token type to user
        if (isMoca) {
            mocaToken.safeTransfer(msg.sender, amountToReturn);
        } else {
            esMocaToken.safeTransfer(msg.sender, amountToReturn);
        }
        
        // emit event
    }*/
```

# VotingController

delgates can't really use this function since they would be blocked

1. claimRewardsDelegated -> must be called by user. through which delegatefee is paid as well
2. this means delegates are dependent on users proactively calling `claimRewardsDelegated()` to get their fees.
3. this is a problem as most users will delegate and turtle off.

```solidity
    // note: delegates get paid out in claimRewardsFromDelegate
    function claimDelegateFees() external {
        Delegate storage delegate = delegates[msg.sender];
        //require(delegate.isRegistered, Errors.DelegateNotRegistered()); --> unregistered delegates can still claim fees
        uint256 feesToClaim = delegate.totalFees - delegate.totalFeesClaimed;
        require(feesToClaim > 0, Errors.NoFeesToClaim());

        delegate.totalFeesClaimed += feesToClaim;
        _esMoca().safeTransfer(delegate, feesToClaim);

        emit Events.DelegateFeesClaimed(delegate, feesToClaim);
    }
```

## Delegates need a function to claim their fees independently. 

### V1

```solidity

// Add new function for delegates to force-claim fees (and push net rewards to delegator) after delay
function forceClaimRewardsForDelegator(uint256 epoch, address delegator, bytes32[] calldata poolIds) external {
    // Caller must be a registered delegate
    require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());

    // Epoch must be finalized
    require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

    // Now run similar logic as claimRewardsFromDelegate, but with delegator as user, msg.sender as delegate
    address delegate = msg.sender;  // Caller is delegate
    uint256 userTotalGrossRewards;

    for(uint256 i; i < poolIds.length; ++i) {
        bytes32 poolId = poolIds[i];

        // Sanity checks (same as original)
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
        require(userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] == 0, Errors.RewardsAlreadyClaimed());

        // Same calculations...
        uint256 delegatePoolVotes = delegatesEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
        uint256 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
        uint256 totalPoolRewards = epochPools[epoch][poolId].totalRewards;

        if(totalPoolRewards == 0 || delegatePoolVotes == 0) continue;

        uint256 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
        if(delegatePoolRewards == 0) continue;

        delegatesEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;
        delegateEpochData[epoch][delegate].totalRewards += delegatePoolRewards;

        uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);

        uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;

        uint256 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
        if(userGrossRewards == 0) continue;

        userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] = userGrossRewards;

        epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
        pools[poolId].totalRewardsClaimed += userGrossRewards;

        userTotalGrossRewards += userGrossRewards;
    }

    if(userTotalGrossRewards == 0) revert Errors.NoRewardsToClaim();

    uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];
    uint256 delegateFee = userTotalGrossRewards * delegateFeePct / Constants.PRECISION_BASE;
    uint256 userTotalNetRewards = userTotalGrossRewards - delegateFee;

    // Allow even if net=0 (for fee>0 cases)
    // No require(userTotalNetRewards > 0);

    // Accounting updates (same)
    userDelegateAccounting[epoch][delegator][delegate].totalNetRewards += uint128(userTotalNetRewards);

    delegates[delegate].totalGrossRewards += userTotalGrossRewards;
    if(delegateFee > 0){
        delegates[delegate].totalFees += delegateFee;
        delegates[delegate].totalFeesClaimed += delegateFee;
        _esMoca().safeTransfer(delegate, delegateFee);  // Pay fee to delegate (caller)
    }

    epochs[epoch].totalRewardsClaimed += userTotalGrossRewards;

    emit Events.RewardsForceClaimedByDelegate(epoch, delegator, delegate, poolIds, userTotalNetRewards);

    // Push net rewards to delegator (user)
    _esMoca().safeTransfer(delegator, userTotalNetRewards);
}

// Note: claimDelegateFees remains as-is for any residual/unclaimed fees, though with force-claim, it may be less necessary.

//BATCHING----------------------------------------------------------------------------------------------------------------------------------

// Batch force-claim for multiple delegators in one tx [claimDelegateFees()]
function forceClaimRewardsForDelegators(uint256 epoch, address[] calldata delegators, bytes32[][] calldata poolIdsPerDelegator) external {
    // Caller must be a registered delegate
    require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());

    // Require after delay
    uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
    require(currentEpoch >= epoch + UNCLAIMED_DELAY_EPOCHS, Errors.CanOnlyForceAfterDelay());

    // Epoch must be finalized
    require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

    require(delegators.length > 0 && delegators.length == poolIdsPerDelegator.length, Errors.MismatchedArrayLengths());

    address delegate = msg.sender;  // Caller is delegate
    uint256 totalDelegateFees;  // Accumulate fees across all delegators

    for (uint256 d; d < delegators.length; ++d) {
        address delegator = delegators[d];
        bytes32[] calldata poolIds = poolIdsPerDelegator[d];

        if (poolIds.length == 0) continue;  // Skip if no pools for this delegator

        uint256 userTotalGrossRewards;

        for (uint256 i; i < poolIds.length; ++i) {
            bytes32 poolId = poolIds[i];

            // Sanity checks
            require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
            require(userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] == 0, Errors.RewardsAlreadyClaimed());

            // Calculations (same as single)
            uint256 delegatePoolVotes = delegatesEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
            uint256 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
            uint256 totalPoolRewards = epochPools[epoch][poolId].totalRewards;

            if (totalPoolRewards == 0 || delegatePoolVotes == 0) continue;

            uint256 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
            if (delegatePoolRewards == 0) continue;

            delegatesEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;
            delegateEpochData[epoch][delegate].totalRewards += delegatePoolRewards;

            uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);

            uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;

            uint256 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
            if (userGrossRewards == 0) continue;

            userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] = userGrossRewards;

            epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
            pools[poolId].totalRewardsClaimed += userGrossRewards;

            userTotalGrossRewards += userGrossRewards;
        }

        // Skip if no gross for this delegator (e.g., didn't delegate or zero votes in pools)
        if (userTotalGrossRewards == 0) continue;

        uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];
        uint256 delegateFee = userTotalGrossRewards * delegateFeePct / Constants.PRECISION_BASE;
        uint256 userTotalNetRewards = userTotalGrossRewards - delegateFee;

        // Accounting (per delegator)
        userDelegateAccounting[epoch][delegator][delegate].totalNetRewards += uint128(userTotalNetRewards);

        delegates[delegate].totalGrossRewards += userTotalGrossRewards;
        if (delegateFee > 0) {
            delegates[delegate].totalFees += delegateFee;
            delegates[delegate].totalFeesClaimed += delegateFee;
            totalDelegateFees += delegateFee;  // Accumulate for batch transfer
        }

        epochs[epoch].totalRewardsClaimed += userTotalGrossRewards;

        // Push net to delegator
        _esMoca().safeTransfer(delegator, userTotalNetRewards);

        emit Events.RewardsForceClaimedByDelegate(epoch, delegator, delegate, poolIds, userTotalNetRewards);
    }

    // Batch transfer all accrued fees to delegate at end (if any)
    if (totalDelegateFees > 0) {
        _esMoca().safeTransfer(delegate, totalDelegateFees);
    }
}

// Note: If total across all=0, it just no-ops without revert—lenient for cases where some delegators have zero 
```

### V2

```solidity
// ... existing code ...

// Internal function for shared claim logic (handles one delegator)
function _claimDelegateRewards(uint256 epoch, address delegator, address delegate, bytes32[] calldata poolIds) internal returns (uint256 userTotalNetRewards, uint256 delegateFee) {
    uint256 userTotalGrossRewards;

    for (uint256 i; i < poolIds.length; ++i) {
        bytes32 poolId = poolIds[i];

        // Sanity checks
        require(pools[poolId].poolId != bytes32(0), Errors.PoolDoesNotExist());
        require(userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] == 0, Errors.RewardsAlreadyClaimed());

        // Calculations
        uint256 delegatePoolVotes = delegatesEpochPoolData[epoch][poolId][delegate].totalVotesSpent;
        uint256 totalPoolVotes = epochPools[epoch][poolId].totalVotes;
        uint256 totalPoolRewards = epochPools[epoch][poolId].totalRewards;

        if (totalPoolRewards == 0 || delegatePoolVotes == 0) continue;

        uint256 delegatePoolRewards = (delegatePoolVotes * totalPoolRewards) / totalPoolVotes;
        if (delegatePoolRewards == 0) continue;

        delegatesEpochPoolData[epoch][poolId][delegate].totalRewards = delegatePoolRewards;
        delegateEpochData[epoch][delegate].totalRewards += delegatePoolRewards;

        uint256 userVotesAllocatedToDelegateForEpoch = IVotingEscrowMoca(IAddressBook.getVotingEscrowMoca()).getSpecificDelegatedBalanceAtEpochEnd(delegator, delegate, epoch);

        uint256 delegateTotalVotesForEpoch = delegateEpochData[epoch][delegate].totalVotesSpent;

        uint256 userGrossRewards = (userVotesAllocatedToDelegateForEpoch * delegatePoolRewards) / delegateTotalVotesForEpoch;
        if (userGrossRewards == 0) continue;

        userDelegateAccounting[epoch][delegator][delegate].poolGrossRewards[poolId] = userGrossRewards;

        epochPools[epoch][poolId].totalRewardsClaimed += userGrossRewards;
        pools[poolId].totalRewardsClaimed += userGrossRewards;

        userTotalGrossRewards += userGrossRewards;
    }

    if (userTotalGrossRewards == 0) return (0, 0);  // Early return if nothing to claim

    uint256 delegateFeePct = delegateHistoricalFees[delegate][epoch];
    delegateFee = userTotalGrossRewards * delegateFeePct / Constants.PRECISION_BASE;
    userTotalNetRewards = userTotalGrossRewards - delegateFee;

    // Accounting updates
    userDelegateAccounting[epoch][delegator][delegate].totalNetRewards += uint128(userTotalNetRewards);

    delegates[delegate].totalGrossRewards += userTotalGrossRewards;
    if (delegateFee > 0) {
        delegates[delegate].totalFees += delegateFee;
        delegates[delegate].totalFeesClaimed += delegateFee;
    }

    epochs[epoch].totalRewardsClaimed += userTotalGrossRewards;
}


// Updated claimRewardsFromDelegate to batch multiple delegates
function claimRewardsFromDelegate(uint256 epoch, address[] calldata delegates, bytes32[][] calldata poolIdsPerDelegate) external {
    // Epoch must be finalized
    require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

    require(delegates.length > 0 && delegates.length == poolIdsPerDelegate.length, Errors.MismatchedArrayLengths());

    uint256 totalUserNetRewards;  // Accumulate user's nets across all delegates

    for (uint256 delIdx; delIdx < delegates.length; ++delIdx) {
        address delegate = delegates[delIdx];
        bytes32[] calldata poolIds = poolIdsPerDelegate[delIdx];

        // Sanity check: delegate
        require(delegates[delegate].isRegistered, Errors.DelegateNotRegistered());  // Note: 'delegates' is storage mapping; this checks registration

        if (poolIds.length == 0) continue;

        (uint256 userTotalNetRewardsForDelegate, uint256 delegateFee) = _claimDelegateRewards(epoch, msg.sender, delegate, poolIds);

        // No per-delegate require (allow zero-net); aggregate total net
        totalUserNetRewards += userTotalNetRewardsForDelegate;

        // Transfer fee to delegate (per-delegate, as in original)
        if (delegateFee > 0) {
            _esMoca().safeTransfer(delegate, delegateFee);
        }

        emit Events.RewardsClaimedFromDelegate(epoch, msg.sender, delegate, poolIds, userTotalNetRewardsForDelegate);
    }

    require(totalUserNetRewards > 0, Errors.NoRewardsToClaim());  // Check aggregate net >0

    // Single transfer of total net to user (caller)
    _esMoca().safeTransfer(msg.sender, totalUserNetRewards);
}


    // Batch force-claim for multiple delegators (delegate-called)
    function forceClaimRewardsForDelegators(uint256 epoch, address[] calldata delegators, bytes32[][] calldata poolIdsPerDelegator) external {
        // Caller must be a registered delegate
        require(delegates[msg.sender].isRegistered, Errors.DelegateNotRegistered());

        // Epoch must be finalized (no delay check, as per request)
        require(epochs[epoch].isFullyFinalized, Errors.EpochNotFinalized());

        require(delegators.length > 0 && delegators.length == poolIdsPerDelegator.length, Errors.MismatchedArrayLengths());

        address delegate = msg.sender;  // Caller is delegate
        uint256 totalDelegateFees;  // Accumulate fees across all delegators

        for (uint256 d; d < delegators.length; ++d) {
            address delegator = delegators[d];
            bytes32[] calldata poolIds = poolIdsPerDelegator[d];

            if (poolIds.length == 0) continue;  // Skip if no pools

            (uint256 userTotalNetRewards, uint256 delegateFee) = _claimDelegateRewards(epoch, delegator, delegate, poolIds);

            // No require on net>0 (allow fee-only)

            totalDelegateFees += delegateFee;

            emit Events.RewardsForceClaimedByDelegate(epoch, delegator, delegate, poolIds, userTotalNetRewards);

            // Push net to delegator (inside loop)
            if (userTotalNetRewards > 0) {
                _esMoca().safeTransfer(delegator, userTotalNetRewards);
            }
        }

        // Batch transfer all accrued fees to delegate at end
        if (totalDelegateFees > 0) {
            _esMoca().safeTransfer(delegate, totalDelegateFees);
        }
    }

// Note: Shared internal _claimDelegateRewards handles core logic. No delay in force-claim. Zeros skipped gracefully.
```