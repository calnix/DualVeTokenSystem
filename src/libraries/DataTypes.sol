// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library DataTypes {

// --------- PaymentsController.sol -------

    struct Issuer {
        bytes32 issuerId;
        address adminAddress;       // for interacting w/ contract 
        address assetAddress;       // for claiming fees 
                
        // credentials
        uint128 totalVerified; // incremented on each verification
        
        // USD8 | 6dp precision
        uint128 totalNetFeesAccrued;    // net of protocol and voter fees
        uint128 totalClaimed;
    }

    struct Verifier {
        bytes32 verifierId;
        address adminAddress;
        address assetAddress;   // used for both deposit/withdrawing fees + staking Moca
        address signerAddress;

        // MOCA | 18 dp precision
        uint128 mocaStaked;

        // USD8 | 6dp precision
        uint128 currentBalance;
        uint128 totalExpenditure;  // count: never decremented
    }

    struct Schema {
        bytes32 schemaId;
        bytes32 issuerId;
        
        // fees are expressed in USD8 terms | 6dp precision
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       

        // counts: never decremented
        uint128 totalVerified;
        uint128 totalGrossFeesAccrued;            // disregards protocol and voting fees

        // for VotingController
        bytes32 poolId;
    }

    // epoch accounting: treasury + voters
    struct FeesAccrued {
        uint128 feesAccruedToProtocol;
        uint128 feesAccruedToVoters;

        bool isProtocolFeeWithdrawn;
        bool isVotersFeeWithdrawn;
    }

// --------- VotingController.sol -------


    struct Epoch {
        uint128 totalVotes;
        
        // verifier subsidies
        uint128 totalSubsidies;               // Total esMOCA subsidies: set in depositSubsidies()
        //uint128 subsidyPerVote;               // set in depositSubsidies()
        uint128 totalSubsidiesClaimed;        // Total esMOCA subsidies claimed

        // voting rewards
        uint128 totalRewards;           // Total esMoca rewards: set in depositRewards()
        uint128 totalRewardsClaimed;    // Total esMoca rewards claimed

        // epochEnd: flags
        bool isSubsidyPerVoteSet;       // flag set in depositSubsidies()
        bool isRewardsPerVoteSet;       // flag set in depositRewards()
        uint128 poolsFinalized;         // number of pools that have been finalized for this epoch
        bool isFullyFinalized;          // flag set in finalizeEpochRewardsSubsidies()
    }
    
    // Pool data [global]
    struct Pool {
        bytes32 poolId;         // poolId = credentialId  
        bool isActive;          // active+inactive: pause pool

        // global metrics TODO: review
        uint128 totalVotes;             // total votes pool accrued throughout all epochs
        uint128 totalSubsidies;         // allocated esMOCA subsidies: based on EpochData.subsidyPerVote
        uint128 totalRewards;           // set in finalizeEpochRewardsSubsidies()
        uint128 totalSubsidiesClaimed;  
        uint128 totalRewardsClaimed;    
    }

    // pool data [epoch]
    struct PoolEpoch {
        uint128 totalVotes;
        
        uint128 totalRewards;           // set in finalizeEpochRewardsSubsidies()
        uint128 totalRewardsClaimed;    // total gross rewards claimed 
    
        // verifier data
        uint128 totalSubsidies;         // allocated esMoca subsidies: based on EpochData.subsidyPerVote
        uint128 totalSubsidiesClaimed;  
    }

    // delegate data
    struct Delegate {
        bool isRegistered;             
        uint128 currentFeePct;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
        
        // fee change
        uint128 nextFeePct;       // to be in effect for next epoch
        uint128 nextFeePctEpoch;  // epoch of next fee change

        uint128 totalRewardsCaptured;      // total gross voting rewards accrued by delegate [from delegated votes]
        uint128 totalFees;                 // total fees accrued by delegate
        uint128 totalFeesClaimed;          // total fees claimed by delegate
    }


    // user data     | perEpoch | perPoolPerEpoch
    // delegate data | perEpoch | perPoolPerEpoch
    struct Account {
        uint128 totalVotesSpent;
        uint128 totalRewards;       // total accrued rewards
    }

    struct UserDelegateAccount {
        uint128 totalNetClaimed;
        mapping(bytes32 poolId => uint128 grossRewards) poolGrossRewards;
    }

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

// ---------- consider removing this -------



    // global view of user's principal
    struct User {
        uint128 moca;
        uint128 esMoca;
    }

    

}
