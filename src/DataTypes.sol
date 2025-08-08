// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library DataTypes {

    struct Lock {
        bytes32 lockId;
        address owner;
        address delegate;           // flag: zero = not delegated, non-zero = delegated

        // locked principal
        uint128 moca;    
        uint128 esMoca;
            
        uint128 expiry;        // timestamp when lock ends
        bool isUnlocked;       // flag: indicates lock's principals are returned
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

    // note: for bool isDelegated, we could use enum BalanceType { Personal, Delegated }
    // meh, feels like more overhead
    enum BalanceType { 
        Personal, 
        Delegated
    }



// ---------- consider removing this -------



    // global view of user's principal
    struct User {
        uint128 moca;
        uint128 esMoca;
    }

    

}
