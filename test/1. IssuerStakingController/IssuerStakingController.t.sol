// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

import "../utils/TestingHarness.sol";


abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}


contract StateT0_Deploy_Test is StateT0_Deploy {

    function test_Deploy() public {
        // Check correct deployment parameters
        assertEq(issuerStakingController.UNSTAKE_DELAY(), 7 days, "UNSTAKE_DELAY not set correctly");
        assertEq(issuerStakingController.MAX_SINGLE_STAKE_AMOUNT(), 1000 ether, "MAX_SINGLE_STAKE_AMOUNT not set correctly");
        
        assertEq(address(issuerStakingController.WMOCA()), address(mockWMoca), "WMOCA address not set correctly");

        assertEq(issuerStakingController.MOCA_TRANSFER_GAS_LIMIT(), MOCA_TRANSFER_GAS_LIMIT, "MOCA_TRANSFER_GAS_LIMIT not set correctly");

        // Check role admin assignments
        assertTrue(issuerStakingController.hasRole(issuerStakingController.ISSUER_STAKING_CONTROLLER_ADMIN_ROLE(), issuerStakingControllerAdmin), "issuerStakingControllerAdmin should have admin role");
        assertTrue(issuerStakingController.hasRole(issuerStakingController.EMERGENCY_EXIT_HANDLER_ROLE(), emergencyExitHandler), "emergencyExitHandler should have emergency exit handler role");
        assertTrue(issuerStakingController.hasRole(issuerStakingController.MONITOR_ADMIN_ROLE(), monitorAdmin), "monitorAdmin should have monitor admin role");
        assertTrue(issuerStakingController.hasRole(issuerStakingController.MONITOR_ROLE(), monitor), "monitor should have monitor role");
    }

    function testRevert_Constructor_InvalidUnstakeDelay() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, monitor, emergencyExitHandler, 0, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidMaxStakeAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, monitor, emergencyExitHandler, 7 days, 0, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidWMoca() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, monitor, emergencyExitHandler, 7 days, 1000 ether, address(0), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidMocaTransferGasLimit() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, monitor, emergencyExitHandler, 7 days, 1000 ether, address(mockWMoca), 0);
    }

    function testRevert_Constructor_InvalidGlobalAdmin() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(address(0), issuerStakingControllerAdmin, monitorAdmin, monitor, emergencyExitHandler, 7 days, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidIssuerStakingControllerAdmin() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(globalAdmin, address(0), monitorAdmin, monitor, emergencyExitHandler, 7 days, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidMonitorAdmin() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, address(0), monitor, emergencyExitHandler, 7 days, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidMonitorBot() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, address(0), emergencyExitHandler, 7 days, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }

    function testRevert_Constructor_InvalidEmergencyExitHandler() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new IssuerStakingController(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, monitor, address(0), 7 days, 1000 ether, address(mockWMoca), MOCA_TRANSFER_GAS_LIMIT);
    }


    // state transition: issuer can stake moca
    function testCan_StakeMoca() public {

        // fund issuer with Moca
        vm.deal(issuer1Asset, 100 ether);
        assertEq(address(issuer1Asset).balance, 100 ether, "issuer must hold moca tokens");

        // Check event
        vm.expectEmit(true, true, true, true);
        emit Events.Staked(issuer1Asset, 50 ether);

        // Check issuer can stake moca
        vm.prank(issuer1Asset);
        issuerStakingController.stakeMoca{value: 50 ether}();

        // Check contract state
        assertEq(issuerStakingController.issuers(issuer1Asset), 50 ether, "issuer's moca staked not set correctly");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 50 ether, "total moca staked not set correctly");

        // Check Native token balance
        assertEq(address(issuerStakingController).balance, 50 ether, "contract moca balance not set correctly");
        assertEq(address(issuer1Asset).balance, 50 ether, "issuer moca balance not set correctly");

    }
}


abstract contract StateT1_Issuer1Staked is StateT0_Deploy {

    uint256 public constant ISSUER1_MOCA = 100 ether;

    function setUp() public virtual override {
        super.setUp();

        // fund issuer with Moca
        vm.deal(issuer1Asset, 100 ether);

        vm.startPrank(issuer1Asset);
            issuerStakingController.stakeMoca{value: ISSUER1_MOCA / 2}();
        vm.stopPrank();
    }
}

contract StateT1_Issuer1Staked_Test is StateT1_Issuer1Staked {

    function testVerifyState_Issuer1Staked50Moca() public {
        // Check contract state
        assertEq(issuerStakingController.issuers(issuer1Asset), ISSUER1_MOCA / 2, "issuer's moca staked not set correctly");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), ISSUER1_MOCA / 2, "total moca staked not set correctly");

        // Check token balance
        assertEq(address(issuerStakingController).balance, ISSUER1_MOCA / 2, "contract moca balance not set correctly");
        assertEq(address(issuer1Asset).balance, ISSUER1_MOCA / 2, "issuer moca balance not set correctly");
    }

    function testRevert_StakeMoca_InvalidAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        issuerStakingController.stakeMoca{value: 0}();
    }

    //note: foundry bug, when using expectRevert, the call doesn't revert.
    // but when removing vm.expectRevert, the call reverts as expected.
    // so we use try/catch to verify the call reverted.
    function testRevert_StakeMoca_ExceedsMaxSingleStakeAmount() public {
            
        bool success;

        try issuerStakingController.stakeMoca{value: issuerStakingController.MAX_SINGLE_STAKE_AMOUNT() + 10000 ether}() {
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
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "totalPendingUnstakedMoca should be zero before");

        // Native Moca balances before
        assertEq(address(issuerStakingController).balance, 50 ether, "contract moca balance not set correctly before");
        assertEq(address(issuer1Asset).balance, 50 ether, "issuer moca balance not set correctly before");

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
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 50 ether, "totalPendingUnstakedMoca not set after initiateUnstake");

        // Native Moca balances after
        assertEq(address(issuerStakingController).balance, 50 ether, "contract moca balance not correct after initiateUnstake");
        assertEq(address(issuer1Asset).balance, 50 ether, "issuer moca balance not correct after initiateUnstake");
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

    function testRevert_UpdateUnstakeDelay_Exceeds90Days() public {
        vm.prank(issuerStakingControllerAdmin);
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        issuerStakingController.setUnstakeDelay(91 days);
    }

    function testRevert_UserCannotUpdateUnstakeDelay() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer1Asset, issuerStakingController.ISSUER_STAKING_CONTROLLER_ADMIN_ROLE()));
        vm.prank(issuer1Asset);
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
        uint256 totalPendingUnstakedMocaBefore = issuerStakingController.totalPendingUnstakedMoca(issuer1Asset);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Native token balances before
        uint256 contractMocaBalanceBefore = address(issuerStakingController).balance;
        uint256 issuerMocaBalanceBefore = address(issuer1Asset).balance;

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
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), totalPendingUnstakedMocaBefore + claimableAmount, "totalPendingUnstakedMoca not set after initiateUnstake");

        // Native Moca balances after
        assertEq(address(issuerStakingController).balance, contractMocaBalanceBefore, "contract moca balance not correct after initiateUnstake");
        assertEq(address(issuer1Asset).balance, issuerMocaBalanceBefore, "issuer moca balance not correct after initiateUnstake");
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

        // Check Native Moca balances
        assertEq(address(issuerStakingController).balance, ISSUER1_MOCA/2, "contract moca balance not set correctly after full unstake");
        assertEq(address(issuer1Asset).balance, ISSUER1_MOCA/2, "issuer moca balance not set correctly after full unstake");

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
    function testCan_ClaimFullUnstaked_NativeTransferSuccess() public {
        // note: firstClaimableTimestamp  > secondClaimableTimestamp | admin reduced unstake delay
        vm.warp(firstClaimableTimestamp);

        uint256 claimableAmount = ISSUER1_MOCA/2;

        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp);
        uint256 totalPendingUnstakedMocaBefore = issuerStakingController.totalPendingUnstakedMoca(issuer1Asset);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Native token balances before
        uint256 contractMocaBalanceBefore = address(issuerStakingController).balance;
        uint256 issuerMocaBalanceBefore = address(issuer1Asset).balance;

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
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "totalPendingUnstakedMoca should be zero after claimUnstake");

        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, firstClaimableTimestamp), 0, "pendingUnstakedMoca should be zero after claimUnstake");
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, secondClaimableTimestamp), 0, "pendingUnstakedMoca should be zero after claimUnstake");

        // Native token balances after
        assertEq(address(issuerStakingController).balance, 0, "contract native moca balance not correct after claimUnstake");
        assertEq(address(issuer1Asset).balance, ISSUER1_MOCA, "issuer native moca balance not correct after claimUnstake");
    }

    function testCan_ClaimFullUnstaked_WrapIfNativeTransferFails() public {
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

    // state transition for TransferGasLimitChanged.t.sol
    function testCan_SetTransferGasLimit_IssuerStakingControllerAdmin() public {
        // Before: check current value
        uint256 gasLimitBefore = issuerStakingController.MOCA_TRANSFER_GAS_LIMIT();
        assertEq(gasLimitBefore, MOCA_TRANSFER_GAS_LIMIT, "initial MOCA_TRANSFER_GAS_LIMIT is not correct");

        // Expect event emission
        vm.expectEmit(true, true, true, true);
        emit Events.MocaTransferGasLimitUpdated(gasLimitBefore, MOCA_TRANSFER_GAS_LIMIT * 2);

        // Action: change gas limit
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);

        // After: check new value
        assertEq(issuerStakingController.MOCA_TRANSFER_GAS_LIMIT(), MOCA_TRANSFER_GAS_LIMIT * 2, "MOCA_TRANSFER_GAS_LIMIT not set correctly");
    }
}



// note: since admin reduced unstake delay, we need to warp to second claimable timestamp to test available for first claim
// firstClaimableTimestamp: 604,801 > secondClaimableTimestamp: 8,6402
abstract contract StateT86402_FirstAvailableUnstakeClaim is StateT2_InitiateUnstake_Full {
    function setUp() public virtual override {
        super.setUp();

        vm.warp(secondClaimableTimestamp);
    }
}

contract StateT86402_FirstAvailableUnstakeClaim_Test is StateT86402_FirstAvailableUnstakeClaim {

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
        uint256 totalPendingUnstakedMocaBefore = issuerStakingController.totalPendingUnstakedMoca(issuer1Asset);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Native token balances before
        uint256 contractMocaBalanceBefore = address(issuerStakingController).balance;
        uint256 issuerMocaBalanceBefore = address(issuer1Asset).balance;

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
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), ISSUER1_MOCA/4, "totalPendingUnstakedMoca must be decremented after claimUnstake");
        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp), 0, "pendingUnstakedMoca must be deleted after claimUnstake");

        // Native token balances after
        assertEq(address(issuerStakingController).balance, ISSUER1_MOCA/4, "contract moca balance not correct after claimUnstake");
        assertEq(address(issuer1Asset).balance, ISSUER1_MOCA/4 * 3, "issuer moca balance not correct after claimUnstake");
    }
}


abstract contract StateT604801_SecondAvailableUnstakeClaim is StateT86402_FirstAvailableUnstakeClaim {
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

contract StateT604801_SecondAvailableUnstakeClaim_Test is StateT604801_SecondAvailableUnstakeClaim {

    // note: firstClaimableTimestamp
    function test_CanClaimSecondAvailableUnstake() public {
        // --- Before: check contract & balance states ---
        // Contract state before
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 pendingUnstakedMocaBefore = issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp);
        uint256 totalPendingUnstakedMocaBefore = issuerStakingController.totalPendingUnstakedMoca(issuer1Asset);
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
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "totalPendingUnstakedMoca must be 0");
        // pending mapping
        assertEq(issuerStakingController.pendingUnstakedMoca(issuer1Asset, block.timestamp), 0, "pendingUnstakedMoca must be deleted after claimUnstake");

        // Token balances after
        assertEq(address(issuerStakingController).balance, 0, "contract moca balance not correct after claimUnstake");
        assertEq(address(issuer1Asset).balance, ISSUER1_MOCA, "issuer moca balance not correct after claimUnstake");        
    }


    // state transition: setMaxSingleStakeAmount
    function testCan_SetMaxSingleStakeAmount() public {
        // --- Before ---
        uint256 oldMaxSingleStakeAmount = issuerStakingController.MAX_SINGLE_STAKE_AMOUNT();
        assertTrue(oldMaxSingleStakeAmount != 10 ether, "Test precondition, max stake amount should not already be 1000 ether");

        // --- Expect event emitted ---
        vm.expectEmit(false, false, false, true);
        emit Events.MaxSingleStakeAmountUpdated(oldMaxSingleStakeAmount, 10 ether);

        // --- Set max single stake amount ---
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMaxSingleStakeAmount(10 ether);

        // --- After: check contract state ---
        assertEq(issuerStakingController.MAX_SINGLE_STAKE_AMOUNT(), 10 ether, "max stake amount not set correctly after setMaxSingleStakeAmount");
    }
}

abstract contract StateT604801_SetMaxSingleStakeAmount_ReducedMaxSingleStakeAmount is StateT604801_SecondAvailableUnstakeClaim {
    function setUp() public virtual override {
        super.setUp();

        
        // set max stake amount
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMaxSingleStakeAmount(10 ether);
    }
}

contract StateT604801_SetMaxSingleStakeAmount_ReducedMaxSingleStakeAmount_Test is StateT604801_SetMaxSingleStakeAmount_ReducedMaxSingleStakeAmount {
 
    function testVerifyState_ReducedMaxStakeAmount() public {
        assertEq(issuerStakingController.MAX_SINGLE_STAKE_AMOUNT(), 10 ether, "max single stake amount not set correctly after setMaxSingleStakeAmount");
    }

    function testRevert_SetMaxSingleStakeAmount_ZeroAmount() public {
        vm.prank(issuerStakingControllerAdmin);
        vm.expectRevert(Errors.InvalidAmount.selector);
        issuerStakingController.setMaxSingleStakeAmount(0);
    }

    function testRevert_UserCannotSetMaxSingleStakeAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer1Asset, issuerStakingController.ISSUER_STAKING_CONTROLLER_ADMIN_ROLE()));
        vm.prank(issuer1Asset);
        issuerStakingController.setMaxSingleStakeAmount(10 ether);
    }


    function testRevert_UserCannotExceedNewMaxSingleStakeAmount() public {
        vm.prank(issuer1Asset);
        vm.expectRevert(Errors.InvalidAmount.selector);
        issuerStakingController.stakeMoca{value: 11 ether}();
    }

    function test_UserStakesOnNewMaxStakeAmount() public {
        // --- Before: check contract & balance states ---
        uint256 issuerMocaStakedBefore = issuerStakingController.issuers(issuer1Asset);
        uint256 totalMocaStakedBefore = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalMocaPendingUnstakeBefore = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();

        // Token balances before
        uint256 contractMocaBalanceBefore = address(issuerStakingController).balance;
        uint256 issuerMocaBalanceBefore = address(issuer1Asset).balance;

        // --- Expect event emitted ---
        vm.expectEmit(false, false, false, true);
        emit Events.Staked(issuer1Asset, 10 ether);

        // --- User stakes on new max stake amount ---
        vm.prank(issuer1Asset);
        issuerStakingController.stakeMoca{value: 10 ether}();

        // --- After: check contract & balance states ---
        assertEq(issuerStakingController.issuers(issuer1Asset), issuerMocaStakedBefore + 10 ether, "issuer's moca staked not set correctly after stakeMoca");
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), totalMocaStakedBefore + 10 ether, "total moca staked not set correctly after stakeMoca");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), totalMocaPendingUnstakeBefore, "pending unstake not set correctly after stakeMoca");
        // Token balances after
        assertEq(address(issuerStakingController).balance, contractMocaBalanceBefore + 10 ether, "contract moca balance not set correctly after stakeMoca");
        assertEq(address(issuer1Asset).balance, issuerMocaBalanceBefore - 10 ether, "issuer moca balance not set correctly after stakeMoca");
    }


    // --- state transition: pause ---
    function testRevert_UserCannotCallPause() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer1Asset, issuerStakingController.MONITOR_ROLE()));
        vm.prank(issuer1Asset);
        issuerStakingController.pause();
    }

    function testRevert_IssuerStakingControllerAdmin_CannotPause() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuerStakingControllerAdmin, issuerStakingController.MONITOR_ROLE()));
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.pause();
    }

    function test_OnlyMonitor_CanPause() public {
        // --- Before: check contract state ---
        assertTrue(issuerStakingController.paused() == false, "Test precondition, contract should not be paused");

        // --- Pause contract ---
        vm.prank(monitor);
        issuerStakingController.pause();

        assertEq(issuerStakingController.paused(), true, "contract should be paused after pause");
    }
}

abstract contract StateT604801_Paused is StateT604801_SetMaxSingleStakeAmount_ReducedMaxSingleStakeAmount {
    function setUp() public virtual override {
        super.setUp();

        // pause
        vm.prank(monitor);
        issuerStakingController.pause();
    }
}

contract StateT604801_Paused_Test is StateT604801_Paused {
    
    function testVerifyState_Paused() public {
        assertTrue(issuerStakingController.paused() == true, "contract should be paused after pause");
    }

// --------- User functions that should revert when contract is paused ---------
    function testRevert_UserCannotStakeMoca_WhenPaused() public {
        vm.prank(issuer1Asset);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        issuerStakingController.stakeMoca{value: 10 ether}();
    }

    function testRevert_UserCannotInitiateUnstake_WhenPaused() public {
        vm.prank(issuer1Asset);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        issuerStakingController.initiateUnstake(10 ether);
    }
    
    function testRevert_UserCannotClaimUnstake_WhenPaused() public {
        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = block.timestamp;

        vm.prank(issuer1Asset);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        issuerStakingController.claimUnstake(claimableTimestamps);
    }

// --------- Admin functions that should revert when contract is paused ---------
    function testRevert_AdminCannotSetMaxSingleStakeAmount_WhenPaused() public {
        vm.prank(issuerStakingControllerAdmin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        issuerStakingController.setMaxSingleStakeAmount(10 ether);
    }
    
    
    function testRevert_AdminCannotSetUnstakeDelay_WhenPaused() public {
        vm.prank(issuerStakingControllerAdmin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        issuerStakingController.setUnstakeDelay(7 days);
    }

    function testRevert_AdminCannotSetTransferGasLimit_WhenPaused() public {
        vm.prank(issuerStakingControllerAdmin);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        issuerStakingController.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }

// --------- state transition: unpause ---------

    function testRevert_UserCannotCallUnpause_WhenPaused() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer1Asset, issuerStakingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(issuer1Asset);
        issuerStakingController.unpause();
    }

    function testRevert_MonitorCannotCallUnpause_WhenPaused() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, monitor, issuerStakingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(monitor);
        issuerStakingController.unpause();
    }

    function testRevert_IssuerStakingControllerAdminCannotCallUnpause_WhenPaused() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuerStakingControllerAdmin, issuerStakingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.unpause();
    }

    function test_OnlyGlobalAdmin_CanUnpause_WhenPaused() public {
        vm.prank(globalAdmin);
        issuerStakingController.unpause();

        assertEq(issuerStakingController.paused(), false, "contract should be unpaused after unpause");
    }
}

abstract contract StateT604801_Unpaused is StateT604801_Paused {
    function setUp() public virtual override {
        super.setUp();

        // unpause
        vm.prank(globalAdmin);
        issuerStakingController.unpause();
    }
}

contract StateT604801_Unpaused_Test is StateT604801_Unpaused {

    function testVerifyState_Unpaused() public {
        assertEq(issuerStakingController.paused(), false, "contract should be unpaused after unpause");
    }

    // --------- User functions that should not revert when contract is unpaused ---------
    function test_UserCanStakeMoca_WhenUnpaused() public {
        vm.prank(issuer1Asset);
        issuerStakingController.stakeMoca{value: 10 ether}();
    }


    function test_UserCannotInitiateUnstake_WhenUnpaused() public {
        vm.prank(issuer1Asset);
        issuerStakingController.stakeMoca{value: 1 ether}();

        vm.prank(issuer1Asset);
        issuerStakingController.initiateUnstake(1 ether);
    }

    function test_UserCanClaimUnstake_WhenUnpaused() public {
        // create array of claimable timestamps
        uint256[] memory claimableTimestamps = new uint256[](1);
        claimableTimestamps[0] = block.timestamp;

        vm.prank(issuer1Asset);
        issuerStakingController.claimUnstake(claimableTimestamps);
    }
    
    // --------- Admin functions that should not revert when contract is unpaused ---------
    function test_AdminCanSetMaxStakeAmount_WhenUnpaused() public {
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setMaxSingleStakeAmount(10 ether);
    }
    
    
    function test_AdminCanSetUnstakeDelay_WhenUnpaused() public {
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.setUnstakeDelay(7 days);
    }

    // --------- state transition: pause ---------
    function test_OnlyMonitor_CanPause() public {
        vm.prank(monitor);
        issuerStakingController.pause();

        assertEq(issuerStakingController.paused(), true, "contract should be paused after pause");
    }
}

abstract contract StateT604801_Paused_Again is StateT604801_Unpaused {
    function setUp() public virtual override {
        super.setUp();

        // pause
        vm.prank(monitor);
        issuerStakingController.pause();
    }
}

contract StateT604801_Paused_Again_Test is StateT604801_Paused_Again {

    function testVerifyState_Paused_Again() public {
        assertEq(issuerStakingController.paused(), true, "contract should be paused after pause");
    }

    // Test case: emergencyExit when not frozen
    function testRevert_EmergencyExit_NotFrozen() public {
        // First unpause and unfreeze
        vm.prank(globalAdmin);
        issuerStakingController.unpause();
        
        address[] memory issuerAddresses = new address[](1);
        issuerAddresses[0] = issuer1Asset;
        
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.NotFrozen.selector);
        issuerStakingController.emergencyExit(issuerAddresses);
    }

    // state transition: freeze
    function testRevert_UserCannotCallFreeze() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuer1Asset, issuerStakingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(issuer1Asset);
        issuerStakingController.freeze();
    }

    function testRevert_MonitorCannotCallFreeze() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, monitor, issuerStakingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(monitor);
        issuerStakingController.freeze();
    }

    function testRevert_IssuerStakingControllerAdminCannotCallFreeze() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, issuerStakingControllerAdmin, issuerStakingController.DEFAULT_ADMIN_ROLE()));
        vm.prank(issuerStakingControllerAdmin);
        issuerStakingController.freeze();
    }

    function test_OnlyGlobalAdmin_CanFreeze() public {
        vm.prank(globalAdmin);
        issuerStakingController.freeze();

        assertEq(issuerStakingController.paused(), true, "contract should be frozen after freeze");
        assertEq(issuerStakingController.isFrozen(), 1, "contract should be frozen after freeze");
    }
}

abstract contract StateT604801_Frozen is StateT604801_Paused_Again {
    function setUp() public virtual override {
        super.setUp();

        // freeze
        vm.prank(globalAdmin);
        issuerStakingController.freeze();
    }
}

contract StateT604801_Frozen_Test is StateT604801_Frozen {

    function testVerifyState_Frozen() public {
        assertEq(issuerStakingController.paused(), true, "contract should be frozen after freeze");
        assertEq(issuerStakingController.isFrozen(), 1, "contract should be frozen after freeze");
    }
   
    // Test case: emergencyExit with empty array
    function testRevert_EmergencyExit_EmptyArray() public {
        address[] memory emptyArray = new address[](0);
        
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.InvalidArray.selector);
        issuerStakingController.emergencyExit(emptyArray);
    }

    // Test case: random user cannot emergency exit for others
    function testRevert_UserCannotEmergencyExit_ForOthers() public {
        address randomUser = makeAddr("randomUser");
        
        address[] memory issuerAddresses = new address[](1);
        issuerAddresses[0] = issuer1Asset; // Issuer's address but called by random user
        
        vm.prank(randomUser);
        vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandlerOrIssuer.selector);
        issuerStakingController.emergencyExit(issuerAddresses);
    }

    // Test case: issuer cannot emergency exit for others in batch
    function testRevert_IssuerCannotEmergencyExit_ForOthersInBatch() public {
        address anotherIssuer = makeAddr("anotherIssuer");
        
        address[] memory issuerAddresses = new address[](2);
        issuerAddresses[0] = issuer1Asset; // Own address
        issuerAddresses[1] = anotherIssuer; // Another issuer's address
        
        vm.prank(issuer1Asset);
        vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandlerOrIssuer.selector);
        issuerStakingController.emergencyExit(issuerAddresses);
    }

    // Test case: emergencyExit with issuers having zero balances (should skip)
    function test_EmergencyExit_SkipsZeroBalanceIssuers() public {
        address zeroBalanceIssuer = makeAddr("zeroBalanceIssuer");
        
        address[] memory issuerAddresses = new address[](2);
        issuerAddresses[0] = issuer1Asset; // Has balance
        issuerAddresses[1] = zeroBalanceIssuer; // No balance
        
        uint256 totalStaked = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalPendingUnstake = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();
        uint256 totalMoca = totalStaked + totalPendingUnstake;
        
        vm.expectEmit(true, true, false, true, address(issuerStakingController));
        emit Events.EmergencyExit(issuerAddresses, totalMoca);
        
        vm.prank(emergencyExitHandler);
        issuerStakingController.emergencyExit(issuerAddresses);
        
        // Verify only issuer1Asset was processed
        assertEq(issuerStakingController.issuers(issuer1Asset), 0);
        assertEq(issuerStakingController.issuers(zeroBalanceIssuer), 0);
    }

    function test_EmergencyExitHandler_CanEmergencyExit_WhenFrozen() public {
        // Setup before state for balances and contract variables
        uint256 totalStaked = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalPendingUnstake = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();
        uint256 totalMoca = totalStaked + totalPendingUnstake;

        assertGt(totalMoca, 0, "There should be Moca to transfer");
        uint256 contractBalanceBefore = address(issuerStakingController).balance;
        assertEq(contractBalanceBefore, totalMoca, "contract must hold moca tokens");

        uint256 issuerBalanceBefore = address(issuer1Asset).balance;
        assertGt(issuerBalanceBefore, 0, "issuer must hold moca tokens");

        // Create array of issuer addresses for batch processing
        address[] memory issuerAddresses = new address[](1);
        issuerAddresses[0] = issuer1Asset;

        // expect event emission for batch processing
        vm.expectEmit(true, true, false, true, address(issuerStakingController));
        emit Events.EmergencyExit(issuerAddresses, totalMoca);

        // Emergency exit call with issuer addresses array
        vm.prank(emergencyExitHandler);
        issuerStakingController.emergencyExit(issuerAddresses);

        // After checks - contract state
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "TOTAL_MOCA_STAKED should be reset");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "TOTAL_MOCA_PENDING_UNSTAKE should be reset");
        // Verify issuer's staked balance is reset
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's staked balance should be reset");
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "issuer's pending unstake balance should be reset");
        
        // After checks - token balances
        uint256 issuerBalanceAfter = address(issuer1Asset).balance;
        uint256 contractBalanceAfter = address(issuerStakingController).balance;

        assertEq(contractBalanceAfter, 0, "contract balance should be zero after emergency exit");
        assertEq(issuerBalanceAfter, issuerBalanceBefore + totalMoca, "issuer should receive all their Moca from the contract");
    }

    // Test case: issuer can emergency exit for themselves
    function test_Issuer_CanEmergencyExit_ForThemselves() public {
        uint256 totalStaked = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalPendingUnstake = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();
        uint256 totalMoca = totalStaked + totalPendingUnstake;

        uint256 issuerBalanceBefore = address(issuer1Asset).balance;
        uint256 contractBalanceBefore = address(issuerStakingController).balance;

        address[] memory issuerAddresses = new address[](1);
        issuerAddresses[0] = issuer1Asset;

        vm.expectEmit(true, true, false, true, address(issuerStakingController));
        emit Events.EmergencyExit(issuerAddresses, totalMoca);

        vm.prank(issuer1Asset);
        issuerStakingController.emergencyExit(issuerAddresses);

        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "TOTAL_MOCA_STAKED should be reset");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "TOTAL_MOCA_PENDING_UNSTAKE should be reset");
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's staked balance should be reset");
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "issuer's pending unstake balance should be reset");
        assertEq(address(issuerStakingController).balance, 0, "contract balance should be zero");
        assertEq(address(issuer1Asset).balance, issuerBalanceBefore + totalMoca, "issuer should receive all their Moca");
    }

    function testCan_EmergencyExit_WrapIfNativeTransferFails_EmergencyExitHandler() public {
        // Deploy a contract with expensive receive function that exceeds MOCA_TRANSFER_GAS_LIMIT
        // We'll use vm.etch to replace issuer1Asset with this contract's code
        
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;
        
        // Replace issuer1Asset with contract code that has expensive receive
        vm.etch(issuer1Asset, gasGuzzlerCode);

        // Setup before state for balances and contract variables
        uint256 totalStaked = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalPendingUnstake = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();
        uint256 totalMoca = totalStaked + totalPendingUnstake;

        assertGt(totalMoca, 0, "There should be Moca to transfer");
        uint256 contractBalanceBefore = address(issuerStakingController).balance;
        assertEq(contractBalanceBefore, totalMoca, "contract must hold moca tokens");

        // Balances before
        assertEq(mockWMoca.balanceOf(issuer1Asset), 0, "Issuer should have no wMoca before");
        uint256 issuerNativeBefore = address(issuer1Asset).balance;

        // Create array of issuer addresses for batch processing
        address[] memory issuerAddresses = new address[](1);
        issuerAddresses[0] = issuer1Asset;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(issuerStakingController));
        emit Events.EmergencyExit(issuerAddresses, totalMoca);

        // Emergency exit call with issuer addresses array
        vm.prank(emergencyExitHandler);
        issuerStakingController.emergencyExit(issuerAddresses);

        // After checks - contract state
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "TOTAL_MOCA_STAKED should be reset");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "TOTAL_MOCA_PENDING_UNSTAKE should be reset");
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's staked balance should be reset");
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "issuer's pending unstake balance should be reset");
        
        // After checks - token balances: wMoca was given instead of native moca
        assertEq(mockWMoca.balanceOf(issuer1Asset), totalMoca, "issuer should get WMoca if native transfer fails");
        assertEq(address(issuer1Asset).balance, issuerNativeBefore, "issuer native moca balance unchanged");
        assertEq(address(issuerStakingController).balance, 0, "contract balance should be zero after emergency exit");
    }


    function testCan_EmergencyExit_WrapIfNativeTransferFails_Issuer() public {
        // Deploy a contract with expensive receive function that exceeds MOCA_TRANSFER_GAS_LIMIT
        // We'll use vm.etch to replace issuer1Asset with this contract's code
        
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;
        
        // Replace issuer1Asset with contract code that has expensive receive
        vm.etch(issuer1Asset, gasGuzzlerCode);

        // Setup before state for balances and contract variables
        uint256 totalStaked = issuerStakingController.TOTAL_MOCA_STAKED();
        uint256 totalPendingUnstake = issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE();
        uint256 totalMoca = totalStaked + totalPendingUnstake;

        assertGt(totalMoca, 0, "There should be Moca to transfer");
        uint256 contractBalanceBefore = address(issuerStakingController).balance;
        assertEq(contractBalanceBefore, totalMoca, "contract must hold moca tokens");

        // Balances before
        assertEq(mockWMoca.balanceOf(issuer1Asset), 0, "Issuer should have no wMoca before");
        uint256 issuerNativeBefore = address(issuer1Asset).balance;

        // Create array of issuer addresses for batch processing
        address[] memory issuerAddresses = new address[](1);
        issuerAddresses[0] = issuer1Asset;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(issuerStakingController));
        emit Events.EmergencyExit(issuerAddresses, totalMoca);

        // Emergency exit call with issuer addresses array
        vm.prank(issuer1Asset);
        issuerStakingController.emergencyExit(issuerAddresses);

        // After checks - contract state
        assertEq(issuerStakingController.TOTAL_MOCA_STAKED(), 0, "TOTAL_MOCA_STAKED should be reset");
        assertEq(issuerStakingController.TOTAL_MOCA_PENDING_UNSTAKE(), 0, "TOTAL_MOCA_PENDING_UNSTAKE should be reset");
        assertEq(issuerStakingController.issuers(issuer1Asset), 0, "issuer's staked balance should be reset");
        assertEq(issuerStakingController.totalPendingUnstakedMoca(issuer1Asset), 0, "issuer's pending unstake balance should be reset");
        
        // After checks - token balances: wMoca was given instead of native moca
        assertEq(mockWMoca.balanceOf(issuer1Asset), totalMoca, "issuer should get WMoca if native transfer fails");
        assertEq(address(issuer1Asset).balance, issuerNativeBefore, "issuer native moca balance unchanged");
        assertEq(address(issuerStakingController).balance, 0, "contract balance should be zero after emergency exit");
    }

    // --------- Others ---------

    function testRevert_Unpause_WhenFrozen() public {        
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen.selector);
        issuerStakingController.unpause();
    }

    function testRevert_Freeze_WhenFrozen() public {
        vm.prank(globalAdmin);
        vm.expectRevert(Errors.IsFrozen.selector);
        issuerStakingController.freeze();
    }   
}