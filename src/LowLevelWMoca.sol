// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IWMoca} from "./interfaces/IWMoca.sol";

/**
 * @title LowLevelWMoca
 * @notice This contract contains a function to transfer Moca with an option to wrap to wMoca.
 *         If the Moca transfer fails within a gas limit, the amount in Moca is wrapped to wMoca and then transferred.
 */
contract LowLevelWMoca {
    /**
     * @notice It transfers Moca to a recipient with a specified gas limit.
     *         If the original transfers fails, it wraps to wMoca and transfers the wMoca to recipient.
     * @param wMoca wMoca address
     * @param _to Recipient address
     * @param _amount Amount to transfer
     * @param _gasLimit Gas limit to perform the Moca transfer
     */
    function _transferMocaAndWrapIfFailWithGasLimit(
        address wMoca,
        address _to,
        uint256 _amount,
        uint256 _gasLimit
    ) internal {
        bool status;

        assembly {
            status := call(_gasLimit, _to, _amount, 0, 0, 0, 0)
        }

        if (!status) {
            IWMoca(wMoca).deposit{value: _amount}();
            IWMoca(wMoca).transfer(_to, _amount);
        }
    }
}