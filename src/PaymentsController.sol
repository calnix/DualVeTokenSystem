// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
// sig. checker + EIP712
import "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker, ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

// access control
import {AccessControlEnumerable, AccessControl} from "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable, IAccessControl} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

// libraries
import {DataTypes} from "./libraries/DataTypes.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {EpochMath} from "./libraries/EpochMath.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
 * @title PaymentsController
 * @author Calnix [@cal_nix]
 * @notice Central contract managing verification fees, and related distribution.
 * @dev Integrates with external controllers and enforces protocol-level access and safety checks. 
 */

contract PaymentsController is EIP712, LowLevelWMoca, Pausable, AccessControlEnumerable {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    // Contracts
    address public immutable WMOCA;
    IERC20 public immutable USD8;

    // fees: 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy) [both fees can be 0]
    uint256 public PROTOCOL_FEE_PERCENTAGE;    
    uint256 public VOTING_FEE_PERCENTAGE;   

    // delay period before an issuer's fee increase becomes effective for a given schema
    uint256 public FEE_INCREASE_DELAY_PERIOD;            // in seconds

    // total claimed by issuers | proxy for total verification fees accrued - to reduce storage updates in deductBalance()
    uint256 public TOTAL_CLAIMED_VERIFICATION_FEES;   // expressed in USD8 terms

    // staked by verifiers
    uint256 public TOTAL_MOCA_STAKED;


    // total fees unclaimed: for emergency withdrawal [USD8 terms]
    uint256 public TOTAL_PROTOCOL_FEES_UNCLAIMED;
    uint256 public TOTAL_VOTING_FEES_UNCLAIMED;

    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;
    
    // Roles
    bytes32 public constant PAYMENTS_CONTROLLER_ADMIN_ROLE = Constants.PAYMENTS_CONTROLLER_ADMIN_ROLE;
    bytes32 public constant EMERGENCY_EXIT_HANDLER_ROLE = Constants.EMERGENCY_EXIT_HANDLER_ROLE;
    bytes32 public constant MONITOR_ADMIN_ROLE = Constants.MONITOR_ADMIN_ROLE;
    bytes32 public constant CRON_JOB_ADMIN_ROLE = Constants.CRON_JOB_ADMIN_ROLE;
    bytes32 public constant MONITOR_ROLE = Constants.MONITOR_ROLE;
    bytes32 public constant CRON_JOB_ROLE = Constants.CRON_JOB_ROLE;

    // treasury address for payments controller
    address public PAYMENTS_CONTROLLER_TREASURY;


    // risk management
    uint256 public isFrozen;

//------------------------------- Mappings -----------------------------------------------------
    
    // issuer, verifier: address are adminAddresses
    mapping(address issuerAdminAddress => DataTypes.Issuer issuer) internal _issuers;
    mapping(address verifierAdminAddress => DataTypes.Verifier verifier) internal _verifiers;

    // schema: deterministic id generation
    mapping(bytes32 schemaId => DataTypes.Schema schema) internal _schemas;
    
    // nonces for preventing race conditions [ECDSA.sol::recover handles sig.malfunctions]
    // we do not store this in verifier struct since signerAddress is updatable
    mapping(address signerAddress => mapping(address userAddress => uint256 nonce)) internal _verifierNonces;

    // logs nonce for salt used for deterministic schema id generation
    mapping(address issuerAdminAddress => uint256 nonce) internal _issuerSchemaNonce;

    // Staking tiers: determines subsidy percentage for each verifier | admin fn will setup the tiers
    DataTypes.SubsidyTier[10] internal _subsidyTiers;


    // for VotingController.claimSubsidies(): track subsidies for each verifier, and pool, per epoch | getVerifierAndPoolAccruedSubsidies()
    mapping(uint256 epoch => mapping(bytes32 poolId => uint256 totalSubsidies)) internal _epochPoolSubsidies;                                                               // totalSubsidiesPerPoolPerEpoch
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(address verifierAdminAddress => uint256 verifierTotalSubsidies))) internal _epochPoolVerifierSubsidies;      // totalSubsidiesPerPoolPerEpochPerVerifier
    
    // To track fees accrued to each pool, per epoch | for voting rewards tracking
    mapping(uint256 epoch => mapping(bytes32 poolId => DataTypes.FeesAccrued feesAccrued)) internal _epochPoolFeesAccrued;
    // for correct withdrawal of fees and rewards
    mapping(uint256 epoch => DataTypes.FeesAccrued feesAccrued) internal _epochFeesAccrued;    
    
    // whitelist of pools [pseudo verification that poolId actually exists in VotingController]
    mapping(bytes32 poolId => bool isWhitelisted) internal _votingPools;

//------------------------------- Constructor---------------------------------------------------------------------

    // name: PaymentsController, version: 1
    constructor(
        address globalAdmin, address paymentsControllerAdmin, address monitorAdmin, address cronJobAdmin, address monitorBot, 
        address paymentsControllerTreasury, address emergencyExitHandler,
        uint256 protocolFeePercentage, uint256 voterFeePercentage, uint128 delayPeriod, 
        address wMoca_, address usd8_, uint256 mocaTransferGasLimit,
        string memory name, string memory version) EIP712(name, version) {


        // check: wrapped moca is set
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // check: usd8 is set
        require(usd8_ != address(0), Errors.InvalidAddress());
        USD8 = IERC20(usd8_);

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;
      
        // check if fee percentages are valid [both fees can be 0, but cannot be 100%]
        require(protocolFeePercentage + voterFeePercentage < Constants.PRECISION_BASE, Errors.InvalidPercentage());
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;
        VOTING_FEE_PERCENTAGE = voterFeePercentage;

        // min. delay period is 1 epoch; value must be in epoch intervals
        require(delayPeriod >= EpochMath.EPOCH_DURATION, Errors.InvalidDelayPeriod());
        require(EpochMath.isValidEpochTime(delayPeriod), Errors.InvalidDelayPeriod());
        FEE_INCREASE_DELAY_PERIOD = delayPeriod;


        _setupRolesAndTreasury(globalAdmin, paymentsControllerAdmin, monitorAdmin, cronJobAdmin, monitorBot, paymentsControllerTreasury, emergencyExitHandler);
    }

    // cronJob is not setup here; as its preferably to not keep it persistent. I.e. add address to cronJob when needed; then revoke.
    function _setupRolesAndTreasury(
        address globalAdmin, address paymentsControllerAdmin, address monitorAdmin, address cronJobAdmin, 
        address monitorBot, address paymentsControllerTreasury, address emergencyExitHandler) 
    internal {

        // sanity check: all addresses are not zero address
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(paymentsControllerAdmin != address(0), Errors.InvalidAddress());
        require(monitorAdmin != address(0), Errors.InvalidAddress());
        require(cronJobAdmin != address(0), Errors.InvalidAddress());
        require(monitorBot != address(0), Errors.InvalidAddress());
        require(paymentsControllerTreasury != address(0), Errors.InvalidAddress());
        require(emergencyExitHandler != address(0), Errors.InvalidAddress());

        // grant roles to addresses
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);    
        _grantRole(PAYMENTS_CONTROLLER_ADMIN_ROLE, paymentsControllerAdmin);
        _grantRole(MONITOR_ADMIN_ROLE, monitorAdmin);
        _grantRole(CRON_JOB_ADMIN_ROLE, cronJobAdmin);
        _grantRole(EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler);

        // there should at least 1 bot address for monitoring at deployment
        _grantRole(MONITOR_ROLE, monitorBot);

        // --------------- Set role admins ------------------------------
        // Operational role administrators managed by global admin
        _setRoleAdmin(PAYMENTS_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EMERGENCY_EXIT_HANDLER_ROLE, DEFAULT_ADMIN_ROLE);

        _setRoleAdmin(MONITOR_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(CRON_JOB_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        // High-frequency roles managed by their dedicated admins
        _setRoleAdmin(MONITOR_ROLE, MONITOR_ADMIN_ROLE);
        _setRoleAdmin(CRON_JOB_ROLE, CRON_JOB_ADMIN_ROLE);
        

        // set treasury address
        PAYMENTS_CONTROLLER_TREASURY = paymentsControllerTreasury;
    }

//------------------------------- Issuer functions-----------------------------------------------------------------


    /**
     * @notice Creates a new issuer.
     * @dev Each address can only be the admin of a single issuer [and a single verifier]
     * @param assetManagerAddress The address where issuer fees will be claimed.
     */
    function createIssuer(address assetManagerAddress) external whenNotPaused {
        require(assetManagerAddress != address(0), Errors.InvalidAddress());
        
        // check if issuer already exists
        require(_issuers[msg.sender].assetManagerAddress == address(0), Errors.IssuerAlreadyExists());

        // STORAGE: setup issuer
        _issuers[msg.sender].assetManagerAddress = assetManagerAddress;
        
        emit Events.IssuerCreated(msg.sender, assetManagerAddress);
    }

 
    /**
     * @notice Creates a new schema for the specified issuer.
     * @dev Only the issuer can call this function. The schemaId is generated to be unique.
     * @param fee The fee for the schema, expressed in USD8 (6 decimals).
     */
    function createSchema(uint128 fee) external whenNotPaused returns (bytes32) {
        // issuer must exist
        require(_issuers[msg.sender].assetManagerAddress != address(0), Errors.IssuerDoesNotExist());
        
        // sanity check: fee cannot be greater than 10_000 USD8
        // fee is an absolute value expressed in USD8 terms | free credentials are allowed
        require(fee < 10_000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // deterministic id generation: check if schemaId already exists; if so increment salt
        uint256 totalSchemas = _issuers[msg.sender].totalSchemas;
        bytes32 schemaId;
        uint256 salt;
        {
            // get current nonce
            salt = _issuerSchemaNonce[msg.sender];
            
            schemaId = keccak256(abi.encode("SCHEMA", msg.sender, totalSchemas, salt));
            
            // if non-zero; this schemaId has been taken
            while (_schemas[schemaId].issuer != address(0)) {
                // increment nonce and generate new id
                schemaId = keccak256(abi.encode("SCHEMA", msg.sender, totalSchemas, ++salt));
            }
        }

        // increment nonce for next schemaId generation
        _issuerSchemaNonce[msg.sender] = ++salt;

        // Increment schema count for issuer
        ++_issuers[msg.sender].totalSchemas;

        // STORAGE: create schema
        DataTypes.Schema storage schemaPtr = _schemas[schemaId];
        schemaPtr.issuer = msg.sender;
        schemaPtr.currentFee = fee;

        emit Events.SchemaCreated(schemaId, msg.sender, fee);

        return schemaId;
    }

    /**
     * @notice Updates the fee for a given schema under a specific issuer.
     * @dev Only the issuer admin can call this function. Decreasing the fee applies immediately; increasing the fee is scheduled after a delay.
     * @param schemaId The unique identifier of the schema to update.
     * @param newFee The new fee to set, expressed in USD8 (6 decimals).
     * @return newFee The new fee that was set. Returns value for better middleware integration.
     */
    function updateSchemaFee(bytes32 schemaId, uint128 newFee) external whenNotPaused returns (uint256) {        
        // cache pointers
        DataTypes.Schema storage schemaPtr = _schemas[schemaId];

        // sanity check: schema belongs to issuer[msg.sender] | [implicitly checks if schema exists]
        require(schemaPtr.issuer == msg.sender, Errors.InvalidSchema());

        // sanity check: fee cannot be greater than 10,000 USD8 | free credentials are allowed
        // 10_000 is an arbitrary large value selected
        require(newFee < 10_000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // if new fee is the same as the current fee, revert
        uint256 currentFee = schemaPtr.currentFee;
        require(newFee != currentFee, Errors.InvalidAmount());

        // decrementing fee is applied immediately
        if(newFee < currentFee) {
            schemaPtr.currentFee = newFee;
            
            // delete pending fee increase [in case it was set in a prior updateSchemaFee() call]
            delete schemaPtr.nextFee;
            delete schemaPtr.nextFeeTimestamp;

            emit Events.SchemaFeeReduced(schemaId, newFee, currentFee);

        } else {                    // new fee > current fee: schedule increase
            // increment nextFee 
            schemaPtr.nextFee = newFee;
            
            // set next fee timestamp
            uint128 nextFeeTimestamp = uint128(block.timestamp + FEE_INCREASE_DELAY_PERIOD);
            schemaPtr.nextFeeTimestamp = nextFeeTimestamp;

            emit Events.SchemaNextFeeSet(schemaId, newFee, nextFeeTimestamp, currentFee);
        }

        return newFee;
    }


    /**
     * @notice Claims all unclaimed verification fees for a given issuer.
     * @dev Only callable by the issuer's asset manager address; to which the total unclaimed fees are transferred.
     * - Caller must match the issuer's asset manager address.
     * - There must be claimable fees available.
     * @param issuer The address of the issuer to claim fees for.
     */
    function claimFees(address issuer) external whenNotPaused {
        // cache pointers
        DataTypes.Issuer storage issuerPtr = _issuers[issuer];
        
        // caller must be issuer's asset manager address
        require(issuerPtr.assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // sanity check: issuer has claimable fees
        uint256 claimableFees = issuerPtr.totalNetFeesAccrued - issuerPtr.totalClaimed;
        require(claimableFees > 0, Errors.NoClaimableFees());

        // overwrite .totalClaimed with .totalNetFeesAccrued
        issuerPtr.totalClaimed = issuerPtr.totalNetFeesAccrued;

        // update global counter
        TOTAL_CLAIMED_VERIFICATION_FEES += claimableFees;

        emit Events.IssuerFeesClaimed(issuer, claimableFees);

        // transfer fees to issuer
        USD8.safeTransfer(msg.sender, claimableFees);
    }


//------------------------------- Verifier functions---------------------------------------------------------------

    /**
     * @notice Creates a new verifier.
     * @dev Each address can only be the admin of a single verifier [and a single issuer]
     * @param signerAddress The address of the signer of the verifier.
     * @param assetManagerAddress The address where verifier fees will be claimed.
     */
    function createVerifier(address signerAddress, address assetManagerAddress) external whenNotPaused {
        require(signerAddress != address(0), Errors.InvalidAddress());
        require(assetManagerAddress != address(0), Errors.InvalidAddress());

        // check if verifier already exists
        require(_verifiers[msg.sender].assetManagerAddress == address(0), Errors.VerifierAlreadyExists());

        // STORAGE: create verifier
        DataTypes.Verifier storage verifierPtr = _verifiers[msg.sender];
        verifierPtr.signerAddress = signerAddress;
        verifierPtr.assetManagerAddress = assetManagerAddress;

        emit Events.VerifierCreated(msg.sender, signerAddress, assetManagerAddress);
    }


    /**
     * @notice Deposits USD8 into the verifier's balance.
     * @dev Only callable by the verifier's asset manager address. Increases the verifier's balance.
     * - Caller must match the verifier's asset manager address.
     * @param verifier The address of the verifier to deposit for.
     * @param amount The amount of USD8 to deposit.
     */
    function deposit(address verifier, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());
        
        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifier];

        // caller must be verifier's asset manager address
        require(verifierPtr.assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update balance
        verifierPtr.currentBalance += amount;

        emit Events.VerifierDeposited(verifier, msg.sender, amount);

        // transfer funds to verifier
        USD8.safeTransferFrom(msg.sender, address(this), amount);
    }


    /**
     * @notice Withdraws USD8 from the verifier's balance.
     * @dev Only callable by the verifier's asset manager address. Decreases the verifier's balance.
     * - Caller must match the verifier's asset manager address.
     * @param verifier The address of the verifier to withdraw from.
     * @param amount The amount of USD8 to withdraw.
     */
    function withdraw(address verifier, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifier];

        // caller must be verifier's asset manager address
        require(verifierPtr.assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough balance
        uint128 balance = verifierPtr.currentBalance;
        require(balance >= amount, Errors.InvalidAmount());

        // STORAGE: update balance
        verifierPtr.currentBalance -= amount;

        emit Events.VerifierWithdrew(verifier, msg.sender, amount);

        // transfer funds to verifier
        USD8.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Updates the signer address for a verifier.
     * @dev Only callable by the verifier's admin address. The new signer address must be non-zero and different from the current one.
     * @param newSignerAddress The new signer address to set.
     */
    function updateSignerAddress(address newSignerAddress) external whenNotPaused {
        require(newSignerAddress != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[msg.sender];
        address currentSignerAddress = verifierPtr.signerAddress;

        // check if verifier exists
        require(currentSignerAddress != address(0), Errors.VerifierDoesNotExist());

        // check if new signer address is different from current one
        require(currentSignerAddress != newSignerAddress, Errors.InvalidAddress());

        // update signer address
        verifierPtr.signerAddress = newSignerAddress;

        emit Events.VerifierSignerAddressUpdated(msg.sender, newSignerAddress);
    }


    /**
     * @notice Stakes MOCA for a verifier. Accepts native MOCA via msg.value.
     * @dev Only callable by the verifier's assetManagerAddress address. Increases the verifier's moca staked.
     * @param verifier The address of the verifier to stake MOCA for.
     */
    function stakeMoca(address verifier) external payable whenNotPaused {
        uint128 amount = uint128(msg.value);
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifier];
        
        // caller must be verifier's asset manager address
        require(verifierPtr.assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update moca staked
        verifierPtr.mocaStaked += amount;
        TOTAL_MOCA_STAKED += amount;

        emit Events.VerifierMocaStaked(verifier, msg.sender, amount);
    }


    /**
     * @notice Unstakes MOCA for a verifier.
     * @dev Only callable by the verifier's asset manager address. Decreases the verifier's moca staked.
     *      Transfers native MOCA via msg.value; if transfer fails within gas limit, wraps to wMoca and transfers the wMoca to verifier.
     * @param verifier The address of the verifier to unstake MOCA for.
     * @param amount The amount of MOCA to unstake.
     */
    function unstakeMoca(address verifier, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifier];

        // caller must be verifier's asset manager address
        address assetManagerAddress = verifierPtr.assetManagerAddress;
        require(assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough moca staked
        require(verifierPtr.mocaStaked >= amount, Errors.InvalidAmount());

        // STORAGE: update moca staked
        verifierPtr.mocaStaked -= amount;
        TOTAL_MOCA_STAKED -= amount;

        // transfer moca to issuer [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, assetManagerAddress, amount, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.VerifierMocaUnstaked(verifier, assetManagerAddress, amount);
    }

//------------------------------- updateAssetManagerAddress: common to both issuer and verifier ------------------

    //note: can be called during paused state, for use during emergency exit operations
    /**
     * @notice Generic function to update the asset manager address for either an issuer or a verifier.
     * @dev Caller must be the admin of the provided ID. IDs are unique across types, preventing cross-updates.
     * @param newAssetManagerAddress The new asset manager address to set.
     * @param isIssuer Whether the caller belongs to an issuer or a verifier.
     * @return newAssetManagerAddress The updated asset manager address.
     */
    function updateAssetManagerAddress(address newAssetManagerAddress, bool isIssuer) external returns (address) {
        require(newAssetManagerAddress != address(0), Errors.InvalidAddress());

        if(isIssuer) {
            // cache pointer
            DataTypes.Issuer storage issuerPtr = _issuers[msg.sender];
            
            // sanity check that the issuer exists
            require(issuerPtr.assetManagerAddress != address(0), Errors.IssuerDoesNotExist());

            // update asset manager address
            issuerPtr.assetManagerAddress = newAssetManagerAddress;

        } else {
            // cache pointer
            DataTypes.Verifier storage verifierPtr = _verifiers[msg.sender];
            
            // sanity check that the verifier exists
            require(verifierPtr.assetManagerAddress != address(0), Errors.VerifierDoesNotExist());

            // update asset manager address
            verifierPtr.assetManagerAddress = newAssetManagerAddress;
        }

        emit Events.AssetManagerAddressUpdated(msg.sender, newAssetManagerAddress);
        return newAssetManagerAddress;
    }

//------------------------------- Deduct Balance functions -------------------------------------------------------

    /**
     * @notice Deducts the verifier's balance for a verification, distributing protocol and voting fees.
     * @dev Validates signature, updates schema fee if needed, and increments verifier nonce.
     * @param verifier The address of the verifier.
     * @param schemaId The unique identifier of the schema.
     * @param amount The fee amount to deduct (must match current schema fee).
     * @param expiry The signature expiry timestamp.
     * @param signature The EIP-712 signature from the verifier's signer address.
     */
    function deductBalance(address verifier, address userAddress, bytes32 schemaId, uint128 amount, uint256 expiry, bytes calldata signature) external whenNotPaused {
        require(expiry > block.timestamp, Errors.SignatureExpired()); 
        require(amount > 0, Errors.InvalidAmount());
        
        // cache schema
        DataTypes.Schema storage schemaStorage = _schemas[schemaId];

        // get issuer address from schema + check if schema exists
        address issuer = schemaStorage.issuer;
        require(issuer != address(0), Errors.InvalidSchema());

        //----- NextFee check -----
        uint128 currentFee = _updateSchemaFeeIfNeeded(schemaStorage, schemaId);


        // cache verifier
        DataTypes.Verifier storage verifierStorage = _verifiers[verifier];

        // ----- Verify signature + Update nonce -----
        _verifyDeductBalanceSignature(verifierStorage, issuer, verifier, schemaId, userAddress, amount, expiry, signature, currentFee);


        // ----- Combined fee calculation -----
        (uint128 protocolFee, uint128 votingFee, uint128 netFee) = _calculateFees(amount);

        // ----- Update verifier, issuer, and schema balances and counters -----
        _updateBalancesAndCounters(verifierStorage, schemaStorage, issuer, amount, netFee);
        emit Events.BalanceDeducted(verifier, schemaId, issuer, amount);

        // ----- Book fees: pool-specific and epoch-level -----
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

        {
            bytes32 poolId = schemaStorage.poolId;
            // book fees: pool-specific and epoch-level
            _bookFees(verifier, poolId, schemaId, amount, currentEpoch, protocolFee, votingFee);
        }        

        // ----- Increment verification count -----
        ++schemaStorage.totalVerified;
        emit Events.SchemaVerified(schemaId);
    }


    /**
     * @notice Deducts a verifier's balance for a zero-fee schema verification, updating relevant counters.
     * @dev Requires the schema to have zero fee. Verifies the signature for the operation.
     *      Increments verification counters for the schema and issuer. Emits SchemaVerifiedZeroFee event.
     * @param verifier The address of the verifier.
     * @param schemaId The unique identifier of the schema.
     * @param expiry The timestamp after which the signature is invalid.
     * @param signature The EIP-712 signature from the verifier's signer address.
     */
    function deductBalanceZeroFee(address verifier, bytes32 schemaId, address userAddress, uint256 expiry, bytes calldata signature) external whenNotPaused {
        require(expiry > block.timestamp, Errors.SignatureExpired());
        
        // get pointer
        DataTypes.Schema storage schemaPtr = _schemas[schemaId];

        // get issuer address from schema + check if schema exists
        address issuer = schemaPtr.issuer;
        require(issuer != address(0), Errors.InvalidSchema());

    
        //----- Verify schema has still has zero fee [ NextFee timestamp check ]-----
        if (schemaPtr.nextFee > 0 && schemaPtr.nextFeeTimestamp <= block.timestamp) revert Errors.InvalidSchemaFee();

        // ----- Verify signature + Update nonce -----
        _verifyDeductBalanceZeroFeeSignature(verifier, issuer, schemaId, userAddress, expiry, signature);
        
        // ----- Increment issuer and schema total verified counters -----
        ++schemaPtr.totalVerified;
        ++_issuers[issuer].totalVerified;
        
        emit Events.SchemaVerifiedZeroFee(schemaId);
    }

    
    /**
     * @notice Verifies the EIP-712 signature for deductBalanceZeroFee and updates nonce.
     * @dev Internal function to reduce stack depth in deductBalanceZeroFee.
     * @param verifierAdminAddress The verifier admin address.
     * @param issuerAdminAddress The issuer admin address.
     * @param schemaId The schema identifier.
     * @param userAddress The user address.
     * @param expiry The signature expiry timestamp.
     * @param signature The EIP-712 signature.
     */
    function _verifyDeductBalanceZeroFeeSignature(
        address verifierAdminAddress,
        address issuerAdminAddress,
        bytes32 schemaId,
        address userAddress,
        uint256 expiry,
        bytes calldata signature
    ) internal {
        // cache verifier to get signer address
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierAdminAddress];
        address signerAddress = verifierPtr.signerAddress;
        
        // hash the signature
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(
            Constants.DEDUCT_BALANCE_ZERO_FEE_TYPEHASH,
            issuerAdminAddress,
            verifierAdminAddress,
            schemaId,
            userAddress,
            expiry,
            _verifierNonces[signerAddress][userAddress]
        )));
        
        // handles both EOA and contract signatures | returns true if signature is valid
        require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), Errors.InvalidSignature());
        
        // increment verifier nonce
        ++_verifierNonces[signerAddress][userAddress];
    }

//------------------------------- Internal functions--------------------------------------------------------------

    // Finds the highest tier the verifier qualifies for (closest largest) and applies that subsidy.
    // expects subsidy tier array to be orders in ascending fashion (from smallest to largest)
    function _bookSubsidy(address verifier, bytes32 poolId, bytes32 schemaId, uint128 amount, uint256 currentEpoch) internal {
        // get verifier's moca staked
        uint256 verifierMocaStaked = _verifiers[verifier].mocaStaked;
        
        // find the highest tier the verifier qualifies for
        uint256 subsidyPct = _getSubsidyPercentage(verifierMocaStaked);

        // if subsidy percentage is non-zero, calculate and book subsidy
        if(subsidyPct > 0) {
            // calculate subsidy
            uint256 subsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;
            
            if(subsidy > 0) {
                // book verifier's subsidy
                _epochPoolSubsidies[currentEpoch][poolId] += subsidy;
                _epochPoolVerifierSubsidies[currentEpoch][poolId][verifier] += subsidy;
                emit Events.SubsidyBooked(verifier, poolId, schemaId, subsidy);
            }
        }
    }
   
    // finds the highest qualifying tier and returns the subsidy percentage for that tier
    // expects subsidy tier array to be orders in ascending fashion (from smallest to largest)
    function _getSubsidyPercentage(uint256 verifierMocaStaked) internal view returns (uint256) {
        
        // Loop backwards to find highest qualifying tier immediately
        uint256 i = 10;
        while(i > 0) {
            --i;
            // get tier's moca staked
            uint128 tierMocaStaked = _subsidyTiers[i].mocaStaked;

            // skip unset tiers
            if(tierMocaStaked == 0) continue;
            
            // if verifier qualifies for this tier, return immediately (highest qualifying tier)
            if(verifierMocaStaked >= tierMocaStaked) return _subsidyTiers[i].subsidyPercentage;

            if(i == 0) break; // avoid underflow
        }
        
        // no qualifying tier found
        return 0;
    }

    /**
     * @notice Calculates protocol fee, voting fee, and net fee from an amount. [Fees are calculated in USD8 terms | 6dp precision]
     * @dev Internal function to reduce stack depth in deductBalance.
     * @param amount The amount to calculate fees from.
     * @return protocolFee The protocol fee amount.
     * @return votingFee The voting fee amount.
     * @return netFee The net fee amount after deducting protocol and voting fees.
     */
    function _calculateFees(uint128 amount) internal view returns (uint128 protocolFee, uint128 votingFee, uint128 netFee) {
        // Multiplying by percentage could overflow uint128 → needs uint256 intermediate & cast to uint128 could silently truncate values
        uint256 protocolFeeCalc = (uint256(amount) * PROTOCOL_FEE_PERCENTAGE) / Constants.PRECISION_BASE;
        uint256 votingFeeCalc = (uint256(amount) * VOTING_FEE_PERCENTAGE) / Constants.PRECISION_BASE;

        //@audit should these require safecast? USD8 is 6 dp precision [calnix]
        protocolFee = uint128(protocolFeeCalc); 
        votingFee = uint128(votingFeeCalc);
        netFee = uint128(amount - protocolFee - votingFee);
    }

    /**
     * @notice Updates schema fee if nextFee timestamp has passed.
     * @dev Internal function to reduce stack depth in deductBalance.
     * @param schemaStorage Storage pointer to the schema.
     * @param schemaId The schema identifier for event emission.
     * @return currentFee The current fee after potential update.
     */
    function _updateSchemaFeeIfNeeded(DataTypes.Schema storage schemaStorage, bytes32 schemaId) internal returns (uint128) {
        uint128 currentFee = schemaStorage.currentFee;

        if (schemaStorage.nextFee > 0 && schemaStorage.nextFeeTimestamp <= block.timestamp) {
            // cache for event emission
            uint128 oldFee = currentFee;
            currentFee = schemaStorage.nextFee;

            // update schema fee
            schemaStorage.currentFee = currentFee;
            delete schemaStorage.nextFee;
            delete schemaStorage.nextFeeTimestamp;
            emit Events.SchemaFeeIncreased(schemaId, oldFee, currentFee);
        }
        return currentFee;
    }
    

    /**
     * @notice Verifies the EIP-712 signature for deductBalance and updates nonce.
     * @dev Internal function to reduce stack depth in deductBalance.
     * @param verifierStorage Storage pointer to the verifier.
     * @param issuerAdminAddress The issuer admin address.
     * @param verifierAdminAddress The verifier admin address.
     * @param schemaId The schema identifier.
     * @param userAddress The user address.
     * @param amount The amount to verify.
     * @param expiry The signature expiry timestamp.
     * @param signature The EIP-712 signature.
     * @param currentFee The current schema fee to validate against.
     */
    function _verifyDeductBalanceSignature(
        DataTypes.Verifier storage verifierStorage,
        address issuerAdminAddress,
        address verifierAdminAddress,
        bytes32 schemaId,
        address userAddress,
        uint128 amount,
        uint256 expiry,
        bytes calldata signature,
        uint128 currentFee
    ) internal {
        
        // sanity check: amount matches latest schema fee
        require(amount == currentFee, Errors.InvalidSchemaFee());

        // get signer address from verifier
        address signerAddress = verifierStorage.signerAddress;
        
        // hash the signature
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(
            Constants.DEDUCT_BALANCE_TYPEHASH,
            issuerAdminAddress,
            verifierAdminAddress,
            schemaId,
            userAddress,
            amount,
            expiry,
            _verifierNonces[signerAddress][userAddress]
        )));
        
        // handles both EOA and contract signatures | returns true if signature is valid
        require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), Errors.InvalidSignature()); 

        // increment verifier nonce
        ++_verifierNonces[signerAddress][userAddress];
    }


    /**
     * @notice Updates verifier, issuer, and schema balances and counters.
     * @dev Internal function to reduce stack depth in deductBalance.
     * @param verifierStorage Storage pointer to the verifier.
     * @param schemaStorage Storage pointer to the schema.
     * @param issuer The issuer address.
     * @param amount The amount being deducted.
     * @param netFee The net fee after protocol and voting fees.
     */
    function _updateBalancesAndCounters(
        DataTypes.Verifier storage verifierStorage,
        DataTypes.Schema storage schemaStorage,
        address issuer, uint128 amount, uint128 netFee
    ) internal {
        
        // sanity check: verifier has sufficient balance
        uint128 verifierBalance = verifierStorage.currentBalance;
        require(verifierBalance >= amount, Errors.InsufficientBalance());
        
        // verifier: deduct amount from verifier's balance + increment total expenditure
        verifierStorage.currentBalance = verifierBalance - amount;
        verifierStorage.totalExpenditure += amount;
        
        // issuer: update total net fees accrued and total verified
        DataTypes.Issuer storage issuerStorage = _issuers[issuer];
        issuerStorage.totalNetFeesAccrued += netFee;
        ++issuerStorage.totalVerified; 

        // schema: update total gross fees accrued
        schemaStorage.totalGrossFeesAccrued += amount;
    }

    /**
     * @notice Books fees for pool-specific and epoch-level tracking.
     * @dev Internal function to reduce stack depth in deductBalance.
     * @param verifier The verifier address.
     * @param poolId The pool identifier.
     * @param schemaId The schema identifier.
     * @param amount The amount for subsidy calculation.
     * @param currentEpoch The current epoch number.
     * @param protocolFee The protocol fee amount.
     * @param votingFee The voting fee amount.
     */
    function _bookFees(
        address verifier, bytes32 poolId, bytes32 schemaId, uint128 amount, 
        uint256 currentEpoch, uint128 protocolFee, uint128 votingFee
    ) internal {

        // Pool-specific updates [for VotingController]
        if(_votingPools[poolId]) {
            _bookSubsidy(verifier, poolId, schemaId, amount, currentEpoch);
            
            // Batch pool fee updates
            DataTypes.FeesAccrued storage poolFees = _epochPoolFeesAccrued[currentEpoch][poolId];
            poolFees.feesAccruedToProtocol += protocolFee;
            poolFees.feesAccruedToVoters += votingFee;
        }

        // Book fees: global + epoch [for AssetManager]
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[currentEpoch];
        epochFees.feesAccruedToProtocol += protocolFee;
        epochFees.feesAccruedToVoters += votingFee;
        
        // for emergency withdrawal
        TOTAL_PROTOCOL_FEES_UNCLAIMED += protocolFee;
        TOTAL_VOTING_FEES_UNCLAIMED += votingFee;
    }

    

//------------------------------- PaymentsControllerAdmin: update functions---------------------------------------

    /**
     * @notice Updates the poolId associated with a schema. Can set, update, or remove the poolId.
     * @dev Only callable by PaymentsController admin. The schema must exist.
     * @param schemaId The unique id of the schema to update.
     * @param poolId The new poolId to associate with the schema (can be zero to remove).
     */
    function updatePoolId(bytes32 schemaId, bytes32 poolId) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        DataTypes.Schema storage schemaPtr = _schemas[schemaId];

        // sanity check: schema must exist
        require(schemaPtr.issuer != address(0), Errors.InvalidSchema());
        
        // pool must be whitelisted
        require(_votingPools[poolId], Errors.PoolNotWhitelisted());

        // update pool id
        schemaPtr.poolId = poolId;

        emit Events.PoolIdUpdated(schemaId, poolId);
    }

    /**
     * @notice Whitelists or un-whitelists a pool.
     * @dev Only callable by PaymentsController admin. [The pool must exist in VotingController]
     * @param poolId The poolId to whitelist or un-whitelist.
     * @param isWhitelisted The new whitelist status.
     */
    function whitelistPool(bytes32 poolId, bool isWhitelisted) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(_votingPools[poolId] != isWhitelisted, Errors.PoolWhitelistedStatusUnchanged());

        _votingPools[poolId] = isWhitelisted;
        emit Events.PoolWhitelistedUpdated(poolId, isWhitelisted);
    }

    /**
     * @notice Updates the fee increase delay period for schema fee increases.
     * @dev Only callable by PaymentsController admin. The delay period must be greater than 0,
     *      and a multiple of the epoch duration defined in EpochMath.
     * @param newDelayPeriod The new delay period to set, in seconds. Must be divisible by EpochMath.EPOCH_DURATION.
     */
    function updateFeeIncreaseDelayPeriod(uint128 newDelayPeriod) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        // min. delay period is 1 epoch; value must be in epoch intervals
        require(newDelayPeriod >= EpochMath.EPOCH_DURATION, Errors.InvalidDelayPeriod());
        require(EpochMath.isValidEpochTime(newDelayPeriod), Errors.InvalidDelayPeriod());

        FEE_INCREASE_DELAY_PERIOD = newDelayPeriod;

        emit Events.FeeIncreaseDelayPeriodUpdated(newDelayPeriod);
    }

    /**
     * @notice Updates the protocol fee percentage.
     * @dev Only callable by PaymentsController admin. 
     *      The new total fee percentage cannot be greater than 100% [10_000].
     * @param protocolFeePercentage The new protocol fee percentage to set.
     */
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        // total fee percentage cannot be greater than 100%
        require(protocolFeePercentage + VOTING_FEE_PERCENTAGE < Constants.PRECISION_BASE, Errors.InvalidPercentage());

        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        emit Events.ProtocolFeePercentageUpdated(protocolFeePercentage);
    }

    /**
     * @notice Updates the voting fee percentage.
     * @dev Only callable by PaymentsController admin. The voting fee percentage cannot be greater than 100% [10_000].
     *      The new total fee percentage cannot be greater than 100% [10_000].
     * @param votingFeePercentage The new voting fee percentage to set.
     */
    function updateVotingFeePercentage(uint256 votingFeePercentage) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        // total fee percentage cannot be greater than 100%
        require(votingFeePercentage + PROTOCOL_FEE_PERCENTAGE < Constants.PRECISION_BASE, Errors.InvalidPercentage());
        
        VOTING_FEE_PERCENTAGE = votingFeePercentage;

        emit Events.VotingFeePercentageUpdated(votingFeePercentage);
    }

    /**
     * @notice Overwrites the subsidy tiers array with latest inputs. [Ensures ascending order and contiguity]
     * @dev Only callable by the PaymentsController admin.
     * @param mocaStaked The moca staked for each tier.
     * @param subsidyPercentages The subsidy percentage for each tier. [Can be 100%, but not 0. If 0, no reason to setup a tier]
     */
    function setVerifierSubsidyTiers(uint128[] calldata mocaStaked, uint128[] calldata subsidyPercentages) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        uint256 length = mocaStaked.length;
        require(length > 0 && length <= 10, Errors.InvalidArray());
        require(length == subsidyPercentages.length, Errors.MismatchedArrayLengths());

        // Build a new contiguous tier set: indices [0..length-1] set, [length..MAX-1] zeroed
        DataTypes.SubsidyTier[10] memory newTiers;

        // indices [length..MAX-1] remain zero (contiguity enforced)
        uint128 prevMoca;
        uint128 prevPct;
        for (uint256 i; i < length; ++i) {
            uint128 currentMocaStaked = mocaStaked[i];
            uint128 currentSubsidyPct = subsidyPercentages[i];

            // Non-zero values for contiguous head
            require(currentMocaStaked > 0, Errors.InvalidAmount());
            require(currentSubsidyPct > 0 && currentSubsidyPct <= Constants.PRECISION_BASE, Errors.InvalidPercentage());

            // Strictly ascending
            if (i > 0) {
                require(currentMocaStaked > prevMoca, Errors.InvalidMocaStakedTierOrder());
                require(currentSubsidyPct > prevPct, Errors.InvalidSubsidyPercentageTierOrder());
            }

            newTiers[i].mocaStaked = currentMocaStaked;
            newTiers[i].subsidyPercentage = currentSubsidyPct;

            prevMoca = currentMocaStaked;
            prevPct = currentSubsidyPct;
        }
        
        // STORAGE: update _subsidyTiers with newTiers
        _subsidyTiers = newTiers;

        emit Events.VerifierStakingTiersSet(mocaStaked, subsidyPercentages);
    }

    /**
     * @notice Clears all verifier subsidy tiers.
     * @dev Only callable by the PaymentsController admin.
     */
    function clearVerifierSubsidyTiers() external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        delete _subsidyTiers;
        emit Events.VerifierStakingTiersCleared();
    }


    /**
     * @notice Sets the gas limit for moca transfer.
     * @dev Only callable by the PaymentsController admin.
     * @param newMocaTransferGasLimit The new gas limit for moca transfer.
     */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyRole(PAYMENTS_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }

//------------------------------- CronJob: withdraw functions-----------------------------------------------------

    //note: every 2 weeks/epoch
    //note: use cronjob instead of asset manager, due to frequency of calls; so that can be scripted.

    /**
     * @notice Allows withdrawal of protocol fees only after the specified epoch has ended.
     * @dev Protocol fees for a given epoch can be withdrawn once per epoch, after the epoch is finalized.
     *      Use cronjob instead of asset manager, due to frequency of calls; so that can be scripted; i.e. bi-weekly.
     *      Assets are sent to payments controller treasury.
     * @param epoch The epoch number for which to withdraw protocol fees.
     */
    function withdrawProtocolFees(uint256 epoch) external onlyRole(CRON_JOB_ROLE) whenNotPaused {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());

        // get payments controller treasury address
        address paymentsControllerTreasury = PAYMENTS_CONTROLLER_TREASURY;
        require(paymentsControllerTreasury != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[epoch];

        require(!epochFees.isProtocolFeeWithdrawn, Errors.ProtocolFeeAlreadyWithdrawn());

        // sanity check: there must be protocol fees to withdraw
        uint256 protocolFees = epochFees.feesAccruedToProtocol;
        require(protocolFees > 0, Errors.ZeroProtocolFee());

        // update flag
        epochFees.isProtocolFeeWithdrawn = true;
        TOTAL_PROTOCOL_FEES_UNCLAIMED -= protocolFees;

        emit Events.ProtocolFeesWithdrawn(epoch, protocolFees);

        USD8.safeTransfer(paymentsControllerTreasury, protocolFees);
    }

    /**
     * @notice Allows withdrawal of voters fees only after the specified epoch has ended.
     * @dev Voters fees for a given epoch can be withdrawn once per epoch, after the epoch is finalized.
     *      Use cronjob instead of asset manager, due to frequency of calls; so that can be scripted; i.e. bi-weekly.
     *      Assets are sent to payments controller treasury.
     * @param epoch The epoch number for which to withdraw voters fees.
     */
    function withdrawVotersFees(uint256 epoch) external onlyRole(CRON_JOB_ROLE) whenNotPaused {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());

        // get payments controller treasury address
        address paymentsControllerTreasury = PAYMENTS_CONTROLLER_TREASURY;
        require(paymentsControllerTreasury != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[epoch];

        require(!epochFees.isVotersFeeWithdrawn, Errors.VotersFeeAlreadyWithdrawn());

        // sanity check: there must be voters fees to withdraw
        uint256 votersFees = epochFees.feesAccruedToVoters;
        require(votersFees > 0, Errors.ZeroVotersFee());

        // update flag
        epochFees.isVotersFeeWithdrawn = true;
        TOTAL_VOTING_FEES_UNCLAIMED -= votersFees;
        emit Events.VotersFeesWithdrawn(epoch, votersFees);

        USD8.safeTransfer(paymentsControllerTreasury, votersFees);
    }

//------------------------------- DEFAULT_ADMIN_ROLE: update treasury address ------------------------------------------
    
    /**
     * @notice Sets the payments controller treasury address
     * @dev Only callable by the DEFAULT_ADMIN_ROLE
     * @param newPaymentsControllerTreasury The new payments controller treasury address
    */
    function setPaymentsControllerTreasury(address newPaymentsControllerTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // sanity check: new treasury address is not zero address or the same address
        require(newPaymentsControllerTreasury != address(0), Errors.InvalidAddress());
        require(newPaymentsControllerTreasury != address(this), Errors.InvalidAddress());
        require(newPaymentsControllerTreasury != PAYMENTS_CONTROLLER_TREASURY, Errors.InvalidAddress());

        // update treasury address
        address oldPaymentsControllerTreasury = PAYMENTS_CONTROLLER_TREASURY;
        PAYMENTS_CONTROLLER_TREASURY = newPaymentsControllerTreasury;

        emit Events.PaymentsControllerTreasuryUpdated(oldPaymentsControllerTreasury, newPaymentsControllerTreasury);
    }

//------------------------------- Risk-related functions ---------------------------------------------------------

    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external onlyRole(MONITOR_ROLE) whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        require(isFrozen == 0, Errors.IsFrozen());
        isFrozen = 1;
        emit Events.ContractFrozen();
    }  

    /**
     * @notice Transfers all verifiers' remaining balances to their registered asset addresses during emergency exit.
     * @dev If called by an verifier, they should pass an array of length 1 with their own verifier address.
     *      If called by the emergency exit handler, they should pass an array of length > 1 with the verifier addresses of the verifiers to exit.
     *      Can only be called when the contract is frozen.
     *      Iterates through the provided verifierIds, transferring each non-zero balance to the corresponding asset manager address.
     *      Skips verifiers with zero balance.
     * @param verifiers Array of verifier addresses whose balances will be exfil'd.
     */
    function emergencyExitVerifiers(address[] calldata verifiers) external {
        require(isFrozen == 1, Errors.NotFrozen());
        require(verifiers.length > 0, Errors.InvalidArray());
   
        uint256 totalAssets;

        // check: if NOT emergency exit handler, verifier can only exit themselves
        if (!hasRole(EMERGENCY_EXIT_HANDLER_ROLE, msg.sender)) {
            // check: caller can only exit themselves
            require(msg.sender == verifiers[0] && verifiers.length == 1, Errors.OnlyCallableByEmergencyExitHandlerOrVerifier());
        }
        
        // if anything other than a valid verifier address is given, will retrieve either empty struct and skip
        for(uint256 i; i < verifiers.length; ++i) {
            
            address verifier = verifiers[i];
            
            // cache verifier pointer
            DataTypes.Verifier storage verifierPtr = _verifiers[verifier];

            // get balance: if 0, skip
            uint256 verifierUSD8Balance = verifierPtr.currentBalance;
            uint256 verifierMocaStaked = verifierPtr.mocaStaked;
            
            // check if total assets is 0; if so, skip
            totalAssets += verifierUSD8Balance + verifierMocaStaked;
            if(totalAssets == 0) continue;

            // get asset manager address
            address verifierAssetManagerAddress = verifierPtr.assetManagerAddress;

            // reset balance and moca staked
            delete verifierPtr.currentBalance;
            delete verifierPtr.mocaStaked;

            
            // transfer USD8 balance to verifier
            if(verifierUSD8Balance > 0) USD8.safeTransfer(verifierAssetManagerAddress, verifierUSD8Balance);
            
            // transfer MOCA staked to verifier
            if(verifierMocaStaked > 0) {

                // decrement total moca staked
                TOTAL_MOCA_STAKED -= verifierMocaStaked;

                // transfer moca to verifier
                _transferMocaAndWrapIfFailWithGasLimit(WMOCA, verifierAssetManagerAddress, verifierMocaStaked, MOCA_TRANSFER_GAS_LIMIT);
            }
        }

        // emit event if total assets is > 0
        if(totalAssets > 0) emit Events.EmergencyExitVerifiers(verifiers);
    }

    /**
     * @notice Transfers all issuers' unclaimed fees to their registered asset addresses during emergency exit.
     * @dev If called by an issuer, they should pass an array of length 1 with their own issuerId.
     *      If called by the emergency exit handler, they should pass an array of length > 1 with the issuerIds of the issuers to exit.
     *      Can only be called when the contract is frozen.
     *      Iterates through the provided issuerIds, transferring each non-zero unclaimed fees to the corresponding asset manager address.
     *      Skips issuers with zero unclaimed fees.
     * @param issuers Array of issuer addresses whose unclaimed fees will be exfil'd.
     */
    function emergencyExitIssuers(address[] calldata issuers) external {
        require(isFrozen == 1, Errors.NotFrozen());
        require(issuers.length > 0, Errors.InvalidArray());

        uint256 totalAssets;

        // check: if NOT emergency exit handler, issuer can only exit themselves
        if (!hasRole(EMERGENCY_EXIT_HANDLER_ROLE, msg.sender)) {
            // check: caller can only exit themselves
            require(msg.sender == issuers[0] && issuers.length == 1, Errors.OnlyCallableByEmergencyExitHandlerOrIssuer());
        }

        // if anything other than a valid issuer address is given, will retrieve either empty struct and skip
        for(uint256 i; i < issuers.length; ++i) {

            address issuer = issuers[i];

            // cache pointer
            DataTypes.Issuer storage issuerPtr = _issuers[issuer];

            // get unclaimed fees: if 0, skip
            uint256 unclaimedFees = issuerPtr.totalNetFeesAccrued - issuerPtr.totalClaimed;
            if(unclaimedFees == 0) continue;

            // increment total claimed fees
            issuerPtr.totalClaimed = issuerPtr.totalNetFeesAccrued;

            // increment counter
            totalAssets += unclaimedFees;

            // transfer fees to issuer
            USD8.safeTransfer(issuerPtr.assetManagerAddress, unclaimedFees);
        }

        // emit event if total assets is > 0
        if(totalAssets > 0) emit Events.EmergencyExitIssuers(issuers);   
    }

    /**
     * @notice Transfers all unclaimed protocol and voting fees to the treasury during emergency exit.
     * @dev Callable only by the emergency exit handler when the contract is frozen.
     *      Transfers the sum of unclaimed fees to payments controller treasury address.
     *      Resets the unclaimed fee counters to zero after transfer.
     */
    function emergencyExitFees() external onlyRole(EMERGENCY_EXIT_HANDLER_ROLE) {
        require(isFrozen == 1, Errors.NotFrozen());

        // get treasury address
        address paymentsControllerTreasury = PAYMENTS_CONTROLLER_TREASURY;
        require(paymentsControllerTreasury != address(0), Errors.InvalidAddress());
        require(paymentsControllerTreasury != address(this), Errors.InvalidAddress());
        
        // sanity check: there must be unclaimed fees to claim
        uint256 totalUnclaimedFees = TOTAL_PROTOCOL_FEES_UNCLAIMED + TOTAL_VOTING_FEES_UNCLAIMED;
        require(totalUnclaimedFees > 0, Errors.NoFeesToClaim());

        // reset counters
        delete TOTAL_PROTOCOL_FEES_UNCLAIMED;
        delete TOTAL_VOTING_FEES_UNCLAIMED;
        
        // transfer fees to treasury
        USD8.safeTransfer(paymentsControllerTreasury, totalUnclaimedFees);

        emit Events.EmergencyExitFees(paymentsControllerTreasury, totalUnclaimedFees);
    }
    

//------------------------------- View functions ------------------------------------------------------------------
   
    // note: called by VotingController.claimSubsidies | no need for zero address check on the caller
    /**
     * @notice Returns the total subsidies per epoch, for a pool and {verifier, pool}.
     * @param epoch The epoch number.   
     * @param poolId The pool id.
     * @param verifierAddress The verifier address.
     * @param caller Expected to be the verifier's asset manager address. [Called through VotingController.claimSubsidies()].
     * @return verifierAccruedSubsidies The total subsidies for the {verifier, pool}, for the epoch.
     * @return poolAccruedSubsidies The total subsidies for the pool, for the epoch.
     */
    function getVerifierAndPoolAccruedSubsidies(uint128 epoch, bytes32 poolId, address verifierAddress, address caller) external view returns (uint256, uint256) {
        // verifiers's asset manager address must be the caller of VotingController.claimSubsidies
        require(caller == _verifiers[verifierAddress].assetManagerAddress, Errors.InvalidCaller());
        return (_epochPoolVerifierSubsidies[epoch][poolId][verifierAddress], _epochPoolSubsidies[epoch][poolId]);
    }
    
    /**
     * @notice Returns the Issuer struct for a given issuer address.
     * @param issuer The address of the issuer.
     * @return issuer The Issuer struct containing all issuer data.
     */
    function getIssuer(address issuer) external view returns (DataTypes.Issuer memory) {
        return _issuers[issuer];
    }

    /** 
     * @notice Returns the Schema struct for a given schemaId.
     * @param schemaId The unique identifier of the schema.
     * @return schema The Schema struct containing all schema data.
     */
    function getSchema(bytes32 schemaId) external view returns (DataTypes.Schema memory) {
        return _schemas[schemaId];
    }

    /**
     * @notice Returns the Verifier struct for a given verifier address.
     * @param verifier The address of the verifier.
     * @return verifier The Verifier struct containing all verifier data.
     */
    function getVerifier(address verifier) external view returns (DataTypes.Verifier memory) {
        return _verifiers[verifier];
    }

    /**
     * @notice Returns the nonce for a given signerAddress and userAddress.
     * @param signerAddress The address of the signer.
     * @param userAddress The address of the user.
     * @return nonce The nonce for the signer and userAddress.
     */
    function getVerifierNonce(address signerAddress, address userAddress) external view returns (uint256) {
        return _verifierNonces[signerAddress][userAddress];
    }

    /**
     * @notice Returns the subsidy percentage for a given staked amount.
     * @dev Finds the highest tier the staked amount qualifies for (same logic as _bookSubsidy).
     * @param mocaStaked The amount of MOCA staked.
     * @return subsidyPercentage The subsidy percentage the staked amount qualifies for.
     */
    function getEligibleSubsidyPercentage(uint256 mocaStaked) external view returns (uint256) {
        return _getSubsidyPercentage(mocaStaked);
    }

    /**
     * @notice Returns all subsidy tiers.
     * @return tiers Array of all subsidy tiers.
     */
    function getAllSubsidyTiers() external view returns (DataTypes.SubsidyTier[10] memory) {
        return _subsidyTiers;
    }

    /**
     * @notice Returns a specific subsidy tier by index.
     * @param tierIndex The index of the tier (0-9).
     * @return tier The subsidy tier at the specified index.
     */
    function getSubsidyTier(uint256 tierIndex) external view returns (DataTypes.SubsidyTier memory) {
        require(tierIndex < 10, Errors.InvalidIndex());
        return _subsidyTiers[tierIndex];
    }

    /**
     * @notice Returns the total subsidies for a given pool and epoch.
     * @param epoch The epoch.
     * @param poolId The pool id.
     * @return totalSubsidies The total subsidies for the pool and epoch.
     */
    function getEpochPoolSubsidies(uint256 epoch, bytes32 poolId) external view returns (uint256) {
        return _epochPoolSubsidies[epoch][poolId];
    }

    /**
     * @notice Returns the total subsidies for a given pool and verifier and epoch.
     * @param epoch The epoch.
     * @param poolId The pool id.
     * @param verifier The verifier address.
     * @return totalSubsidies The total subsidies for the pool and verifier and epoch.
     */
    function getEpochPoolVerifierSubsidies(uint256 epoch, bytes32 poolId, address verifier) external view returns (uint256) {
        return _epochPoolVerifierSubsidies[epoch][poolId][verifier];
    }

    // note: manually refer to this, to know how much esMoca to deposit per pool on VotingController.depositRewardsForEpoch()
    /**
     * @notice Returns the fees accrued for a given pool and epoch.
     * @param epoch The epoch.
     * @param poolId The pool id.
     * @return feesAccrued The fees accrued for the pool and epoch.
     */
    function getEpochPoolFeesAccrued(uint256 epoch, bytes32 poolId) external view returns (DataTypes.FeesAccrued memory) {
        return _epochPoolFeesAccrued[epoch][poolId];
    }

    /**
     * @notice Returns the fees accrued for a given epoch.
     * @param epoch The epoch.
     * @return feesAccrued The fees accrued for the epoch.
     */
    function getEpochFeesAccrued(uint256 epoch) external view returns (DataTypes.FeesAccrued memory) {
        return _epochFeesAccrued[epoch];
    }

    /**
     * @notice Returns the nonce for a given issuer address.
     * @param issuer The issuer address.
     * @return nonce The nonce for the issuer address.
     */
    function getIssuerSchemaNonce(address issuer) external view returns (uint256) {
        return _issuerSchemaNonce[issuer];
    }

    /**
     * @notice Returns true if the pool is whitelisted, false otherwise.
     * @param poolId The pool id.
     * @return isWhitelisted True if the pool is whitelisted, false otherwise.
     */
    function checkIfPoolIsWhitelisted(bytes32 poolId) external view returns (bool) {
        return _votingPools[poolId];
    }

}