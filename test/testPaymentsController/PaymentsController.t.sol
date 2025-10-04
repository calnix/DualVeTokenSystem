// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "../utils/TestingHarness.sol";

abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}

contract StateT0_DeployTest is StateT0_Deploy {
    
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


    function test_CreateIssuer_RevertsWhenAssetAddressIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(issuer1);
        paymentsController.createIssuer(address(0));
    }

    function test_CreateIssuer_EmitsEventAndReturnsCorrectId() public {
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

    function test_CreateVerifier_RevertsWhenAssetAddressIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(verifier1);
        paymentsController.createVerifier(verifier1Signer, address(0));
    }

    function test_CreateVerifier_EmitsEventAndReturnsCorrectId() public {
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

abstract contract StateT1_CreateIssuerAndVerifier is StateT0_Deploy {

    bytes32 public issuerId = PaymentsController_generateId(block.number, issuer1, issuer1Asset);
    bytes32 public verifierId = PaymentsController_generateId(block.number, verifier1, verifier1Asset);

    function setUp() public virtual override {
        super.setUp();

        vm.prank(issuer1);
        paymentsController.createIssuer(issuer1Asset);

        vm.prank(verifier1);
        paymentsController.createVerifier(verifier1Signer, verifier1Asset);
    }
}

contract StateT1_CreateIssuerAndVerifierTest is StateT1_CreateIssuerAndVerifier {

    function test_CreateSchema_RevertsWhenCallerIsNotIssuerAdmin() public {
        uint128 fee = 1000;

        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the issuer admin
        paymentsController.createSchema(issuerId, fee);
    }


    function test_CreateSchema_RevertsWhenFeeTooLarge() public {
        // Use max uint128 as an obviously too large fee
        uint128 tooLargeFee = type(uint128).max; 

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(issuer1);
        paymentsController.createSchema(issuerId, tooLargeFee);
    }


    function test_CreateSchema_EmitsEventAndReturnsCorrectId() public {
        uint128 fee = 1000;
        bytes32 expectedSchemaId = PaymentsController_generateSchemaId(block.number, issuerId);

        // Expect the SchemaCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaCreated(expectedSchemaId, issuerId, fee);

        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(issuerId, fee);

        // Assert
        assertEq(schemaId, expectedSchemaId, "schemaId not set correctly");
        
        // Verify schema storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(expectedSchemaId);

        assertEq(schema.schemaId, expectedSchemaId, "Schema ID not stored correctly");
        assertEq(schema.issuerId, issuerId, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, fee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }


}