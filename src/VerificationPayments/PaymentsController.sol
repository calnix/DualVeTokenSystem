// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker, ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

// risk management
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

// libraries
import {Events} from "../libraries/Events.sol";
import {Errors} from "../libraries/Errors.sol";
import {Constants} from "../libraries/Constants.sol";
import {EpochMath} from "../libraries/EpochMath.sol";
import {DataTypes} from "../libraries/DataTypes.sol";

// interfaces
import {IAddressBook} from "../interfaces/IAddressBook.sol";
import {IEscrowedMoca} from "../interfaces/IEscrowedMoca.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";

contract PaymentsController is EIP712, Pausable {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    // immutable
    IAddressBook internal immutable _addressBook;

    // fees: 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 internal PROTOCOL_FEE_PERCENTAGE;    
    uint256 internal VOTING_FEE_PERCENTAGE;   

    // issuer's fee increase delay | for schema
    uint256 internal DELAY_PERIOD;            // in seconds

    // verification fees
    uint256 internal TOTAL_VERIFICATION_FEES_ACCRUED;
    uint256 internal TOTAL_CLAIMED_VERIFICATION_FEES;

    // staked by verifiers
    uint256 internal TOTAL_MOCA_STAKED;

    // protocol fees accrued note: drop to reduce storage updates
    //uint256 internal TOTAL_PROTOCOL_FEES_ACCRUED;
    //uint256 internal TOTAL_CLAIMED_PROTOCOL_FEES;

    // risk management
    uint256 internal _isFrozen;


//-------------------------------mappings-----------------------------------------------------
    
    // issuer, verifier, schema
    mapping(bytes32 issuerId => DataTypes.Issuer issuer) internal _issuers;
    mapping(bytes32 schemaId => DataTypes.Schema schema) internal _schemas;
    mapping(bytes32 verifierId => DataTypes.Verifier verifier) internal _verifiers;


    // nonces for preventing race conditions [ECDSA.sol::recover handles sig.malfunctions]
    mapping(address signerAddress => uint256 nonce) internal _verifierNonces;

    // Staking tiers: determines subsidy percentage for each verifier | admin fn will setup the tiers
    mapping(uint256 mocaStaked => uint256 subsidyPercentage) internal _verifiersStakingTiers;


    // for VotingController.claimSubsidies(): track subsidies for each verifier, and pool, per epoch | getVerifierAndPoolAccruedSubsidies()
    mapping(uint256 epoch => mapping(bytes32 poolId => uint256 totalSubsidies)) private _epochPoolSubsidies;        // totalSubsidiesPerPoolPerEpoch
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(bytes32 verifierId => uint256 verifierTotalSubsidies))) private _epochPoolVerifierSubsidies;        // totalSubsidiesPerPoolPerEpochPerVerifier
    
    // for VotingController.claimRewards()
    mapping(uint256 epoch => mapping(bytes32 poolId => DataTypes.FeesAccrued feesAccrued)) private _epochPoolFeesAccrued;
    // for correct withdrawal of fees and rewards
    mapping(uint256 epoch => DataTypes.FeesAccrued feesAccrued) private _epochFeesAccrued;    

//-------------------------------constructor-----------------------------------------

    // name: PaymentsController, version: 1
    constructor(
        address addressBook, uint256 protocolFeePercentage, uint256 voterFeePercentage, uint256 delayPeriod, 
        string memory name, string memory version) EIP712(name, version) {

        // check if addressBook is valid
        require(addressBook != address(0), Errors.InvalidAddress());
        _addressBook = IAddressBook(addressBook);
      
        // check if protocol fee percentage is valid
        require(protocolFeePercentage < Constants.PRECISION_BASE, Errors.InvalidFeePercentage());
        require(protocolFeePercentage > 0, Errors.InvalidFeePercentage());
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        // check if voter fee percentage is valid
        require(voterFeePercentage < Constants.PRECISION_BASE, Errors.InvalidFeePercentage());
        require(voterFeePercentage > 0, Errors.InvalidFeePercentage());
        VOTING_FEE_PERCENTAGE = voterFeePercentage;

        // min. delay period is 1 epoch; value must be in epoch intervals
        require(delayPeriod >= EpochMath.EPOCH_DURATION, Errors.InvalidDelayPeriod());
        require(EpochMath.isValidEpochTime(delayPeriod), Errors.InvalidDelayPeriod());
        DELAY_PERIOD = delayPeriod;
    }

//-------------------------------issuer functions-----------------------------------------

    /**
     * @notice Generates and registers a new issuer with a unique issuerId.
     * @dev The issuerId is derived from the sender and asset address, ensuring uniqueness across issuers, verifiers, and schemas.
     * @param assetAddress The address where issuer fees will be claimed.
     * @return issuerId The unique identifier assigned to the new issuer.
     */
    function createIssuer(address assetAddress) external returns (bytes32) {
        require(assetAddress != address(0), Errors.InvalidAddress());

        // generate issuerId
        bytes32 issuerId;
        {
            uint256 salt = ++block.number; 
            issuerId = _generateId(salt, msg.sender, assetAddress);
            // If generated id must be unique: if used by issuer, verifier or schema, generate new Id
            while (_issuers[issuerId].issuerId != bytes32(0) || _verifiers[issuerId].verifierId != bytes32(0) || _schemas[issuerId].schemaId != bytes32(0)) {
                issuerId = _generateId(++salt, msg.sender, assetAddress); 
            }
        }

        // STORAGE: setup issuer
        _issuers[issuerId].issuerId = issuerId;
        _issuers[issuerId].adminAddress = msg.sender;
        _issuers[issuerId].assetAddress = assetAddress;
        
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
    function createSchema(bytes32 issuerId, uint128 fee) external returns (bytes32) {
        // check if issuerId matches msg.sender
        require(_issuers[issuerId].adminAddress == msg.sender, Errors.InvalidCaller());

        // sanity check: fee cannot be greater than 1000 USD8
        // fee is an absolute value expressed in USD8 terms | free credentials are allowed
        require(fee < 1000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // generate schemaId
        bytes32 schemaId;
        {
            uint256 salt = ++block.number; 
            schemaId = _generateSchemaId(salt, issuerId);
            // If generated id must be unique: if used by issuer, verifier or schema, generate new Id
            while (_schemas[schemaId].schemaId != bytes32(0) || _verifiers[schemaId].verifierId != bytes32(0) || _issuers[schemaId].issuerId != bytes32(0)) {
                schemaId = _generateSchemaId(++salt, issuerId);
            }
        }

        // STORAGE: create schema
        _schemas[schemaId].schemaId = schemaId;
        _schemas[schemaId].issuerId = issuerId;
        _schemas[schemaId].currentFee = fee;

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
    function updateSchemaFee(bytes32 issuerId, bytes32 schemaId, uint128 newFee) external returns (uint256) {
        // check if issuerId matches msg.sender
        require(_issuers[issuerId].adminAddress == msg.sender, Errors.InvalidCaller());
        // check if schemaId is valid
        require(_schemas[schemaId].schemaId != bytes32(0), Errors.InvalidId());


        // sanity check: fee cannot be greater than 10,000 USD8
        // fee is an absolute value expressed in USD8 terms | free credentials are allowed
        require(newFee < 10_000 * Constants.USD8_PRECISION, Errors.InvalidAmount());

        // decrementing fee is applied immediately
        uint256 currentFee = _schemas[schemaId].currentFee;
        if(newFee < currentFee) {
            _schemas[schemaId].currentFee = newFee;

            emit Events.SchemaFeeReduced(schemaId, newFee, currentFee);

        } else {
            // increment nextFee 
            _schemas[schemaId].nextFee = newFee;
            
            // set next fee timestamp
            uint128 nextFeeTimestamp = uint128(block.timestamp + DELAY_PERIOD);
            _schemas[schemaId].nextFeeTimestamp = nextFeeTimestamp;

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
    function claimFees(bytes32 issuerId) external {
        // check if issuerId matches msg.sender
        require(_issuers[issuerId].assetAddress == msg.sender, Errors.InvalidCaller());

        uint256 claimableFees = _issuers[issuerId].totalNetFeesAccrued - _issuers[issuerId].totalClaimed;

        // check if issuer has claimable fees
        require(claimableFees > 0, Errors.NoClaimableFees());

        // overwrite .totalClaimed with .totalNetFeesAccrued
        _issuers[issuerId].totalClaimed = _issuers[issuerId].totalNetFeesAccrued;

        // update global counter
        TOTAL_CLAIMED_VERIFICATION_FEES += claimableFees;

        emit Events.IssuerFeesClaimed(issuerId, claimableFees);

        // transfer fees to issuer
        IERC20(_addressBook.getUSD8Token()).safeTransfer(msg.sender, claimableFees);
    }

//-------------------------------verifier functions-----------------------------------------

    /**
     * @notice Generates and registers a new verifier with a unique verifierId.
     * @dev The verifierId is derived from the sender and asset address, ensuring uniqueness across issuers, verifiers, and schemas.
     * @param signerAddress The address of the signer of the verifier.
     * @param assetAddress The address where verifier fees will be claimed.
     * @return verifierId The unique identifier assigned to the new verifier.
     */
    function createVerifier(address signerAddress, address assetAddress) external returns (bytes32) {
        require(signerAddress != address(0), Errors.InvalidAddress());
        require(assetAddress != address(0), Errors.InvalidAddress());

        // generate verifierId
        bytes32 verifierId;
        {
            uint256 salt = ++block.number; 
            verifierId = _generateId(salt, msg.sender, assetAddress);
            // If generated id must be unique: if used by issuer, verifier or schema, generate new Id
            while (_verifiers[verifierId].verifierId != bytes32(0) || _issuers[verifierId].issuerId != bytes32(0) || _schemas[verifierId].schemaId != bytes32(0)) {
                verifierId = _generateId(++salt, msg.sender, assetAddress); 
            }
        }

        // STORAGE: create verifier
        _verifiers[verifierId].verifierId = verifierId;
        _verifiers[verifierId].adminAddress = msg.sender;
        _verifiers[verifierId].signerAddress = signerAddress;
        _verifiers[verifierId].assetAddress = assetAddress;

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
    function deposit(bytes32 verifierId, uint128 amount) external {
        // check msg.sender is verifierId's asset address
        address assetAddress = _verifiers[verifierId].assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update balance
        _verifiers[verifierId].currentBalance += amount;

        emit Events.VerifierDeposited(verifierId, assetAddress, amount);

        // transfer funds to verifier
        IERC20(_addressBook.getUSD8Token()).safeTransferFrom(msg.sender, address(this), amount);
    }


    /**
     * @notice Withdraws USD8 from the verifier's balance.
     * @dev Only callable by the verifier's asset address. Decreases the verifier's balance.
     * - Caller must match the verifier's asset address.
     * @param verifierId The unique identifier of the verifier to withdraw from.
     * @param amount The amount of USD8 to withdraw.
     */
    function withdraw(bytes32 verifierId, uint128 amount) external {
        require(amount > 0, Errors.InvalidAmount());

        // check msg.sender is verifierId's asset address
        address assetAddress = _verifiers[verifierId].assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough balance
        uint128 balance = _verifiers[verifierId].currentBalance;
        require(balance >= amount, Errors.InvalidAmount());

        // STORAGE: update balance
        _verifiers[verifierId].currentBalance -= amount;

        emit Events.VerifierWithdrew(verifierId, assetAddress, amount);

        // transfer funds to verifier
        IERC20(_addressBook.getUSD8Token()).safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Updates the signer address for a verifier.
     * @dev Only callable by the verifier's admin address. The new signer address must be non-zero and different from the current one.
     * @param verifierId The unique identifier of the verifier.
     * @param signerAddress The new signer address to set.
     */
    function updateSignerAddress(bytes32 verifierId, address signerAddress) external {
        require(signerAddress != address(0), Errors.InvalidAddress());
        
        // check msg.sender is verifierId's admin address
        require(_verifiers[verifierId].adminAddress == msg.sender, Errors.InvalidCaller());

        // check if new signer address is different from current one
        require(_verifiers[verifierId].signerAddress != signerAddress, Errors.InvalidAddress());

        // update signer address
        _verifiers[verifierId].signerAddress = signerAddress;

        emit Events.VerifierSignerAddressUpdated(verifierId, signerAddress);
    }


    /**
     * @notice Stakes MOCA for a verifier.
     * @dev Only callable by the verifier's assetAddress address. Increases the verifier's moca staked.
     * @param verifierId The unique identifier of the verifier to stake MOCA for.
     * @param amount The amount of MOCA to stake.
     */
    function stakeMoca(bytes32 verifierId, uint128 amount) external {
        require(amount > 0, Errors.InvalidAmount());
        
        // check msg.sender is verifierId's asset address
        address assetAddress = _verifiers[verifierId].assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // STORAGE: update moca staked
        _verifiers[verifierId].mocaStaked += amount;
        TOTAL_MOCA_STAKED += amount;

        // transfer Moca to verifier
        IERC20(_addressBook.getMocaToken()).safeTransferFrom(msg.sender, address(this), amount);

        emit Events.VerifierMocaStaked(verifierId, assetAddress, amount);
    }


    /**
     * @notice Unstakes MOCA for a verifier.
     * @dev Only callable by the verifier's asset address. Decreases the verifier's moca staked.
     * @param verifierId The unique identifier of the verifier to unstake MOCA for.
     * @param amount The amount of MOCA to unstake.
     */
    function unstakeMoca(bytes32 verifierId, uint128 amount) external {
        require(amount > 0, Errors.InvalidAmount());

        // check msg.sender is verifierId's asset address
        address assetAddress = _verifiers[verifierId].assetAddress;
        require(assetAddress == msg.sender, Errors.InvalidCaller());

        // check if verifier has enough moca staked
        require(_verifiers[verifierId].mocaStaked >= amount, Errors.InvalidAmount());

        // STORAGE: update moca staked
        _verifiers[verifierId].mocaStaked -= amount;
        TOTAL_MOCA_STAKED -= amount;

        // transfer Moca to verifier
        IERC20(_addressBook.getMocaToken()).safeTransfer(msg.sender, amount);

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
    function updateAssetAddress(bytes32 id, address newAssetAddress) external returns (address) {
        require(newAssetAddress != address(0), Errors.InvalidAddress());

        if (_issuers[id].issuerId != bytes32(0)) {
            
            // Issuer update
            require(_issuers[id].adminAddress == msg.sender, Errors.InvalidCaller());
            _issuers[id].assetAddress = newAssetAddress;

        } else if (_verifiers[id].verifierId != bytes32(0)) {

            // Verifier update
            require(_verifiers[id].adminAddress == msg.sender, Errors.InvalidCaller());
            _verifiers[id].assetAddress = newAssetAddress;
            
        } else {
            revert Errors.InvalidId();
        }

        emit Events.AssetAddressUpdated(id, newAssetAddress);
        return newAssetAddress;
    }


//-------------------------------UniversalVerificationContract functions-----------------------------------------

    //TODO: subsidy based on staking tiers -> calculate and book subsidy into _verifierSubsidies
    // make this fn as gas optimized as possible
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint128 amount, uint256 expiry, bytes calldata signature) external {
        require(expiry > block.timestamp, Errors.SignatureExpired());

        // nextFee check
        uint128 nextFee = _schemas[schemaId].nextFee;
        // if nextFee is set, check if it's time to apply it
        if(nextFee > 0) {
            if(_schemas[schemaId].nextFeeTimestamp <= block.timestamp) {
                // apply nextFee
                uint128 currentFee = _schemas[schemaId].currentFee;
                _schemas[schemaId].currentFee = nextFee;
                // delete nextFee and nextFeeTimestamp
                delete _schemas[schemaId].nextFee;
                delete _schemas[schemaId].nextFeeTimestamp;

                emit Events.SchemaFeeIncreased(schemaId, currentFee, nextFee);
            }
        }

        // ---- try: so that fee updates occur regardless of subsequent revert ---

        // amount must match latest schema fee [set by issuer]
        uint256 schemaFee = _schemas[schemaId].currentFee;
        require(amount == schemaFee, Errors.InvalidSchemaFee());

        // check if sufficient balance
        require(_verifiers[verifierId].currentBalance >= amount, Errors.InsufficientBalance());


        // ----- Verify signature -----
            address signerAddress = _verifiers[verifierId].signerAddress;
            bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(Constants.DEDUCT_BALANCE_TYPEHASH, issuerId, verifierId, schemaId, amount, expiry, _verifierNonces[signerAddress])));
            // handles both EOA and contract signatures | returns true if signature is valid
            require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), Errors.InvalidSignature());
        
        // ----- Update nonce -----
        ++_verifierNonces[signerAddress];


        // ----- Calc. fee split -----
        uint128 protocolFee = (PROTOCOL_FEE_PERCENTAGE > 0) ? (amount * PROTOCOL_FEE_PERCENTAGE) / Constants.PRECISION_BASE : 0;
        uint128 votingFee = (VOTING_FEE_PERCENTAGE > 0) ? (amount * VOTING_FEE_PERCENTAGE) / Constants.PRECISION_BASE : 0;

        // get current epoch
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

        // ----- Book subsidy & fees (voting rewards) if poolId is set -----
        bytes32 poolId = _schemas[schemaId].poolId;
        if (poolId != bytes32(0)) {
            // for VotingController.claimSubsidies(): which calls getVerifierAndPoolAccruedSubsidies() on this contract
            _bookSubsidy(verifierId, poolId, schemaId, amount, currentEpoch);
        }

        // ---------------------------------------------------------------------

        // issuer: global accounting
        _issuers[issuerId].totalNetFeesAccrued += (amount - protocolFee - votingFee);  // all uint128
        ++_issuers[issuerId].totalVerified;

        // verifier: global accounting
        _verifiers[verifierId].currentBalance -= amount;
        _verifiers[verifierId].totalExpenditure += amount;

        // schema: global accounting
        _schemas[schemaId].totalGrossFeesAccrued += amount;     // disregards protocol and voting fees
        ++_schemas[schemaId].totalVerified;
        
        // protocol + voting fees accounting | to enable withdrawal of fees at the end of an epoch
        _epochFeesAccrued[currentEpoch].feesAccruedToProtocol += protocolFee;
        _epochFeesAccrued[currentEpoch].feesAccruedToVoters += votingFee;  

        // for VotingController.depositRewards(): which calls getPoolVotingFeesAccrued() on this contract
        // to identify how much fees accrued for a pool, to assist with distribution of voting rewards
        _epochPoolFeesAccrued[currentEpoch][poolId].feesAccruedToProtocol += protocolFee;
        _epochPoolFeesAccrued[currentEpoch][poolId].feesAccruedToVoters += votingFee;

        emit Events.BalanceDeducted(verifierId, schemaId, issuerId, amount);
    }

    // for VotingController to identify how much subsidies owed to each verifier; based on their staking tier+expenditure
    function _bookSubsidy(bytes32 verifierId, bytes32 poolId, bytes32 schemaId, uint256 amount, uint256 currentEpoch) internal {
        // get verifier's staking tier + subsidy percentage
        uint256 mocaStaked = _verifiers[verifierId].mocaStaked;
        uint256 subsidyPercentage = _verifiersStakingTiers[mocaStaked];

        // calculate subsidy | if subsidyPercentage is 0, txn reverts; no need to check for 0
        uint256 subsidy = (amount * subsidyPercentage) / Constants.PRECISION_BASE;
        require(subsidy > 0, Errors.ZeroSubsidy());
        

        // book verifier's subsidy
        _epochPoolSubsidies[currentEpoch][poolId] += subsidy;
        _epochPoolVerifierSubsidies[currentEpoch][poolId][verifierId] += subsidy;

        emit Events.SubsidyBooked(verifierId, poolId, schemaId, subsidy);
    }
 
//-------------------------------internal functions-----------------------------------------

    ///@dev Generate a issuer or verifier id. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    // adminAddress: msg.sender
    function _generateId(uint256 salt, address adminAddress, address assetAddress) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(adminAddress, assetAddress, block.timestamp, salt)));
    }


    function _generateSchemaId(uint256 salt, bytes32 issuerId) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(issuerId, block.timestamp, salt)));
    }


//-------------------------------admin: update functions-----------------------------------------

    // add/update/remove
    function updatePoolId(bytes32 schemaId, bytes32 poolId) external onlyPaymentsAdmin {
        require(_schemas[schemaId].schemaId != bytes32(0), "Schema does not exist");
        _schemas[schemaId].poolId = poolId;

        emit Events.PoolIdUpdated(schemaId, poolId);
    }

    function updateDelayPeriod(uint256 delayPeriod) external onlyPaymentsAdmin {
        require(delayPeriod > 0, "Invalid delay period");
        require(delayPeriod % EpochMath.EPOCH_DURATION == 0, "Delay period must be a multiple of epoch duration");

        DELAY_PERIOD = delayPeriod;

        emit Events.DelayPeriodUpdated(delayPeriod);
    }

    // protocol fee can be 0
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external onlyPaymentsAdmin {
        // protocol fee cannot be greater than 100%
        require(protocolFeePercentage < Constants.PRECISION_BASE, "Invalid protocol fee percentage");
        // total fee percentage cannot be greater than 100%
        require(protocolFeePercentage + VOTING_FEE_PERCENTAGE < Constants.PRECISION_BASE, "Invalid protocol fee percentage");

        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        emit Events.ProtocolFeePercentageUpdated(protocolFeePercentage);
    }

    // voter fee can be 0
    function updateVotingFeePercentage(uint256 votingFeePercentage) external onlyPaymentsAdmin {
        // voter fee cannot be greater than 100%
        require(votingFeePercentage < Constants.PRECISION_BASE, "Invalid voting fee percentage");
        // total fee percentage cannot be greater than 100%
        require(votingFeePercentage + PROTOCOL_FEE_PERCENTAGE < Constants.PRECISION_BASE, "Invalid voting fee percentage");
        
        VOTING_FEE_PERCENTAGE = votingFeePercentage;

        emit Events.VotingFeePercentageUpdated(votingFeePercentage);
    }

    // used to set/overwrite/update
    function updateVerifierStakingTiers(uint256 mocaStaked, uint256 subsidyPercentage) external onlyPaymentsAdmin {
        require(mocaStaked > 0, "Invalid moca staked");
        require(subsidyPercentage < Constants.PRECISION_BASE, "Invalid subsidy percentage");

        _verifiersStakingTiers[mocaStaked] = subsidyPercentage;

        emit Events.VerifierStakingTierUpdated(mocaStaked, subsidyPercentage);
    }

//-------------------------------admin: withdraw functions-----------------------------------------

    //note: can only withdraw protocol fees after epoch ended
    function withdrawProtocolFees(uint256 epoch) external onlyPaymentsAdmin {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());
        require(!_epochFeesAccrued[epoch].isProtocolFeeWithdrawn, Errors.ProtocolFeeAlreadyWithdrawn());

        uint256 protocolFees = _epochFeesAccrued[epoch].feesAccruedToProtocol;
        require(protocolFees > 0, Errors.ZeroProtocolFee());

        _epochFeesAccrued[epoch].isProtocolFeeWithdrawn = true;

        emit Events.ProtocolFeesWithdrawn(epoch, protocolFees);
    }

    function withdrawVotersFees(uint256 epoch) external onlyPaymentsAdmin {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());
        require(!_epochFeesAccrued[epoch].isVotersFeeWithdrawn, Errors.VotersFeeAlreadyWithdrawn());

        uint256 votersFees = _epochFeesAccrued[epoch].feesAccruedToVoters;
        require(votersFees > 0, Errors.ZeroVotersFee());

        _epochFeesAccrued[epoch].isVotersFeeWithdrawn = true;

        emit Events.VotersFeesWithdrawn(epoch, votersFees);
    }
/*
    function withdrawFees(uint256 epoch, bool isProtocolFee) external onlyPaymentsAdmin {
        require(epoch < EpochMath.getCurrentEpochNumber(), Errors.InvalidEpoch());
        
        bool storage isWithdrawn;
        uint256 accruedFees;

        (isWithdrawn, accruedFees) = isProtocolFee ? 
            (_epochFeesAccrued[epoch].isProtocolFeeWithdrawn, _epochFeesAccrued[epoch].feesAccruedToProtocol) : 
            (_epochFeesAccrued[epoch].isVotersFeeWithdrawn, _epochFeesAccrued[epoch].feesAccruedToVoters);

        require(!isWithdrawn, isProtocolFee ? Errors.ProtocolFeeAlreadyWithdrawn() : Errors.VotersFeeAlreadyWithdrawn());
        require(accruedFees > 0, isProtocolFee ? Errors.ZeroProtocolFee() : Errors.ZeroVotersFee());

        isWithdrawn = true;

        if(isProtocolFee) {
            emit Events.ProtocolFeesWithdrawn(epoch, accruedFees);
        } else {
            emit Events.VotersFeesWithdrawn(epoch, accruedFees);
        }

        /*
            if(isProtocolFee) {

                require(!_epochFeesAccrued[epoch].isProtocolFeeWithdrawn, Errors.ProtocolFeeAlreadyWithdrawn());

                uint256 protocolFees = _epochFeesAccrued[epoch].feesAccruedToProtocol;
                require(protocolFees > 0, Errors.ZeroProtocolFee());
                
                _epochFeesAccrued[epoch].isProtocolFeeWithdrawn = true;

                emit Events.ProtocolFeesWithdrawn(epoch, protocolFees);

            } else {

                require(!_epochFeesAccrued[epoch].isVotersFeeWithdrawn, Errors.VotersFeeAlreadyWithdrawn());

                uint256 votersFees = _epochFeesAccrued[epoch].feesAccruedToVoters;
                require(votersFees > 0, Errors.ZeroVotersFee());
                
                _epochFeesAccrued[epoch].isVotersFeeWithdrawn = true;

                emit Events.VotersFeesWithdrawn(epoch, votersFees);
            } 
        */
 /*   }
*/
//------------------------------- risk -------------------------------------------------------

    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external whenNotPaused onlyMonitor {
        if(_isFrozen == 1) revert Errors.IsFrozen(); 
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external whenPaused onlyGlobalAdmin {
        if(_isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external whenPaused onlyGlobalAdmin {
        if(_isFrozen == 1) revert Errors.IsFrozen();
        _isFrozen = 1;
        emit Events.ContractFrozen();
    }  


    // exfil verifiers' balance to their stored addresses
    function emergencyExitVerifiers(bytes32[] calldata verifierIds) external whenPaused {
        //if(isFrozen == 0) revert Errors.NotFrozen();
        //if(verifierIds.length == 0) revert Errors.InvalidInput();

        // get USD8 address from AddressBook
        address usd8 = _addressBook.getUSD8Token();
    
        // if issuerId is given, will retrieve either empty or wrong struct
        for(uint256 i; i < verifierIds.length; ++i) {
            
            // get balance: if 0, skip
            uint256 verifierBalance = _verifiers[verifierIds[i]].currentBalance;
            if(verifierBalance == 0) continue;

            // get asset address
            address verifierAssetAddress = _verifiers[verifierIds[i]].assetAddress;

            // transfer balance to verifier
            IERC20(usd8).safeTransfer(verifierAssetAddress, verifierBalance);
        }

        emit Events.EmergencyExitVerifiers(verifierIds);
    }

    // exfil issuers' unclaimed fees to their stored addresses
    function emergencyExitIssuers(bytes32[] calldata issuerIds) external whenPaused {
        //if(isFrozen == 0) revert Errors.NotFrozen();
        //if(issuerIds.length == 0) revert Errors.InvalidInput();

        // get USD8 address from AddressBook
        address usd8 = _addressBook.getUSD8Token();

        // if verifierId is given, will retrieve either empty or wrong struct
        for(uint256 i; i < issuerIds.length; ++i) {

            // get unclaimed fees: if 0, skip
            uint256 issuerBalance = _issuers[issuerIds[i]].totalNetFeesAccrued - _issuers[issuerIds[i]].totalClaimed;
            if(issuerBalance == 0) continue;

            // get asset address
            address issuerAssetAddress = _issuers[issuerIds[i]].assetAddress;

            // transfer balance to issuer
            IERC20(usd8).safeTransfer(issuerAssetAddress, issuerBalance);
        }

        emit Events.EmergencyExitIssuers(issuerIds);
    }


//------------------------------- modifiers -------------------------------------------------------

    modifier onlyMonitor() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isMonitor(msg.sender), "Only callable by Monitor");
        _;
    }

    modifier onlyPaymentsAdmin() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isPaymentsAdmin(msg.sender), "Only callable by Payments Admin");
        _;
    }

    modifier onlyGlobalAdmin() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isGlobalAdmin(msg.sender), "Only callable by Global Admin");
        _;
    }   

//-------------------------------view functions---------------------------------------------
   
    // called by VotingController.claimSubsidies
    function getVerifierAndPoolAccruedSubsidies(uint256 epoch, bytes32 poolId, bytes32 verifierId, address caller) external view returns (uint256, uint256) {
        // verifiers's asset address must be the caller of VotingController.claimSubsidies
        require(caller == _verifiers[verifierId].assetAddress, Errors.InvalidCaller());
        return (_epochPoolVerifierSubsidies[epoch][poolId][verifierId], _epochPoolSubsidies[epoch][poolId]);
    }

    // called by VotingController.depositRewards()
    function getPoolVotingFeesAccrued(uint256 epoch, bytes32 poolId) external view returns (uint256) {
        return _epochPoolFeesAccrued[epoch][poolId].feesAccruedToVoters;
    }


    function getIssuer(bytes32 issuerId) external view returns (DataTypes.Issuer memory) {
        return _issuers[issuerId];
    }

    function getSchema(bytes32 schemaId) external view returns (DataTypes.Schema memory) {
        return _schemas[schemaId];
    }

    function getVerifier(bytes32 verifierId) external view returns (DataTypes.Verifier memory) {
        return _verifiers[verifierId];
    }

    function getVerifierNonce(address verifier) external view returns (uint256) {
        return _verifierNonces[verifier];
    }

    // nice to have
    function getSchemaFee(bytes32 schemaId) external view returns (uint256) {
        return _schemas[schemaId].currentFee;
    }

    function getProtocolFeePercentage() external view returns (uint256) {
        return PROTOCOL_FEE_PERCENTAGE;
    }

    function getVoterFeePercentage() external view returns (uint256) {
        return VOTING_FEE_PERCENTAGE;
    }

    function getDelayPeriod() external view returns (uint256) {
        return DELAY_PERIOD;
    }

    /*
    function getAddressBook() external view returns (IAddressBook) {
        return _addressBook;
    }
*/

}


/**
    TODO: how to upgrade?

    1. pause old contract, deploy new contract. 
        - requires downtime
        - requires issuers and verifiers to repeat setup on new contract [more work for them]
    
    2. Make contract upgradable
        - repeat setup might not be required; contingent on added logic
        - allows extension of logic
        - but dangerous if extending incorrectly & if new logic is introduced

        Potentially more seamless, but could introduce critical risks if not done correctly

    TODO: contracts should not directly refer to each other
        - instead, use a central contract to manage the relationships
        - AddressBook contract can be used to:
            - track contract address changes [upgrades]
            - manage permissions
 */


/**
    TODO or to be ignored:
    1. issuers staking moca before being able to issue credentials
    2. tiering


 */

