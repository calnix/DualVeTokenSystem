// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Constants {
    
    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 internal constant PRECISION_BASE = 10_000;   

    uint256 internal constant USD8_PRECISION = 1E6; // 6dp precision
    uint256 internal constant MOCA_PRECISION = 1E18;

    // signature for PaymentsController::deductBalance()
    bytes32 internal constant DEDUCT_BALANCE_TYPEHASH = keccak256("DeductBalance(bytes32 issuerId,bytes32 verifierId,bytes32 schemaId,uint128 amount,uint256 expiry,uint256 nonce)");
    // signature for PaymentsController::deductBalanceZeroFee() | does not include amount
    bytes32 internal constant DEDUCT_BALANCE_ZERO_FEE_TYPEHASH = keccak256("DeductBalanceZeroFee(bytes32 issuerId,bytes32 verifierId,bytes32 schemaId,uint256 expiry,uint256 nonce)"); 
}