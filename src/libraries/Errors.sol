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
    error DelegateNotRegistered();
    error LockNotDelegated();
    error LockExpiresTooSoon();
    error PrincipalsAlreadyReturned();
    error OnlyCallableByVotingEscrowMocaAdmin();
    error OnlyCallableByVotingControllerContract();

// --------- VotingController.sol ---------
    // epoch
    error InvalidEpochState();
    error EpochAlreadyFinalized();
    error EpochNotFinalized();
    error EpochNotProcessed();
    error PreviousEpochNotFinalized();
    // votes
    error NoAvailableVotes();
    error ZeroVotes();
    error InsufficientVotes();
    // pool
    error PoolNotActive();
    error InvalidPoolPair();
    error PoolHasNoRewards();
    error PoolHasNoSubsidies();
    error NoVotesInPool();
    // claiming
    error AlreadyClaimed();
    error NoRewardsToClaim();
    // _claimRewardsInternal
    error ZeroDelegatedVP();
    error ZeroDelegatePoolRewards();
    error ZeroUserGrossRewards();
    error InsufficientRewardsClaimable();
    
    // delegation
    error DelegateAlreadyRegistered();
    error NotRegisteredAsDelegate();
    error CannotUnregisterWithActiveVotes();
        
    // claimSubsidies
    error ClaimsBlocked();
    error NoSubsidiesToClaim();
    error NoSubsidiesForPool(); 
    error VerifierAccruedSubsidiesGreaterThanPool();
    error InsufficientSubsidiesClaimable();
   
    // endEpoch
    error EpochNotOver();
    // processRewardsAndSubsidies
    error EpochNotVerified();
    error SubsidyPerVoteZero();
    error SubsidiesNotSet();
    error PoolAlreadyProcessed();
    
    // withdrawUnclaimedSubsidies & withdrawUnclaimedRewards
    error NoUnclaimedRewardsToWithdraw();
    error NoUnclaimedSubsidiesToWithdraw();
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