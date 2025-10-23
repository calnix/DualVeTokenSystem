// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

interface IIssuerStakingController {
    // --- External Functions ---

    function stakeMoca(uint256 amount) external;

    function initiateUnstake(uint256 amount) external;

    function claimUnstake(uint256[] calldata timestamps) external;

    function setUnstakeDelay(uint256 newUnstakeDelay) external;

    function setMaxStakeAmount(uint256 newMaxStakeAmount) external;

    function pause() external;

    function unpause() external;

    function freeze() external;

    function emergencyExit() external;

    // --- View Functions ---

    function addressBook() external view returns (address);

    function TOTAL_MOCA_STAKED() external view returns (uint256);

    function TOTAL_MOCA_PENDING_UNSTAKE() external view returns (uint256);

    function UNSTAKE_DELAY() external view returns (uint256);

    function MAX_STAKE_AMOUNT() external view returns (uint256);

    function isFrozen() external view returns (uint256);

    function issuers(address issuer) external view returns (uint256);

    function pendingUnstakedMoca(address issuer, uint256 timestamp) external view returns (uint256);
}
