// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title Events
 * @author Calnix [@cal_nix]
 * @notice Library for events used across the Moca protocol.
 * @dev Provides events for protocol functions.
 */
    
library Events {
    
// --------- Generic: Risk ---------
    event ContractFrozen();

// --------- EscrowedMoca.sol ---------
    // escrow()
    event EscrowedMoca(address indexed caller, uint256 amount);
    // redeem()
    event RedemptionScheduled(address indexed caller, uint256 mocaReceivable, uint256 penaltyAmount, uint256 redemptionTimestamp);
    event PenaltyAccrued(uint256 penaltyToVoters, uint256 penaltyToTreasury);
    event Redeemed(address indexed caller, uint256 mocaReceivable, uint256 redemptionTimestamp);
    // claimRedemption()
    event RedemptionClaimed(address indexed caller, uint256 mocaReceivable, uint256 redemptionTimestamp, uint256 penaltyAmount);
    // stakeOnBehalf()
    event StakedOnBehalf(address[] callers, uint256[] amounts);
    // setPenaltyToVoters()
    event PenaltyToVotersUpdated(uint256 oldPenaltyToVoters, uint256 newPenaltyToVoters);
    // setRedemptionOption()
    event RedemptionOptionUpdated(uint256 redemptionOption, uint256 lockDuration, uint256 receivablePct);
    // setRedemptionOptionStatus()
    event RedemptionOptionEnabled(uint256 redemptionOption, uint256 receivablePct, uint256 lockDuration);
    event RedemptionOptionDisabled(uint256 redemptionOption);
    // setWhitelistStatus()
    event AddressWhitelisted(address indexed addr, bool isWhitelisted);
    // releaseEscrowedMoca()
    event EscrowedMocaReleased(address indexed caller, uint256 amount);
    // claimPenalty()
    event PenaltyClaimed(uint256 totalClaimable);

// --------- VotingEscrowMoca.sol ---------
    event LockCreated(bytes32 indexed lockId, address indexed owner, address delegate, uint256 moca, uint256 esMoca, uint256 expiry);
    // delegate
    event DelegateRegistered(address indexed delegate);
    event DelegateUnregistered(address indexed delegate);
    //unlock
    event LockUnlocked(bytes32 indexed lockId, address indexed owner, uint256 moca, uint256 esMoca);
    // undelegateLock
    event LockUndelegated(bytes32 indexed lockId, address indexed owner, address delegate);
    // switchDelegate
    event LockDelegateSwitched(bytes32 indexed lockId, address indexed owner, address delegate, address newDelegate);
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
    event IssuerCreated(bytes32 indexed issuerId, address adminAddress, address assetAddress);
    event VerifierCreated(bytes32 indexed verifierId, address adminAddress, address signerAddress, address assetAddress);
    event SchemaCreated(bytes32 indexed schemaId, bytes32 issuerId, uint256 fee);
    // updateSchemaFee
    event SchemaFeeReduced(bytes32 indexed schemaId, uint256 newFee, uint256 currentFee);
    event SchemaNextFeeSet(bytes32 indexed schemaId, uint256 newFee, uint256 nextFeeTimestamp, uint256 currentFee);
    event SchemaFeeIncreased(bytes32 indexed schemaId, uint256 oldFee, uint256 newFee);
    // claimFees
    event IssuerFeesClaimed(bytes32 indexed issuerId, uint256 claimableFees);

    // verifier: deposit(), withdraw(), stakeMoca(), unstakeMoca()
    event VerifierDeposited(bytes32 indexed verifierId, address indexed assetAddress, uint128 amount);
    event VerifierWithdrew(bytes32 indexed verifierId, address indexed assetAddress, uint128 amount);
    event VerifierMocaStaked(bytes32 indexed verifierId, address assetAddress, uint256 amount);
    event VerifierMocaUnstaked(bytes32 indexed verifierId, address assetAddress, uint256 amount);
    event VerifierSignerAddressUpdated(bytes32 indexed verifierId, address signerAddress);

    // updateAssetAddress + updateAdminAddress
    event AssetAddressUpdated(bytes32 indexed verifierOrIssuerId, address newAssetAddress);
    event AdminAddressUpdated(bytes32 indexed verifierOrIssuerId, address newAdminAddress);

    // deductBalance()
    event SubsidyBooked(bytes32 indexed verifierId, bytes32 indexed poolId, bytes32 indexed schemaId, uint256 subsidy);
    event BalanceDeducted(bytes32 indexed verifierId, bytes32 indexed schemaId, bytes32 indexed issuerId, uint256 amount);
    event SchemaVerified(bytes32 indexed schemaId);
    event SchemaVerifiedZeroFee(bytes32 indexed schemaId);

    // admin update fns
    event PoolIdUpdated(bytes32 indexed schemaId, bytes32 indexed poolId);
    event FeeIncreaseDelayPeriodUpdated(uint256 newDelayPeriod);
    event ProtocolFeePercentageUpdated(uint256 protocolFeePercentage);
    event VotingFeePercentageUpdated(uint256 voterFeePercentage);
    event VerifierStakingTierUpdated(uint256 stakingAmount, uint256 subsidyPercentage);
    
    // withdrawProtocolFees, withdrawVotersFees
    event ProtocolFeesWithdrawn(uint256 epoch, uint256 protocolFees);
    event VotersFeesWithdrawn(uint256 epoch, uint256 votersFees);

    // emergencyExit
    event EmergencyExitIssuers(bytes32[] issuerIds);
    event EmergencyExitVerifiers(bytes32[] verifierIds);

// --------- AddressBook.sol ---------
    event AddressSet(bytes32 indexed identifier, address registeredAddress);
    event GlobalAdminUpdated(address indexed oldGlobalAdmin, address indexed newGlobalAdmin);

// --------- AccessController.sol ---------
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

}