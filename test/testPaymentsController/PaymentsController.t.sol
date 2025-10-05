// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "../utils/TestingHarness.sol";

abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}

contract StateT0_Deploy_Test is StateT0_Deploy {
    
    function test_Deploy() public {
        // Check PaymentsController addressBook is set correctly
        assertEq(address(paymentsController.addressBook()), address(addressBook), "addressBook not set correctly");

        // Check protocol fee percentage
        assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), protocolFeePercentage, "PROTOCOL_FEE_PERCENTAGE not set correctly");

        // Check voting fee percentage
        assertEq(paymentsController.VOTING_FEE_PERCENTAGE(), voterFeePercentage, "VOTING_FEE_PERCENTAGE not set correctly");

        // Check fee increase delay period
        assertEq(paymentsController.FEE_INCREASE_DELAY_PERIOD(), feeIncreaseDelayPeriod, "FEE_INCREASE_DELAY_PERIOD not set correctly");
    }

    function testCan_PaymentsControllerAdmin_SetSubsidyTiers() public {
        vm.startPrank(paymentsControllerAdmin);
        
        // First tier
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierStakingTierUpdated(10 ether, 1000);
        paymentsController.updateVerifierSubsidyPercentages(10 ether, 1000);
        
        // Second tier
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierStakingTierUpdated(20 ether, 2000);
        paymentsController.updateVerifierSubsidyPercentages(20 ether, 2000);
        
        // Third tier
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierStakingTierUpdated(30 ether, 3000);
        paymentsController.updateVerifierSubsidyPercentages(30 ether, 3000);
        
        vm.stopPrank();

        // Check subsidy tiers
        assertEq(paymentsController.getVerifierSubsidyPercentage(10 ether), 1000, "10 ether subsidy percentage not set correctly");
        assertEq(paymentsController.getVerifierSubsidyPercentage(20 ether), 2000, "20 ether subsidy percentage not set correctly");
        assertEq(paymentsController.getVerifierSubsidyPercentage(30 ether), 3000, "30 ether subsidy percentage not set correctly");
    }

    function testCannot_CreateIssuer_WhenAssetAddressIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(issuer1);
        paymentsController.createIssuer(address(0));
    }

    function testCan_CreateIssuer() public {
        bytes32 expectedIssuerId = PaymentsController_generateId(block.number, issuer1, issuer1Asset);

        // Expect the IssuerCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.IssuerCreated(expectedIssuerId, issuer1, issuer1Asset);

        vm.prank(issuer1);
        bytes32 issuerId = paymentsController.createIssuer(issuer1Asset);
        assertEq(issuerId, expectedIssuerId, "issuerId not set correctly");

        // Check storage state of issuer1
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuerId);

        assertEq(issuer.issuerId, expectedIssuerId, "storedIssuerId mismatch");
        assertEq(issuer.adminAddress, issuer1, "adminAddress mismatch");
        assertEq(issuer.assetAddress, issuer1Asset, "assetAddress mismatch");
        assertEq(issuer.totalNetFeesAccrued, 0, "totalNetFeesAccrued should be 0");
        assertEq(issuer.totalClaimed, 0, "totalClaimed should be 0");
    }

    function testCannot_CreateVerifier_WhenAssetAddressIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(verifier1);
        paymentsController.createVerifier(verifier1Signer, address(0));
    }

    function testCannot_CreateVerifier_WhenSignerAddressIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(verifier1);
        paymentsController.createVerifier(address(0), verifier1Asset);
    }

    function testCan_CreateVerifier() public {
        bytes32 expectedVerifierId = PaymentsController_generateId(block.number, verifier1, verifier1Asset);

        // Expect the VerifierCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierCreated(expectedVerifierId, verifier1, verifier1Signer, verifier1Asset);

        vm.prank(verifier1);
        bytes32 verifierId = paymentsController.createVerifier(verifier1Signer, verifier1Asset);
        assertEq(verifierId, expectedVerifierId, "verifierId not set correctly");

        // Check storage state of verifier1
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifierId);

        assertEq(verifier.verifierId, expectedVerifierId, "storedVerifierId mismatch");
        assertEq(verifier.adminAddress, verifier1, "adminAddress mismatch");
        assertEq(verifier.signerAddress, verifier1Signer, "signerAddress mismatch");
        assertEq(verifier.assetAddress, verifier1Asset, "assetAddress mismatch");
        assertEq(verifier.currentBalance, 0, "currentBalance should be 0");
        assertEq(verifier.totalExpenditure, 0, "totalExpenditure should be 0");
    }

}

abstract contract StateT1_CreateIssuerVerifierAndSubsidyTiers is StateT0_Deploy {

    bytes32 public issuerId = PaymentsController_generateId(block.number, issuer1, issuer1Asset);
    bytes32 public verifierId = PaymentsController_generateId(block.number, verifier1, verifier1Asset);
    bytes32 public expectedSchemaId1 = PaymentsController_generateSchemaId(block.number, issuerId);

    function setUp() public virtual override {
        super.setUp();

        vm.prank(issuer1);
        paymentsController.createIssuer(issuer1Asset);

        vm.prank(verifier1);
        paymentsController.createVerifier(verifier1Signer, verifier1Asset);

        // Create subsidy tiers for verifiers
        vm.startPrank(paymentsControllerAdmin);
        // First tier
        paymentsController.updateVerifierSubsidyPercentages(10 ether, 1000);
        // Second tier
        paymentsController.updateVerifierSubsidyPercentages(20 ether, 2000);       
        // Third tier
        paymentsController.updateVerifierSubsidyPercentages(30 ether, 3000);
        
        vm.stopPrank();
    }
}

contract StateT1_CreateIssuerVerifierAndSubsidyTiers_Test is StateT1_CreateIssuerVerifierAndSubsidyTiers {

    function testCannot_CreateSchema_WhenCallerIsNotIssuerAdmin() public {
        uint128 fee = 1000;

        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the issuer admin
        paymentsController.createSchema(issuerId, fee);
    }


    function testCannot_CreateSchema_WhenFeeTooLarge() public {
        // Use max uint128 as an obviously too large fee
        uint128 tooLargeFee = type(uint128).max; 

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(issuer1);
        paymentsController.createSchema(issuerId, tooLargeFee);
    }


    function testCan_CreateSchema() public {
        uint128 fee = 1000;

        // Expect the SchemaCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaCreated(expectedSchemaId1, issuerId, fee);

        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(issuerId, fee);

        // Assert
        assertEq(schemaId, expectedSchemaId1, "schemaId not set correctly");
        
        // Verify schema storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(expectedSchemaId1);

        assertEq(schema.schemaId, expectedSchemaId1, "Schema ID not stored correctly");
        assertEq(schema.issuerId, issuerId, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, fee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }

}

abstract contract StateT2_UpdateSchemaFee is StateT1_CreateIssuerAndVerifier {

    uint128 public issuer1SchemaFee = 100 * 1e6;  // 100 USD8 (6 decimals) instead of 1 ether

    function setUp() public virtual override {
        super.setUp();

        vm.prank(issuer1);
        paymentsController.createSchema(issuerId, issuer1SchemaFee);
    }
}

contract StateT2_UpdateSchemaFee_Test is StateT2_UpdateSchemaFee {

    // ---------- update schema fee ----------

    function testCannot_UpdateSchemaFee_WhenCallerIsNotIssuerAdmin() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the issuer admin
        paymentsController.updateSchemaFee(issuerId, expectedSchemaId1, issuer1SchemaFee);
    }
    
    function testCannot_UpdateSchmeFee_InvalidId() public {
        vm.expectRevert(Errors.InvalidId.selector);
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(issuerId, bytes32(0), issuer1SchemaFee);
    }

    function testCannot_UpdateSchemaFee_WhenNewFeeTooLarge() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        
        uint128 newFee = type(uint128).max;
     
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(issuerId, expectedSchemaId1, newFee);
    }

    function testCan_UpdateSchemaFee_ReduceFee() public {
        uint128 oldFee = issuer1SchemaFee;
        uint128 newFee = oldFee / 2;

        // Expect the SchemaFeeReduced event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeReduced(expectedSchemaId1, newFee, oldFee);

        vm.prank(issuer1);
        uint256 returnedFee = paymentsController.updateSchemaFee(issuerId, expectedSchemaId1, newFee);
        assertEq(returnedFee, newFee, "newFee not set correctly");
        
        // Check storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(expectedSchemaId1);
        assertEq(schema.currentFee, newFee, "Schema currentFee not updated correctly");  // Should be 500 after reduction
        assertEq(schema.nextFee, 0, "Schema nextFee should be 0 after fee reduction");
        assertEq(schema.nextFeeTimestamp, 0, "Schema nextFeeTimestamp should be 0 after fee reduction");
    }

    function testCan_UpdateSchemaFee_IncreaseFee() public {
        uint128 oldFee = issuer1SchemaFee;
        uint128 newFee = oldFee * 2;
        uint256 nextFeeTimestamp = block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD();


        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaNextFeeSet(expectedSchemaId1, newFee, nextFeeTimestamp, oldFee);

        vm.prank(issuer1);
        uint256 returnedFee = paymentsController.updateSchemaFee(issuerId, expectedSchemaId1, newFee);
        assertEq(returnedFee, newFee, "newFee not set correctly");

        // Check storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(expectedSchemaId1);
        assertEq(schema.currentFee, oldFee, "Schema currentFee should remain unchanged until delay elapses");
        assertEq(schema.nextFee, newFee, "Schema nextFee not set correctly");
        assertEq(schema.nextFeeTimestamp, nextFeeTimestamp, "Schema nextFeeTimestamp not set correctly");
    }

    // ---------- verifier deposit ----------

    function testCannot_VerifierDepositUSD8_CallerIsNotVerifierAssetAddress() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the verifier asset address
        paymentsController.deposit(verifierId, 1000 * 1e6);
    }

    function testCan_VerifierDepositUSD8_CallerIsVerifierAssetAddress() public {
        uint128 amount = 10 * 1e6;

        // Check storage and token balances before deposit
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifierId);
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        vm.startPrank(verifier1Asset);
            mockUSD8.approve(address(paymentsController), amount);

            // Expect the VerifierDeposited event to be emitted with correct parameters
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierDeposited(verifierId, verifier1Asset, amount);

            paymentsController.deposit(verifierId, amount);
        vm.stopPrank();

        // Check storage state of verifier1 after deposit
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifierId);
        assertEq(verifierAfter.currentBalance, verifierBefore.currentBalance + amount, "currentBalance not updated correctly");

        // Check token balances after deposit
        uint256 contractBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceAfter = mockUSD8.balanceOf(verifier1Asset);

        assertEq(contractBalanceAfter, contractBalanceBefore + amount, "PaymentsController contract USD8 balance not updated correctly");
        assertEq(verifierBalanceAfter, verifierBalanceBefore - amount, "verifier1Asset USD8 balance not updated correctly");
    }


    // ---------- deduct balance ----------

    function testCannot_DeductBalance_WhenExpiryIsInThePast() public {
        vm.expectRevert(Errors.SignatureExpired.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, issuer1SchemaFee, block.timestamp, "");
    }

    function testCannot_DeductBalance_WhenAmountIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, 0, block.timestamp + 1000, "");
    }
    
    function testCannot_DeductBalance_WhenSchemaDoesNotBelongToIssuer() public {
        vm.expectRevert(Errors.InvalidIssuer.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance("", verifierId, expectedSchemaId1, issuer1SchemaFee, block.timestamp + 1000, "");
    }
   
    function testCannot_DeductBalance_InvalidSignature() public {
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, issuer1SchemaFee, block.timestamp + 1000, "");
    }

    function testCannot_DeductBalance_WhenAmountDoesNotMatchSchemaFee() public {
        // Generate a valid signature for deductBalance
        uint128 amount = issuer1SchemaFee + 1000 * 1e6;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuerId,
            verifierId,
            expectedSchemaId1,
            amount,
            expiry,
            nonce
        );
        vm.expectRevert(Errors.InvalidSchemaFee.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, amount, expiry, signature);
    }

    function testCannot_DeductBalance_WhenVerifierHasNoDeposit() public {
        // Generate a valid signature for deductBalance
        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuerId,
            verifierId,
            expectedSchemaId1,
            amount,
            expiry,
            nonce
        );

        // Call deductBalance as the verifier's signer address, but with no deposit made
        vm.expectRevert(Errors.InsufficientBalance.selector);
        
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(
            issuerId,
            verifierId,
            expectedSchemaId1,
            amount,
            expiry,
            signature
        );
    }
    
}


abstract contract StateT3_VerifierDepositsUSD8 is StateT2_UpdateSchemaFee {

    function setUp() public virtual override {
        super.setUp();

        // verifier1: deposit 1000 USD8 for expenses (instead of 10 ether)
        vm.startPrank(verifier1Asset);
            mockUSD8.approve(address(paymentsController), 1000 * 1e6);
            paymentsController.deposit(verifierId, 1000 * 1e6);
        vm.stopPrank();
    }
}

contract StateT3_VerifierDepositsUSD8_Test is StateT3_VerifierDepositsUSD8 {
    
    // ---------- withdraw USD8 ----------
    function testCannot_VerifierWithdrawUSD8_CallerIsNotVerifierAssetAddress() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the verifier asset address
        paymentsController.withdraw(verifierId, 10 * 1e6);  // 10 USD8 instead of 10 ether
    }

    function testCannot_VerifierWithdrawUSD8_WhenAmountIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifierId, 0);
    }

    function testCannot_VerifierWithdrawUSD8_WhenAmountIsGreaterThanBalance() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifierId, 10000 * 1e6);  // 10000 USD8 instead of 100 ether
    }   

    function testCan_VerifierWithdrawUSD8_CallerIsVerifierAssetAddress() public {
        uint128 amount = 1000 * 1e6;  // 1000 USD8 instead of 10 ether

        // Check storage and token balances before withdrawal
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifierId);
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 assetBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        // Expect the VerifierWithdrawn event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifierId, verifier1Asset, amount);

        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifierId, amount);

        // Check storage state of verifier1 after withdrawal
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifierId);
        assertEq(verifierAfter.currentBalance, verifierBefore.currentBalance - amount, "currentBalance not updated correctly");

        // Check token balances after withdrawal
        uint256 contractBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        uint256 assetBalanceAfter = mockUSD8.balanceOf(verifier1Asset);

        assertEq(contractBalanceAfter, contractBalanceBefore - amount, "PaymentsController contract USD8 balance not updated correctly");
        assertEq(assetBalanceAfter, assetBalanceBefore + amount, "verifier1Asset USD8 balance not updated correctly");
    }

    // ---------- deduct balance ----------

    function testCannot_VerifierDeductBalance_WhenAmountIsGreaterThanBalance() public {
        // Generate a valid signature for deductBalance
        uint128 amount = issuer1SchemaFee + 1000 * 1e6;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuerId,
            verifierId,
            expectedSchemaId1,
            amount,
            expiry,
            nonce
        );

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, amount, block.timestamp + 1000, signature);  
    }
    
    function testCannot_VerifierDeductBalance_WhenSignatureExpired() public {
        vm.expectRevert(Errors.SignatureExpired.selector);
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, issuer1SchemaFee, block.timestamp - 1000, "");
    }
    
    function testCannot_VerifierDeductBalance_WhenAmountDoesNotMatchSchemaFee() public {
        vm.expectRevert(Errors.InvalidSchemaFee.selector);
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, (issuer1SchemaFee*2), block.timestamp + 1000, "");
    }
    
    function testCan_VerifierDeductBalance_WhenAmountMatchesSchemaFee() public {
        // Generate a valid signature for deductBalance using the helper function
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuerId,
            verifierId,
            expectedSchemaId1,
            issuer1SchemaFee,
            block.timestamp + 1000,
            0 // nonce, set to 0 for test; update if needed for replay protection
        );

        vm.prank(verifier1Asset);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, issuer1SchemaFee, block.timestamp + 1000, signature);
    }
    
    function testCan_VerifierDeductBalance_WhenSignatureIsValid() public {
        // Generate a valid signature for deductBalance using the helper function
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuerId,
            verifierId,
            expectedSchemaId1,
            issuer1SchemaFee,
            block.timestamp + 1000,
            0 // nonce, set to 0 for test; update if needed for replay protection
        );
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(issuerId, verifierId, expectedSchemaId1, issuer1SchemaFee, block.timestamp + 1000, signature);
    }
    

}

abstract contract StateT4_VerifierInitiatesVerification is StateT3_VerifierDepositsUSD8 {

    function setUp() public virtual override {
        super.setUp();
    }
}
