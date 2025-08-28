// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Errors {

    // --------- Generic ---------
    error InvalidUser(); 
    error InvalidAmount();
    error InvalidExpiry();
    error InvalidLockDuration();
    error InvalidArray();
    error MismatchedArrayLengths();


    error IsFrozen();

    // Access control
    error CallerNotRiskOrPoolAdmin();


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

}