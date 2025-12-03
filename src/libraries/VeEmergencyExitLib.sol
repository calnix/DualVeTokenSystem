// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DataTypes} from "./DataTypes.sol";
import {Events} from "./Events.sol";

// contracts
import {LowLevelWMoca} from "../LowLevelWMoca.sol";

/**
 * @title EmergencyExitLib
 * @notice External linked library for emergency exit logic
 * @dev Deployed separately and linked at deploy time to reduce main contract size.
 *      Uses delegatecall, so storage operations persist in the calling contract.
 */
library VeEmergencyExitLib {
    using SafeERC20 for IERC20;

    /**
     * @notice Execute emergency exit for specified locks
     * @dev Storage pointers are passed directly; updates persist in caller's storage via delegatecall.
     * @param lockIds Array of lock IDs to process
     * @param locks Storage mapping of locks
     * @param esMoca esMOCA token contract
     * @param totalLockedMoca Storage pointer to total locked MOCA
     * @param totalLockedEsMoca Storage pointer to total locked esMOCA
     * @param wMoca WMOCA contract address
     * @param mocaTransferGasLimit Gas limit for MOCA transfers
     * @param transferMocaFn Function pointer for MOCA transfer with wrap fallback
     * @return totalLocksProcessed Number of locks processed
     * @return totalMocaReturned Total MOCA returned
     * @return totalEsMocaReturned Total esMOCA returned
     */
    function executeEmergencyExit(
        bytes32[] calldata lockIds,
        mapping(bytes32 => DataTypes.Lock) storage locks,
        uint128 storage TOTAL_LOCKED_MOCA,
        uint128 storage TOTAL_LOCKED_ESMOCA,
        IERC20 ESMOCA,
        address wMoca,
        uint256 MOCA_TRANSFER_GAS_LIMIT,
        function(address, address, uint256, uint256) internal transferMocaFn
    ) external returns (uint128 totalLocksProcessed, uint128 totalMocaReturned, uint128 totalEsMocaReturned) {
        
        // Track totals for single event emission
        uint128 totalMocaReturned;
        uint128 totalEsMocaReturned;
        uint128 totalLocksProcessed;

        uint256 length = lockIds.length;

        for (uint256 i; i < length; ++i) {
            DataTypes.Lock storage lockPtr = locks[lockIds[i]];

            // Skip invalid/already processed locks
            if (lockPtr.owner == address(0) || lockPtr.isUnlocked) continue;

            // Mark unlocked
            lockPtr.isUnlocked = true;

            // Handle esMoca
            if (lockPtr.esMoca > 0) {

                uint128 esMocaToReturn = lockPtr.esMoca;
                delete lockPtr.esMoca;
                TOTAL_LOCKED_ESMOCA -= esMocaToReturn;
                
                // increment counter
                totalEsMocaReturned += esMocaToReturn;

                ESMOCA.safeTransfer(lockPtr.owner, esMocaToReturn);
            }

            // Handle moca
            if (lockPtr.moca > 0) {

                uint128 mocaToReturn = lockPtr.moca;
                delete lockPtr.moca;
                TOTAL_LOCKED_MOCA -= mocaToReturn;
                
                // increment counter
                totalMocaReturned += mocaToReturn;

                // transfer moca [wraps if transfer fails within gas limit]
                _transferMocaAndWrapIfFailWithGasLimit(WMOCA, lockPtr.owner, mocaToReturn, MOCA_TRANSFER_GAS_LIMIT);
            }

            ++totalLocksProcessed;
        }

        // emit event if total locks processed is > 0
        if (totalLocksProcessed > 0) emit Events.EmergencyExit(lockIds, totalLocksProcessed, totalMocaReturned, totalEsMocaReturned);

        // return totals
        return (totalLocksProcessed, totalMocaReturned, totalEsMocaReturned);
    }
}