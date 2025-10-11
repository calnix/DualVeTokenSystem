// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {Ownable2Step, Ownable} from "./../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "./../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";

import {IAccessController} from "./interfaces/IAccessController.sol";

/**
 * @title AddressBook
 * @author Calnix [@cal_nix]
 * @notice Centralized address book for all system addresses [Main registry of addresses part of or connected to the protocol]
 * @dev Owned by Governance multisig
 */

contract AddressBook is Ownable2Step, Pausable {

    // --------------- Main identifiers ---------------

    // LZ
    bytes32 public constant MOCA_NATIVE_ADAPTER = 'MOCA_NATIVE_ADAPTER';

    // Tokens
    bytes32 public constant USD8 = 'USD8';
    bytes32 public constant MOCA = 'MOCA';
    bytes32 public constant ES_MOCA = 'ES_MOCA';
    bytes32 public constant VOTING_ESCROW_MOCA = 'VOTING_ESCROW_MOCA';
    
    // Controllers
    bytes32 public constant ACCESS_CONTROLLER = 'ACCESS_CONTROLLER';
    bytes32 public constant VOTING_CONTROLLER = 'VOTING_CONTROLLER';
    bytes32 public constant PAYMENTS_CONTROLLER = 'PAYMENTS_CONTROLLER'; 
    
    // Treasury
    bytes32 public constant TREASURY = 'TREASURY';

    // Router
    bytes32 public constant ROUTER = 'ROUTER';


    // Map of registered addresses | internal so that public getter can be custom paused
    mapping(bytes32 identifier => address registeredAddress) internal _addresses;

    // Risk
    uint256 public isFrozen;


    // --------------- Constructor ---------------
    constructor(address globalAdmin) Ownable(globalAdmin) {
        require(globalAdmin != address(0), Errors.InvalidAddress());
        
        // set global admin: DEFAULT_ADMIN_ROLE
        _addresses[bytes32(0)] = globalAdmin;
    }

// ------------------------------ Setters --------------------------------


    /**
     * @notice Sets the address for a given identifier in the address book.
     * @dev Only callable by the contract owner when not paused.
     *      Cannot set or change the address for the bytes32(0) (DEFAULT_ADMIN_ROLE).
     *      Emits an {AddressSet} event on success.
     * @param identifier The bytes32 identifier for the registered address.
     * @param registeredAddress The address to register for the given identifier.
     */
    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner whenNotPaused {
        // cannot change address for 0x00: DEFAULT_ADMIN_ROLE
        require(identifier != bytes32(0), Errors.InvalidId());

        require(registeredAddress != address(0), Errors.InvalidAddress());

        _addresses[identifier] = registeredAddress;

        emit Events.AddressSet(identifier, registeredAddress);
    }


    /**
     * @notice Overrides to allow synchronization with AccessController, with new global admin when contract ownership changes.
     * @dev Invoked when acceptOwnership() is executed by the new owner; updates global admin in AccessController (if registered).
     * @param newOwner Address assuming contract ownership and global admin role.
     */
    function _transferOwnership(address newOwner) internal virtual override {
        address oldOwner = owner();
        
        // Call parent implementation first
        super._transferOwnership(newOwner);
        
        // Update the stored global admin
        _addresses[bytes32(0)] = newOwner;
        
        // Update AccessController if it exists 
        address accessControllerAddr = _addresses[ACCESS_CONTROLLER];
        if (accessControllerAddr != address(0)) {
            // transfer global admin from old owner to new owner
            // will revert if AccessController is paused
            IAccessController(accessControllerAddr).transferGlobalAdminFromAddressBook(oldOwner, newOwner);
        }
        
        emit Events.GlobalAdminUpdated(oldOwner, newOwner);
    }
    
// ------------------------------ Getters --------------------------------


    /**
     * @notice Returns the registered address for a given identifier.
     * @dev Reverts if the contract is paused.
     * @param identifier The bytes32 identifier for the registered address.
     * @return The address associated with the given identifier.
     */
    function getAddress(bytes32 identifier) external view whenNotPaused returns (address) {
        return _addresses[identifier];
    }

    function getMocaNativeAdapter() external view whenNotPaused returns (address) {
        return _addresses[MOCA_NATIVE_ADAPTER];
    }

    function getUSD8() external view whenNotPaused returns (address) {   
        return _addresses[USD8];
    }

    function getMoca() external view whenNotPaused returns (address) {
        return _addresses[MOCA];
    }

    function getEscrowedMoca() external view whenNotPaused returns (address) {
        return _addresses[ES_MOCA];
    }

    function getVotingEscrowMoca() external view whenNotPaused returns (address) {
        return _addresses[VOTING_ESCROW_MOCA];
    }

    function getAccessController() external view whenNotPaused returns (address) {
        return _addresses[ACCESS_CONTROLLER];
    }

    function getVotingController() external view whenNotPaused returns (address) {
        return _addresses[VOTING_CONTROLLER];
    }

    function getPaymentsController() external view whenNotPaused returns (address) {
        return _addresses[PAYMENTS_CONTROLLER];
    }

    function getTreasury() external view whenNotPaused returns (address) {
        return _addresses[TREASURY];
    }

    function getGlobalAdmin() external view whenNotPaused returns (address) {
        return _addresses[bytes32(0)];
    }

    function getRouter() external view whenNotPaused returns (address) {
        return _addresses[ROUTER];
    }



//-------------------------------Risk functions-----------------------------

    /**
     * @notice Pause the contract.
     * @dev Only callable by the Owner [multi-sig].
     */
    function pause() external onlyOwner whenNotPaused {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _pause();
    }

    /**
     * @notice Unpause the contract.
     * @dev Only callable by the Owner [multi-sig].
     */
    function unpause() external onlyOwner whenPaused {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice Freeze the contract.
     * @dev Only callable by the Owner [multi-sig].
     *      This is a kill switch function
     */
    function freeze() external onlyOwner whenPaused {
        if(isFrozen == 1) revert Errors.IsFrozen();
        isFrozen = 1;
        emit Events.ContractFrozen();
    }

}
