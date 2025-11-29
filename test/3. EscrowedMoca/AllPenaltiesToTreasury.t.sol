// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "./EscrowedMoca.t.sol";

abstract contract AllPenaltiesToTreasury is StateT60Days_UserTwoHasRedemptionScheduled {

    function setUp() public virtual override {
        super.setUp();

        // change penalty split: all penalties to treasury
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setVotersPenaltyPct(0);
        vm.stopPrank();
    }
}

contract AllPenaltiesToTreasury_Test is AllPenaltiesToTreasury {

    // total penalty is all to treasury
    function test_User1_CanRedeem_Quarter_WithOption1() public {
        // Setup
        uint256 redemptionAmount = user1Amount / 4;
        uint256 optionId = redemptionOption1_30Days;
        (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(optionId);
        
        // Block 1: Execute redemption and verify immediate effects
        {
            uint256 esMocaBalBefore = esMoca.balanceOf(user1);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 ACCRUED_PENALTY_TO_VOTERS_before = esMoca.ACCRUED_PENALTY_TO_VOTERS();
            uint256 ACCRUED_PENALTY_TO_TREASURY_before = esMoca.ACCRUED_PENALTY_TO_TREASURY();
            
            // Calculations
            uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
            uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
            
            // With VOTERS_PENALTY_PCT set to 0, the penalty should be all to treasury
            uint256 expectedPenaltyToTreasury = expectedPenalty;
            
            // Execute redemption
            vm.startPrank(user1);

                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.PenaltyAccrued(0, expectedPenaltyToTreasury);

                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);

                esMoca.selectRedemptionOption(optionId, redemptionAmount, expectedMocaReceivable, block.timestamp + lockDuration);
            vm.stopPrank();
            
            // --- Assert immediate effects ---
            assertEq(esMoca.balanceOf(user1), esMocaBalBefore - redemptionAmount, "user1 esMoca not deducted correctly");
            assertEq(esMoca.balanceOf(user1), user1Amount / 4, "user1 should have a quarter of esMoca redeemed, three-quarters left");
            assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "totalSupply should reflect burning");
            
            // Ensure penalty is tracked and all to treasury
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), ACCRUED_PENALTY_TO_VOTERS_before, "penalty to voters incorrect: not 0%");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), ACCRUED_PENALTY_TO_TREASURY_before + expectedPenalty, "penalty to treasury incorrect: not all to treasury");
        }
        
        // Block 2: Verify redemption schedule
        {
            uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
            uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
            
            uint256 mocaReceivable = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
            assertEq(mocaReceivable, expectedMocaReceivable, "redemption schedule: mocaReceivable wrong");
        }
    }
    
}