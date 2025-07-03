// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Constants} from "./Constants.sol";

library WeekMath {

    // consider moving constants for: week,min,max to here

    function getWeekStartTimestamp(uint128 timestamp) internal pure returns (uint128) {
        return (timestamp / Constants.WEEK) * Constants.WEEK;
    }

    function getCurrentWeekStart() internal view returns (uint128) {
        return getWeekStartTimestamp(uint128(block.timestamp));
    }

    function isValidWTime(uint256 time) internal pure returns (bool) {
        return time % Constants.WEEK == 0;
    }
}