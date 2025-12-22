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
        address assetManagerAddress;       // for claiming fees 
                
        // credentials
        uint128 totalVerified;            // incremented on each verification
        
        // USD8 | 6dp precision
        uint128 totalNetFeesAccrued;    // net of protocol and voter fees
        uint128 totalClaimed;

        uint128 totalSchemas;       // track schemas created by issuer
    }

    struct Verifier {
        address assetManagerAddress;    // used for both deposit/withdrawing fees + staking Moca
        address signerAddress;

        // MOCA | 18 dp precision
        uint128 mocaStaked;

        // USD8 | 6dp precision
        uint128 currentBalance;
        uint128 totalExpenditure;  // count: never decremented
    }

    struct Schema {
        address issuer;
        
        // fees are expressed in USD8 terms | 6dp precision
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       

        // counts: never decremented
        uint128 totalVerified;
        uint128 totalGrossFeesAccrued;            // disregards protocol and voting fees

        // for VotingController
        uint128 poolId;
    }

    struct SubsidyTier {
        uint128 mocaStaked;           // minimum MOCA required for this tier
        uint128 subsidyPercentage;    // subsidy percentage for this tier
    }

    // epoch accounting: treasury + voters
    struct FeesAccrued {
        uint128 feesAccruedToProtocol;
        uint128 feesAccruedToVoters;

        bool isProtocolFeeWithdrawn;
        bool isVotersFeeWithdrawn;
    }

// --------- VotingController.sol -------


    /* Lifecycle states for epoch finalization:
        Voting: default, voting open, pools can be created/removed
        Ended: voting closed, end-of-epoch processing started
        Verified: verifiers claims checked, awaiting rewards & subsidies allocation
        Processed: all pools processed, awaiting reward deposit
        Finalized: rewards deposited, claims open
        ForceFinalized: admin forced (may block claims)
    */
    enum EpochState {
        Voting,           // 0 - voting open, epoch in progress
        Ended,            // 1 - voting closed, end-of-epoch processing started
        Verified,         // 2 - verifiers claims checked, awaiting rewards & subsidies allocation
        Processed,        // 3 - all pools processed, awaiting finalization
        Finalized,        // 4 - complete, claims open
        ForceFinalized    // 5 - emergency finalization, claims blocked
    }
    
    struct Epoch {
        EpochState state;

        // Pool & Vote Tracking
        uint128 totalActivePools;               // set in depositEpochSubsidies()   
        uint128 poolsProcessed;                 // incremented in processEpochRewardsSubsidies()

        // Allocations
        uint128 totalSubsidiesAllocated;         // set & deposited in depositEpochSubsidies()
        uint128 totalRewardsAllocated;           // accumulated in processEpochRewardsSubsidies()

        // Claims Tracking: esMOCA 
        uint128 totalRewardsClaimed;   
        uint128 totalSubsidiesClaimed;    

        // Unclaimed: withdrawn to treasury (for record-keeping purposes)
        uint128 totalRewardsWithdrawn;   
        uint128 totalSubsidiesWithdrawn;     
    }
    
    // Pool data [global]
    struct Pool {
        bool isActive;                        // flag: indicates pool is active

        uint128 totalVotes;                   // total votes pool accrued throughout all epochs
        uint128 totalRewardsAllocated;        // set in processEpochRewardsSubsidies()
        uint128 totalSubsidiesAllocated;      // set in processEpochRewardsSubsidies()
    }

    // pool data [epoch]
    struct PoolEpoch {
        uint128 totalVotes;
        uint128 totalRewardsAllocated;           // set in processEpochRewardsSubsidies()
        uint128 totalSubsidiesAllocated;         // set in processEpochRewardsSubsidies()

        bool isProcessed;                        // flag for finalization of pool
    }

    // global delegate data
    struct Delegate {
        bool isRegistered;             
        
        uint128 currentFeePct;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
        uint128 nextFeePct;         
        uint128 nextFeePctEpoch;            

        uint128 totalRewardsCaptured;      // total gross rewards accrued by delegate [from delegated votes]
        uint128 totalFeesAccrued;          // total fees accrued by delegate
    }


    // user/delegate data    [perEpoch][perPoolPerEpoch]
    struct Account {
        uint128 totalVotesSpent;       // total votes spent by user [personal] || total votes spent by delegatee [delegated]
        uint128 totalRewards;          // Total gross rewards earned [user get's everything, delegate's fee is based on this]
    }


    struct UserDelegateAccount {
        // Aggregate totals (accumulated during processing)
        uint128 totalGrossRewards;              // Sum of gross rewards across processed pools
        uint128 totalDelegateFees;              // Sum of delegate fees
        uint128 totalNetRewards;                // totalGrossRewards - totalDelegateFees
        
        // Aggregate claimed (updated during actual transfers)
        uint128 userClaimed;                    // Total NET claimed by user
        uint128 delegateClaimed;                // Total FEES claimed by delegate
        
        // Per-pool tracking (for processing only)
        mapping(uint128 poolId => uint128 grossRewards) userPoolGrossRewards;
        mapping(uint128 poolId => bool) poolProcessed;
    }


    struct VerifierEpoch {
        bool isBlocked;
        uint128 totalSubsidiesClaimed;
    }


// --------- VotingEscrowMoca.sol -------

    struct Lock {
        address owner;              
        uint128 expiry;        // timestamp when lock ends

        // locked principal
        uint128 moca;    
        uint128 esMoca;
            
        bool isUnlocked;       // flag: indicates lock's principals are returned
        address delegate;           // flag: zero = not delegated, non-zero = delegated
 
        // Delegation tracking
        address currentHolder;     // current holder until delegationEpoch (pending scenario)
        uint96 delegationEpoch;    // epoch start when delegate field becomes effective; 0 = none
    }

    // Aggregation: global + user
    struct VeBalance {
        uint128 bias;
        uint128 slope;
    }

    // Checkpoint
    struct Checkpoint {
        VeBalance veBalance;
        uint128 lastUpdatedAt;
    }

    struct VeDeltas {
        bool hasAddition;
        bool hasSubtraction;
        DataTypes.VeBalance additions;
        DataTypes.VeBalance subtractions;
    }

    // for delegateLock, switchDelegate, undelegateLock
    enum DelegationType {
        Delegate,
        Switch,
        Undelegate
    }

    

// --------- EscrowedMoca.sol -------

    struct RedemptionOption {
        uint128 lockDuration;    // Seconds until redemption is available; 0 for instant redemption
        uint128 receivablePct;   // Percentage of redemption amount user receives; cannot be 0
        //2 dp (XX.yy), 1–10_000 (100%: 10_000, 1%: 100, 0.1%: 10, 0.01%: 1)

        bool isEnabled;
    }

}