// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library DataTypes {

// --------- VotingEscrowMoca.sol -------
    struct Lock {
        bytes32 lockId;             // can i remove lockId since ownerAddress can be the flag
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

// --------- PaymentsController.sol -------

    struct Issuer {
        bytes32 issuerId;
        address adminAddress;       // for interacting w/ contract 
        address assetAddress;        // for claiming fees 
                
        // credentials
        uint128 totalVerified; // incremented on each verification
        
        // USD8 | 6dp precision
        uint128 totalFeesAccrued;
        uint128 totalClaimed;
    }

    struct Verifier {
        bytes32 verifierId;
        address adminAddress;
        address signerAddress;
        address assetAddress;   // used for both deposit/withdrawing fees + staking Moca

        uint128 balance;
        uint128 totalExpenditure;
        uint128 totalSubsidies; //todo
    }

    struct Schema {
        bytes32 schemaId;
        bytes32 issuerId;
        
        // fees are expressed in USD8 terms
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       // could use epoch and epochMath?

        // counts
        uint128 totalVerified;
        uint128 totalFeesAccrued;

        // for VotingController
        bytes32 poolId;
    }

    

// ---------- consider removing this -------



    // global view of user's principal
    struct User {
        uint128 moca;
        uint128 esMoca;
    }

    

}
