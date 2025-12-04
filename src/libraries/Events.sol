// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "./DataTypes.sol";

/**
 * @title Events
 * @author Calnix [@cal_nix]
 * @notice Library for events used across the Moca protocol.
 * @dev Provides events for protocol functions.
 */
    
library Events {
    
// --------- Generic: Risk ---------
    event ContractFrozen();
    event MocaTransferGasLimitUpdated(uint256 oldMocaTransferGasLimit, uint256 newMocaTransferGasLimit);

// --------- EscrowedMoca.sol ---------
    // escrow()
    event EscrowedMoca(address indexed caller, uint256 amount);
    // redeem()
    event RedemptionScheduled(address indexed caller, uint256 mocaReceivable, uint256 penaltyAmount, uint256 redemptionTimestamp);
    event PenaltyAccrued(uint256 penaltyToVoters, uint256 penaltyToTreasury);
    event Redeemed(address indexed caller, uint256 mocaReceivable, uint256 penaltyAmount);
    // claimRedemption()
    event RedemptionsClaimed(address indexed caller, uint256[] redemptionTimestamps, uint256[] mocaReceivables);
    // stakeOnBehalf()
    event StakedOnBehalf(address[] callers, uint256[] amounts);
    // setPenaltyToVoters()
    event VotersPenaltyPctUpdated(uint256 oldVotersPenaltyPct, uint256 newVotersPenaltyPct);
    // setRedemptionOption()
    event RedemptionOptionUpdated(uint256 redemptionOption, uint256 lockDuration, uint256 receivablePct);
    // setRedemptionOptionStatus()
    event RedemptionOptionEnabled(uint256 redemptionOption, uint256 receivablePct, uint256 lockDuration);
    event RedemptionOptionDisabled(uint256 redemptionOption);
    // setWhitelistStatus()
    event AddressWhitelisted(address[] addresses, bool isWhitelisted);
    // releaseEscrowedMoca()
    event EscrowedMocaReleased(address indexed caller, uint256 amount);
    // claimPenalty()
    event PenaltyClaimed(address indexed treasury, uint256 totalClaimable);
    // emergencyExit
    event EmergencyExitEscrowedMoca(address[] users, uint256 totalMoca);

// --------- VotingEscrowMoca.sol ---------
    
    event GlobalUpdated(uint128 bias, uint128 slope);
    event UserUpdated(address indexed user, uint128 bias, uint128 slope);
    event AccountUpdated(address indexed account, uint128 bias, uint128 slope);

    // create lock
    event LockCreated(bytes32 indexed lockId, address indexed owner, uint256 moca, uint256 esMoca, uint256 expiry);
    // increaseAmount
    event LockAmountIncreased(bytes32 indexed lockId, address indexed owner, address delegate, uint128 mocaToAdd, uint128 esMocaToAdd);
    // increaseDuration
    event LockDurationIncreased(bytes32 indexed lockId, address indexed owner, address delegate, uint256 oldExpiry, uint256 newExpiry);
    // unlock
    event LockUnlocked(bytes32 indexed lockId, address indexed owner, uint256 moca, uint256 esMoca);
    
    // createLockFor
    event LocksCreatedFor(address[] users, bytes32[] lockIds, uint256 totalMoca, uint256 totalEsMoca);
    
    // delegate: register, unregister
    event DelegateRegistrationStatusUpdated(address indexed delegate, bool isRegistered);
    
    // delegateLock
    event LockDelegated(bytes32 indexed lockId, address indexed owner, address delegate);
    event DelegateUpdated(address indexed delegate, uint128 bias, uint128 slope);
    event DelegatedAggregationUpdated(address indexed user, address indexed delegate, uint128 bias, uint128 slope);
    // switchDelegate
    event LockDelegateSwitched(bytes32 indexed lockId, address indexed owner, address oldDelegate, address newDelegate);
    // undelegateLock
    event LockUndelegated(bytes32 indexed lockId, address indexed owner, address delegate);

    // setVotingController
    event VotingControllerUpdated(address newVotingController);


    // emergencyExit
    event EmergencyExit(bytes32[] lockIds, uint256 validLocks, uint256 totalMocaReturned, uint256 totalEsMocaReturned);


// --------- VotingController.sol ---------
    // createPool(), removePool()
    event PoolCreated(bytes32 indexed poolId);
    event PoolRemoved(bytes32 indexed poolId);

    // vote(), migrateVotes()
    event Voted(uint256 indexed epoch, address indexed caller, bytes32[] poolIds, uint128[] votes, bool isDelegated);
    event VotesMigrated(uint256 indexed epoch, address indexed caller, bytes32[] srcPoolIds, bytes32[] dstPoolIds, uint128[] votes, bool isDelegated);
    // delegate
    event DelegateRegistered(address indexed delegate, uint256 feePct);
    event DelegateFeeDecreased(address indexed delegate, uint256 currentFeePct, uint256 feePct);
    event DelegateFeeIncreased(address indexed delegate, uint256 currentFeePct, uint256 feePct, uint256 nextFeePctEpoch);
    event ClaimDelegateFees(address indexed delegate, uint256 feesClaimed);
    // voterClaimRewards
    event RewardsClaimed(address indexed caller, uint256 epoch, bytes32[] poolIds, uint256 totalClaimableRewards);
    // claimDelegateFees
    event RewardsClaimedFromDelegate(uint256 indexed epoch, address indexed caller, address indexed delegate, bytes32[] poolIds, uint256 totalClaimableRewards);
    // claimRewardsFromDelegate
    event RewardsClaimedFromDelegateBatch(uint256 indexed epoch, address indexed caller, address[] delegateList, bytes32[][] poolIdsPerDelegate, uint256 userTotalNetRewards);
    event DelegateFeesClaimed(address indexed delegate, uint256 feesClaimed);
    // delegateClaimFeesFromDelegators
    event RewardsForceClaimedByDelegate(uint256 indexed epoch, address indexed delegator, address indexed delegate, bytes32[] poolIds, uint256 totalClaimableRewards);

    // claimSubsidies
    event SubsidiesClaimed(address indexed verifier, uint256 epoch, bytes32[] poolIds, uint256 totalSubsidiesClaimed);


    // depositSubsidies
    event SubsidiesDeposited(address indexed depositor, uint256 epoch, uint256 totalSubsidies);
    event SubsidiesSet(uint256 indexed epoch, uint256 totalSubsidies);

    // withdrawUnclaimedSubsidies & withdrawUnclaimedRewards & withdrawRegistrationFees
    event UnclaimedRewardsWithdrawn(address indexed treasury, uint256 indexed epoch, uint256 unclaimedRewards);
    event UnclaimedSubsidiesWithdrawn(address indexed treasury, uint256 indexed epoch, uint256 unclaimedSubsidies);
    event RegistrationFeesWithdrawn(address indexed treasury, uint256 claimableRegistrationFees);

    // setMaxDelegateFeePct
    event MaxDelegateFeePctUpdated(uint256 maxDelegateFeePct);
    // setFeeIncreaseDelayEpochs
    event FeeIncreaseDelayEpochsUpdated(uint256 delayEpochs);
    // setUnclaimedDelay
    event UnclaimedDelayUpdated(uint256 indexed oldDelay, uint256 indexed newDelay);
    // setDelegateRegistrationFee
    event DelegateRegistrationFeeUpdated(uint256 oldRegistrationFee, uint256 newRegistrationFee);

    // finalizeEpoch
    event EpochSubsidyPerVoteSet(uint256 indexed epoch, uint256 subsidyPerVote);
    event EpochPartiallyFinalized(uint256 indexed epoch, bytes32[] poolIds);
    event EpochFullyFinalized(uint256 indexed epoch);

    // emergencyExit
    event EmergencyExit(address indexed treasury);

// --------- PaymentsController.sol ---------
    event IssuerCreated(address indexed issuer, address assetManagerAddress);
    event VerifierCreated(address indexed verifier, address signerAddress, address assetManagerAddress);
    event SchemaCreated(bytes32 indexed schemaId, address indexed issuer, uint256 fee);
    // updateSchemaFee
    event SchemaFeeReduced(bytes32 indexed schemaId, uint256 newFee, uint256 currentFee);
    event SchemaNextFeeSet(bytes32 indexed schemaId, uint256 newFee, uint256 nextFeeTimestamp, uint256 currentFee);
    event SchemaFeeIncreased(bytes32 indexed schemaId, uint256 oldFee, uint256 newFee);
    // claimFees
    event IssuerFeesClaimed(address indexed issuer, uint256 claimableFees);

    // verifier: deposit(), withdraw(), stakeMoca(), unstakeMoca()
    event VerifierDeposited(address indexed verifier, address indexed assetManagerAddress, uint128 amount);
    event VerifierWithdrew(address indexed verifier, address indexed assetManagerAddress, uint128 amount);
    event VerifierMocaStaked(address indexed verifier, address indexed assetManagerAddress, uint256 amount);
    event VerifierMocaUnstaked(address indexed verifier, address indexed assetManagerAddress, uint256 amount);
    event VerifierSignerAddressUpdated(address indexed verifier, address newSignerAddress);

    // updateAssetManagerAddress
    event AssetManagerAddressUpdated(address indexed verifierOrIssuer, address newAssetAddress);

    // deductBalance()
    event SubsidyBooked(address indexed verifier, bytes32 indexed poolId, bytes32 indexed schemaId, uint256 subsidy);
    event BalanceDeducted(address indexed verifier, bytes32 indexed schemaId, address indexed issuer, uint256 amount);
    event SchemaVerified(bytes32 indexed schemaId);
    event SchemaVerifiedZeroFee(bytes32 indexed schemaId);

    // --- admin update fns ---
    // update poolId for schema
    event PoolIdUpdated(bytes32 indexed schemaId, bytes32 indexed poolId);
    // whitelist pool
    event PoolWhitelistedUpdated(bytes32 indexed poolId, bool isWhitelisted);
    // update fee increase delay period
    event FeeIncreaseDelayPeriodUpdated(uint256 newDelayPeriod);
    // update protocol fee percentage
    event ProtocolFeePercentageUpdated(uint256 protocolFeePercentage);
    // update voting fee percentage
    event VotingFeePercentageUpdated(uint256 voterFeePercentage);
    // set verifier staking tiers
    event VerifierStakingTiersSet(uint128[] mocaStaked, uint128[] subsidyPercentages);
    // clear verifier staking tiers
    event VerifierStakingTiersCleared();

    // --- cronJob events ---
    // cronJob: withdrawProtocolFees, withdrawVotersFees
    event ProtocolFeesWithdrawn(uint256 epoch, uint256 protocolFees);
    event VotersFeesWithdrawn(uint256 epoch, uint256 votersFees);

    // --- default admin events ---
    // setPaymentsControllerTreasury
    event PaymentsControllerTreasuryUpdated(address oldTreasuryAddress, address newTreasuryAddress);

    // emergencyExit
    event EmergencyExitIssuers(address[] issuers);
    event EmergencyExitVerifiers(address[] verifiers);
    event EmergencyExitFees(address indexed treasury, uint256 totalUnclaimedFees);

// --------- AccessController.sol ---------
    // Treasury
    event VotingControllerTreasuryUpdated(address oldTreasuryAddress, address newTreasuryAddress);
    event EsMocaTreasuryUpdated(address oldTreasuryAddress, address newTreasuryAddress);
    // Monitor admin functions
    event MonitorAdminRemoved(address indexed admin, address indexed removedBy);
    event MonitorAdminAdded(address indexed admin, address indexed addedBy);
    // Monitor role functions
    event MonitorAdded(address indexed monitor, address indexed addedBy);
    event MonitorRemoved(address indexed monitor, address indexed removedBy);
    // CronJob role functions
    event CronJobAdded(address indexed cronJob, address indexed addedBy);
    event CronJobRemoved(address indexed cronJob, address indexed removedBy);
    // CronJob admin functions
    event CronJobAdminAdded(address indexed admin, address indexed addedBy);
    event CronJobAdminRemoved(address indexed admin, address indexed removedBy);
    // IssuerStakingController admin functions
    event IssuerStakingControllerAdminAdded(address indexed admin, address indexed addedBy);
    event IssuerStakingControllerAdminRemoved(address indexed admin, address indexed removedBy);
    // PaymentsController admin functions
    event PaymentsControllerAdminAdded(address indexed admin, address indexed addedBy);
    event PaymentsControllerAdminRemoved(address indexed admin, address indexed removedBy);
    // VotingController admin functions
    event VotingControllerAdminAdded(address indexed admin, address indexed addedBy);
    event VotingControllerAdminRemoved(address indexed admin, address indexed removedBy);
    // VotingEscrowMocaAdmin functions
    event VotingEscrowMocaAdminAdded(address indexed admin, address indexed addedBy);
    event VotingEscrowMocaAdminRemoved(address indexed admin, address indexed removedBy);
    // EscrowedMocaAdmin functions
    event EscrowedMocaAdminAdded(address indexed admin, address indexed addedBy);
    event EscrowedMocaAdminRemoved(address indexed admin, address indexed removedBy);
    // AssetManager role functions
    event AssetManagerAdded(address indexed manager, address indexed addedBy);
    event AssetManagerRemoved(address indexed manager, address indexed removedBy);
    // EmergencyExitHandler role functions
    event EmergencyExitHandlerAdded(address indexed handler, address indexed addedBy);
    event EmergencyExitHandlerRemoved(address indexed handler, address indexed removedBy);
    // Global admin functions
    event GlobalAdminAdded(address indexed admin, address indexed addedBy);
    event GlobalAdminRemoved(address indexed admin, address indexed removedBy);
    // transferGlobalAdminFromAddressBook
    event GlobalAdminTransferred(address indexed oldAdmin, address indexed newAdmin);

// --------- IssuerStakingController.sol ---------
    // users
    event Staked(address indexed caller, uint256 amount);
    event UnstakeInitiated(address indexed caller, uint256 amount, uint256 claimableTimestamp);
    event UnstakeClaimed(address indexed caller, uint256 amount);
    // restricted functions
    event UnstakeDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event MaxSingleStakeAmountUpdated(uint256 oldMaxSingleStakeAmount, uint256 newMaxSingleStakeAmount);
    // emergencyExit
    event EmergencyExit(address[] issuerAddresses, uint256 totalMoca);
}