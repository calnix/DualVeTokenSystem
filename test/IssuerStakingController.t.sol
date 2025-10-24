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

        // check admin
        assertTrue(accessController.isIssuerStakingControllerAdmin(issuerStakingControllerAdmin), "issuerStakingControllerAdmin not set correctly");
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

    uint256 public firstClaimableTimestamp;

    function setUp() public virtual override {
        super.setUp();

        // initiate unstake [partial unstake]
        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(ISSUER1_MOCA / 4);

        firstClaimableTimestamp = block.timestamp + issuerStakingController.UNSTAKE_DELAY();
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

    // state transition: admin updates unstake delay, including before/after state and event emission check
    function testCan_UpdateUnstakeDelay() public {
        // --- Before ---
        uint256 oldUnstakeDelay = issuerStakingController.UNSTAKE_DELAY();
        assertTrue(oldUnstakeDelay != 1 days, "Test precondition, unstake delay should not already be 1 day");

        // --- Expect event emitted ---
        vm.expectEmit(false, false, false, true);
        emit Events.UnstakeDelayUpdated(oldUnstakeDelay, 1 days);

        // --- Update unstake delay ---
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setUnstakeDelay(1 days);

        // --- After: check contract state ---
        assertEq(issuerStakingController.UNSTAKE_DELAY(), 1 days, "unstake delay not set correctly after updateUnstakeDelay");
    }

}

abstract contract StateT1_UpdateUnstakeDelay is StateT1_InitiateUnstake_Partial {

    function setUp() public virtual override {
        super.setUp();

        // update unstake delay
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setUnstakeDelay(1 days);
    }
}

contract StateT1_UpdateUnstakeDelay_Test is StateT1_UpdateUnstakeDelay {

    function testVerifyState_UnstakeDelayUpdated() public {
        assertEq(issuerStakingController.UNSTAKE_DELAY(), 1 days, "unstake delay not set correctly");
    }

    function testRevert_UpdateUnstakeDelay_ZeroDelay() public {
        vm.prank(issuerStakingControllerAdmin);
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        issuerStakingController.setUnstakeDelay(0);
    }

    function testRevert_UserCannotUpdateUnstakeDelay() public {
        vm.prank(issuer1Asset);
        vm.expectRevert(Errors.OnlyCallableByIssuerStakingControllerAdmin.selector);
        issuerStakingController.setUnstakeDelay(1 days);
    }

    // state transition: issuer1 initiates unstake the remaining balance
    function testCan_InitiateUnstake_FullUnstake() public {

        // calculate claimable timestamp
        uint256 claimableTimestamp = block.timestamp + issuerStakingController.UNSTAKE_DELAY();

        uint256 claimableAmount = ISSUER1_MOCA / 4;

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
        emit Events.UnstakeInitiated(issuer1Asset, claimableAmount, claimableTimestamp);

        // --- Initiate unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(claimableAmount);

        // --- After: check contract & balance states ---

        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca staked not zero after initiateUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked not zero after initiateUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), totalMocaPendingUnstakeBefore + claimableAmount, "TOTAL_MOCA_PENDING_UNSTAKE not set after initiateUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, claimableTimestamp), pendingUnstakedMocaBefore + claimableAmount, "pendingUnstakedMoca not set after initiateUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), contractMocaBalanceBefore, "contract moca balance not correct after initiateUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), issuerMocaBalanceBefore, "issuer moca balance not correct after initiateUnstake");
    }
}

abstract contract StateT2_InitiateUnstake_Full is StateT1_UpdateUnstakeDelay {

    uint256 public secondClaimableTimestamp;

    function setUp() public virtual override {
        super.setUp();

        vm.warp(2);
        
        // initiate unstake [full unstaked]
        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(ISSUER1_MOCA / 4);

        secondClaimableTimestamp = block.timestamp + issuerStakingController.UNSTAKE_DELAY();
    }
}


contract StateT2_InitiateUnstake_Full_Test is StateT2_InitiateUnstake_Full {

    function testVerifyState_Issuer1FullUnstaked() public {

        // Check contract state
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca staked not zero after full unstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked not zero after full unstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), ISSUER1_MOCA/2, "pending unstake not set correctly after full unstake");

        // Check token balance
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), ISSUER1_MOCA/2, "contract moca balance not set correctly after full unstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), ISSUER1_MOCA/2, "issuer moca balance not set correctly after full unstake");

        // Check pending unstake
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, firstClaimableTimestamp), ISSUER1_MOCA/4, "pending unstake for 1st claim not set correctly");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp), ISSUER1_MOCA/4, "pending unstake for 2nd claim not set correctly");
    }

    function testRevert_ClaimUnstake_InvalidArray() public {
        uint256[] memory claimableTimestamps = new uint256[](0);
        vm.expectRevert(Errors.InvalidArray.selector);
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);
    }

    function testRevert_ClaimUnstake_InvalidTimestamp() public {
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = block.timestamp + 1;

        vm.expectRevert(Errors.InvalidTimestamp.selector);

        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);
    }

    function testRevert_ClaimUnstake_NothingToClaim() public {

        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = block.timestamp - 1;

        vm.expectRevert(Errors.NothingToClaim.selector);
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);
    }

    // state transition: issuer1 can claim unstake
    function testCan_ClaimFullUnstaked() public {
        // note: firstClaimableTimestamp  > secondClaimableTimestamp | admin reduced unstake delay
        vm.warp(firstClaimableTimestamp);

        uint256 claimableAmount = ISSUER1_MOCA/2;

        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Token balances before
        uint256 contractMocaBalanceBefore = mockMoca.balanceOf(address(issuerStakingController));
        uint256 issuerMocaBalanceBefore = mockMoca.balanceOf(issuer1Asset);

        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, firstClaimableTimestamp), ISSUER1_MOCA/4, "pendingUnstakedMoca should be set correctly after initiateUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp), ISSUER1_MOCA/4, "pendingUnstakedMoca should be set correctly after initiateUnstake");

        // --- Expect event emitted ---
        vm.expectEmit(true, true, true, true);
        emit Events.UnstakeClaimed(issuer1Asset, claimableAmount);

        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](2);
        claimableTimestamps[0] = firstClaimableTimestamp;
        claimableTimestamps[1] = secondClaimableTimestamp;

        // --- Claim unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);

        // --- After: check contract & balance states ---
        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca staked not zero after claimUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked should not change after claimUnstake");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "pending unstake should be zero after claimUnstake");
        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, firstClaimableTimestamp), 0, "pendingUnstakedMoca should be zero after claimUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp), 0, "pendingUnstakedMoca should be zero after claimUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), 0, "contract moca balance not correct after claimUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), ISSUER1_MOCA, "issuer moca balance not correct after claimUnstake");
    }
}

// note: since admin reduced unstake delay, we need to warp to second claimable timestamp to test available for first claim
// firstClaimableTimestamp: 604,801 > secondClaimableTimestamp: 8,6402
abstract contract State_FirstAvailableUnstakeClaim is StateT2_InitiateUnstake_Full {
    function setUp() public virtual override {
        super.setUp();

        vm.warp(secondClaimableTimestamp);
    }
}

contract State_FirstAvailableUnstakeClaim_Test is State_FirstAvailableUnstakeClaim {

    function testRevert_CannotClaimBothUnstaked() public {
        console2.log("block.timestamp", block.timestamp);
        console2.log("firstClaimableTimestamp", firstClaimableTimestamp);
        console2.log("secondClaimableTimestamp", secondClaimableTimestamp);
        assertTrue(block.timestamp == secondClaimableTimestamp, "Test precondition, block.timestamp should be before 2nd claimable timestamp");


        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](2);
        claimableTimestamps[0] = firstClaimableTimestamp;
        claimableTimestamps[1] = secondClaimableTimestamp;

        // --- Claim unstake ---
        vm.prank(issuer1Asset);
        vm.expectRevert(Errors.InvalidTimestamp.selector);
        issuerStakingController.claimUnstake(claimableTimestamps);
    }

    // note: secondClaimableTimestamp 
    function test_CanClaimFirstAvailableUnstake() public {
        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Token balances before
        uint256 contractMocaBalanceBefore = mockMoca.balanceOf(address(issuerStakingController));
        uint256 issuerMocaBalanceBefore = mockMoca.balanceOf(issuer1Asset);

        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp), ISSUER1_MOCA/4);

        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = block.timestamp;

        // --- Claim unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);

        // --- After: check contract & balance states ---

        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca must be 0");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked must be 0");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), ISSUER1_MOCA/4, "pending unstake must be decremented after claimUnstake");
        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp), 0, "pendingUnstakedMoca must be deleted after claimUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), ISSUER1_MOCA/4, "contract moca balance not correct after claimUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), ISSUER1_MOCA/4 * 3, "issuer moca balance not correct after claimUnstake");
    }
}

abstract contract State_SecondAvailableUnstakeClaim is State_FirstAvailableUnstakeClaim {
    function setUp() public virtual override {
        super.setUp();

        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = secondClaimableTimestamp;
        
        // claim first unstake      
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);

        // warp to first claimable timestamp
        vm.warp(firstClaimableTimestamp);
    }
}

contract State_SecondAvailableUnstakeClaim_Test is State_SecondAvailableUnstakeClaim {

    // note: firstClaimableTimestamp
    function test_CanClaimSecondAvailableUnstake() public {
        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp), ISSUER1_MOCA/4);

        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = block.timestamp;

        // --- Claim unstake ---
        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);

        // --- After: check contract & balance states ---
        // Contract state after
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's moca must be 0");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "total moca staked must be 0");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "pending unstake must be 0");
        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp), 0, "pendingUnstakedMoca must be deleted after claimUnstake");

        // Token balances after
        assertEq(mockMoca.balanceOf(address(issuerStakingController)), 0, "contract moca balance not correct after claimUnstake");
        assertEq(mockMoca.balanceOf(issuer1Asset), ISSUER1_MOCA, "issuer moca balance not correct after claimUnstake");        
    }


    // state transition: setMaxStakeAmount
    function testCan_SetMaxStakeAmount() public {
        // --- Before ---
        uint256 oldMaxStakeAmount = issuerStakingController.MAX_STAKE_AMOUNT();
        assertTrue(oldMaxStakeAmount != 10 ether, "Test precondition, max stake amount should not already be 1000 ether");

        // --- Expect event emitted ---
        vm.expectEmit(false, false, false, true);
        emit Events.MaxStakeAmountUpdated(oldMaxStakeAmount, 10 ether);

        // --- Set max stake amount ---
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMaxStakeAmount(10 ether);

        // --- After: check contract state ---
        assertEq(issuerStakingController.MAX_STAKE_AMOUNT(), 10 ether, "max stake amount not set correctly after setMaxStakeAmount");
    }
}

abstract contract StateT1_SetMaxStakeAmount_ReducedMaxStakeAmount is StateT1_InitiateUnstake_Partial {
    function setUp() public virtual override {
        super.setUp();

        // set max stake amount
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMaxStakeAmount(10 ether);
    }
}


