// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {Ownable2Step, Ownable} from "./../lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/**
 * @title AddressBook
 * @author Calnix
 * @notice Centralized address book for all system addresses [Main registry of addresses part of or connected to the protocol]
 * @dev Owned by Governance multisig
 */

contract AddressBook is Ownable2Step {

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
    mapping(bytes32 identifier => address registeredAddress) public addresses;


    constructor(address globalAdmin) Ownable(globalAdmin) {

        // set global admin: DEFAULT_ADMIN_ROLE
        addresses[bytes32(0)] = globalAdmin;
    }

// ------------------------------ Setters --------------------------------

    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner {
        // cannot set address for 0x00: DEFAULT_ADMIN_ROLE
        require(identifier != bytes32(0), "Invalid identifier");

        require(registeredAddress != address(0), "Invalid address");

        addresses[identifier] = registeredAddress;

        emit AddressSet(identifier, registeredAddress);
    }

    // specific to updating global admin
    function updateGlobalAdmin(address globalAdmin) external onlyOwner {
        require(globalAdmin != address(0), "Invalid address");

        emit GlobalAdminUpdated(addresses[bytes32(0)], globalAdmin);
        
        // update global admin
        addresses[bytes32(0)] = globalAdmin;
    }

// ------------------------------ Getters --------------------------------
    /**
        zero address checks are not set here, and are expected to be handled by the caller contract
        
     */

    function getUSD8Token() external view returns (address) {   // forge-lint: disable-line(mixed-case-function)
        return addresses[USD8];
    }

    function getMoca() external view returns (address) {
        return addresses[MOCA];
    }

    function getEscrowedMoca() external view returns (address) {
        return addresses[ES_MOCA];
    }

    function getVotingEscrowMoca() external view returns (address) {
        return addresses[VOTING_ESCROW_MOCA];
    }

    function getAccessController() external view returns (address) {
        return addresses[ACCESS_CONTROLLER];
    }

    function getVotingController() external view returns (address) {
        return addresses[VOTING_CONTROLLER];
    }

    function getPaymentsController() external view returns (address) {
        return addresses[PAYMENTS_CONTROLLER];
    }

    function getTreasury() external view returns (address) {
        return addresses[TREASURY];
    }

    function getGlobalAdmin() external view returns (address) {
        return addresses[DEFAULT_ADMIN_ROLE];
    }


}
