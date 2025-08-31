// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Errors {

    // --------- Generic ---------
    error InvalidUser(); 
    error InvalidAmount();
    error InvalidAddress();
    error InvalidExpiry();
    error InvalidEpoch();
    error InvalidArray();
    error MismatchedArrayLengths();
    error InvalidFeePercentage();
    error InvalidDelayPeriod();
    error IsFrozen();

    // Access control
    error CallerNotRiskOrPoolAdmin();

// --------- PaymentsController.sol ---------
    error InvalidCaller();
    error InvalidId();
    error SignatureExpired();
    error NoClaimableFees();
    error InvalidSchemaFee();
    error InsufficientBalance();
    error InvalidSignature();
    error ZeroProtocolFee();
    error ProtocolFeeAlreadyWithdrawn();
    error VotersFeeAlreadyWithdrawn();
    error ZeroVotersFee();

// --------- VotingEscrowMoca.sol ---------
    error InvalidLockDuration();
    


// --------- VotingController.sol ---------
    error EpochFinalized();
    error NoSpareVotes();
    error InvalidFeePct();
    error ZeroVotes();
    error PoolDoesNotExist();
    error PoolNotActive();
    error InsufficientVotes();
    // delegation
    error DelegateAlreadyRegistered();
    error DelegateNotRegistered();
    //claimRewards
    error NoRewardsToClaim();
    //claimSubsidies
    error FutureEpoch();
    error NoVotesInPool();
    error NoSubsidiesToClaim();
    error NoSubsidiesAccrued();
    error SubsidyAlreadyClaimed();
    // finalizeEpoch
    error SubsidyPerVoteZero();
    // depositSubsidies
    error CanOnlySetSubsidiesForFutureEpochs();
    error InsufficientSubsidies();
    // withdrawUnclaimedSubsidies
    error CanOnlyWithdrawUnclaimedSubsidiesAfterDelay();
    // depositRewards
    error NoRewardsAccrued();

}