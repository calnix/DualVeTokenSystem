// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// internal libraries
import {EpochMath} from "./EpochMath.sol";
import {DataTypes} from "./DataTypes.sol";

import {VeMathLib} from "./VeMathLib.sol";


library VeViewLib {
    using VeMathLib for DataTypes.VeBalance;

    function viewGlobal(
        DataTypes.VeBalance memory veGlobal_, 
        uint128 lastUpdatedAt, 
        uint128 currentEpochStart,
        mapping(uint128 => uint128) storage slopeChanges
        ) internal view returns (DataTypes.VeBalance memory) {   

        // nothing to update: lastUpdate was within current epoch 
        if(lastUpdatedAt >= currentEpochStart) return (veGlobal_); 

        // skip first time: no prior updates needed | set lastUpdatedAt | return
        if(lastUpdatedAt == 0) return veGlobal_;

        // update global veBalance
        while (lastUpdatedAt < currentEpochStart) {
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {lastUpdatedAt += EpochMath.EPOCH_DURATION;}                  

            // apply scheduled slope reductions and decrement bias for expiring locks
            veGlobal_ = veGlobal_.subtractExpired(slopeChanges[lastUpdatedAt], lastUpdatedAt);
        }

        return (veGlobal_);
    }

    function viewAccountAndGlobalAndPendingDeltas(
        address account, 
        uint128 currentEpochStart, 
        DataTypes.VeBalance memory veGlobal_,
        uint128 lastUpdatedTimestamp_,
        mapping(uint128 => uint128) storage slopeChanges,
        mapping(address => mapping(uint128 => DataTypes.VeBalance)) storage accountHistoryMapping,
        mapping(address => mapping(uint128 => uint128)) storage accountSlopeChangesMapping,
        mapping(address => mapping(uint128 => DataTypes.VeDeltas)) storage accountPendingDeltas,
        mapping(address => uint128) storage accountLastUpdatedMapping
    ) external view returns (DataTypes.VeBalance memory, DataTypes.VeBalance memory) {

        // init account veAccount
        DataTypes.VeBalance memory veAccount_;

        // get account's lastUpdatedTimestamp [either matches global or lags behind it]
        uint128 accountLastUpdatedAt = accountLastUpdatedMapping[account];

        // account's first time: no prior updates to execute 
        if (accountLastUpdatedAt == 0) {
            // view global: does not update storage
            veGlobal_ = viewGlobal(veGlobal_, lastUpdatedTimestamp_, currentEpochStart, slopeChanges);
            return (veGlobal_, veAccount_);
        }

        // get account's previous veBalance: if both global and account are up to date, return
        veAccount_ = accountHistoryMapping[account][accountLastUpdatedAt];
        if(accountLastUpdatedAt >= currentEpochStart) return (veGlobal_, veAccount_); 

        // update both global and account veBalance to current epoch
        while (accountLastUpdatedAt < currentEpochStart) {
            
            // advance 1 epoch [unchecked: can't overflow; saves some gas]
            unchecked {accountLastUpdatedAt += EpochMath.EPOCH_DURATION;}

            // update global: if needed 
            if(lastUpdatedTimestamp_ < accountLastUpdatedAt) {
                
                // apply scheduled slope reductions and decrement bias for expiring locks
                veGlobal_ = veGlobal_.subtractExpired(slopeChanges[accountLastUpdatedAt], accountLastUpdatedAt);
                // book ve supply for this epoch
                //totalSupplyAt[accountLastUpdatedAt] = _getValueAt(veGlobal_, accountLastUpdatedAt);
            }

            // update account: apply scheduled slope reductions and decrement bias for expiring locks
            veAccount_ = veAccount_.subtractExpired(accountSlopeChangesMapping[account][accountLastUpdatedAt], accountLastUpdatedAt);

            // get the pending delta for the current epoch
            DataTypes.VeDeltas storage deltaPtr = accountPendingDeltas[account][accountLastUpdatedAt];
           
            // copy flags to mem
            bool hasAddition = deltaPtr.hasAddition;
            bool hasSubtraction = deltaPtr.hasSubtraction;

            // if the pending delta has no additions or subtractions, skip
            if(!hasAddition && !hasSubtraction) continue;

            // apply the pending delta to the veAccount [add then sub]
            if(hasAddition) veAccount_ = veAccount_.add(deltaPtr.additions);
            if(hasSubtraction) veAccount_ = veAccount_.sub(deltaPtr.subtractions);
        }

        return (veGlobal_, veAccount_);
    }
}