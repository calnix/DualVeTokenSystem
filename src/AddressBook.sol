// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title AddressBook
 * @author Calnix
 * @notice Centralized address book for all system addresses.
 */

contract AddressBook is Ownable {

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
    
    // Treasury
    bytes32 private constant TREASURY = 'TREASURY';

    // Map of registered addresses
    mapping(bytes32 identifier => address registeredAddress) private _addresses;


    constructor(address globalAdmin_) Ownable(globalAdmin_) {

        // set global admin: DEFAULT_ADMIN_ROLE
        _addresses[GLOBAL_ADMIN] = globalAdmin_;
    }


// ------------------------------ Getters --------------------------------

    function getAddress(bytes32 identifier) external view returns (address) {
        return _addresses[identifier];
    }


    function getUSD8Token() external view returns (address) {
        return _addresses[USD8];
    }

    function getMocaToken() external view returns (address) {
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


    function getTreasury() external view returns (address) {
        return _addresses[TREASURY];
    }

    function getGlobalAdmin() external view returns (address) {
        return _addresses[GLOBAL_ADMIN];
    }

// ------------------------------ Setters --------------------------------

    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner {
        _addresses[identifier] = registeredAddress;

        // emit AddressSet(identifier, registeredAddress);
    }

}


 
// https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/configuration/PoolAddressesProvider.sol

// on batch:
// https://samczsun.com/two-rights-might-make-a-wrong/
// https://blog.trailofbits.com/2021/12/16/detecting-miso-and-opyns-msg-value-reuse-vulnerability-with-slither/

/** NOTE TODO 
    If I combine AddressBook and AccessController, it streamlines a fair bit on the calls
    However, that means that i cannot redeploy AccessController separately.

    Aave allows for repdloyment of ACL, and its latest address is updated in AddressBook.
    - is this useful for us?

 */