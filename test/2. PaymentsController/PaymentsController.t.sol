// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

import "../utils/TestingHarness.sol";

// note: deploy
abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}

contract StateT0_DeployAndCreateSubsidyTiers_Test is StateT0_Deploy {
    
    function test_Deploy() public view {
        // Check all initialized addresses
        assertEq(address(paymentsController.USD8()), address(mockUSD8), "USD8 not set correctly");
        assertEq(address(paymentsController.WMOCA()), address(mockWMoca), "WMoca not set correctly");

        // Check MOCA_TRANSFER_GAS_LIMIT has been set correctly
        assertEq(paymentsController.MOCA_TRANSFER_GAS_LIMIT(), MOCA_TRANSFER_GAS_LIMIT, "MOCA_TRANSFER_GAS_LIMIT not set correctly");

        // Check protocol and voting fee parameters
        assertEq(paymentsController.PROTOCOL_FEE_PERCENTAGE(), protocolFeePercentage, "PROTOCOL_FEE_PERCENTAGE not set correctly");
        assertEq(paymentsController.VOTING_FEE_PERCENTAGE(), voterFeePercentage, "VOTING_FEE_PERCENTAGE not set correctly");

        // Check delay period for fee increase
        assertEq(paymentsController.FEE_INCREASE_DELAY_PERIOD(), feeIncreaseDelayPeriod, "FEE_INCREASE_DELAY_PERIOD not set correctly");
        // Check default verifier unstake delay period
        assertEq(paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD(), 1 days, "VERIFIER_UNSTAKE_DELAY_PERIOD not set correctly");

        // Confirm the name and version if constructor arguments are visible
        //assertEq(paymentsController.name(), "PaymentsController", "Name not set correctly");
        //assertEq(paymentsController.version(), "1", "Version not set correctly");

        // Check treasury address is set
        assertEq(paymentsController.PAYMENTS_CONTROLLER_TREASURY(), paymentsControllerTreasury, "Treasury not set correctly");

        // Roles sanity: default admin
        assertTrue(paymentsController.hasRole(paymentsController.DEFAULT_ADMIN_ROLE(), globalAdmin), "global admin not set");
        assertTrue(paymentsController.hasRole(paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin), "payments controller admin not set");
        assertTrue(paymentsController.hasRole(paymentsController.MONITOR_ADMIN_ROLE(), monitorAdmin), "monitor admin not set");
        assertTrue(paymentsController.hasRole(paymentsController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin), "cron job admin not set");
        assertTrue(paymentsController.hasRole(paymentsController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler), "emergency exit handler not set");
        assertTrue(paymentsController.hasRole(paymentsController.MONITOR_ROLE(), monitor), "monitor bot not set");
    }

    function testRevert_Deploy_GlobalAdminIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            address(0), paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_PaymentsControllerAdminIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, address(0), monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_MonitorAdminIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, address(0), cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_CronJobAdminIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, address(0), monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_MonitorBotIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, address(0),
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_TreasuryIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            address(0), emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_EmergencyExitHandlerIsZero() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, address(0),
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_WMOCAIsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(0), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_USD8IsZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(0), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_MOCA_TRANSFER_GAS_LIMITIsLessThan2300() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), 2300 - 1, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_ProtocolFeePercentageIsGreaterThan100Pct() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            Constants.PRECISION_BASE + 1, voterFeePercentage, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_VoterFeePercentageIsGreaterThan100Pct() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, Constants.PRECISION_BASE + 1, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_SumFeePercentagesIs100Pct() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            Constants.PRECISION_BASE, Constants.PRECISION_BASE, feeIncreaseDelayPeriod,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_FeeIncreaseDelayPeriodIsZero() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, 0,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_FeeIncreaseDelayPeriodIsLessThanEpochDuration() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, EpochMath.EPOCH_DURATION - 1,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }

    function testRevert_Deploy_FeeIncreaseDelayPeriod_IsNotEpochAligned() public {
        // Only valid epoch times allowed
        uint128 notEpochAligned = (EpochMath.EPOCH_DURATION * 2) + 1;
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new PaymentsController(
            globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitor,
            paymentsControllerTreasury, emergencyExitHandler,
            protocolFeePercentage, voterFeePercentage, notEpochAligned,
            address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1"
        );
    }


    // ---------- state transition: subsidy tiers ----------

    function testCannot_SetSubsidyTiers_WhenCallerIsNotPaymentsControllerAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xdeadbeef), paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
        vm.prank(address(0xdeadbeef)); // not the payments controller admin
        paymentsController.setVerifierSubsidyTiers(new uint128[](0), new uint128[](0));
    }


    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenEmptyArray() public {
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.setVerifierSubsidyTiers(new uint128[](0), new uint128[](0));
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenLengthGreaterThan10() public {
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](11);
        uint128[] memory subsidies = new uint128[](11);
        for (uint256 i = 0; i < 11; ++i) {
            mocaStaked[i] = uint128(1 + i);
            subsidies[i] = uint128(10 + i);
        }
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenLengthsMismatch() public {
        vm.expectRevert(Errors.MismatchedArrayLengths.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](2);
        uint128[] memory subsidies = new uint128[](1);
        mocaStaked[0] = 1;
        mocaStaked[1] = 2;
        subsidies[0] = 10;
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenMocaStakedIsZero() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](1);
        uint128[] memory subsidies = new uint128[](1);
        mocaStaked[0] = 0;
        subsidies[0] = 1000;
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenSubsidyPercentageIsZero() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](1);
        uint128[] memory subsidies = new uint128[](1);
        mocaStaked[0] = 10 ether;
        subsidies[0] = 0;
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenSubsidyPercentageIsGreaterThan100Pct() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](1);
        uint128[] memory subsidies = new uint128[](1);
        mocaStaked[0] = 10 ether;
        subsidies[0] = uint128(Constants.PRECISION_BASE + 1);
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenNotAscendingMocaStaked() public {
        vm.expectRevert(Errors.InvalidMocaStakedTierOrder.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](2);
        uint128[] memory subsidies = new uint128[](2);
        mocaStaked[0] = 20 ether;
        mocaStaked[1] = 10 ether; // not ascending
        subsidies[0] = 1000;
        subsidies[1] = 2000;
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCannot_PaymentsControllerAdmin_SetSubsidyTiers_WhenNotAscendingSubsidyPercentages() public {
        vm.expectRevert(Errors.InvalidSubsidyPercentageTierOrder.selector);
        vm.prank(paymentsControllerAdmin);
        uint128[] memory mocaStaked = new uint128[](2);
        uint128[] memory subsidies = new uint128[](2);
        mocaStaked[0] = 10 ether;
        mocaStaked[1] = 20 ether;
        subsidies[0] = 2000;
        subsidies[1] = 1000; // not ascending
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }

    function testCan_PaymentsControllerAdmin_SetSubsidyTiers() public {
        vm.startPrank(paymentsControllerAdmin);

        uint128[] memory mocaStaked = new uint128[](3);
        uint128[] memory subsidies = new uint128[](3);

        mocaStaked[0] = 10 ether;
        subsidies[0] = 1000;
        mocaStaked[1] = 20 ether;
        subsidies[1] = 2000;
        mocaStaked[2] = 30 ether;
        subsidies[2] = 3000;

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierStakingTiersSet(mocaStaked, subsidies);

        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);

        vm.stopPrank();

        // Check subsidy tiers: should match input tier setup
        DataTypes.SubsidyTier[10] memory subsidyTiers = paymentsController.getAllSubsidyTiers();
        assertEq(subsidyTiers[0].mocaStaked, 10 ether, "10 ether moca staked not set correctly");
        assertEq(subsidyTiers[0].subsidyPercentage, 1000, "1000 subsidy percentage not set correctly");
        assertEq(subsidyTiers[1].mocaStaked, 20 ether, "20 ether moca staked not set correctly");
        assertEq(subsidyTiers[1].subsidyPercentage, 2000, "2000 subsidy percentage not set correctly");
        assertEq(subsidyTiers[2].mocaStaked, 30 ether, "30 ether moca staked not set correctly");
        assertEq(subsidyTiers[2].subsidyPercentage, 3000, "3000 subsidy percentage not set correctly"); 

        // Querying a value between tiers should return the highest <= tier
        assertEq(paymentsController.getEligibleSubsidyPercentage(25 ether), 2000, "25 ether should match second tier's subsidy");
        assertEq(paymentsController.getEligibleSubsidyPercentage(5 ether), 0, "smaller than any tier should be zero");
    }

    function testCan_PaymentsControllerAdmin_ClearSubsidyTiers() public {
        // Set first
        vm.startPrank(paymentsControllerAdmin);

        uint128[] memory mocaStaked = new uint128[](2);
        uint128[] memory subsidies = new uint128[](2);
        mocaStaked[0] = 10 ether;
        subsidies[0] = 1000;
        mocaStaked[1] = 20 ether;
        subsidies[1] = 2000;

        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);

        vm.expectEmit(false, false, false, true, address(paymentsController));
        emit Events.VerifierStakingTiersCleared();

        paymentsController.clearVerifierSubsidyTiers();

        vm.stopPrank();

        // All subsidy percent queries should be 0 after clear
        DataTypes.SubsidyTier[10] memory subsidyTiers = paymentsController.getAllSubsidyTiers();
        
        assertEq(subsidyTiers[0].subsidyPercentage, 0, "After clear, should return zero");
        assertEq(subsidyTiers[0].mocaStaked, 0, "After clear, should return zero");

        assertEq(subsidyTiers[1].subsidyPercentage, 0, "After clear, should return zero");
        assertEq(subsidyTiers[1].mocaStaked, 0, "After clear, should return zero");

        assertEq(subsidyTiers[2].subsidyPercentage, 0, "After clear, should return zero");
        assertEq(subsidyTiers[2].mocaStaked, 0, "After clear, should return zero");

    }
}

// note: subsidy tiers created
abstract contract StateT1_SubsidyTiersCreated is StateT0_Deploy {

    function setUp() public virtual override {
        super.setUp();

        // subsidy tiers
        uint128[] memory mocaStaked = new uint128[](3);
        uint128[] memory subsidies = new uint128[](3);

        mocaStaked[0] = 10 ether;
        subsidies[0] = 1000;
        mocaStaked[1] = 20 ether;
        subsidies[1] = 2000;
        mocaStaked[2] = 30 ether;
        subsidies[2] = 3000;

        // Create subsidy tiers for verifiers
        vm.startPrank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        vm.stopPrank();
    }
}

// test: create issuers and verifiers
contract StateT1_SubsidyTiersCreated_Test is StateT1_SubsidyTiersCreated {
    
    // ---- issuer fns ----
        function testCannot_CreateIssuer_WhenAssetAddressIsZeroAddress() public {
            vm.expectRevert(Errors.InvalidAddress.selector);
            vm.prank(issuer1);
            paymentsController.createIssuer(address(0));
        }

        function testCan_CreateIssuer() public {
        
            // Expect the IssuerCreated event to be emitted with correct parameters
            vm.expectEmit(true, false, false, false, address(paymentsController));
            emit Events.IssuerCreated(issuer1, issuer1Asset);

            vm.prank(issuer1);
            paymentsController.createIssuer(issuer1Asset);
            
            // Check storage state of issuer1
            DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);

            assertEq(issuer.assetManagerAddress, issuer1Asset, "assetManagerAddress mismatch");
            assertEq(issuer.totalVerified, 0, "totalVerified should be 0");
            assertEq(issuer.totalNetFeesAccrued, 0, "totalNetFeesAccrued should be 0");
            assertEq(issuer.totalClaimed, 0, "totalClaimed should be 0");
            assertEq(issuer.totalSchemas, 0, "totalSchemas should be 0");
        }
        
        function testRevert_SameAdminAddress_CannotCreateMultipleIssuerIds() public {
            testCan_CreateIssuer();

            vm.expectRevert(Errors.IssuerAlreadyExists.selector);
            vm.prank(issuer1);
            paymentsController.createIssuer(issuer1Asset);
        }


    // ---- verifier fns ----
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

            // Expect the VerifierCreated event to be emitted with correct parameters
            vm.expectEmit(true, false, false, false, address(paymentsController));
            emit Events.VerifierCreated(verifier1, verifier1Signer, verifier1Asset);

            vm.prank(verifier1);
            paymentsController.createVerifier(verifier1Signer, verifier1Asset);

            // Check storage state of verifier1
            DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);

            assertEq(verifier.signerAddress, verifier1Signer, "signerAddress mismatch");
            assertEq(verifier.assetManagerAddress, verifier1Asset, "assetManagerAddress mismatch");
            assertEq(verifier.currentBalance, 0, "currentBalance should be 0");
            assertEq(verifier.totalExpenditure, 0, "totalExpenditure should be 0");
            assertEq(verifier.mocaStaked, 0, "mocaStaked should be 0");
        }

        function testRevert_SameAdminAddress_CannotCreateMultipleVerifierIds() public {
            testCan_CreateVerifier();

            vm.expectRevert(Errors.VerifierAlreadyExists.selector);
            vm.prank(verifier1);
            paymentsController.createVerifier(verifier1Signer, verifier1Asset);
        }
}

// note: create issuers and verifiers
abstract contract StateT1_CreateIssuerVerifiers is StateT1_SubsidyTiersCreated {

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
    using stdStorage for StdStorage;

    function testRevert_CreateSchema_IssuerDoesNotExist() public {
        uint128 fee = 1000;

        vm.expectRevert(Errors.IssuerDoesNotExist.selector);
        vm.prank(address(0xdeadbeef)); // not the issuer admin
        paymentsController.createSchema(fee);
    }

    function testRevert_CreateSchema_FeeTooLarge() public {
        // Use max uint128 as an obviously too large fee
        uint128 tooLargeFee = type(uint128).max; 

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(issuer1);
        paymentsController.createSchema(tooLargeFee);
    }


    function testCan_CreateSchema() public {
        uint128 fee = 1000;

        uint256 preNonce = paymentsController.getIssuerSchemaNonce(issuer1);
        uint256 totalSchemas = paymentsController.getIssuer(issuer1).totalSchemas;
        assertEq(preNonce, 0, "issuer1 nonce should init at 0");
        assertEq(totalSchemas, 0, "totalSchemas should be 0");

        // expects deterministic schema id
        bytes32 expectedSchemaId = keccak256(abi.encode("SCHEMA", issuer1, totalSchemas, preNonce));

        // event check
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaCreated(expectedSchemaId, issuer1, fee);

        vm.prank(issuer1);
        bytes32 schemaId = paymentsController.createSchema(fee);

        // Check returned id matches calculated deterministic id
        assertEq(schemaId, expectedSchemaId, "schemaId not set correctly");
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId);

        // validate struct fields per implementation
        assertEq(schema.issuer, issuer1, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, fee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
        assertEq(schema.totalVerified, 0, "totalVerified should be 0");
        assertEq(schema.totalGrossFeesAccrued, 0, "totalGrossFeesAccrued should be 0");
        assertEq(schema.poolId, uint128(0), "poolId should be 0");

        // totalSchemas incremented for issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
        assertEq(issuer.totalSchemas, 1, "totalSchemas should be 1");

        // nonce should increment for issuer
        uint256 postNonce = paymentsController.getIssuerSchemaNonce(issuer1);
        assertEq(postNonce, preNonce + 1, "issuer schema nonce should have incremented");
    }
}


abstract contract StateT2_CreateSchemas is StateT1_CreateIssuerVerifiers {

    bytes32 public schemaId1;
    bytes32 public schemaId2;
    bytes32 public schemaId3;

    uint128 public issuer1SchemaFee = 10 * 1e6;  // 10 USD8 (6 decimals) instead of 1 ether
    uint128 public issuer2SchemaFee = 20 * 1e6;  // 20 USD8 (6 decimals) instead of 2 ether
    uint128 public issuer3SchemaFeeIsZero = 0;  

    function setUp() public virtual override {
        super.setUp();

        vm.prank(issuer1);
        schemaId1 = paymentsController.createSchema(issuer1SchemaFee);

        vm.prank(issuer2);
        schemaId2 = paymentsController.createSchema(issuer2SchemaFee);

        vm.prank(issuer3);
        schemaId3 = paymentsController.createSchema(issuer3SchemaFeeIsZero);
    }
}

contract StateT2_CreateSchemas_Test is StateT2_CreateSchemas {

    function test_VerifyCreatedSchemas() public view {
        // verify issuer storage state: totalSchemas should be 1
        assertEq(paymentsController.getIssuer(issuer1).totalSchemas, 1, "totalSchemas should be 1");
        assertEq(paymentsController.getIssuer(issuer2).totalSchemas, 1, "totalSchemas should be 1");
        assertEq(paymentsController.getIssuer(issuer3).totalSchemas, 1, "totalSchemas should be 1");
    }

    function testSchema1_StorageState() public view {
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
     
        assertEq(schema.issuer, issuer1, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, issuer1SchemaFee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }

    function testSchema2_StorageState() public view {
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId2);
        assertEq(schema.issuer, issuer2, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, issuer2SchemaFee, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }
    
    function testSchema3_StorageState() public view {
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId3);
        assertEq(schema.issuer, issuer3, "Issuer ID not stored correctly");
        assertEq(schema.currentFee, issuer3SchemaFeeIsZero, "Current fee not stored correctly");
        assertEq(schema.nextFee, 0, "Next fee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Next fee timestamp should be 0 for new schema");
    }


    // state transition: verifier deposits USD8 for payment
    function testCan_Verifier1DepositUSD8() public {
        uint128 amount = 100 * 1e6;

        // Record balances before deposit
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance before deposit
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;


        // Perform deposit
        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), amount); 

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierDeposited(verifier1, verifier1Asset, amount);

        paymentsController.deposit(verifier1, amount);
        vm.stopPrank();

        // Record balances after deposit
        uint256 contractBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceAfter = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance after deposit
        uint256 verifierCurrentBalanceAfter = paymentsController.getVerifier(verifier1).currentBalance;

        // Check storage: deposited amount should be reflected
        assertEq(verifierCurrentBalanceBefore, 0, "Verifier balance should be zero before deposit");
        assertEq(verifierCurrentBalanceAfter, amount, "Verifier balance not updated correctly after deposit");

        // Check token balances
        assertEq(contractBalanceAfter, contractBalanceBefore + amount, "Contract balance not increased correctly");
        assertEq(verifierBalanceAfter, verifierBalanceBefore - amount, "Verifier balance not decreased correctly");
    }
    
}


// note: verifier1 deposits USD8
abstract contract StateT3_Verifier1DepositUSD8 is StateT2_CreateSchemas {

    function setUp() public virtual override {
        super.setUp();

        // Perform deposit: verifier1
        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), 100 * 1e6);
        paymentsController.deposit(verifier1, 100 * 1e6);
        vm.stopPrank();
    }
}


contract StateT3_Verifier1DepositUSD8_Test is StateT3_Verifier1DepositUSD8 {
    
    function testRevert_Verifier1DepositUSD8_CallerIsNotVerifierAssetAddress() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(address(0xdeadbeef)); // not the verifier asset address
        paymentsController.deposit(verifier1, 1000 * 1e6);
    }

    function test_VerifierWithdrawUSD8_CallerIsVerifierAssetAddress() public {
        uint128 withdrawAmount = 100 * 1e6;

        // Record balances before withdrawal
        uint256 contractBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceBefore = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance before withdrawal
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifier1, verifier1Asset, withdrawAmount);

        // Perform withdrawal
        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifier1, withdrawAmount);

        // Record balances after withdrawal
        uint256 contractBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        uint256 verifierBalanceAfter = mockUSD8.balanceOf(verifier1Asset);

        // Record verifier's currentBalance after withdrawal
        uint256 verifierCurrentBalanceAfter = paymentsController.getVerifier(verifier1).currentBalance;

        // Check storage: withdrawn amount should be reflected
        assertEq(verifierCurrentBalanceAfter, verifierCurrentBalanceBefore - withdrawAmount, "Verifier balance not updated correctly after withdrawal");

        // Check token balances
        assertEq(contractBalanceAfter, contractBalanceBefore - withdrawAmount, "Contract balance not decreased correctly");
        assertEq(verifierBalanceAfter, verifierBalanceBefore + withdrawAmount, "Verifier balance not increased correctly");
    }

    //------- state transition: deductBalance() -----------

        function testCannot_DeductBalance_WhenExpiryIsInThePast() public {
            vm.expectRevert(Errors.SignatureExpired.selector);
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, schemaId1, issuer1SchemaFee, block.timestamp, "");
        }

        function testCannot_DeductBalance_WhenAmountIsZero() public {
            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, schemaId1, 0, block.timestamp + 1000, "");
        }
        
        function testCannot_DeductBalance_WhenSchemaDoesNotBelongToIssuer() public {
            vm.expectRevert(Errors.InvalidSchema.selector);
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, bytes32(0), issuer1SchemaFee, block.timestamp + 1000, "");
        }
    
        function testCannot_DeductBalance_InvalidSignature() public {
            vm.expectRevert(Errors.InvalidSignature.selector);
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, schemaId1, issuer1SchemaFee, block.timestamp + 1000, "");
        }

        function testCannot_DeductBalance_WhenAmountDoesNotMatchSchemaFee() public {
            // Generate a valid signature for deductBalance
            uint128 amount = issuer1SchemaFee + 1000 * 1e6;
            uint256 expiry = block.timestamp + 1000;
            uint256 nonce = getVerifierNonce(verifier1Signer, user1);
            bytes memory signature = generateDeductBalanceSignature(
                verifier1SignerPrivateKey,
                issuer1,
                verifier1,
                schemaId1,
                user1,
                amount,
                expiry,
                nonce
            );
            vm.expectRevert(Errors.InvalidSchemaFee.selector);
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
        }

        // Use verifier2 which has no deposit
        function testCannot_DeductBalance_WhenVerifierHasNoDeposit() public {
            // Generate a valid signature for deductBalance using verifier2 which has no deposit
            uint128 amount = issuer1SchemaFee;
            uint256 expiry = block.timestamp + 1000;
            uint256 nonce = getVerifierNonce(verifier2Signer, user1);
            bytes memory signature = generateDeductBalanceSignature(
                verifier2SignerPrivateKey,
                issuer1,
                verifier2,  // Use verifier2
                schemaId1,
                user1,
                amount,
                expiry,
                nonce
            );

            // Call deductBalance as the verifier2's signer address, which has no deposit
            vm.expectRevert(Errors.InsufficientBalance.selector);
            
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(
                verifier2,  // Use verifier2
                user1,
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
            uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;

            // Record issuer's totalNetFeesAccrued before deduction
            uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
            assertEq(issuerTotalNetFeesAccruedBefore, 0, "Issuer totalNetFeesAccrued should be zero before deduction");
            // Record issuer's totalVerified before deduction
            uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1).totalVerified;
            assertEq(issuerTotalVerifiedBefore, 0, "Issuer totalVerified should be zero before deduction");

            // Record schema's totalGrossFeesAccrued before deduction
            uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
            assertEq(schemaTotalGrossFeesAccruedBefore, 0, "Schema totalGrossFeesAccrued should be zero before deduction");
            // Record schema's totalVerified before deduction
            uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;
            assertEq(schemaTotalVerifiedBefore, 0, "Schema totalVerified should be zero before deduction");

            uint128 amount = issuer1SchemaFee;
            uint256 expiry = block.timestamp + 1000;
            uint256 nonce = getVerifierNonce(verifier1Signer, user1);
            bytes memory signature = generateDeductBalanceSignature(
                verifier1SignerPrivateKey,
                issuer1,
                verifier1,
                schemaId1,
                user1,
                amount,
                expiry,
                nonce
            );

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount);

            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.SchemaVerified(schemaId1);

            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);

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
            DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
            assertEq(issuer.totalNetFeesAccrued, netFee, "Issuer totalNetFeesAccrued not updated correctly");
            assertEq(issuer.totalVerified, 1, "Issuer totalVerified not updated correctly");

            // Check storage state: verifier
            DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
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

        function testCan_DeductBalance_AppliesPendingFeeIncrease() public {
            uint128 amount = issuer1SchemaFee + 1 * 1e6;
            // Setup schema with pending fee increase
            vm.prank(issuer1);
            paymentsController.updateSchemaFee(schemaId1, amount);
            
            // Fast forward past the delay period
            vm.warp(block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD() + 1);

            // Generate signature for the increased fee
            uint256 expiry = block.timestamp + 1000;
            uint256 nonce = getVerifierNonce(verifier1Signer, user1);
            bytes memory signature = generateDeductBalanceSignature(
                verifier1SignerPrivateKey,
                issuer1,
                verifier1,
                schemaId1,
                user1,
                amount,
                expiry,
                nonce
            );

            // Call deductBalance with the correct signature and increased fee
            vm.prank(verifier1Asset);
            paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
        }
}


// note: verifier1 deducts balance
abstract contract StateT4_DeductBalanceExecuted is StateT3_Verifier1DepositUSD8 {


    function setUp() public virtual override {
        super.setUp();

        // Perform deduction: verifier1
        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1Signer, user1);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1SignerPrivateKey,
            issuer1,
            verifier1,
            schemaId1,
            user1,
            amount,
            expiry,
            nonce
        );

        vm.startPrank(verifier1Asset);
        mockUSD8.approve(address(paymentsController), amount);
        vm.stopPrank();

        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
    }
}

contract StateT4_DeductBalanceExecuted_Test is StateT4_DeductBalanceExecuted {
   
    // state transition: verifier changes signer address
    function testCan_Verifier1UpdateSignerAddress_WhenNewSignerAddressIsDifferentFromCurrentOne() public {
        (address verifier1NewSigner, uint256 verifier1NewSignerPrivateKey) = makeAddrAndKey("verifier1NewSigner");

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierSignerAddressUpdated(verifier1, verifier1NewSigner);
       
        vm.prank(verifier1);
        paymentsController.updateSignerAddress(verifier1NewSigner);
    }

}

// note: verifier1 changes signer address
abstract contract StateT5_VerifierChangesSignerAddress is StateT4_DeductBalanceExecuted {

    address public verifier1NewSigner;
    uint256 public verifier1NewSignerPrivateKey;
    
    function setUp() public virtual override {
        super.setUp();

        (verifier1NewSigner, verifier1NewSignerPrivateKey) = makeAddrAndKey("verifier1NewSigner");

        vm.prank(verifier1);
        paymentsController.updateSignerAddress(verifier1NewSigner);
    }
}

// deductBalance should work w/ new signer address
contract StateT5_VerifierChangesSignerAddress_Test is StateT5_VerifierChangesSignerAddress {

    function testCan_Verifier1DeductBalance_WhenNewSignerAddressIsDifferentFromCurrentOne() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;

        // Record epoch fees before deduction
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer1SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        bytes memory signature = generateDeductBalanceSignature(
            verifier1NewSignerPrivateKey,
            issuer1,
            verifier1,
            schemaId1,
            user1,
            amount,
            expiry,
            nonce
        );

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount); 

        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);

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
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
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
        paymentsController.updateSchemaFee(schemaId1, newFee);

        // Check schema state after
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.currentFee, newFee, "Schema currentFee not updated correctly");
        assertEq(schemaAfter.nextFee, 0, "Schema nextFee should be 0 after immediate fee reduction");
        assertEq(schemaAfter.nextFeeTimestamp, 0, "Schema nextFeeTimestamp should be 0 after immediate fee reduction");
    }

}

// note: issuer decreases fee
abstract contract StateT6_IssuerDecreasesFee is StateT5_VerifierChangesSignerAddress {

    uint128 public issuer1DecreasedSchemaFee = issuer1SchemaFee / 2;

    function setUp() public virtual override {
        super.setUp();
        
        // Decrease fee
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(schemaId1, issuer1DecreasedSchemaFee);
    }
}

// issuer decreases fee: impact should be instant
contract StateT6_IssuerDecreasesFee_Test is StateT6_IssuerDecreasesFee {

    function testCan_Verifier1DeductBalance_WithDecreasedFee() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;

        // Record epoch fees before deduction
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature: use new verifier1's new signer address
        uint128 amount = issuer1DecreasedSchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, nonce);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount); 
        
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);

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
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
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

        // Expect event emissions: SchemaNextFeeSet, SchemaFeeIncreased
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaNextFeeSet(schemaId1, newFee, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD(), schemaBefore.currentFee);

        vm.prank(issuer1);
        paymentsController.updateSchemaFee(schemaId1, newFee);

        // Check schema state after: nextFee and nextFeeTimestamp updated
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.currentFee, schemaBefore.currentFee, "Schema currentFee should be unchanged");
        assertEq(schemaAfter.nextFee, newFee, "Schema nextFee should be updated correctly");
        assertEq(schemaAfter.nextFeeTimestamp, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD(), "Schema nextFeeTimestamp should be updated correctly");

        console2.log("deductBalance should be operating on currentFee not nextFee");
        // ---- deductBalance should be operating on currentFee not nextFee --------
        console2.log("First, Test: deductBalance should revert on nextFee");

        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        
        // First, try to deduct with the new fee - should revert
        bytes memory signatureNewFee = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, newFee, expiry, nonce);
        
        vm.expectRevert(Errors.InvalidSchemaFee.selector);
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, newFee, expiry, signatureNewFee);
        
        console2.log("Next, Test: deductBalance should be operating on currentFee");
        // Now verify deductBalance succeeds with the current fee
        bytes memory signatureCurrentFee = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, schemaBefore.currentFee, expiry, nonce);
        
        // Record balance before deduction
        uint128 balanceBefore = paymentsController.getVerifier(verifier1).currentBalance;
        
        // Expect successful deduction event
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, schemaBefore.currentFee);
        
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, schemaBefore.currentFee, expiry, signatureCurrentFee);
        
        // Verify balance was deducted with current fee
        uint128 balanceAfter = paymentsController.getVerifier(verifier1).currentBalance;
        assertEq(balanceAfter, balanceBefore - schemaBefore.currentFee, "Balance should be deducted by current fee amount");
        
        // Verify schema still shows nextFee is pending
        DataTypes.Schema memory schemaFinal = paymentsController.getSchema(schemaId1);
        assertEq(schemaFinal.currentFee, schemaBefore.currentFee, "Current fee should remain unchanged");
        assertEq(schemaFinal.nextFee, newFee, "Next fee should still be pending");
        assertEq(schemaFinal.nextFeeTimestamp, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD(), "Next fee timestamp should be unchanged");
    }
}


//note: increase fee, but nextFeeTimestamp not yet passed
abstract contract StateT7_IssuerIncreasedFee_FeeNotYetApplied is StateT6_IssuerDecreasesFee {

    uint128 public issuer1IncreasedSchemaFee = issuer1SchemaFee * 2;

    function setUp() public virtual override {
        super.setUp();
        
        // Increase fee
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(schemaId1, issuer1IncreasedSchemaFee);
    }
}


contract StateT7_IssuerIncreasedFee_FeeNotYetApplied_Test is StateT7_IssuerIncreasedFee_FeeNotYetApplied {

    function testCan_DeductBalanceStillDeductsCurrentFee_NewFeeNotYetApplied() public {
        // Record verifier's state before deduction
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1);
        
        // Record issuer's state before deduction
        DataTypes.Issuer memory issuerBefore = paymentsController.getIssuer(issuer1);
        
        // Record schema's state before deduction
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);

        // Generate signature
        uint128 amount = schemaBefore.currentFee;  // old fee
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, nonce);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount);
        
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);
        
        // deduct
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
        
        // Calculate fee splits using helper
        (uint128 protocolFee, uint128 votingFee, uint128 netFee) = calculateFeeSplits(amount);

        // Record states after
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1);
        DataTypes.Issuer memory issuerAfter = paymentsController.getIssuer(issuer1);
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);

        // Check verifier state: balance should be deducted
        assertEq(verifierAfter.currentBalance, verifierBefore.currentBalance - amount, "Balance should be deducted by current fee amount");
        assertEq(verifierAfter.totalExpenditure, verifierBefore.totalExpenditure + amount, "Verifier totalExpenditure not updated correctly");
        
        // Check issuer state: totalVerified should be incremented
        assertEq(issuerAfter.totalNetFeesAccrued, issuerBefore.totalNetFeesAccrued + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuerAfter.totalVerified, issuerBefore.totalVerified + 1, "Issuer totalVerified not updated correctly");
        assertEq(issuerAfter.totalClaimed, issuerBefore.totalClaimed, "Issuer totalClaimed not updated correctly");
        
        // Check schema state: currentFee should remain unchanged
        assertEq(schemaAfter.totalGrossFeesAccrued, schemaBefore.totalGrossFeesAccrued + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schemaAfter.totalVerified, schemaBefore.totalVerified + 1, "Schema totalVerified not updated correctly");
        assertEq(schemaAfter.currentFee, amount, "Current fee should remain unchanged");
        // nextFee checks
        assertEq(schemaAfter.nextFee, schemaBefore.nextFee, "Next fee should be unchanged");
        assertEq(schemaAfter.nextFeeTimestamp, schemaBefore.nextFeeTimestamp, "Next fee timestamp should be unchanged");
    }

    function testCan_IssuerIncreaseFeeAgain_OverwritesPriorSetNextFeeToLatestSetNextFee() public {
        // Record verifier's state before deduction
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1);
        
        // Record issuer's state before deduction
        DataTypes.Issuer memory issuerBefore = paymentsController.getIssuer(issuer1);
        
        // Record schema's state before deduction
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        assertTrue(schemaBefore.nextFee > 0, "Next fee should be greater than 0");
        assertTrue(schemaBefore.nextFeeTimestamp > 0, "Next fee timestamp should be greater than 0");

        /**note
            in the first increase of fee, the nextFee = issuer1SchemaFee * 2
            it was doubled
            we are doing to increase the fee relative to currentFee, but be lesser than the initial nextFee
            therefore, 2nd newFee = 200 / 110 * currentFee [< nextFee]
         */
        uint128 secondNewFee = schemaBefore.currentFee * 200 / 110; 
        assertTrue(secondNewFee < schemaBefore.nextFee, "2nd newFee should be less than nextFee");
        assertTrue(secondNewFee > schemaBefore.currentFee, "2nd newFee should be greater than currentFee");

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaNextFeeSet(schemaId1, secondNewFee, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD() + 1, schemaBefore.currentFee);
        
        // advance time by 1 second
        vm.warp(block.timestamp + 1);
        
        // Increase fee
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(schemaId1, secondNewFee);

        // Record schema's state after deduction
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.nextFee, secondNewFee, "Next fee should be updated correctly");
        assertEq(schemaAfter.nextFeeTimestamp, block.timestamp + paymentsController.FEE_INCREASE_DELAY_PERIOD(), "Next fee timestamp should be updated correctly");

        // compare nextFees before and after
        assertTrue(schemaAfter.nextFee < schemaBefore.nextFee, "Next fee should be decreased, on overwriting the prior nextFee");
        assertTrue(schemaAfter.nextFeeTimestamp > schemaBefore.nextFeeTimestamp, "Next fee timestamp should be increased");
    }
}


// issuer increased fee: impact should applied now that delay has passed
abstract contract StateT8_IssuerIncreasedFeeIsAppliedAfterDelay is StateT7_IssuerIncreasedFee_FeeNotYetApplied {

    function setUp() public virtual override {
        super.setUp();
        
        DataTypes.Schema memory schema1 = paymentsController.getSchema(schemaId1);

        // warp to nextFeeTimestamp
        vm.warp(schema1.nextFeeTimestamp);
    }
}

contract StateT8_IssuerIncreasedFeeIsAppliedAfterDelay_Test is StateT8_IssuerIncreasedFeeIsAppliedAfterDelay {

    function testCan_Verifier1DeductBalance_WithIncreasedFee() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;
       
        // Record epoch fees before deduction
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer1IncreasedSchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, nonce);
        
        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeIncreased(schemaId1, issuer1DecreasedSchemaFee, issuer1IncreasedSchemaFee);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount); 

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);

        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
        
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
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");
    }

    // state transition: create schema w/ 0 fees
    function testCan_Issuer3CreatesSchemaWith0Fees() public {
        uint128 fee = 0;

        // expected schemaId
        uint256 totalSchemas = paymentsController.getIssuer(issuer3).totalSchemas;
        assertTrue(totalSchemas == 1, "issuer3 totalSchemas should be 1");
        bytes32 expectedSchemaId3 = generateUnusedSchemaId(issuer3);

        // Expect the SchemaCreated event to be emitted with correct parameters
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SchemaCreated(expectedSchemaId3, issuer3, fee);
        
        vm.prank(issuer3);
        bytes32 schemaId = paymentsController.createSchema(fee);
        
        // check schemaId
        assertEq(schemaId, expectedSchemaId3, "schemaId not set correctly");
        
        // Check storage state
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId);
        assertEq(schema.currentFee, fee, "Schema currentFee not updated correctly");
        assertEq(schema.nextFee, 0, "Schema nextFee should be 0 for new schema");
        assertEq(schema.nextFeeTimestamp, 0, "Schema nextFee timestamp should be 0 for new schema");
    }
}


// note: issuer3 creates schema with 0 fees
abstract contract StateT9_Issuer3CreatesSchemaWith0Fees is StateT8_IssuerIncreasedFeeIsAppliedAfterDelay {

    function setUp() public virtual override {
        super.setUp();
        
        // Create schema with 0 fees
        vm.prank(issuer3);
        schemaId3 = paymentsController.createSchema(0);
    }
}

// issuer created schema with 0 fees: impact should be instant
contract StateT9_Issuer3CreatesSchemaWith0Fees_Test is StateT9_Issuer3CreatesSchemaWith0Fees {

    function testCan_Verifier2DeductBalance_With0FeeSchema() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier2).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier2).totalExpenditure;

        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer3).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer3).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId3).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId3).totalVerified;
        
        
        // Record epoch fees before deduction
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;
        
        // Generate signature
        uint128 amount = 0;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer, user1);
        bytes memory signature = generateDeductBalanceZeroFeeSignature(verifier2SignerPrivateKey, issuer3, verifier2, schemaId3, user1, expiry, nonce);

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerifiedZeroFee(schemaId3);

        vm.prank(verifier2Asset);
        paymentsController.deductBalanceZeroFee(verifier2, schemaId3, user1, expiry, signature);

        // Check storage state: verifier (no changes to balance or expenditure)
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier2);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore, "Verifier balance should remain unchanged for zero fee");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore, "Verifier totalExpenditure should remain unchanged for zero fee");

        // Check storage state: issuer (only totalVerified increments)
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer3);
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

    function testCan_DeductBalanceZeroFee_WhenFeeIncreasePendingAndNotEffective() public {
        uint128 scheduledFee = 1_000_000; // 1 USD8 with 6 decimals

        // Schedule a fee increase for the zero-fee schema
        vm.prank(issuer3);
        paymentsController.updateSchemaFee(schemaId3, scheduledFee);

        DataTypes.Schema memory schemaAfterSchedule = paymentsController.getSchema(schemaId3);
        uint256 expectedNextFeeTimestamp = schemaAfterSchedule.nextFeeTimestamp;
        assertGt(expectedNextFeeTimestamp, block.timestamp, "Next fee should be scheduled in the future");
        assertEq(schemaAfterSchedule.currentFee, 0, "Current fee must remain zero until timestamp");

        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer, user1);
        bytes memory signature = generateDeductBalanceZeroFeeSignature(verifier2SignerPrivateKey, issuer3, verifier2, schemaId3, user1, expiry, nonce);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerifiedZeroFee(schemaId3);

        vm.prank(verifier2Asset);
        paymentsController.deductBalanceZeroFee(verifier2, schemaId3, user1, expiry, signature);

        // Ensure scheduled increase is untouched and counters increment
        DataTypes.Schema memory schemaAfterCall = paymentsController.getSchema(schemaId3);
        assertEq(schemaAfterCall.currentFee, 0, "Current fee should remain zero before schedule activates");
        assertEq(schemaAfterCall.nextFee, scheduledFee, "Scheduled fee should remain set");
        assertEq(schemaAfterCall.totalVerified, schemaAfterSchedule.totalVerified + 1, "totalVerified should increment");

        // Nonce should increment on successful call
        assertEq(getVerifierNonce(verifier2Signer, user1), nonce + 1, "Verifier nonce should increment");
    }

    function testCannot_DeductBalanceZeroFee_WhenFeeIncreaseBecameEffective() public {
        assertEq(paymentsController.getSchema(schemaId3).currentFee, 0, "currentFee should be 0");

        uint128 scheduledFee = 1e6; // 1 USD8 with 6 decimals

        // Schedule a fee increase for the zero-fee schema
        vm.prank(issuer3);
        paymentsController.updateSchemaFee(schemaId3, scheduledFee);

        uint256 nextFeeTimestamp = paymentsController.getSchema(schemaId3).nextFeeTimestamp;
        vm.warp(nextFeeTimestamp + 1);

        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer, user1);
        bytes memory signature = generateDeductBalanceZeroFeeSignature(verifier2SignerPrivateKey, issuer3, verifier2, schemaId3, user1, expiry, nonce);

        vm.expectRevert(Errors.InvalidSchemaFee.selector);
        vm.prank(verifier2Asset);
        paymentsController.deductBalanceZeroFee(verifier2, schemaId3, user1, expiry, signature);

        // Revert unwinds the fee application; state should remain scheduled at zero-fee current
        DataTypes.Schema memory schemaAfterRevert = paymentsController.getSchema(schemaId3);
        assertEq(schemaAfterRevert.currentFee, 0, "currentFee remains zero after revert");
        assertEq(schemaAfterRevert.nextFee, scheduledFee, "nextFee stays scheduled after revert");
    }

    //------------------------------ negative tests for deductBalanceZeroFee ------------------------------

        function testCannot_DeductBalanceZeroFee_WhenExpiryIsInThePast() public {
            vm.expectRevert(Errors.SignatureExpired.selector);
            vm.prank(verifier2Asset);
            paymentsController.deductBalanceZeroFee(verifier2, schemaId3, user1, block.timestamp, "");
        }


        function testCannot_DeductBalanceZeroFee_WhenSchemaDoesNotHave0Fee() public {
            vm.expectRevert(Errors.InvalidSchemaFee.selector);
            vm.prank(verifier2Asset);
            paymentsController.deductBalanceZeroFee(verifier2, schemaId1, user1, block.timestamp + 1000, "");
        }

        function testCannot_DeductBalanceZeroFee_InvalidSignature() public {
            vm.expectRevert(Errors.InvalidSignature.selector);
            vm.prank(verifier2Asset);
            paymentsController.deductBalanceZeroFee(verifier2, schemaId3, user1, block.timestamp + 1000, "");
        }
        
    //------------------------------ state transition: subsidies - verifiers stake MOCA ------------------------------
    
    // note: verifier1 stakes MOCA
    function testCan_Verifier1StakeMOCA() public {
        uint128 amount = 10 ether;

        uint256 verifier1MocaStakedBefore = paymentsController.getVerifier(verifier1).mocaStaked;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierMocaStaked(verifier1, verifier1Asset, amount);

        vm.prank(verifier1Asset);
        paymentsController.stakeMoca{value: amount}(verifier1);

        // Check storage state
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        assertEq(verifier.mocaStaked, verifier1MocaStakedBefore + amount, "Verifier mocaStaked not updated correctly");
    }

    function testRevert_PaymentsControllerAdmin_CannotUpdatePoolId_SchemaDoesNotExist() public {
        uint128 poolId1 = uint128(123);
        
        vm.expectRevert(Errors.InvalidSchema.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(bytes32("999"), poolId1);
    }

    function testRevert_PaymentsControllerAdmin_CannotUpdatePoolId_PoolNotWhitelisted() public {
        uint128 poolId1 = uint128(123);
        
        vm.expectRevert(Errors.PoolNotWhitelisted.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(schemaId1, poolId1);
    }

    function test_PaymentsControllerAdmin_CanUpdatePoolId_PoolWhitelisted() public {
        uint128 poolId1 = uint128(123);

        // ---- whitelist pool -----
        // event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.PoolWhitelistedUpdated(poolId1, true);

        vm.prank(paymentsControllerAdmin);
        paymentsController.whitelistPool(poolId1, true);

        // check storage state
        assertEq(paymentsController.checkIfPoolIsWhitelisted(poolId1), true);

        // ---- update pool id -----    

        // event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.PoolIdUpdated(schemaId1, poolId1);

        vm.prank(paymentsControllerAdmin);
        paymentsController.updatePoolId(schemaId1, poolId1);

        // check storage state
        assertEq(paymentsController.getSchema(schemaId1).poolId, poolId1);
    }
}


// note: verifier1 stakes MOCA for subsidies & schema 1 is associated with pool1 [whitelisted]
abstract contract StateT10_Verifier1StakeMOCA is StateT9_Issuer3CreatesSchemaWith0Fees {
    uint128 public poolId1 = uint128(123);
        
    function setUp() public virtual override {
        super.setUp();
        
        uint128 amount = 10 ether;

        // verifier1: stakes MOCA
        vm.prank(verifier1Asset);
        paymentsController.stakeMoca{value: amount}(verifier1);

        // paymentsControllerAdmin: associate schema with pool
        vm.startPrank(paymentsControllerAdmin);
            paymentsController.whitelistPool(poolId1, true);
            paymentsController.updatePoolId(schemaId1, poolId1);
        vm.stopPrank();
    }
}

contract StateT10_Verifier1StakeMOCA_Test is StateT10_Verifier1StakeMOCA {

    //------------------------------ tests for unstakeMoca ------------------------------

        function testCannot_UnstakeMoca_InvalidAmount() public {
            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, 0);
        }

        function testCannot_UnstakeMoca_WhenCallerIsNotVerifierAsset() public {
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(verifier1);
            paymentsController.unstakeMoca(verifier1, 10 ether);
        }

        function testCannot_UnstakeMoca_MorethanStaked() public {
            uint128 amount = 1000 ether;

            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, amount);
        }

        function testCannot_UnstakeMoca_BeforeDelayPeriod() public {
            vm.expectRevert(Errors.UnstakeDelayNotPassed.selector);
            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, 1 ether);
        }

        function testCan_UnstakeMoca_AfterDelayPeriod() public {
            uint128 amount = 1 ether;

            // move time past delay threshold
            uint256 lastStakedAt = paymentsController.getVerifier(verifier1).lastStakedAt;
            vm.warp(lastStakedAt + paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD() + 1);

            uint256 verifier1AssetBalanceBefore = verifier1Asset.balance;
            uint256 contractBalanceBefore = address(paymentsController).balance;

            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierMocaUnstaked(verifier1, verifier1Asset, amount);

            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, amount);

            DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
            assertEq(verifier.mocaStaked, 10 ether - amount, "Verifier mocaStaked not updated correctly after delay");
            assertEq(paymentsController.TOTAL_MOCA_STAKED(), 10 ether - amount, "TOTAL_MOCA_STAKED not updated correctly after delay");
            assertEq(verifier1Asset.balance, verifier1AssetBalanceBefore + amount, "Verifier asset native balance not increased");
            assertEq(address(paymentsController).balance, contractBalanceBefore - amount, "Contract native balance not decreased");
        }

        function testCan_UnstakeMoca_UsesUpdatedDelay() public {
            uint256 oldDelay = paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD();
            uint256 newDelay = oldDelay + 6 hours;

            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.VerifierUnstakeDelayPeriodUpdated(oldDelay, newDelay);

            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierUnstakeDelayPeriod(newDelay);

            // attempt before new delay should revert
            vm.expectRevert(Errors.UnstakeDelayNotPassed.selector);
            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, 1 ether);

            // warp past new delay and succeed
            uint256 lastStakedAt = paymentsController.getVerifier(verifier1).lastStakedAt;
            vm.warp(lastStakedAt + newDelay + 1);

            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, 1 ether);
        }

        function testCan_Verifier1_UnstakeMOCA_ReceiveNative() public {
            uint128 amount = 10 ether;

            uint256 lastStakedAt = paymentsController.getVerifier(verifier1).lastStakedAt;
            vm.warp(lastStakedAt + paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD() + 1);

            // Record state before
            uint256 verifier1MocaStakedBefore = paymentsController.getVerifier(verifier1).mocaStaked;
            uint256 totalMocaStakedBefore = paymentsController.TOTAL_MOCA_STAKED();

            // There is no need to check mockMoca balances, as unstakeMoca should send native MOCA to verifier1Asset.
            uint256 verifier1AssetBalanceBefore = verifier1Asset.balance; // Native Moca (Ether)
            uint256 contractBalanceBefore = address(paymentsController).balance;
            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierMocaUnstaked(verifier1, verifier1Asset, amount);

            // Unstake
            vm.startPrank(verifier1Asset);
                paymentsController.unstakeMoca(verifier1, amount);
            vm.stopPrank();

            // Check storage state after
            DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
            assertEq(verifier.mocaStaked, verifier1MocaStakedBefore - amount, "Verifier mocaStaked not updated correctly");
            assertEq(paymentsController.TOTAL_MOCA_STAKED(), totalMocaStakedBefore - amount, "TOTAL_MOCA_STAKED not updated correctly");

            // Check native MOCA (Ether) balances after
            uint256 verifier1AssetBalanceAfter = verifier1Asset.balance;
            uint256 contractBalanceAfter = address(paymentsController).balance;
            assertEq(verifier1AssetBalanceAfter, verifier1AssetBalanceBefore + amount, "Verifier asset native MOCA (Ether) balance not increased correctly");
            assertEq(contractBalanceAfter, contractBalanceBefore - amount, "Contract native MOCA (Ether) balance not decreased correctly");
        }

        function testCan_Verifier1_UnstakeMOCA_ReceiveWMoca() public {
            // Deploy a contract with expensive receive function that exceeds MOCA_TRANSFER_GAS_LIMIT
            GasGuzzler gasGuzzler = new GasGuzzler();
            bytes memory gasGuzzlerCode = address(gasGuzzler).code;
            vm.etch(verifier1Asset, gasGuzzlerCode);

            uint128 amount = 10 ether;

            uint256 lastStakedAt = paymentsController.getVerifier(verifier1).lastStakedAt;
            vm.warp(lastStakedAt + paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD() + 1);

            // Record state before
            uint256 verifier1MocaStakedBefore = paymentsController.getVerifier(verifier1).mocaStaked;
            uint256 totalMocaStakedBefore = paymentsController.TOTAL_MOCA_STAKED();
            // wrapped moca balances before
            uint256 verifier1WMocaBalanceBefore = mockWMoca.balanceOf(verifier1Asset);
            uint256 contractWMocaBalanceBefore = mockWMoca.balanceOf(address(paymentsController));
            // native moca balances before
            uint256 verifier1AssetNativeBalanceBefore = verifier1Asset.balance;
            uint256 contractNativeBalanceBefore = address(paymentsController).balance;

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierMocaUnstaked(verifier1, verifier1Asset, amount);

            vm.prank(verifier1Asset);
            paymentsController.unstakeMoca(verifier1, amount);

            // Check storage state after
            DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
            assertEq(verifier.mocaStaked, verifier1MocaStakedBefore - amount, "Verifier mocaStaked not updated correctly");
            assertEq(paymentsController.TOTAL_MOCA_STAKED(), totalMocaStakedBefore - amount, "TOTAL_MOCA_STAKED not updated correctly");

            // Check wrapped moca balances after
            assertEq(mockWMoca.balanceOf(verifier1Asset), verifier1WMocaBalanceBefore + amount, "VerifierAsset addresss received wrapped moca");
            assertEq(mockWMoca.balanceOf(address(paymentsController)), 0, "Contract should not have wrapped moca");

            // Check native moca after
            assertEq(verifier1Asset.balance, verifier1AssetNativeBalanceBefore, "Verifier asset native MOCA balance should remain unchanged (received wrapped MOCA instead)");
            assertEq(address(paymentsController).balance, contractNativeBalanceBefore - amount, "Contract native MOCA (Ether) balance not decreased correctly");
        }

    //------------------------------ negative tests for stakeMoca ------------------------------
        function testCannot_StakeMoca_WhenAmountIsZero() public {
            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(verifier1Asset);
            paymentsController.stakeMoca{value: 0}(verifier1);
        }
        
        function testCannot_StakeMoca_WhenCallerIsNotVerifierAsset() public {
            vm.deal(verifier1, 10 ether);

            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(verifier1);
            paymentsController.stakeMoca{value: 10 ether}(verifier1);
        }

    //------------------------------ negative tests for updatePoolId ------------------------------
        function testCannot_UpdatePoolId_WhenSchemaDoesNotExist() public {
            vm.expectRevert(Errors.InvalidSchema.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updatePoolId(bytes32("456"), uint128(456));
        }
        
        function testCannot_UpdatePoolId_WhenCallerIsNotPaymentsControllerAdmin() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
            vm.prank(verifier1);
            paymentsController.updatePoolId(schemaId1, uint128(123));
        }

        // ---------------------- updateVerifierUnstakeDelayPeriod ----------------------
        function testCan_PaymentsControllerAdmin_UpdateVerifierUnstakeDelayPeriod() public {
            uint256 oldDelay = paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD();
            uint256 newDelay = oldDelay + 6 hours;

            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.VerifierUnstakeDelayPeriodUpdated(oldDelay, newDelay);

            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierUnstakeDelayPeriod(newDelay);

            assertEq(paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD(), newDelay, "VERIFIER_UNSTAKE_DELAY_PERIOD not updated");
        }

        function testCannot_NonAdmin_UpdateVerifierUnstakeDelayPeriod() public {
            uint256 oldDelay = paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD();
            uint256 newDelay = oldDelay + 1 hours;

            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
            vm.prank(verifier1);
            paymentsController.updateVerifierUnstakeDelayPeriod(newDelay);
        }

        function testCannot_UpdateVerifierUnstakeDelayPeriod_WhenZero() public {
            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierUnstakeDelayPeriod(0);
        }

        function testCannot_UpdateVerifierUnstakeDelayPeriod_WhenAboveMax() public {
            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierUnstakeDelayPeriod(60 days + 1);
        }

        function testCannot_UpdateVerifierUnstakeDelayPeriod_WhenUnchanged() public {
            uint256 currentDelay = paymentsController.VERIFIER_UNSTAKE_DELAY_PERIOD();

            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateVerifierUnstakeDelayPeriod(currentDelay);
        }

    //------------------------------ deductBalance should book subsidies for verifier ------------------------------
    function testCan_Verifier1DeductBalance_ShouldBookSubsidies() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier1).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer1).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId1).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId1).totalVerified;
       
        // Record epoch fees before deduction
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer1IncreasedSchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, nonce);
        
        // calc. subsidy
        uint256 mocaStaked = paymentsController.getVerifier(verifier1).mocaStaked;
        uint256 subsidyPct = paymentsController.getEligibleSubsidyPercentage(mocaStaked);
        uint256 subsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeIncreased(schemaId1, issuer1DecreasedSchemaFee, issuer1IncreasedSchemaFee);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier1, poolId1, schemaId1, subsidy);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);

        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
        
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
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId1);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");

        // check subsidy booked correctly
        uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        assertEq(epochPoolSubsidies, subsidy, "Subsidy not booked correctly");
        
        uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier1);
        assertEq(epochPoolVerifierSubsidies, subsidy, "Subsidy not booked correctly");

        // check view function
        vm.prank(verifier1Asset);
        (uint256 verifierAccruedSubsidies, uint256 poolAccruedSubsidies) = paymentsController.getVerifierAndPoolAccruedSubsidies(currentEpoch, poolId1, verifier1, verifier1Asset);
        assertEq(verifierAccruedSubsidies, subsidy, "Verifier accrued subsidies not returned correctly");
        assertEq(poolAccruedSubsidies, subsidy, "Pool accrued subsidies not returned correctly");
    }   

    //note: test getVerifierAndPoolAccruedSubsidies revert on invalid caller for VotingController.sol integration
    function testCannot_GetVerifierAndPoolAccruedSubsidies_InvalidCaller() public {
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();

        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(verifier1);
        paymentsController.getVerifierAndPoolAccruedSubsidies(currentEpoch, poolId1, verifier1, verifier1);
    }
}


// note: verifier2 stakes MOCA for subsidies & schema 2 is associated with pool2 [whitelisted]
// note: verifier3 stakes MOCA for subsidies & schema 3 is associated with pool3 [whitelisted]
abstract contract StateT11_AllVerifiersStakedMOCA is StateT10_Verifier1StakeMOCA {
    uint128 public poolId2 = uint128(234);
    uint128 public poolId3 = uint128(345);

    function setUp() public virtual override {
        super.setUp();
        
        // verifier2: stakes 20 MOCA for 20% subsidy tier
        vm.startPrank(verifier2Asset);
            paymentsController.stakeMoca{value: 20 ether}(verifier2);
            // for verification payments
            mockUSD8.approve(address(paymentsController), 100 * 1e6);
            paymentsController.deposit(verifier2, 100 * 1e6);
        vm.stopPrank();

        // verifier3: stakes 30 MOCA for 30% subsidy tier
        vm.startPrank(verifier3Asset);
            paymentsController.stakeMoca{value: 30 ether}(verifier3);
        vm.stopPrank();
        
        // paymentsControllerAdmin: associate schema2 and schema3 with pools
        vm.startPrank(paymentsControllerAdmin);
            paymentsController.whitelistPool(poolId2, true);
            paymentsController.whitelistPool(poolId3, true);
            paymentsController.updatePoolId(schemaId2, poolId2);
            paymentsController.updatePoolId(schemaId3, poolId3);
        vm.stopPrank();
    }
}

// Check subsidies being booked for other tiers: verifier2 and verifier3
// Check that no subsidies are booked for schema3 - zero-fee schema. even if schema is associated to a pool.
contract StateT11_AllVerifiersStakedMOCA_Test is StateT11_AllVerifiersStakedMOCA {

    //note: verifier 2: deposited 100 USD8 for verification payments. But did stake 20 MOCA for 20% subsidy tier.
    function testCan_Verifier2DeductBalance_ShouldBookSubsidies() public {
        // Record verifier's state before deduction
        uint256 verifierCurrentBalanceBefore = paymentsController.getVerifier(verifier2).currentBalance;
        uint256 verifierTotalExpenditureBefore = paymentsController.getVerifier(verifier2).totalExpenditure;
        
        // Record issuer's state before deduction
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer2).totalNetFeesAccrued;
        uint256 issuerTotalVerifiedBefore = paymentsController.getIssuer(issuer2).totalVerified;
        
        // Record schema's state before deduction
        uint256 schemaTotalGrossFeesAccruedBefore = paymentsController.getSchema(schemaId2).totalGrossFeesAccrued;
        uint256 schemaTotalVerifiedBefore = paymentsController.getSchema(schemaId2).totalVerified;
       
        // Record epoch fees before deduction
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint256 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint256 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;

        // Generate signature
        uint128 amount = issuer2SchemaFee;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier2SignerPrivateKey, issuer2, verifier2, schemaId2, user1, amount, expiry, nonce);
        
        // calc. subsidy (verifier2 staked 20 ether = 20% subsidy)
        uint256 mocaStaked = paymentsController.getVerifier(verifier2).mocaStaked;
        assertEq(mocaStaked, 20 ether, "Verifier2 should have 20 ether staked");
        uint256 subsidyPct = paymentsController.getEligibleSubsidyPercentage(mocaStaked);
        assertEq(subsidyPct, 2000, "Verifier2 should have 20% subsidy");
        uint256 subsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier2, schemaId2, issuer2, amount);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier2, poolId2, schemaId2, subsidy);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId2);

        vm.prank(verifier2Asset);
        paymentsController.deductBalance(verifier2, user1, schemaId2, amount, expiry, signature);
        
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
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier2);
        assertEq(verifier.currentBalance, verifierCurrentBalanceBefore - amount, "Verifier balance not updated correctly");
        assertEq(verifier.totalExpenditure, verifierTotalExpenditureBefore + amount, "Verifier totalExpenditure not updated correctly");

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer2);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore + netFee, "Issuer totalNetFeesAccrued not updated correctly");
        assertEq(issuer.totalVerified, issuerTotalVerifiedBefore + 1, "Issuer totalVerified not updated correctly");

        // Check storage state: schema
        DataTypes.Schema memory schema = paymentsController.getSchema(schemaId2);
        assertEq(schema.totalGrossFeesAccrued, schemaTotalGrossFeesAccruedBefore + amount, "Schema totalGrossFeesAccrued not updated correctly");
        assertEq(schema.totalVerified, schemaTotalVerifiedBefore + 1, "Schema totalVerified not updated correctly");

        // check subsidy booked correctly
        uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2);
        assertEq(epochPoolSubsidies, subsidy, "Subsidy not booked correctly for pool2");
        
        uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2);
        assertEq(epochPoolVerifierSubsidies, subsidy, "Subsidy not booked correctly for verifier2");
    }


    //note: verifier 3: deposited 0 USD8 for verification payments. But did stake 30 MOCA for 30% subsidy tier.
    function testCan_Verifier3DeductBalance_ShouldBookSubsidies() public {
        // For verifier3, we'll use the zero-fee schema (schemaId3) but still test subsidy booking
        // Generate signature for zero-fee deduction
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier3Signer, user1);
        bytes memory signature = generateDeductBalanceZeroFeeSignature(verifier3SignerPrivateKey, issuer3, verifier3, schemaId3, user1, expiry, nonce);
        
        // calc. subsidy (verifier3 staked 30 ether = 30% subsidy, but on 0 fee)
        uint256 mocaStaked = paymentsController.getVerifier(verifier3).mocaStaked;
        assertEq(mocaStaked, 30 ether, "Verifier3 should have 30 ether staked");
        uint256 subsidyPct = paymentsController.getEligibleSubsidyPercentage(mocaStaked);
        assertEq(subsidyPct, 3000, "Verifier3 should have 30% subsidy");
        // No subsidy for zero-fee schemas
        uint256 subsidy = 0;

        // Expect only SchemaVerifiedZeroFee event (no SubsidyBooked event for zero-fee)
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerifiedZeroFee(schemaId3);

        vm.prank(verifier3Asset);
        paymentsController.deductBalanceZeroFee(verifier3, schemaId3, user1, expiry, signature);

        // Check that no subsidy was booked (zero-fee schemas don't generate subsidies)
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId3);
        assertEq(epochPoolSubsidies, 0, "No subsidy should be booked for zero-fee schema");
        
        uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId3, verifier3);
        assertEq(epochPoolVerifierSubsidies, 0, "No subsidy should be booked for verifier3 with zero-fee schema");
    }

    // state transition: issuer can claim fees
    function testCan_IssuerClaimFees() public {
        // Record issuer's state before claiming fees
        uint256 issuerTotalNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
        uint256 issuerTotalClaimedBefore = paymentsController.getIssuer(issuer1).totalClaimed;

        uint256 claimableFees = paymentsController.getIssuer(issuer1).totalNetFeesAccrued - paymentsController.getIssuer(issuer1).totalClaimed;
        assertGt(claimableFees, 0, "Claimable fees should be greater than 0");

        // Record token balances before claim
        uint256 issuerTokenBalanceBefore = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));

        // Expect event emission
        vm.expectEmit(true, false, false, false, address(paymentsController));
        emit Events.IssuerFeesClaimed(issuer1, claimableFees);

        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1);

        // Check storage state: issuer
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
        assertEq(issuer.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore, "Issuer totalNetFeesAccrued must be unchanged");
        assertEq(issuer.totalClaimed, issuerTotalClaimedBefore + claimableFees, "Issuer totalClaimed must be increased by claimable fees");

        // Check token balances after claim
        uint256 issuerTokenBalanceAfter = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        assertEq(issuerTokenBalanceAfter, issuerTokenBalanceBefore + claimableFees, "Issuer should receive claimed fees in tokens");
        assertEq(controllerTokenBalanceAfter, controllerTokenBalanceBefore - claimableFees, "Controller should send out claimed fees in tokens");
    }
}


//note: issuer1Asset claims fees
abstract contract StateT12_IssuerClaimsAllFees is StateT11_AllVerifiersStakedMOCA {   
    function setUp() public virtual override {
        super.setUp();
        
        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1);
    }
}

contract StateT12_IssuerClaimsAllFees_Test is StateT12_IssuerClaimsAllFees {
    
    //------------------------------ negative tests for claimFees ------------------------------

    function testCannot_ClaimFees_WhenIssuerDoesNotHaveClaimableFees() public {     
        vm.expectRevert(Errors.NoClaimableFees.selector);
        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1);
    }

    function testCannot_ClaimFees_WhenCallerIsNotIssuerAsset() public {
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(issuer1);
        paymentsController.claimFees(issuer1);
    }

    // ---- state transition: issuer change assetManagerAddress ----
    function testCan_IssuerUpdateAssetManagerAddress() public{
        // Record issuer's state before update
        DataTypes.Issuer memory issuer1Before = paymentsController.getIssuer(issuer1);
        assertEq(issuer1Before.assetManagerAddress, issuer1Asset, "Issuer assetManagerAddress should be the same");
        
        // new asset manager address
        address issuer1_newAssetAddress = address(0x1234567890123456789012345678901234567890);

        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.AssetManagerAddressUpdated(issuer1, issuer1_newAssetAddress, true);
 
        vm.prank(issuer1);
        address newAssetManagerAddress = paymentsController.updateAssetManagerAddress(issuer1_newAssetAddress, true);

        // Check storage state: issuer
        DataTypes.Issuer memory issuer1After = paymentsController.getIssuer(issuer1);
        assertEq(newAssetManagerAddress, issuer1_newAssetAddress, "returned newAssetManagerAddress should be the same");
        assertEq(issuer1After.assetManagerAddress, issuer1_newAssetAddress, "Issuer assetManagerAddress should be updated");
    }
}


//note: issuer1 changes asset address & deductBalance called by verifier1 to pay fees to issuer1
abstract contract StateT13_IssuerChangesAssetManagerAddress is StateT12_IssuerClaimsAllFees {
    
    address public issuer1_newAssetAddress = address(0x1234567890123456789012345678901234567890);

    function setUp() public virtual override {
        super.setUp();
        
        // issuer changes asset address
        vm.prank(issuer1);
        paymentsController.updateAssetManagerAddress(issuer1_newAssetAddress, true);

        // deductBalance called by verifier
        uint256 expiry = block.timestamp + 100;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        uint128 amount = issuer1IncreasedSchemaFee;
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, nonce);
        
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
    }
}

contract StateT13_IssuerChangesAssetManagerAddress_Test is StateT13_IssuerChangesAssetManagerAddress {

    function testCan_Issuer1ClaimFees_WithNewAssetManagerAddress() public {
        // Record issuer's state before claim
        DataTypes.Issuer memory issuerBefore = paymentsController.getIssuer(issuer1);
        uint256 issuerTotalNetFeesAccruedBefore = issuerBefore.totalNetFeesAccrued;
        uint256 issuerTotalClaimedBefore = issuerBefore.totalClaimed;

        // Record TOTAL_CLAIMED_VERIFICATION_FEES before claim
        uint256 totalClaimedBefore = paymentsController.TOTAL_CLAIMED_VERIFICATION_FEES();
        
        // Calculate claimable fees (fees from the deductBalance in setup)
        uint256 claimableFees = issuerTotalNetFeesAccruedBefore - issuerTotalClaimedBefore;
        assertTrue(claimableFees > 0, "Issuer should have claimable fees");
        
        // Check token balances before claim
        uint256 newAssetManagerAddressTokenBalanceBefore = mockUSD8.balanceOf(issuer1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));
        
        // Expect event emission
        vm.expectEmit(true, false, false, false, address(paymentsController));
        emit Events.IssuerFeesClaimed(issuer1, claimableFees);
        
        // Claim fees using new asset address
        vm.prank(issuer1_newAssetAddress);
        paymentsController.claimFees(issuer1);
        
        // Check storage state: issuer
        DataTypes.Issuer memory issuerAfter = paymentsController.getIssuer(issuer1);
        assertEq(issuerAfter.totalNetFeesAccrued, issuerTotalNetFeesAccruedBefore, "Issuer totalNetFeesAccrued should remain unchanged");
        assertEq(issuerAfter.totalClaimed, issuerTotalNetFeesAccruedBefore, "Issuer totalClaimed should equal totalNetFeesAccrued after claim");
        assertEq(issuerAfter.assetManagerAddress, issuer1_newAssetAddress, "Issuer assetManagerAddress should be the new address");
        
        // Check token balances after claim
        uint256 newAssetManagerAddressTokenBalanceAfter = mockUSD8.balanceOf(issuer1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceAfter = mockUSD8.balanceOf(issuer1Asset);
        uint256 controllerTokenBalanceAfter = mockUSD8.balanceOf(address(paymentsController));
        
        // Verify fees were transferred to new asset address, not old one
        assertEq(newAssetManagerAddressTokenBalanceAfter, newAssetManagerAddressTokenBalanceBefore + claimableFees, "New asset address should receive claimed fees");
        assertEq(oldAssetAddressTokenBalanceAfter, oldAssetAddressTokenBalanceBefore, "Old asset address should not receive any fees");
        assertEq(controllerTokenBalanceAfter, controllerTokenBalanceBefore - claimableFees, "Controller should transfer out claimed fees");
        
        // Check global counter
        assertEq(paymentsController.TOTAL_CLAIMED_VERIFICATION_FEES(), totalClaimedBefore + claimableFees, "TOTAL_CLAIMED_VERIFICATION_FEES should be updated");
    }

    function testCannot_Issuer1ClaimFees_WithOldAssetAddress() public {
        // Verify issuer has claimable fees
        DataTypes.Issuer memory issuer = paymentsController.getIssuer(issuer1);
        uint256 claimableFees = issuer.totalNetFeesAccrued - issuer.totalClaimed;
        assertGt(claimableFees, 0, "Issuer should have claimable fees");
        
        // Attempt to claim with old asset address should fail
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(issuer1Asset);
        paymentsController.claimFees(issuer1);
    }

    //------------------------------ common negative tests for updateAssetAddress ------------------------------

        function testCannot_UpdateAssetAddress_WhenAssetAddressIsZeroAddress() public {
            vm.expectRevert(Errors.InvalidAddress.selector);
            vm.prank(issuer1);
            paymentsController.updateAssetManagerAddress(address(0), true);
        }

        function testCannot_UpdateAssetAddress_WhenIssuerDoesNotExist() public {
            vm.expectRevert(Errors.IssuerDoesNotExist.selector);
            vm.prank(address(0xdeadbeef));
            paymentsController.updateAssetManagerAddress(address(1), true);
        }

    //------------------------------ state transition: verifier updateAssetAddress ------------------------------
        function testCannot_UpdateAssetAddress_WhenVerifierDoesNotExist() public {
            vm.expectRevert(Errors.VerifierDoesNotExist.selector);
            vm.prank(address(0xdeadbeef));
            paymentsController.updateAssetManagerAddress(address(1), false);
        }

        function testCan_Verifier1UpdateAssetManagerAddress() public {
            // Record verifier's state before update
            DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1);
            assertEq(verifierBefore.assetManagerAddress, verifier1Asset, "Verifier assetManagerAddress should be the same");

            // new addr
            address verifier1_newAssetManagerAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_newAssetManagerAddress", block.timestamp, block.prevrandao)))));

            vm.expectEmit(true, true, false, false, address(paymentsController));
        emit Events.AssetManagerAddressUpdated(verifier1, verifier1_newAssetManagerAddress, false);

            vm.prank(verifier1);
            paymentsController.updateAssetManagerAddress(verifier1_newAssetManagerAddress, false);
            
            // Check storage state: verifier
            DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1);
            assertEq(verifierAfter.assetManagerAddress, verifier1_newAssetManagerAddress, "Verifier assetManagerAddress should be updated");
            assertNotEq(verifierAfter.assetManagerAddress, verifier1Asset, "Verifier assetManagerAddress should be updated");
        }
}


//note: verifier1 changes asset address
abstract contract StateT14_VerifierChangesAssetAddress is StateT13_IssuerChangesAssetManagerAddress {

    address public verifier1_newAssetAddress = address(uint160(uint256(keccak256(abi.encodePacked("verifier1_newAssetAddress", block.timestamp, block.prevrandao)))));

    function setUp() public virtual override {
        super.setUp();
        
        vm.prank(verifier1);
        paymentsController.updateAssetManagerAddress(verifier1_newAssetAddress, false);
    }
}

contract StateT14_VerifierChangesAssetAddress_Test is StateT14_VerifierChangesAssetAddress {
    
    function testCan_VerifierWithdrawUSD8_WithNewAssetAddress() public {
        // Record verifier's state before withdraw
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1);
        uint128 verifierCurrentBalanceBefore = verifierBefore.currentBalance;
        assertGt(verifierCurrentBalanceBefore, 0, "Verifier should have balance");
        assertEq(verifierBefore.assetManagerAddress, verifier1_newAssetAddress, "Verifier assetManagerAddress should be updated");

        // Check token balances before withdraw
        uint256 newAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(verifier1_newAssetAddress);
        uint256 oldAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(verifier1Asset);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));

        // event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifier1, verifier1_newAssetAddress, verifierCurrentBalanceBefore);

        vm.prank(verifier1_newAssetAddress);
        paymentsController.withdraw(verifier1, verifierCurrentBalanceBefore);

        // Check storage state: verifier
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1);
        assertEq(verifierAfter.currentBalance, 0, "Verifier balance should be zero after full withdraw");
        assertEq(verifierAfter.assetManagerAddress, verifier1_newAssetAddress, "Verifier assetManagerAddress should remain unchanged");

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
        DataTypes.Verifier memory verifierBefore = paymentsController.getVerifier(verifier1);
        uint128 verifierCurrentBalanceBefore = verifierBefore.currentBalance;
        assertGt(verifierCurrentBalanceBefore, 0, "Verifier should have non-zero balance");
        
        uint128 withdrawAmount = verifierCurrentBalanceBefore / 2;
        
        // Check token balances before withdraw
        uint256 newAssetAddressTokenBalanceBefore = mockUSD8.balanceOf(verifier1_newAssetAddress);
        uint256 controllerTokenBalanceBefore = mockUSD8.balanceOf(address(paymentsController));

        // event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierWithdrew(verifier1, verifier1_newAssetAddress, withdrawAmount);

        vm.prank(verifier1_newAssetAddress);
        paymentsController.withdraw(verifier1, withdrawAmount);

        // Check storage state: verifier
        DataTypes.Verifier memory verifierAfter = paymentsController.getVerifier(verifier1);
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
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        uint128 currentBalance = verifier.currentBalance;
        assertGt(currentBalance, 0, "Verifier should have balance");
        
        // Attempt to withdraw with old asset address should fail
        vm.expectRevert(Errors.InvalidCaller.selector);
        vm.prank(verifier1Asset);
        paymentsController.withdraw(verifier1, currentBalance);
    }

    // --------------- negative tests for withdraw ------------------------
        function testCannot_VerifierWithdraw_WhenAmountIsZero() public {
            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(verifier1_newAssetAddress);
            paymentsController.withdraw(verifier1, 0);
        }

        function testCannot_VerifierWithdraw_WhenAmountIsGreaterThanBalance() public {
            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(verifier1_newAssetAddress);
            paymentsController.withdraw(verifier1, 1000 ether);
        }

        function testCannot_VerifierWithdraw_WhenCallerIsNotVerifierAsset() public {
            vm.expectRevert(Errors.InvalidCaller.selector);
            vm.prank(verifier1);
            paymentsController.withdraw(verifier1, 1 ether);
        }

    // --------------- state transition: updateProtocolFee() ------------------------   
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


// note: protocol fee is increased
abstract contract StateT15_PaymentsControllerAdminIncreasesProtocolFee is StateT14_VerifierChangesAssetAddress {

    uint256 public newProtocolFee;

    function setUp() public virtual override {
        super.setUp();

        newProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE() + 100;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateProtocolFeePercentage(newProtocolFee);
    }
}   

contract StateT15_PaymentsControllerAdminIncreasesProtocolFee_Test is StateT15_PaymentsControllerAdminIncreasesProtocolFee {
    
    function testCan_PaymentsControllerAdmin_UpdateProtocolFee() public view {
        uint256 updatedProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
        assertEq(updatedProtocolFee, newProtocolFee, "Protocol fee should be updated to new value"); 
    }

    // check that deductBalance books the correct amount of protocol fee when protocol fee is increased     
    function testCan_DeductBalance_WhenProtocolFeeIsIncreased() public {
        // Note: verifier2 has 100 USD8 deposited (from StateT10) and 20 MOCA staked for 20% subsidy
        // schemaId2 fee is 20 USD8, and it's associated with poolId2
        
        // Record initial states
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        DataTypes.FeesAccrued memory poolFeesBefore = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId2);
        
        // Verify verifier2 has sufficient USD8 balance
        uint256 verifier2USD8BalanceBefore = paymentsController.getVerifier(verifier2).currentBalance;
        assertGe(verifier2USD8BalanceBefore, issuer2SchemaFee, "Verifier2 should have sufficient USD8 balance");
        
        uint256 verifier2ExpenditureBefore = paymentsController.getVerifier(verifier2).totalExpenditure;
        uint256 issuer2NetFeesBefore = paymentsController.getIssuer(issuer2).totalNetFeesAccrued;
        
        // Record subsidy data before
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2);
        
        // Use schemaId2 which has poolId2 associated
        uint128 amount = issuer2SchemaFee; // 20 USD8 (to be paid from USD8 balance)
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier2SignerPrivateKey, issuer2, verifier2, schemaId2, user1, amount, expiry, nonce);

        // Calculate expected fees with increased protocol fee (6% instead of 5%)
        uint256 expectedProtocolFee = (amount * newProtocolFee) / Constants.PRECISION_BASE;
        uint256 expectedVotingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 expectedNetFee = amount - expectedProtocolFee - expectedVotingFee;
        
        // Calculate expected subsidy based on MOCA staked (verifier2 has 20 MOCA = 20% subsidy tier)
        uint256 mocaStaked = paymentsController.getVerifier(verifier2).mocaStaked;
        assertEq(mocaStaked, 20 ether, "Verifier2 should have 20 MOCA staked");
        uint256 expectedSubsidyPct = 2000; // 20%
        uint256 expectedSubsidy = (amount * expectedSubsidyPct) / Constants.PRECISION_BASE;

        // Expect events
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier2, schemaId2, issuer2, amount);

        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier2, poolId2, schemaId2, expectedSubsidy);

        vm.expectEmit(true, false, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId2);

        // Execute deductBalance - this deducts USD8, not MOCA
        vm.prank(verifier2Asset);
        paymentsController.deductBalance(verifier2, user1, schemaId2, amount, expiry, signature);

        // Verify global epoch fees updated correctly with new protocol fee
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, epochFeesBefore.feesAccruedToProtocol + expectedProtocolFee, "Protocol fees incorrectly updated w/ increased percentage");
        assertEq(epochFeesAfter.feesAccruedToVoters, epochFeesBefore.feesAccruedToVoters + expectedVotingFee, "Voting fees incorrectly updated");
        
        
        // Verify pool-specific fees updated correctly
        DataTypes.FeesAccrued memory poolFeesAfter = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId2);
        assertEq(poolFeesAfter.feesAccruedToProtocol, poolFeesBefore.feesAccruedToProtocol + expectedProtocolFee, "Pool protocol fees incorrectly updated w/ increased percentage");
        assertEq(poolFeesAfter.feesAccruedToVoters, poolFeesBefore.feesAccruedToVoters + expectedVotingFee, "Pool voting fees incorrectly updated");
        
        // Verify verifier USD8 balance decreased (not MOCA balance)
        assertEq(paymentsController.getVerifier(verifier2).currentBalance, verifier2USD8BalanceBefore - amount, "Verifier USD8 balance not decreased correctly");
        assertEq(paymentsController.getVerifier(verifier2).totalExpenditure, verifier2ExpenditureBefore + amount, "Verifier expenditure not increased correctly");
        
        // Verify MOCA balance unchanged
        assertEq(paymentsController.getVerifier(verifier2).mocaStaked, 20 ether, "MOCA staked should remain unchanged after deductBalance");
        
        // Verify issuer received correct net fee (in USD8)
        assertEq(paymentsController.getIssuer(issuer2).totalNetFeesAccrued, issuer2NetFeesBefore + expectedNetFee, "Issuer net fees not updated correctly");
        
        // Verify subsidies booked correctly (based on MOCA staked percentage)  
        assertEq(paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2), poolSubsidiesBefore + expectedSubsidy, "Pool subsidies not booked correctly");
        assertEq(paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2), verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies not booked correctly");
    }

    // ------- negative tests for updateProtocolFeePercentage() ----------
    
        function testCannot_NonAdmin_UpdateProtocolFee() public {
            uint256 attemptedNewFee = paymentsController.PROTOCOL_FEE_PERCENTAGE() + 200;
            
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
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


//note: voting fee percentage is increased
abstract contract StateT16_PaymentsControllerAdminIncreasesVotingFee is StateT15_PaymentsControllerAdminIncreasesProtocolFee {

    uint256 public newVotingFee;

    function setUp() public virtual override {
        super.setUp();
        
        newVotingFee = paymentsController.VOTING_FEE_PERCENTAGE() + 100;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateVotingFeePercentage(newVotingFee);
    }
}

contract StateT16_PaymentsControllerAdminIncreasesVotingFee_Test is StateT16_PaymentsControllerAdminIncreasesVotingFee {
    
    function testCan_PaymentsControllerAdmin_UpdateVotingFee() public view {
        uint256 updatedVotingFee = paymentsController.VOTING_FEE_PERCENTAGE();
        assertEq(updatedVotingFee, newVotingFee, "Voting fee should be updated to new value");
    }

    // check that deductBalance books the correct amount of voting fee when voting fee pct is increased     
    function testCan_DeductBalance_WhenVotingFeeIsIncreased() public {
        // Note: verifier2 has 100 USD8 deposited (from StateT10) and 20 MOCA staked for 20% subsidy
        // schemaId2 fee is 20 USD8, and it's associated with poolId2
        // Protocol fee was increased to 6% in StateT14, voting fee now increased to 11% in StateT15
        
        // Record initial states
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        DataTypes.FeesAccrued memory poolFeesBefore = paymentsController.getEpochPoolFeesAccrued(currentEpoch, poolId2);
        
        // Verify verifier2 has sufficient USD8 balance
        uint256 verifier2USD8BalanceBefore = paymentsController.getVerifier(verifier2).currentBalance;
        assertGe(verifier2USD8BalanceBefore, issuer2SchemaFee, "Verifier2 should have sufficient USD8 balance");
        
        uint256 verifier2ExpenditureBefore = paymentsController.getVerifier(verifier2).totalExpenditure;
        uint256 issuer2NetFeesBefore = paymentsController.getIssuer(issuer2).totalNetFeesAccrued;
        
        // Record subsidy data before
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2);
        
        // Use schemaId2 which has poolId2 associated
        uint128 amount = issuer2SchemaFee; // 20 USD8 (to be paid from USD8 balance)
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier2Signer, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier2SignerPrivateKey, issuer2, verifier2, schemaId2, user1, amount, expiry, nonce);

        // Calculate expected fees with increased voting fee (11% instead of 10%) and protocol fee (6% from StateT14)
        uint256 currentProtocolFee = paymentsController.PROTOCOL_FEE_PERCENTAGE();
        uint256 expectedProtocolFee = (amount * currentProtocolFee) / Constants.PRECISION_BASE;
        uint256 expectedVotingFee = (amount * newVotingFee) / Constants.PRECISION_BASE;
        uint256 expectedNetFee = amount - expectedProtocolFee - expectedVotingFee;
        
        // Calculate expected subsidy based on MOCA staked (verifier2 has 20 MOCA = 20% subsidy tier)
        uint256 mocaStaked = paymentsController.getVerifier(verifier2).mocaStaked;
        assertEq(mocaStaked, 20 ether, "Verifier2 should have 20 MOCA staked");
        uint256 expectedSubsidyPct = 2000; // 20%
        uint256 expectedSubsidy = (amount * expectedSubsidyPct) / Constants.PRECISION_BASE;

        // Expect events
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier2, schemaId2, issuer2, amount);

        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier2, poolId2, schemaId2, expectedSubsidy);

        vm.expectEmit(true, false, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId2);

        // Execute deductBalance - this deducts USD8, not MOCA
        vm.prank(verifier2Asset);
        paymentsController.deductBalance(verifier2, user1, schemaId2, amount, expiry, signature);

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
        assertEq(paymentsController.getVerifier(verifier2).currentBalance, verifier2USD8BalanceBefore - amount, "Verifier USD8 balance not decreased correctly");
        assertEq(paymentsController.getVerifier(verifier2).totalExpenditure,verifier2ExpenditureBefore + amount,"Verifier expenditure not increased correctly");
        
        // Verify MOCA balance unchanged
        assertEq(paymentsController.getVerifier(verifier2).mocaStaked, 20 ether, "MOCA staked should remain unchanged after deductBalance");
        
        
        // Verify issuer received correct net fee (in USD8)
        assertEq(paymentsController.getIssuer(issuer2).totalNetFeesAccrued, issuer2NetFeesBefore + expectedNetFee, "Issuer net fees not updated correctly with increased voting fee");
        
        
        // Verify subsidies booked correctly (based on MOCA staked percentage)
        assertEq(paymentsController.getEpochPoolSubsidies(currentEpoch, poolId2), poolSubsidiesBefore + expectedSubsidy, "Pool subsidies not booked correctly");
        assertEq(paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId2, verifier2), verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies not booked correctly");
    }

    // ------- negative tests for updateVotingFeePercentage() ----------
    
        function testCannot_NonAdmin_UpdateVotingFee() public {
            uint256 attemptedNewFee = paymentsController.VOTING_FEE_PERCENTAGE() + 200;
            
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
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
    
        // change for tier1: 10 moca staked -> 11% subsidy
        function testCan_PaymentsControllerAdmin_UpdateVerifierSubsidyPercentages() public {
            uint256 currentSubsidyPct = paymentsController.getEligibleSubsidyPercentage(10 ether);
            uint256 newSubsidyPct = currentSubsidyPct + 100;
            

            // subsidy tiers
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](3);

            mocaStaked[0] = 10 ether;
            subsidies[0] = uint128(newSubsidyPct);
            mocaStaked[1] = 20 ether;
            subsidies[1] = 2000;
            mocaStaked[2] = 30 ether;
            subsidies[2] = 3000;


            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.VerifierStakingTiersSet(mocaStaked, subsidies);

            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);

            assertEq(paymentsController.getEligibleSubsidyPercentage(10 ether), newSubsidyPct, "Verifier subsidy percentage not updated correctly");
        }        
}


//note: change subsidy tier1: 10 moca staked -> 11% subsidy [prev. 10%]
abstract contract StateT17_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage is StateT16_PaymentsControllerAdminIncreasesVotingFee {

    uint256 public newSubsidyPct;

    function setUp() public virtual override {
        super.setUp();

        uint256 currentSubsidyPct = paymentsController.getEligibleSubsidyPercentage(10 ether);
        newSubsidyPct = currentSubsidyPct + 100;


            // subsidy tiers
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](3);

            mocaStaked[0] = 10 ether;
            subsidies[0] = uint128(newSubsidyPct);
            mocaStaked[1] = 20 ether;
            subsidies[1] = 2000;
            mocaStaked[2] = 30 ether;
            subsidies[2] = 3000;


        vm.prank(paymentsControllerAdmin);
        paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
    }
}

contract StateT17_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage_Test is StateT17_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage {

    function testCan_PaymentsControllerAdmin_UpdateVerifierSubsidyPercentages() public view {
        assertEq(paymentsController.getEligibleSubsidyPercentage(10 ether), newSubsidyPct, "Verifier subsidy percentage not updated correctly");    
    }

    // check that deductBalance books the correct amount of subsidy when subsidy percentage is increased
    function testCan_DeductBalance_WhenVerifierSubsidyPercentageIsIncreased() public {
        // Note: verifier1 has 10 MOCA staked (tier1) which now gives 11% subsidy instead of 10%
        // verifier1 has 100 USD8 deposited, schemaId1 fee is 10 USD8, poolId1 associated
        
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Cache initial subsidy states
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier1);
        
        // Prepare deductBalance call
        uint128 amount = issuer1IncreasedSchemaFee; // 10 USD8
        uint256 expiry = block.timestamp + 1000;
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, getVerifierNonce(verifier1NewSigner, user1));

        // Verify subsidy percentage is 11% for 10 MOCA stake
        assertEq(paymentsController.getEligibleSubsidyPercentage(10 ether), 1100, "Subsidy should be 11%");
        
        // Calculate expected subsidy with new 11% rate
        uint256 expectedSubsidy = (amount * 1100) / Constants.PRECISION_BASE;

        // Expect events
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount);

        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier1, poolId1, schemaId1, expectedSubsidy);

        // Execute deductBalance
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);

        // Verify subsidies increased with new percentage
        assertEq(paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1), poolSubsidiesBefore + expectedSubsidy, "Pool subsidies not booked correctly");
        assertEq(paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier1), verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies not booked correctly");
        
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
    function testCan_DeductBalance_WhenVerifierStakedMoca_InBetweenTiers() public {
        // Create new verifier4 with 15 MOCA staked (not in any tier)
        address verifier4 = makeAddr("verifier4");
        address verifier4Asset = makeAddr("verifier4Asset");
        address verifier4Signer;
        uint256 verifier4SignerPrivateKey;
        (verifier4Signer, verifier4SignerPrivateKey) = makeAddrAndKey("verifier4Signer");
        
        // Mint tokens to verifier4Asset
        mockUSD8.mint(verifier4Asset, 100 * 1e6);
        vm.deal(verifier4Asset, 100 ether);
        
        // Create verifier4 - fix parameter order: (signerAddress, assetAddress)
        vm.prank(verifier4);
        paymentsController.createVerifier(verifier4Signer, verifier4Asset);
        
        // Stake 15 MOCA (between tier1=10 and tier2=20, so gets 11% subsidy)
        uint128 nonTierMocaAmount = 15 ether;
        vm.startPrank(verifier4Asset);
            paymentsController.stakeMoca{value: nonTierMocaAmount}(verifier4);
            // Deposit USD8 for verification payments
            mockUSD8.approve(address(paymentsController), 50 * 1e6);
            paymentsController.deposit(verifier4, 50 * 1e6);
        vm.stopPrank();
        
        // Verify subsidy percentage: 15 MOCA should round down to 10 MOCA tier (11%)
        uint256 subsidyPct = paymentsController.getEligibleSubsidyPercentage(nonTierMocaAmount);
        assertEq(subsidyPct, 1100, "Subsidy percentage should match 10 MOCA tier (11%)");
        
        // Record initial states
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint256 poolSubsidiesBefore = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        uint256 verifierSubsidiesBefore = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier4);
        assertEq(verifierSubsidiesBefore, 0, "Verifier should have no subsidies initially");
        
        // Prepare deductBalance - MUST use issuer1IncreasedSchemaFee (20 USD8) not issuer1SchemaFee
        uint128 amount = issuer1IncreasedSchemaFee; // 20 USD8 - changed from issuer1SchemaFee
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier4Signer, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier4SignerPrivateKey, issuer1, verifier4, schemaId1, user1, amount, expiry, nonce);
        

        // Calculate expected subsidy: amount * subsidyPct / PRECISION_BASE
        uint256 expectedSubsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;
        
        // Expect SubsidyBooked event with correct subsidy amount
        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier4, schemaId1, issuer1, amount);

        vm.expectEmit(true, true, true, true, address(paymentsController));
        emit Events.SubsidyBooked(verifier4, poolId1, schemaId1, expectedSubsidy);

        vm.expectEmit(true, false, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);
                
        // Execute deductBalance
        vm.prank(verifier4Asset);
        paymentsController.deductBalance(verifier4, user1, schemaId1, amount, expiry, signature);
        
        // Verify no subsidies were booked
        uint256 poolSubsidiesAfter = paymentsController.getEpochPoolSubsidies(currentEpoch, poolId1);
        assertEq(poolSubsidiesAfter, poolSubsidiesBefore + expectedSubsidy, "Pool subsidies should increase by expected subsidy");
        
        uint256 verifierSubsidiesAfter = paymentsController.getEpochPoolVerifierSubsidies(currentEpoch, poolId1, verifier4);
        assertEq(verifierSubsidiesAfter, verifierSubsidiesBefore + expectedSubsidy, "Verifier subsidies should equal expected subsidy");
        
        // Verify fees are still distributed correctly
        DataTypes.Verifier memory verifier4Data = paymentsController.getVerifier(verifier4);
        assertEq(verifier4Data.currentBalance, 50 * 1e6 - amount, "Verifier USD8 balance should be reduced by amount");
        assertEq(verifier4Data.totalExpenditure, amount, "Verifier expenditure should equal amount");
    }

    // ------- negative tests for setVerifierSubsidyTiers() ----------
    
        function testCannot_NonAdmin_SetVerifierSubsidyTiers() public {
            // subsidy tiers
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](3);

            mocaStaked[0] = 10 ether;
            subsidies[0] = uint128(newSubsidyPct);
            mocaStaked[1] = 20 ether;
            subsidies[1] = 2000;
            mocaStaked[2] = 30 ether;
            subsidies[2] = 3000;
            
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
            vm.prank(verifier1);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
            
            // Verify subsidy percentage remains unchanged for new tier
            assertEq(paymentsController.getEligibleSubsidyPercentage(mocaStaked[0]), subsidies[0], "Subsidy percentage should remain 0 for unapproved tier");
        }


        function testCannot_SetVerifierSubsidyTiers_WhenInvalidArray_Size0() public {
            // create arrays
            uint128[] memory mocaStaked = new uint128[](0);
            uint128[] memory subsidies = new uint128[](0);

            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

        function testCannot_SetVerifierSubsidyTiers_WhenInvalidArray_SizeGreaterThan10() public {
            // create arrays
            uint128[] memory mocaStaked = new uint128[](11);
            uint128[] memory subsidies = new uint128[](11);
            for (uint256 i = 0; i < 11; ++i) {
                mocaStaked[i] = uint128(1 + i);
                subsidies[i] = uint128(10 + i);
            }

            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

        function testCannot_SetVerifierSubsidyTiers_WhenInvalidArray_SizeMismatch() public {    
            // create arrays
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](2);

            mocaStaked[0] = 10 ether;
            subsidies[0] = 1000;
            mocaStaked[1] = 20 ether;
            subsidies[1] = 2000;
            mocaStaked[2] = 30 ether;

            vm.expectRevert(Errors.MismatchedArrayLengths.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

        function testCannot_SetVerifierSubsidyTiers_WhenMocaStakedIsZero() public {
            // create arrays
            uint128[] memory mocaStaked = new uint128[](1);
            uint128[] memory subsidies = new uint128[](1);

            mocaStaked[0] = 0;
            subsidies[0] = 1000;

            vm.expectRevert(Errors.InvalidAmount.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

        function testCannot_SetVerifierSubsidyTiers_WhenSubsidyPercentageIsZero() public {
                      // create arrays
            uint128[] memory mocaStaked = new uint128[](1);
            uint128[] memory subsidies = new uint128[](1);

            mocaStaked[0] = 10 ether;
            subsidies[0] = 0;

            vm.expectRevert(Errors.InvalidPercentage.selector); 
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

        function testCannot_SetVerifierSubsidyTiers_WhenSubsidyPercentageExceedsMax() public {
            uint128 exceedingMaxSubsidy = uint128(Constants.PRECISION_BASE + 1); // 100.01%

            // subsidy tiers
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](3);

            mocaStaked[0] = 10 ether;
            subsidies[0] = exceedingMaxSubsidy;
            mocaStaked[1] = 20 ether;
            subsidies[1] = 2000;
            mocaStaked[2] = 30 ether;
            subsidies[2] = 3000;
            
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }
        
        function testCannot_SetVerifierSubsidyTiers_WhenMocaStakedIsNotAscending() public {
            // create arrays
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](3);

            mocaStaked[0] = 10 ether;
            subsidies[0] = 1000;
            mocaStaked[1] = 20 ether;
            subsidies[1] = 2000;
            mocaStaked[2] = 15 ether; // not ascending
            subsidies[2] = 3000;
            
            vm.expectRevert(Errors.InvalidMocaStakedTierOrder.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

        function testCannot_SetVerifierSubsidyTiers_WhenSubsidyPercentageIsNotAscending() public {
            // create arrays
            uint128[] memory mocaStaked = new uint128[](3);
            uint128[] memory subsidies = new uint128[](3);

            mocaStaked[0] = 10 ether;
            subsidies[0] = 1000;
            mocaStaked[1] = 20 ether;
            subsidies[1] = 500;         // not ascending
            mocaStaked[2] = 30 ether; 
            subsidies[2] = 3000;

            vm.expectRevert(Errors.InvalidSubsidyPercentageTierOrder.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
        }

    // ------- state transition: updateFeeIncreaseDelayPeriod() ---------
    
        function testCan_PaymentsControllerAdmin_UpdateFeeIncreaseDelayPeriod() public {
            uint128 newDelayPeriod = 28 days;
            
            vm.expectEmit(true, true, false, true, address(paymentsController));
            emit Events.FeeIncreaseDelayPeriodUpdated(newDelayPeriod);
            
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }
}


//note: fee increase delay period increased to 28 days
abstract contract StateT18_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod is StateT17_PaymentsControllerAdminIncreasesVerifierSubsidyPercentage {

    uint128 public newDelayPeriod;

    function setUp() public virtual override {
        super.setUp();

        newDelayPeriod = 28 days;

        vm.prank(paymentsControllerAdmin);
        paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
    }
}

contract StateT18_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod_Test is StateT18_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod {

    function testCan_PaymentsControllerAdmin_UpdateFeeIncreaseDelayPeriod() public view {
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
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(schemaId1, issuer1IncreasedSchemaFeeV2);

        //check that the fee is increased
        assertEq(paymentsController.getSchema(schemaId1).currentFee, issuer1IncreasedSchemaFee, "Current fee unchanged");
        assertEq(paymentsController.getSchema(schemaId1).nextFee, issuer1IncreasedSchemaFeeV2, "Next fee should be increased");
        assertEq(paymentsController.getSchema(schemaId1).nextFeeTimestamp, block.timestamp + newDelayPeriod, "Next fee timestamp should be increased");
    }

    // ------- negative tests: updateFeeIncreaseDelayPeriod() ---------

        function testCannot_NonAdmin_UpdateFeeIncreaseDelayPeriod() public {
            uint128 newDelayPeriod = 28 days;
            
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
            vm.prank(verifier1);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }

        function testCannot_UpdateFeeIncreaseDelayPeriod_WhenZero() public {
            uint128 newDelayPeriod = 0;
            
            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }

        function testCannot_UpdateFeeIncreaseWithNonEpochPeriod() public {
            uint128 newDelayPeriod = 27 days;
            
            vm.expectRevert(Errors.InvalidDelayPeriod.selector);
            vm.prank(paymentsControllerAdmin);
            paymentsController.updateFeeIncreaseDelayPeriod(newDelayPeriod);
        }

    // ------ state transition --------

        function testCan_CronJobAdmin_GrantRole_CronJob() public {
            // Verify cronJobAdmin has CRON_JOB_ADMIN_ROLE
            bool hasCronJobAdminRole = paymentsController.hasRole(paymentsController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin);
            assertTrue(hasCronJobAdminRole, "cronJobAdmin should have CRON_JOB_ADMIN_ROLE");

            // verify cronjob has no CRON_JOB_ROLE
            bool hasCronJobRole = paymentsController.hasRole(paymentsController.CRON_JOB_ROLE(), cronJob);
            assertFalse(hasCronJobRole, "CronJob should not have CRON_JOB_ROLE");
            
            // setup cronJob role
            vm.startPrank(cronJobAdmin);
            paymentsController.grantRole(paymentsController.CRON_JOB_ROLE(), cronJob);
            vm.stopPrank();

            hasCronJobRole = paymentsController.hasRole(paymentsController.CRON_JOB_ROLE(), cronJob);
            assertTrue(hasCronJobRole, "CronJob should have CRON_JOB_ROLE");
        }
}


//note: issuer1 increases schema1's fee to 40 USD8 (2x increase) | cronJob receives CRON_JOB_ROLE
abstract contract StateT19_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay is StateT18_PaymentsControllerAdminIncreasesFeeIncreaseDelayPeriod {

    uint128 public issuer1IncreasedSchemaFeeV2;
    uint128 public newNextFeeTimestamp;

    function setUp() public virtual override {
        super.setUp();

        issuer1IncreasedSchemaFeeV2 = issuer1IncreasedSchemaFee * 2;

        //issuer1 increases fees
        vm.prank(issuer1);
        paymentsController.updateSchemaFee(schemaId1, issuer1IncreasedSchemaFeeV2);
        
        newNextFeeTimestamp = uint128(block.timestamp + newDelayPeriod);

        vm.warp(newNextFeeTimestamp);

        // setup cronJob role
        vm.startPrank(cronJobAdmin);
        paymentsController.grantRole(paymentsController.CRON_JOB_ROLE(), cronJob);
        vm.stopPrank();
    }
}

contract StateT19_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay_Test is StateT19_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay {
    using stdStorage for StdStorage;

    function testCan_Schema1_StorageState_AfterNewDelayPeriodAndFeeIncrease_BeforeDeductBalance() public view {
        //record schema state - the new fee should not be active yet, as deductBalance has not been called
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        assertEq(schemaBefore.currentFee, issuer1IncreasedSchemaFee, "Current fee unchanged");
        assertEq(schemaBefore.nextFee, issuer1IncreasedSchemaFeeV2, "Next fee should be increased");
        assertEq(schemaBefore.nextFeeTimestamp, newNextFeeTimestamp, "Next fee timestamp should be increased");
    }

    function testCan_DeductBalanceForSchema1_AfterNewDelayPeriodAndFeeIncrease() public {
        //record schema state - the new fee should now be active after the delay period
        DataTypes.Schema memory schemaBefore = paymentsController.getSchema(schemaId1);
        assertEq(schemaBefore.currentFee, issuer1IncreasedSchemaFee, "Current fee should still be previous fee");
        assertEq(schemaBefore.nextFee, issuer1IncreasedSchemaFeeV2, "Next fee should still be set, not applied yet");
        assertEq(schemaBefore.nextFeeTimestamp, newNextFeeTimestamp, "Next fee timestamp should still be set");
        
        // Record verifier balance before
        uint128 verifierBalanceBefore = paymentsController.getVerifier(verifier1).currentBalance;
        // Record issuer's accumulated fees before
        uint128 issuerNetFeesAccruedBefore = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;

        // Record epoch fees before
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        DataTypes.FeesAccrued memory epochFeesBefore = paymentsController.getEpochFeesAccrued(currentEpoch);
        uint128 protocolFeesBefore = epochFeesBefore.feesAccruedToProtocol;
        uint128 votersFeesBefore = epochFeesBefore.feesAccruedToVoters;
        
        // Generate signature with the new fee amount
        uint128 amount = issuer1IncreasedSchemaFeeV2;
        uint256 expiry = block.timestamp + 1000;
        uint256 nonce = getVerifierNonce(verifier1NewSigner, user1);
        bytes memory signature = generateDeductBalanceSignature(verifier1NewSignerPrivateKey, issuer1, verifier1, schemaId1, user1, amount, expiry, nonce);  
            
        // Expect SchemaFeeIncreased event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaFeeIncreased(schemaId1, issuer1IncreasedSchemaFee, issuer1IncreasedSchemaFeeV2);

        // Expect BalanceDeducted event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.BalanceDeducted(verifier1, schemaId1, issuer1, amount);
        
        // Expect SchemaVerified event
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.SchemaVerified(schemaId1);
        
        // Execute deductBalance with new fee
        vm.prank(verifier1Asset);
        paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
        
        // Calculate fee splits
        uint256 protocolFee = (amount * paymentsController.PROTOCOL_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 votingFee = (amount * paymentsController.VOTING_FEE_PERCENTAGE()) / Constants.PRECISION_BASE;
        uint256 issuerFee = amount - protocolFee - votingFee;
        
        // Verify verifier balance decreased by new fee amount
        uint128 verifierBalanceAfter = paymentsController.getVerifier(verifier1).currentBalance;
        assertEq(verifierBalanceAfter, verifierBalanceBefore - amount, "Verifier balance not decreased correctly");
        
        // Verify fee splits
        DataTypes.FeesAccrued memory epochFeesAfter = paymentsController.getEpochFeesAccrued(currentEpoch);
        assertEq(epochFeesAfter.feesAccruedToProtocol, protocolFeesBefore + protocolFee, "Protocol fees not accrued correctly");
        assertEq(epochFeesAfter.feesAccruedToVoters, votersFeesBefore + votingFee, "Voting fees not accrued correctly");
        
        // Verify issuer balance increased
        assertEq(paymentsController.getIssuer(issuer1).totalNetFeesAccrued, issuerNetFeesAccruedBefore + issuerFee, "Issuer balance not increased correctly");
        
        // Verify schema fee has been updated after deductBalance
        DataTypes.Schema memory schemaAfter = paymentsController.getSchema(schemaId1);
        assertEq(schemaAfter.totalVerified, 3, "Schema totalVerified not incremented");
        assertEq(schemaAfter.currentFee, issuer1IncreasedSchemaFeeV2, "Current fee should be updated after deductBalance");
        assertEq(schemaAfter.nextFee, 0, "Next fee should be cleared after update");
        assertEq(schemaAfter.nextFeeTimestamp, 0, "Next fee timestamp should be cleared after update");
    }

    // state transition
    function testCannot_PaymentsControllerAdmin_WithdrawProtocolFees_NoTreasuryAddressSet() public {
        // modify storage to set paymentsController.TREASURY() to address(0)
        stdstore
            .target(address(paymentsController))
            .sig("PAYMENTS_CONTROLLER_TREASURY()")  
            .checked_write(address(0));
        assertTrue(paymentsController.PAYMENTS_CONTROLLER_TREASURY() == address(0), "Treasury address should be 0");

        uint256 protocolFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToProtocol;
        assertTrue(protocolFees > 0, "Protocol fees should be greater than 0");

        // Move to next epoch (required for withdrawal)
        skip(14 days);

        vm.expectRevert(Errors.InvalidAddress.selector);

        // Execute deduction
        vm.prank(cronJob);
        paymentsController.withdrawProtocolFees(0);
    }

    function testCannot_PaymentsControllerAdmin_WithdrawVotersFees_NoTreasuryAddressSet() public {
        // modify storage to set paymentsController.TREASURY() to address(0)
        stdstore
            .target(address(paymentsController))
            .sig("PAYMENTS_CONTROLLER_TREASURY()")  
            .checked_write(address(0));
        assertTrue(paymentsController.PAYMENTS_CONTROLLER_TREASURY() == address(0), "Treasury address should be 0");

        uint256 votersFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToVoters;
        assertTrue(votersFees > 0, "Voters fees should be greater than 0");

        // Move to next epoch (required for withdrawal)
        skip(14 days);

        vm.expectRevert(Errors.InvalidAddress.selector);

        // Execute deduction
        vm.prank(cronJob);
        paymentsController.withdrawVotersFees(0);
    }
}


//note: test withdraw functions: protocol and voters fees
abstract contract StateT20_PaymentsControllerAdminWithdrawsProtocolFees is StateT19_DeductBalanceCalledForSchema1AfterFeeIncreaseAndNewDelay {

    function setUp() public virtual override {
        super.setUp();

        vm.warp(20);
    }
}

contract StateT20_PaymentsControllerAdminWithdrawsProtocolFees_Test is StateT20_PaymentsControllerAdminWithdrawsProtocolFees {
    
    function testCan_CronJob_WithdrawProtocolFees() public {
        // before
        uint128 protocolFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToProtocol;
        assertTrue(protocolFees > 0, "Protocol fees should be greater than 0");
        assertEq(mockUSD8.balanceOf(paymentsControllerTreasury), 0, "treasury has 0 USD8");
        assertEq(paymentsController.getEpochFeesAccrued(0).isProtocolFeeWithdrawn, false, "Protocol fees should not be withdrawn");

        // Check TOTAL_PROTOCOL_FEES_UNCLAIMED before
        uint256 beforeTotalProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
        assertTrue(beforeTotalProtocolFeesUnclaimed >= protocolFees, "TOTAL_PROTOCOL_FEES_UNCLAIMED should be >= protocolFees");


        // Warp to epoch 1 so epoch 0 becomes a past epoch
        vm.warp(block.timestamp + 14 days);

        // Expect event emission
        vm.expectEmit(true, true, true, true);
        emit Events.ProtocolFeesWithdrawn(0, protocolFees);

        vm.prank(cronJob);
        paymentsController.withdrawProtocolFees(0);

        assertEq(paymentsController.getEpochFeesAccrued(0).feesAccruedToProtocol, protocolFees, "Protocol fees should be non-zero");
        assertEq(paymentsController.getEpochFeesAccrued(0).isProtocolFeeWithdrawn, true, "Protocol fees should be withdrawn");

        assertEq(mockUSD8.balanceOf(paymentsControllerTreasury), protocolFees, "Protocol fees should be transferred to treasury");

        // Check TOTAL_PROTOCOL_FEES_UNCLAIMED after
        uint256 afterTotalProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
        assertEq(afterTotalProtocolFeesUnclaimed, beforeTotalProtocolFeesUnclaimed - protocolFees, "TOTAL_PROTOCOL_FEES_UNCLAIMED should decrease by protocolFees");
    }

    function testCan_CronJob_WithdrawVotersFees() public {
        // before
        uint128 votersFees = paymentsController.getEpochFeesAccrued(0).feesAccruedToVoters;
        assertTrue(votersFees > 0, "Voters fees should be greater than 0");
        assertEq(mockUSD8.balanceOf(paymentsControllerTreasury), 0, "treasury has 0 USD8");
        assertEq(paymentsController.getEpochFeesAccrued(0).isVotersFeeWithdrawn, false, "Voters fees should not be withdrawn");

        // Check TOTAL_VOTING_FEES_UNCLAIMED before
        uint256 beforeTotalVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();
        assertTrue(beforeTotalVotingFeesUnclaimed >= votersFees, "TOTAL_VOTING_FEES_UNCLAIMED should be >= votersFees");

        // Warp to epoch 1 so epoch 0 becomes a past epoch
        vm.warp(block.timestamp + 14 days);

        // Expect event emission
        vm.expectEmit(true, true, true, true);
        emit Events.VotersFeesWithdrawn(0, votersFees);

        vm.prank(cronJob);
        paymentsController.withdrawVotersFees(0);

        assertEq(paymentsController.getEpochFeesAccrued(0).feesAccruedToVoters, votersFees, "Voters fees should be non-zero");
        assertEq(paymentsController.getEpochFeesAccrued(0).isVotersFeeWithdrawn, true, "Voters fees should be withdrawn");

        assertEq(mockUSD8.balanceOf(paymentsControllerTreasury), votersFees, "Voters fees should be transferred to treasury");

        // Check TOTAL_VOTING_FEES_UNCLAIMED after
        uint256 afterTotalVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();
        assertEq(afterTotalVotingFeesUnclaimed, beforeTotalVotingFeesUnclaimed - votersFees, "TOTAL_VOTING_FEES_UNCLAIMED should decrease by votersFees");
    }

    // ------ negative tests: withdrawProtocolFees -------

        // withdrawing for future epoch
        function testCannot_CronJob_WithdrawProtocolFees_InvalidEpoch() public {
            
            vm.expectRevert(Errors.InvalidEpoch.selector);
            vm.prank(cronJob);
            paymentsController.withdrawProtocolFees(10);
        }

        function testCannot_CronJob_WithdrawProtocolFees_AlreadyWithdrawn() public {
            testCan_CronJob_WithdrawProtocolFees();

            vm.expectRevert(Errors.ProtocolFeeAlreadyWithdrawn.selector);
            vm.prank(cronJob);
            paymentsController.withdrawProtocolFees(0);
        }

        function testCannot_CronJob_WithdrawProtocolFees_ZeroProtocolFees() public {
            // Warp to epoch 3 so epoch 2 becomes a valid past epoch with zero fees
            vm.warp(block.timestamp + (3 * 14 days));
            
            // Epoch 2 has zero protocol fees (no deductions occurred in epoch 2)
            vm.expectRevert(Errors.ZeroProtocolFee.selector);
            vm.prank(cronJob);
            paymentsController.withdrawProtocolFees(2);
        }

    // ------ negative tests: withdrawVotersFees -------

        // withdrawing for future epoch
        function testCannot_CronJob_WithdrawVotersFees_InvalidEpoch() public {
            
            vm.expectRevert(Errors.InvalidEpoch.selector);
            vm.prank(cronJob);
            paymentsController.withdrawVotersFees(10);
        }

        function testCannot_CronJob_WithdrawVotersFees_AlreadyWithdrawn() public {
            testCan_CronJob_WithdrawVotersFees();

            vm.expectRevert(Errors.VotersFeeAlreadyWithdrawn.selector);
            vm.prank(cronJob);
            paymentsController.withdrawVotersFees(0);
        }

        function testCannot_CronJob_WithdrawVotersFees_ZeroVotersFees() public {
            // Warp to epoch 3 so epoch 2 becomes a valid past epoch with zero fees
            vm.warp(block.timestamp + 3 * 14 days);
            
            // Epoch 2 has zero voters fees (no deductions occurred in epoch 2)
            vm.expectRevert(Errors.ZeroVotersFee.selector);
            vm.prank(cronJob);
            paymentsController.withdrawVotersFees(EpochMath.getCurrentEpochNumber() - 1);
        }


    
    // ----- state transition: pause -------

        function testCannot_ArbitraryAddressCannotPauseContract() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.MONITOR_ROLE()));
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


//note: pause contract
abstract contract StateT21_PaymentsControllerAdminFreezesContract is StateT20_PaymentsControllerAdminWithdrawsProtocolFees {

    function setUp() public virtual override {
        super.setUp();

        vm.prank(monitor);
        paymentsController.pause();
    }
}

contract StateT21_PaymentsControllerAdminFreezesContract_Test is StateT21_PaymentsControllerAdminFreezesContract {

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
                paymentsController.createSchema(100 * 1e6);
            }

            function test_updateSchemaFee_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1);
                paymentsController.updateSchemaFee(schemaId1, 200 * 1e6);
            }

            function test_claimFees_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(issuer1Asset);
                paymentsController.claimFees(issuer1);
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
                paymentsController.deposit(verifier1, 100 * 1e6);
            }

            function test_withdraw_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.withdraw(verifier1, 50 * 1e6);
            }

            function test_updateSignerAddress_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1);
                paymentsController.updateSignerAddress(makeAddr("newSigner"));
            }

            function test_stakeMoca_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.stakeMoca{value: 10 ether}(verifier1);
            }

            function test_unstakeMoca_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.unstakeMoca(verifier1, 5 ether);
            }

            function test_updateVerifierUnstakeDelayPeriod_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updateVerifierUnstakeDelayPeriod(2 days);
            }

        // ------ Common functions for issuer and verifier ------

            function test_updateAssetManagerAddress_worksWhenPaused() public {
                address newAddr = makeAddr("newAssetManagerAddress");
                vm.prank(issuer1);
                address result = paymentsController.updateAssetManagerAddress(newAddr, true);
                assertEq(result, newAddr);
            }

        // ------ UniversalVerificationContract functions ------
            function test_deductBalance_revertsWhenPaused() public {
                // Generate a valid signature
                uint128 amount = issuer1SchemaFee;
                uint256 expiry = block.timestamp + 1000;
                uint256 nonce = getVerifierNonce(verifier1Signer, user1);
                bytes memory signature = generateDeductBalanceSignature(
                    verifier1SignerPrivateKey,
                    issuer1,
                    verifier1,
                    schemaId1,
                    user1,
                    amount,
                    expiry,
                    nonce
                );

                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Asset);
                paymentsController.deductBalance(verifier1, user1, schemaId1, amount, expiry, signature);
            }

            function test_deductBalanceZeroFee_revertsWhenPaused() public {
                // Generate a valid signature
                uint256 expiry = block.timestamp + 1000;
                uint256 nonce = getVerifierNonce(verifier1Signer, user1);
                bytes memory signature = generateDeductBalanceZeroFeeSignature(
                    verifier1SignerPrivateKey,
                    issuer1,
                    verifier1,
                    schemaId3, // assuming schemaId3 has zero fee
                    user1,
                    expiry,
                    nonce
                );

                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(verifier1Signer);
                paymentsController.deductBalanceZeroFee(verifier1, schemaId3, user1, expiry, signature);
            }

        // ---- Admin update functions ----
            function test_updatePoolId_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.updatePoolId(schemaId1, uint128(123));
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

            function test_setVerifierSubsidyTiers_revertsWhenPaused() public {
                // create arrays
                uint128[] memory mocaStaked = new uint128[](1);
                uint128[] memory subsidies = new uint128[](1);
                mocaStaked[0] = 10 ether;
                subsidies[0] = 1000;

                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.setVerifierSubsidyTiers(mocaStaked, subsidies);
            }

            function test_clearVerifierSubsidyTiers_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(paymentsControllerAdmin);
                paymentsController.clearVerifierSubsidyTiers();
            }

        // ---- Admin withdraw functions ----
            function test_withdrawProtocolFees_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(cronJob);
                paymentsController.withdrawProtocolFees(0);
            }

            function test_withdrawVotersFees_revertsWhenPaused() public {
                vm.expectRevert(Pausable.EnforcedPause.selector);
                vm.prank(cronJob);
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
                paymentsController.emergencyExitVerifiers(new address[](1));
            }

            function test_emergencyExitIssuers_revertsWhenPaused() public {
                vm.expectRevert(Errors.NotFrozen.selector);
                vm.prank(emergencyExitHandler);
                paymentsController.emergencyExitIssuers(new address[](1));
            }


    // ------ Functions that should NOT revert when paused -------

        // View functions should still work when paused
        function test_ViewFunctions_WorkWhenPaused() public {
            // View and getter functions should be callable when paused
            paymentsController.getIssuer(issuer1);
            paymentsController.getSchema(schemaId1);
            paymentsController.getVerifier(verifier1);
            paymentsController.getVerifierNonce(verifier1Signer, user1);
            paymentsController.getEligibleSubsidyPercentage(10 ether);
            paymentsController.getAllSubsidyTiers();
            
            // getSubsidyTier
            DataTypes.SubsidyTier memory subsidyTier = paymentsController.getSubsidyTier(0);
            assertEq(subsidyTier.mocaStaked, 10 ether, "mocaStaked mismatch");
            assertEq(subsidyTier.subsidyPercentage, 1100, "subsidyPercentage mismatch");

            vm.expectRevert(Errors.InvalidIndex.selector);
            paymentsController.getSubsidyTier(11);

            // getVerifierAndPoolAccruedSubsidies expects asset manager as 'caller'
            // Get the actual asset manager address from the verifier
            DataTypes.Verifier memory v1 = paymentsController.getVerifier(verifier1);
            (uint256 verifierAccrued, uint256 poolAccrued) =
                paymentsController.getVerifierAndPoolAccruedSubsidies(0, poolId1, verifier1, v1.assetManagerAddress);
            assertEq(verifierAccrued, 0, "verifier accrued subsidy mismatch");
            assertEq(poolAccrued, 0, "pool accrued subsidy mismatch");

            // getEpochPoolSubsidies & getEpochPoolVerifierSubsidies
            uint256 epochPoolSubsidies = paymentsController.getEpochPoolSubsidies(0, poolId1);
            assertEq(epochPoolSubsidies, 0, "epochPoolSubsidies mismatch");

            uint256 epochPoolVerifierSubsidies = paymentsController.getEpochPoolVerifierSubsidies(0, poolId1, verifier1);
            assertEq(epochPoolVerifierSubsidies, 0, "epochPoolVerifierSubsidies mismatch");

            // getEpochPoolFeesAccrued and getEpochFeesAccrued
            DataTypes.FeesAccrued memory epochPoolFees = paymentsController.getEpochPoolFeesAccrued(0, poolId1);
            assertEq(epochPoolFees.feesAccruedToProtocol, 0, "feesAccruedToProtocol mismatch");
            assertEq(epochPoolFees.feesAccruedToVoters, 0, "feesAccruedToVoters mismatch");

            DataTypes.FeesAccrued memory epochFees = paymentsController.getEpochFeesAccrued(0);
            assertEq(epochFees.feesAccruedToProtocol, 500000, "feesAccruedToProtocol mismatch");
            assertEq(epochFees.feesAccruedToVoters, 1000000, "feesAccruedToVoters mismatch");

            // getIssuerSchemaNonce
            uint256 issuerSchemaNonce = paymentsController.getIssuerSchemaNonce(makeAddr("0xdead"));
            assertEq(issuerSchemaNonce, 0, "issuerSchemaNonce mismatch");


            // checkIfPoolIsWhitelisted
            bool isWhitelisted = paymentsController.checkIfPoolIsWhitelisted(poolId1);
            assertEq(isWhitelisted, true, "isWhitelisted mismatch");



            // test direct public variable getter reads
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


abstract contract StateT22_PaymentsControllerAdminFreezesContract is StateT21_PaymentsControllerAdminFreezesContract {

    function setUp() public virtual override {
        super.setUp();

        vm.prank(globalAdmin);
        paymentsController.freeze();
    }
}

contract StateT22_PaymentsControllerAdminFreezesContract_Test is StateT22_PaymentsControllerAdminFreezesContract {
    
    // ------ Contract frozen: no fns can be called except: emergencyExits -------
        
        function testCannot_GlobalAdmin_Unpause() public {
            vm.expectRevert(Errors.IsFrozen.selector);
            vm.prank(globalAdmin);
            paymentsController.unpause();
        }

    // ------ emergencyExitVerifiers ------

        function testCannot_ArbitraryAddressCall_EmergencyExitVerifiers() public {
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandlerOrVerifier.selector);
            vm.prank(verifier1);
            paymentsController.emergencyExitVerifiers(new address[](1));
        }

        function testCannot_EmergencyExitHandlerCall_EmergencyExitVerifiers_InvalidArray() public {
            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(new address[](0));
        }

        function testCannot_EmergencyExitVerifiers_ValidVerifierId_ButZeroBalance() public {
            testCan_EmergencyExitHandler_EmergencyExitVerifiers();
            
            // Prepare the verifierIds array
            address[] memory verifierIds = new address[](3);
            verifierIds[0] = verifier1;
            verifierIds[1] = verifier2;
            verifierIds[2] = verifier3;

            // Record balances before
            uint256 beforeBalance = mockUSD8.balanceOf(address(paymentsController));

            // Start recording logs/events
            vm.recordLogs();

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(verifierIds);

            // Stop recording and retrieve logs
            Vm.Log[] memory entries = vm.getRecordedLogs();

            // Assert that no logs (events) were emitted
            assertEq(entries.length, 0, "No event should be emitted for zero balance");

            // Record balances after
            uint256 afterBalance = mockUSD8.balanceOf(address(paymentsController));

            // Assert that no assets were transferred
            assertEq(afterBalance, beforeBalance, "No assets should be transferred for zero balance");
        }

        function testCan_EmergencyExitHandler_EmergencyExitVerifiers() public {
            // Prepare verifierIds array with verifier1, verifier2, verifier3
            address[] memory verifierIds = new address[](3);
            verifierIds[0] = verifier1;
            verifierIds[1] = verifier2;
            verifierIds[2] = verifier3;

            // Get current asset addresses from the contract (they may have been updated)
            address currentAsset1 = paymentsController.getVerifier(verifier1).assetManagerAddress;
            address currentAsset2 = paymentsController.getVerifier(verifier2).assetManagerAddress;  
            address currentAsset3 = paymentsController.getVerifier(verifier3).assetManagerAddress;

            // Record pre-exit contract balances for each verifier
            uint256 beforeVerifier1ContractBalance = paymentsController.getVerifier(verifier1).currentBalance;
            uint256 beforeVerifier2ContractBalance = paymentsController.getVerifier(verifier2).currentBalance;
            uint256 beforeVerifier3ContractBalance = paymentsController.getVerifier(verifier3).currentBalance;

            // Record pre-exit USD8 balances for each verifier
            uint256 beforeVerifier1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 beforeVerifier2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 beforeVerifier3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Record pre-exit MOCA staked for each verifier
            uint256 beforeVerifier1MocaStaked = paymentsController.getVerifier(verifier1).mocaStaked;
            uint256 beforeVerifier2MocaStaked = paymentsController.getVerifier(verifier2).mocaStaked;
            uint256 beforeVerifier3MocaStaked = paymentsController.getVerifier(verifier3).mocaStaked;

            // Record pre-exit MOCA balances for each verifier
            uint256 beforeVerifier1MOCABalance = currentAsset1.balance;
            uint256 beforeVerifier2MOCABalance = currentAsset2.balance;
            uint256 beforeVerifier3MOCABalance = currentAsset3.balance;

            // Expect the EmergencyExitVerifiers event to be emitted
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitVerifiers(verifierIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(verifierIds);

            // Record post-exit contract balances for each verifier
            uint256 afterVerifier1ContractBalance = paymentsController.getVerifier(verifier1).currentBalance;
            uint256 afterVerifier2ContractBalance = paymentsController.getVerifier(verifier2).currentBalance;
            uint256 afterVerifier3ContractBalance = paymentsController.getVerifier(verifier3).currentBalance;

            // Record post-exit USD8 balances for each verifier
            uint256 afterVerifier1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 afterVerifier2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 afterVerifier3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Record post-exit Moca balances for each verifier
            uint256 afterVerifier1MOCABalance = currentAsset1.balance;
            uint256 afterVerifier2MOCABalance = currentAsset2.balance;
            uint256 afterVerifier3MOCABalance = currentAsset3.balance;

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

        function testCan_EmergencyExitHandler_EmergencyExitVerifiers_SkipsZeroBalanceEntries() public {
            address zeroVerifier = makeAddr("zeroVerifier");

            // verifier1 has funds; zeroVerifier is unregistered/zero balances
            address[] memory verifierIds = new address[](2);
            verifierIds[0] = verifier1;
            verifierIds[1] = zeroVerifier;

            DataTypes.Verifier memory v1Before = paymentsController.getVerifier(verifier1);
            uint256 controllerUSD8Before = mockUSD8.balanceOf(address(paymentsController));
            uint256 zeroVerifierUSD8Before = mockUSD8.balanceOf(zeroVerifier);
            uint256 zeroVerifierMocaBefore = zeroVerifier.balance;

            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitVerifiers(verifierIds);

            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitVerifiers(verifierIds);

            DataTypes.Verifier memory v1After = paymentsController.getVerifier(verifier1);
            assertEq(v1After.currentBalance, 0, "verifier1 USD8 should be exited");
            assertEq(v1After.mocaStaked, 0, "verifier1 MOCA should be exited");

            uint256 controllerUSD8After = mockUSD8.balanceOf(address(paymentsController));
            assertEq(controllerUSD8Before - v1Before.currentBalance, controllerUSD8After, "Controller should reduce by verifier1 balance only");

            // zeroVerifier remains untouched
            assertEq(mockUSD8.balanceOf(zeroVerifier), zeroVerifierUSD8Before, "zeroVerifier USD8 should remain unchanged");
            assertEq(zeroVerifier.balance, zeroVerifierMocaBefore, "zeroVerifier native balance should remain unchanged");
        }

    // ------ emergencyExitIssuers ------

        function testCannot_ArbitraryAddressCall_EmergencyExitIssuers() public {
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandlerOrIssuer.selector);
            vm.prank(issuer1);
            paymentsController.emergencyExitIssuers(new address[](1));
        }

        function testCannot_EmergencyExitHandlerCall_EmergencyExitIssuers_InvalidArray() public {
            vm.expectRevert(Errors.InvalidArray.selector);
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(new address[](0));
        }

        //Note: invalid ids get skipped, but are emitted in the event
        // Test that no event is emitted when calling emergencyExitIssuers with an invalid issuerId.
        function testNoEventEmitted_EmergencyExitHandlerCall_EmergencyExitIssuers_InvalidIssuerId() public {
            // Provide an issuerId that is not registered (e.g., random bytes32)
            address invalidIssuerId = makeAddr("invalidIssuer");
            address[] memory issuerIds = new address[](1);
            issuerIds[0] = invalidIssuerId;

            // Record contract's token balance before
            uint256 beforeUSD8Balance = mockUSD8.balanceOf(address(paymentsController));

            // Start recording logs/events
            vm.recordLogs();

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(issuerIds);

            // Stop recording and retrieve logs
            Vm.Log[] memory entries = vm.getRecordedLogs();

            // Assert that no logs (events) were emitted
            assertEq(entries.length, 0, "No event should be emitted for invalid issuerId");

            // Record contract's token balance after
            uint256 afterUSD8Balance = mockUSD8.balanceOf(address(paymentsController));

            // Assert that no tokens were transferred
            assertEq(afterUSD8Balance, beforeUSD8Balance, "No tokens should be transferred for invalid issuerId");
        }

        function testCannot_EmergencyExitIssuers_ValidIssuerId_ButZeroUnclaimedBalance() public {
            // First run emergency exit to ensure issuers have zero unclaimed balance
            testCan_EmergencyExitHandler_EmergencyExitIssuers();
            
            // Prepare the issuerIds array
            address[] memory issuerIds = new address[](3);
            issuerIds[0] = issuer1;
            issuerIds[1] = issuer2;
            issuerIds[2] = issuer3; 

            // Record balances before
            uint256 beforeBalance = mockUSD8.balanceOf(address(paymentsController));

            // Start recording logs/events
            vm.recordLogs();

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(issuerIds);

            // Stop recording and retrieve logs
            Vm.Log[] memory entries = vm.getRecordedLogs();

            // Assert that no logs (events) were emitted
            assertEq(entries.length, 0, "No event should be emitted for zero unclaimed balance");

            // Record balances after
            uint256 afterBalance = mockUSD8.balanceOf(address(paymentsController));

            // Assert that no tokens were transferred
            assertEq(afterBalance, beforeBalance, "No tokens should be transferred for zero unclaimed balance");
        }

        function testCan_EmergencyExitHandler_EmergencyExitIssuers() public {
            // Prepare issuerIds array with issuer1, issuer2, issuer3
            address[] memory issuerIds = new address[](3);
            issuerIds[0] = issuer1;
            issuerIds[1] = issuer2;
            issuerIds[2] = issuer3;

            // Get current asset addresses from the contract (they may have been updated)
            address currentAsset1 = paymentsController.getIssuer(issuer1).assetManagerAddress;
            address currentAsset2 = paymentsController.getIssuer(issuer2).assetManagerAddress;
            address currentAsset3 = paymentsController.getIssuer(issuer3).assetManagerAddress;

            // Record pre-exit unclaimed fees for each issuer
            uint256 beforeIssuer1UnclaimedFees = paymentsController.getIssuer(issuer1).totalNetFeesAccrued - paymentsController.getIssuer(issuer1).totalClaimed;
            uint256 beforeIssuer2UnclaimedFees = paymentsController.getIssuer(issuer2).totalNetFeesAccrued - paymentsController.getIssuer(issuer2).totalClaimed;
            uint256 beforeIssuer3UnclaimedFees = paymentsController.getIssuer(issuer3).totalNetFeesAccrued - paymentsController.getIssuer(issuer3).totalClaimed;

            // Record pre-exit USD8 balances for each issuer asset address
            uint256 beforeIssuer1USD8Balance = mockUSD8.balanceOf(currentAsset1);
            uint256 beforeIssuer2USD8Balance = mockUSD8.balanceOf(currentAsset2);
            uint256 beforeIssuer3USD8Balance = mockUSD8.balanceOf(currentAsset3);

            // Record pre-exit totalClaimed for each issuer
            uint256 beforeIssuer1TotalClaimed = paymentsController.getIssuer(issuer1).totalClaimed;
            uint256 beforeIssuer2TotalClaimed = paymentsController.getIssuer(issuer2).totalClaimed;
            uint256 beforeIssuer3TotalClaimed = paymentsController.getIssuer(issuer3).totalClaimed;

            // Record totalNetFeesAccrued for verification after
            uint256 issuer1TotalNetFeesAccrued = paymentsController.getIssuer(issuer1).totalNetFeesAccrued;
            uint256 issuer2TotalNetFeesAccrued = paymentsController.getIssuer(issuer2).totalNetFeesAccrued;
            uint256 issuer3TotalNetFeesAccrued = paymentsController.getIssuer(issuer3).totalNetFeesAccrued;

            // Expect the EmergencyExitIssuers event to be emitted
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitIssuers(issuerIds);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitIssuers(issuerIds);

            // Record post-exit totalClaimed for each issuer
            uint256 afterIssuer1TotalClaimed = paymentsController.getIssuer(issuer1).totalClaimed;
            uint256 afterIssuer2TotalClaimed = paymentsController.getIssuer(issuer2).totalClaimed;
            uint256 afterIssuer3TotalClaimed = paymentsController.getIssuer(issuer3).totalClaimed;

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
            uint256 afterIssuer1UnclaimedFees = paymentsController.getIssuer(issuer1).totalNetFeesAccrued - paymentsController.getIssuer(issuer1).totalClaimed;
            uint256 afterIssuer2UnclaimedFees = paymentsController.getIssuer(issuer2).totalNetFeesAccrued - paymentsController.getIssuer(issuer2).totalClaimed;
            uint256 afterIssuer3UnclaimedFees = paymentsController.getIssuer(issuer3).totalNetFeesAccrued - paymentsController.getIssuer(issuer3).totalClaimed;
            
            assertEq(afterIssuer1UnclaimedFees, 0, "issuer1 should have zero unclaimed fees after emergency exit");
            assertEq(afterIssuer2UnclaimedFees, 0, "issuer2 should have zero unclaimed fees after emergency exit");
            assertEq(afterIssuer3UnclaimedFees, 0, "issuer3 should have zero unclaimed fees after emergency exit");
        }

    // ------ emergencyExitFees ------

        function testCannot_ArbitraryAddressCall_EmergencyExitFees() public {
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1, paymentsController.EMERGENCY_EXIT_HANDLER_ROLE()));
            vm.prank(verifier1);
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
            address treasuryAddress = paymentsController.PAYMENTS_CONTROLLER_TREASURY();
            assertTrue(treasuryAddress != address(0), "Treasury address should not be zero");

            // Record pre-exit unclaimed fees
            uint256 beforeProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
            uint256 beforeVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();
            uint256 totalUnclaimedFees = beforeProtocolFeesUnclaimed + beforeVotingFeesUnclaimed;
            
            // Ensure there are fees to claim (from previous state transitions)
            assertGt(totalUnclaimedFees, 0, "Should have unclaimed fees from previous transactions");

            // Record pre-exit treasury balance
            uint256 beforeTreasuryBalance = mockUSD8.balanceOf(paymentsControllerTreasury);

            // Record contract balance before
            uint256 beforeContractBalance = mockUSD8.balanceOf(address(paymentsController));

            // Expect the EmergencyExitFees event to be emitted
            vm.expectEmit(true, false, false, true, address(paymentsController));
            emit Events.EmergencyExitFees(paymentsControllerTreasury, totalUnclaimedFees);

            // Call as emergencyExitHandler
            vm.prank(emergencyExitHandler);
            paymentsController.emergencyExitFees();

            // Record post-exit unclaimed fees
            uint256 afterProtocolFeesUnclaimed = paymentsController.TOTAL_PROTOCOL_FEES_UNCLAIMED();
            uint256 afterVotingFeesUnclaimed = paymentsController.TOTAL_VOTING_FEES_UNCLAIMED();

            // Record post-exit treasury balance
            uint256 afterTreasuryBalance = mockUSD8.balanceOf(paymentsControllerTreasury);

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

    // ------- pause and unpause should revert --------
        function testCannot_Pause_WhenFrozen() public {
            vm.expectRevert(Pausable.EnforcedPause.selector);
            vm.prank(monitor);
            paymentsController.pause();
        } 

        function testCannot_Unpause_WhenFrozen() public {
            vm.expectRevert(Errors.IsFrozen.selector);
            vm.prank(globalAdmin);
            paymentsController.unpause();
        }
}
