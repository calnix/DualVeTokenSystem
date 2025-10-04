// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

// import all contracts
import {AccessController} from "../../src/AccessController.sol";
import {AddressBook} from "../../src/AddressBook.sol";
import {PaymentsController} from "../../src/PaymentsController.sol";
import {VotingController} from "../../src/VotingController.sol";
import {VotingEscrowMoca} from "../../src/VotingEscrowMoca.sol";
import {EscrowedMoca} from "../../src/EscrowedMoca.sol";

// import all libraries
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {EpochMath} from "../../src/libraries/EpochMath.sol";

// mocks
import {MockMoca} from "./MockMoca.sol";
import {MockUSD8} from "./MockUSD8.sol";

// interfaces
import {IAddressBook} from "../../src/interfaces/IAddressBook.sol";
import {IAccessController} from "../../src/interfaces/IAccessController.sol";
import {IPaymentsController} from "../../src/interfaces/IPaymentsController.sol";
import {IVotingEscrowMoca} from "../../src/interfaces/IVotingEscrowMoca.sol";
import {IEscrowedMoca} from "../../src/interfaces/IEscrowedMoca.sol";

abstract contract TestingHarness is Test {
    using stdStorage for StdStorage;
    
    // actual contracts
    AddressBook public addressBook;    
    AccessController public accessController;
    PaymentsController public paymentsController;
    VotingEscrowMoca public veMoca;
    VotingController public votingController;
    EscrowedMoca public esMoca;

    // mocks
    MockMoca public mockMoca;
    MockUSD8 public mockUSD8;

    // actors
    address public issuer1 = makeAddr("issuer1");
    address public issuer1Asset = makeAddr("issuer1Asset");
    address public issuer2 = makeAddr("issuer2");
    address public issuer2Asset = makeAddr("issuer2Asset");
    address public issuer3 = makeAddr("issuer3");
    address public issuer3Asset = makeAddr("issuer3Asset");
    address public verifier1 = makeAddr("verifier1");
    address public verifier1Asset = makeAddr("verifier1Asset");
    address public verifier1Signer = makeAddr("verifier1Signer");
    address public verifier2 = makeAddr("verifier2");
    address public verifier2Asset = makeAddr("verifier2Asset");
    address public verifier2Signer = makeAddr("verifier2Signer");
    address public verifier3 = makeAddr("verifier3");
    address public verifier3Asset = makeAddr("verifier3Asset");
    address public verifier3Signer = makeAddr("verifier3Signer");

    // users
    //address public user1 = makeAddr("user1");
    //address public user2 = makeAddr("user2");
    //address public user3 = makeAddr("user3");
    
    // privileged role addresses
    address public globalAdmin = makeAddr("globalAdmin");
    // high-frequency role addresses
    address public monitorAdmin = makeAddr("monitorAdmin");
    address public cronJobAdmin = makeAddr("cronJobAdmin");
    address public monitor = makeAddr("monitor");   
    address public cronJob = makeAddr("cronJob");
    // strategic role addresses
    address public paymentsControllerAdmin = makeAddr("paymentsControllerAdmin");
    address public votingControllerAdmin = makeAddr("votingControllerAdmin");
    address public votingEscrowMocaAdmin = makeAddr("votingEscrowMocaAdmin");
    address public escrowedMocaAdmin = makeAddr("escrowedMocaAdmin");
    // asset manager addresses
    address public assetManager = makeAddr("assetManager");
    // emergency exit handler addresses
    address public emergencyExitHandler = makeAddr("emergencyExitHandler");
    
    // deployer addresses
    address public deployer = makeAddr("deployer");

    // PaymentsController parameters
    uint256 public protocolFeePercentage = 500;   // 5%
    uint256 public voterFeePercentage = 1000;     // 10%
    uint256 public feeIncreaseDelayPeriod = 14 days; // 14 days

    // VotingController parameters
    uint256 public registrationFee = 1000;       // 1000 MOCA
    uint256 public maxDelegateFeePct = 200;      // 20%
    uint256 public delayDuration = 14 days;      // 14 days

    function setUp() public virtual {

        // deploy mock contracts
        mockMoca = new MockMoca();
        mockUSD8 = new MockUSD8();

        // deploy contracts
        addressBook = new AddressBook(globalAdmin);
        accessController = new AccessController(address(addressBook));

        // initialize roles
        vm.startPrank(globalAdmin);
            accessController.grantRole(accessController.DEFAULT_ADMIN_ROLE(), globalAdmin);
            accessController.grantRole(accessController.MONITOR_ADMIN_ROLE(), monitorAdmin);
            accessController.grantRole(accessController.CRON_JOB_ADMIN_ROLE(), cronJobAdmin);
            accessController.grantRole(accessController.PAYMENTS_CONTROLLER_ADMIN_ROLE(), paymentsControllerAdmin);
            accessController.grantRole(accessController.VOTING_CONTROLLER_ADMIN_ROLE(), votingControllerAdmin);
            accessController.grantRole(accessController.VOTING_ESCROW_MOCA_ADMIN_ROLE(), votingEscrowMocaAdmin);
            accessController.grantRole(accessController.ESCROWED_MOCA_ADMIN_ROLE(), escrowedMocaAdmin);
            accessController.grantRole(accessController.ASSET_MANAGER_ROLE(), assetManager);
            accessController.grantRole(accessController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler);
        vm.stopPrank();


        // Deploy mock tokens + register in AddressBook
        vm.startPrank(globalAdmin);
            addressBook.setAddress(addressBook.MOCA(), address(mockMoca));
            addressBook.setAddress(addressBook.USD8(), address(mockUSD8));
        vm.stopPrank();


        // 1. PaymentsController
        paymentsController = new PaymentsController(address(addressBook), protocolFeePercentage, voterFeePercentage, feeIncreaseDelayPeriod,
             "PaymentsController", "1");
        
        vm.startPrank(globalAdmin);
            addressBook.setAddress(addressBook.PAYMENTS_CONTROLLER(), address(paymentsController));
        vm.stopPrank();

        // 2. veMoca
        //veMoca = new VotingEscrowMoca(address(addressBook));



        //addressBook.setAddress(addressBook.ES_MOCA(), address(escrowedMoca));
        //addressBook.setAddress(addressBook.VOTING_ESCROW_MOCA(), address(veMoca));
        //addressBook.setAddress(addressBook.ACCESS_CONTROLLER(), address(accessController));
        //addressBook.setAddress(addressBook.VOTING_CONTROLLER(), address(votingController));

    }

// ------------------------------Helper functions-----------------------------------------

    function PaymentsController_generateId(uint256 salt, address adminAddress, address assetAddress) public view returns (bytes32) {
        return bytes32(keccak256(abi.encode(adminAddress, assetAddress, block.timestamp, salt)));
    }

    function PaymentsController_generateSchemaId(uint256 salt, bytes32 issuerId) public view returns (bytes32) {
        return bytes32(keccak256(abi.encode(issuerId, block.timestamp, salt)));
    }

}
