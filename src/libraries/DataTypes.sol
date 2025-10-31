// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title DataTypes
 * @author Calnix [@cal_nix]
 * @notice Library for data types used across the Moca protocol.
 * @dev Provides data structures for protocol entities.
 */

library DataTypes {

// --------- PaymentsController.sol -------

    struct Issuer {
        bytes32 issuerId;
        address adminAddress;              // for interacting w/ contract 
        address assetManagerAddress;       // for claiming fees 
                
        // credentials
        uint128 totalVerified; // incremented on each verification
        
        // USD8 | 6dp precision
        uint128 totalNetFeesAccrued;    // net of protocol and voter fees
        uint128 totalClaimed;

        uint128 totalSchemas;       // track schemas created by issuer
    }

    struct Verifier {
        bytes32 verifierId;
        address adminAddress;           // msg.sender   
        address assetManagerAddress;    // used for both deposit/withdrawing fees + staking Moca
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

        // rewards + subsidies
        uint128 totalRewardsAllocated;           // set+deposited in finalizeEpochRewardsSubsidies()
        uint128 totalSubsidiesDeposited;         // deposited subsidies; set in depositEpochSubsidies()

        // claimed: esMOCA 
        uint128 totalRewardsClaimed;   
        uint128 totalSubsidiesClaimed;      

        // epochEnd: flags
        uint128 poolsFinalized;         // incremented in finalizeEpochRewardsSubsidies()
        bool isSubsidiesSet;            // set in depositEpochSubsidies()
        bool isFullyFinalized;          // set in finalizeEpochRewardsSubsidies()
        bool residualsWithdrawn;        // set in withdrawResidualSubsidies()
    }
    
    // Pool data [global]
    struct Pool {
        bytes32 poolId;         // poolId = credentialId  
        bool isRemoved;         // flag: indicates pool has been removed permanently

        // global metrics TODO: review
        uint128 totalVotes;             // total votes pool accrued throughout all epochs
        uint128 totalRewardsAllocated;           // set in finalizeEpochRewardsSubsidies()
        uint128 totalSubsidiesAllocated;         // set in finalizeEpochRewardsSubsidies()

        // claimed: esMOCA 
        uint128 totalSubsidiesClaimed;  
        uint128 totalRewardsClaimed;    
    }

    // pool data [epoch]
    struct PoolEpoch {
        uint128 totalVotes;
        uint128 totalRewardsAllocated;           // set in finalizeEpochRewardsSubsidies()
        uint128 totalSubsidiesAllocated;         // set in finalizeEpochRewardsSubsidies()

        // claimed: esMOCA 
        uint128 totalRewardsClaimed;    
        uint128 totalSubsidiesClaimed;  
        
        // flag for finalization
        bool isProcessed;
    }

    // global delegate data
    struct Delegate {
        bool isRegistered;             
        
        uint128 currentFeePct;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
        uint128 nextFeePct;         
        uint256 nextFeePctEpoch;            

        uint128 totalRewardsCaptured;      // total gross rewards accrued by delegate [from delegated votes]
        uint128 totalFees;               // total fees accrued by delegate
        uint128 totalFeesClaimed;        // total fees claimed by delegate
    }


    // user/delegate data     | perEpoch | perPoolPerEpoch
    struct Account {
        uint128 totalVotesSpent;      // total votes spent by user [personal] || total votes spent by delegatee [delegated]
        uint128 totalRewards;         // user: total rewards || delegate: total gross rewards accrued [from delegated votes]
        // the delegate cannot claim totalRewards; they can only claim by applying their fee
    }

    struct OmnibusDelegateAccount {
        uint128 totalNetRewards;    // claimed by user
        mapping(bytes32 poolId => uint128 grossRewards) userPoolGrossRewards; // flag: 0 = not claimed, non-zero = claimed
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
    }

// --------- EscrowedMoca.sol -------

    struct RedemptionOption {
        uint128 lockDuration;    // Seconds until redemption is available; 0 for instant redemption
        uint128 receivablePct;   // Percentage of redemption amount user receives; cannot be 0
        //2 dp (XX.yy), 1–10_000 (100%: 10_000, 1%: 100, 0.1%: 10, 0.01%: 1)

        bool isEnabled;
    }

    struct Redemption {
        uint256 mocaReceivable;
        uint256 penalty;   
        uint256 claimed;  
    }
}
