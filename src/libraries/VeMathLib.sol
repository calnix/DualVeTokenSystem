// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {EpochMath} from "./EpochMath.sol";
import {DataTypes} from "./DataTypes.sol";
import {Errors} from "./Errors.sol";

library VeMathLib {

    /*  lock must have at least 3 epochs `liveliness` before expiry: current + 2 more epochs
        - non-zero voting power in the current and next epoch.  
        - 0 voting power in the 3rd epoch.
        This is a result of forward-decay: benchmarking voting power to the end of the epoch [to freeze intra-epoch decay] 
        
        We also want locks created to be delegated, and since delegation takes effect in the next epoch;
        need to check that the lock has at least 3 epochs left, before expiry: current + 2 epochs.

        Example:
        - Epoch 1: User delegates lock; user still retains voting rights of lock 
        - Epoch 2: Delegation takes effect; delegate can now vote with lock
        - Epoch 3: Lock's voting power is forward decay-ed to 0

        Lock must expire at the end of Epoch3 for the above to be feasible. 
        Therefore, the minimum expiry of a lock is currentEpoch + 3 epochs [currentEpoch + 2 more epochs]
    */  
    function minimumDurationCheck(uint128 expiry) internal view returns (uint128) {
        // get current epoch start
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();

        // multiply start by 3, to get the end of the 3rd epoch [lock has 0 voting power in the 3rd epoch]
        require(expiry >= currentEpochStart + (3 * EpochMath.EPOCH_DURATION), Errors.LockExpiresTooSoon());

        return currentEpochStart;
    }

//------------------------------ Internal: Pure-----------------------------------------------------------   

    /** note: for _subtractExpired(), _convertToVeBalance(), _getValueAt()

        On bias & slope calculations, we can use uint128 for all calculations.

        Overflow is mathematically impossible given:
        - Total MOCA supply: 8.89 billion tokens
        - Maximum lock duration: 728 days
        - Reasonable timestamp ranges (through year 2300)

        So if someone locks the entire Moca supply for 728 days [MAX_LOCK_DURATION]:
        - slope = totalAmount / MAX_LOCK_DURATION
        - slope = (8.89 × 10^27) / (62,899,200)
        - slope ≈ 1.413 × 10^20 wei/second
        
        bias = slope × expiry:
        - bias = (1.413 × 10^20) × (4.1 × 10^9)
        - bias ≈ 5.79 × 10^29 wei

        uint128.max = 2^128 - 1 ≈ 3.402 × 10^38 wei
        - Safety Margin = uint128.max / bias
        - Safety Margin = (3.402 × 10^38) / (5.79 × 10^29)
        - Safety Margin ≈ 587 million times

        When would overflow actually occur?
        - Only if someone could lock 587 million times the entire circulating supply in a single lock, which is:
        - Economically impossible (tokens don't exist)
    */

    /**
     * @notice Removes expired locks from a veBalance.
     * @dev Overflow is only possible if 100% of MOCA is locked at the same expiry, which is infeasible in practice.
     *      No SafeCast required as only previously added values are subtracted; 8.89B MOCA supply ensures overflow is impossible.
     *      Does not update global parameter: lastUpdatedAt.
     * @param a The veBalance to update.
     * @param expiringSlope The slope value expiring at the given expiry.
     * @param expiry The timestamp at which the slope expires.
     * @return The updated veBalance with expired values removed.
     */
    function subtractExpired(DataTypes.VeBalance memory a, uint128 expiringSlope, uint128 expiry) internal pure returns (DataTypes.VeBalance memory) {
        uint128 biasReduction = expiringSlope * expiry;

        // defensive: to prevent underflow [should not be possible in practice]
        a.bias = a.bias > biasReduction ? a.bias - biasReduction : 0;      // remove decayed ve
        a.slope = a.slope > expiringSlope ? a.slope - expiringSlope : 0; // remove expiring slopes
        return a;
    }

    // calc. veBalance{bias,slope} from lock; based on expiry time | inception offset is handled by balanceOf() queries
    function convertToVeBalance(DataTypes.Lock memory lock) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veBalance;

        // In practice, this should never overflow given MOCA supply constraints
        veBalance.slope = (lock.moca + lock.esMoca) / EpochMath.MAX_LOCK_DURATION;
        veBalance.bias = veBalance.slope * lock.expiry;

        return veBalance;
    }

    // subtracts b from a: a - b
    function sub(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory res;
            res.bias = a.bias - b.bias;
            res.slope = a.slope - b.slope;

        return res;
    }

    function add(DataTypes.VeBalance memory a, DataTypes.VeBalance memory b) internal pure returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory res;
            res.bias = a.bias + b.bias;
            res.slope = a.slope + b.slope;

        return res;
    }

    // time is timestamp, not duration
    function getValueAt(DataTypes.VeBalance memory a, uint128 timestamp) internal pure returns (uint128) {
        uint128 decay = a.slope * timestamp;

        if(a.bias <= decay) return 0;

        // offset inception inflation
        return a.bias - decay;
    }
}