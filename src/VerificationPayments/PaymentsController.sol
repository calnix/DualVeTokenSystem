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
import {Constants} from "../Constants.sol";

// interfaces
import {IAddressBook} from "../interfaces/IAddressBook.sol";
import {IEscrowedMoca} from "../interfaces/IEscrowedMoca.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";

contract PaymentsController is EIP712, AccessControl, Pausable {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    // immutable
    IAddressBook internal immutable _addressBook;
    IEpochController internal immutable _epochController;

    // fees
    uint256 private PROTOCOL_FEE_PERCENTAGE; // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 private VOTER_FEE_PERCENTAGE;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

    // issuer fee increase delay
    uint256 private DELAY_PERIOD;            // in seconds

    uint256 public isFrozen;

    struct Issuer {
        bytes32 issuerId;
        address configAddress;     // for interacting w/ contract 
        address wallet;            // for claiming fees 
        
        //uint128 stakedMoca;
        
        // credentials
        uint128 totalIssuances; // incremented on each verification
        
        // USD8
        uint128 totalEarned;
        uint128 totalClaimed;
    }

    mapping(bytes32 issuerId => Issuer issuer) private _issuers;

    // each credential is unique pairwise {issuerId, credentialType}
    struct Credential {
        bytes32 credentialId;
        bytes32 issuerId;
        
        // fees are expressed in USD8 terms
        uint128 currentFee;
        uint128 nextFee;
        uint128 nextFeeTimestamp;       // could use epoch and epochMath?

        // counts
        uint128 totalIssued;
        uint128 totalFeesAccrued;
    }

    mapping(bytes32 credentialId => Credential credential) private _credentials;

    struct Verifier {
        bytes32 verifierId;
        address signerAddress;
        address depositAddress;

        uint128 balance;
        uint128 totalExpenditure;
    }

    mapping(bytes32 verifierId => Verifier verifier) private _verifiers;


    bytes32 public constant TYPEHASH = keccak256("DeductBalance(bytes32 issuerId,bytes32 verifierId,bytes32 credentialId,uint256 amount,uint256 expiry,uint256 nonce)");
    // nonces for preventing race conditions [ECDSA.sol::recover handles sig.mal]
    mapping(address verifier => uint256 nonce) private _verifierNonces;



    // epoch accounting: treasury + voters
    struct Epoch {
        uint128 feesAccruedToTreasury;
        uint128 feesAccruedToVoters;
    }
    mapping(uint256 epoch => mapping(bytes32 credentialId => Epoch epoch)) private _epochs;


//-------------------------------constructor-----------------------------------------

    constructor(
        address usd8_, address treasury_, uint256 protocolFeePercentage_, uint256 delayPeriod_, address epochController_,
        string memory name, string memory version) EIP712(name, version) {

        // check if addresses are valid
        //require(treasury_ != address(0), "Invalid treasury address");
        //require(usd8_ != address(0), "Invalid USD8 address");

        //USD8 = IERC20(usd8_);
        //treasury = treasury_;

        require(protocolFeePercentage_ < Constants.PRECISION_BASE, "Invalid protocol fee percentage");
        require(protocolFeePercentage_ > 0, "Invalid protocol fee percentage");
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage_;

        require(delayPeriod_ > 0, "Invalid delay period");
        DELAY_PERIOD = delayPeriod_;
        
        _epochController = IEpochController(epochController_);
    }

//-------------------------------issuer functions-----------------------------------------

    // new issuer: generate issuerId
    function setupIssuer(address wallet) external returns (bytes32) {
        
        // generate issuerId
        bytes32 issuerId;
        {
            uint256 salt = ++block.number; 
            issuerId = _generateId(salt, msg.sender);
            // If generated id is used by either issuer or verifier, generate new Id
            while (issuers[issuerId].issuerId != bytes32(0) || verifiers[issuerId].verifierId != bytes32(0)) {
                issuerId = _generateId(++salt, msg.sender); 
            }
        }

        // setup issuer
        Issuer memory issuer;
            issuer.issuerId = issuerId;
            issuer.configAddress = msg.sender;
            issuer.wallet = wallet;
        
        // store issuer
        issuers[issuerId] = issuer;

        // emit IssuerCreated(issuerId, msg.sender);

        return issuerId;
    }


    // new issuance program: verify credentialId is not already setup
    // assumption: credentialId is generated by BE and is bytes32 
    // note: msg.sender is issuer
    function setupCredential(bytes32 issuerId, bytes32 credentialId, uint128 fee) external returns {
        // check if credentialId is not being used
        require(credentials[credentialId].credentialId == bytes32(0), "CredentialId already in use");

        // check if issuerId matches msg.sender
        require(issuers[issuerId].wallet == msg.sender, "Issuer Id<->Address mismatch");

        // check if fee is valid
        //require(fee > 0, "Invalid fee"); --- free credentials are allowed?
        require(fee < Constants.PRECISION_BASE, "Invalid fee");

        // set fee
        credentials[credentialId].credentialId = credentialId;
        credentials[credentialId].issuerId = issuerId;
        credentials[credentialId].currentFee = fee;

        // emit CredentialFeeUpdated(issuerId, credentialId, fee);
    }


    function updateFee(bytes32 issuerId, bytes32 credentialId, uint256 fee) external {
        // check if credentialId is valid
        require(credentials[credentialId].credentialId != bytes32(0), "Invalid credentialId");

        // check if issuerId matches msg.sender
        require(issuers[issuerId].wallet == msg.sender, "Issuer Id<->Address mismatch");

        // check if fee is valid
        require(fee < Constants.PRECISION_BASE, "Invalid fee");

        // decrementing fee is instant 
        if(fee < credentials[credentialId].currentFee) {
            credentials[credentialId].currentFee = fee;

            // emit CredentialFeeUpdated(issuerId, credentialId, fee);

        } else {

            // incrementing fee is delayed
            credentials[credentialId].nextFee = fee;
            credentials[credentialId].nextFeeTimestamp = block.timestamp + DELAY_PERIOD;

            // emit CredentialFeeUpdatedDelayed(issuerId, credentialId, fee);
        }
    }

    //note: for issuers to change receiving payment address
    function updateWalletAddress(bytes32 issuerId, address wallet) external {
        // check if issuerId matches msg.sender
        require(issuers[issuerId].wallet == msg.sender, "Issuer Id<->Address mismatch");

        // update wallet address
        issuers[issuerId].wallet = wallet;

        // emit WalletAddressUpdated(issuerId, wallet);
    }

    function claimFees(bytes32 issuerId) external {
        // check if issuerId matches msg.sender
        require(issuers[issuerId].wallet == msg.sender, "Issuer Id<->Address mismatch");

        uint256 feesToClaim = issuers[issuerId].totalEarned - issuers[issuerId].totalClaimed;

        // check if issuer has fees to claim
        require(feesToClaim > 0, "No fees to claim");

        // update total claimed
        issuers[issuerId].totalClaimed += feesToClaim;

        // emit FeesClaimed(issuerId, feesToClaim);

        // transfer fees to issuer
        USD8.safeTransfer(msg.sender, feesToClaim);
    }

//-------------------------------verifier functions-----------------------------------------

    function setupVerifier() external returns (bytes32) {
        // generate verifierId
        bytes32 verifierId;
        {
            uint256 salt = ++block.number; 
            verifierId = _generateId(salt, msg.sender);
            // If generated id is used by either issuer or verifier, generate new Id
            while (verifiers[verifierId].verifierId != bytes32(0) || issuers[verifierId].issuerId != bytes32(0)) {
                verifierId = _generateId(++salt, msg.sender); 
            }
        }

        // setup verifier
        Verifier memory verifier;
            verifier.verifierId = verifierId;
            verifier.wallet = msg.sender;

        // store verifier
        verifiers[verifierId] = verifier;

        // emit VerifierCreated(verifierId, msg.sender);

        return verifierId;
    }

    function deposit(bytes32 verifierId, uint256 amount) external {
        // check if verifierId is valid + matches msg.sender
        require(verifiers[verifierId].wallet == msg.sender, "Verifier Id<->Address mismatch");

        // update balance
        verifiers[verifierId].balance += amount;

        // emit Deposit(verifierId, amount);

        // transfer funds to verifier
        IERC20(_addressBook.getUSD8Token()).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(bytes32 verifierId, uint256 amount) external {
        // check if verifierId is valid + matches msg.sender
        require(verifiers[verifierId].wallet == msg.sender, "Verifier Id<->Address mismatch");

        // check if verifier has enough balance
        uint256 balance = verifiers[verifierId].balance;
        require(balance >= amount, "Insufficient balance");

        // update balance
        verifiers[verifierId].balance = balance - amount;

        // emit Withdraw(verifierId, amount);

        // transfer funds to verifier
        IERC20(_addressBook.getUSD8Token()).safeTransfer(msg.sender, amount);
    }

    // must be called from old signerAddress
    function updateSignerAddress(bytes32 verifierId, address signerAddress) external {
        // check if verifierId matches msg.sender
        require(verifiers[verifierId].signerAddress == msg.sender, "Verifier Id<->Address mismatch");

        // update signer address
        verifiers[verifierId].signerAddress = signerAddress;

        // emit SignerAddressUpdated(verifierId, signerAddress);
    }

//-------------------------------VERIFIER CONTRACT CALL -----------------------------------------


    // make this fn as gas optimized as possible
    function deductBalance(bytes32 issuerId, bytes32 verifierId, bytes32 credentialId, uint256 amount, uint256 expiry, bytes calldata signature) external {
        //if(expiry < block.timestamp) revert Errors.SignatureExpired();

        // check if amount matches credential fee set by issuer
        uint256 credentialFee = credentials[credentialId].currentFee;
        require(amount == credentialFee, "Amount does not match credential fee");

        // check if sufficient balance
        require(verifiers[verifierId].balance >= amount, "Insufficient balance");

        // to get nonce + signerAddress
        address signerAddress = verifiers[verifierId].signerAddress;

        // verify signature | note: check inputs
        bytes32 hash = _hashTypedDataV4(keccak256(abi.encode(TYPEHASH, issuerId, verifierId, credentialId, amount, expiry, verifierNonces[signerAddress])));

        // handles both EOA and contract signatures | returns true if signature is valid
        require(SignatureChecker.isValidSignatureNowCalldata(signerAddress, hash, signature), "Invalid signature");

        // calc. fee split
        unchecked{
            uint256 protocolFee = (PROTOCOL_FEE_PERCENTAGE > 0) ? (amount * PROTOCOL_FEE_PERCENTAGE) / Constants.PRECISION_BASE : 0;
            uint256 voterFee = (VOTER_FEE_PERCENTAGE > 0) ? (protocolFee * VOTER_FEE_PERCENTAGE) / Constants.PRECISION_BASE : 0;
            uint256 treasuryFee = (protocolFee - voterFee);
        }

        // update nonce
        ++verifierNonces[signerAddress];

        // verifier accounting
        verifiers[verifierId].balance -= amount;
        verifiers[verifierId].totalExpenditure += amount;

        // issuer accounting
        issuers[issuerId].totalEarned += (amount - protocolFee);
        ++issuers[issuerId].totalIssuances;

        // credential accounting
        credentials[credentialId].totalFeesAccrued += amount;
        ++credentials[credentialId].totalIssued;
        
        // treasury + voters accounting
        uint256 currentEpoch = _epochController.getCurrentEpoch();
        epochs[currentEpoch].feesAccruedToTreasury += treasuryFee;
        epochs[currentEpoch].feesAccruedToVoters += voterFee;  

        // emit BalanceDeducted(verifierId, credentialId, issuerId, amount);
        // do we need more events for the other accounting actions?
    }

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

    ///@dev Generate a issuerId. keccak256 is cheaper than using a counter with a SSTORE, even accounting for eventual collision retries.
    function _generateId(uint256 salt, address user) internal view returns (bytes32) {
        return bytes32(keccak256(abi.encode(user, block.timestamp, salt)));
    }


//-------------------------------admin functions-----------------------------------------


    function updateDelayPeriod(uint256 delayPeriod) external onlyPaymentsAdmin {
        require(delayPeriod > 0, "Invalid delay period");
        require(delayPeriod % Constants.EPOCH_DURATION == 0, "Delay period must be a multiple of epoch duration");

        DELAY_PERIOD = delayPeriod;

        // emit DelayPeriodUpdated(delayPeriod);
    }

    // protocol fee can be 0
    function updateProtocolFeePercentage(uint256 protocolFeePercentage) external onlyPaymentsAdmin {
        // protocol fee cannot be greater than 100%
        require(protocolFeePercentage < Constants.PRECISION_BASE, "Invalid protocol fee percentage");
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage;

        // emit ProtocolFeePercentageUpdated(protocolFeePercentage);
    }

    // voter fee can be 0
    function updateVoterFeePercentage(uint256 voterFeePercentage) external onlyPaymentsAdmin {
        // voter fee cannot be greater than 100%
        require(voterFeePercentage < Constants.PRECISION_BASE, "Invalid voter fee percentage");
        VOTER_FEE_PERCENTAGE = voterFeePercentage;

        // emit VoterFeePercentageUpdated(voterFeePercentage);
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
        emit ContractFrozen(block.timestamp);
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
            uint256 verifierBalance = verifiers[verifierIds[i]].balance;
            if(verifierBalance == 0) continue;

            // get deposit address
            address verifierDepositAddress = verifiers[verifierIds[i]].depositAddress;

            // transfer balance to verifier
            IERC20(usd8).safeTransfer(verifierDepositAddress, verifierBalance);
        }

        // emit EmergencyExitVerifiers(verifierIds);
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
            uint256 issuerBalance = issuers[issuerIds[i]].totalEarned - issuers[issuerIds[i]].totalClaimed;
            if(issuerBalance == 0) continue;

            // get wallet address
            address issuerWallet = issuers[issuerIds[i]].wallet;

            // transfer balance to issuer
            IERC20(usd8).safeTransfer(issuerWallet, issuerBalance);
        }

        // emit EmergencyExitIssuers(issuerIds);
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

    /**
     * @notice Returns the fees accrued to voters for a given epoch
     * @param epoch The epoch number
     * @param credentialId The credential id
     * @return feesAccruedToVoters The amount of fees accrued to voters in the given epoch
     */
    function feesAccruedToVoters(uint256 epoch, bytes32 credentialId) external view returns (uint256) {
        return _epochs[epoch][credentialId].feesAccruedToVoters;
    }


    function getIssuer(bytes32 issuerId) external view returns (Issuer memory) {
        return _issuers[issuerId];
    }

    function getCredential(bytes32 credentialId) external view returns (Credential memory) {
        return _credentials[credentialId];
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
    function getCredentialFee(bytes32 credentialId) external view returns (uint256) {
        return _credentials[credentialId].currentFee;
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

