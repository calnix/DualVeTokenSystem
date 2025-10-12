// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Errors
 * @author Calnix [@cal_nix]
 * @notice Library for error messages used across the Moca protocol.
 * @dev Provides error messages for protocol functions.
 */

library Errors {

    // --------- Generic ---------
    error InvalidId();
    error InvalidUser(); 
    error InvalidAmount();
    error InvalidFeePct();
    error InvalidAddress();
    error InvalidExpiry();
    error InvalidEpoch();
    error InvalidArray();
    error MismatchedArrayLengths();
    error InvalidPercentage();
    error InvalidDelayPeriod();
    error NotFrozen();
    error IsFrozen();
    error NoFeesToClaim();

// --------- PaymentsController.sol ---------
    error InvalidCaller();
    error InvalidIssuer();
    error InvalidSchema();
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
    error IsNonTransferable();
    error InvalidLockId();
    error InvalidLockState();
    error InvalidOwner();
    error InvalidEpochTime();
    error InvalidDelegate();
    error LockExpiresTooSoon();
    error PrincipalsAlreadyReturned();
    error InvalidTimestamp();

// --------- VotingController.sol ---------
    error EpochNotEnded();
    error EpochFinalized();
    error EpochNotFinalized();
    error NoAvailableVotes();
    error ZeroVotes();
    error PoolDoesNotExist();
    error PoolRemoved();
    error InsufficientVotes();
    error InvalidPoolPair();

    // delegation
    error DelegateAlreadyRegistered();
    error DelegateNotRegistered();
    error CannotUnregisterWithActiveVotes();
    //voterClaimRewards
    error NoRewardsToClaim();
    //claimSubsidies
    error NoSubsidiesToClaim();
    error FutureEpoch();
    error NoVotesInPool();
    error NoSubsidiesForPool(); 
    error SubsidyAlreadyClaimed();
    error RebaseOverflow();
    // depositSubsidies
    error CannotSetSubsidiesForFutureEpochs();
    error SubsidiesAlreadySet();
    error InsufficientSubsidies();
    //depositRewards
    error RewardsAlreadySet();
    // finalizeEpochRewardsSubsidies
    error SubsidyPerVoteZero();
    error SubsidiesNotSet();
    error PoolAlreadyProcessed();
    
    // withdrawUnclaimedSubsidies & withdrawUnclaimedRewards
    error NoUnclaimedRewardsToWithdraw();
    error CanOnlyWithdrawUnclaimedAfterDelay();
    // withdrawRegistrationFees
    error NoRegistrationFeesToWithdraw();

    // removePool
    error EndOfEpochOpsUnderway();

// --------- EscrowedMoca.sol ---------
    error RedemptionNotAvailableYet();
    error NothingToClaim();
    error RedemptionOptionAlreadyEnabled();
    error RedemptionOptionAlreadyDisabled();
    error WhitelistStatusUnchanged();
    error OnlyCallableByWhitelistedAddress();
    error TotalMocaEscrowedExceeded();

// --------- AccessController.sol ---------
    error CallerNotRiskOrPoolAdmin();
    error OnlyCallableByAssetManager();
    error OnlyCallableByMonitor();
    error OnlyCallableByCronJob();
    error OnlyCallableByGlobalAdmin();
    error OnlyCallableByEmergencyExitHandler();
    error OnlyCallableByEscrowedMocaAdmin();
    error OnlyCallableByVotingControllerAdmin();
    error OnlyCallableByPaymentsControllerAdmin();

    error OnlyCallableByVotingControllerContract();
    // transferGlobalAdminFromAddressBook
    error OnlyCallableByAddressBook();
    error OldAdminDoesNotHaveRole();

}