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
    //bytes32 private constant EPOCH_CONTROLLER = 'EPOCH_CONTROLLER';
    bytes32 private constant ACCESS_CONTROLLER = 'ACCESS_CONTROLLER';
    bytes32 private constant VOTING_CONTROLLER = 'VOTING_CONTROLLER';
    bytes32 private constant PAYMENTS_CONTROLLER = 'PAYMENTS_CONTROLLER';   //OmPm.sol
    bytes32 private constant ROUTER = 'ROUTER';
    
    // Treasury
    bytes32 private constant TREASURY = 'TREASURY';

    // TODO: Admin -> check for coherence against ACL
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;


    // Map of registered addresses
    mapping(bytes32 identifier => address registeredAddress) private _addresses;


    constructor(address globalAdmin_) Ownable(globalAdmin_) {

        // set global admin: DEFAULT_ADMIN_ROLE
        _addresses[DEFAULT_ADMIN_ROLE] = globalAdmin_;
    }


// ------------------------------ Getters --------------------------------

    function getAddress(bytes32 identifier) external view returns (address) {
        return _addresses[identifier];
    }


    function getUSD8Token() external view returns (address) {   // forge-lint: disable-line(mixed-case-function)
        return _addresses[USD8];
    }

    function getMoca() external view returns (address) {
        return _addresses[MOCA];
    }

    function getEscrowedMoca() external view returns (address) {
        return _addresses[ES_MOCA];
    }

    function getVotingEscrowMoca() external view returns (address) {
        return _addresses[VOTING_ESCROW_MOCA];
    }

    function getAccessController() external view returns (address) {
        return _addresses[ACCESS_CONTROLLER];
    }

    function getVotingController() external view returns (address) {
        return _addresses[VOTING_CONTROLLER];
    }

    function getPaymentsController() external view returns (address) {
        return _addresses[PAYMENTS_CONTROLLER];
    }

    function getRouter() external view returns (address) {
        return _addresses[ROUTER];
    }


    function getTreasury() external view returns (address) {
        return _addresses[TREASURY];
    }

    function getGlobalAdmin() external view returns (address) {
        return _addresses[DEFAULT_ADMIN_ROLE];
    }

// ------------------------------ Setters --------------------------------

    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner {
        _addresses[identifier] = registeredAddress;

        // emit AddressSet(identifier, registeredAddress);
    }

}
