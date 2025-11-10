// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "./IssuerStakingController.t.sol";

abstract contract StateT2_TransferGasLimitChanged is StateT2_InitiateUnstake_Full {

    function setUp() public virtual override {
        super.setUp();

        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }
}

contract StateT2_TransferGasLimitChanged_Test is StateT2_TransferGasLimitChanged {


    function testRevert_SetTransferGasLimit_NotIssuerStakingControllerAdmin() public {
        vm.expectRevert(Errors.OnlyCallableByIssuerStakingControllerAdmin.selector);
        vm.prank(issuer1Asset);
        issuerStakingController.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }

    function testRevert_MustBeMoreThan2300() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMocaTransferGasLimit(2300 - 1);
    }


    function testCan_ClaimFullUnstaked_WrapIfNativeTransferFails_OnNewLimit() public {
        // Deploy a contract with expensive receive function that exceeds MOCA_TRANSFER_GAS_LIMIT
        // We'll use vm.etch to replace issuer1Asset with this contract's code
        
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;
        
        // Replace issuer1Asset with contract code that has expensive receive
        vm.etch(issuer1Asset, gasGuzzlerCode);

        // Ensure contract is at correct claimable state
        vm.warp(firstClaimableTimestamp);

        uint256 claimableAmount = ISSUER1_MOCA/2;

        // Balances before
        assertEq(mockWMoca.balanceOf(issuer1Asset), 0, "Issuer should have no wMoca before");
        uint256 issuerNativeBefore = address(issuer1Asset).balance;

        uint256 contractNativeBefore = address(issuerStakingController).balance;
        uint256 contractWMocaBefore = mockWMoca.balanceOf(issuer1Asset);

        // Expect event unchanged
        vm.expectEmit(true, true, true, true);
        emit Events.UnstakeClaimed(issuer1Asset, claimableAmount);

        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](2);
        claimableTimestamps[0] = firstClaimableTimestamp;
        claimableTimestamps[1] = secondClaimableTimestamp;

        // -- Claim: should fallback to sending wMoca --
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);

        // After: wMoca was given instead of native moca
        assertEq(mockWMoca.balanceOf(issuer1Asset), contractWMocaBefore + claimableAmount, "issuer should get WMoca if native transfer fails");
        assertEq(address(issuer1Asset).balance, issuerNativeBefore, "issuer native moca balance unchanged");

        // Core state
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca staked not zero after claimUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked should not change after claimUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "pending unstake should be zero after claimUnstake");
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "totalPendingUnstakedMoca should be zero after claimUnstake");

        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, firstClaimableTimestamp), 0, "pendingUnstakedMoca should be zero after claimUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp), 0, "pendingUnstakedMoca should be zero after claimUnstake");
    }

}