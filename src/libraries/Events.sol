// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Events {
    
    // --------- Generic: Risk ---------
    event ContractFrozen();



// --------- VotingEscrowMoca.sol ---------
    event LockCreated(bytes32 indexed lockId, address indexed owner, address delegate, uint256 moca, uint256 esMoca, uint256 expiry);
    // delegate
    event DelegateRegistered(address indexed delegate);
    event DelegateUnregistered(address indexed delegate);
    event EmergencyExit(bytes32[] lockIds);

// --------- VotingController.sol ---------
    event Voted(uint256 indexed epoch, address indexed caller, bytes32[] poolIds, uint256[] votes, bool isDelegated);
    event VotesMigrated(uint256 indexed epoch, address indexed caller, bytes32[] srcPoolIds, bytes32[] dstPoolIds, uint256[] votes, bool isDelegated);
    event DelegateRegistered(address indexed delegate, uint256 feePct);
    event DelegateFeeDecreased(address indexed delegate, uint256 currentFeePct, uint256 feePct);
    event DelegateFeeIncreased(address indexed delegate, uint256 currentFeePct, uint256 feePct, uint256 nextFeePctEpoch);
    // claimRewards
    event RewardsClaimed(address indexed caller, uint256 epoch, bytes32[] poolIds, uint256 totalClaimableRewards);
    event RewardsClaimedFromDelegate(uint256 indexed epoch, address indexed caller, address indexed delegate, bytes32[] poolIds, uint256 totalClaimableRewards);

    // claimSubsidies
    event SubsidiesClaimed(address indexed verifier, uint256 epoch, bytes32[] poolIds, uint256 totalSubsidiesClaimed);
    // depositSubsidies
    event SubsidiesDeposited(address indexed depositor, uint256 epoch, uint256 depositSubsidies, uint256 totalSubsidies);
    // withdrawSubsidies
    event SubsidiesWithdrawn(address indexed depositor, uint256 epoch, uint256 withdrawSubsidies, uint256 totalSubsidies);
    // withdrawUnclaimedSubsidies
    event UnclaimedSubsidiesWithdrawn(address indexed depositor, uint256 epoch, uint256 unclaimedSubsidies);
    // setUnclaimedSubsidiesDelay
    event UnclaimedSubsidiesDelayUpdated(uint256 delayPeriod);
    // setMaxDelegateFeePct
    event MaxDelegateFeePctUpdated(uint256 maxDelegateFeePct);
    // finalizeEpoch
    event EpochSubsidyPerVoteSet(uint256 indexed epoch, uint256 subsidyPerVote);
    event EpochPartiallyFinalized(uint256 indexed epoch, bytes32[] poolIds);
    event EpochFullyFinalized(uint256 indexed epoch);

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
    // admin update fns
    event PoolIdUpdated(bytes32 indexed schemaId, bytes32 indexed poolId);
    event DelayPeriodUpdated(uint256 delayPeriod);
    event ProtocolFeePercentageUpdated(uint256 protocolFeePercentage);
    event VotingFeePercentageUpdated(uint256 voterFeePercentage);
    event VerifierStakingTierUpdated(uint256 stakingTier, uint256 stakingAmount);
    
    // withdrawProtocolFees, withdrawVotersFees
    event ProtocolFeesWithdrawn(uint256 epoch, uint256 protocolFees);
    event VotersFeesWithdrawn(uint256 epoch, uint256 votersFees);

    // emergencyExit
    event EmergencyExitIssuers(bytes32[] issuerIds);
    event EmergencyExitVerifiers(bytes32[] verifierIds);

}