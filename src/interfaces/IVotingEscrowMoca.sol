// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DataTypes} from "../libraries/DataTypes.sol";

interface IVotingEscrowMoca {

    /**
     * @notice Returns the current personal voting power (veBalance) of a user.
     * @param user The address of the user whose veBalance is being queried.
     * @return The current personal veBalance of the user.
     */
    function balanceOf(address user) external view returns (uint256);

    /**
     * @notice Returns the current voting power (veBalance) of a user.
     * @param user The address of the user whose veBalance is being queried.
     * @param forDelegated If true: delegated veBalance; if false: personal veBalance.
     * @return The current veBalance of the user.
     */
    function balanceOf(address user, bool forDelegated) external view returns (uint256);

    /**
     * @notice Historical search of a user's voting escrowed balance (veBalance) at a specific timestamp.
     * @param user The address of the user whose veBalance is being queried.
     * @param time The historical timestamp for which the veBalance is requested.
     * @param forDelegated If true: delegated veBalance; if false: personal veBalance.
     * @return The user's veBalance at the specified timestamp.
     */
    function balanceOfAt(address user, uint256 time, bool forDelegated) external view returns (uint256);
}
