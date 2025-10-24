// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IAddressBook
 * @author Calnix
 * @notice Interface for the AddressBook central registry contract
 */
interface IAddressBook {
    // ----------- Getters -----------

    /// @notice Returns the address registered for a given identifier.
    /// @dev Reverts if the contract is paused.
    /// @param identifier The bytes32 identifier.
    /// @return The address associated with the identifier.
    function getAddress(bytes32 identifier) external view returns (address);

    /// @notice Returns LZ MOCA_NATIVE_ADAPTER address
    function getMocaNativeAdapter() external view returns (address);

    /// @notice Returns the USD8 token address.
    function getUSD8() external view returns (address);

    /// @notice Returns the MOCA token address.
    function getMoca() external view returns (address);

    /// @notice Returns the escrowed MOCA token (ES_MOCA) address.
    function getEscrowedMoca() external view returns (address);

    /// @notice Returns the Voting Escrow MOCA contract (VOTING_ESCROW_MOCA) address.
    function getVotingEscrowMoca() external view returns (address);

    /// @notice Returns the Access Controller contract address.
    function getAccessController() external view returns (address);

    /// @notice Returns the Voting Controller contract address.
    function getVotingController() external view returns (address);

    /// @notice Returns the Payments Controller contract address.
    function getPaymentsController() external view returns (address);

    /// @notice Returns the Issuer Staking Controller contract address.
    function getIssuerStakingController() external view returns (address);

    /// @notice Returns the Treasury contract address.
    function getTreasury() external view returns (address);

    /// @notice Returns the Global Admin address.
    function getGlobalAdmin() external view returns (address);

    /// @notice Returns router address.
    function getRouter() external view returns (address);

    // ----------- Setters -----------

    /// @notice Sets the address for a given identifier in the address book.
    /// @dev Only callable by the contract owner when not paused.
    ///      Cannot set or change the address for the bytes32(0) (DEFAULT_ADMIN_ROLE).
    /// @param identifier The bytes32 identifier for the registered address.
    /// @param registeredAddress The address to register.
    function setAddress(bytes32 identifier, address registeredAddress) external;

    // ----------- Risk Management -----------

    /// @notice Pause the contract (Only callable by owner).
    function pause() external;

    /// @notice Unpause the contract (Only callable by owner).
    function unpause() external;

    /// @notice Freeze the contract (kill switch, only callable by owner).
    function freeze() external;
}
