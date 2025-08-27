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
    // claimSubsidies
    event SubsidiesClaimed(address indexed verifier, uint256 epoch, bytes32[] poolIds, uint256 totalSubsidiesClaimed);
    
    // --------- PaymentsController.sol ---------
    event VerifierMocaStaked(bytes32 indexed verifierId, uint256 amount);
    event VerifierMocaUnstaked(bytes32 indexed verifierId, uint256 amount);
    event SubsidyBooked(bytes32 indexed verifierId, bytes32 indexed poolId, bytes32 indexed schemaId, uint256 subsidy);
    event PoolIdUpdated(bytes32 indexed schemaId, bytes32 indexed poolId);
    event DelayPeriodUpdated(uint256 delayPeriod);
    event ProtocolFeePercentageUpdated(uint256 protocolFeePercentage);
    event VoterFeePercentageUpdated(uint256 voterFeePercentage);
    event VerifierStakingTierUpdated(uint256 stakingTier, uint256 stakingAmount);

    event EmergencyExitIssuers(bytes32[] issuerIds);
    event EmergencyExitVerifiers(bytes32[] verifierIds);

}