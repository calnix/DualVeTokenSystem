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

    // fees
    uint256 internal PROTOCOL_FEE_PERCENTAGE; // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 internal VOTER_FEE_PERCENTAGE;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

    // issuer's fee increase delay | for schema
    uint256 internal DELAY_PERIOD;            // in seconds

    // verification fees
    uint256 internal TOTAL_VERIFICATION_FEES_ACCRUED;
    uint256 internal TOTAL_CLAIMED_VERIFICATION_FEES;

    // risk management
    uint256 internal _isFrozen;


//-------------------------------mappings-----------------------------------------------------
    
    // issuer, verifier, schema
    mapping(bytes32 issuerId => DataTypes.Issuer issuer) internal _issuers;
    mapping(bytes32 schemaId => DataTypes.Schema schema) internal _schemas;
    mapping(bytes32 verifierId => DataTypes.Verifier verifier) internal _verifiers;


    // nonces for preventing race conditions [ECDSA.sol::recover handles sig.malfunctions]
    mapping(address verifier => uint256 nonce) internal _verifierNonces;


    // verifier staking tiers | admin fn will setup the tiers
    mapping(uint256 mocaStaked => uint256 subsidyPercentage) internal _verifiersStakingTiers;
    mapping(bytes32 verifierId => uint256 mocaStaked) internal _verifiersMocaStaked;

    // for VotingController: track subsidies for each verifier, per epoch | getVerifierAndPoolAccruedSubsidies()
    mapping(bytes32 verifierId => mapping(uint256 epoch => uint256 subsidy)) internal _verifierSubsidies;

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
        VOTER_FEE_PERCENTAGE = voterFeePercentage;

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
        require(fee < 1000 * Constants.USD8_PRECISION, Errors.InvalidFee());

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
    function updateSchemaFee(bytes32 issuerId, bytes32 schemaId, uint256 newFee) external returns (uint256) {
        // check if issuerId matches msg.sender
        require(_issuers[issuerId].adminAddress == msg.sender, Errors.InvalidCaller());
        // check if schemaId is valid
        require(_schemas[schemaId].schemaId != bytes32(0), Errors.InvalidSchema());


        // sanity check: fee cannot be greater than 10,000 USD8
        // fee is an absolute value expressed in USD8 terms | free credentials are allowed
        require(newFee < 10_000 * Constants.USD8_PRECISION, Errors.InvalidFee());

        // decrementing fee is applied immediately
        uint256 currentFee = _schemas[schemaId].currentFee;
        if(newFee < currentFee) {
            _schemas[schemaId].currentFee = newFee;

            emit Events.SchemaFeeReduced(schemaId, newFee, currentFee);

        } else {
            // increment nextFee 
            _schemas[schemaId].nextFee = newFee;
            
            // set next fee timestamp
            uint256 nextFeeTimestamp = block.timestamp + DELAY_PERIOD;
            _schemas[schemaId].nextFeeTimestamp = nextFeeTimestamp;

            emit Events.SchemaFeeIncreased(schemaId, newFee, nextFeeTimestamp, currentFee);
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

        uint256 claimableFees = _issuers[issuerId].totalFeesAccrued - _issuers[issuerId].totalClaimed;

        // check if issuer has claimable fees
        require(claimableFees > 0, Errors.NoClaimableFees());

        // overwrite .totalClaimed with .totalFeesAccrued
        _issuers[issuerId].totalClaimed = _issuers[issuerId].totalFeesAccrued;

        // update global counter
        TOTAL_CLAIMED_VERIFICATION_FEES += claimableFees;

        emit Events.IssuerFeesClaimed(issuerId, claimableFees);

        // transfer fees to issuer
        IERC20(_addressBook.getUSD8Token()).safeTransfer(msg.sender, claimableFees);
    }

//-------------------------------verifier functions-----------------------------------------

    function setupVerifier(address signerAddress, address assetAddress) external returns (bytes32) {
        // generate verifierId
        bytes32 verifierId;
        {
            uint256 salt = ++block.number; 
            verifierId = _generateId(salt, msg.sender);
            // If generated id is used by either issuer or verifier, generate new Id
            while (_verifiers[verifierId].verifierId != bytes32(0) || _issuers[verifierId].issuerId != bytes32(0)) {
                verifierId = _generateId(++salt, msg.sender); 
            }
        }

        // setup verifier
        Verifier memory verifier;
            verifier.verifierId = verifierId;
            verifier.adminAddress = msg.sender;
            verifier.signerAddress = signerAddress;
            verifier.assetAddress = assetAddress;

        // store verifier
        _verifiers[verifierId] = verifier;

        // emit VerifierCreated(verifierId, msg.sender);

        return verifierId;
    }

    function deposit(bytes32 verifierId, uint256 amount) external {
        // check if verifierId is valid + matches msg.sender
        require(_verifiers[verifierId].wallet == msg.sender, "Verifier Id<->Address mismatch");

        // update balance
        _verifiers[verifierId].balance += amount;

        // emit Deposit(verifierId, amount);

        // transfer funds to verifier
        IERC20(_addressBook.getUSD8Token()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(bytes32 verifierId, uint256 amount) external {
        // check if verifierId is valid + matches msg.sender
        require(_verifiers[verifierId].wallet == msg.sender, "Verifier Id<->Address mismatch");

        // check if verifier has enough balance
        uint256 balance = _verifiers[verifierId].balance;
        require(balance >= amount, "Insufficient balance");

        // update balance
        _verifiers[verifierId].balance = balance - amount;

        // emit Withdraw(verifierId, amount);

        // transfer funds to verifier
        IERC20(_addressBook.getUSD8Token()).safeTransfer(msg.sender, amount);
    }

    // must be called from old signerAddress
    function updateSignerAddress(bytes32 verifierId, address signerAddress) external {
        // check if verifierId matches msg.sender
        require(_verifiers[verifierId].signerAddress == msg.sender, "Verifier Id<->Address mismatch");

        // update signer address
        _verifiers[verifierId].signerAddress = signerAddress;

        // emit SignerAddressUpdated(verifierId, signerAddress);
    }


    function stakeMoca(bytes32 verifierId, uint256 amount) external {
        // check if verifierId is valid + matches msg.sender
        require(_verifiers[verifierId].assetAddress == msg.sender, "Verifier Id<->Address mismatch");

        // update moca staked
        _verifierMocaStaked[verifierId] += amount;

        // transfer Moca to verifier
        IERC20(_addressBook.getMocaToken()).safeTransferFrom(msg.sender, address(this), amount);

        emit Events.VerifierMocaStaked(verifierId, amount);
    }

    function unstakeMoca(bytes32 verifierId, uint256 amount) external {
        // check if verifierId is valid + matches msg.sender
        require(_verifiers[verifierId].assetAddress == msg.sender, "Verifier Id<->Address mismatch");
        require(_verifierMocaStaked[verifierId] >= amount, "Insufficient moca staked");

        // update moca staked
        _verifierMocaStaked[verifierId] -= amount;

        // transfer Moca to verifier
        IERC20(_addressBook.getMocaToken()).safeTransfer(msg.sender, amount);

        emit Events.VerifierMocaUnstaked(verifierId, amount);
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
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 schemaId, uint256 amount, uint256 expiry, bytes calldata signature) external {
        //if(expiry < block.timestamp) revert Errors.SignatureExpired();

        // check if amount matches credential fee set by issuer
        uint256 credentialFee = _schemas[credentialId].currentFee;
        require(amount == credentialFee, "Amount does not match credential fee");

        // check if sufficient balance
        require(_verifiers[verifierId].balance >= amount, "Insufficient balance");

        // to get nonce + signerAddress
        address signerAddress = _verifiers[verifierId].signerAddress;

        // verify signature | note: check inputs
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(TYPEHASH, issuerId, verifierId, schemaId, amount, expiry, _verifierNonces[signerAddress])));

        // handles both EOA and contract signatures | returns true if signature is valid
        require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), "Invalid signature");
        // update nonce
        ++_verifierNonces[signerAddress];


        // calc. fee split
        unchecked{
            uint256 protocolFee = (PROTOCOL_FEE_PERCENTAGE > 0) ? (amount * PROTOCOL_FEE_PERCENTAGE) / Constants.PRECISION_BASE : 0;
            uint256 voterFee = (VOTER_FEE_PERCENTAGE > 0) ? (protocolFee * VOTER_FEE_PERCENTAGE) / Constants.PRECISION_BASE : 0;
            uint256 treasuryFee = (protocolFee - voterFee);
        }

        // Only book subsidy if the schema has a poolId (i.e., is linked to a voting pool)
        bytes32 poolId = _schemas[schemaId].poolId;
        if (poolId != bytes32(0)) {
            _bookSubsidy(verifierId, poolId, schemaId, amount);
            
            // for VotingController.claimRewards()
            FeesAccrued memory feesAccrued;
                feesAccrued.feesAccruedToTreasury += treasuryFee;
                feesAccrued.feesAccruedToVoters += voterFee;
            _epochPoolFeesAccrued[currentEpoch][poolId] = feesAccrued;
        }


        // verifier accounting
        _verifiers[verifierId].balance -= amount;
        _verifiers[verifierId].totalExpenditure += amount;

        // issuer accounting
        _issuers[issuerId].totalEarned += (amount - protocolFee);
        ++_issuers[issuerId].totalIssuances;

        // schema accounting
        _schemas[schemaId].totalFeesAccrued += amount;
        ++_schemas[schemaId].totalIssued;
        
        // treasury + voters accounting
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();
        _epochs[currentEpoch].feesAccruedToTreasury += treasuryFee;
        _epochs[currentEpoch].feesAccruedToVoters += voterFee;  

        //TODO: do you want to call VotingController to update accrued fees?
        // -> NO. i don't want PaymentsController to have external call dependencies to other contracts.
        // -> may create problems when upgrading to new contracts. 
        // -> PaymentsController should be silo-ed off as much as possible. Other contracts can call this if needed.

        // emit BalanceDeducted(verifierId, credentialId, issuerId, amount);
        // do we need more events for the other accounting actions?

        // emit BalanceDeducted(verifierId, credentialId, issuerId, amount);
    }

    // deductBalance() calls VotingController if the schema has a poolId
    // for VotingController to identify how much subsidies owed to each verifier; based on their staking tier+expenditure
    function _bookSubsidy(bytes32 verifierId, bytes32 poolId, bytes32 schemaId, uint256 amount) internal {
        // get verifier's staking tier
        uint256 mocaStaked = _verifiersMocaStaked[verifierId];
        uint256 subsidyPercentage = _verifiersStakingTiers[mocaStaked];


        // calculate subsidy | if subsidyPercentage is 0, txn reverts - no need to check for 0
        uint256 subsidy = (amount * subsidyPercentage) / Constants.PRECISION_BASE;
        require(subsidy > 0, "Zero subsidy");

        // get current epoch
        uint256 currentEpoch = EpochMath.getCurrentEpochNumber();

        // book verifier's subsidy
        _epochPoolSubsidies[currentEpoch][poolId] += subsidy;
        _epochPoolVerifierSubsidies[currentEpoch][poolId][verifierId] += subsidy;
        _epochPoolSchemaSubsidies[currentEpoch][poolId][schemaId] += subsidy;

        emit Events.SubsidyBooked(verifierId, poolId, schemaId, subsidy);
    }

    // totalSubsidiesPerPoolPerEpoch
    mapping(uint256 epoch => mapping(bytes32 poolId => uint256 totalSubsidies)) private _epochPoolSubsidies;
    // totalSubsidiesPerPoolPerEpochPerVerifier
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(bytes32 verifierId => uint256 verifierTotalWeight))) private _epochPoolVerifierSubsidies;
    //@follow-up totalSubsidiesPerPoolPerEpochPerSchema -- do we need this? | tracks what portion of a pool's subsidy is attributed to a schema
    mapping(uint256 epoch => mapping(bytes32 poolId => mapping(bytes32 schemaId => uint256 schemaTotalWeight))) private _epochPoolSchemaSubsidies;

    // epoch accounting: treasury + voters
    struct FeesAccrued {
        uint128 feesAccruedToTreasury;
        uint128 feesAccruedToVoters;
    }
    // VotingController needs this:
    mapping(uint256 epoch => mapping(bytes32 poolId => FeesAccrued feesAccrued)) private _epochPoolFeesAccrued;
    
    // technically not needed, but nice to have for completeness:
    mapping(uint256 epoch => mapping(bytes32 schemaId => FeesAccrued feesAccrued)) private _epochSchemaFeesAccrued;
    mapping(uint256 epoch => FeesAccrued feesAccrued) private _epochFeesAccrued;
    


//-------------------------------VotingController functions-----------------------------------------

    /** NOTE:

        1. How to swap USD8 to MOCA?
        2. When to swap USD8 for MOCA?
            - end of Epoch,
            - OR, per txn, in deductBalance()

        If swapping end of Epoch, we need to:
         1. swap USD8 to MOCA, for that epoch
         2. convert Moca to esMoca
         3. set esMoca::approve for VotingController to do transferFrom() to pay Voters

        If swapping per txn, we need to:
         1. swap USD8 to MOCA, for that txn
         2. convert Moca to esMoca, at end of Epoch
         3. set esMoca::approve for VotingController to do transferFrom() to pay Voters

         in either scenario, we convert Moca to esMoca, at end of Epoch

    */

    // convert Moca to esMoca 
    function escrowMocaForEpoch(uint256 epoch) external {
        // check if msg.sender is VotingController
        require(msg.sender == _addressBook.getVotingController(), "Only callable by VotingController");

        // get amount of Moca to escrow
        uint256 amount = epochs[epoch].feesAccruedToVoters;

        // check if amount is greater than 0
        require(amount > 0, "No Moca to escrow");

        // convert Moca to esMoca
        IEscrowedMoca(_addressBook.getEscrowedMoca()).escrow(amount);

        // emit MocaEscrowed(amount);
    }

    // set approval for VotingController
    function setApproval(uint256 amount) external {
        // 1. swap voters' fee of USD8 for MOCA


        // get VotingController address from AddressBook
        //address votingController = AddressBook.getAddress("VotingController");
        IERC20(_addressBook.getUSD8Token()).approve(_addressBook.getVotingController(), amount);
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


//-------------------------------admin functions-----------------------------------------

    // add/update/remove
    function updatePoolId(bytes32 schemaId, bytes32 poolId) external onlyPaymentsAdmin {
        require(_schemas[schemaId].schemaId != bytes32(0), "Schema does not exist");
        _schemas[schemaId].poolId = poolId;

        emit Events.PoolIdUpdated(schemaId, poolId);
    }

    function updateDelayPeriod(uint256 delayPeriod) external onlyPaymentsAdmin {
        require(delayPeriod > 0, "Invalid delay period");
        require(delayPeriod % Constants.EPOCH_DURATION == 0, "Delay period must be a multiple of epoch duration");

        DELAY_PERIOD = delayPeriod;

        emit Events.DelayPeriodUpdated(delayPeriod);
    }

    // protocol fee can be 0
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external onlyPaymentsAdmin {
        // protocol fee cannot be greater than 100%
        require(protocolFeePercentage < Constants.PRECISION_BASE, "Invalid protocol fee percentage");
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        emit Events.ProtocolFeePercentageUpdated(protocolFeePercentage);
    }

    // voter fee can be 0
    function updateVoterFeePercentage(uint256 voterFeePercentage) external onlyPaymentsAdmin {
        // voter fee cannot be greater than 100%
        require(voterFeePercentage < Constants.PRECISION_BASE, "Invalid voter fee percentage");
        VOTER_FEE_PERCENTAGE = voterFeePercentage;

        emit Events.VoterFeePercentageUpdated(voterFeePercentage);
    }

    // used to set/overwrite/update
    function updateVerifierStakingTiers(uint256 mocaStaked, uint256 subsidyPercentage) external onlyPaymentsAdmin {
        require(mocaStaked > 0, "Invalid moca staked");
        require(subsidyPercentage < Constants.PRECISION_BASE, "Invalid subsidy percentage");

        _verifierStakingTiers[mocaStaked] = subsidyPercentage;

        emit Events.VerifierStakingTierUpdated(mocaStaked, subsidyPercentage);
    }

//------------------------------- risk -------------------------------------------------------

    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external whenNotPaused onlyMonitor {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external whenPaused onlyGlobalAdmin {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external whenPaused onlyGlobalAdmin {
        if(isFrozen == 1) revert Errors.IsFrozen();
        isFrozen = 1;
        emit Events.ContractFrozen(block.timestamp);
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
            uint256 verifierBalance = _verifiers[verifierIds[i]].balance;
            if(verifierBalance == 0) continue;

            // get deposit address
            address verifierDepositAddress = _verifiers[verifierIds[i]].depositAddress;

            // transfer balance to verifier
            IERC20(usd8).safeTransfer(verifierDepositAddress, verifierBalance);
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
            uint256 issuerBalance = _issuers[issuerIds[i]].totalEarned - _issuers[issuerIds[i]].totalClaimed;
            if(issuerBalance == 0) continue;

            // get wallet address
            address issuerWallet = _issuers[issuerIds[i]].wallet;

            // transfer balance to issuer
            IERC20(usd8).safeTransfer(issuerWallet, issuerBalance);
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
   
    // called by VotingController
    function getVerifierAndPoolAccruedSubsidies(uint256 epoch, bytes32 poolId, address verifier) external view returns (uint256, uint256) {
        return (_epochPoolVerifierSubsidies[epoch][poolId][verifier], _epochPoolSubsidies[epoch][poolId]);
    }

    // called by VotingController
    function getPoolVotingFeesAccrued(uint256 epoch, bytes32 poolId) external view returns (uint256) {
        return _epochPoolFeesAccrued[epoch][poolId].feesAccruedToVoters;
    }

    


    /**
     * @notice Returns the fees accrued to voters for a given epoch
     * @param epoch The epoch number
     * @param schemaId The schema id
     * @return feesAccruedToVoters The amount of fees accrued to voters in the given epoch
     */
    function feesAccruedToVoters(uint256 epoch, bytes32 schemaId) external view returns (uint256) {
        return _epochs[epoch][schemaId].feesAccruedToVoters;
    }


    function getIssuer(bytes32 issuerId) external view returns (Issuer memory) {
        return _issuers[issuerId];
    }

    function getSchema(bytes32 schemaId) external view returns (Schema memory) {
        return _schemas[schemaId];
    }

    function getVerifier(bytes32 verifierId) external view returns (Verifier memory) {
        return _verifiers[verifierId];
    }

    function getVerifierNonce(address verifier) external view returns (uint256) {
        return _verifierNonces[verifier];
    }

    function getEpoch(uint256 epoch) external view returns (Epoch memory) {
        return _epochs[epoch];
    }

    // nice to have
    function getSchemaFee(bytes32 schemaId) external view returns (uint256) {
        return _schemas[schemaId].currentFee;
    }

    function getProtocolFeePercentage() external view returns (uint256) {
        return PROTOCOL_FEE_PERCENTAGE;
    }

    function getVoterFeePercentage() external view returns (uint256) {
        return VOTER_FEE_PERCENTAGE;
    }

    function getDelayPeriod() external view returns (uint256) {
        return DELAY_PERIOD;
    }

    /*
    function getAddressBook() external view returns (IAddressBook) {
        return _addressBook;
    }

    function getEpochController() external view returns (IEpochController) {
        return _epochController;
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

