// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {RevertMsgExtractor} from "./utils/RevertMsgExtractor.sol";

contract AddressBook is Ownable {
    //using SafeERC20 for IERC20;

    // Main identifiers
    bytes32 private constant MOCA_TOKEN = 'MOCA_TOKEN';
    bytes32 private constant ES_MOCA = 'ES_MOCA';
    bytes32 private constant VOTING_ESCROW_MOCA = 'VOTING_ESCROW_MOCA';
    
    // controllers
    bytes32 private constant EPOCH_CONTROLLER = 'EPOCH_CONTROLLER';
    bytes32 private constant VOTING_CONTROLLER = 'VOTING_CONTROLLER';
    
    bytes32 private constant TREASURY = 'TREASURY';

    // Map of registered addresses
    mapping(bytes32 identifier => address registeredAddress) private _addresses;

    constructor() Ownable(msg.sender) {
    }


// ------------------------------ Getters --------------------------------
    function getAddress(bytes32 identifier) external view returns (address) {
        return _addresses[identifier];
    }

    function getMocaToken() external view returns (address) {
        return _addresses[MOCA_TOKEN];
    }

    function getEscrowedMoca() external view returns (address) {
        return _addresses[ES_MOCA];
    }

    function getVotingEscrowMoca() external view returns (address) {
        return _addresses[VOTING_ESCROW_MOCA];
    }

    function getVotingController() external view returns (address) {
        return _addresses[VOTING_CONTROLLER];
    }

    function getEpochController() external view returns (address) {
        return _addresses[EPOCH_CONTROLLER];
    }

    function getTreasury() external view returns (address) {
        return _addresses[TREASURY];
    }

// ------------------------------ Setters --------------------------------
    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner {
        _addresses[identifier] = registeredAddress;

        // emit AddressSet(identifier, registeredAddress);
    }

// ------------------------------ Batch --------------------------------

    // TODO MOVE TO ROUTER
    /// @dev Allows batched call to self (this contract).
    /// @param calls An array of inputs for each call.
    /// note: batch is also an issue if you use msg.value inside it
    function batch(bytes[] calldata calls) external payable returns (bytes[] memory results) {
        results = new bytes[](calls.length);

        for (uint256 i; i < calls.length; i++) {

            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) revert(RevertMsgExtractor.getRevertMsg(result));
            results[i] = result;
        }
    }

}


 
// https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/configuration/PoolAddressesProvider.sol

// on batch:
// https://samczsun.com/two-rights-might-make-a-wrong/
// https://blog.trailofbits.com/2021/12/16/detecting-miso-and-opyns-msg-value-reuse-vulnerability-with-slither/
