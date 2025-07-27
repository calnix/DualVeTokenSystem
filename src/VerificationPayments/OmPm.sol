// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker, ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

import {Constants} from "../Constants.sol";
import {EpochController} from "../EpochController.sol";

import {IAddressBook} from "../interfaces/IAddressBook.sol";
import {IEscrowedMoca} from "../interfaces/IEscrowedMoca.sol";

contract OweMoneyPayMoney is EIP712, AccessControl {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    // addresses
    IAddressBook internal _addressBook;
    EpochController public epochController;

    // fees
    uint256 private PROTOCOL_FEE_PERCENTAGE; // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)
    uint256 private VOTER_FEE_PERCENTAGE;    // 100%: 10_000, 1%: 100, 0.1%: 10 | 2dp precision (XX.yy)

    // issuer fee delay
    uint256 private DELAY_PERIOD;            // in seconds


    struct Issuer {
        bytes32 issuerId;
        address wallet;            // for claiming fees | updatable

        //uint128 stakedMoca;
        
        // credentials
        uint128 totalIssuances; // incremented on each verification
        
        // USD8
        uint128 totalEarned;
        uint128 totalClaimed;
    }

    mapping(bytes32 issuerId => Issuer issuer) public issuers;

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

    mapping(bytes32 credentialId => Credential credential) public credentials;

    struct Verifier {
        bytes32 verifierId;
        address signerAddress;

        uint128 balance;
        uint128 totalExpenditure;
    }

    mapping(bytes32 verifierId => Verifier verifier) public verifiers;


    bytes32 public constant TYPEHASH = keccak256("DeductBalance(bytes32 issuerId,bytes32 verifierId,bytes32 credentialId,uint256 amount,uint256 expiry,uint256 nonce)");
    // nonces for preventing race conditions [ECDSA.sol::recover handles sig.mal]
    mapping(address verifier => uint256 nonce) public verifierNonces;



    // epoch accounting: treasury + voters
    struct Epoch {
        uint128 feesAccruedToTreasury;
        uint128 feesAccruedToVoters;
    }
    mapping(uint256 epoch => Epoch epoch) public epochs;


//-------------------------------constructor-----------------------------------------

    constructor(
        address usd8_, address treasury_, uint256 protocolFeePercentage_, uint256 delayPeriod_, address epochController_,
        string memory name, string memory version) EIP712(name, version) {

        // check if addresses are valid
        require(treasury_ != address(0), "Invalid treasury address");
        require(usd8_ != address(0), "Invalid USD8 address");

        USD8 = IERC20(usd8_);
        treasury = treasury_;

        require(protocolFeePercentage_ < Constants.PRECISION_BASE, "Invalid protocol fee percentage");
        require(protocolFeePercentage_ > 0, "Invalid protocol fee percentage");
        PROTOCOL_FEE_PERCENTAGE = protocolFeePercentage_;

        require(delayPeriod_ > 0, "Invalid delay period");
        DELAY_PERIOD = delayPeriod_;
        
        epochController = EpochController(epochController_);
    }


//-------------------------------admin functions-----------------------------------------

// TODO: complete designing Global Access Control layer for all contracts | add modifiers here
/*
    // note: only admin can update delay period | add ACL modifier
    function updateDelayPeriod(uint256 delayPeriod) external {
        require(delayPeriod > 0, "Invalid delay period");
        DELAY_PERIOD = delayPeriod;

        // emit DelayPeriodUpdated(delayPeriod);
    }
*/

//-------------------------------issuer functions-----------------------------------------

    // new issuer: generate issuerId
    function setupIssuer() external returns (bytes32) {
        
        // generate issuerId
        bytes32 issuerId;
        {
            uint256 salt = ++block.number; 
            issuerId = _generateId(salt, msg.sender);
            while (issuers[issuerId].issuerId != bytes32(0)) issuerId = _generateId(++salt, msg.sender);  // If issuerId exists, generate new random Id
        }

        // setup issuer
        Issuer memory issuer;
            issuer.issuerId = issuerId;
            issuer.wallet = msg.sender;
        
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
            while (verifiers[verifierId].verifierId != bytes32(0)) verifierId = _generateId(++salt, msg.sender);  // If verifierId exists, generate new random Id
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
        uint256 currentEpoch = epochController.getCurrentEpoch();
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

//-------------------------------view functions---------------------------------------------

    
    //note: if credentialId is unique pairwise,{issuerId, credentialType}; drop issuerId param
    function getPrice(bytes32 issuerId, bytes32 credentialId) external view returns (uint256) {
    }

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

