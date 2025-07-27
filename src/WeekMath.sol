// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.27;

import {Constants} from "./Constants.sol";

library WeekMath {

    function getCurrentWeekStart() internal view returns (uint128) {
        return getWeekStartTimestamp(uint128(block.timestamp));
    }

    function getWeekStartTimestamp(uint128 timestamp) internal pure returns (uint128) {
        return (timestamp / Constants.WEEK) * Constants.WEEK;
    }

    function isValidWTime(uint128 time) internal pure returns (bool) {
        return time % Constants.WEEK == 0;
    }
}