// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library DataTypes {

    struct Lock {
        bytes32 lockId;
        address creator;

        // locked principal
        uint128 moca;    
        uint128 esMoca;
            
        uint128 expiry;             // timestamp when lock ends
        bool isWithdrawn;           // flag to indicate if the lock has been withdrawn
    }
    
    // Checkpoint
    struct Checkpoint {
        VeBalance veBalance;
        uint128 lastUpdatedAt;
    }

    // Aggregation: global + user
    struct VeBalance {
        uint128 bias;
        uint128 slope;
        // permanentLockBalance
    }








    // global view of user's principal
    struct User {
        uint128 moca;
        uint128 esMoca;
    }

    

}
