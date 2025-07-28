// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {RevertMsgExtractor} from "./utils/RevertMsgExtractor.sol";


contract Router {

    
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