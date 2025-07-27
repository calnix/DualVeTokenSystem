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
    mapping(bytes32 identifier => address registeredAddress) public addresses;


    constructor() Ownable(msg.sender) {
    }


    // Setters
    function setAddress(bytes32 identifier, address registeredAddress) external onlyOwner {
        addresses[identifier] = registeredAddress;
    }

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
