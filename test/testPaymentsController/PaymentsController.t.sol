// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

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
            
            vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin.selector);
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

    // ---- state transition: updateVotingFeePercentage() ----------
    
        function testCan_PaymentsControllerAdmin_UpdateVotingFee() public {
            // Arrange
            uint256 currentVotingFee = paymentsController.VOTING_FEE_PERCENTAGE();
            uint256 newVotingFee = currentVotingFee + 100;
            uint256 protocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();

            // Ensure newVotingFee does not exceed max or total fee constraints
            assertLt(newVotingFee, Constants.PRECISION_BASE, "Voting fee must be less than 100%");
            assertLe(newVotingFee + protocolFee, Constants.PRECISION_BASE, "Total fee must not exceed 100%");

            // Act & Assert: Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VotingFeePercentageUpdated(newVotingFee);

            // Act: Only admin can update
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVotingFeePercentage(newVotingFee);

            // Assert: Fee updated
            assertEq(paymentsController.VOTING_FEE_PERCENTAGE(), newVotingFee, "Voting fee should be updated");

            // Assert: Protocol fee remains unchanged
            assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), protocolFee, "Protocol fee should remain unchanged");
        }
}

abstract contract StateT15_PaymentsControllerAdminIncreasesVotingFee is StateT14_PaymentsControllerAdminIncreasesProtocolFee {

    uint256 public newVotingFee;

    function setUp() public virtual override {
        super.setUp();
        
        newVotingFee = paymentsController.VOTING_FEE_PERCENTAGE() + 100;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateVotingFeePercentage(newVotingFee);
    }
}

contract StateT15_PaymentsControllerAdminIncreasesVotingFee_Test is StateT15_PaymentsControllerAdminIncreasesVotingFee {
    
    function testCan_PaymentsControllerAdmin_UpdateVotingFee() public {
        uint256 updatedVotingFee = paymentsController.VOTING_FEE_PERCENTAGE();
        assertEq(updatedVotingFee, newVotingFee, "Voting fee should be updated to new value");
    }

    // check that deductBalance books the correct amount of voting fee when voting fee pct is increased     
    function testCan_DeductBalance_WhenVotingFeeIsIncreased() public {
        // Note: verifier2 has 100 USD8 deposited (from StateT10) and 20 MOCA staked for 20% subsidy
        // schemaId2 fee is 20 USD8, and it's associated with poolId2
        // Protocol fee was increased to 6% in StateT14, voting fee now increased to 11% in StateT15
        
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

        // Calculate expected fees with increased voting fee (11% instead of 10%) and protocol fee (6% from StateT14)
        uint256 currentProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
        uint256 expectedProtocolFee = (amount * currentProtocolFee) / Constants.PRECISION_BASE;
        uint256 expectedVotingFee = (amount * newVotingFee) / Constants.PRECISION_BASE;
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

        // Verify global epoch fees updated correctly with new voting fee
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, epochFeesBefore.feesAccruedToProtocol + expectedProtocolFee, "Protocol fees incorrectly updated w/ increased percentage");
        assertEq(epochFeesAfter.feesAccruedToVoters, epochFeesBefore.feesAccruedToVoters + expectedVotingFee, "Voting fees incorrectly updated");
        assertEq(epochFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");
        
        // Verify pool-specific fees updated correctly
        DataTypes.FeesAccrued memory poolFeesAfter = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId2);
        assertEq(poolFeesAfter.feesAccruedToProtocol, poolFeesBefore.feesAccruedToProtocol + expectedProtocolFee, "Pool protocol fees incorrectly updated w/ increased percentage");
        assertEq(poolFeesAfter.feesAccruedToVoters, poolFeesBefore.feesAccruedToVoters + expectedVotingFee, "Pool voting fees incorrectly updated");
        assertEq(poolFeesAfter.isProtocolFeeWithdrawn, false, "epochFees.isProtocolFeeWithdrawn should be false");
        assertEq(epochFeesAfter.isVotersFeeWithdrawn, false, "epochFees.isVotersFeeWithdrawn should be false");
        
        assertEq(poolFeesAfter.feesAccruedToVoters, poolFeesBefore.feesAccruedToVoters + expectedVotingFee, "Pool voting fees not updated correctly with increased percentage");
        
        // Verify verifier USD8 balance decreased (not MOCA balance)
        assertEq(paymentsController.getVerifier(verifier2_Id).currentBalance, verifier2USD8BalanceBefore - amount, "Verifier USD8 balance not decreased correctly");
        assertEq(paymentsController.getVerifier(verifier2_Id).totalExpenditure,verifier2ExpenditureBefore + amount,"Verifier expenditure not increased correctly");
        
        // Verify MOCA balance unchanged
        assertEq(paymentsController.getVerifier(verifier2_Id).mocaStaked, 20 ether, "MOCA staked should remain unchanged after deductBalance");
        
        
        // Verify issuer received correct net fee (in USD8)
        assertEq(paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued, issuer2NetFeesBefore + expectedNetFee, "Issuer net fees not updated correctly with increased voting fee");
        
        
        // Verify subsidies booked correctly (based on MOCA staked percentage)
        assertEq(paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2), poolSubsidiesBefore + expectedSubsidy, "Pool subsidies not booked correctly");
        assertEq(paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2_Id), verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies not booked correctly");
    }

    // ------- negative tests for updateVotingFeePercentage() ----------
    
        function testCannot_NonAdmin_UpdateVotingFee() public {
            uint256 attemptedNewFee = paymentsController.VOTING_FEE_PERCENTAGE() + 200;
            
            vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin.selector);
            vm.prank(verifier1);
            paymentsController.updateVotingFeePercentage(attemptedNewFee);
            
            // Verify fee remains unchanged
            assertEq(paymentsController.VOTING_FEE_PERCENTAGE(), newVotingFee, "Voting fee should remain unchanged");
        }
        
        function testCannot_UpdateVotingFee_WhenFeeExceedsMax() public {
            // Assuming max fee is 100% (10,000 in basis points)
            uint256 exceedingMaxFee = Constants.PRECISION_BASE + 1;
            
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVotingFeePercentage(exceedingMaxFee);
            
            // Verify fee remains unchanged
            assertEq(paymentsController.VOTING_FEE_PERCENTAGE(), newVotingFee, "Voting fee should remain unchanged");
        }
        
        function testCannot_UpdateVotingFee_WhenTotalFeeExceedsMax() public {
            uint256 protocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
            uint256 votingFee = paymentsController.VOTING_FEE_PERCENTAGE();
            
            uint256 totalFee = votingFee + protocolFee;
            uint256 deltaToExceedTotal = Constants.PRECISION_BASE - totalFee + 1;
            
            uint256 excessiveNewVotingFee = votingFee + deltaToExceedTotal;
            
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVotingFeePercentage(excessiveNewVotingFee);
            
            // Verify fee remains unchanged
            assertEq(paymentsController.VOTING_FEE_PERCENTAGE(), newVotingFee, "Voting fee should remain unchanged");
        }

    // ------- state transition: updateVerifierSubsidyPercentages() ----------
    
        function testCan_PaymentsControllerAdmin_UpdateVerifierSubsidyPercentages() public {
            // change for tier1: 10 moca staked -> 11% subsidy
            uint256 currentSubsidyPct = paymentsController.getVerifierSubsidyPercentage(10 ether);
            uint256 newSubsidyPct = currentSubsidyPct + 100;
            
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierStakingTierUpdated(10 ether, newSubsidyPct);

            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierSubsidyPercentages(10 ether, newSubsidyPct);

            assertEq(paymentsController.getVerifierSubsidyPercentage(10 ether), newSubsidyPct, "Verifier subsidy percentage not updated correctly");
        }
}

// change for tier1: 10 moca staked -> 11% subsidy
abstract contract StateT16_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage is StateT15_PaymentsControllerAdminIncreasesVotingFee {

    uint256 public newSubsidyPct;

    function setUp() public virtual override {
        super.setUp();

        uint256 currentSubsidyPct = paymentsController.getVerifierSubsidyPercentage(10 ether);
        newSubsidyPct = currentSubsidyPct + 100;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateVerifierSubsidyPercentages(10 ether, newSubsidyPct);
    }
}

contract StateT16_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage_Test is StateT16_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage {

    function testCan_PaymentsControllerAdmin_UpdateVerifierSubsidyPercentages() public {
        assertEq(paymentsController.getVerifierSubsidyPercentage(10 ether), newSubsidyPct, "Verifier subsidy percentage not updated correctly");    
    }

    // check that deductBalance books the correct amount of subsidy when subsidy percentage is increased
    function testCan_DeductBalance_WhenVerifierSubsidyPercentageIsIncreased() public {
        // Note: verifier1 has 10 MOCA staked (tier1) which now gives 11% subsidy instead of 10%
        // verifier1 has 100 USD8 deposited, schemaId1 fee is 10 USD8, poolId1 associated
        
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Cache initial subsidy states
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier1_Id);
        
        // Prepare deductBalance call
        uint128 amount = issuer1IncreasedSchemaFee; // 10 USD8
        uint256 expiry = block.timestamp + 1000;
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, getVerifierNonce(verifier1NewSigner));

        // Verify subsidy percentage is 11% for 10 MOCA stake
        assertEq(paymentsController.getVerifierSubsidyPercentage(10 ether), 1100, "Subsidy should be 11%");
        
        // Calculate expected subsidy with new 11% rate
        uint256 expectedSubsidy = (amount * 1100) / Constants.PRECISION_BASE;

        // Expect events
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier1_Id, poolId1, schemaId1, expectedSubsidy);
        
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount);

        // Execute deductBalance
        vm.prank(verifier1NewSigner);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);

        // Verify subsidies increased with new percentage
        assertEq(paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1), poolSubsidiesBefore + expectedSubsidy, "Pool subsidies not booked correctly");
        assertEq(paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier1_Id), verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies not booked correctly");
        
        // Verify fees distributed correctly (protocol 6%, voting 11%, net 83%)
        uint256 expectedProtocolFee = (amount * 600) / Constants.PRECISION_BASE;  // 6%
        uint256 expectedVotingFee = (amount * 1100) / Constants.PRECISION_BASE;   // 11%
        
        DataTypes.FeesAccrued memory epochFees = paymentsController.getEpochFeesAccrued(currentEpoch);
        DataTypes.FeesAccrued memory poolFees = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId1);
        
        // Verify fees accumulated (these would be cumulative from previous tests)
        assertGe(epochFees.feesAccruedToProtocol, expectedProtocolFee, "Protocol fees should include this transaction");
        assertGe(epochFees.feesAccruedToVoters, expectedVotingFee, "Voting fees should include this transaction");
        assertGe(poolFees.feesAccruedToProtocol, expectedProtocolFee, "Pool protocol fees should include this transaction");
        assertGe(poolFees.feesAccruedToVoters, expectedVotingFee, "Pool voting fees should include this transaction");
    }

    // test verifier with non-tier MOCA amount receives no subsidy
    function testCan_DeductBalance_WhenVerifierStakedMocaNotInAnyTier() public {
        // Create new verifier4 with 15 MOCA staked (not in any tier)
        address verifier4 = makeAddr("verifier4");
        address verifier4Asset = makeAddr("verifier4Asset");
        address verifier4Signer;
        uint256 verifier4SignerPrivateKey;
        (verifier4Signer, verifier4SignerPrivateKey) = makeAddrAndKey("verifier4Signer");
        
        // Mint tokens to verifier4Asset
        mockUSD8.mint(verifier4Asset, 100 * 1e6);
        mockMoca.mint(verifier4Asset, 100 ether);
        
        // Create verifier4 - fix parameter order: (signerAddress, assetAddress)
        vm.prank(verifier4);
        bytes32 verifier4_Id = paymentsController.createVerifier(verifier4Signer, verifier4Asset);
        
        // Stake 15 MOCA (between tier1=10 and tier2=20, so no subsidy)
        uint128 nonTierMocaAmount = 15 ether;
        vm.startPrank(verifier4Asset);
            mockMoca.approve(address(paymentsController), nonTierMocaAmount);
            paymentsController.stakeMoca(verifier4_Id, nonTierMocaAmount);
            // Deposit USD8 for verification payments
            mockUSD8.approve(address(paymentsController), 50 * 1e6);
            paymentsController.deposit(verifier4_Id, 50 * 1e6);
        vm.stopPrank();
        
        // Verify no subsidy percentage for this amount
        uint256 subsidyPct = paymentsController.getVerifierSubsidyPercentage(nonTierMocaAmount);
        assertEq(subsidyPct, 0, "Subsidy percentage should be 0 for non-tier amount");
        
        // Record initial states
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier4_Id);
        assertEq(verifierSubsidiesBefore, 0, "Verifier should have no subsidies initially");
        
        // Prepare deductBalance - MUST use issuer1IncreasedSchemaFee (20 USD8) not issuer1SchemaFee
        uint128 amount = issuer1IncreasedSchemaFee; // 20 USD8 - changed from issuer1SchemaFee
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier4Signer);
        bytes memory signature = generateDeductBalanceSignature(verifier4SignerPrivateKey, issuer1_Id, verifier4_Id, schemaId1, amount, expiry, nonce);
        
        // Note: SubsidyBooked event should NOT be emitted since subsidy is 0
        
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier4_Id, schemaId1, issuer1_Id, amount);
        
        vm.expectEmit(true, false, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);
        
        // Execute deductBalance
        vm.prank(verifier4Signer);
        paymentsController.deductBalance(issuer1_Id, verifier4_Id, schemaId1, amount, expiry, signature);
        
        // Verify no subsidies were booked
        uint256 poolSubsidiesAfter = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        assertEq(poolSubsidiesAfter, poolSubsidiesBefore, "Pool subsidies should not change for non-tier verifier");
        
        uint256 verifierSubsidiesAfter = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier4_Id);
        assertEq(verifierSubsidiesAfter, 0, "Verifier should receive no subsidies for non-tier stake");
        
        // Verify fees are still distributed correctly
        DataTypes.Verifier memory verifier4Data = paymentsController.getVerifier(verifier4_Id);
        assertEq(verifier4Data.currentBalance, 50 * 1e6 - amount, "Verifier USD8 balance should be reduced by amount");
        assertEq(verifier4Data.totalExpenditure, amount, "Verifier expenditure should equal amount");
        assertEq(verifier4Data.mocaStaked, nonTierMocaAmount, "MOCA staked should remain unchanged");
    }

    // ------- negative tests for updateVerifierSubsidyPercentages() ----------
    
        function testCannot_NonAdmin_UpdateVerifierSubsidyPercentages() public {
            uint256 mocaAmount = 15 ether;
            uint256 attemptedSubsidyPct = 1500; // 15%
            
            vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin.selector);
            vm.prank(verifier1);
            paymentsController.updateVerifierSubsidyPercentages(mocaAmount, attemptedSubsidyPct);
            
            // Verify subsidy percentage remains unchanged for new tier
            assertEq(paymentsController.getVerifierSubsidyPercentage(mocaAmount), 0, "Subsidy percentage should remain 0 for unapproved tier");
        }
        
        function testCannot_UpdateVerifierSubsidyPercentage_WhenExceedsMax() public {
            uint256 mocaAmount = 40 ether;
            uint256 exceedingMaxSubsidy = Constants.PRECISION_BASE + 1; // 100.01%
            
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierSubsidyPercentages(mocaAmount, exceedingMaxSubsidy);
            
            // Verify subsidy percentage remains unchanged
            assertEq(paymentsController.getVerifierSubsidyPercentage(mocaAmount), 0, "Subsidy percentage should remain 0");
        }
        
        function testCan_UpdateVerifierSubsidyPercentage_ToZero() public {
            // Test that admin can set subsidy to 0 (remove a tier)
            uint256 mocaAmount = 10 ether;
            
            // Verify current subsidy is non-zero
            assertGt(paymentsController.getVerifierSubsidyPercentage(mocaAmount), 0, "Subsidy should be non-zero initially");
            
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierStakingTierUpdated(mocaAmount, 0);
            
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierSubsidyPercentages(mocaAmount, 0);
            
            // Verify subsidy is now 0
            assertEq(paymentsController.getVerifierSubsidyPercentage(mocaAmount), 0, "Subsidy percentage should be 0");
        }
    
    // ------- state transition: updateFeeIncreaseDelayPeriod() ---------
    
        function testCan_PaymentsControllerAdmin_UpdateFeeIncreaseDelayPeriod() public {
            uint256 newDelayPeriod = 28 days;
            
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.FeeIncreaseDelayPeriodUpdated(newDelayPeriod);
            
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }
}

abstract contract StateT17_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod is StateT16_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage {

    uint256 public newDelayPeriod;

    function setUp() public virtual override {
        super.setUp();

        newDelayPeriod = 28 days;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
    }
}

contract StateT17_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod_Test is StateT17_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod {

    function testCan_PaymentsControllerAdmin_UpdateFeeIncreaseDelayPeriod() public {
        assertEq(paymentsController.FEE_INCREASE_DELAY_PERIOD(), newDelayPeriod, "Fee increase delay period not updated correctly");
    }

    function testCan_IssuerIncreaseFee_AfterNewDelayPeriod() public {
        uint128 issuer1IncreasedSchemaFeeV2 = issuer1IncreasedSchemaFee * 2;

        //record schema state before
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        assertEq(schemaBefore.nextFee, 0, "Next fee should be 0");
        assertEq(schemaBefore.nextFeeTimestamp, 0, "Next fee timestamp should be 0");
        assertEq(schemaBefore.currentFee, issuer1IncreasedSchemaFee, "Current fee should be increased");

        //issuer1 increases fees
        vm.prank(issuer1_newAdminAddress);
        paymentsController.updateSchemaFee(issuer1_Id, schemaId1, issuer1IncreasedSchemaFeeV2);

        //check that the fee is increased
        assertEq(paymentsController.getSchema(schemaId1).currentFee, issuer1IncreasedSchemaFee, "Current fee unchanged");
        assertEq(paymentsController.getSchema(schemaId1).nextFee, issuer1IncreasedSchemaFeeV2, "Next fee should be increased");
        assertEq(paymentsController.getSchema(schemaId1).nextFeeTimestamp, block.timestamp + newDelayPeriod, "Next fee timestamp should be increased");
    }

    // ------- negative tests: updateFeeIncreaseDelayPeriod() ---------

        function testCannot_NonAdmin_UpdateFeeIncreaseDelayPeriod() public {
            uint256 newDelayPeriod = 28 days;
            
            vm.expectRevert(Errors.OnlyCallableByPaymentsControllerAdmin.selector);
            vm.prank(verifier1);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }

        function testCannot_UpdateFeeIncreaseDelayPeriod_WhenZero() public {
            uint256 newDelayPeriod = 0;
            
            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }

        function testCannot_UpdateFeeIncreaseWithNonEpochPeriod() public {
            uint256 newDelayPeriod = 27 days;
            
            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }

}

abstract contract StateT18_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay is StateT17_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod {

    uint128 public issuer1IncreasedSchemaFeeV2;
    uint128 public newNextFeeTimestamp;

    function setUp() public virtual override {
        super.setUp();

        issuer1IncreasedSchemaFeeV2 = issuer1IncreasedSchemaFee * 2;

        //issuer1 increases fees
        vm.prank(issuer1_newAdminAddress);
        paymentsController.updateSchemaFee(issuer1_Id, schemaId1, issuer1IncreasedSchemaFeeV2);
        
        newNextFeeTimestamp = uint128(block.timestamp + newDelayPeriod);

        vm.warp(newNextFeeTimestamp);
    }
}

contract StateT18_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay_Test is StateT18_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay {

    function testCan_Schema1_StorageState_AfterNewDelayPeriodAndFeeIncrease_BeforeDeductBalance() public {
        //record schema state - the new fee should not be active yet, as deductBalance has not been called
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        assertEq(schemaBefore.currentFee, issuer1IncreasedSchemaFee, "Current fee unchanged");
        assertEq(schemaBefore.nextFee, issuer1IncreasedSchemaFeeV2, "Next fee should be increased");
        assertEq(schemaBefore.nextFeeTimestamp, newNextFeeTimestamp, "Next fee timestamp should be increased");
    }

    function testCan_DeductBalanceForSchema1_AfterNewDelayPeriodAndFeeIncrease() public {
        //record schema state - the new fee should now be active after the delay period
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        assertEq(schemaBefore.currentFee, issuer1IncreasedSchemaFee, "Current fee should be updated to new fee");
        assertEq(schemaBefore.nextFee, issuer1IncreasedSchemaFeeV2, "Next fee should be cleared");
        assertEq(schemaBefore.nextFeeTimestamp, newNextFeeTimestamp, "Next fee timestamp should be cleared");
        
        // Record verifier balance before
        uint128 verifierBalanceBefore = paymentsController.getVerifier(verifier1_Id).currentBalance;
        // Record issuer's accumulated fees before
        uint256 issuerNetFeesAccruedBefore = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;

        // Record epoch fees before
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;
        
        // Generate signature with the new fee amount
        uint128 amount = issuer1IncreasedSchemaFeeV2;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1_Id, verifier1_Id, schemaId1, amount, expiry, nonce);  
            
        // Expect SchemaFeeIncreased event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeIncreased(schemaId1, issuer1IncreasedSchemaFee, issuer1IncreasedSchemaFeeV2);

        // Expect BalanceDeducted event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1_Id, schemaId1, issuer1_Id, amount);
        
        // Expect SchemaVerified event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);
        
        // Execute deductBalance with new fee
        vm.prank(verifier1NewSigner);
        paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
        
        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 issuerFee = amount - protocolFee - votingFee;
        
        // Verify verifier balance decreased by new fee amount
        uint128 verifierBalanceAfter = paymentsController.getVerifier(verifier1_Id).currentBalance;
        assertEq(verifierBalanceAfter, verifierBalanceBefore - amount, "Verifier balance not decreased correctly");
        
        // Verify fee splits
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not accrued correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voting fees not accrued correctly");
        
        // Verify issuer balance increased
        assertEq(paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued, issuerNetFeesAccruedBefore + issuerFee, "Issuer balance not increased correctly");
        
        // Verify schema fee has been updated after deductBalance
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.totalVerified, 3, "Schema totalVerified not incremented");
        assertEq(schemaAfter.currentFee, issuer1IncreasedSchemaFeeV2, "Current fee should be updated after deductBalance");
        assertEq(schemaAfter.nextFee, 0, "Next fee should be cleared after update");
        assertEq(schemaAfter.nextFeeTimestamp, 0, "Next fee timestamp should be cleared after update");
    }

    // state transition
    function testCannot_PaymentsControllerAdmin_WithdrawProtocolFees_NoTreasuryAddressSet() public {

        uint256 protocolFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToProtocol;
        assertTrue(protocolFees > 0, "Protocol fees should be greater than 0");

        // Move to next epoch (required for withdrawal)
        skip(14 days);

        vm.expectRevert(Errors.InvalidAddress.selector);

        // Execute deduction
        vm.prank(assetManager);
        paymentsController.withdrawProtocolFees(0);
    }

    function testCannot_PaymentsControllerAdmin_WithdrawVotersFees_NoTreasuryAddressSet() public {

        uint256 votersFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToVoters;
        assertTrue(votersFees > 0, "Voters fees should be greater than 0");

        // Move to next epoch (required for withdrawal)
        skip(14 days);

        vm.expectRevert(Errors.InvalidAddress.selector);

        // Execute deduction
        vm.prank(assetManager);
        paymentsController.withdrawVotersFees(0);
    }

}


// set treasury address, test admin withdraw functions
abstract contract StateT19_PaymentsControllerAdminWithdrawsProtocolFees is StateT18_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay {

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(globalAdmin);
            addressBook.setAddress(addressBook.TREASURY(), treasury);
        vm.stopPrank();

    }
}

contract StateT19_PaymentsControllerAdminWithdrawsProtocolFees_Test is StateT19_PaymentsControllerAdminWithdrawsProtocolFees {
    
    function testCan_PaymentsControllerAdmin_WithdrawProtocolFees() public {
        // before
        uint256 protocolFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToProtocol;
        assertTrue(protocolFees > 0, "Protocol fees should be greater than 0");
        assertEq(mockUSD8.balanceOf(treasury), 0, "treasury has 0 USD8");
        assertEq(paymentsController.getEpochFeesAccrued(0).isProtocolFeeWithdrawn, false, "Protocol fees should not be withdrawn");

        // Check TOTAL_PROTOCOL_FEES_UNCLAIMED before
        uint256 beforeTotalProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
        assertTrue(beforeTotalProtocolFeesUnclaimed >= protocolFees, "TOTAL_PROTOCOL_FEES_UNCLAIMED should be >= protocolFees");

        // Expect event emission
        vm.expectEmit(true, true, true, true);
        emit Events.ProtocolFeesWithdrawn(0, protocolFees);

        vm.prank(assetManager);
        paymentsController.withdrawProtocolFees(0);

        assertEq(paymentsController.getEpochFeesAccrued(0).feesAccruedToProtocol, protocolFees, "Protocol fees should be non-zero");
        assertEq(paymentsController.getEpochFeesAccrued(0).isProtocolFeeWithdrawn, true, "Protocol fees should be withdrawn");

        assertEq(mockUSD8.balanceOf(treasury), protocolFees, "Protocol fees should be transferred to treasury");

        // Check TOTAL_PROTOCOL_FEES_UNCLAIMED after
        uint256 afterTotalProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
        assertEq(afterTotalProtocolFeesUnclaimed, beforeTotalProtocolFeesUnclaimed - protocolFees, "TOTAL_PROTOCOL_FEES_UNCLAIMED should decrease by protocolFees");
    }

    function testCan_PaymentsControllerAdmin_WithdrawVotersFees() public {
        // before
        uint256 votersFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToVoters;
        assertTrue(votersFees > 0, "Voters fees should be greater than 0");
        assertEq(mockUSD8.balanceOf(treasury), 0, "treasury has 0 USD8");
        assertEq(paymentsController.getEpochFeesAccrued(0).isVotersFeeWithdrawn, false, "Voters fees should not be withdrawn");

        // Check TOTAL_VOTING_FEES_UNCLAIMED before
        uint256 beforeTotalVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();
        assertTrue(beforeTotalVotingFeesUnclaimed >= votersFees, "TOTAL_VOTING_FEES_UNCLAIMED should be >= votersFees");

        // Expect event emission
        vm.expectEmit(true, true, true, true);
        emit Events.VotersFeesWithdrawn(0, votersFees);

        vm.prank(assetManager);
        paymentsController.withdrawVotersFees(0);

        assertEq(paymentsController.getEpochFeesAccrued(0).feesAccruedToVoters, votersFees, "Voters fees should be non-zero");
        assertEq(paymentsController.getEpochFeesAccrued(0).isVotersFeeWithdrawn, true, "Voters fees should be withdrawn");

        assertEq(mockUSD8.balanceOf(treasury), votersFees, "Voters fees should be transferred to treasury");

        // Check TOTAL_VOTING_FEES_UNCLAIMED after
        uint256 afterTotalVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();
        assertEq(afterTotalVotingFeesUnclaimed, beforeTotalVotingFeesUnclaimed - votersFees, "TOTAL_VOTING_FEES_UNCLAIMED should decrease by votersFees");
    }

    // ------ negative tests: withdrawProtocolFees -------

        // withdrawing for future epoch
        function testCannot_PaymentsControllerAdmin_WithdrawProtocolFees_InvalidEpoch() public {
            
            vm.expectRevert(Errors.InvalidEpoch.selector);
            vm.prank(assetManager);
            paymentsController.withdrawProtocolFees(10);
        }

        function testCannot_PaymentsControllerAdmin_WithdrawProtocolFees_AlreadyWithdrawn() public {
            testCan_PaymentsControllerAdmin_WithdrawProtocolFees();

            vm.expectRevert(Errors.ProtocolFeeAlreadyWithdrawn.selector);
            vm.prank(assetManager);
            paymentsController.withdrawProtocolFees(0);
        }

        function testCannot_PaymentsControllerAdmin_WithdrawProtocolFees_ZeroProtocolFees() public {
            vm.expectRevert(Errors.ZeroProtocolFee.selector);
            vm.prank(assetManager);
            paymentsController.withdrawProtocolFees(EpochMath.getCurrentEpochNumber() - 1);
        }

    // ------ negative tests: withdrawVotersFees -------

        // withdrawing for future epoch
        function testCannot_PaymentsControllerAdmin_WithdrawVotersFees_InvalidEpoch() public {
            
            vm.expectRevert(Errors.InvalidEpoch.selector);
            vm.prank(assetManager);
            paymentsController.withdrawVotersFees(10);
        }

        function testCannot_PaymentsControllerAdmin_WithdrawVotersFees_AlreadyWithdrawn() public {
            testCan_PaymentsControllerAdmin_WithdrawVotersFees();

            vm.expectRevert(Errors.VotersFeeAlreadyWithdrawn.selector);
            vm.prank(assetManager);
            paymentsController.withdrawVotersFees(0);
        }

        function testCannot_PaymentsControllerAdmin_WithdrawVotersFees_ZeroVotersFees() public {
            vm.expectRevert(Errors.ZeroVotersFee.selector);
            vm.prank(assetManager);
            paymentsController.withdrawVotersFees(EpochMath.getCurrentEpochNumber() - 1);
        }


    
    // ----- state transition: pause -------

        function testCannot_ArbitraryAddressCannotPauseContract() public {
            vm.expectRevert(Errors.OnlyCallableByMonitor.selector);
            vm.prank(verifier1);
            paymentsController.pause();
        }

        function testCan_MonitorPauseContract() public {
            assertFalse(paymentsController.paused(), "Contract should NOT be paused");

            vm.prank(monitor);
            paymentsController.pause();

            assertTrue(paymentsController.paused(), "Contract should be paused");
        }
}

abstract contract StateT20_PaymentsControllerAdminFreezesContract is StateT19_PaymentsControllerAdminWithdrawsProtocolFees {

    function setUp() public virtual override {
        super.setUp();

        vm.prank(monitor);
        paymentsController.pause();
    }
}

contract StateT20_PaymentsControllerAdminFreezesContract_Test is StateT20_PaymentsControllerAdminFreezesContract {

    // ------ Contract paused: no fns can be called except: unpause or freeze -------
        
        // ------ Issuer functions ------
            function test_createIssuer_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1);
                paymentsController.createIssuer(issuer1Asset);
            }

            function test_createSchema_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1);
                paymentsController.createSchema(issuer1_Id, 100 * 1e6);
            }

            function test_updateSchemaFee_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1);
                paymentsController.updateSchemaFee(issuer1_Id, schemaId1, 200 * 1e6);
            }

            function test_claimFees_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1Asset);
                paymentsController.claimFees(issuer1_Id);
            }

        // ------ Verifier functions ------
            function test_createVerifier_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1);
                paymentsController.createVerifier(verifier1Signer, verifier1Asset);
            }

            function test_deposit_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.deposit(verifier1_Id, 100 * 1e6);
            }

            function test_withdraw_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.withdraw(verifier1_Id, 50 * 1e6);
            }

            function test_updateSignerAddress_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1);
                paymentsController.updateSignerAddress(verifier1_Id, makeAddr("newSigner"));
            }

            function test_stakeMoca_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.stakeMoca(verifier1_Id, 10 ether);
            }

            function test_unstakeMoca_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.unstakeMoca(verifier1_Id, 5 ether);
            }

        // ------ Common functions for issuer and verifier ------
            function test_updateAssetAddress_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1);
                paymentsController.updateAssetAddress(issuer1_Id, makeAddr("newAsset"));
            }

            function test_updateAdminAddress_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1);
                paymentsController.updateAdminAddress(issuer1_Id, makeAddr("newAdmin"));
            }

        // ------ UniversalVerificationContract functions ------
            function test_deductBalance_revertsWhenPaused() public {
                // Generate a valid signature
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

                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Signer);
                paymentsController.deductBalance(issuer1_Id, verifier1_Id, schemaId1, amount, expiry, signature);
            }

            function test_deductBalanceZeroFee_revertsWhenPaused() public {
                // Generate a valid signature
                uint256 expiry = block.timestamp + 1000;
                uint256 nonce = getVerifierNonce(verifier1Signer);
                bytes memory signature = generateDeductBalanceZeroFeeSignature(
                    verifier1SignerPrivateKey,
                    issuer1_Id,
                    verifier1_Id,
                    schemaId3, // assuming schemaId3 has zero fee
                    expiry,
                    nonce
                );

                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Signer);
                paymentsController.deductBalanceZeroFee(issuer1_Id, verifier1_Id, schemaId3, expiry, signature);
            }

        // ---- Admin update functions ----
            function test_updatePoolId_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updatePoolId(schemaId1, bytes32("pool1"));
            }

            function test_updateFeeIncreaseDelayPeriod_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updateFeeIncreaseDelayPeriod(28 days);
            }

            function test_updateProtocolFeePercentage_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updateProtocolFeePercentage(600); // 6%
            }

            function test_updateVotingFeePercentage_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updateVotingFeePercentage(1100); // 11%
            }

            function test_updateVerifierSubsidyPercentages_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updateVerifierSubsidyPercentages(40 ether, 4000);
            }

        // ---- Admin withdraw functions ----
            function test_withdrawProtocolFees_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(assetManager);
                paymentsController.withdrawProtocolFees(0);
            }

            function test_withdrawVotersFees_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(assetManager);
                paymentsController.withdrawVotersFees(0);
            }

            // ---- The pause function itself should also revert when called if already paused ----
            function test_pause_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(monitor);
                paymentsController.pause();
            }
        
        // ------ EmergencyExit functions: requires frozen to be called ------

            function test_emergencyExitVerifiers_revertsWhenPaused() public {
                vm.expectRevert(Errors.NotFrozen.selector);
                vm.prank(emergencyExitHandler);
                paymentsController.emergencyExitVerifiers(new bytes32[](1));
            }

            function test_emergencyExitIssuers_revertsWhenPaused() public {
                vm.expectRevert(Errors.NotFrozen.selector);
                vm.prank(emergencyExitHandler);
                paymentsController.emergencyExitIssuers(new bytes32[](1));
            }


    // ------ Functions that should NOT revert when paused -------

        // View functions should still work when paused
        function test_viewFunctions_workWhenPaused() public view {
            // These should not revert
            paymentsController.getIssuer(issuer1_Id);
            paymentsController.getSchema(schemaId1);
            paymentsController.getVerifier(verifier1_Id);
            paymentsController.getVerifierNonce(verifier1Signer);
            paymentsController.getVerifierSubsidyPercentage(10 ether);
            paymentsController.getEpochPoolSubsidies(0, bytes32("pool1"));
            paymentsController.getEpochPoolVerifierSubsidies(0, bytes32("pool1"), verifier1_Id);
            paymentsController.getEpochPoolFeesAccrued(0, bytes32("pool1"));
            paymentsController.getEpochFeesAccrued(0);
            
            // Also check immutable/state variables can be read
            paymentsController.addressBook();
            paymentsController.PROTOCOL_FEE_PERCENTAGE();
            paymentsController.VOTING_FEE_PERCENTAGE();
            paymentsController.FEE_INCREASE_DELAY_PERIOD();
            paymentsController.TOTAL_CLAIMED_VERIFICATION_FEES();
            paymentsController.TOTAL_MOCA_STAKED();
            paymentsController.isFrozen();
            paymentsController.paused();
        }

        // can unpause
        function testCan_unpause_WhenPaused() public {
            // Check contract is paused
            assertTrue(paymentsController.paused(), "Contract should be paused");

            // Unpause should work
            vm.prank(globalAdmin);
            paymentsController.unpause();

            // Check contract is unpaused
            assertFalse(paymentsController.paused(), "Contract should be unpaused");
        }


    // ------ State transition: freeze ------

        function testCan_freeze_WhenPaused() public {
            // Check contract is paused but not frozen
            assertTrue(paymentsController.paused(), "Contract should be paused");
            assertEq(paymentsController.isFrozen(), 0, "Contract should not be frozen");

            // Expect freeze event
            vm.expectEmit(true, true, true, true);
            emit Events.ContractFrozen();

            // Freeze should work when paused
            vm.prank(globalAdmin);
            paymentsController.freeze();

            // Check contract is frozen
            assertEq(paymentsController.isFrozen(), 1, "Contract should be frozen");
        }
}

abstract contract StateT21_PaymentsControllerAdminFreezesContract is StateT20_PaymentsControllerAdminFreezesContract {

    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        paymentsController.freeze();
    }
}

contract StateT21_PaymentsControllerAdminFreezesContract_Test is StateT21_PaymentsControllerAdminFreezesContract {
    
    // ------ Contract frozen: no fns can be called except: emergencyExit -------
        
        function testCannot_GlobalAdmin_Unpause() public {
            vm.expectRevert(Errors.IsFrozen.selector);
            vm.prank(globalAdmin);
            paymentsController.unpause();
        }

    // ------ emergencyExitVerifiers ------

        function testCannot_ArbitraryAddressCall_EmergencyExitVerifiers() public {
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler.selector);
            vm.prank(verifier1);
            paymentsController.emergencyExitVerifiers(new bytes32[](1));
        }

        function testCannot_EmergencyExitHandlerCall_EmergencyExitVerifiers_InvalidArray() public {
            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(new bytes32[](0));
        }

        //Note: invalid ids get skipped, but are emitted in the event
        function testCan_EmergencyExitHandlerCall_EmergencyExitVerifiers_InvalidVerifierId() public {
            // Provide a verifierId that is not registered (e.g., random bytes32)
            bytes32 invalidVerifierId = keccak256("invalidVerifierId");
            bytes32[] memory verifierIds = new bytes32[](1);
            verifierIds[0] = invalidVerifierId;

            // Record contract's token balance before
            uint256 beforeUSD8Balance = mockUSD8.balanceOf(address(paymentsController));
            uint256 beforeMocaBalance = mockMoca.balanceOf(address(paymentsController));

            // Expect the EmergencyExitVerifiers event to be emitted with the invalid verifierId
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitVerifiers(verifierIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(verifierIds);

            // Record contract's token balance after
            uint256 afterUSD8Balance = mockUSD8.balanceOf(address(paymentsController));
            uint256 afterMocaBalance = mockMoca.balanceOf(address(paymentsController));

            // Assert that no tokens were transferred
            assertEq(afterUSD8Balance, beforeUSD8Balance, "No tokens should be transferred for invalid verifierId");
            assertEq(afterMocaBalance, beforeMocaBalance, "No tokens should be transferred for invalid verifierId");
        }

        function testCannot_EmergencyExitVerifiers_ValidVerifierId_ButZeroBalance() public {
            testCan_EmergencyExitHandler_EmergencyExitVerifiers();
            
            // Prepare the verifierIds array
            bytes32[] memory verifierIds = new bytes32[](3);
            verifierIds[0] = verifier1_Id;
            verifierIds[1] = verifier2_Id;
            verifierIds[2] = verifier3_Id;

            // Record balances before
            uint256 beforeBalance = mockUSD8.balanceOf(address(paymentsController));

            // Expect the EmergencyExitVerifiers event to be emitted even if balance is zero
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitVerifiers(verifierIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(verifierIds);

            // Record balances after
            uint256 afterBalance = mockUSD8.balanceOf(address(paymentsController));

            // Assert that no tokens were transferred
            assertEq(afterBalance, beforeBalance, "No tokens should be transferred for zero balance");
        }

        function testCan_EmergencyExitHandler_EmergencyExitVerifiers() public {
            // Prepare verifierIds array with verifier1, verifier2, verifier3
            bytes32[] memory verifierIds = new bytes32[](3);
            verifierIds[0] = verifier1_Id;
            verifierIds[1] = verifier2_Id;
            verifierIds[2] = verifier3_Id;

            // Get current asset addresses from the contract (they may have been updated)
            address currentAsset1 = paymentsController.getVerifier(verifier1_Id).assetAddress;
            address currentAsset2 = paymentsController.getVerifier(verifier2_Id).assetAddress;
            address currentAsset3 = paymentsController.getVerifier(verifier3_Id).assetAddress;

            // Record pre-exit contract balances for each verifier
            uint256 beforeVerifier1ContractBalance = paymentsController.getVerifier(verifier1_Id).currentBalance;
            uint256 beforeVerifier2ContractBalance = paymentsController.getVerifier(verifier2_Id).currentBalance;
            uint256 beforeVerifier3ContractBalance = paymentsController.getVerifier(verifier3_Id).currentBalance;

            // Record pre-exit USD8 balances for each verifier
            uint256 beforeVerifier1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 beforeVerifier2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 beforeVerifier3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Record pre-exit MOCA staked for each verifier
            uint256 beforeVerifier1MocaStaked = paymentsController.getVerifier(verifier1_Id).mocaStaked;
            uint256 beforeVerifier2MocaStaked = paymentsController.getVerifier(verifier2_Id).mocaStaked;
            uint256 beforeVerifier3MocaStaked = paymentsController.getVerifier(verifier3_Id).mocaStaked;

            // Record pre-exit MOCA balances for each verifier
            uint256 beforeVerifier1MOCABalance = mockMoca.balanceOf(currentAsset1);
            uint256 beforeVerifier2MOCABalance = mockMoca.balanceOf(currentAsset2);
            uint256 beforeVerifier3MOCABalance = mockMoca.balanceOf(currentAsset3);

            // Expect the EmergencyExitVerifiers event to be emitted
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitVerifiers(verifierIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(verifierIds);

            // Record post-exit contract balances for each verifier
            uint256 afterVerifier1ContractBalance = paymentsController.getVerifier(verifier1_Id).currentBalance;
            uint256 afterVerifier2ContractBalance = paymentsController.getVerifier(verifier2_Id).currentBalance;
            uint256 afterVerifier3ContractBalance = paymentsController.getVerifier(verifier3_Id).currentBalance;

            // Record post-exit USD8 balances for each verifier
            uint256 afterVerifier1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 afterVerifier2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 afterVerifier3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Record post-exit Moca balances for each verifier
            uint256 afterVerifier1MOCABalance = mockMoca.balanceOf(currentAsset1);
            uint256 afterVerifier2MOCABalance = mockMoca.balanceOf(currentAsset2);
            uint256 afterVerifier3MOCABalance = mockMoca.balanceOf(currentAsset3);

            // Check that contract-state balances for verifiers are now zero
            assertEq(afterVerifier1ContractBalance, 0, "verifier1 contract-state USD8_balance should be zero after emergency exit");
            assertEq(afterVerifier2ContractBalance, 0, "verifier2 contract-state USD8_balance should be zero after emergency exit");
            assertEq(afterVerifier3ContractBalance, 0, "verifier3 contract-state USD8_balance should be zero after emergency exit");
            assertEq(afterVerifier1ContractBalance, 0, "verifier1 contract-state Moca_staked should be zero after emergency exit");
            assertEq(afterVerifier2ContractBalance, 0, "verifier2 contract-state Moca_staked should be zero after emergency exit");
            assertEq(afterVerifier3ContractBalance, 0, "verifier3 contract-state Moca_staked should be zero after emergency exit");

            // Check that USD8 balances were transferred from contract to verifiers
            assertEq(afterVerifier1USD8Balance, beforeVerifier1USD8Balance + beforeVerifier1ContractBalance, "verifier1Asset should receive all contract-state USD8_balance tokens");
            assertEq(afterVerifier2USD8Balance, beforeVerifier2USD8Balance + beforeVerifier2ContractBalance, "verifier2Asset should receive all contract-state USD8_balance tokens");
            assertEq(afterVerifier3USD8Balance, beforeVerifier3USD8Balance + beforeVerifier3ContractBalance, "verifier3Asset should receive all contract-state USD8_balance tokens");
            
            // Check that Moca balances were transferred from contract to verifiers
            assertEq(afterVerifier1MOCABalance, beforeVerifier1MocaStaked + beforeVerifier1MOCABalance, "verifier1Asset should receive all contract-state Moca_staked tokens");
            assertEq(afterVerifier2MOCABalance, beforeVerifier2MocaStaked + beforeVerifier2MOCABalance, "verifier2Asset should receive all contract-state Moca_staked tokens");
            assertEq(afterVerifier3MOCABalance, beforeVerifier3MocaStaked + beforeVerifier3MOCABalance, "verifier3Asset should receive all contract-state Moca_staked tokens");
        }

    // ------ emergencyExitIssuers ------

        function testCannot_ArbitraryAddressCall_EmergencyExitIssuers() public {
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler.selector);
            vm.prank(issuer1);
            paymentsController.emergencyExitIssuers(new bytes32[](1));
        }

        function testCannot_EmergencyExitHandlerCall_EmergencyExitIssuers_InvalidArray() public {
            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(new bytes32[](0));
        }

        //Note: invalid ids get skipped, but are emitted in the event
        function testCan_EmergencyExitHandlerCall_EmergencyExitIssuers_InvalidIssuerId() public {
            // Provide an issuerId that is not registered (e.g., random bytes32)
            bytes32 invalidIssuerId = keccak256("invalidIssuerId");
            bytes32[] memory issuerIds = new bytes32[](1);
            issuerIds[0] = invalidIssuerId;

            // Record contract's token balance before
            uint256 beforeUSD8Balance = mockUSD8.balanceOf(address(paymentsController));

            // Expect the EmergencyExitIssuers event to be emitted with the invalid issuerId
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitIssuers(issuerIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(issuerIds);

            // Record contract's token balance after
            uint256 afterUSD8Balance = mockUSD8.balanceOf(address(paymentsController));

            // Assert that no tokens were transferred
            assertEq(afterUSD8Balance, beforeUSD8Balance, "No tokens should be transferred for invalid issuerId");
        }

        function testCannot_EmergencyExitIssuers_ValidIssuerId_ButZeroUnclaimedBalance() public {
            // First run emergency exit to ensure issuers have zero unclaimed balance
            testCan_EmergencyExitHandler_EmergencyExitIssuers();
            
            // Prepare the issuerIds array
            bytes32[] memory issuerIds = new bytes32[](3);
            issuerIds[0] = issuer1_Id;
            issuerIds[1] = issuer2_Id;
            issuerIds[2] = issuer3_Id;

            // Record balances before
            uint256 beforeBalance = mockUSD8.balanceOf(address(paymentsController));

            // Expect the EmergencyExitIssuers event to be emitted even if balance is zero
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitIssuers(issuerIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(issuerIds);

            // Record balances after
            uint256 afterBalance = mockUSD8.balanceOf(address(paymentsController));

            // Assert that no tokens were transferred
            assertEq(afterBalance, beforeBalance, "No tokens should be transferred for zero unclaimed balance");
        }

        function testCan_EmergencyExitHandler_EmergencyExitIssuers() public {
            // Prepare issuerIds array with issuer1, issuer2, issuer3
            bytes32[] memory issuerIds = new bytes32[](3);
            issuerIds[0] = issuer1_Id;
            issuerIds[1] = issuer2_Id;
            issuerIds[2] = issuer3_Id;

            // Get current asset addresses from the contract (they may have been updated)
            address currentAsset1 = paymentsController.getIssuer(issuer1_Id).assetAddress;
            address currentAsset2 = paymentsController.getIssuer(issuer2_Id).assetAddress;
            address currentAsset3 = paymentsController.getIssuer(issuer3_Id).assetAddress;

            // Record pre-exit unclaimed fees for each issuer
            uint256 beforeIssuer1UnclaimedFees = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer1_Id).totalClaimed;
            uint256 beforeIssuer2UnclaimedFees = paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer2_Id).totalClaimed;
            uint256 beforeIssuer3UnclaimedFees = paymentsController.getIssuer(issuer3_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer3_Id).totalClaimed;

            // Record pre-exit USD8 balances for each issuer asset address
            uint256 beforeIssuer1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 beforeIssuer2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 beforeIssuer3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Record pre-exit totalClaimed for each issuer
            uint256 beforeIssuer1TotalClaimed = paymentsController.getIssuer(issuer1_Id).totalClaimed;
            uint256 beforeIssuer2TotalClaimed = paymentsController.getIssuer(issuer2_Id).totalClaimed;
            uint256 beforeIssuer3TotalClaimed = paymentsController.getIssuer(issuer3_Id).totalClaimed;

            // Record totalNetFeesAccrued for verification after
            uint256 issuer1TotalNetFeesAccrued = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued;
            uint256 issuer2TotalNetFeesAccrued = paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued;
            uint256 issuer3TotalNetFeesAccrued = paymentsController.getIssuer(issuer3_Id).totalNetFeesAccrued;

            // Expect the EmergencyExitIssuers event to be emitted
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitIssuers(issuerIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(issuerIds);

            // Record post-exit totalClaimed for each issuer
            uint256 afterIssuer1TotalClaimed = paymentsController.getIssuer(issuer1_Id).totalClaimed;
            uint256 afterIssuer2TotalClaimed = paymentsController.getIssuer(issuer2_Id).totalClaimed;
            uint256 afterIssuer3TotalClaimed = paymentsController.getIssuer(issuer3_Id).totalClaimed;

            // Record post-exit USD8 balances for each issuer
            uint256 afterIssuer1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 afterIssuer2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 afterIssuer3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Check that totalClaimed now equals totalNetFeesAccrued for each issuer
            assertEq(afterIssuer1TotalClaimed, issuer1TotalNetFeesAccrued, "issuer1 totalClaimed should equal totalNetFeesAccrued after emergency exit");
            assertEq(afterIssuer2TotalClaimed, issuer2TotalNetFeesAccrued, "issuer2 totalClaimed should equal totalNetFeesAccrued after emergency exit");
            assertEq(afterIssuer3TotalClaimed, issuer3TotalNetFeesAccrued, "issuer3 totalClaimed should equal totalNetFeesAccrued after emergency exit");

            // Check that USD8 balances were transferred from contract to issuers
            assertEq(afterIssuer1USD8Balance, beforeIssuer1USD8Balance + beforeIssuer1UnclaimedFees, "issuer1Asset should receive all unclaimed fees");
            assertEq(afterIssuer2USD8Balance, beforeIssuer2USD8Balance + beforeIssuer2UnclaimedFees, "issuer2Asset should receive all unclaimed fees");
            assertEq(afterIssuer3USD8Balance, beforeIssuer3USD8Balance + beforeIssuer3UnclaimedFees, "issuer3Asset should receive all unclaimed fees");
            
            // Verify unclaimed balances are now zero
            uint256 afterIssuer1UnclaimedFees = paymentsController.getIssuer(issuer1_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer1_Id).totalClaimed;
            uint256 afterIssuer2UnclaimedFees = paymentsController.getIssuer(issuer2_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer2_Id).totalClaimed;
            uint256 afterIssuer3UnclaimedFees = paymentsController.getIssuer(issuer3_Id).totalNetFeesAccrued - paymentsController.getIssuer(issuer3_Id).totalClaimed;
            
            assertEq(afterIssuer1UnclaimedFees, 0, "issuer1 should have zero unclaimed fees after emergency exit");
            assertEq(afterIssuer2UnclaimedFees, 0, "issuer2 should have zero unclaimed fees after emergency exit");
            assertEq(afterIssuer3UnclaimedFees, 0, "issuer3 should have zero unclaimed fees after emergency exit");
        }

    // ------ emergencyExitFees ------

        function testCannot_ArbitraryAddressCall_EmergencyExitFees() public {
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler.selector);
            vm.prank(assetManager);
            paymentsController.emergencyExitFees();
        }

        function testCannot_EmergencyExitHandlerCall_EmergencyExitFees_NoFeesToClaim() public {
            // First ensure all fees have been claimed
            testCan_EmergencyExitHandler_EmergencyExitFees();
            
            // Try to call emergencyExitFees again when no fees remain
            vm.expectRevert(Errors.NoFeesToClaim.selector);
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitFees();
        }

        function testCan_EmergencyExitHandler_EmergencyExitFees() public {
            // Get treasury address
            address treasuryAddress = addressBook.getTreasury();
            require(treasuryAddress != address(0), "Treasury address should not be zero");

            // Record pre-exit unclaimed fees
            uint256 beforeProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
            uint256 beforeVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();
            uint256 totalUnclaimedFees = beforeProtocolFeesUnclaimed + beforeVotingFeesUnclaimed;
            
            // Ensure there are fees to claim (from previous state transitions)
            assertGt(totalUnclaimedFees, 0, "Should have unclaimed fees from previous transactions");

            // Record pre-exit treasury balance
            uint256 beforeTreasuryBalance = mockUSD8.balanceOf(treasuryAddress);

            // Record contract balance before
            uint256 beforeContractBalance = mockUSD8.balanceOf(address(paymentsController));

            // Expect the EmergencyExitFees event to be emitted
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitFees(treasuryAddress, totalUnclaimedFees);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitFees();

            // Record post-exit unclaimed fees
            uint256 afterProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
            uint256 afterVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();

            // Record post-exit treasury balance
            uint256 afterTreasuryBalance = mockUSD8.balanceOf(treasuryAddress);

            // Record contract balance after
            uint256 afterContractBalance = mockUSD8.balanceOf(address(paymentsController));

            // Check that unclaimed fee counters are now zero
            assertEq(afterProtocolFeesUnclaimed, 0, "TOTAL_PROTOCOL_FEES_UNCLAIMED should be zero after emergency exit");
            assertEq(afterVotingFeesUnclaimed, 0, "TOTAL_VOTING_FEES_UNCLAIMED should be zero after emergency exit");

            // Check that treasury received the fees
            assertEq(afterTreasuryBalance, beforeTreasuryBalance + totalUnclaimedFees, "Treasury should receive all unclaimed fees");

            // Check that contract balance decreased by the transferred amount
            assertEq(afterContractBalance, beforeContractBalance - totalUnclaimedFees, "Contract balance should decrease by totalUnclaimedFees");
        }

}

