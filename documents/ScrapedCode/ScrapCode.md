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