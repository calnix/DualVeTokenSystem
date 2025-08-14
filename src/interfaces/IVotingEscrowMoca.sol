// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {DataTypes} from "../libraries/DataTypes.sol";

interface IVotingEscrowMoca {

    function delegatedAggregationHistory(address user, address delegate, uint128 eTime) external view returns (DataTypes.VeBalance memory);

    function getDelegatedBalanceAtEpochEnd(address user, address delegate, uint128 eTime) external view returns (uint256);
}
