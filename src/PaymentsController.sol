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
import {IAddressBook} from "./interfaces/IAddressBook.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";


/**
 * @title PaymentsController
 * @author Calnix [@cal_nix]
 * @notice Central contract managing verification fees, and related distribution.
 * @dev Integrates with external controllers and enforces protocol-level access and safety checks. 
 */



contract PaymentsController is EIP712, Pausable {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    IAddressBook public immutable addressBook;

    // fees: 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 public PROTOCOL_FEE_PERCENTAGE;    
    uint256 public VOTING_FEE_PERCENTAGE;   

    // delay period before an issuer's fee increase becomes effective for a given schema
    uint256 public FEE_INCREASE_DELAY_PERIOD;            // in seconds

    // total claimed by issuers | proxy for total verification fees accrued - to reduce storage updates in deductBalance()
    uint256 public TOTAL_CLAIMED_VERIFICATION_FEES;   // expressed in USD8 terms

    // staked by verifiers
    uint256 public TOTAL_MOCA_STAKED;

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

//-------------------------------constructor-----------------------------------------

    // name: PaymentsController, version: 1
    constructor(
        address addressBook_, uint256 protocolFeePercentage, uint256 voterFeePercentage, uint256 delayPeriod, 
        string memory name, string memory version) EIP712(name, version) {

        // check if addressBook is valid
        require(addressBook_ != address(0), Errors.InvalidAddress());
        addressBook = IAddressBook(addressBook_);
      
        // check if protocol fee percentage is valid
        require(protocolFeePercentage < Constants.PRECISION_BASE, Errors.InvalidPercentage());
        require(protocolFeePercentage > 0, Errors.InvalidPercentage());
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        // check if voter fee percentage is valid
        require(voterFeePercentage < Constants.PRECISION_BASE, Errors.InvalidPercentage());
        require(voterFeePercentage > 0, Errors.InvalidPercentage());
        VOTING_FEE_PERCENTAGE = voterFeePercentage;

        // min. delay period is 1 epoch; value must be in epoch intervals
        require(delayPeriod >= EpochMath.EPOCH_DURATION, Errors.InvalidDelayPeriod());
        require(EpochMath.isValidEpochTime(delayPeriod), Errors.InvalidDelayPeriod());
        FEE_INCREASE_DELAY_PERIOD = delayPeriod;
    }

//-------------------------------issuer functions-----------------------------------------

    /**
     * @notice Generates and registers a new issuer with a unique issuerId.
     * @dev The issuerId is derived from the sender and asset address, ensuring uniqueness across issuers, verifiers, and schemas.
     * @param assetAddress The address where issuer fees will be claimed.
     * @return issuerId The unique identifier assigned to the new issuer.
     */
    function createIssuer(address assetAddress) external whenNotPaused returns (bytes32) {
        require(assetAddress != address(0), Errors.InvalidAddress());

        // generate issuerId
        bytes32 issuerId;
        {
            uint256 salt = block.number; 
            issuerId = _generateId(salt, msg.sender, assetAddress);
            // generated id must be unique: if used by issuer, verifier or schema, generate new Id
            while (_issuers[issuerId].issuerId != bytes32(0) || _verifiers[issuerId].verifierId != bytes32(0) || _schemas[issuerId].schemaId != bytes32(0)) {
                issuerId = _generateId(++salt, msg.sender, assetAddress); 
            }
        }

        // STORAGE: setup issuer
        DataTypes.Issuer storage issuerPtr = _issuers[issuerId];
        issuerPtr.issuerId = issuerId;
        issuerPtr.adminAddress = msg.sender;
        issuerPtr.assetAddress = assetAddress;
        
        emit Events.IssuerCreated(issuerId, msg.sender, assetAddress);

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

        // cache pointers
        DataTypes.Issuer storage issuerPtr = _issuers[issuerId];
        DataTypes.Verifier storage verifierPtr = _verifiers[issuerId];
        DataTypes.Schema storage schemaPtr = _schemas[issuerId];

        // check if issuerId matches msg.sender
        require(issuerPtr.adminAddress == msg.sender, Errors.InvalidCaller());

        // sanity check: fee cannot be greater than 1000 USD8
        // fee is an absolute value expressed in USD8 terms | free credentials are allowed
        require(fee < 1000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // generate schemaId
        bytes32 schemaId;
        {
            uint256 salt = block.number; 
            schemaId = _generateSchemaId(salt, issuerId);
            // If generated id must be unique: if used by issuer, verifier or schema, generate new Id
            while (schemaPtr.schemaId != bytes32(0) || verifierPtr.verifierId != bytes32(0) || issuerPtr.issuerId != bytes32(0)) {
                schemaId = _generateSchemaId(++salt, issuerId);
            }
        }

        // STORAGE: create schema
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

        // check if issuerId matches msg.sender
        require(issuerPtr.adminAddress == msg.sender, Errors.InvalidCaller());

        // check if schemaId is valid
        require(schemaPtr.schemaId != bytes32(0), Errors.InvalidId());

        // sanity check: fee cannot be greater than 10,000 USD8 | free credentials are allowed
        require(newFee < 10_000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // decrementing fee is applied immediately
        uint256 currentFee = schemaPtr.currentFee;
        if(newFee < currentFee) {
            schemaPtr.currentFee = newFee;

            emit Events.SchemaFeeReduced(schemaId, newFee, currentFee);

        } else {
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
     * @dev Only callable by the issuer's asset address. Transfers the total unclaimed fees to the issuer.
     * - Caller must match the issuer's asset address.
     * - There must be claimable fees available.
     * @param issuerId The unique identifier of the issuer to claim fees for.
     */
    function claimFees(bytes32 issuerId) external whenNotPaused {
        // cache pointers
        DataTypes.Issuer storage issuerPtr = _issuers[issuerId];

        // check if issuerId matches msg.sender
        require(issuerPtr.assetAddress == msg.sender, Errors.InvalidCaller());

        uint256 claimableFees = issuerPtr.totalNetFeesAccrued - issuerPtr.totalClaimed;

        // check if issuer has claimable fees
        require(claimableFees > 0, Errors.NoClaimableFees());

        // overwrite .totalClaimed with .totalNetFeesAccrued
        issuerPtr.totalClaimed = issuerPtr.totalNetFeesAccrued;

        // update global counter
        TOTAL_CLAIMED_VERIFICATION_FEES += claimableFees;

        emit Events.IssuerFeesClaimed(issuerId, claimableFees);

        // transfer fees to issuer
        _usd8().safeTransfer(msg.sender, claimableFees);
    }


//-------------------------------verifier functions-----------------------------------------

    /**
     * @notice Generates and registers a new verifier with a unique verifierId.
     * @dev The verifierId is derived from the sender and asset address, ensuring uniqueness across issuers, verifiers, and schemas.
     * @param signerAddress The address of the signer of the verifier.
     * @param assetAddress The address where verifier fees will be claimed.
     * @return verifierId The unique identifier assigned to the new verifier.
     */
    function createVerifier(address signerAddress, address assetAddress) external whenNotPaused returns (bytes32) {
        require(signerAddress != address(0), Errors.InvalidAddress());
        require(assetAddress != address(0), Errors.InvalidAddress());

        // generate verifierId
        bytes32 verifierId;
        {
            uint256 salt = block.number; 
            verifierId = _generateId(salt, msg.sender, assetAddress);
            // If generated id must be unique: if used by issuer, verifier or schema, generate new Id
            while (_verifiers[verifierId].verifierId != bytes32(0) || _issuers[verifierId].issuerId != bytes32(0) || _schemas[verifierId].schemaId != bytes32(0)) {
                verifierId = _generateId(++salt, msg.sender, assetAddress); 
            }
        }

        // STORAGE: create verifier
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];
        verifierPtr.verifierId = verifierId;
        verifierPtr.adminAddress = msg.sender;
        verifierPtr.signerAddress = signerAddress;
        verifierPtr.assetAddress = assetAddress;

        emit Events.VerifierCreated(verifierId, msg.sender, signerAddress, assetAddress);

        return verifierId;
    }


    /**
     * @notice Deposits USD8 into the verifier's balance.
     * @dev Only callable by the verifier's asset address. Increases the verifier's balance.
     * - Caller must match the verifier's asset address.
     * @param verifierId The unique identifier of the verifier to deposit for.
     * @param amount The amount of USD8 to deposit.
     */
    function deposit(bytes32 verifierId, uint128 amount) external whenNotPaused {
        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

        // check msg.sender is verifierId's asset address
        address assetAddress = verifierPtr.assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update balance
        verifierPtr.currentBalance += amount;

        emit Events.VerifierDeposited(verifierId, assetAddress, amount);

        // transfer funds to verifier
        _usd8().safeTransferFrom(msg.sender, address(this), amount);
    }


    /**
     * @notice Withdraws USD8 from the verifier's balance.
     * @dev Only callable by the verifier's asset address. Decreases the verifier's balance.
     * - Caller must match the verifier's asset address.
     * @param verifierId The unique identifier of the verifier to withdraw from.
     * @param amount The amount of USD8 to withdraw.
     */
    function withdraw(bytes32 verifierId, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

        // check msg.sender is verifierId's asset address
        address assetAddress = verifierPtr.assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough balance
        uint128 balance = verifierPtr.currentBalance;
        require(balance >= amount, Errors.InvalidAmount());

        // STORAGE: update balance
        verifierPtr.currentBalance -= amount;

        emit Events.VerifierWithdrew(verifierId, assetAddress, amount);

        // transfer funds to verifier
        _usd8().safeTransfer(msg.sender, amount);
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

        // check msg.sender is verifierId's admin address
        require(verifierPtr.adminAddress == msg.sender, Errors.InvalidCaller());

        // check if new signer address is different from current one
        require(verifierPtr.signerAddress != signerAddress, Errors.InvalidAddress());

        // update signer address
        verifierPtr.signerAddress = signerAddress;

        emit Events.VerifierSignerAddressUpdated(verifierId, signerAddress);
    }


    /**
     * @notice Stakes MOCA for a verifier.
     * @dev Only callable by the verifier's assetAddress address. Increases the verifier's moca staked.
     * @param verifierId The unique identifier of the verifier to stake MOCA for.
     * @param amount The amount of MOCA to stake.
     */
    function stakeMoca(bytes32 verifierId, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];
        
        // check msg.sender is verifierId's asset address
        address assetAddress = verifierPtr.assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update moca staked
        verifierPtr.mocaStaked += amount;
        TOTAL_MOCA_STAKED += amount;

        // transfer Moca to verifier
        _moca().safeTransferFrom(msg.sender, address(this), amount);

        emit Events.VerifierMocaStaked(verifierId, assetAddress, amount);
    }


    /**
     * @notice Unstakes MOCA for a verifier.
     * @dev Only callable by the verifier's asset address. Decreases the verifier's moca staked.
     * @param verifierId The unique identifier of the verifier to unstake MOCA for.
     * @param amount The amount of MOCA to unstake.
     */
    function unstakeMoca(bytes32 verifierId, uint128 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        // cache pointer
        DataTypes.Verifier storage verifierPtr = _verifiers[verifierId];

        // check msg.sender is verifierId's asset address
        address assetAddress = verifierPtr.assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough moca staked
        require(verifierPtr.mocaStaked >= amount, Errors.InvalidAmount());

        // STORAGE: update moca staked
        verifierPtr.mocaStaked -= amount;
        TOTAL_MOCA_STAKED -= amount;

        // transfer Moca to verifier
        _moca().safeTransfer(msg.sender, amount);

        emit Events.VerifierMocaUnstaked(verifierId, assetAddress, amount);
    }

//-------------------------------updateAssetAddress: common to both issuer and verifier -----------------------------------------

    /**
     * @notice Generic function to update the asset address for either an issuer or a verifier.
     * @dev Caller must be the admin of the provided ID. IDs are unique across types, preventing cross-updates.
     * @param id The unique identifier (issuerId or verifierId).
     * @param newAssetAddress The new asset address to set.
     * @return newAssetAddress The updated asset address.
     */
    function updateAssetAddress(bytes32 id, address newAssetAddress) external whenNotPaused returns (address) {
        require(newAssetAddress != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.Issuer storage issuerPtr = _issuers[id];
        DataTypes.Verifier storage verifierPtr = _verifiers[id];

        if (issuerPtr.issuerId != bytes32(0)) {
            
            // Issuer update
            require(issuerPtr.adminAddress == msg.sender, Errors.InvalidCaller());
            issuerPtr.assetAddress = newAssetAddress;

        } else if (verifierPtr.verifierId != bytes32(0)) {

            // Verifier update
            require(verifierPtr.adminAddress == msg.sender, Errors.InvalidCaller());
            verifierPtr.assetAddress = newAssetAddress;
            
        } else {
            revert Errors.InvalidId();
        }

        emit Events.AssetAddressUpdated(id, newAssetAddress);
        return newAssetAddress;
    }

    /**
     * @notice Generic function to update the admin address for either an issuer or a verifier.
     * @dev Caller must be the current admin of the provided ID. IDs are unique across types, preventing cross-updates.
     * @param id The unique identifier (issuerId or verifierId).
     * @param newAdminAddress The new admin address to set.
     * @return newAdminAddress The updated admin address.
     */
    function updateAdminAddress(bytes32 id, address newAdminAddress) external whenNotPaused returns (address) {
        require(newAdminAddress != address(0), Errors.InvalidAddress());

        // cache pointer
        DataTypes.Issuer storage issuerPtr = _issuers[id];
        DataTypes.Verifier storage verifierPtr = _verifiers[id];

        if (issuerPtr.issuerId != bytes32(0)) {
            // Issuer admin update
            require(issuerPtr.adminAddress == msg.sender, Errors.InvalidCaller());
            _issuers[id].adminAddress = newAdminAddress;
            
        } else if (verifierPtr.verifierId != bytes32(0)) {
            // Verifier admin update
            require(verifierPtr.adminAddress == msg.sender, Errors.InvalidCaller());
            verifierPtr.adminAddress = newAdminAddress;
            
        } else {
            revert Errors.InvalidId();
        }

        emit Events.AdminAddressUpdated(id, newAdminAddress);
        return newAdminAddress;
    }


//-------------------------------UniversalVerificationContract functions-----------------------------------------

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
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(Constants.DEDUCT_BALANCE_TYPEHASH, issuerId, verifierId, schemaId, amount, expiry, _verifierNonces[signerAddress])));
        // handles both EOA and contract signatures | returns true if signature is valid
        require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), Errors.InvalidSignature()); 
        ++_verifierNonces[signerAddress];

        // check if amount matches latest schema fee
        require(amount == currentFee, Errors.InvalidSchemaFee());
        

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
        if(poolId != bytes32(0)) {
            // amount is uint128, but _bookSubsidy expects uint256 | acceptable since uint128 < uint256
            _bookSubsidy(verifierId, poolId, schemaId, amount, currentEpoch);
            
            // Batch pool fee updates
            DataTypes.FeesAccrued storage poolFees = _epochPoolFeesAccrued[currentEpoch][poolId];
            poolFees.feesAccruedToProtocol += protocolFee;
            poolFees.feesAccruedToVoters += votingFee;
        }

        // Global epoch fees [for AssetManager]
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[currentEpoch];
        epochFees.feesAccruedToProtocol += protocolFee;
        epochFees.feesAccruedToVoters += votingFee;

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

 
//-------------------------------internal functions---------------------------------------------

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

    ///@dev Generate a issuer or verifier id. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    // adminAddress: msg.sender
    function _generateId(uint256 salt, address adminAddress, address assetAddress) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(adminAddress, assetAddress, block.timestamp, salt)));
    }


    function _generateSchemaId(uint256 salt, bytes32 issuerId) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(issuerId, block.timestamp, salt)));
    }
    
    // if zero address, reverts automatically
    function _usd8() internal view returns (IERC20) {
        return IERC20(addressBook.getUSD8Token());
    }
    
    // if zero address, reverts automatically
    function _moca() internal view returns (IERC20){
        return IERC20(addressBook.getMoca());
    }

//-------------------------------admin: update functions-----------------------------------------

    // add/update/remove | can be 0 
    function updatePoolId(bytes32 schemaId, bytes32 poolId) external onlyPaymentsAdmin whenNotPaused {
        require(_schemas[schemaId].schemaId != bytes32(0), "Schema does not exist");
        _schemas[schemaId].poolId = poolId;

        emit Events.PoolIdUpdated(schemaId, poolId);
    }

    function updateFeeIncreaseDelayPeriod(uint256 newDelayPeriod) external onlyPaymentsAdmin whenNotPaused {
        require(newDelayPeriod > 0, "Invalid delay period");
        require(newDelayPeriod % EpochMath.EPOCH_DURATION == 0, "Delay period must be a multiple of epoch duration");

        FEE_INCREASE_DELAY_PERIOD = newDelayPeriod;

        emit Events.FeeIncreaseDelayPeriodUpdated(newDelayPeriod);
    }

    // protocol fee can be 0
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external onlyPaymentsAdmin whenNotPaused {
        // protocol fee cannot be greater than 100%
        require(protocolFeePercentage < Constants.PRECISION_BASE, "Invalid protocol fee percentage");
        // total fee percentage cannot be greater than 100%
        require(protocolFeePercentage + VOTING_FEE_PERCENTAGE < Constants.PRECISION_BASE, "Invalid protocol fee percentage");

        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        emit Events.ProtocolFeePercentageUpdated(protocolFeePercentage);
    }

    // voter fee can be 0
    function updateVotingFeePercentage(uint256 votingFeePercentage) external onlyPaymentsAdmin whenNotPaused {
        // voter fee cannot be greater than 100%
        require(votingFeePercentage < Constants.PRECISION_BASE, "Invalid voting fee percentage");
        // total fee percentage cannot be greater than 100%
        require(votingFeePercentage + PROTOCOL_FEE_PERCENTAGE < Constants.PRECISION_BASE, "Invalid voting fee percentage");
        
        VOTING_FEE_PERCENTAGE = votingFeePercentage;

        emit Events.VotingFeePercentageUpdated(votingFeePercentage);
    }

    // used to set/overwrite/update
    function updateVerifierSubsidyPercentages(uint256 mocaStaked, uint256 subsidyPercentage) external onlyPaymentsAdmin whenNotPaused {
        require(mocaStaked > 0, "Invalid moca staked");
        require(subsidyPercentage < Constants.PRECISION_BASE, "Invalid subsidy percentage");

        _verifiersSubsidyPercentages[mocaStaked] = subsidyPercentage;

        emit Events.VerifierStakingTierUpdated(mocaStaked, subsidyPercentage);
    }

//-------------------------------admin: withdraw functions----------------------------------------

    /**
     * @notice Allows withdrawal of protocol fees only after the specified epoch has ended.
     * @dev Protocol fees for a given epoch can be withdrawn once per epoch, after the epoch is finalized.
     * @param epoch The epoch number for which to withdraw protocol fees.
     */
    function withdrawProtocolFees(uint256 epoch) external onlyAssetManager whenNotPaused {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());

        // cache pointer
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[epoch];

        require(!epochFees.isProtocolFeeWithdrawn, Errors.ProtocolFeeAlreadyWithdrawn());

        uint256 protocolFees = epochFees.feesAccruedToProtocol;
        require(protocolFees > 0, Errors.ZeroProtocolFee());

        // get treasury address
        address treasury = addressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());

        // update flag
        epochFees.isProtocolFeeWithdrawn = true;
        emit Events.ProtocolFeesWithdrawn(epoch, protocolFees);

        _usd8().safeTransfer(treasury, protocolFees);
    }

    /**
     * @notice Allows withdrawal of voters fees only after the specified epoch has ended.
     * @dev Voters fees for a given epoch can be withdrawn once per epoch, after the epoch is finalized.
     * @param epoch The epoch number for which to withdraw voters fees.
     */
    function withdrawVotersFees(uint256 epoch) external onlyAssetManager whenNotPaused {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());

        // cache pointer
        DataTypes.FeesAccrued storage epochFees = _epochFeesAccrued[epoch];

        require(!epochFees.isVotersFeeWithdrawn, Errors.VotersFeeAlreadyWithdrawn());

        uint256 votersFees = epochFees.feesAccruedToVoters;
        require(votersFees > 0, Errors.ZeroVotersFee());

        // get treasury address
        address treasury = addressBook.getTreasury();
        require(treasury != address(0), Errors.InvalidAddress());

        // update flag
        epochFees.isVotersFeeWithdrawn = true;
        emit Events.VotersFeesWithdrawn(epoch, votersFees);

        _usd8().safeTransfer(treasury, votersFees);
    }

//------------------------------- risk ----------------------------------------------------------

    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external onlyMonitor whenNotPaused {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
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
     * @dev Callable only by the emergency exit handler when the contract is frozen.
     *      Iterates through the provided verifierIds, transferring each non-zero balance to the corresponding asset address.
     *      Skips verifiers with zero balance.
     * @param verifierIds Array of verifier identifiers whose balances will be exfil'd.
     */
    function emergencyExitVerifiers(bytes32[] calldata verifierIds) external onlyEmergencyExitHandler {
        if(isFrozen == 0) revert Errors.NotFrozen();
        if(verifierIds.length == 0) revert Errors.InvalidArray();
   
        // if issuerId is given, will retrieve either empty or wrong struct
        for(uint256 i; i < verifierIds.length; ++i) {
            
            // cache pointer
            DataTypes.Verifier storage verifierPtr = _verifiers[verifierIds[i]];

            // get balance: if 0, skip
            uint256 verifierBalance = verifierPtr.currentBalance;
            if(verifierBalance == 0) continue;

            // get asset address
            address verifierAssetAddress = verifierPtr.assetAddress;

            // transfer balance to verifier
            _usd8().safeTransfer(verifierAssetAddress, verifierBalance);
        }

        emit Events.EmergencyExitVerifiers(verifierIds);
    }

    /**
     * @notice Transfers all issuers' unclaimed fees to their registered asset addresses during emergency exit.
     * @dev Callable only by the emergency exit handler when the contract is frozen.
     *      Iterates through the provided issuerIds, transferring each non-zero balance to the corresponding asset address.
     *      Skips issuers with zero balance.
     * @param issuerIds Array of issuer identifiers whose balances will be exfil'd.
     */
    function emergencyExitIssuers(bytes32[] calldata issuerIds) external onlyEmergencyExitHandler {
        if(isFrozen == 0) revert Errors.NotFrozen();
        if(issuerIds.length == 0) revert Errors.InvalidArray();

        // if issuerId is given, will retrieve either empty or wrong struct
        for(uint256 i; i < issuerIds.length; ++i) {
            
            // cache pointer
            DataTypes.Issuer storage issuerPtr = _issuers[issuerIds[i]];

            // get unclaimed fees: if 0, skip
            uint256 issuerBalance = issuerPtr.totalNetFeesAccrued - issuerPtr.totalClaimed;
            if(issuerBalance == 0) continue;

            // get asset address
            address issuerAssetAddress = issuerPtr.assetAddress;

            // transfer balance to issuer
            _usd8().safeTransfer(issuerAssetAddress, issuerBalance);
        }

        emit Events.EmergencyExitIssuers(issuerIds);
    }


//------------------------------- modifiers -------------------------------------------------------

    modifier onlyMonitor() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isMonitor(msg.sender), Errors.OnlyCallableByMonitor());
        _;
    }

    modifier onlyPaymentsAdmin() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isPaymentsControllerAdmin(msg.sender), Errors.OnlyCallableByPaymentsControllerAdmin());
        _;
    }

    modifier onlyGlobalAdmin() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isGlobalAdmin(msg.sender), Errors.OnlyCallableByGlobalAdmin());
        _;
    }   

    modifier onlyAssetManager() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isAssetManager(msg.sender), Errors.OnlyCallableByAssetManager());
        _;
    }

    modifier onlyEmergencyExitHandler() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isEmergencyExitHandler(msg.sender), Errors.OnlyCallableByEmergencyExitHandler());
        _;
    }


//-------------------------------view functions---------------------------------------------
   
    // note: called by VotingController.claimSubsidies | no need for zero address check on the caller
    function getVerifierAndPoolAccruedSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId, address caller) external view returns (uint256, uint256) {
        // verifiers's asset address must be the caller of VotingController.claimSubsidies
        require(caller == _verifiers[verifierId].assetAddress, Errors.InvalidCaller());
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

    function getVerifierSubsidyPercentage(uint256 mocaStaked) external view returns (uint256) {
        return _verifiersSubsidyPercentages[mocaStaked];
    }

    // note: overlap with getVerifierAndPoolAccruedSubsidies
    function getEpochPoolSubsidies(uint256 epoch, bytes32 poolId) external view returns (uint256) {
        return _epochPoolSubsidies[epoch][poolId];
    }

    function getEpochPoolVerifierSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId) external view returns (uint256) {
        return _epochPoolVerifierSubsidies[epoch][poolId][verifierId];
    }

    // note: manually refer to this, to know how much esMoca to deposit per pool on VotingController.depositRewardsForEpoch()
    function getEpochPoolFeesAccrued(uint256 epoch, bytes32 poolId) external view returns (DataTypes.FeesAccrued memory) {
        return _epochPoolFeesAccrued[epoch][poolId];
    }

    function getEpochFeesAccrued(uint256 epoch) external view returns (DataTypes.FeesAccrued memory) {
        return _epochFeesAccrued[epoch];
    }
}