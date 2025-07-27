// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAddressBook
 * @author Calnix
 * @notice Defines the basic interface for AddressBook.sol
 */

interface IAddressBook {
    
    function getAddress(bytes32 identifier) external view returns (address);
    function setAddress(bytes32 identifier, address registeredAddress) external;
}
