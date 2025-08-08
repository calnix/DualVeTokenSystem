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




// on batch:
// https://samczsun.com/two-rights-might-make-a-wrong/
// https://blog.trailofbits.com/2021/12/16/detecting-miso-and-opyns-msg-value-reuse-vulnerability-with-slither/