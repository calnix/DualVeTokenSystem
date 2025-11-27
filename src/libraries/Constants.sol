// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

/**
 * @title Constants
 * @author Calnix [@cal_nix]
 * @notice Library for constant values used across the Moca protocol.
 * @dev Provides precision constants for token decimals and other protocol-level values.
 */
    
library Constants {
    
    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 internal constant PRECISION_BASE = 10_000;   
    
    // Minimum lock amount to prevent precision loss in voting power calculations
    uint128 internal constant MIN_LOCK_AMOUNT = 1E13 wei;  // 0.00001 MOCA/esMOCA

    uint256 internal constant USD8_PRECISION = 1E6; // 6dp precision
    uint256 internal constant MOCA_PRECISION = 1E18;

    // signature for PaymentsController::deductBalance()
    bytes32 internal constant DEDUCT_BALANCE_TYPEHASH = keccak256("DeductBalance(address issuer,address verifier,bytes32 schemaId,address userAddress,uint128 amount,uint256 expiry,uint256 nonce)");
    // signature for PaymentsController::deductBalanceZeroFee() | does not include amount
    bytes32 internal constant DEDUCT_BALANCE_ZERO_FEE_TYPEHASH = keccak256("DeductBalanceZeroFee(address issuer,address verifier,bytes32 schemaId,address userAddress,uint256 expiry,uint256 nonce)"); 


    // ------------------------------------------- ROLES --------------------------------------
    // ______ HIGH-FREQUENCY ROLES [AUTOMATED OPERATIONAL FUNCTIONS] ______
    bytes32 internal constant MONITOR_ROLE = keccak256("MONITOR_ROLE");      // Pause only
    bytes32 internal constant CRON_JOB_ROLE = keccak256("CRON_JOB_ROLE");    // Automated tasks: createLockFor, finalizeEpoch, depositSubsidies
    
    // Role admins for operational roles [Dedicated role admins for operational efficiency]
    bytes32 internal constant MONITOR_ADMIN_ROLE = keccak256("MONITOR_ADMIN_ROLE"); 
    bytes32 internal constant CRON_JOB_ADMIN_ROLE = keccak256("CRON_JOB_ADMIN_ROLE");

    // ______ LOW-FREQUENCY STRATEGIC ROLES: NO DEDICATED ADMINS [MANAGED BY GLOBAL ADMIN] ______
    // Roles for making changes to contract parameters + configuration [multi-sig]
    bytes32 internal constant PAYMENTS_CONTROLLER_ADMIN_ROLE = keccak256("PAYMENTS_CONTROLLER_ADMIN_ROLE");
    bytes32 internal constant VOTING_CONTROLLER_ADMIN_ROLE = keccak256("VOTING_CONTROLLER_ADMIN_ROLE");
    bytes32 internal constant VOTING_ESCROW_MOCA_ADMIN_ROLE = keccak256("VOTING_ESCROW_MOCA_ADMIN_ROLE");
    bytes32 internal constant ESCROWED_MOCA_ADMIN_ROLE = keccak256("ESCROWED_MOCA_ADMIN_ROLE");
    bytes32 internal constant ISSUER_STAKING_CONTROLLER_ADMIN_ROLE = keccak256("ISSUER_STAKING_CONTROLLER_ADMIN_ROLE");

    // For multiple contracts: depositing/withdrawing/converting assets [PaymentsController, VotingController, esMoca]
    bytes32 internal constant ASSET_MANAGER_ROLE = keccak256("ASSET_MANAGER_ROLE");                   // withdraw fns on PaymentsController, VotingController
    bytes32 internal constant EMERGENCY_EXIT_HANDLER_ROLE = keccak256("EMERGENCY_EXIT_HANDLER_ROLE"); 
    
}