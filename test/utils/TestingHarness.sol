// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

// import all contracts
import {AccessController} from "../../src/AccessController.sol";
import {PaymentsController} from "../../src/PaymentsController.sol";
//import {VotingController} from "../../src/VotingController.sol";
//import {VotingEscrowMoca} from "../../src/VotingEscrowMoca.sol";
//import {EscrowedMoca} from "../../src/EscrowedMoca.sol";
import {IssuerStakingController} from "../../src/IssuerStakingController.sol";

// import all libraries
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {EpochMath} from "../../src/libraries/EpochMath.sol";

// mocks
import {MockWMoca} from "./MockWMoca.sol";
import {MockUSD8} from "./MockUSD8.sol";

// interfaces
import {IAccessController} from "../../src/interfaces/IAccessController.sol";
import {IPaymentsController} from "../../src/interfaces/IPaymentsController.sol";
import {IVotingEscrowMoca} from "../../src/interfaces/IVotingEscrowMoca.sol";
import {IEscrowedMoca} from "../../src/interfaces/IEscrowedMoca.sol";
import {IIssuerStakingController} from "../../src/interfaces/IIssuerStakingController.sol";

abstract contract TestingHarness is Test {
    using stdStorage for StdStorage;
    
    // actual contracts
    AccessController public accessController;
    PaymentsController public paymentsController;
    //VotingEscrowMoca public veMoca;
    //VotingController public votingController;
    //EscrowedMoca public esMoca;
    IssuerStakingController public issuerStakingController;

    // mocks
    MockWMoca public mockWMoca;
    MockUSD8 public mockUSD8;

    uint256 public constant MOCA_TRANSFER_GAS_LIMIT = 2300;

// ------------ Actors ------------

    // ------------ issuers ------------
    address public issuer1 = makeAddr("issuer1");
    address public issuer1Asset = makeAddr("issuer1Asset");
    address public issuer2 = makeAddr("issuer2");
    address public issuer2Asset = makeAddr("issuer2Asset");
    address public issuer3 = makeAddr("issuer3");
    address public issuer3Asset = makeAddr("issuer3Asset");

    // ------------ verifiers ------------
    //verifier1
    address public verifier1 = makeAddr("verifier1");
    address public verifier1Asset = makeAddr("verifier1Asset");
    address public verifier1Signer;
    uint256 public verifier1SignerPrivateKey;
    //verifier2
    address public verifier2 = makeAddr("verifier2");
    address public verifier2Asset = makeAddr("verifier2Asset");
    address public verifier2Signer;
    uint256 public verifier2SignerPrivateKey;
    //verifier3
    address public verifier3 = makeAddr("verifier3");
    address public verifier3Asset = makeAddr("verifier3Asset");
    address public verifier3Signer;
    uint256 public verifier3SignerPrivateKey;

    // ------------ misc. ------------
    address public treasury = makeAddr("treasury");

    // ------------ users ------------
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

// ------------ Privileged Role Addresses ------------
    // global admin
    address public globalAdmin = makeAddr("globalAdmin");
    // high-frequency role addresses
    address public monitorAdmin = makeAddr("monitorAdmin");
    address public cronJobAdmin = makeAddr("cronJobAdmin");
    address public monitor = makeAddr("monitor");   
    address public cronJob = makeAddr("cronJob");
    // strategic role addresses
    address public issuerStakingControllerAdmin = makeAddr("issuerStakingControllerAdmin");
    address public paymentsControllerAdmin = makeAddr("paymentsControllerAdmin");
    address public votingControllerAdmin = makeAddr("votingControllerAdmin");
    address public votingEscrowMocaAdmin = makeAddr("votingEscrowMocaAdmin");
    address public escrowedMocaAdmin = makeAddr("escrowedMocaAdmin");
    // asset manager addresses
    address public assetManager = makeAddr("assetManager");
    // emergency exit handler addresses
    address public emergencyExitHandler = makeAddr("emergencyExitHandler");
    
    // deployer
    address public deployer = makeAddr("deployer");

// ------------ Contract Parameters ------------

    // PaymentsController parameters
    uint256 public protocolFeePercentage = 500;      // 5%
    uint256 public voterFeePercentage = 1000;        // 10%
    uint256 public feeIncreaseDelayPeriod = 14 days; // 14 days

    // VotingController parameters
    uint256 public registrationFee = 1000;       // 1000 MOCA
    uint256 public maxDelegateFeePct = 200;      // 20%
    uint256 public delayDuration = 14 days;      // 14 days

// ------------ Contract Deployment ------------
    function setUp() public virtual {
        
        // ------------ Verifier Signers ------------
        (verifier1Signer, verifier1SignerPrivateKey) = makeAddrAndKey("verifier1Signer");
        (verifier2Signer, verifier2SignerPrivateKey) = makeAddrAndKey("verifier2Signer");
        (verifier3Signer, verifier3SignerPrivateKey) = makeAddrAndKey("verifier3Signer");

        // 0. Deploy mock contracts
        mockWMoca = new MockWMoca();
        mockUSD8 = new MockUSD8();

        // 1. Deploy access controller
        accessController = new AccessController(globalAdmin, treasury);

        // 2. Initialize roles
        vm.startPrank(globalAdmin);
            accessController.grantRole(accessController.DEFAULT_ADMIN_ROLE(), globalAdmin);
            accessController.grantRole(accessController.MONITOR_ADMIN_ROLE(), monitorAdmin);
            accessController.grantRole(accessController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin);
            accessController.grantRole(accessController.ISSUER_STAKING_CONTROLLER_ADMIN_ROLE(), issuerStakingControllerAdmin);
            accessController.grantRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin);
            accessController.grantRole(accessController.VOTING_CONTROLLER_ADMIN_ROLE(), votingControllerAdmin);
            accessController.grantRole(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE(), votingEscrowMocaAdmin);
            accessController.grantRole(accessController.ESCROWED_MOCA_ADMIN_ROLE(), escrowedMocaAdmin);
            accessController.grantRole(accessController.ASSET_MANAGER_ROLE(), assetManager);
            accessController.grantRole(accessController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler);
        vm.stopPrank();

        vm.prank(monitorAdmin);
            accessController.addMonitor(monitor);
        vm.prank(cronJobAdmin);
            accessController.addCronJob(cronJob);

        // 4. Deploy IssuerStakingController
        issuerStakingController = new IssuerStakingController(address(accessController), 7 days, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);


        // 5. Deploy PaymentsController
        paymentsController = new PaymentsController(address(accessController), protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
             address(mockWMoca), address(mockUSD8), MOCA_TRANSFER_GAS_LIMIT, "PaymentsController", "1");
    

        // 6. Deploy EscrowedMoca
        //esMoca = new EscrowedMoca(address(accessController), 1000, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT); // 10% penalty split


        // 7. Deploy VotingEscrowMoca
        //veMoca = new VotingEscrowMoca(address(accessController));
        
        // 8. Whitelist VotingEscrowMoca in EscrowedMoca for transfers
        //vm.prank(escrowedMocaAdmin);
        //esMoca.setWhitelistStatus(address(veMoca), true);

        
        // ---- Misc. ---------

        // PaymentsController: minting tokens
        mockUSD8.mint(verifier1Asset, 100 ether);
        mockUSD8.mint(verifier2Asset, 100 ether);
        mockUSD8.mint(verifier3Asset, 100 ether);
        // deal native moca to verifiers
        vm.deal(verifier1Asset, 100 ether);
        vm.deal(verifier2Asset, 100 ether);
        vm.deal(verifier3Asset, 100 ether);


    }

// ------------------------------Helper functions-----------------------------------------

    function generateLockId(uint256 salt, address user) public view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }


// ------------------------------Signature Helper Functions-----------------------------------------

    /**
     * @notice Generates an EIP-712 signature for deductBalance()
     * @param signerPrivateKey The private key of the verifier's signer
     * @param issuerId The unique identifier of the issuer
     * @param verifierId The unique identifier of the verifier
     * @param schemaId The unique identifier of the schema
     * @param amount The fee amount to deduct
     * @param expiry The signature expiry timestamp
     * @param nonce The current nonce for the signer address
     * @return signature The EIP-712 signature
     */
    function generateDeductBalanceSignature(
        uint256 signerPrivateKey,
        bytes32 issuerId,
        bytes32 verifierId,
        bytes32 schemaId,
        uint128 amount,
        uint256 expiry,
        uint256 nonce
    ) public view returns (bytes memory) {
        // EIP-712 domain separator
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PaymentsController")),
                keccak256(bytes("1")),
                block.chainid,
                address(paymentsController)
            )
        );

        // Struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                Constants.DEDUCT_BALANCE_TYPEHASH,
                issuerId,
                verifierId,
                schemaId,
                amount,
                expiry,
                nonce
            )
        );

        // EIP-712 typed data hash
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Generates an EIP-712 signature for deductBalanceZeroFee()
     * @param signerPrivateKey The private key of the verifier's signer
     * @param issuerId The unique identifier of the issuer
     * @param verifierId The unique identifier of the verifier
     * @param schemaId The unique identifier of the schema
     * @param expiry The signature expiry timestamp
     * @param nonce The current nonce for the signer address
     * @return signature The EIP-712 signature
     */
    function generateDeductBalanceZeroFeeSignature(
        uint256 signerPrivateKey,
        bytes32 issuerId,
        bytes32 verifierId,
        bytes32 schemaId,
        uint256 expiry,
        uint256 nonce
    ) public view returns (bytes memory) {
        // EIP-712 domain separator
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PaymentsController")),
                keccak256(bytes("1")),
                block.chainid,
                address(paymentsController)
            )
        );

        // Struct hash
        bytes32 structHash = keccak256(
            abi.encode(
                Constants.DEDUCT_BALANCE_ZERO_FEE_TYPEHASH,
                issuerId,
                verifierId,
                schemaId,
                expiry,
                nonce
            )
        );

        // EIP-712 typed data hash
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Helper to get verifier nonce
     * @param signerAddress The signer address of the verifier
     * @return nonce The current nonce
     */
    function getVerifierNonce(address signerAddress) public view returns (uint256) {
        return paymentsController.getVerifierNonce(signerAddress);
    }


    /// @notice Deterministically generates an unused issuerId based on issuer and salt, similar to PaymentsController
    /// @dev Tries salt, salt+1, salt+2, ... until an unused id is found.
    function generateUnusedIssuerId(address issuer) public view returns (bytes32 issuerId) {
        uint256 salt = block.number;

        issuerId = keccak256(abi.encode("ISSUER", issuer, salt));
        // Check if id is used in any mapping
        while (
            paymentsController.getIssuer(issuerId).issuerId != bytes32(0) ||
            paymentsController.getVerifier(issuerId).verifierId != bytes32(0) ||
            paymentsController.getSchema(issuerId).schemaId != bytes32(0)
        ) {
            issuerId = keccak256(abi.encode("ISSUER", issuer, ++salt));
        }
    }

    function generateUnusedVerifierId(address verifier) public view returns (bytes32 verifierId) {
        uint256 salt = block.number;
        
        verifierId = keccak256(abi.encode("VERIFIER", verifier, salt));
        // Check if id is used in any mapping
        while (
            paymentsController.getIssuer(verifierId).issuerId != bytes32(0) ||
            paymentsController.getVerifier(verifierId).verifierId != bytes32(0) ||
            paymentsController.getSchema(verifierId).schemaId != bytes32(0)
        ) {
            verifierId = keccak256(abi.encode("VERIFIER", verifier, ++salt));
        }
    }

    function generateUnusedSchemaId(bytes32 issuerId) public view returns (bytes32 schemaId) {
        // get totalSchemas for this issuer
        uint256 totalSchemas = paymentsController.getIssuer(issuerId).totalSchemas;
        uint256 salt = block.number;

        schemaId = keccak256(abi.encode("SCHEMA", issuerId, totalSchemas, salt));
        // Check if id is used in any mapping
        while (
            paymentsController.getIssuer(schemaId).issuerId != bytes32(0) ||
            paymentsController.getVerifier(schemaId).verifierId != bytes32(0) ||
            paymentsController.getSchema(schemaId).schemaId != bytes32(0)
        ) {
            schemaId = keccak256(abi.encode("SCHEMA", issuerId, totalSchemas, ++salt));
        }
    }
}

// Contract with expensive receive function
contract GasGuzzler {
    uint256[] private storageArray;
    
    receive() external payable {
        // Do multiple storage operations to consume > 2300 gas
        // First-time SSTORE costs ~20,000 gas
        // We'll do operations that definitely exceed 2300
        for (uint256 i = 0; i < 5; i++) {
            storageArray.push(block.timestamp + i);
        }
    }
}