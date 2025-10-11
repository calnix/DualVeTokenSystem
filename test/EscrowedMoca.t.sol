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

    function test_Constructor() public {
        assertEq(address(esMoca.addressBook()), address(addressBook), "addressBook not set correctly");
        assertEq(esMoca.VOTERS_PENALTY_SPLIT(), 1000, "VOTERS_PENALTY_SPLIT not set correctly");
        
        // erc20
        assertEq(esMoca.name(), "esMoca", "name not set correctly");
        assertEq(esMoca.symbol(), "esMoca", "symbol not set correctly");


        assertEq(esMoca.TOTAL_MOCA_ESCROWED(), 0);
    }


    function testReverts_Batched_Constructor() public {
        // invalid address
        vm.expectRevert(Errors.InvalidAddress.selector);
        new EscrowedMoca(address(0), 1000);

        // invalid percentage
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new EscrowedMoca(address(addressBook), 0);

        // invalid percentage
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new EscrowedMoca(address(addressBook), Constants.PRECISION_BASE + 1);
    }

    // state transition: escrow moca
    function testCan_User_EscrowMoca() public {
        assertEq(esMoca.TOTAL_MOCA_ESCROWED(), 0);

        // setup
        uint256 amount = 100 ether;
        mockMoca.mint(user1, amount);

        // check balances before action
        uint256 beforeUserMoca = mockMoca.balanceOf(user1);
        uint256 beforeContractMoca = mockMoca.balanceOf(address(esMoca));
        uint256 beforeUserEsMoca = esMoca.balanceOf(user1);

        // approve + escrow
        vm.startPrank(user1);
            mockMoca.approve(address(esMoca), amount);

            // event
            vm.expectEmit(true, true, true, true, address(esMoca));
            emit Events.EscrowedMoca(user1, amount);

            esMoca.escrowMoca(amount);
        vm.stopPrank();

        // check balances after action
        uint256 afterUserMoca = mockMoca.balanceOf(user1);
        uint256 afterContractMoca = mockMoca.balanceOf(address(esMoca));
        uint256 afterUserEsMoca = esMoca.balanceOf(user1);

        // esMoca minted correctly
        assertEq(afterUserEsMoca, beforeUserEsMoca + amount, "esMoca not minting correctly");
        assertEq(afterUserMoca, beforeUserMoca - amount, "User MOCA not transferred from user");
        // contract moca balance increased by amount
        assertEq(afterContractMoca, beforeContractMoca + amount, "contract MOCA not transferred to contract");
        assertEq(esMoca.TOTAL_MOCA_ESCROWED(), amount, "TOTAL_MOCA_ESCROWED not incremented correctly");

    }

}

abstract contract StateT0_EscrowedMoca is StateT0_Deploy {

    uint256 user1Amount = 100 ether;
    uint256 user2Amount = 200 ether;
    uint256 user3Amount = 300 ether;

    function setUp() public virtual override {
        super.setUp();

        // setup
        mockMoca.mint(user1, user1Amount);
        mockMoca.mint(user2, user2Amount);
        mockMoca.mint(user3, user3Amount);

        // approve + escrow
        vm.startPrank(user1);
        mockMoca.approve(address(esMoca), user1Amount);
        esMoca.escrowMoca(user1Amount);
        vm.stopPrank();

        vm.startPrank(user2);
        mockMoca.approve(address(esMoca), user2Amount);
        esMoca.escrowMoca(user2Amount);
        vm.stopPrank();

        vm.startPrank(user3);
        mockMoca.approve(address(esMoca), user3Amount);
        esMoca.escrowMoca(user3Amount);
        vm.stopPrank();
    }
}

contract StateT0_EscrowedMoca_Test is StateT0_EscrowedMoca {

    function testRevert_EscrowedMoca_InvalidAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        esMoca.escrowMoca(0);
    }

    // --------- state transition: set redemption options ---------

        function testRevert_UserCannot_SetRedemptionOptions() public {
            vm.expectRevert(Errors.OnlyCallableByEscrowedMocaAdmin.selector);
            vm.prank(user1);
            esMoca.setRedemptionOption(1, 30 days, 5_000); // 50% penalty
        }

        function testCan_EscrowedMocaAdmin_SetRedemptionOptions() public {
            vm.startPrank(escrowedMocaAdmin);

            // event
            vm.expectEmit(true, true, true, true, address(esMoca));
            emit Events.RedemptionOptionUpdated(1, 30 days, 5_000);

            esMoca.setRedemptionOption(1, 30 days, 5_000); // 50% penalty
            vm.stopPrank();
        }
}

//note: set all 3 redemption options
abstract contract StateT0_RedemptionOptionsSet is StateT0_EscrowedMoca {

    uint256 public redemptionOption1_30Days = 1;
    uint256 public redemptionOption2_60Days = 2;
    uint256 public redemptionOption3_Instant = 3;

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(escrowedMocaAdmin);
            // option 1: 30 days, 50% penalty
            esMoca.setRedemptionOption(1, 30 days, 5_000); 
            // option 2: 60 days, 100% receivable [0% penalty]
            esMoca.setRedemptionOption(2, 60 days, uint128(Constants.PRECISION_BASE)); 
            // option 3: 0 days, 20% receivable [80% penalty]
            esMoca.setRedemptionOption(3, 0, 2_000); 
        vm.stopPrank();
    }
}

contract StateT0_RedemptionOptionsSet_Test is StateT0_RedemptionOptionsSet {

    // --------- negative tests ---------
    
        function testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidPercentage() public {
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(escrowedMocaAdmin);
            esMoca.setRedemptionOption(1, 30 days, 10_001); // 100.01% penalty
        }

        // lock duration must be <= 888 days
        function testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidLockDuration() public {
            vm.expectRevert(Errors.InvalidLockDuration.selector);
            vm.prank(escrowedMocaAdmin);
            esMoca.setRedemptionOption(1, 889 days, 5_000); // 889 days lock duration
        }
    
    // --------- positive tests ---------

        function test_User1Can_SelectRedemptionOption_30Days() public {
            // --- Arrange ---
            uint256 redemptionAmount = user1Amount / 2;
            uint256 optionId = redemptionOption1_30Days;
            // Get redemption option params
            (uint128 lockDuration, uint128 receivablePct, bool isEnabled) = esMoca.redemptionOptions(optionId);

            // Before state: balances + burn
            uint256 esMocaBalBefore = esMoca.balanceOf(user1);
            uint256 mocaBalBefore = mockMoca.balanceOf(user1);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 totalEscrowedBefore = esMoca.TOTAL_MOCA_ESCROWED();

            // calculation for receivable/penalty
            uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
            uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;

            // calculate penalty amount
            uint256 penaltyToVoters = expectedPenalty * esMoca.VOTERS_PENALTY_SPLIT() / Constants.PRECISION_BASE;
            uint256 penaltyToTreasury = expectedPenalty - penaltyToVoters;

            // --- redeem ---
            vm.startPrank(user1);

                vm.expectEmit(true, true, false, true, address(esMoca));
                // Event: RedemptionScheduled (delayed redemptions emit, instant might emit MocaTransferred)
                emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);
                // Event: PenaltyAccrued
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);

                // partial redemption with penalty | 30 days lock
                esMoca.selectRedemptionOption(optionId, redemptionAmount); 

            vm.stopPrank();

            // --- assert ---

            // esMoca tokens burned
            assertEq(esMoca.balanceOf(user1), esMocaBalBefore - redemptionAmount, "esMoca balance not decremented correctly");
            assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "esMoca totalSupply not decremented");

            // Escrowed MOCA unchanged yet (not claimed)
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), totalEscrowedBefore, "Escrowed MOCA shouldn't change until claim");
            // Penalty accrued
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), penaltyToVoters, "penaltyToVoters not accrued correctly");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), penaltyToTreasury, "penaltyToTreasury not accrued correctly");

            // Moca not received yet
            assertEq(mockMoca.balanceOf(user1), mocaBalBefore, "MOCA balance should not increment until claimRedemption");

            // Redemption schedule created for user
            (uint256 mocaReceivable, uint256 claimed, uint256 penalty) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
            assertEq(mocaReceivable, expectedMocaReceivable, "stored mocaReceivable incorrect");
            assertEq(claimed, 0, "claimed should be 0");
            assertEq(penalty, expectedPenalty, "penalty incorrect");
        }

        // note: user2 schedules a 60 day redemption: no penalties
        function test_User2Can_SelectRedemptionOption_60Days() public {
            // --- Arrange ---
            uint256 redemptionAmount = user2Amount;
            uint256 optionId = redemptionOption2_60Days;
            // Get redemption option params
            (uint128 lockDuration, uint128 receivablePct, bool isEnabled) = esMoca.redemptionOptions(optionId);

            // Before state: balances + burn
            uint256 esMocaBalBefore = esMoca.balanceOf(user2);
            uint256 mocaBalBefore = mockMoca.balanceOf(user2);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 totalEscrowedBefore = esMoca.TOTAL_MOCA_ESCROWED();

            // --- redeem ---
            vm.startPrank(user2);

                // event emission for redemption scheduled
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user2, redemptionAmount, 0, block.timestamp + lockDuration);

                // full redemption with no penalty | 60 days lock
                esMoca.selectRedemptionOption(optionId, redemptionAmount); 

            vm.stopPrank();

            // --- assert ---

            // esMoca tokens burned
            assertEq(esMoca.balanceOf(user2), 0);
            assertEq(esMoca.balanceOf(user2), esMocaBalBefore - redemptionAmount, "esMoca balance not decremented correctly");
            assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "esMoca totalSupply not decremented");

            // Escrowed MOCA unchanged yet (not claimed)
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), totalEscrowedBefore, "Escrowed MOCA shouldn't change until claim");

            // Penalty accrued: 0 because no penalty
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), 0, "penaltyToVoters not accrued correctly");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), 0, "penaltyToTreasury not accrued correctly");

            // Moca not received yet
            assertEq(mockMoca.balanceOf(user2), mocaBalBefore, "MOCA balance should not increment until claimRedemption");

            // Redemption schedule created for user2 
            (uint256 mocaReceivable, uint256 claimed, uint256 penalty) = esMoca.redemptionSchedule(user2, block.timestamp + lockDuration);
            assertEq(mocaReceivable, redemptionAmount, "stored mocaReceivable incorrect");
            assertEq(claimed, 0, "claimed should be 0");
            assertEq(penalty, 0, "penalty incorrect");
        }
}

// note: user1 has a redemption scheduled | partial redemption
abstract contract StateT0_UsersScheduleTheirRedemptions is StateT0_RedemptionOptionsSet {

    function setUp() public virtual override {
        super.setUp();

        // user1 schedules a redemption: penalties booked + redemption scheduled
        vm.startPrank(user1);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, user1Amount / 2);
        vm.stopPrank();

        // user2 schedules a redemption: penalties booked + redemption scheduled
        vm.startPrank(user2);
            esMoca.selectRedemptionOption(redemptionOption2_60Days, user2Amount);
        vm.stopPrank();
    }
}

// note: partial redemption of redemptionOption1_30Days [30 days lock, 50% penalty]
contract StateT0_UsersScheduleTheirRedemptions_Test is StateT0_UsersScheduleTheirRedemptions {

    // --------- negative tests: claimRedemption() ---------

        function testRevert_User1Cannot_ClaimRedemption_Before30Days() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.NothingToClaim.selector);
            esMoca.claimRedemption(block.timestamp);
            vm.stopPrank();
        }

        function testRevert_User1Cannot_ClaimRedemption_PassingFutureTimestamp() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.RedemptionNotAvailableYet.selector);
            esMoca.claimRedemption(block.timestamp + 1);
            vm.stopPrank();
        }


        function testRevert_User2Cannot_ClaimRedemption_Before60Days() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.NothingToClaim.selector);
            esMoca.claimRedemption(block.timestamp);
            vm.stopPrank();
        }

        function testRevert_User2Cannot_ClaimRedemption_PassingFutureTimestamp() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.RedemptionNotAvailableYet.selector);
            esMoca.claimRedemption(block.timestamp + 1);
            vm.stopPrank();
        }

    // --------- positive test: claimRedemption() for instant redemption ---------

    function test_User3Can_RedeemInstant_ReceivesMocaImmediately() public {
        // --- before balances & state ---
        uint256 user3MocaBefore = mockMoca.balanceOf(user3);
        uint256 user3EsMocaBefore = esMoca.balanceOf(user3);
        uint256 totalSupplyBefore = esMoca.totalSupply();
        uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();
        
        // redemption option instant params
        (uint128 lockDuration, uint128 receivablePct, bool isEnabled) = esMoca.redemptionOptions(redemptionOption3_Instant);

        // redemption option instant values
        uint256 instantRedeemAmount = user3Amount / 2;
        uint256 expectedMocaReceivable = instantRedeemAmount * receivablePct / Constants.PRECISION_BASE;
        uint256 expectedPenalty = instantRedeemAmount - expectedMocaReceivable;
        
        // calculate penalty amount
        uint256 penaltyToVoters = expectedPenalty * esMoca.VOTERS_PENALTY_SPLIT() / Constants.PRECISION_BASE;
        uint256 penaltyToTreasury = expectedPenalty - penaltyToVoters;

        // event emission for instant redemption
        vm.expectEmit(true, false, false, false, address(esMoca));
        emit Events.Redeemed(user3, expectedMocaReceivable, block.timestamp);

        vm.expectEmit(true, false, false, false, address(esMoca));
        emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);

        // --- execute ---
        vm.startPrank(user3);
            esMoca.selectRedemptionOption(redemptionOption3_Instant, instantRedeemAmount);
        vm.stopPrank();

        // --- after balances & state ---
        uint256 user3MocaAfter = mockMoca.balanceOf(user3);
        uint256 user3EsMocaAfter = esMoca.balanceOf(user3);
        uint256 totalSupplyAfter = esMoca.totalSupply();
        uint256 TOTAL_MOCA_ESCROWED_after = esMoca.TOTAL_MOCA_ESCROWED();
        (uint256 mocaReceivableAfter, uint256 claimedAfter, uint256 penaltyAfter) = esMoca.redemptionSchedule(user3, block.timestamp);

        // check token balances after selectRedemptionOption
        assertEq(user3MocaAfter, user3MocaBefore + expectedMocaReceivable, "MOCA balance should increase immediately by mocaReceivable");
        // esMoca balance should decrease by amount redeemed
        assertEq(user3EsMocaAfter, user3EsMocaBefore - instantRedeemAmount, "esMoca balance should decrease by redeemed amount");
        assertEq(totalSupplyAfter, totalSupplyBefore - instantRedeemAmount, "totalSupply should decrease by redeemed amount");
        assertEq(TOTAL_MOCA_ESCROWED_after, TOTAL_MOCA_ESCROWED_before - expectedMocaReceivable, "TOTAL_MOCA_ESCROWED should decrease by mocaReceivable");

        // check redemption schedule updates
        assertEq(mocaReceivableAfter, expectedMocaReceivable, "mocaReceivable in schedule should equal amount received");
        assertEq(claimedAfter, expectedMocaReceivable, "claimed in redemptionSchedule should match mocaReceivable for instant");
        assertEq(penaltyAfter, expectedPenalty, "penalty should be stored in schedule");
    }
}


abstract contract StateT30Days_UserOneHasRedemptionScheduled is StateT0_UsersScheduleTheirRedemptions {

    function setUp() public virtual override {
        super.setUp();

        // fast forward to 30 days
        skip(30 days);
    }
}


contract StateT30Days_UserOneHasRedemptionScheduled_Test is StateT30Days_UserOneHasRedemptionScheduled {

    // --------- negative tests: claimRedemption() ---------
        function testRevert_User2Cannot_ClaimRedemption_Before60Days() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.NothingToClaim.selector);
            esMoca.claimRedemption(block.timestamp);
            vm.stopPrank();
        }

        function testRevert_User2Cannot_ClaimRedemption_PassingFutureTimestamp() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.RedemptionNotAvailableYet.selector);
            esMoca.claimRedemption(block.timestamp + 1);
            vm.stopPrank();
        }

    // --------- positive test: claimRedemption() for 30 days lock ---------
        function test_User1Can_ClaimRedemption_30Days() public {
            // --- before balances & state ---
            uint256 user1MocaBefore = mockMoca.balanceOf(user1);
            uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();
            // user1's redemption schedule
            (uint256 mocaReceivableBefore, uint256 claimedBefore, uint256 penaltyBefore) = esMoca.redemptionSchedule(user1, block.timestamp);

            // events
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.Redeemed(user1, mocaReceivableBefore, block.timestamp);

            vm.startPrank(user1);
            esMoca.claimRedemption(block.timestamp);
            vm.stopPrank();
            
            // --- after balances & state ---
            uint256 user1MocaAfter = mockMoca.balanceOf(user1);
            uint256 user1EsMocaAfter = esMoca.balanceOf(user1);
            uint256 totalSupplyAfter = esMoca.totalSupply();

            // user1's redemption schedule after claimRedemption
            (uint256 mocaReceivableAfter, uint256 claimedAfter, uint256 penaltyAfter) = esMoca.redemptionSchedule(user1, block.timestamp);
            
            // check token balances after claimRedemption
            assertEq(user1MocaAfter, user1MocaBefore + mocaReceivableBefore, "MOCA balance not transferred correctly");
            // esMoca balance should not change in claim
            assertEq(user1EsMocaAfter, user1EsMocaBefore, "esMoca balance should not change in claim");
            assertEq(totalSupplyAfter, totalSupplyBefore, "totalSupply should not change in claim");
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), TOTAL_MOCA_ESCROWED_before - mocaReceivableBefore, "TOTAL_MOCA_ESCROWED not decremented correctly");

            // check redemption schedule updates
            assertEq(mocaReceivableAfter, mocaReceivableBefore, "mocaReceivable in redemptionSchedule should not change");
            assertEq(claimedAfter, mocaReceivableBefore, "claimed should be updated to full amount");
            assertEq(penaltyAfter, penaltyBefore, "penalty in redemptionSchedule should not change");
        }
}

abstract contract StateT60Days_UserTwoHasRedemptionScheduled is StateT30Days_UserOneHasRedemptionScheduled {

    function setUp() public virtual override {
        super.setUp();

        // fast forward another 30 days
        skip(30 days);
    }
}

contract StateT60Days_UserTwoHasRedemptionScheduled_Test is StateT60Days_UserTwoHasRedemptionScheduled {

    // --------- positive test: claimRedemption() for 60 days lock ---------
        function test_User2Can_ClaimRedemption_60Days() public {
            // --- before balances & state ---
            uint256 user2MocaBefore = mockMoca.balanceOf(user2);
            uint256 user2EsMocaBefore = esMoca.balanceOf(user2);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();
            // user2's redemption schedule
            (uint256 mocaReceivableBefore, uint256 claimedBefore, uint256 penaltyBefore) = esMoca.redemptionSchedule(user2, block.timestamp);


            // events
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.Redeemed(user2, mocaReceivableBefore, block.timestamp);

            vm.startPrank(user2);
            esMoca.claimRedemption(block.timestamp);
            vm.stopPrank();

            // --- after balances & state ---
            uint256 user2MocaAfter = mockMoca.balanceOf(user2);
            uint256 user2EsMocaAfter = esMoca.balanceOf(user2);
            uint256 totalSupplyAfter = esMoca.totalSupply();
            uint256 TOTAL_MOCA_ESCROWED_after = esMoca.TOTAL_MOCA_ESCROWED();
            (uint256 mocaReceivableAfter, uint256 claimedAfter, uint256 penaltyAfter) = esMoca.redemptionSchedule(user2, block.timestamp);

            // check token balances after claimRedemption
            assertEq(user2MocaAfter, user2MocaBefore + mocaReceivableBefore, "MOCA balance not transferred correctly");
            assertEq(user2EsMocaAfter, 0, "esMoca balance should be 0 after claimRedemption");

            // esMoca balance should not change in claim
            assertEq(user2EsMocaAfter, user2EsMocaBefore, "esMoca balance should not change in claim");
            assertEq(totalSupplyAfter, totalSupplyBefore, "totalSupply should not change in claim");
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), TOTAL_MOCA_ESCROWED_before - mocaReceivableBefore, "TOTAL_MOCA_ESCROWED not decremented correctly");

            // check redemption schedule updates
            assertEq(mocaReceivableAfter, mocaReceivableBefore, "mocaReceivable in redemptionSchedule should not change");
            assertEq(claimedAfter, mocaReceivableBefore, "claimed should be updated to full amount");
        }

    // --------- state transition: change penalty split ---------
        function test_UserCannot_SetPenaltyToVoters() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.OnlyCallableByEscrowedMocaAdmin.selector);
            esMoca.setPenaltyToVoters(5000); 
            vm.stopPrank();
        }

        function test_EscrowedMocaAdminCan_SetPenaltyToVoters() public {
            // record old value
            uint256 oldPenaltyToVoters = esMoca.VOTERS_PENALTY_SPLIT();
            assertEq(esMoca.VOTERS_PENALTY_SPLIT(), 1000);

            // expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.PenaltyToVotersUpdated(oldPenaltyToVoters, 5000);

            vm.startPrank(escrowedMocaAdmin);
                esMoca.setPenaltyToVoters(5000); // 50% penalty
            vm.stopPrank();

            // check state update
            assertEq(esMoca.VOTERS_PENALTY_SPLIT(), 5000, "VOTERS_PENALTY_SPLIT not updated");
        }

}

// note: change penalty split to 50%
abstract contract StateT60Days_ChangePenaltySplit is StateT60Days_UserTwoHasRedemptionScheduled {

    function setUp() public virtual override {
        super.setUp();

        // change penalty split: 50% split between voters and treasury
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setPenaltyToVoters(5000);
        vm.stopPrank();
    }
}

contract StateT60Days_ChangePenaltySplit_Test is StateT60Days_ChangePenaltySplit {

    // --------- negative tests: setPenaltyToVoters() ---------

        // invalid percentage: 0    
        function test_EscrowedMocaAdminCannot_SetInvalidPenaltyToVoters_Zero() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidPercentage.selector);
            esMoca.setPenaltyToVoters(0);
            vm.stopPrank();
        }

        // invalid percentage: > 100%
        function test_EscrowedMocaAdminCannot_SetInvalidPenaltyToVoters_GreaterThan100() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidPercentage.selector);
            esMoca.setPenaltyToVoters(Constants.PRECISION_BASE + 1);
            vm.stopPrank();
        }

    // --------- positive tests: setPenaltyToVoters() ---------

        // total penalty is split 50% between voters and treasury
        function test_User1_CanRedeem_Quarter_WithOption1() public {
            // --- before balances & state ---
            uint256 redemptionAmount = user1Amount / 4;
            uint256 optionId = redemptionOption1_30Days;

            (uint128 lockDuration, uint128 receivablePct, bool isEnabled) = esMoca.redemptionOptions(optionId);

            uint256 esMocaBalBefore = esMoca.balanceOf(user1);
            uint256 totalSupplyBefore = esMoca.totalSupply();

            uint256 ACCRUED_PENALTY_TO_VOTERS_before = esMoca.ACCRUED_PENALTY_TO_VOTERS();
            uint256 ACCRUED_PENALTY_TO_TREASURY_before = esMoca.ACCRUED_PENALTY_TO_TREASURY();

            // Calculations
            uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
            uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;

            // With VOTERS_PENALTY_SPLIT set to 5000, the split should be 50/50 between voters and treasury
            uint256 expectedPenaltyToVoters = expectedPenalty * 5000 / Constants.PRECISION_BASE;
            uint256 expectedPenaltyToTreasury = expectedPenalty - expectedPenaltyToVoters;
            // Sanity check: should be equal for 50/50 split
            assertEq(expectedPenaltyToVoters, expectedPenaltyToTreasury, "Penalty split is not 50/50");


            vm.startPrank(user1);

                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);

                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.PenaltyAccrued(expectedPenaltyToVoters, expectedPenaltyToTreasury);

                esMoca.selectRedemptionOption(optionId, redemptionAmount);

            vm.stopPrank();


            // --- Assert ---
            assertEq(esMoca.balanceOf(user1), esMocaBalBefore - redemptionAmount, "user1 esMoca not deducted correctly");
            assertEq(esMoca.balanceOf(user1), user1Amount / 4, "user1 should have a quarter of esMoca redeemed, three-quarters left");

            assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "totalSupply should reflect burning");

            // Ensure penalty is tracked and split is 50/50
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), ACCRUED_PENALTY_TO_VOTERS_before + expectedPenaltyToVoters, "penalty to voters incorrect: not 50%");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), ACCRUED_PENALTY_TO_TREASURY_before + expectedPenaltyToTreasury, "penalty to treasury incorrect: not 50%");

            // Also ensure the split is exactly half of the penalty (for 50% split)
            assertEq(expectedPenaltyToVoters, expectedPenalty/2, "Voters penalty share is not half");
            assertEq(expectedPenaltyToTreasury, expectedPenalty/2, "Treasury penalty share is not half");

            // Redemption data stored
            (uint256 mocaReceivable, uint256 claimed, uint256 penalty) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
            assertEq(mocaReceivable, expectedMocaReceivable, "redemption schedule: mocaReceivable wrong");
            assertEq(claimed, 0, "redemption schedule: claimed should be 0");
            assertEq(penalty, expectedPenalty, "redemption schedule: penalty wrong");
        }
    
    // --------- state transition: disable redemption option ---------
        function test_UserCannot_DisableRedemptionOption() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByEscrowedMocaAdmin.selector);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, false);
            vm.stopPrank();
        }

        function test_EscrowedMocaAdminCan_DisableRedemptionOption() public {
            // Check pre-disable state (option should be enabled)
            (uint128 lockDuration, uint128 receivablePct, bool isEnabledBefore) = esMoca.redemptionOptions(redemptionOption1_30Days);
            assertTrue(isEnabledBefore, "Option should be enabled before disabling");

            // Expect event
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionOptionDisabled(redemptionOption1_30Days);

            // Disable option as admin
            vm.startPrank(escrowedMocaAdmin);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, false);
            vm.stopPrank();

            // Check post-disable state
            (, , bool isEnabledAfter) = esMoca.redemptionOptions(redemptionOption1_30Days);
            assertFalse(isEnabledAfter, "Option should be disabled after call");
        }
}


abstract contract StateT60Days_DisableRedemptionOption is StateT60Days_ChangePenaltySplit {

    function setUp() public virtual override {
        super.setUp();

        // disable redemption option
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, false);
        vm.stopPrank();
    }
}

contract StateT60Days_DisableRedemptionOption_Test is StateT60Days_DisableRedemptionOption {

    // --------- negative tests: selectRedemptionOption() ---------

        function testRevert_UserCannot_SelectRedemptionOption() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.RedemptionOptionAlreadyDisabled.selector);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, user1Amount/4);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_DisableRedemptionOptionAgain() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.RedemptionOptionAlreadyDisabled.selector);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, false);
            vm.stopPrank();
        }


    // --------- positive tests: setRedemptionOptionStatus() ---------
        function test_EscrowedMocaAdminCan_EnableRedemptionOption() public {
            // Check pre-enable state (option should be disabled)
            (, , bool isEnabledBefore) = esMoca.redemptionOptions(redemptionOption1_30Days);
            assertFalse(isEnabledBefore, "Option should be disabled before enabling");

            // Expect event
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionOptionEnabled(redemptionOption1_30Days, 5000, 30 days);

            // Enable option as admin
            vm.prank(escrowedMocaAdmin);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, true);
            
            // Check post-enable state
            (, , bool isEnabledAfter) = esMoca.redemptionOptions(redemptionOption1_30Days);
            assertTrue(isEnabledAfter, "Option should be enabled after call");
        }
}

abstract contract StateT60Days_EnableRedemptionOption is StateT60Days_DisableRedemptionOption {

    function setUp() public virtual override {
        super.setUp();

        // enable redemption option
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, true);
        vm.stopPrank();
    }
}

contract StateT60Days_EnableRedemptionOption_Test is StateT60Days_EnableRedemptionOption {
 
    // --------- positive tests: selectRedemptionOption() ---------
        function test_User1Can_SelectRedemptionOption1_30Days() public {
            uint256 amount = user1Amount / 4;
            uint256 optionPct = 5000; // per context: 50%
            uint256 lockDuration = 30 days;

            // --- before balances & state ---
            uint256 userEsMocaBalanceBefore = esMoca.balanceOf(user1);
            uint256 esMocaTotalSupplyBefore = esMoca.totalSupply();

            // user1's redemption schedule
            (uint256 mocaReceivableBefore, uint256 claimedBefore, uint256 penaltyBefore) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);

            uint256 totalMocaEscrowedBefore = esMoca.TOTAL_MOCA_ESCROWED();
            (,,bool isEnabled) = esMoca.redemptionOptions(redemptionOption1_30Days);
            assertTrue(isEnabled, "Redemption option should be enabled before selection");

            // Calculate expected
            uint256 expectedMocaReceivable = amount * optionPct / 10000;
            uint256 expectedPenalty = amount - expectedMocaReceivable;
            uint256 redemptionTimestamp = block.timestamp + lockDuration;

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, redemptionTimestamp);

            // User selects redemption option
            vm.startPrank(user1);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, amount);
            vm.stopPrank();

            // After-state checks
            uint256 userEsMocaBalanceAfter = esMoca.balanceOf(user1);
            uint256 esMocaTotalSupplyAfter = esMoca.totalSupply();
            (uint256 mocaReceivableAfter, uint256 claimedAfter, uint256 penaltyAfter) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);

            uint256 totalMocaEscrowedAfter = esMoca.TOTAL_MOCA_ESCROWED();

            // User esMOCA should decrease by amount
            assertEq(userEsMocaBalanceAfter, userEsMocaBalanceBefore - amount, "User esMOCA should decrease by amount");
            // Total supply should decrease by amount
            assertEq(esMocaTotalSupplyAfter, esMocaTotalSupplyBefore - amount, "Total supply should decrease by amount");
            // Moca receivable increased as expected
            assertEq(mocaReceivableAfter - mocaReceivableBefore, expectedMocaReceivable, "Moca receivable increased as expected");
            // Penalty booked
            assertEq(penaltyAfter - penaltyBefore, expectedPenalty, "Penalty booked as expected");
            // No moca claimed immediately for delayed redemption
            assertEq(claimedAfter, claimedBefore, "No moca claimed immediately for delayed redemption");
            // Escrowed MOCA unchanged yet (not claimed)
            assertEq(totalMocaEscrowedAfter, totalMocaEscrowedBefore, "TOTAL_MOCA_ESCROWED shouldn't be reduced until claim");
        }
}

/**
whitelist for transfers
risk

 */