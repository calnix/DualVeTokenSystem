// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAddressBook
 * @author Calnix
 * @notice Defines the basic interface for AddressBook.sol
 */

interface IAddressBook {
    

    /// @notice Returns the address associated with the given identifier.
    /// @param identifier The bytes32 identifier for the address.
    /// @return The address mapped to the identifier.
    function getAddress(bytes32 identifier) external view returns (address);

    /// @notice Returns the address of the USD8 token.
    /// @return The USD8 token address.
    function getUSD8Token() external view returns (address);   // forge-lint: disable-line(mixed-case-function)

    /// @notice Returns the address of the MOCA token.
    /// @return The MOCA token address.
    function getMocaToken() external view returns (address);

    /// @notice Returns the address of the escrowed MOCA token.
    /// @return The escrowed MOCA token address.
    function getEscrowedMoca() external view returns (address);

    /// @notice Returns the address of the Voting Escrow MOCA contract.
    /// @return The Voting Escrow MOCA contract address.
    function getVotingEscrowMoca() external view returns (address);

    /// @notice Returns the address of the Access Controller contract.
    /// @return The Access Controller contract address.
    function getAccessController() external view returns (address);

    /// @notice Returns the address of the Voting Controller contract.
    /// @return The Voting Controller contract address.
    function getVotingController() external view returns (address);

    /// @notice Returns the address of the Payments Controller contract.
    /// @return The Payments Controller contract address.
    function getPaymentsController() external view returns (address);

    /// @notice Returns the address of the Treasury contract.
    /// @return The Treasury contract address.
    function getTreasury() external view returns (address);

    /// @notice Returns the address of the Global Admin.
    /// @return The Global Admin address.
    function getGlobalAdmin() external view returns (address);

    /// @notice Sets the address associated with the given identifier.
    /// @param identifier The bytes32 identifier for the address.
    /// @param registeredAddress The address to set.
    function setAddress(bytes32 identifier, address registeredAddress) external;

}
