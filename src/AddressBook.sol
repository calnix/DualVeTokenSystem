// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {Ownable2Step, Ownable} from "./../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Pausable} from "./../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";

import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";

/**
 * @title AddressBook
 * @author Calnix [@cal_nix]
 * @notice Centralized address book for all system addresses [Main registry of addresses part of or connected to the protocol]
 * @dev Owned by Governance multisig
 */

contract AddressBook is Ownable2Step, Pausable {

    // ..... Main identifiers .....

    // Tokens
    bytes32 private constant USD8 = 'USD8';
    bytes32 private constant MOCA = 'MOCA';
    bytes32 private constant ES_MOCA = 'ES_MOCA';
    bytes32 private constant VOTING_ESCROW_MOCA = 'VOTING_ESCROW_MOCA';
    
    // Controllers
    bytes32 private constant ACCESS_CONTROLLER = 'ACCESS_CONTROLLER';
    bytes32 private constant VOTING_CONTROLLER = 'VOTING_CONTROLLER';
    bytes32 private constant PAYMENTS_CONTROLLER = 'PAYMENTS_CONTROLLER'; 
    bytes32 private constant ROUTER = 'ROUTER';
    
    // Treasury
    bytes32 private constant TREASURY = 'TREASURY';

    // Map of registered addresses
    mapping(bytes32 identifier => address registeredAddress) internal _addresses;

    // risk
    uint256 public isFrozen;

    constructor(address globalAdmin) Ownable(globalAdmin) {

        // set global admin: DEFAULT_ADMIN_ROLE
        _addresses[bytes32(0)] = globalAdmin;
    }

// ------------------------------ Setters --------------------------------

    //REVIEW
    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner whenNotPaused {
        // cannot change address for 0x00: DEFAULT_ADMIN_ROLE
        require(identifier != bytes32(0), "Invalid identifier");

        require(registeredAddress != address(0), "Invalid address");

        _addresses[identifier] = registeredAddress;

        emit Events.AddressSet(identifier, registeredAddress);
    }


    /**
     * @notice Updates the global admin address in the address book.
     * @dev Only callable by the contract owner when not paused. 
     *      Emits a GlobalAdminUpdated event with the previous and new admin addresses.
     * @param globalAdmin The new global admin address to set.
     */
    function updateGlobalAdmin(address globalAdmin) external onlyOwner whenNotPaused {
        require(globalAdmin != address(0), "Invalid address");

        emit Events.GlobalAdminUpdated(_addresses[bytes32(0)], globalAdmin);
        
        // update global admin
        _addresses[bytes32(0)] = globalAdmin;
    }

// ------------------------------ Getters --------------------------------

    /**
       REVIEW: should these be whenNotPaused?   
       if we pause this contract - assume a malicious actor has changed an address,
       so pause all view functions as well. 
       @audit : R - what do you think?   
     */

    /**
     * @notice Returns the registered address for a given identifier.
     * @dev Reverts if the contract is paused.
     * @param identifier The bytes32 identifier for the registered address.
     * @return The address associated with the given identifier.
     */
    function getAddress(bytes32 identifier) external view whenNotPaused returns (address) {
        return _addresses[identifier];
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

    function getRouter() external view whenNotPaused returns (address) {
        return _addresses[ROUTER];
    }

//-------------------------------Risk functions-----------------------------

    /**
     * @notice Pause the contract.
     * @dev Only callable by the Owner [multi-sig].
     */
    function pause() external whenNotPaused onlyOwner {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _pause();
    }

    /**
     * @notice Unpause the contract.
     * @dev Only callable by the Owner [multi-sig].
     */
    function unpause() external whenPaused onlyOwner {
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice Freeze the contract.
     * @dev Only callable by the Owner [multi-sig].
     *      This is a kill switch function
     */
    function freeze() external whenPaused onlyOwner {
        if(isFrozen == 1) revert Errors.IsFrozen();
        isFrozen = 1;
        emit Events.ContractFrozen();
    }

}
