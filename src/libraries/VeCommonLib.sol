// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EpochMath} from "./EpochMath.sol";
import {VeMathLib} from "./VeMathLib.sol";
import {DataTypes} from "./DataTypes.sol";

library VeCommonLib {
    using VeMathLib for DataTypes.VeBalance;

//------------------------------ Internal: update functions----------------------------------------------

    function _pushCheckpoint(DataTypes.Checkpoint[] storage lockHistory_, DataTypes.VeBalance memory veBalance, uint128 currentEpochStart) internal {
        uint256 length = lockHistory_.length;

        // if last checkpoint is in the same epoch as incoming; overwrite
        if(length > 0 && lockHistory_[length - 1].lastUpdatedAt == currentEpochStart) {
            lockHistory_[length - 1].veBalance = veBalance;
        } else {
            // new checkpoint for new epoch: set lastUpdatedAt to currentEpochStart
            lockHistory_.push(DataTypes.Checkpoint(veBalance, currentEpochStart));
        }
    }

    
    // returns: veGlobal, lastUpdatedTimestamp. updates totalSupplyAt[] directly into storage
    function _updateGlobal(
        DataTypes.VeBalance memory veGlobal_, 
        uint128 lastUpdatedTimestamp,
        uint128 currentEpochStart,
        mapping(uint128 => uint128) storage slopeChanges,
        mapping(uint128 => uint128) storage totalSupplyAt
    ) internal returns (DataTypes.VeBalance memory, uint128) {       
        // nothing to update: lastUpdate was within current epoch [already up to date]
        if(lastUpdatedTimestamp >= currentEpochStart) return (veGlobal_, lastUpdatedTimestamp); 

        // 1st call: no prior updates [global lastUpdatedTimestamp is set to currentEpochStart]
        if(lastUpdatedTimestamp == 0) {
            lastUpdatedTimestamp = currentEpochStart;   // move forward the anchor point to skip empty epochs
            return (veGlobal_, lastUpdatedTimestamp);
        }

        // cache epoch duration
        uint128 epochDuration = EpochMath.EPOCH_DURATION;

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {lastUpdatedAt += epochDuration;}                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = veGlobal_.subtractExpired(slopeChanges[lastUpdatedAt], lastUpdatedAt);

            // book ve supply for this epoch
            totalSupplyAt[lastUpdatedAt] = veGlobal_.getValueAt(lastUpdatedAt);
        }

        // set final lastUpdatedTimestamp
        lastUpdatedTimestamp = lastUpdatedAt;

        return (veGlobal_, lastUpdatedTimestamp);
    }

    /**
        - user.lastUpdatedAt either matches the global.lastUpdatedAt OR is behind it
        - the global never lags behind the user
     */
    function _updateAccountAndGlobalAndPendingDeltas(address account, uint128 currentEpochStart, bool isDelegate) internal returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {
        // Streamlined mapping lookups based on account type
        (
            mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
            mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
            mapping(address account => mapping(uint128 eTime => DataTypes.VeDeltas veDeltas)) storage accountPendingDeltas,
            mapping(address account => uint128 lastUpdatedTimestamp) storage accountLastUpdatedMapping
        ) 
            = isDelegate ? (delegateHistory, delegateSlopeChanges, delegatePendingDeltas, delegateLastUpdatedTimestamp) : (userHistory, userSlopeChanges, userPendingDeltas, userLastUpdatedTimestamp);

        // CACHE: global veBalance + lastUpdatedTimestamp
        DataTypes.VeBalance memory veGlobal_ = veGlobal;
        uint128 lastUpdatedTimestamp_ = lastUpdatedTimestamp;

        // init account veAccount
        DataTypes.VeBalance memory veAccount_;

        // get account's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];
        
        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            
            // set account's lastUpdatedTimestamp
            accountLastUpdatedMapping[account] = currentEpochStart;

            // update global: updates lastUpdatedTimestamp [may or may not have updates]
            veGlobal_ = veGlobal_.updateGlobal(lastUpdatedTimestamp_, currentEpochStart);

            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 

        // cache epoch duration
        uint128 epochDuration = EpochMath.EPOCH_DURATION;

        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {accountLastUpdatedAt += epochDuration;}

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = veGlobal_.subtractExpired(slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                totalSupplyAt[accountLastUpdatedAt] = veGlobal_.getValueAt(accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = veAccount_.subtractExpired(accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

    
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];

            // apply the pending delta to the veAccount [add then sub]
            if(deltaPtr.hasAddition) veAccount_ = veAccount_.add(deltaPtr.additions);
            if(deltaPtr.hasSubtraction) veAccount_ = veAccount_.sub(deltaPtr.subtractions);

            // book account checkpoint 
            accountHistoryMapping[account][accountLastUpdatedAt] = veAccount_;

            // clean up after applying
            delete accountPendingDeltas[account][accountLastUpdatedAt];
        }

        // set final lastUpdatedTimestamp: for global & account
        lastUpdatedTimestamp = accountLastUpdatedMapping[account] = accountLastUpdatedAt;

        return (veGlobal_, veAccount_);
    }

    function _updatePendingForDelegatePair(address user, address delegate, uint128 currentEpochStart) internal returns (DataTypes.VeBalance memory) {
        uint128 pairLastUpdatedAt = userDelegatedPairLastUpdatedTimestamp[user][delegate];

        // init user veUser
        DataTypes.VeBalance memory vePair_;

        // if the pair has never been updated, return the initial aggregated veBalance
        if(pairLastUpdatedAt == 0) {
            // update the last updated timestamp
            userDelegatedPairLastUpdatedTimestamp[user][delegate] = currentEpochStart;
            return vePair_;
        }

        // copy the previous aggregated veBalance to mem [if the pair is already up to date, return]
        vePair_ = delegatedAggregationHistory[user][delegate][pairLastUpdatedAt];
        if(pairLastUpdatedAt == currentEpochStart) return vePair_; 

        // update pair's aggregated veBalance to current epoch start
        while(pairLastUpdatedAt < currentEpochStart) {

            // advance to next epoch
            pairLastUpdatedAt += EpochMath.EPOCH_DURATION;

            // apply decay to the aggregated veBalance
            vePair_ = vePair_.subtractExpired(userDelegatedSlopeChanges[user][delegate][pairLastUpdatedAt], pairLastUpdatedAt);
            
            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
            
            // apply the pending deltas to the vePair [add then sub]
            if (deltaPtr.hasAddition) vePair_ = vePair_.add(deltaPtr.additions);
            if (deltaPtr.hasSubtraction) vePair_ = vePair_.sub(deltaPtr.subtractions);

            // STORAGE: book veBalance for epoch 
            delegatedAggregationHistory[user][delegate][pairLastUpdatedAt] = vePair_;

            // clean up after applying
            delete userPendingDeltasForDelegate[user][delegate][pairLastUpdatedAt];
        }

        // update the last updated timestamp
        userDelegatedPairLastUpdatedTimestamp[user][delegate] = pairLastUpdatedAt;

        return vePair_;
    }


}