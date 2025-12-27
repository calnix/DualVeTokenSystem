// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {VotingControllerHarness} from "./VotingControllerHarness.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/**
 * @title VotingController_Withdrawals_Test
 * @notice Tests for withdrawUnclaimedRewards, withdrawUnclaimedSubsidies, withdrawRegistrationFees
 */
contract VotingController_Withdrawals_Test is VotingControllerHarness {

    uint128 internal epoch;

    function setUp() public override {
        super.setUp();
        _createPools(2);
        epoch = getCurrentEpochNumber();
    }

    // ═══════════════════════════════════════════════════════════════════
    // withdrawUnclaimedRewards: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_WithdrawUnclaimedRewards_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        
        // Warp past unclaimed delay
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        // ---- CAPTURE BEFORE STATE ----
        uint256 treasuryBalanceBefore = mockEsMoca.balanceOf(votingControllerTreasury);
        EpochSnapshot memory epochBefore = captureEpochState(epoch);
        
        assertEq(epochBefore.totalRewardsWithdrawn, 0, "No rewards withdrawn initially");
        assertEq(epochBefore.totalRewardsClaimed, 0, "No rewards claimed");
        assertEq(epochBefore.totalRewardsAllocated, 100 ether, "100 ether allocated");
        
        // ---- EXECUTE ----
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.UnclaimedRewardsWithdrawn(votingControllerTreasury, epoch, 100 ether);
        
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
        
        // ---- CAPTURE AFTER STATE ----
        uint256 treasuryBalanceAfter = mockEsMoca.balanceOf(votingControllerTreasury);
        EpochSnapshot memory epochAfter = captureEpochState(epoch);
        
        // ---- VERIFY EXACT STATE CHANGES ----
        
        // Treasury receives unclaimed (balance increased by withdrawn amount)
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + 100 ether, "Treasury: +100 ether");
        
        // Epoch tracking
        assertEq(epochAfter.totalRewardsWithdrawn, 100 ether, "Epoch totalRewardsWithdrawn: 100 ether");
        
        // Allocations unchanged
        assertEq(epochAfter.totalRewardsAllocated, epochBefore.totalRewardsAllocated, "Allocations unchanged");
        
        // Claimed unchanged (no user claimed)
        assertEq(epochAfter.totalRewardsClaimed, epochBefore.totalRewardsClaimed, "Claimed unchanged: 0");
        
        // Verify the math: allocated - claimed - withdrawn = remaining unclaimed
        uint128 remaining = epochAfter.totalRewardsAllocated - epochAfter.totalRewardsClaimed - epochAfter.totalRewardsWithdrawn;
        assertEq(remaining, 0, "No remaining rewards after withdrawal");
    }

    function test_WithdrawUnclaimedRewards_PartiallyClaimedRewards() public {
        _setupVotingPower(voter1, epoch, 500 ether, 0);
        _setupVotingPower(voter2, epoch, 500 ether, 0);
        
        _vote(voter1, _toArray(1), _toArray(500 ether));
        _vote(voter2, _toArray(1), _toArray(500 ether));
        
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        
        // Only voter1 claims
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        // Warp past unclaimed delay
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
        
        // Should withdraw 50 ether (voter2's unclaimed portion)
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(snapshot.totalRewardsWithdrawn, 50 ether, "Should withdraw only unclaimed portion");
    }

    // ═══════════════════════════════════════════════════════════════════
    // withdrawUnclaimedRewards: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_WithdrawUnclaimedRewards_TooEarly() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        
        // Only advance partway through delay
        _warpToEpoch(epoch + unclaimedDelayEpochs);
        
        vm.expectRevert(Errors.CanOnlyWithdrawUnclaimedAfterDelay.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
    }

    function test_RevertWhen_WithdrawUnclaimedRewards_EpochNotFinalized() public {
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.expectRevert(Errors.EpochNotFinalized.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
    }

    function test_RevertWhen_WithdrawUnclaimedRewards_AlreadyWithdrawn() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
        
        vm.expectRevert(Errors.RewardsAlreadyWithdrawn.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
    }

    function test_RevertWhen_WithdrawUnclaimedRewards_NoUnclaimedRewards() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        
        // Claim all rewards
        vm.prank(voter1);
        votingController.claimPersonalRewards(epoch, _toArray(1));
        
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.expectRevert(Errors.NoUnclaimedRewardsToWithdraw.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedRewards(epoch);
    }

    function test_RevertWhen_WithdrawUnclaimedRewards_Unauthorized() public {
        _finalizeEpoch(_toArray(1, 2), _toArray(100 ether, 0), _toArray(0, 0));
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.ASSET_MANAGER_ROLE));
        vm.prank(voter1);
        votingController.withdrawUnclaimedRewards(epoch);
    }

    // ═══════════════════════════════════════════════════════════════════
    // withdrawUnclaimedSubsidies: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_WithdrawUnclaimedSubsidies_Success() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 0));
        
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        uint256 treasuryBalanceBefore = mockEsMoca.balanceOf(votingControllerTreasury);
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.UnclaimedSubsidiesWithdrawn(votingControllerTreasury, epoch, 100 ether);
        
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch);
        
        uint256 treasuryBalanceAfter = mockEsMoca.balanceOf(votingControllerTreasury);
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, 100 ether, "Treasury should receive unclaimed subsidies");
        
        EpochSnapshot memory snapshot = captureEpochState(epoch);
        assertEq(snapshot.totalSubsidiesWithdrawn, 100 ether, "Subsidies withdrawn should be tracked");
    }

    // ═══════════════════════════════════════════════════════════════════
    // withdrawUnclaimedSubsidies: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_WithdrawUnclaimedSubsidies_TooEarly() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 0));
        
        _warpToEpoch(epoch + unclaimedDelayEpochs);
        
        vm.expectRevert(Errors.CanOnlyWithdrawUnclaimedAfterDelay.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch);
    }

    function test_RevertWhen_WithdrawUnclaimedSubsidies_AlreadyWithdrawn() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 0));
        
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch);
        
        vm.expectRevert(Errors.SubsidiesAlreadyWithdrawn.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch);
    }

    function test_RevertWhen_WithdrawUnclaimedSubsidies_NoUnclaimedSubsidies() public {
        _setupVotingPower(voter1, epoch, 1000 ether, 0);
        _vote(voter1, _toArray(1), _toArray(1000 ether));
        _finalizeEpoch(_toArray(1, 2), _toArray(0, 0), _toArray(100 ether, 0));
        
        // Verifier claims all subsidies
        mockPaymentsController.setMockedVerifierAccruedSubsidies(epoch, 1, verifier1, 100e6);
        mockPaymentsController.setMockedPoolAccruedSubsidies(epoch, 1, 100e6);
        
        vm.prank(verifier1Asset);
        votingController.claimSubsidies(epoch, verifier1, _toArray(1));
        
        _warpToEpoch(epoch + unclaimedDelayEpochs + 1);
        
        vm.expectRevert(Errors.NoUnclaimedSubsidiesToWithdraw.selector);
        vm.prank(assetManager);
        votingController.withdrawUnclaimedSubsidies(epoch);
    }

    // ═══════════════════════════════════════════════════════════════════
    // withdrawRegistrationFees: Success Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_WithdrawRegistrationFees_Success() public {
        // Register some delegates to accumulate fees
        _registerDelegate(delegate1, 1000);
        _registerDelegate(delegate2, 2000);
        
        uint128 totalFees = delegateRegistrationFee * 2;
        
        uint256 treasuryBalanceBefore = votingControllerTreasury.balance;
        
        vm.expectEmit(true, true, true, true, address(votingController));
        emit Events.RegistrationFeesWithdrawn(votingControllerTreasury, totalFees);
        
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
        
        // Check treasury received native MOCA (or wMoca if transfer failed)
        uint256 treasuryBalanceAfter = votingControllerTreasury.balance;
        uint256 wMocaBalance = mockWMoca.balanceOf(votingControllerTreasury);
        
        assertTrue(
            treasuryBalanceAfter - treasuryBalanceBefore == totalFees || wMocaBalance >= totalFees,
            "Treasury should receive registration fees"
        );
        
        assertEq(votingController.TOTAL_REGISTRATION_FEES_CLAIMED(), totalFees, "Claimed fees should be tracked");
    }

    function test_WithdrawRegistrationFees_MultipleWithdrawals() public {
        _registerDelegate(delegate1, 1000);
        
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
        
        // Register more delegates
        _registerDelegate(delegate2, 2000);
        _registerDelegate(delegate3, 3000);
        
        // Withdraw again
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
        
        assertEq(votingController.TOTAL_REGISTRATION_FEES_CLAIMED(), delegateRegistrationFee * 3, "All fees should be claimed");
    }

    // ═══════════════════════════════════════════════════════════════════
    // withdrawRegistrationFees: Revert Cases
    // ═══════════════════════════════════════════════════════════════════

    function test_RevertWhen_WithdrawRegistrationFees_NoFeesToWithdraw() public {
        vm.expectRevert(Errors.NoRegistrationFeesToWithdraw.selector);
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
    }

    function test_RevertWhen_WithdrawRegistrationFees_AllAlreadyClaimed() public {
        _registerDelegate(delegate1, 1000);
        
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
        
        vm.expectRevert(Errors.NoRegistrationFeesToWithdraw.selector);
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
    }

    function test_RevertWhen_WithdrawRegistrationFees_Unauthorized() public {
        _registerDelegate(delegate1, 1000);
        
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, voter1, Constants.ASSET_MANAGER_ROLE));
        vm.prank(voter1);
        votingController.withdrawRegistrationFees();
    }

    function test_RevertWhen_WithdrawRegistrationFees_Paused() public {
        _registerDelegate(delegate1, 1000);
        
        vm.prank(monitor);
        votingController.pause();
        
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(assetManager);
        votingController.withdrawRegistrationFees();
    }
}

