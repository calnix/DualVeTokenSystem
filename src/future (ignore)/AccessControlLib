// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IAddressBook} from "../interfaces/IAddressBook.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";
import {Errors} from "./Errors.sol";

/**
 * @title AccessControlLib
 * @notice Library for common access control operations
 */
library AccessControlLib {
    
    /**
     * @dev Get AccessController with null check
     */
    function getAccessController(IAddressBook addressBook) internal view returns (IAccessController) {
        address accessControllerAddr = addressBook.getAccessController();
        require(accessControllerAddr != address(0), Errors.InvalidAddress());
        return IAccessController(accessControllerAddr);
    }
}
