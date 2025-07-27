// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/**
 * @title IEscrowedMoca
 * @author Calnix
 * @notice Defines the basic interface for EscrowedMoca.sol
 */

interface IEscrowedMoca {
    // convert moca to esMoca
    function escrow(uint256 amount) external;

    // redeem esMoca for moca
    function redeem(uint256 redemptionAmount, uint256 redemptionOption) external;
}
