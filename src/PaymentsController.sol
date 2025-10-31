// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
// sig. checker + EIP712
import "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker, ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

// libraries
import {DataTypes} from "./libraries/DataTypes.sol";
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";
import {EpochMath} from "./libraries/EpochMath.sol";

// interfaces
import {IAccessController} from "./interfaces/IAccessController.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
 * @title PaymentsController
 * @author Calnix [@cal_nix]
 * @notice Central contract managing verification fees, and related distribution.
 * @dev Integrates with external controllers and enforces protocol-level access and safety checks. 
 */

contract PaymentsController is EIP712, Pausable, LowLevelWMoca {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    // Contracts
    IAccessController public immutable accessController;
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

    // risk management
    uint256 public isFrozen;


//-------------------------------mappings-----------------------------------------------------
    
    // issuer, verifier, schema
    mapping(bytes32 issuerId => DataTypes.Issuer issuer) internal _issuers;
    mapping(bytes32 schemaId => DataTypes.Schema schema) internal _schemas;
    mapping(bytes32 verifierId => DataTypes.Verifier verifier) internal _verifiers;


    // nonces for preventing race conditions [ECDSA.sol::recover handles sig.malfunctions]
    // we do not store this in verifier struct since signerAddress is updatable
    mapping(address signerAddress => uint256 nonce) internal _verifierNonces;

    // Staking tiers: determines subsidy percentage for each verifier | admin fn will setup the tiers
    mapping(uint256 mocaStaked => uint256 subsidyPercentage) internal _verifiersSubsidyPercentages;


    // for VotingController.claimSubsidies(): track subsidies for each verifier, and pool, per epoch | getVerifierAndPoolAccruedSubsidies()
    mapping(uint256 epoch => mapping(bytes32 poolId => uint256 totalSubsidies)) internal _epochPoolSubsidies;                                                     // totalSubsidiesPerPoolPerEpoch
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(bytes32 verifierId => uint256 verifierTotalSubsidies))) internal _epochPoolVerifierSubsidies;      // totalSubsidiesPerPoolPerEpochPerVerifier
    
    // To track fees accrued to each pool, per epoch | for voting rewards tracking
    mapping(uint256 epoch => mapping(bytes32 poolId => DataTypes.FeesAccrued feesAccrued)) internal _epochPoolFeesAccrued;
    // for correct withdrawal of fees and rewards
    mapping(uint256 epoch => DataTypes.FeesAccrued feesAccrued) internal _epochFeesAccrued;    

//-------------------------------Constructor---------------------------------------------------------------------

    // name: PaymentsController, version: 1
    constructor(
        address accessController_, uint256 protocolFeePercentage, uint256 voterFeePercentage, uint256 delayPeriod, 
        address wMoca_, address usd8_, uint256 mocaTransferGasLimit,
        string memory name, string memory version) EIP712(name, version) {

        // check: access controller is set [Treasury should be non-zero]
        accessController = IAccessController(accessController_);
        require(accessController.TREASURY() != address(0), Errors.InvalidAddress());

        // check: wrapped moca is set
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // check: usd8 is set
        require(usd8_ != address(0), Errors.InvalidAddress());
        USD8 = IERC20(usd8_);

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;
      
        // check if fee percentages are valid [both fees can be 0]
        require(protocolFeePercentage + voterFeePercentage < Constants.PRECISION_BASE, Errors.InvalidPercentage());
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;
        VOTING_FEE_PERCENTAGE = voterFeePercentage;

        // min. delay period is 1 epoch; value must be in epoch intervals
        require(delayPeriod >= EpochMath.EPOCH_DURATION, Errors.InvalidDelayPeriod());
        require(EpochMath.isValidEpochTime(delayPeriod), Errors.InvalidDelayPeriod());
        FEE_INCREASE_DELAY_PERIOD = delayPeriod;
    }

//-------------------------------Issuer functions-----------------------------------------------------------------


    /**
     * @notice Generates and registers a new issuer with a unique issuerId.
     * @dev The issuerId is derived from msg.sender, ensuring uniqueness across issuers, verifiers, and schemas.
     * @param assetManagerAddress The address where issuer fees will be claimed.
     * @return issuerId The unique identifier assigned to the new issuer.
     */
    function createIssuer(address assetManagerAddress) external whenNotPaused returns (bytes32) {
        require(assetManagerAddress != address(0), Errors.InvalidAddress());

        bytes32 issuerId;
        // deterministic id generation: check if id already exists in ANY of the three mappings
        {
            uint256 salt = block.number;
            issuerId = keccak256(abi.encode("ISSUER", msg.sender, salt));
            while (
                _issuers[issuerId].issuerId != bytes32(0) 
                || _verifiers[issuerId].verifierId != bytes32(0) 
                || _schemas[issuerId].schemaId != bytes32(0)
            ) {
                issuerId = keccak256(abi.encode("ISSUER", msg.sender, ++salt));
            }
        }

        // STORAGE: setup issuer
        DataTypes.Issuer storage issuerPtr = _issuers[issuerId];
        issuerPtr.issuerId = issuerId;
        issuerPtr.adminAddress = msg.sender;
        issuerPtr.assetManagerAddress = assetManagerAddress;
        
        emit Events.IssuerCreated(issuerId, msg.sender, assetManagerAddress);

        return issuerId;
    }


    /**
     * @notice Creates a new schema for the specified issuer.
     * @dev Only the issuer admin can call this function. The schemaId is generated to be unique.
     * @param issuerId The unique id of the issuer creating the schema.
     * @param fee The fee for the schema, expressed in USD8 (6 decimals).
     * @return schemaId The unique id assigned to the new schema.
     */
    function createSchema(bytes32 issuerId, uint128 fee) external whenNotPaused returns (bytes32) {
        // caller must be issuer's admin address
        require(_issuers[issuerId].adminAddress == msg.sender, Errors.InvalidCaller());

        // sanity check: fee cannot be greater than 10_000 USD8
        // fee is an absolute value expressed in USD8 terms | free credentials are allowed
        require(fee < 10_000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // deterministic id generation: check if schemaId already exists in ANY of the three mappings
        uint256 totalSchemas = _issuers[issuerId].totalSchemas;
        bytes32 schemaId;
        {
            uint256 salt = block.number;
            schemaId = keccak256(abi.encode("SCHEMA", issuerId, totalSchemas, salt));
            while (
                _issuers[schemaId].issuerId != bytes32(0) 
                || _verifiers[schemaId].verifierId != bytes32(0) 
                || _schemas[schemaId].schemaId != bytes32(0)
            ) {
                schemaId = keccak256(abi.encode("SCHEMA", issuerId, totalSchemas, ++salt));
            }
        }

        // Increment schema count for issuer
        ++_issuers[issuerId].totalSchemas;

        // STORAGE: create schema
        DataTypes.Schema storage schemaPtr = _schemas[schemaId];
        schemaPtr.schemaId = schemaId;
        schemaPtr.issuerId = issuerId;
        schemaPtr.currentFee = fee;

        emit Events.SchemaCreated(schemaId, issuerId, fee);

        return schemaId;
    }

    /**
     * @notice Updates the fee for a given schema under a specific issuer.
     * @dev Only the issuer admin can call this function. Decreasing the fee applies immediately; increasing the fee is scheduled after a delay.
     * @param issuerId The unique identifier of the issuer.
     * @param schemaId The unique identifier of the schema to update.
     * @param newFee The new fee to set, expressed in USD8 (6 decimals).
     * @return newFee The new fee that was set. Returns value for better middleware integration.
     */
    function updateSchemaFee(bytes32 issuerId, bytes32 schemaId, uint128 newFee) external whenNotPaused returns (uint256) {        
        // cache pointers
        DataTypes.Issuer storage issuerPtr = _issuers[issuerId];
        DataTypes.Schema storage schemaPtr = _schemas[schemaId];

        // caller must be issuer's admin address
        require(issuerPtr.adminAddress == msg.sender, Errors.InvalidCaller());

        // check if schemaId is valid
        require(schemaPtr.schemaId != bytes32(0), Errors.InvalidId());

        // sanity check: fee cannot be greater than 10,000 USD8 | free credentials are allowed
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
     * @dev Only callable by the issuer's asset manager address. Transfers the total unclaimed fees to the issuer.
     * - Caller must match the issuer's asset manager address.
     * - There must be claimable fees available.
     * @param issuerId The unique identifier of the issuer to claim fees for.
     */
    function claimFees(bytes32 issuerId) external whenNotPaused {
        // cache pointers
        DataTypes.Issuer storage issuerPtr = _issuers[issuerId];

        // caller must be issuer's asset manager address
        require(issuerPtr.assetManagerAddress == msg.sender, Errors.InvalidCaller());

        uint256 claimableFees = issuerPtr.totalNetFeesAccrued - issuerPtr.totalClaimed;

        // check if issuer has claimable fees
        require(claimableFees > 0, Errors.NoClaimableFees());

        // overwrite .totalClaimed with .totalNetFeesAccrued
        issuerPtr.totalClaimed = issuerPtr.totalNetFeesAccrued;

        // update global counter
        TOTAL_CLAIMED_VERIFICATION_FEES += claimableFees;

        emit Events.IssuerFeesClaimed(issuerId, claimableFees);

        // transfer fees to issuer
        USD8.safeTransfer(msg.sender, claimableFees);
    }


//-------------------------------Verifier functions---------------------------------------------------------------

    /**
     * @notice Generates and registers a new verifier with a unique verifierId.
     * @dev The verifierId is derived from msg.sender, ensuring uniqueness across issuers, verifiers, and schemas.
     * @param signerAddress The address of the signer of the verifier.
     * @param assetManagerAddress The address where verifier fees will be claimed.
     * @return verifierId The unique identifier assigned to the new verifier.
     */
    function createVerifier(address signerAddress, address assetManagerAddress) external whenNotPaused returns (bytes32) {
        require(signerAddress != address(0), Errors.InvalidAddress());
        require(assetManagerAddress != address(0), Errors.InvalidAddress());

        bytes32 verifierId;
        // deterministic id generation: check if id already exists in ANY of the three mappings
        {
            uint256 salt = block.number;
            verifierId = keccak256(abi.encode("VERIFIER", msg.sender, salt));
            while (
                _issuers[verifierId].issuerId != bytes32(0) 
                || _verifiers[verifierId].verifierId != bytes32(0)
                || _schemas[verifierId].schemaId != bytes32(0)
            ) {
                verifierId = keccak256(abi.encode("VERIFIER", msg.sender, ++salt));
            }
        }

        // STORAGE: create verifier
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];
        verifierPtr.verifierId = verifierId;
        verifierPtr.adminAddress = msg.sender;
        verifierPtr.signerAddress = signerAddress;
        verifierPtr.assetManagerAddress = assetManagerAddress;

        emit Events.VerifierCreated(verifierId, msg.sender, signerAddress, assetManagerAddress);

        return verifierId;
    }


    /**
     * @notice Deposits USD8 into the verifier's balance.
     * @dev Only callable by the verifier's asset manager address. Increases the verifier's balance.
     * - Caller must match the verifier's asset manager address.
     * @param verifierId The unique identifier of the verifier to deposit for.
     * @param amount The amount of USD8 to deposit.
     */
    function deposit(bytes32 verifierId, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());
        
        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

        // caller must be verifier's asset manager address
        address assetManagerAddress = verifierPtr.assetManagerAddress;
        require(assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update balance
        verifierPtr.currentBalance += amount;

        emit Events.VerifierDeposited(verifierId, assetManagerAddress, amount);

        // transfer funds to verifier
        USD8.safeTransferFrom(msg.sender, address(this), amount);
    }


    /**
     * @notice Withdraws USD8 from the verifier's balance.
     * @dev Only callable by the verifier's asset manager address. Decreases the verifier's balance.
     * - Caller must match the verifier's asset manager address.
     * @param verifierId The unique identifier of the verifier to withdraw from.
     * @param amount The amount of USD8 to withdraw.
     */
    function withdraw(bytes32 verifierId, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

        // caller must be verifier's asset manager address
        address assetManagerAddress = verifierPtr.assetManagerAddress;
        require(assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough balance
        uint128 balance = verifierPtr.currentBalance;
        require(balance >= amount, Errors.InvalidAmount());

        // STORAGE: update balance
        verifierPtr.currentBalance -= amount;

        emit Events.VerifierWithdrew(verifierId, assetManagerAddress, amount);

        // transfer funds to verifier
        USD8.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Updates the signer address for a verifier.
     * @dev Only callable by the verifier's admin address. The new signer address must be non-zero and different from the current one.
     * @param verifierId The unique identifier of the verifier.
     * @param signerAddress The new signer address to set.
     */
    function updateSignerAddress(bytes32 verifierId, address signerAddress) external whenNotPaused {
        require(signerAddress != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

        // caller must be verifier's admin address
        require(verifierPtr.adminAddress == msg.sender, Errors.InvalidCaller());

        // check if new signer address is different from current one
        require(verifierPtr.signerAddress != signerAddress, Errors.InvalidAddress());

        // update signer address
        verifierPtr.signerAddress = signerAddress;

        emit Events.VerifierSignerAddressUpdated(verifierId, signerAddress);
    }


    /**
     * @notice Stakes MOCA for a verifier. Accepts native MOCA via msg.value.
     * @dev Only callable by the verifier's assetManagerAddress address. Increases the verifier's moca staked.
     * @param verifierId The unique identifier of the verifier to stake MOCA for.
     */
    function stakeMoca(bytes32 verifierId) external payable whenNotPaused {
        uint128 amount = uint128(msg.value);
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];
        
        // caller must be verifier's asset manager address
        address assetManagerAddress = verifierPtr.assetManagerAddress;
        require(assetManagerAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update moca staked
        verifierPtr.mocaStaked += amount;
        TOTAL_MOCA_STAKED += amount;

        emit Events.VerifierMocaStaked(verifierId, assetManagerAddress, amount);
    }


    /**
     * @notice Unstakes MOCA for a verifier.
     * @dev Only callable by the verifier's asset manager address. Decreases the verifier's moca staked.
     *      Transfers native MOCA via msg.value; if transfer fails within gas limit, wraps to wMoca and transfers the wMoca to verifier.
     * @param verifierId The unique identifier of the verifier to unstake MOCA for.
     * @param amount The amount of MOCA to unstake.
     */
    function unstakeMoca(bytes32 verifierId, uint128 amount) external payable whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

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

        emit Events.VerifierMocaUnstaked(verifierId, assetManagerAddress, amount);
    }

//------------------------------- updateAssetManagerAddress: common to both issuer and verifier ------------------

    /**
     * @notice Generic function to update the asset manager address for either an issuer or a verifier.
     * @dev Caller must be the admin of the provided ID. IDs are unique across types, preventing cross-updates.
     * @param id The unique identifier (issuerId or verifierId).
     * @param newAssetManagerAddress The new asset manager address to set.
     * @return newAssetManagerAddress The updated asset manager address.
     */
    function updateAssetManagerAddress(bytes32 id, address newAssetManagerAddress) external whenNotPaused returns (address) {
        require(newAssetManagerAddress != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.Issuer storage issuerPtr = _issuers[id];
        DataTypes.Verifier storage verifierPtr = _verifiers[id];

        if (issuerPtr.issuerId != bytes32(0)) {
            
            // Issuer update
            require(issuerPtr.adminAddress == msg.sender, Errors.InvalidCaller());
            issuerPtr.assetManagerAddress = newAssetManagerAddress;

        } else if (verifierPtr.verifierId != bytes32(0)) {

            // Verifier update
            require(verifierPtr.adminAddress == msg.sender, Errors.InvalidCaller());
            verifierPtr.assetManagerAddress = newAssetManagerAddress;
            
        } else {
            revert Errors.InvalidId();
        }

        emit Events.AssetManagerAddressUpdated(id, newAssetManagerAddress);
        return newAssetManagerAddress;
    }

//------------------------------- UniversalVerificationContract functions-----------------------------------------

    /**
     * @notice Deducts the verifier's balance for a verification, distributing protocol and voting fees.
     * @dev Gas optimized: minimizes storage reads/writes, by employing a hybrid storage-memory optimization pattern, and unchecked math where safe.
     *      Validates signature, updates schema fee if needed, and increments verifier nonce.
     * @param issuerId The unique identifier of the issuer.
     * @param verifierId The unique identifier of the verifier.
     * @param schemaId The unique identifier of the schema.
     * @param amount The fee amount to deduct (must match current schema fee).
     * @param expiry The signature expiry timestamp.
     * @param signature The EIP-712 signature from the verifier's signer address.
     */
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint128 amount, uint256 expiry, bytes calldata signature) external whenNotPaused {
        require(expiry > block.timestamp, Errors.SignatureExpired()); 
        require(amount > 0, Errors.InvalidAmount());
        
        // cache schema in memory (saves ~800 gas)
        DataTypes.Schema storage schemaStorage = _schemas[schemaId];
        DataTypes.Schema memory schema = schemaStorage; // Load once into memory
        
        // check if schema belongs to issuer
        require(schema.issuerId == issuerId, Errors.InvalidIssuer());

        //----- NextFee check -----
        uint128 currentFee = schema.currentFee;
        if (schema.nextFee > 0 && schema.nextFeeTimestamp <= block.timestamp) {
            // cache old fee + update currentFee
            uint128 oldFee = currentFee;
            currentFee = schema.nextFee;

            // Batch storage updates
            schemaStorage.currentFee = currentFee;
            delete schemaStorage.nextFee;
            delete schemaStorage.nextFeeTimestamp;
            emit Events.SchemaFeeIncreased(schemaId, oldFee, currentFee);
        }

        // Cache verifier data
        DataTypes.Verifier storage verifierStorage = _verifiers[verifierId];
        address signerAddress = verifierStorage.signerAddress;
        uint128 verifierBalance = verifierStorage.currentBalance;


        // ----- Verify signature + Update nonce -----
        {
            bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(Constants.DEDUCT_BALANCE_TYPEHASH, issuerId, verifierId, schemaId, amount, expiry, _verifierNonces[signerAddress])));
            // handles both EOA and contract signatures | returns true if signature is valid
            require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), Errors.InvalidSignature()); 
            ++_verifierNonces[signerAddress];

            // check if amount matches latest schema fee
            require(amount == currentFee, Errors.InvalidSchemaFee());
        }


        // ----- Combined fee calculation -----
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        uint128 protocolFee;
        uint128 votingFee;
        uint128 netFee;

        unchecked { // Safe because fees < 100%
            protocolFee = uint128((amount * PROTOCOL_FEE_PERCENTAGE) / Constants.PRECISION_BASE);
            votingFee = uint128((amount * VOTING_FEE_PERCENTAGE) / Constants.PRECISION_BASE);
            netFee = amount - protocolFee - votingFee;
        }

        //----- Batch storage updates -----
        bytes32 poolId = schema.poolId;

        // update verifier 
        require(verifierBalance >= amount, Errors.InsufficientBalance());
        verifierStorage.currentBalance = verifierBalance - amount;
        verifierStorage.totalExpenditure += amount;
        
        // update issuer
        DataTypes.Issuer storage issuerStorage = _issuers[issuerId];
        issuerStorage.totalNetFeesAccrued += netFee;
        unchecked { ++issuerStorage.totalVerified; }

        // update schema counters
        schemaStorage.totalGrossFeesAccrued += amount;

        // Pool-specific updates [for VotingController]
        {
            if(poolId != bytes32(0)) {
                // amount is uint128, but _bookSubsidy expects uint256 | acceptable since uint128 < uint256
                _bookSubsidy(verifierId, poolId, schemaId, amount, currentEpoch);
                
                // Batch pool fee updates
                DataTypes.FeesAccrued storage poolFees = _epochPoolFeesAccrued[currentEpoch][poolId];
                poolFees.feesAccruedToProtocol += protocolFee;
                poolFees.feesAccruedToVoters += votingFee;
            }
        }


        // Book fees: global + epoch [for AssetManager]
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[currentEpoch];
        epochFees.feesAccruedToProtocol += protocolFee;
        epochFees.feesAccruedToVoters += votingFee;
        // for emergency withdrawal
        TOTAL_PROTOCOL_FEES_UNCLAIMED += protocolFee;
        TOTAL_VOTING_FEES_UNCLAIMED += votingFee;

        emit Events.BalanceDeducted(verifierId, schemaId, issuerId, amount);
        
        // ----- Increment verification count -----
        unchecked { ++schemaStorage.totalVerified; }
        emit Events.SchemaVerified(schemaId);
    }

    /**
     * @notice Deducts a verifier's balance for a zero-fee schema verification, updating relevant counters.
     * @dev Requires the schema to have zero fee. Verifies the signature for the operation.
     *      Increments verification counters for the schema and issuer. Emits SchemaVerifiedZeroFee event.
     * @param issuerId The unique identifier of the issuer.
     * @param verifierId The unique identifier of the verifier.
     * @param schemaId The unique identifier of the schema.
     * @param expiry The timestamp after which the signature is invalid.
     * @param signature The EIP-712 signature from the verifier's signer address.
     */
    function deductBalanceZeroFee(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint256 expiry, bytes calldata signature) external whenNotPaused {
        require(expiry > block.timestamp, Errors.SignatureExpired());
        
        // Verify schema has zero fee
        require(_schemas[schemaId].currentFee == 0, Errors.InvalidSchemaFee());
        
        // Simplified signature verification: excludes amount/fee from signature check
        address signerAddress = _verifiers[verifierId].signerAddress;
        bytes32 hash = _hashTypedDataV4(
            keccak256(abi.encode(
                Constants.DEDUCT_BALANCE_ZERO_FEE_TYPEHASH,
                issuerId, 
                verifierId, 
                schemaId, 
                expiry, 
                _verifierNonces[signerAddress]
            ))
        );
        require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), Errors.InvalidSignature());
        
        // Update counters
        unchecked {
            ++_verifierNonces[signerAddress];
            ++_schemas[schemaId].totalVerified;
            ++_issuers[issuerId].totalVerified;
        }
        
        emit Events.SchemaVerifiedZeroFee(schemaId);
    }

 
//------------------------------- Internal functions--------------------------------------------------------------

    // for VotingController to identify how much subsidies owed to each verifier; based on their staking tier+expenditure
    // expectation: amount is non-zero
    function _bookSubsidy(bytes32 verifierId, bytes32 poolId, bytes32 schemaId, uint256 amount, uint256 currentEpoch) internal {
        // get verifier's subsidy percentage
        uint256 subsidyPct = _verifiersSubsidyPercentages[_verifiers[verifierId].mocaStaked];

        // if subsidy percentage is non-zero, calculate and book subsidy
        if(subsidyPct > 0) {
            // calculate subsidy
            uint256 subsidy = (amount * subsidyPct) / Constants.PRECISION_BASE;
            
            if(subsidy > 0) {
                // book verifier's subsidy
                _epochPoolSubsidies[currentEpoch][poolId] += subsidy;
                _epochPoolVerifierSubsidies[currentEpoch][poolId][verifierId] += subsidy;
                emit Events.SubsidyBooked(verifierId, poolId, schemaId, subsidy);
            }
        }
    }
   
//------------------------------- PaymentsControllerAdmin: update functions---------------------------------------

    // add/update/remove | can be 0 
    function updatePoolId(bytes32 schemaId, bytes32 poolId) external onlyPaymentsAdmin whenNotPaused {
        require(_schemas[schemaId].schemaId != bytes32(0), Errors.InvalidSchema());
        _schemas[schemaId].poolId = poolId;

        emit Events.PoolIdUpdated(schemaId, poolId);
    }

    function updateFeeIncreaseDelayPeriod(uint256 newDelayPeriod) external onlyPaymentsAdmin whenNotPaused {
        require(newDelayPeriod > 0, Errors.InvalidDelayPeriod());
        require(newDelayPeriod % EpochMath.EPOCH_DURATION == 0, Errors.InvalidDelayPeriod());

        FEE_INCREASE_DELAY_PERIOD = newDelayPeriod;

        emit Events.FeeIncreaseDelayPeriodUpdated(newDelayPeriod);
    }

    // protocol fee can be 0
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external onlyPaymentsAdmin whenNotPaused {
        // total fee percentage cannot be greater than 100%
        require(protocolFeePercentage + VOTING_FEE_PERCENTAGE < Constants.PRECISION_BASE, Errors.InvalidPercentage());

        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        emit Events.ProtocolFeePercentageUpdated(protocolFeePercentage);
    }

    // voter fee can be 0
    function updateVotingFeePercentage(uint256 votingFeePercentage) external onlyPaymentsAdmin whenNotPaused {
        // total fee percentage cannot be greater than 100%
        require(votingFeePercentage + PROTOCOL_FEE_PERCENTAGE < Constants.PRECISION_BASE, Errors.InvalidPercentage());
        
        VOTING_FEE_PERCENTAGE = votingFeePercentage;

        emit Events.VotingFeePercentageUpdated(votingFeePercentage);
    }

    // used to set/overwrite/update
    function updateVerifierSubsidyPercentages(uint256 mocaStaked, uint256 subsidyPercentage) external onlyPaymentsAdmin whenNotPaused {
        require(mocaStaked > 0, Errors.InvalidAmount());
        require(subsidyPercentage < Constants.PRECISION_BASE, Errors.InvalidPercentage());

        _verifiersSubsidyPercentages[mocaStaked] = subsidyPercentage;

        emit Events.VerifierStakingTierUpdated(mocaStaked, subsidyPercentage);
    }


    /**
     * @notice Sets the gas limit for moca transfer.
     * @dev Only callable by the PaymentsController admin.
     * @param newMocaTransferGasLimit The new gas limit for moca transfer.
     */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyPaymentsAdmin whenNotPaused {
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
    function withdrawProtocolFees(uint256 epoch) external onlyCronJob whenNotPaused {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());

        // get payments controller treasury address
        address paymentsControllerTreasury = accessController.PAYMENTS_CONTROLLER_TREASURY();
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
    function withdrawVotersFees(uint256 epoch) external onlyCronJob whenNotPaused {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());

        // get payments controller treasury address
        address paymentsControllerTreasury = accessController.PAYMENTS_CONTROLLER_TREASURY();
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

//------------------------------- Risk-related functions ---------------------------------------------------------

    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external onlyMonitor whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external onlyGlobalAdmin whenPaused {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external onlyGlobalAdmin whenPaused {
        if(isFrozen == 1) revert Errors.IsFrozen();
        isFrozen = 1;
        emit Events.ContractFrozen();
    }  

    /**
     * @notice Transfers all verifiers' remaining balances to their registered asset addresses during emergency exit.
     * @dev If called by an verifier, they should pass an array of length 1 with their own verifierId.
     *      If called by the emergency exit handler, they should pass an array of length > 1 with the verifierIds of the verifiers to exit.
     *      Can only be called when the contract is frozen.
     *      Iterates through the provided verifierIds, transferring each non-zero balance to the corresponding asset manager address.
     *      Skips verifiers with zero balance.
     * @param verifierIds Array of verifier identifiers whose balances will be exfil'd.
     */
    function emergencyExitVerifiers(bytes32[] calldata verifierIds) external payable {
        if(isFrozen == 0) revert Errors.NotFrozen();
        if(verifierIds.length == 0) revert Errors.InvalidArray();
   
        // if anything other than a valid verifierId is given, will retrieve either empty struct and skip
        for(uint256 i; i < verifierIds.length; ++i) {
            
            // cache pointer
            DataTypes.Verifier storage verifierPtr = _verifiers[verifierIds[i]];

            // check: if NOT emergency exit handler, AND NOT, the verifier themselves: revert
            if (!accessController.isEmergencyExitHandler(msg.sender)) {
                if (msg.sender != verifierPtr.adminAddress) {
                    revert Errors.OnlyCallableByEmergencyExitHandlerOrVerifier();
                }
            }

            // get balance: if 0, skip
            uint256 verifierBalance = verifierPtr.currentBalance;
            uint256 verifierMocaStaked = verifierPtr.mocaStaked;
            if(verifierBalance == 0 && verifierMocaStaked == 0) continue;

            // get asset manager address
            address verifierAssetManagerAddress = verifierPtr.assetManagerAddress;

            // reset balance and moca staked
            delete verifierPtr.currentBalance;
            delete verifierPtr.mocaStaked;

            // transfer balance and moca to verifier
            if(verifierBalance > 0) USD8.safeTransfer(verifierAssetManagerAddress, verifierBalance);
            if(verifierMocaStaked > 0) _transferMocaAndWrapIfFailWithGasLimit(WMOCA, verifierAssetManagerAddress, verifierMocaStaked, MOCA_TRANSFER_GAS_LIMIT);
        }

        emit Events.EmergencyExitVerifiers(verifierIds);
    }

    /**
     * @notice Transfers all issuers' unclaimed fees to their registered asset addresses during emergency exit.
     * @dev If called by an issuer, they should pass an array of length 1 with their own issuerId.
     *      If called by the emergency exit handler, they should pass an array of length > 1 with the issuerIds of the issuers to exit.
     *      Can only be called when the contract is frozen.
     *      Iterates through the provided issuerIds, transferring each non-zero unclaimed fees to the corresponding asset manager address.
     *      Skips issuers with zero unclaimed fees.
     * @param issuerIds Array of issuer identifiers whose unclaimed fees will be exfil'd.
     */
    function emergencyExitIssuers(bytes32[] calldata issuerIds) external {
        if(isFrozen == 0) revert Errors.NotFrozen();
        if(issuerIds.length == 0) revert Errors.InvalidArray();

        // if anything other than a valid issuerId is given, will retrieve either empty struct and skip
        for(uint256 i; i < issuerIds.length; ++i) {
            
            // cache pointer
            DataTypes.Issuer storage issuerPtr = _issuers[issuerIds[i]];

            // check: if NOT emergency exit handler, AND NOT, the issuer themselves: revert
            if (!accessController.isEmergencyExitHandler(msg.sender)) {
                if (msg.sender != issuerPtr.adminAddress) {
                    revert Errors.OnlyCallableByEmergencyExitHandlerOrIssuer();
                }
            }

            // get unclaimed fees: if 0, skip
            uint256 unclaimedFees = issuerPtr.totalNetFeesAccrued - issuerPtr.totalClaimed;
            if(unclaimedFees == 0) continue;

            // increment total claimed fees
            issuerPtr.totalClaimed = issuerPtr.totalNetFeesAccrued;

            // transfer fees to issuer
            USD8.safeTransfer(issuerPtr.assetManagerAddress, unclaimedFees);
        }

        emit Events.EmergencyExitIssuers(issuerIds);
    }

    /**
     * @notice Transfers all unclaimed protocol and voting fees to the treasury during emergency exit.
     * @dev Callable only by the emergency exit handler when the contract is frozen.
     *      Transfers the sum of unclaimed fees to payments controller treasury address.
     *      Resets the unclaimed fee counters to zero after transfer.
     */
    function emergencyExitFees() external onlyEmergencyExitHandler {
        if(isFrozen == 0) revert Errors.NotFrozen();

        // get treasury address
        address paymentsControllerTreasury = accessController.PAYMENTS_CONTROLLER_TREASURY();
        require(paymentsControllerTreasury != address(0), Errors.InvalidAddress());

        // sanity check: there must be unclaimed fees to claim
        uint256 totalUnclaimedFees = TOTAL_PROTOCOL_FEES_UNCLAIMED + TOTAL_VOTING_FEES_UNCLAIMED;
        if(totalUnclaimedFees == 0) revert Errors.NoFeesToClaim();

        // reset counters
        delete TOTAL_PROTOCOL_FEES_UNCLAIMED;
        delete TOTAL_VOTING_FEES_UNCLAIMED;
        
        // transfer fees to treasury
        USD8.safeTransfer(paymentsControllerTreasury, totalUnclaimedFees);

        emit Events.EmergencyExitFees(paymentsControllerTreasury, totalUnclaimedFees);
    }
    

//------------------------------- Modifiers ----------------------------------------------------------------------

    modifier onlyMonitor() {
        require(accessController.isMonitor(msg.sender), Errors.OnlyCallableByMonitor());
        _;
    }

    modifier onlyPaymentsAdmin() {
        require(accessController.isPaymentsControllerAdmin(msg.sender), Errors.OnlyCallableByPaymentsControllerAdmin());
        _;
    }

    modifier onlyGlobalAdmin() {
        require(accessController.isGlobalAdmin(msg.sender), Errors.OnlyCallableByGlobalAdmin());
        _;
    }   

    modifier onlyCronJob() {
        require(accessController.isCronJob(msg.sender), Errors.OnlyCallableByCronJob());
        _;
    }

    modifier onlyEmergencyExitHandler() {
        require(accessController.isEmergencyExitHandler(msg.sender), Errors.OnlyCallableByEmergencyExitHandler());
        _;
    }


//------------------------------- View functions ------------------------------------------------------------------
   
    // note: called by VotingController.claimSubsidies | no need for zero address check on the caller
    /**
     * @notice Returns the total subsidies per epoch, for a pool and {verifier, pool}.
     * @param epoch The epoch.
     * @param poolId The pool id.
     * @param verifierId The verifier id.
     * @param caller The verifier's asset manager address. [Called through VotingController.claimSubsidies()].
     * @return verifierAccruedSubsidies The total subsidies for the {verifier, pool}, for the epoch.
     * @return poolAccruedSubsidies The total subsidies for the pool, for the epoch.
     */
    function getVerifierAndPoolAccruedSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId, address caller) external view returns (uint256, uint256) {
        // verifiers's asset manager address must be the caller of VotingController.claimSubsidies
        require(caller == _verifiers[verifierId].assetManagerAddress, Errors.InvalidCaller());
        return (_epochPoolVerifierSubsidies[epoch][poolId][verifierId], _epochPoolSubsidies[epoch][poolId]);
    }

    /**
     * @notice Returns the Issuer struct for a given issuerId.
     * @param issuerId The unique identifier of the issuer.
     * @return issuer The Issuer struct containing all issuer data.
     */
    function getIssuer(bytes32 issuerId) external view returns (DataTypes.Issuer memory) {
        return _issuers[issuerId];
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
     * @notice Returns the Verifier struct for a given verifierId.
     * @param verifierId The unique identifier of the verifier.
     * @return verifier The Verifier struct containing all verifier data.
     */
    function getVerifier(bytes32 verifierId) external view returns (DataTypes.Verifier memory) {
        return _verifiers[verifierId];
    }

    /**
     * @notice Returns the nonce for a given signerAddress.
     * @param signerAddress The address of the signer.
     * @return nonce The nonce for the signer.
     */
    function getVerifierNonce(address signerAddress) external view returns (uint256) {
        return _verifierNonces[signerAddress];
    }

    /**
     * @notice Returns the subsidy percentage for a given moca staked.
     * @param mocaStaked The amount of moca staked.
     * @return subsidyPercentage The subsidy percentage.
     */
    function getVerifierSubsidyPercentage(uint256 mocaStaked) external view returns (uint256) {
        return _verifiersSubsidyPercentages[mocaStaked];
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
     * @param verifierId The verifier id.
     * @return totalSubsidies The total subsidies for the pool and verifier and epoch.
     */
    function getEpochPoolVerifierSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId) external view returns (uint256) {
        return _epochPoolVerifierSubsidies[epoch][poolId][verifierId];
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
}