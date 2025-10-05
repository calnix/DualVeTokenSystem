// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "../utils/TestingHarness.sol";

abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}

contract StateT0_DeployAndCreateSubsidyTiers_Test is StateT0_Deploy {
    
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

    // state transition: subsidy tiers
    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenCallerIsNotPaymentsControllerAdmin() public {
        vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin.selector);
        vm.prank(address(0xdeadbeef)); // not the payments controller admin
        paymentsController.updateVerifierSubsidyPercentages(10 ether, 1000);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenMocaStakedIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.updateVerifierSubsidyPercentages(0, 1000);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenSubsidyPercentageIsGreaterThan100Pct() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.updateVerifierSubsidyPercentages(10 ether, 10000);
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
}

abstract contract StateT1_SubsidyTiersCreated is StateT0_Deploy {

    function setUp() public virtual override {
        super.setUp();

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

// test: create issuers and verifiers
contract StateT1_SubsidyTiersCreated_Test is StateT1_SubsidyTiersCreated {

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

abstract contract StateT1_CreateIssuerVerifiers is StateT1_SubsidyTiersCreated {

    // issuers
    bytes32 public issuer1_Id = PaymentsController_generateId(block.number, issuer1, issuer1Asset);
    bytes32 public issuer2_Id = PaymentsController_generateId(block.number, issuer2, issuer2Asset);
    bytes32 public issuer3_Id = PaymentsController_generateId(block.number, issuer3, issuer3Asset);
    // verifiers
    bytes32 public verifier1_Id = PaymentsController_generateId(block.number, verifier1, verifier1Asset);
    bytes32 public verifier2_Id = PaymentsController_generateId(block.number, verifier2, verifier2Asset);
    bytes32 public verifier3_Id = PaymentsController_generateId(block.number, verifier3, verifier3Asset);

    function setUp() public virtual override {
        super.setUp();

        // issuers
        vm.prank(issuer1);
        paymentsController.createIssuer(issuer1Asset);

        vm.prank(issuer2);
        paymentsController.createIssuer(issuer2Asset);

        vm.prank(issuer3);
        paymentsController.createIssuer(issuer3Asset);  

        // verifiers
        vm.prank(verifier1);
        paymentsController.createVerifier(verifier1Signer, verifier1Asset);

        vm.prank(verifier2);
        paymentsController.createVerifier(verifier2Signer, verifier2Asset);

        vm.prank(verifier3);
        paymentsController.createVerifier(verifier3Signer, verifier3Asset);
    }
}

// test schema creation
contract StateT1_CreateIssuerVerifiers_Test is StateT1_CreateIssuerVerifiers {

    function testCannot_CreateSchema_WhenCallerIsNotIssuerAdmin() public {
        uint128 fee = 1000;

        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the issuer admin
        paymentsController.createSchema(issuer1_Id, fee);
    }


    function testCannot_CreateSchema_WhenFeeTooLarge() public {
        // Use max uint128 as an obviously too large fee
        uint128 tooLargeFee = type(uint128).max; 

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(issuer1);
        paymentsController.createSchema(issuer1_Id, tooLargeFee);
    }


    function testCan_CreateSchema() public {
        uint128 fee = 1000;
        
        // generate expected schemaId
        bytes32 expectedSchemaId1 = PaymentsController_generateSchemaId(block.number, issuer1_Id);   

        // Expect the SchemaCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaCreated(expectedSchemaId1, issuer1_Id, fee);

        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(issuer1_Id, fee);

        // Assert
        assertEq(schemaId, expectedSchemaId1, "schemaId not set correctly");
        
        // Verify schema storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(expectedSchemaId1);

        assertEq(schema.schemaId, expectedSchemaId1, "Schema ID not stored correctly");
        assertEq(schema.issuerId, issuer1_Id, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, fee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }

}

abstract contract StateT2_CreateSchemas is StateT1_CreateIssuerVerifiers {

    // schemas
    bytes32 public schemaId1 = PaymentsController_generateSchemaId(block.number, issuer1_Id);
    bytes32 public schemaId2 = PaymentsController_generateSchemaId(block.number, issuer2_Id);
    bytes32 public schemaId3 = PaymentsController_generateSchemaId(block.number, issuer3_Id);


    uint128 public issuer1SchemaFee = 10 * 1e6;  // 10 USD8 (6 decimals) instead of 1 ether
    uint128 public issuer2SchemaFee = 20 * 1e6;  // 20 USD8 (6 decimals) instead of 2 ether
    uint128 public issuer3SchemaFeeIsZero = 0;  

    function setUp() public virtual override {
        super.setUp();

        vm.prank(issuer1);
        schemaId1 = paymentsController.createSchema(issuer1_Id, issuer1SchemaFee);

        vm.prank(issuer2);
        schemaId2 = paymentsController.createSchema(issuer2_Id, issuer2SchemaFee);

        vm.prank(issuer3);
        schemaId3 = paymentsController.createSchema(issuer3_Id, issuer3SchemaFeeIsZero);
    }
}

contract StateT2_CreateSchemas_Test is StateT2_CreateSchemas {

    function testSchema1_StorageState() public {
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
     
        assertEq(schema.schemaId, schemaId1, "Schema ID not stored correctly");
        assertEq(schema.issuerId, issuer1_Id, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, issuer1SchemaFee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }

    function testSchema2_StorageState() public {
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId2);
        assertEq(schema.schemaId, schemaId2, "Schema ID not stored correctly");
        assertEq(schema.issuerId, issuer2_Id, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, issuer2SchemaFee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }
    
    function testSchema3_StorageState() public {
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId3);
        assertEq(schema.schemaId, schemaId3, "Schema ID not stored correctly");
        assertEq(schema.issuerId, issuer3_Id, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, issuer3SchemaFeeIsZero, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }


    // state transition: verifier deposits USD8 for payment
    function testCan_VerifierDepositUSD8_CallerIsVerifierAssetAddress() public {
        uint128 amount = 100 * 1e6;

        // Record balances before deposit
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance before deposit
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;


        // Perform deposit
        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), amount); 

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierDeposited(verifier1_Id, verifier1Asset, amount);

        paymentsController.deposit(verifier1_Id, amount);
        vm.stopPrank();

        // Record balances after deposit
        uint256 contractBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceAfter = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance after deposit
        uint256 verifierCurrentBalanceAfter = paymentsController.getVerifier(verifier1_Id).currentBalance;

        // Check storage: deposited amount should be reflected
        assertEq(verifierCurrentBalanceBefore, 0, "Verifier balance should be zero before deposit");
        assertEq(verifierCurrentBalanceAfter, amount, "Verifier balance not updated correctly after deposit");

        // Check token balances
        assertEq(contractBalanceAfter, contractBalanceBefore + amount, "Contract balance not increased correctly");
        assertEq(verifierBalanceAfter, verifierBalanceBefore - amount, "Verifier balance not decreased correctly");
    }
    
}

abstract contract StateT3_Verifier1DepositUSD8 is StateT2_CreateSchemas {

    function setUp() public virtual override {
        super.setUp();

        // Perform deposit: verifier1
        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), 100 * 1e6);
        paymentsController.deposit(verifier1_Id, 100 * 1e6);
        vm.stopPrank();
    }
}


contract StateT3_Verifier1DepositUSD8_Test is StateT3_Verifier1DepositUSD8 {
    
    function testCannot_VerifierDepositUSD8_CallerIsNotVerifierAssetAddress() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the verifier asset address
        paymentsController.deposit(verifier1_Id, 1000 * 1e6);
    }

    function testCan_VerifierWithdrawUSD8_CallerIsVerifierAssetAddress() public {
        uint128 withdrawAmount = 100 * 1e6;

        // Record balances before withdrawal
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance before withdrawal
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifier1_Id, verifier1Asset, withdrawAmount);

        // Perform withdrawal
        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifier1_Id, withdrawAmount);

        // Record balances after withdrawal
        uint256 contractBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceAfter = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance after withdrawal
        uint256 verifierCurrentBalanceAfter = paymentsController.getVerifier(verifier1_Id).currentBalance;

        // Check storage: withdrawn amount should be reflected
        assertEq(verifierCurrentBalanceAfter, verifierCurrentBalanceBefore - withdrawAmount, "Verifier balance not updated correctly after withdrawal");

        // Check token balances
        assertEq(contractBalanceAfter, contractBalanceBefore - withdrawAmount, "Contract balance not decreased correctly");
        assertEq(verifierBalanceAfter, verifierBalanceBefore + withdrawAmount, "Verifier balance not increased correctly");
    }

    //state transition: deduct balance
    function testCannot_DeductBalance_WhenExpiryIsInThePast() public {
        vm.expectRevert(Errors.SignatureExpired.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, issuer1SchemaFee, block.timestamp, "");
    }

    function testCannot_DeductBalance_WhenAmountIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, 0, block.timestamp + 1000, "");
    }
    
    function testCannot_DeductBalance_WhenSchemaDoesNotBelongToIssuer() public {
        vm.expectRevert(Errors.InvalidIssuer.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance("", verifier1_Id, schemaId1, issuer1SchemaFee, block.timestamp + 1000, "");
    }
   
    function testCannot_DeductBalance_InvalidSignature() public {
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, issuer1SchemaFee, block.timestamp + 1000, "");
    }

    function testCannot_DeductBalance_WhenAmountDoesNotMatchSchemaFee() public {
        // Generate a valid signature for deductBalance
        uint128 amount = issuer1SchemaFee + 1000 * 1e6;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuer1_Id,
            verifier1_Id,
            schemaId1,
            amount,
            expiry,
            nonce
        );
        vm.expectRevert(Errors.InvalidSchemaFee.selector);
        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
    }

    // Use verifier2 which has no deposit
    function testCannot_DeductBalance_WhenVerifierHasNoDeposit() public {
        // Generate a valid signature for deductBalance using verifier2 which has no deposit
        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier2SignerPrivateKey,
            issuer1_Id,
            verifier2_Id,  // Use verifier2
            schemaId1,
            amount,
            expiry,
            nonce
        );

        // Call deductBalance as the verifier2's signer address, which has no deposit
        vm.expectRevert(Errors.InsufficientBalance.selector);
        
        vm.prank(verifier2Signer);
        paymentsController.deductBalance(
            issuer1_Id,
            verifier2_Id,  // Use verifier2
            schemaId1,
            amount,
            expiry,
            signature
        );
    }

    function testCan_VerifierDeductBalance_WhenAmountMatchesSchemaFee() public {
        // Record balances before deduction
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;

        // Record issuer's totalNetFeesAccrued before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
        assertEq(issuerTotalNetFeesAccruedBefore, 0, "Issuer totalNetFeesAccrued should be zero before deduction");
        // Record issuer's totalVerified before deduction
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1_Id).totalVerified;
        assertEq(issuerTotalVerifiedBefore, 0, "Issuer totalVerified should be zero before deduction");

        // Record schema's totalGrossFeesAccrued before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        assertEq(schemaTotalGrossFeesAccruedBefore, 0, "Schema totalGrossFeesAccrued should be zero before deduction");
        // Record schema's totalVerified before deduction
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;
        assertEq(schemaTotalVerifiedBefore, 0, "Schema totalVerified should be zero before deduction");

        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuer1_Id,
            verifier1_Id,
            schemaId1,
            amount,
            expiry,
            nonce
        );

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);

        vm.prank(verifier1Signer);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);

        //cal. net fee = amount - protocol fee - voting fee
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 netFee = amount - protocolFee - votingFee;

        //Check contract: storage state
        DataTypes.FeesAccrued memory epochFees = paymentsController.getEpochFeesAccrued(EpochMath.getCurrentEpochNumber());
        assertEq(epochFees.feesAccruedToProtocol, protocolFee, "epochFees.feesAccruedToProtocol should be correct");
        assertEq(epochFees.feesAccruedToVoters, votingFee, "epochFees.feesAccruedToVoters should be correct");
        assertEq(epochFees.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFees.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");
        assertEq(paymentsController.TOTAL_CLAIMED_VERIFICATION_FEES(), 0, "TOTAL_CLAIMED_VERIFICATION_FEES should be zero");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer.totalNetFeesAccrued, netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, 1, "Issuer totalVerified not updated correctly");

        // Check storage state: verifier
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, 1, "Schema totalVerified not updated correctly");

        // Check token balances
        assertEq(mockUSD8.balanceOf(address(paymentsController)), contractBalanceBefore, "Contract balance should not change");
        assertEq(mockUSD8.balanceOf(verifier1Asset), verifierBalanceBefore, "Verifier balance should not change");
    }    
}
    
abstract contract StateT4_DeductBalanceExecuted is StateT3_Verifier1DepositUSD8 {

    function setUp() public virtual override {
        super.setUp();

        // Perform deduction: verifier1
        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuer1_Id,
            verifier1_Id,
            schemaId1,
            amount,
            expiry,
            nonce
        );

        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), amount);
        vm.stopPrank();

        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
    }
}

contract StateT4_DeductBalanceExecuted_Test is StateT4_DeductBalanceExecuted {
   
    // state transition: verifier changes signer address
    function testCan_Verifier1UpdateSignerAddress_WhenNewSignerAddressIsDifferentFromCurrentOne() public {
        (address verifier1NewSigner, uint256 verifier1NewSignerPrivateKey) = makeAddrAndKey("verifier1NewSigner");

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierSignerAddressUpdated(verifier1_Id, verifier1NewSigner);
       
        vm.prank(verifier1);
        paymentsController.updateSignerAddress(verifier1_Id, verifier1NewSigner);
    }

}

abstract contract StateT5_VerifierChangesSignerAddress is StateT4_DeductBalanceExecuted {

    address public verifier1NewSigner;
    uint256 public verifier1NewSignerPrivateKey;
    
    function setUp() public virtual override {
        super.setUp();

        (verifier1NewSigner, verifier1NewSignerPrivateKey) = makeAddrAndKey("verifier1NewSigner");

        vm.prank(verifier1);
        paymentsController.updateSignerAddress(verifier1_Id, verifier1NewSigner);
    }
}

// deductBalance should work w/ new signer address
contract StateT5_VerifierChangesSignerAddress_Test is StateT5_VerifierChangesSignerAddress {

    function testCan_Verifier1DeductBalance_WhenNewSignerAddressIsDifferentFromCurrentOne() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1_Id).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1_Id).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;

        // Record epoch fees before deduction
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, nonce);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount); 

        vm.prank(verifier1NewSigner);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);

        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 netFee = amount - protocolFee - votingFee;

        // Check epoch fees after deduction
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not updated correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voter fees not updated correctly");
        assertEq(epochFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");

        // Check storage state: verifier
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");
    }

    // state transition: issuer decreases fee
    function testCan_Issuer1DecreasesFee() public {
        uint128 newFee = issuer1SchemaFee / 2;

        // Record schema state before
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        uint128 oldFee = schemaBefore.currentFee;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeReduced(schemaId1, newFee, oldFee);

        vm.prank(issuer1);
        paymentsController.updateSchemaFee(issuer1_Id, schemaId1, newFee);

        // Check schema state after
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.currentFee, newFee, "Schema currentFee not updated correctly");
        assertEq(schemaAfter.nextFee, 0, "Schema nextFee should be 0 after immediate fee reduction");
        assertEq(schemaAfter.nextFeeTimestamp, 0, "Schema nextFeeTimestamp should be 0 after immediate fee reduction");
    }

}


abstract contract StateT6_IssuerDecreasesFee is StateT5_VerifierChangesSignerAddress {

    uint128 public issuer1DecreasedSchemaFee = issuer1SchemaFee / 2;

    function setUp() public virtual override {
        super.setUp();
        
        // Decrease fee
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(issuer1_Id, schemaId1, issuer1DecreasedSchemaFee);
    }
}

// issuer decreases fee: impact should be instant
contract StateT6_IssuerDecreasesFee_Test is StateT6_IssuerDecreasesFee {

    function testCan_Verifier1DeductBalance_WithDecreasedFee() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1_Id).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1_Id).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;

        // Record epoch fees before deduction
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature: use new verifier1's new signer address
        uint128 amount = issuer1DecreasedSchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, nonce);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount); 

        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);

        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 netFee = amount - protocolFee - votingFee;

        // Check epoch fees after deduction
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not updated correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voter fees not updated correctly");
        assertEq(epochFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");

        // Check storage state: verifier
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");
    }

    //state transition: issuer increases fee
    function testCan_Issuer1IncreasesFee() public {
        uint128 newFee = issuer1SchemaFee * 2;

        // Record schema state before
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        uint128 oldFee = schemaBefore.currentFee;

        // Expect event emissions: SchemaNextFeeSet, SchemaFeeIncreased
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaNextFeeSet(schemaId1,newFee, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD(), oldFee);

        vm.prank(issuer1);
        paymentsController.updateSchemaFee(issuer1_Id, schemaId1, newFee);

        // Check schema state after
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.currentFee, schemaBefore.currentFee, "Schema currentFee should be unchanged");
        assertEq(schemaAfter.nextFee, newFee, "Schema nextFee should be updated correctly");
        assertEq(schemaAfter.nextFeeTimestamp, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD(), "Schema nextFeeTimestamp should be updated correctly");
    }
}

abstract contract StateT7_IssuerIncreasedFeeIsAppliedAfterDelay is StateT6_IssuerDecreasesFee {

    uint128 public issuer1IncreasedSchemaFee = issuer1SchemaFee * 2;

    function setUp() public virtual override {
        super.setUp();
        
        // Increase fee
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(issuer1_Id, schemaId1, issuer1IncreasedSchemaFee);

        vm.warp(block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD());
    }
}

// issuer increased fee: impact should applied now that delay has passed
contract StateT7_IssuerIncreasedFeeIsAppliedAfterDelay_Test is StateT7_IssuerIncreasedFeeIsAppliedAfterDelay {

    function testCan_Verifier1DeductBalance_WithIncreasedFee() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1_Id).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1_Id).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;
       
        // Record epoch fees before deduction
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer1IncreasedSchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, nonce);
        
        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeIncreased(schemaId1, issuer1DecreasedSchemaFee, issuer1IncreasedSchemaFee);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount); 

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);

        vm.prank(verifier1NewSigner);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
        
        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 netFee = amount - protocolFee - votingFee;
        
        
        // Check epoch fees after deduction
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not updated correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voter fees not updated correctly");
        assertEq(epochFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");
       
        // Check storage state: verifier
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");
    }

    // state transition: createa schema w/ 0 fees
    function testCan_Issuer3CreatesSchemaWith0Fees() public {
        uint128 fee = 0;

        // expected schemaId
        bytes32 expectedSchemaId3 = PaymentsController_generateSchemaId(block.number, issuer3_Id);

        // Expect the SchemaCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SchemaCreated(expectedSchemaId3, issuer3_Id, fee);
        
        vm.prank(issuer3);
        bytes32 schemaId = paymentsController.createSchema(issuer3_Id, fee);
        
        // check schemaId
        assertEq(schemaId, expectedSchemaId3, "schemaId not set correctly");
        
        // Check storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId3);
        assertEq(schema.currentFee, fee, "Schema currentFee not updated correctly");
        assertEq(schema.nextFee, 0, "Schema nextFee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Schema nextFee timestamp should be 0 for new schema");
    }
}

abstract contract StateT8_Issuer3CreatesSchemaWith0Fees is StateT7_IssuerIncreasedFeeIsAppliedAfterDelay {

    function setUp() public virtual override {
        super.setUp();
        
        // Create schema with 0 fees
        vm.prank(issuer3);
        schemaId3 = paymentsController.createSchema(issuer3_Id, 0);
    }
}

// issuer created schema with 0 fees: impact should be instant
contract StateT8_Issuer3CreatesSchemaWith0Fees_Test is StateT8_Issuer3CreatesSchemaWith0Fees {

    function testCan_Verifier2DeductBalance_With0FeeSchema() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier2_Id).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier2_Id).totalExpenditure;

        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer3_Id).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer3_Id).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId3).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId3).totalVerified;
        
        
        // Record epoch fees before deduction
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;
        
        // Generate signature
        uint128 amount = 0;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer);
        bytes memory signature = generateDeductBalanceZeroFeeSignature(verifier2SignerPrivateKey, issuer3_Id, verifier2_Id, schemaId3, expiry, nonce);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerifiedZeroFee(schemaId3);

        vm.prank(verifier2Signer);
        paymentsController.deductBalanceZeroFee(issuer3_Id, verifier2_Id, schemaId3, expiry, signature);

        // Check storage state: verifier (no changes to balance or expenditure)
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier2_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore, "Verifier balance should remain unchanged for zero fee");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore, "Verifier totalExpenditure should remain unchanged for zero fee");

        // Check storage state: issuer (only totalVerified increments)
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer3_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore, "Issuer totalNetFeesAccrued should remain unchanged for zero fee");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified should increment by 1");

        // Check storage state: schema (only totalVerified increments)
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId3);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore, "Schema totalGrossFeesAccrued should remain unchanged for zero fee");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified should increment by 1");
        assertEq(schema.currentFee, 0, "Schema currentFee should remain 0");

        // Check epoch fees (no changes)
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore, "Protocol fees should remain unchanged for zero fee");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore, "Voter fees should remain unchanged for zero fee");
    }

//------------------------------ negative tests for deductBalanceZeroFee ------------------------------

    function testCannot_DeductBalanceZeroFee_WhenExpiryIsInThePast() public {
        vm.expectRevert(Errors.SignatureExpired.selector);
        vm.prank(verifier2Signer);
        paymentsController.deductBalanceZeroFee(issuer3_Id, verifier2_Id, schemaId3, block.timestamp, "");
    }


    function testCannot_DeductBalanceZeroFee_WhenSchemaDoesNotHave0Fee() public {
        vm.expectRevert(Errors.InvalidSchemaFee.selector);
        vm.prank(verifier2Signer);
        paymentsController.deductBalanceZeroFee(issuer3_Id, verifier2_Id, schemaId1, block.timestamp + 1000, "");
    }

    function testCannot_DeductBalanceZeroFee_InvalidSignature() public {
        vm.expectRevert(Errors.InvalidSignature.selector);
        vm.prank(verifier2Signer);
        paymentsController.deductBalanceZeroFee(issuer3_Id, verifier2_Id, schemaId3, block.timestamp + 1000, "");
    }
    
//------------------------------ state transition: subsidies - verifiers stake MOCA ------------------------------
    function testCan_Verifier1StakeMOCA() public {
        uint128 amount = 10 ether;

        uint256 verifier1MocaStakedBefore = paymentsController.getVerifier(verifier1_Id).mocaStaked;

        vm.startPrank(verifier1Asset);
            mockMoca.approve(address(paymentsController), amount);

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierMocaStaked(verifier1_Id, verifier1Asset, amount);

            paymentsController.stakeMoca(verifier1_Id, amount);
        vm.stopPrank();

        // Check storage state
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifier.mocaStaked, verifier1MocaStakedBefore + amount, "Verifier mocaStaked not updated correctly");
    }

    function testCan_paymentsControllerAdmin_UpdatePoolId() public {
        bytes32 poolId1 = bytes32("123");

        // Record state before
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.PoolIdUpdated(schemaId1, poolId1);

        // Perform update
        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(schemaId1, poolId1);

        // Check state after
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.poolId, poolId1, "Schema poolId not updated correctly");
        assertEq(schemaAfter.schemaId, schemaBefore.schemaId, "SchemaId should not change");
        assertEq(schemaAfter.issuerId, schemaBefore.issuerId, "IssuerId should not change");
    }
}

abstract contract StateT9_Verifier1StakeMOCA is StateT8_Issuer3CreatesSchemaWith0Fees {
    bytes32 public poolId1 = bytes32("123");
        
    function setUp() public virtual override {
        super.setUp();
        
        uint128 amount = 10 ether;

        // verifier1: stakes MOCA
        vm.startPrank(verifier1Asset);
            mockMoca.approve(address(paymentsController), amount);
            paymentsController.stakeMoca(verifier1_Id, amount);
        vm.stopPrank();

        // paymentsControllerAdmin: associate schema with pool
        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(schemaId1, poolId1);
    }
}

contract StateT9_Verifier1StakeMOCA_Test is StateT9_Verifier1StakeMOCA {

//------------------------------ negative tests for stakeMoca ------------------------------
    function testCannot_StakeMoca_WhenAmountIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1Asset);
        paymentsController.stakeMoca(verifier1_Id, 0);
    }
    
    function testCannot_StakeMoca_WhenCallerIsNotVerifierAsset() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(verifier1);
        paymentsController.stakeMoca(verifier1_Id, 10 ether);
    }

//------------------------------ negative tests for updatePoolId ------------------------------
    function testCannot_UpdatePoolId_WhenSchemaDoesNotExist() public {
        vm.expectRevert(Errors.InvalidSchema.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(bytes32("456"), bytes32("123"));
    }
    
    function testCannot_UpdatePoolId_WhenCallerIsNotPaymentsControllerAdmin() public {
        vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin.selector);
        vm.prank(verifier1);
        paymentsController.updatePoolId(schemaId1, bytes32("123"));
    }

//------------------------------ deductBalance should book subsidies for verifier ------------------------------
    function testCan_Verifier1DeductBalance_ShouldBookSubsidies() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1_Id).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1_Id).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;
       
        // Record epoch fees before deduction
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer1IncreasedSchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, nonce);
        
        // calc. subsidy
        uint256 mocaStaked = paymentsController.getVerifier(verifier1_Id).mocaStaked;
        uint256 subsidyPct = paymentsController.getVerifierSubsidyPercentage(mocaStaked);
        uint256 subsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier1_Id, poolId1, schemaId1, subsidy);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount); 

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);

        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
        
        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 netFee = amount - protocolFee - votingFee;
        
        
        // Check epoch fees after deduction
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not updated correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voter fees not updated correctly");
        assertEq(epochFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");
       
        // Check storage state: verifier
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");

        // check subsidy booked correctly
        uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        assertEq(epochPoolSubsidies, subsidy, "Subsidy not booked correctly");
        
        uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier1_Id);
        assertEq(epochPoolVerifierSubsidies, subsidy, "Subsidy not booked correctly");
    }   
}

abstract contract StateT10_AllVerifiersStakedMOCA is StateT9_Verifier1StakeMOCA {
    bytes32 public poolId2 = bytes32("234");
    bytes32 public poolId3 = bytes32("345");

    function setUp() public virtual override {
        super.setUp();
        
        // verifier2: stakes 20 MOCA for 20% subsidy tier
        vm.startPrank(verifier2Asset);
            mockMoca.approve(address(paymentsController), 20 ether);
            paymentsController.stakeMoca(verifier2_Id, 20 ether);
            // for verification payments
            mockUSD8.approve(address(paymentsController), 100 * 1e6);
            paymentsController.deposit(verifier2_Id, 100 * 1e6);
        vm.stopPrank();

        // verifier3: stakes 30 MOCA for 30% subsidy tier
        vm.startPrank(verifier3Asset);
            mockMoca.approve(address(paymentsController), 30 ether);
            paymentsController.stakeMoca(verifier3_Id, 30 ether);
        vm.stopPrank();
        
        // paymentsControllerAdmin: associate schema2 and schema3 with pools
        vm.startPrank(paymentsControllerAdmin);
            paymentsController.updatePoolId(schemaId2, poolId2);
            paymentsController.updatePoolId(schemaId3, poolId3);
        vm.stopPrank();
    }
}

// Check subsidies being booked for other tiers: verifier2 and verifier3
// Check that no subsidies are booked for schema3 - zero-fee schema. even if schema is associated to a pool.
contract StateT10_AllVerifiersStakedMOCA_Test is StateT10_AllVerifiersStakedMOCA {

    //note: verifier 2: deposited 100 USD8 for verification payments. But did stake 20 MOCA for 20% subsidy tier.
    function testCan_Verifier2DeductBalance_ShouldBookSubsidies() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier2_Id).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier2_Id).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer2_Id).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId2).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId2).totalVerified;
       
        // Record epoch fees before deduction
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer2SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer);
        bytes memory signature = generateDeductBalanceSignature(verifier2SignerPrivateKey, issuer2_Id, verifier2_Id, schemaId2, amount, expiry, nonce);
        
        // calc. subsidy (verifier2 staked 20 ether = 20% subsidy)
        uint256 mocaStaked = paymentsController.getVerifier(verifier2_Id).mocaStaked;
        assertEq(mocaStaked, 20 ether, "Verifier2 should have 20 ether staked");
        uint256 subsidyPct = paymentsController.getVerifierSubsidyPercentage(mocaStaked);
        assertEq(subsidyPct, 2000, "Verifier2 should have 20% subsidy");
        uint256 subsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier2_Id, poolId2, schemaId2, subsidy);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier2_Id, schemaId2, issuer2_Id, amount); 

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId2);

        vm.prank(verifier2Signer);
        paymentsController.deductBalance(issuer2_Id, verifier2_Id, schemaId2, amount, expiry, signature);
        
        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 netFee = amount - protocolFee - votingFee;
        
        // Check epoch fees after deduction
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not updated correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voter fees not updated correctly");
        assertEq(epochFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");
       
        // Check storage state: verifier
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier2_Id);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer2_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId2);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");

        // check subsidy booked correctly
        uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2);
        assertEq(epochPoolSubsidies, subsidy, "Subsidy not booked correctly for pool2");
        
        uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2_Id);
        assertEq(epochPoolVerifierSubsidies, subsidy, "Subsidy not booked correctly for verifier2");
    }


    //note: verifier 3: deposited 0 USD8 for verification payments. But did stake 30 MOCA for 30% subsidy tier.
    function testCan_Verifier3DeductBalance_ShouldBookSubsidies() public {
        // For verifier3, we'll use the zero-fee schema (schemaId3) but still test subsidy booking
        // Generate signature for zero-fee deduction
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier3Signer);
        bytes memory signature = generateDeductBalanceZeroFeeSignature(verifier3SignerPrivateKey, issuer3_Id, verifier3_Id, schemaId3, expiry, nonce);
        
        // calc. subsidy (verifier3 staked 30 ether = 30% subsidy, but on 0 fee)
        uint256 mocaStaked = paymentsController.getVerifier(verifier3_Id).mocaStaked;
        assertEq(mocaStaked, 30 ether, "Verifier3 should have 30 ether staked");
        uint256 subsidyPct = paymentsController.getVerifierSubsidyPercentage(mocaStaked);
        assertEq(subsidyPct, 3000, "Verifier3 should have 30% subsidy");
        // No subsidy for zero-fee schemas
        uint256 subsidy = 0;

        // Expect only SchemaVerifiedZeroFee event (no SubsidyBooked event for zero-fee)
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerifiedZeroFee(schemaId3);

        vm.prank(verifier3Signer);
        paymentsController.deductBalanceZeroFee(issuer3_Id, verifier3_Id, schemaId3, expiry, signature);

        // Check that no subsidy was booked (zero-fee schemas don't generate subsidies)
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId3);
        assertEq(epochPoolSubsidies, 0, "No subsidy should be booked for zero-fee schema");
        
        uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId3, verifier3_Id);
        assertEq(epochPoolVerifierSubsidies, 0, "No subsidy should be booked for verifier3 with zero-fee schema");
    }

    // state transition: issuer can claim fees
    function testCan_IssuerClaimFees() public {
        // Record issuer's state before claiming fees
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
        uint256 issuerTotalClaimedBefore = paymentsController.getIssuer(issuer1_Id).totalClaimed;

        uint256 claimableFees = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer1_Id).totalClaimed;
        assertGt(claimableFees, 0, "Claimable fees should be greater than 0");

        // Record token balances before claim
        uint256 issuerTokenBalanceBefore = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));

        // Expect event emission
        vm.expectEmit(true, false, false, false, address(paymentsController));
        emit Events.IssuerFeesClaimed(issuer1_Id, claimableFees);

        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1_Id);

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore, "Issuer totalNetFeesAccrued must be unchanged");
        assertEq(issuer.totalClaimed, issuerTotalClaimedBefore + claimableFees, "Issuer totalClaimed must be increased by claimable fees");

        // Check token balances after claim
        uint256 issuerTokenBalanceAfter = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        assertEq(issuerTokenBalanceAfter, issuerTokenBalanceBefore + claimableFees, "Issuer should receive claimed fees in tokens");
        assertEq(controllerTokenBalanceAfter, controllerTokenBalanceBefore - claimableFees, "Controller should send out claimed fees in tokens");
    }
}

abstract contract StateT11_IssuerClaimsAllFees is StateT10_AllVerifiersStakedMOCA {   
    function setUp() public virtual override {
        super.setUp();
        
        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1_Id);
    }
}

contract StateT11_IssuerClaimsAllFees_Test is StateT11_IssuerClaimsAllFees {
    
    //------------------------------ negative tests for claimFees ------------------------------

    function testCannot_ClaimFees_WhenIssuerDoesNotHaveClaimableFees() public {     
        vm.expectRevert(Errors.NoClaimableFees.selector);
        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1_Id);
    }

    function testCannot_ClaimFees_WhenCallerIsNotIssuerAsset() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(issuer1);
        paymentsController.claimFees(issuer1_Id);
    }

    // state transition: issuer change assetAddress
    function testCan_IssuerUpdateAssetAddress() public{
        // Record issuer's state before update
        DataTypes.Issuer memory issuer1Before = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer1Before.assetAddress, issuer1Asset, "Issuer asset address should be the same");
        
        // new addr
        address issuer1_newAssetAddress = address(0x1234567890123456789012345678901234567890);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.AssetAddressUpdated(issuer1_Id, issuer1_newAssetAddress);
 
        vm.prank(issuer1);
        paymentsController.updateAssetAddress(issuer1_Id, issuer1_newAssetAddress);

        // Check storage state: issuer
        DataTypes.Issuer memory issuer1After = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuer1After.assetAddress, issuer1_newAssetAddress, "Issuer asset address should be updated");
    }
}

abstract contract StateT11_IssuerChangesAssetAddress is StateT11_IssuerClaimsAllFees {
    
    address public issuer1_newAssetAddress = address(0x1234567890123456789012345678901234567890);

    function setUp() public virtual override {
        super.setUp();
        
        // issuer changes asset address
        vm.prank(issuer1);
        paymentsController.updateAssetAddress(issuer1_Id, issuer1_newAssetAddress);

        // deductBalance called by verifier
        uint256 expiry = block.timestamp + 100;
        uint256 nonce = getVerifierNonce(verifier1NewSigner);
        uint128 amount = issuer1IncreasedSchemaFee;
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, nonce);
        
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
    }
}

contract StateT11_IssuerChangesAssetAddress_Test is StateT11_IssuerChangesAssetAddress {

    function testCan_Issuer1ClaimFees_WithNewAssetAddress() public {
        // Record issuer's state before claim
        DataTypes.Issuer memory issuerBefore = paymentsController.getIssuer(issuer1_Id);
        uint256 issuerTotalNetFeesAccruedBefore = issuerBefore.totalNetFeesAccrued;
        uint256 issuerTotalClaimedBefore = issuerBefore.totalClaimed;

        // Record TOTAL_CLAIMED_VERIFICATION_FEES before claim
        uint256 totalClaimedBefore = paymentsController.TOTAL_CLAIMED_VERIFICATION_FEES();
        
        // Calculate claimable fees (fees from the deductBalance in setup)
        uint256 claimableFees = issuerTotalNetFeesAccruedBefore - issuerTotalClaimedBefore;
        assertTrue(claimableFees > 0, "Issuer should have claimable fees");
        
        // Check token balances before claim
        uint256 newAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(issuer1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        
        // Expect event emission
        vm.expectEmit(true, false, false, false, address(paymentsController));
        emit Events.IssuerFeesClaimed(issuer1_Id, claimableFees);
        
        // Claim fees using new asset address
        vm.prank(issuer1_newAssetAddress);
        paymentsController.claimFees(issuer1_Id);
        
        // Check storage state: issuer
        DataTypes.Issuer memory issuerAfter = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuerAfter.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore, "Issuer totalNetFeesAccrued should remain unchanged");
        assertEq(issuerAfter.totalClaimed, issuerTotalNetFeesAccruedBefore, "Issuer totalClaimed should equal totalNetFeesAccrued after claim");
        assertEq(issuerAfter.assetAddress, issuer1_newAssetAddress, "Issuer asset address should be the new address");
        
        // Check token balances after claim
        uint256 newAssetAddressTokenBalanceAfter = mockUSD8.balanceOf(issuer1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceAfter = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        
        // Verify fees were transferred to new asset address, not old one
        assertEq(newAssetAddressTokenBalanceAfter, newAssetAddressTokenBalanceBefore + claimableFees, "New asset address should receive claimed fees");
        assertEq(oldAssetAddressTokenBalanceAfter, oldAssetAddressTokenBalanceBefore, "Old asset address should not receive any fees");
        assertEq(controllerTokenBalanceAfter, controllerTokenBalanceBefore - claimableFees, "Controller should transfer out claimed fees");
        
        // Check global counter
        assertEq(paymentsController.TOTAL_CLAIMED_VERIFICATION_FEES(), totalClaimedBefore + claimableFees, "TOTAL_CLAIMED_VERIFICATION_FEES should be updated");
    }

    function testCannot_Issuer1ClaimFees_WithOldAssetAddress() public {
        // Verify issuer has claimable fees
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1_Id);
        uint256 claimableFees = issuer.totalNetFeesAccrued - issuer.totalClaimed;
        assertGt(claimableFees, 0, "Issuer should have claimable fees");
        
        // Attempt to claim with old asset address should fail
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1_Id);
    }

    //------------------------------ negative tests for updateAssetAddress ------------------------------

    function testCannot_UpdateAssetAddress_WhenAssetAddressIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(issuer1);
        paymentsController.updateAssetAddress(issuer1_Id, address(0));
    }

    function testCannot_UpdateAssetAddress_WhenCallerIsNotIssuerAdmin() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(issuer2);
        paymentsController.updateAssetAddress(issuer1_Id, issuer1_newAssetAddress);
    }

    //------------------------------ state transition: verifier updateAssetAddress ------------------------------
    function testCan_VerifierUpdateAssetAddress() public {
        // Record verifier's state before update
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifierBefore.assetAddress, verifier1Asset, "Verifier asset address should be the same");

        // new addr
        address verifier1_newAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_newAssetAddress", block.timestamp, block.prevrandao)))));

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.AssetAddressUpdated(verifier1_Id, verifier1_newAssetAddress);

        vm.prank(verifier1);
        paymentsController.updateAssetAddress(verifier1_Id, verifier1_newAssetAddress);
        
        // Check storage state: verifier
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifierAfter.assetAddress, verifier1_newAssetAddress, "Verifier asset address should be updated");
        assertNotEq(verifierAfter.assetAddress, verifier1Asset, "Verifier asset address should be updated");
    }
}

abstract contract StateT12_VerifierChangesAssetAddress is StateT11_IssuerChangesAssetAddress {

    address public verifier1_newAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_newAssetAddress", block.timestamp, block.prevrandao)))));

    function setUp() public virtual override {
        super.setUp();
        
        vm.prank(verifier1);
        paymentsController.updateAssetAddress(verifier1_Id, verifier1_newAssetAddress);
    }
}

contract StateT12_VerifierChangesAssetAddress_Test is StateT12_VerifierChangesAssetAddress {
    
    function testCan_VerifierWithdrawUSD8_WithNewAssetAddress() public {
        // Record verifier's state before withdraw
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1_Id);
        uint128 verifierCurrentBalanceBefore = verifierBefore.currentBalance;
        assertGt(verifierCurrentBalanceBefore, 0, "Verifier should have balance");
        assertEq(verifierBefore.assetAddress, verifier1_newAssetAddress, "Verifier asset address should be updated");

        // Check token balances before withdraw
        uint256 newAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(verifier1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(verifier1Asset);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));

        // event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifier1_Id, verifier1_newAssetAddress, verifierCurrentBalanceBefore);

        vm.prank(verifier1_newAssetAddress);
        paymentsController.withdraw(verifier1_Id, verifierCurrentBalanceBefore);

        // Check storage state: verifier
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifierAfter.currentBalance, 0, "Verifier balance should be zero after full withdraw");
        assertEq(verifierAfter.assetAddress, verifier1_newAssetAddress, "Verifier asset address should remain unchanged");

        // Check token balances after withdraw
        uint256 newAssetAddressTokenBalanceAfter = mockUSD8.balanceOf(verifier1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceAfter = mockUSD8.balanceOf(verifier1Asset);
        uint256 controllerTokenBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        
        // Verify tokens were transferred to new asset address, not old one
        assertEq(newAssetAddressTokenBalanceAfter, newAssetAddressTokenBalanceBefore + verifierCurrentBalanceBefore, "New asset address should receive withdrawn funds");
        assertEq(oldAssetAddressTokenBalanceAfter, oldAssetAddressTokenBalanceBefore, "Old asset address should not receive any funds");
        assertEq(controllerTokenBalanceAfter, controllerTokenBalanceBefore - verifierCurrentBalanceBefore, "Controller should transfer out withdrawn funds");
    }

    function testCan_VerifierPartialWithdraw_WithNewAssetAddress() public {
        // Record verifier's state before withdraw
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1_Id);
        uint128 verifierCurrentBalanceBefore = verifierBefore.currentBalance;
        assertGt(verifierCurrentBalanceBefore, 0, "Verifier should have non-zero balance");
        
        uint128 withdrawAmount = verifierCurrentBalanceBefore / 2;
        
        // Check token balances before withdraw
        uint256 newAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(verifier1_newAssetAddress);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));

        // event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifier1_Id, verifier1_newAssetAddress, withdrawAmount);

        vm.prank(verifier1_newAssetAddress);
        paymentsController.withdraw(verifier1_Id, withdrawAmount);

        // Check storage state: verifier
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifierAfter.currentBalance, verifierCurrentBalanceBefore - withdrawAmount, "Verifier balance should be reduced by withdraw amount");

        // Check token balances after withdraw
        uint256 newAssetAddressTokenBalanceAfter = mockUSD8.balanceOf(verifier1_newAssetAddress);
        uint256 controllerTokenBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        
        // Verify partial withdrawal
        assertEq(newAssetAddressTokenBalanceAfter, newAssetAddressTokenBalanceBefore + withdrawAmount, "New asset address should receive withdrawn amount");
        assertEq(controllerTokenBalanceAfter, controllerTokenBalanceBefore - withdrawAmount, "Controller should transfer out withdrawn amount");
    }

    function testCannot_VerifierWithdraw_WithOldAssetAddress() public {
        // Verify verifier has balance to withdraw
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1_Id);
        uint128 currentBalance = verifier.currentBalance;
        assertGt(currentBalance, 0, "Verifier should have balance");
        
        // Attempt to withdraw with old asset address should fail
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifier1_Id, currentBalance);
    }

    // --------------- negative tests for withdraw ------------------------
    function testCannot_VerifierWithdraw_WhenAmountIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1_newAssetAddress);
        paymentsController.withdraw(verifier1_Id, 0);
    }

    function testCannot_VerifierWithdraw_WhenAmountIsGreaterThanBalance() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(verifier1_newAssetAddress);
        paymentsController.withdraw(verifier1_Id, 1000 ether);
    }

    function testCannot_VerifierWithdraw_WhenCallerIsNotVerifierAsset() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(verifier1);
        paymentsController.withdraw(verifier1_Id, 1 ether);
    }

    // --------------- state transition: updateAdminAddress ------------------------

    function testCan_Verifier1UpdateAdminAddress() public {
        // Record verifier's state before update
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifierBefore.adminAddress, verifier1, "Verifier admin address should be the same");
        
        // new admin
        address verifier1_newAdminAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_newAdminAddress", block.timestamp, block.prevrandao)))));

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.AdminAddressUpdated(verifier1_Id, verifier1_newAdminAddress);

        vm.prank(verifier1);
        paymentsController.updateAdminAddress(verifier1_Id, verifier1_newAdminAddress);

        // Check storage state: verifier
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1_Id);
        assertEq(verifierAfter.adminAddress, verifier1_newAdminAddress, "Verifier admin address should be updated");
        assertNotEq(verifierAfter.adminAddress, verifier1, "Verifier admin address should be updated");
    }

    function testCan_Issuer1UpdateAdminAddress() public {
        // Record issuer's state before update
        DataTypes.Issuer memory issuerBefore = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuerBefore.adminAddress, issuer1, "Issuer admin address should be the same");

        // new admin
        address issuer1_newAdminAddress = address(uint160(uint256(keccak256(abi.encodePacked("issuer1_newAdminAddress", block.timestamp, block.prevrandao)))));

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.AdminAddressUpdated(issuer1_Id, issuer1_newAdminAddress);

        vm.prank(issuer1);
        paymentsController.updateAdminAddress(issuer1_Id, issuer1_newAdminAddress);

        // Check storage state: issuer
        DataTypes.Issuer memory issuerAfter = paymentsController.getIssuer(issuer1_Id);
        assertEq(issuerAfter.adminAddress, issuer1_newAdminAddress, "Issuer admin address should be updated");
        assertNotEq(issuerAfter.adminAddress, issuer1, "Issuer admin address should be updated");
    }

}


abstract contract StateT13_IssuersAndVerifiersChangesAdminAddress is StateT12_VerifierChangesAssetAddress {

    address public verifier1_newAdminAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_newAdminAddress", block.timestamp, block.prevrandao)))));
    address public issuer1_newAdminAddress = address(uint160(uint256(keccak256(abi.encodePacked("issuer1_newAdminAddress", block.timestamp, block.prevrandao)))));

    function setUp() public virtual override {
        super.setUp();
        
        vm.prank(verifier1);
        paymentsController.updateAdminAddress(verifier1_Id, verifier1_newAdminAddress);

        vm.prank(issuer1);
        paymentsController.updateAdminAddress(issuer1_Id, issuer1_newAdminAddress);
    }
}

contract StateT13_IssuersAndVerifiersChangesAdminAddress_Test is StateT13_IssuersAndVerifiersChangesAdminAddress {
    
    // ----- issuer's newAdmin address can call: createSchema, updateSchemaFee, updateAssetAddress ----- 

        function testCan_IssuerNewAdminAddress_CreateSchema() public {
            uint128 fee = 2000;
            
            // generate expected schemaId with new salt
            bytes32 expectedSchemaId = PaymentsController_generateSchemaId(block.number, issuer1_Id);
            
            // Expect the SchemaCreated event to be emitted
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.SchemaCreated(expectedSchemaId, issuer1_Id, fee);
            
            // Call createSchema from new admin address
            vm.prank(issuer1_newAdminAddress);
            bytes32 schemaId = paymentsController.createSchema(issuer1_Id, fee);
            
            // Assert
            assertEq(schemaId, expectedSchemaId, "schemaId not set correctly");
            
            // Verify schema storage state
            DataTypes.Schema memory schema = paymentsController.getSchema(expectedSchemaId);
            assertEq(schema.schemaId, expectedSchemaId, "Schema ID not stored correctly");
            assertEq(schema.issuerId, issuer1_Id, "Issuer ID not stored correctly");
            assertEq(schema.currentFee, fee, "Current fee not stored correctly");
            assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
            assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
        }
        
        function testCan_IssuerNewAdminAddress_UpdateSchemaFee_Decrease() public {
            uint128 newFee = issuer1IncreasedSchemaFee / 2; // Decrease fee
            
            // Record schema state before
            DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
            uint128 oldFee = schemaBefore.currentFee;
            
            // Expect event emission for fee reduction
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.SchemaFeeReduced(schemaId1, newFee, oldFee);
            
            // Call updateSchemaFee from new admin address
            vm.prank(issuer1_newAdminAddress);
            paymentsController.updateSchemaFee(issuer1_Id, schemaId1, newFee);
            
            // Check schema state after
            DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
            assertEq(schemaAfter.currentFee, newFee, "Schema currentFee not updated correctly");
            assertEq(schemaAfter.nextFee, 0, "Schema nextFee should be 0 after immediate fee reduction");
            assertEq(schemaAfter.nextFeeTimestamp, 0, "Schema nextFeeTimestamp should be 0 after immediate fee reduction");
        }
        
        function testCan_IssuerNewAdminAddress_UpdateSchemaFee_Increase() public {
            uint128 newFee = issuer1IncreasedSchemaFee * 2; // Increase fee
            
            // Record schema state before
            DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
            uint128 oldFee = schemaBefore.currentFee;
            
            // Call updateSchemaFee from new admin address
            vm.prank(issuer1_newAdminAddress);
            uint256 returnedFee = paymentsController.updateSchemaFee(issuer1_Id, schemaId1, newFee);
            
            // Assert return value
            assertEq(returnedFee, newFee, "Returned fee should match new fee");
            
            // Check schema state after
            DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
            assertEq(schemaAfter.currentFee, oldFee, "Schema currentFee should remain unchanged");
            assertEq(schemaAfter.nextFee, newFee, "Schema nextFee not set correctly");
            assertGt(schemaAfter.nextFeeTimestamp, block.timestamp, "Next fee timestamp should be in the future");
            assertGt(schemaAfter.nextFeeTimestamp, 0, "Next fee timestamp should be set");
        }
        
        function testCan_IssuerNewAdminAddress_UpdateAssetAddress() public {
            // new asset address
            address issuer1_anotherNewAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("issuer1_anotherNewAssetAddress", block.timestamp)))));
            
            // Record issuer's state before update
            DataTypes.Issuer memory issuer1Before = paymentsController.getIssuer(issuer1_Id);
            
            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.AssetAddressUpdated(issuer1_Id, issuer1_anotherNewAssetAddress);
            
            // Call updateAssetAddress from new admin address
            vm.prank(issuer1_newAdminAddress);
            address returnedAddress = paymentsController.updateAssetAddress(issuer1_Id, issuer1_anotherNewAssetAddress);
            
            // Assert return value
            assertEq(returnedAddress, issuer1_anotherNewAssetAddress, "Returned asset address incorrect");
            
            // Check storage state
            DataTypes.Issuer memory issuer1After = paymentsController.getIssuer(issuer1_Id);
            assertEq(issuer1After.assetAddress, issuer1_anotherNewAssetAddress, "Issuer asset address should be updated");
            assertEq(issuer1After.adminAddress, issuer1_newAdminAddress, "Admin address should remain the new admin");
        }

    // ----- old issuer admin cannot call these functions ----- 

        function testCannot_IssuerOldAdminAddress_CreateSchema() public {
            uint128 fee = 2000;
            
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(issuer1); // old admin address
            paymentsController.createSchema(issuer1_Id, fee);
        }
        
        function testCannot_IssuerOldAdminAddress_UpdateSchemaFee() public {
            uint128 newFee = issuer1IncreasedSchemaFee / 2;
            
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(issuer1); // old admin address
            paymentsController.updateSchemaFee(issuer1_Id, schemaId1, newFee);
        }
        
        function testCannot_IssuerOldAdminAddress_UpdateAssetAddress() public {
            address newAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("newAssetAddress", block.timestamp)))));
            
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(issuer1); // old admin address
            paymentsController.updateAssetAddress(issuer1_Id, newAssetAddress);
        }

    // ----- verifier's newAdmin address can call: updateSignerAddress, updateAssetAddress ----- 

        function testCan_VerifierNewAdminAddress_UpdateSignerAddress() public {
            (address verifier1AnotherNewSigner, ) = makeAddrAndKey("verifier1AnotherNewSigner");
            
            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierSignerAddressUpdated(verifier1_Id, verifier1AnotherNewSigner);
            
            // Call updateSignerAddress from new admin address
            vm.prank(verifier1_newAdminAddress);
            paymentsController.updateSignerAddress(verifier1_Id, verifier1AnotherNewSigner);
            
            // Check storage state
            DataTypes.Verifier memory verifier1After = paymentsController.getVerifier(verifier1_Id);
            assertEq(verifier1After.signerAddress, verifier1AnotherNewSigner, "Verifier signer address should be updated");
            assertEq(verifier1After.adminAddress, verifier1_newAdminAddress, "Admin address should remain the new admin");
        }
        
        function testCan_VerifierNewAdminAddress_UpdateAssetAddress() public {
            // new asset address
            address verifier1_anotherNewAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_anotherNewAssetAddress", block.timestamp)))));
            
            // Record verifier's state before update
            DataTypes.Verifier memory verifier1Before = paymentsController.getVerifier(verifier1_Id);
            
            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.AssetAddressUpdated(verifier1_Id, verifier1_anotherNewAssetAddress);
            
            // Call updateAssetAddress from new admin address
            vm.prank(verifier1_newAdminAddress);
            address returnedAddress = paymentsController.updateAssetAddress(verifier1_Id, verifier1_anotherNewAssetAddress);
            
            // Assert return value
            assertEq(returnedAddress, verifier1_anotherNewAssetAddress, "Returned asset address incorrect");
            
            // Check storage state
            DataTypes.Verifier memory verifier1After = paymentsController.getVerifier(verifier1_Id);
            assertEq(verifier1After.assetAddress, verifier1_anotherNewAssetAddress, "Verifier asset address should be updated");
            assertEq(verifier1After.adminAddress, verifier1_newAdminAddress, "Admin address should remain the new admin");
        }

    // ----- old verifier admin cannot call these functions ----- 

        function testCannot_VerifierOldAdminAddress_UpdateSignerAddress() public {
            (address newSigner, ) = makeAddrAndKey("newSigner");
            
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(verifier1); // old admin address
            paymentsController.updateSignerAddress(verifier1_Id, newSigner);
        }
        
        function testCannot_VerifierOldAdminAddress_UpdateAssetAddress() public {
            address newAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("newAssetAddress", block.timestamp)))));
            
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(verifier1); // old admin address
            paymentsController.updateAssetAddress(verifier1_Id, newAssetAddress);
        }

    // state transition: paymentsControllerAdmin calls updateProtocolFee
    
        function testCan_PaymentsControllerAdmin_UpdateProtocolFee() public {
            // Record protocol fee before update
            uint256 oldProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
            uint256 newProtocolFee = oldProtocolFee + 100;
            assertNotEq(newProtocolFee, oldProtocolFee, "New protocol fee should differ from old fee");

            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.ProtocolFeePercentageUpdated(newProtocolFee);

            vm.prank(paymentsControllerAdmin);
            paymentsController.updateProtocolFeePercentage(newProtocolFee);

            // Check protocol fee after update
            uint256 updatedProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
            assertEq(updatedProtocolFee, newProtocolFee, "Protocol fee should be updated to new value");
            assertNotEq(updatedProtocolFee, oldProtocolFee, "Protocol fee should not be the old value");
        }
}

abstract contract StateT14_PaymentsControllerAdminIncreasesProtocolFee is StateT13_IssuersAndVerifiersChangesAdminAddress {

    uint256 public newProtocolFee;

    function setUp() public virtual override {
        super.setUp();

        newProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE() + 100;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateProtocolFeePercentage(newProtocolFee);
    }
}   

contract StateT14_PaymentsControllerAdminIncreasesProtocolFee_Test is StateT14_PaymentsControllerAdminIncreasesProtocolFee {
    
    function testCan_PaymentsControllerAdmin_UpdateProtocolFee() public {
        uint256 updatedProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
        assertEq(updatedProtocolFee, newProtocolFee, "Protocol fee should be updated to new value");
    }

    // check that deductBalance books the correct amount of protocol fee when protocol fee is increased     
    function testCan_DeductBalance_WhenProtocolFeeIsIncreased() public {
        // Note: verifier2 has 100 USD8 deposited (from StateT10) and 20 MOCA staked for 20% subsidy
        // schemaId2 fee is 20 USD8, and it's associated with poolId2
        
        // Record initial states
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        DataTypes.FeesAccrued memory poolFeesBefore = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId2);
        
        // Verify verifier2 has sufficient USD8 balance
        uint256 verifier2USD8BalanceBefore = paymentsController.getVerifier(verifier2_Id).currentBalance;
        assertGe(verifier2USD8BalanceBefore, issuer2SchemaFee, "Verifier2 should have sufficient USD8 balance");
        
        uint256 verifier2ExpenditureBefore = paymentsController.getVerifier(verifier2_Id).totalExpenditure;
        uint256 issuer2NetFeesBefore = paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued;
        
        // Record subsidy data before
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2_Id);
        
        // Use schemaId2 which has poolId2 associated
        uint128 amount = issuer2SchemaFee; // 20 USD8 (to be paid from USD8 balance)
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer);
        bytes memory signature = generateDeductBalanceSignature(verifier2SignerPrivateKey, issuer2_Id, verifier2_Id, schemaId2, amount, expiry, nonce);

        // Calculate expected fees with increased protocol fee (6% instead of 5%)
        uint256 expectedProtocolFee = (amount * newProtocolFee) / Constants.PRECISION_BASE;
        uint256 expectedVotingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 expectedNetFee = amount - expectedProtocolFee - expectedVotingFee;
        
        // Calculate expected subsidy based on MOCA staked (verifier2 has 20 MOCA = 20% subsidy tier)
        uint256 mocaStaked = paymentsController.getVerifier(verifier2_Id).mocaStaked;
        assertEq(mocaStaked, 20 ether, "Verifier2 should have 20 MOCA staked");
        uint256 expectedSubsidyPct = 2000; // 20%
        uint256 expectedSubsidy = (amount * expectedSubsidyPct) / Constants.PRECISION_BASE;

        // Expect events
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier2_Id, poolId2, schemaId2, expectedSubsidy);
        
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier2_Id, schemaId2, issuer2_Id, amount);
        
        vm.expectEmit(true, false, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId2);

        // Execute deductBalance - this deducts USD8, not MOCA
        vm.prank(verifier2Signer);
        paymentsController.deductBalance(issuer2_Id, verifier2_Id, schemaId2, amount, expiry, signature);

        // Verify global epoch fees updated correctly with new protocol fee
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, epochFeesBefore.feesAccruedToProtocol + expectedProtocolFee, "Protocol fees incorrectly updated w/ increased percentage");
        assertEq(epochFeesAfter.feesAccruedToVoters, epochFeesBefore.feesAccruedToVoters + expectedVotingFee, "Voting fees incorrectly updated");
        
        
        // Verify pool-specific fees updated correctly
        DataTypes.FeesAccrued memory poolFeesAfter = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId2);
        assertEq(poolFeesAfter.feesAccruedToProtocol, poolFeesBefore.feesAccruedToProtocol + expectedProtocolFee, "Pool protocol fees incorrectly updated w/ increased percentage");
        assertEq(poolFeesAfter.feesAccruedToVoters, poolFeesBefore.feesAccruedToVoters + expectedVotingFee, "Pool voting fees incorrectly updated");
        
        // Verify verifier USD8 balance decreased (not MOCA balance)
        assertEq(paymentsController.getVerifier(verifier2_Id).currentBalance, verifier2USD8BalanceBefore - amount, "Verifier USD8 balance not decreased correctly");
        assertEq(paymentsController.getVerifier(verifier2_Id).totalExpenditure, verifier2ExpenditureBefore + amount, "Verifier expenditure not increased correctly");
        
        // Verify MOCA balance unchanged
        assertEq(paymentsController.getVerifier(verifier2_Id).mocaStaked, 20 ether, "MOCA staked should remain unchanged after deductBalance");
        
        // Verify issuer received correct net fee (in USD8)
        assertEq(paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued, issuer2NetFeesBefore + expectedNetFee, "Issuer net fees not updated correctly");
        
        // Verify subsidies booked correctly (based on MOCA staked percentage)  
        assertEq(paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2), poolSubsidiesBefore + expectedSubsidy, "Pool subsidies not booked correctly");
        assertEq(paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2_Id), verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies not booked correctly");
    }

    // ------- negative tests for updateProtocolFeePercentage() ----------
    
        function testCannot_NonAdmin_UpdateProtocolFee() public {
            uint256 attemptedNewFee = paymentsController.PROTOCOL_FEE_PERCENTAGE() + 200;
            
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(verifier1);
            paymentsController.updateProtocolFeePercentage(attemptedNewFee);
            
            // Verify fee remains unchanged
            assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), newProtocolFee, "Protocol fee should remain unchanged");
        }
        
        function testCannot_UpdateProtocolFee_WhenFeeExceedsMax() public {
            // Assuming max fee is 100% (10,000 in basis points)
            uint256 exceedingMaxFee = Constants.PRECISION_BASE + 1;
            
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateProtocolFeePercentage(exceedingMaxFee);
            
            // Verify fee remains unchanged
            assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), newProtocolFee, "Protocol fee should remain unchanged");
        }
        
        function testCannot_UpdateProtocolFee_WhenTotalFeeExceedsMax() public {
            uint256 votingFee = paymentsController.VOTING_FEE_PERCENTAGE();
            uint256 protocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();

            uint256 totalFee = votingFee + protocolFee;
            uint256 deltaToExceedTotal = Constants.PRECISION_BASE - totalFee;

            uint256 excessiveNewProtocolFee = protocolFee + deltaToExceedTotal;
            
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateProtocolFeePercentage(excessiveNewProtocolFee);
        }

}
