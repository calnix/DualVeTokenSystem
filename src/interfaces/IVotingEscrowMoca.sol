pragma solidity ^0.8.0;

interface IVotingEscrowMoca {

    function delegatedAggregationHistory(address user, address delegate, uint128 eTime) external view returns (DataTypes.VeBalance memory);

    function getDelegatedBalanceAtEpochEnd(address user, address delegate, uint128 eTime) external view returns (uint256);
}
