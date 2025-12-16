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
    error InvalidIndex();
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
    error NothingToClaim();
    error NoFeesToClaim();
    error InvalidTimestamp();
    error InsufficientBalance();
    error InvalidGasLimit();
    error OnlyCallableByEmergencyExitHandlerOrIssuer();

// --------- PaymentsController.sol ---------
    error InvalidCaller();
    error InvalidIssuer();
    error IssuerDoesNotExist();
    error VerifierDoesNotExist();
    error IssuerAlreadyExists();
    error VerifierAlreadyExists();
    error InvalidSchema();
    error SignatureExpired();
    error NoClaimableFees();
    error InvalidSchemaFee();
    error InvalidSignature();
    error ZeroProtocolFee();
    error ProtocolFeeAlreadyWithdrawn();
    error VotersFeeAlreadyWithdrawn();
    error ZeroVotersFee();
    error InvalidMocaStakedTierOrder();
    error InvalidSubsidyPercentageTierOrder();
    error DuplicateTierIndex();
    error OnlyCallableByEmergencyExitHandlerOrVerifier();
    error PoolNotWhitelisted();
    error PoolWhitelistedStatusUnchanged();

// --------- VotingEscrowMoca.sol ---------
    error LockExpired();
    error InvalidLockDuration();
    error IsNonTransferable();
    error InvalidLockId();
    error InvalidLockState();
    error InvalidOwner();
    error LockAlreadyDelegated();
    error InvalidEpochTime();
    error InvalidDelegate();
    error LockNotDelegated();
    error LockExpiresTooSoon();
    error PrincipalsAlreadyReturned();
    error OnlyCallableByVotingEscrowMocaAdmin();
    error OnlyCallableByVotingControllerContract();

// --------- VotingController.sol ---------
    error EpochNotEnded();
    error EpochFinalized();
    error EpochNotFinalized();
    error NoAvailableVotes();
    error ZeroVotes();
    error PoolNotActive();
    error PoolRemoved();
    error InsufficientVotes();
    error InvalidPoolPair();
    error PoolHasNoRewards();
    
    // delegation
    error DelegateAlreadyRegistered();
    error NotRegisteredAsDelegate();
    error CannotUnregisterWithActiveVotes();

    //voterClaimRewards
    error NoRewardsToClaim();
    error AlreadyClaimedOrNoRewardsToClaim();
    
    //claimSubsidies
    error NoSubsidiesToClaim();
    error FutureEpoch();
    error NoVotesInPool();
    error NoSubsidiesForPool(); 
    error SubsidyAlreadyClaimed();
    // depositSubsidies
    error SubsidiesAlreadySet();
    error InsufficientSubsidies();
    //depositRewards
    error RewardsAlreadyDeposited();
    // finalizeEpochRewardsSubsidies
    error SubsidyPerVoteZero();
    error SubsidiesNotSet();
    error PoolAlreadyProcessed();
    
    // withdrawUnclaimedSubsidies & withdrawUnclaimedRewards
    error NoUnclaimedRewardsToWithdraw();
    error CanOnlyWithdrawUnclaimedAfterDelay();
    error RewardsAlreadyWithdrawn();
    error SubsidiesAlreadyWithdrawn();
    // withdrawRegistrationFees
    error NoRegistrationFeesToWithdraw();

    // removePool
    error EndOfEpochOpsUnderway();

// --------- EscrowedMoca.sol ---------
    error InvalidRedemptionOption();
    error InvalidRedemptionTimestamp();
    error RedemptionOptionAlreadyEnabled();
    error RedemptionOptionAlreadyDisabled();
    error WhitelistStatusUnchanged();
    error OnlyCallableByWhitelistedAddress();
    error TotalMocaEscrowedExceeded();
    error OnlyCallableByEmergencyExitHandlerOrUser();

// --------- IssuerStakingController.sol ---------
    error TransferFailed();
}