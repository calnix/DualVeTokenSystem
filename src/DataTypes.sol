// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

library DataTypes {

    struct VeBalance {
        uint128 bias;
        uint128 slope;
        uint128 lastUpdatedAt;
        // permanentLockBalance
    }

    struct LockedPosition {
        bytes32 lockId;
        address creator;

        // locked principal
        uint128 moca;    
        uint128 esMoca;
        
        uint128 expiry;             // timestamp when lock ends
    }

    // global view of user
    struct User {
        uint128 moca;
        uint128 esMoca;

        uint128 bias;                           // total bias
        uint128 slope;                          // sum of slopes of all decay curves
        uint128 lastSlopeChangeAppliedAt;       // last time the slope was updated
    }

    
    enum DepositType {
        CREATE_LOCK,
        INCREASE_LOCK_AMOUNT,
        INCREASE_DURATION
        //DEPOSIT_FOR
    }

}
