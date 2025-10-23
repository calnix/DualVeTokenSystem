// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

import "./utils/TestingHarness.sol";


abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}


contract StateT0_Deploy_Test is StateT0_Deploy {

    function test_Deploy() public {
        // Check IssuerStakingController addressBook is set correctly
        assertEq(address(issuerStakingController.addressBook()), address(addressBook), "addressBook not set correctly");

        // Check unstake delay
        assertEq(issuerStakingController.UNSTAKE_DELAY(), 7 days, "unstake delay not set correctly");

        // Check max stake amount
        assertEq(issuerStakingController.MAX_STAKE_AMOUNT(), 1000 ether, "max stake amount not set correctly");
    }

    function testRevert_Constructor_InvalidAddressBook() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(address(0), 7 days, 1000 ether);
    }

    function testRevert_Constructor_InvalidUnstakeDelay() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new IssuerStakingController(address(addressBook), 0, 1000 ether);
    }

    function testRevert_Constructor_InvalidMaxStakeAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        new IssuerStakingController(address(addressBook), 7 days, 0);
    }

    // state transition: issuer can stake moca
    function testCan_StakeMoca() public {

        // fund issuer with Moca
        vm.startPrank(issuer1Asset);
            mockMoca.mint(issuer1Asset, 100 ether);
            mockMoca.approve(address(issuerStakingController), 100 ether);
        vm.stopPrank();


        // Check event
        vm.expectEmit(true, true, true, true);
        emit Events.Staked(issuer1Asset, 50 ether);

        // Check issuer can stake moca
        vm.prank(issuer1Asset);
        issuerStakingController.stakeMoca(50 ether);

        // Check contract state
        assertEq(issuerStakingController.issuers(issuer1Asset), 50 ether, "issuer's moca staked not set correctly");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 50 ether, "total moca staked not set correctly");

        // Check token balance
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), 50 ether, "contract moca balance not set correctly");
        assertEq(mockMoca.balanceOf(issuer1Asset), 50 ether, "issuer moca balance not set correctly");

    }
}

abstract contract StateT1_Issuer1Staked is StateT0_Deploy {

    uint256 public constant ISSUER1_MOCA = 100 ether;

    function setUp() public virtual override {
        super.setUp();

        // fund issuer with Moca
        vm.startPrank(issuer1Asset);
            mockMoca.mint(issuer1Asset, ISSUER1_MOCA);
            mockMoca.approve(address(issuerStakingController), ISSUER1_MOCA);
            issuerStakingController.stakeMoca(ISSUER1_MOCA / 2);
        vm.stopPrank();
    }
}

contract StateT1_Issuer1Staked_Test is StateT1_Issuer1Staked {

    function testVerifyState_Issuer1Staked50Moca() public {
        // Check contract state
        assertEq(issuerStakingController.issuers(issuer1Asset), ISSUER1_MOCA / 2, "issuer's moca staked not set correctly");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), ISSUER1_MOCA / 2, "total moca staked not set correctly");

        // Check token balance
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), ISSUER1_MOCA / 2, "contract moca balance not set correctly");
        assertEq(mockMoca.balanceOf(issuer1Asset), ISSUER1_MOCA / 2, "issuer moca balance not set correctly");
    }

    function testRevert_StakeMoca_InvalidAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        issuerStakingController.stakeMoca(0);
    }

    //note: foundry bug, when using expectRevert, the call doesn't revert.
    // but when removing vm.expectRevert, the call reverts as expected.
    // so we use try/catch to verify the call reverted.
    function testRevert_StakeMoca_ExceedsMaxStakeAmount() public {
            
        bool success;

        try issuerStakingController.stakeMoca(issuerStakingController.MAX_STAKE_AMOUNT() + 10000 ether) {
            // If we get here, the call succeeded (unexpected)
            success = true;
        } catch {
            // If we get here, the call reverted (expected)
            success = false;
        }

        assertFalse(success, "Call should revert");
    }

    // state transition: issuer can initiate unstake
    function testCan_InitiateUnstake() public {
        // calculate claimable timestamp
        uint256 claimableTimestamp = block.timestamp + issuerStakingController.UNSTAKE_DELAY();

        // --- Before: check contract & balance states ---

        // Contract state before
        assertEq(issuerStakingController.issuers(issuer1Asset), 50 ether, "issuer's moca staked not set correctly before");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 50 ether, "total moca staked not set correctly before");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "pending unstake should be zero before");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp), 0, "pendingUnstakedMoca should be zero before");

        // Token balances before
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), 50 ether, "contract moca balance not set correctly before");
        assertEq(mockMoca.balanceOf(issuer1Asset), 50 ether, "issuer moca balance not set correctly before");

        // --- Expect event emitted ---
        vm.expectEmit(true, true, true, true);
        emit Events.UnstakeInitiated(issuer1Asset, 50 ether, claimableTimestamp);

        // --- Initiate unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(50 ether);

        // --- After: check contract & balance states ---

        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca staked not zero after initiateUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked not zero after initiateUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 50 ether, "pending unstake not set after initiateUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp), 50 ether, "pendingUnstakedMoca not set after initiateUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), 50 ether, "contract moca balance not correct after initiateUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), 50 ether, "issuer moca balance not correct after initiateUnstake");
    }
}

abstract contract StateT1_InitiateUnstake_Partial is StateT1_Issuer1Staked {

    function setUp() public virtual override {
        super.setUp();

        // initiate unstake [partial unstake]
        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(ISSUER1_MOCA / 4);
    }
}

contract StateT1_InitiateUnstake_Partial_Test is StateT1_InitiateUnstake_Partial {

    function testVerifyState_Issuer1InitiateUnstakePartial() public {
        // Check contract state
        assertEq(issuerStakingController.issuers(issuer1Asset), ISSUER1_MOCA / 4, "issuer's moca staked not set correctly");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), ISSUER1_MOCA / 4, "total moca staked not set correctly");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), ISSUER1_MOCA / 4, "pending unstake not set correctly");
    }

    function testRevert_InitiateUnstake_ZeroAmount() public {
        vm.prank(issuer1Asset);
        vm.expectRevert(Errors.InvalidAmount.selector);
        issuerStakingController.initiateUnstake(0);
    }

    function testRevert_InitiateUnstake_ExceedsBalance() public {
        vm.prank(issuer1Asset);
        vm.expectRevert(Errors.InsufficientBalance.selector);
        issuerStakingController.initiateUnstake(ISSUER1_MOCA);
    }


    // state transition: issuer1 initiates unstake [partial unstake]
    function testCan_InitiateUnstake_FullUnstake() public {

        // calculate claimable timestamp
        uint256 claimableTimestamp = block.timestamp + issuerStakingController.UNSTAKE_DELAY();

        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Token balances before
        uint256 contractMocaBalanceBefore = mockMoca.balanceOf(address(issuerStakingController));
        uint256 issuerMocaBalanceBefore = mockMoca.balanceOf(issuer1Asset);

        // --- Expect event emitted ---
        vm.expectEmit(true, true, true, true);
        emit Events.UnstakeInitiated(issuer1Asset, ISSUER1_MOCA / 4, claimableTimestamp);

        // --- Initiate unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(ISSUER1_MOCA / 4);

        // --- After: check contract & balance states ---

        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca staked not zero after initiateUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked not zero after initiateUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), pendingUnstakedMocaBefore + ISSUER1_MOCA / 4, "pending unstake not set after initiateUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp), totalMocaPendingUnstakeBefore + ISSUER1_MOCA / 4, "pendingUnstakedMoca not set after initiateUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), contractMocaBalanceBefore, "contract moca balance not correct after initiateUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), issuerMocaBalanceBefore, "issuer moca balance not correct after initiateUnstake");
    }

}

/**
    // state transition: issuer can claim unstake
    function testCan_ClaimUnstake() public {
        uint256 claimableTimestamp = block.timestamp + issuerStakingController.UNSTAKE_DELAY();
        uint256 claimableAmount = ISSUER1_MOCA / 4;

        vm.warp(claimableTimestamp);

        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Token balances before
        uint256 contractMocaBalanceBefore = mockMoca.balanceOf(address(issuerStakingController));
        uint256 issuerMocaBalanceBefore = mockMoca.balanceOf(issuer1Asset);

        // --- Expect event emitted ---
        vm.expectEmit(true, true, true, true);
        emit Events.UnstakeClaimed(issuer1Asset, claimableAmount);

        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = claimableTimestamp;

        // --- Claim unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake([claimableTimestamp]);

        // --- After: check contract & balance states ---
        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), issuerMocaStakedBefore - claimableAmount, "issuer's moca staked not set correctly after claimUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), totalMocaStakedBefore, "total moca staked should not change after claimUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "pending unstake should be zero after claimUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp), pendingUnstakedMocaBefore - claimableAmount, "pendingUnstakedMoca should be zero after claimUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), contractMocaBalanceBefore + claimableAmount, "contract moca balance not correct after claimUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), issuerMocaBalanceBefore + claimableAmount, "issuer moca balance not correct after claimUnstake");
    }

 */