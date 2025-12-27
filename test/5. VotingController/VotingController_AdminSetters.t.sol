// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title VotingController_AdminSetters_Test
 * @notice Tests for admin setter functions
 */
contract VotingController_AdminSetters_Test is VotingControllerHarness {

    // ═══════════════════════════════════════════════════════════════════
    // setVotingControllerTreasury
    // ═══════════════════════════════════════════════════════════════════

    function test_SetVotingControllerTreasury_Success() public {
        address newTreasury = makeAddr("newTreasury");
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.VotingControllerTreasuryUpdated(votingControllerTreasury, newTreasury);
        
        vm.prank(votingControllerAdmin);
        votingController.setVotingControllerTreasury(newTreasury);
        
        assertEq(votingController.VOTING_CONTROLLER_TREASURY(), newTreasury, "Treasury should be updated");
    }

    function test_RevertWhen_SetVotingControllerTreasury_ZeroAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(votingControllerAdmin);
        votingController.setVotingControllerTreasury(address(0));
    }

    function test_RevertWhen_SetVotingControllerTreasury_SameAddress() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        vm.prank(votingControllerAdmin);
        votingController.setVotingControllerTreasury(votingControllerTreasury);
    }

    function test_RevertWhen_SetVotingControllerTreasury_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.setVotingControllerTreasury(makeAddr("newTreasury"));
    }

    // ═══════════════════════════════════════════════════════════════════
    // setDelegateRegistrationFee
    // ═══════════════════════════════════════════════════════════════════

    function test_SetDelegateRegistrationFee_Success() public {
        uint128 newFee = 5 ether;
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.DelegateRegistrationFeeUpdated(delegateRegistrationFee, newFee);
        
        vm.prank(votingControllerAdmin);
        votingController.setDelegateRegistrationFee(newFee);
        
        assertEq(votingController.DELEGATE_REGISTRATION_FEE(), newFee, "Fee should be updated");
    }

    function test_SetDelegateRegistrationFee_ZeroAllowed() public {
        vm.prank(votingControllerAdmin);
        votingController.setDelegateRegistrationFee(0);
        
        assertEq(votingController.DELEGATE_REGISTRATION_FEE(), 0, "Zero fee should be allowed");
    }

    function test_RevertWhen_SetDelegateRegistrationFee_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.setDelegateRegistrationFee(5 ether);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setMaxDelegateFeePct
    // ═══════════════════════════════════════════════════════════════════

    function test_SetMaxDelegateFeePct_Success() public {
        uint128 newMaxFee = 7500; // 75%
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.MaxDelegateFeePctUpdated(maxDelegateFeePct, newMaxFee);
        
        vm.prank(votingControllerAdmin);
        votingController.setMaxDelegateFeePct(newMaxFee);
        
        assertEq(votingController.MAX_DELEGATE_FEE_PCT(), newMaxFee, "Max fee pct should be updated");
    }

    function test_RevertWhen_SetMaxDelegateFeePct_Zero() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(votingControllerAdmin);
        votingController.setMaxDelegateFeePct(0);
    }

    function test_RevertWhen_SetMaxDelegateFeePct_ExceedsPrecisionBase() public {
        vm.expectRevert(Errors.InvalidPercentage.selector);
        vm.prank(votingControllerAdmin);
        votingController.setMaxDelegateFeePct(10_000); // 100% = PRECISION_BASE
    }

    function test_RevertWhen_SetMaxDelegateFeePct_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.setMaxDelegateFeePct(5000);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setFeeIncreaseDelayEpochs
    // ═══════════════════════════════════════════════════════════════════

    function test_SetFeeIncreaseDelayEpochs_Success() public {
        uint128 newDelay = 5;
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.FeeIncreaseDelayEpochsUpdated(feeIncreaseDelayEpochs, newDelay);
        
        vm.prank(votingControllerAdmin);
        votingController.setFeeIncreaseDelayEpochs(newDelay);
        
        assertEq(votingController.FEE_INCREASE_DELAY_EPOCHS(), newDelay, "Fee delay should be updated");
    }

    function test_RevertWhen_SetFeeIncreaseDelayEpochs_Zero() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        vm.prank(votingControllerAdmin);
        votingController.setFeeIncreaseDelayEpochs(0);
    }

    function test_RevertWhen_SetFeeIncreaseDelayEpochs_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.setFeeIncreaseDelayEpochs(5);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setUnclaimedDelay
    // ═══════════════════════════════════════════════════════════════════

    function test_SetUnclaimedDelay_Success() public {
        uint128 newDelay = 10;
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.UnclaimedDelayUpdated(unclaimedDelayEpochs, newDelay);
        
        vm.prank(votingControllerAdmin);
        votingController.setUnclaimedDelay(newDelay);
        
        assertEq(votingController.UNCLAIMED_DELAY_EPOCHS(), newDelay, "Unclaimed delay should be updated");
    }

    function test_RevertWhen_SetUnclaimedDelay_Zero() public {
        vm.expectRevert(Errors.InvalidDelayPeriod.selector);
        vm.prank(votingControllerAdmin);
        votingController.setUnclaimedDelay(0);
    }

    function test_RevertWhen_SetUnclaimedDelay_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.setUnclaimedDelay(10);
    }

    // ═══════════════════════════════════════════════════════════════════
    // setMocaTransferGasLimit
    // ═══════════════════════════════════════════════════════════════════

    function test_SetMocaTransferGasLimit_Success() public {
        uint128 newGasLimit = 5000;
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.MocaTransferGasLimitUpdated(MOCA_TRANSFER_GAS_LIMIT, newGasLimit);
        
        vm.prank(votingControllerAdmin);
        votingController.setMocaTransferGasLimit(newGasLimit);
        
        assertEq(votingController.MOCA_TRANSFER_GAS_LIMIT(), newGasLimit, "Gas limit should be updated");
    }

    function test_RevertWhen_SetMocaTransferGasLimit_TooLow() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        vm.prank(votingControllerAdmin);
        votingController.setMocaTransferGasLimit(2299);
    }

    function test_SetMocaTransferGasLimit_MinimumAllowed() public {
        vm.prank(votingControllerAdmin);
        votingController.setMocaTransferGasLimit(2300);
        
        assertEq(votingController.MOCA_TRANSFER_GAS_LIMIT(), 2300, "Minimum gas limit should be allowed");
    }

    function test_RevertWhen_SetMocaTransferGasLimit_Unauthorized() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.VOTING_CONTROLLER_ADMIN_ROLE));
        vm.prank(voter1);
        votingController.setMocaTransferGasLimit(5000);
    }

    function test_RevertWhen_SetMocaTransferGasLimit_Paused() public {
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(votingControllerAdmin);
        votingController.setMocaTransferGasLimit(5000);
    }
}

