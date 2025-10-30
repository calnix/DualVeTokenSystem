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
        assertEq(address(esMoca.accessController()), address(accessController), "accessController not set correctly");
        assertEq(address(esMoca.wMoca()), address(wMoca), "wMoca not set correctly");
        assertEq(esMoca.MOCA_TRANSFER_GAS_LIMIT(), 2300, "MOCA_TRANSFER_GAS_LIMIT not set correctly");
        assertEq(esMoca.VOTERS_PENALTY_SPLIT(), 1000, "VOTERS_PENALTY_SPLIT not set correctly");
        
        // erc20
        assertEq(esMoca.name(), "esMoca", "name not set correctly");
        assertEq(esMoca.symbol(), "esMoca", "symbol not set correctly");


        assertEq(esMoca.TOTAL_MOCA_ESCROWED(), 0);
    }

    function testRevert_ConstructorChecks() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new EscrowedMoca(address(0), 1000);

        vm.expectRevert(Errors.InvalidPercentage.selector);
        new EscrowedMoca(address(addressBook), 0);

        vm.expectRevert(Errors.InvalidPercentage.selector);
        new EscrowedMoca(address(addressBook), Constants.PRECISION_BASE + 1);
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

        // no penalties to claim
        function testRevert_AssetManagerCannot_ClaimPenalties_WhenZero() public {
            vm.expectRevert(Errors.InvalidAmount.selector);

            vm.prank(assetManager);
            esMoca.claimPenalties();
        }
    
    // --------- state transition: selectRedemptionOption() ---------

        function test_User1Can_SelectRedemptionOption_30Days() public {
            // Setup
            uint256 redemptionAmount = user1Amount / 2;
            uint256 optionId = redemptionOption1_30Days;
            (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(optionId);
            
            // Execute and verify
            {
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
                    emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);
                    
                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);
                    
                    esMoca.selectRedemptionOption(optionId, redemptionAmount);
                vm.stopPrank();
                
                // --- assert ---
                assertEq(esMoca.balanceOf(user1), esMocaBalBefore - redemptionAmount, "esMoca balance not decremented correctly");
                assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "esMoca totalSupply not decremented");
                assertEq(esMoca.TOTAL_MOCA_ESCROWED(), totalEscrowedBefore, "Escrowed MOCA shouldn't change until claim");
                assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), penaltyToVoters, "penaltyToVoters not accrued correctly");
                assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), penaltyToTreasury, "penaltyToTreasury not accrued correctly");
                assertEq(mockMoca.balanceOf(user1), mocaBalBefore, "MOCA balance should not increment until claimRedemption");
            }
            
            // Verify redemption schedule
            {
                uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
                uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
                
                (uint256 mocaReceivable, uint256 claimed, uint256 penalty) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
                assertEq(mocaReceivable, expectedMocaReceivable, "stored mocaReceivable incorrect");
                assertEq(claimed, 0, "claimed should be 0");
                assertEq(penalty, expectedPenalty, "penalty incorrect");
            }
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
    using stdStorage for StdStorage;

    // --------- negative tests: selectRedemptionOption() ---------

        function testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsZero() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, 0);
            vm.stopPrank();
        }

        function testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanBalance() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.InsufficientBalance.selector);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, user1Amount + 1);
            vm.stopPrank();
        }

        function testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanTotalEscrowed() public {
            
            // modify storage to set TOTAL_MOCA_ESCROWED to 1
            stdstore
                .target(address(esMoca))
                .sig("TOTAL_MOCA_ESCROWED()")
                .checked_write(uint256(0));

            assertTrue(esMoca.TOTAL_MOCA_ESCROWED() == 0);
            assertTrue(esMoca.TOTAL_MOCA_ESCROWED() < 10 ether);

            vm.startPrank(user3);
            vm.expectRevert(Errors.TotalMocaEscrowedExceeded.selector);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, 10 ether);
            vm.stopPrank();
        }

        // select redemption option that has not been setup: isEnabled = false
        function testRevert_UserCannot_SelectRedemptionOption_WhenRedemptionOptionIsDisabled() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.RedemptionOptionAlreadyDisabled.selector);
            esMoca.selectRedemptionOption(5, user1Amount/2);
            vm.stopPrank();
        }


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
        // Setup
        uint256 instantRedeemAmount = user3Amount / 2;
        (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(redemptionOption3_Instant);
        
        // Execute instant redemption
        {
            uint256 user3MocaBefore = mockMoca.balanceOf(user3);
            uint256 user3EsMocaBefore = esMoca.balanceOf(user3);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();
            
            uint256 expectedMocaReceivable = instantRedeemAmount * receivablePct / Constants.PRECISION_BASE;
            uint256 expectedPenalty = instantRedeemAmount - expectedMocaReceivable;
            
            uint256 penaltyToVoters = expectedPenalty * esMoca.VOTERS_PENALTY_SPLIT() / Constants.PRECISION_BASE;
            uint256 penaltyToTreasury = expectedPenalty - penaltyToVoters;
            
            // Event expectations
            vm.expectEmit(true, false, false, false, address(esMoca));
            emit Events.Redeemed(user3, expectedMocaReceivable, block.timestamp);
            
            vm.expectEmit(true, false, false, false, address(esMoca));
            emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);
            
            // Execute
            vm.prank(user3);
            esMoca.selectRedemptionOption(redemptionOption3_Instant, instantRedeemAmount);
            
            // Verify balances and state
            assertEq(mockMoca.balanceOf(user3), user3MocaBefore + expectedMocaReceivable, "MOCA balance should increase immediately by mocaReceivable");
            assertEq(esMoca.balanceOf(user3), user3EsMocaBefore - instantRedeemAmount, "esMoca balance should decrease by redeemed amount");
            assertEq(esMoca.totalSupply(), totalSupplyBefore - instantRedeemAmount, "totalSupply should decrease by redeemed amount");
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), TOTAL_MOCA_ESCROWED_before - expectedMocaReceivable, "TOTAL_MOCA_ESCROWED should decrease by mocaReceivable");
        }
        
        // Verify redemption schedule
        {
            uint256 expectedMocaReceivable = instantRedeemAmount * receivablePct / Constants.PRECISION_BASE;
            uint256 expectedPenalty = instantRedeemAmount - expectedMocaReceivable;
            
            (uint256 mocaReceivableAfter, uint256 claimedAfter, uint256 penaltyAfter) = esMoca.redemptionSchedule(user3, block.timestamp);
            assertEq(mocaReceivableAfter, expectedMocaReceivable, "mocaReceivable in schedule should equal amount received");
            assertEq(claimedAfter, expectedMocaReceivable, "claimed in redemptionSchedule should match mocaReceivable for instant");
            assertEq(penaltyAfter, expectedPenalty, "penalty should be stored in schedule");
        }
    }

    // --------- tests: claimPenalties() ---------

        function testRevert_UserCannot_ClaimPenalties() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByAssetManager.selector);
            esMoca.claimPenalties();
            vm.stopPrank();
        }

        function test_AssetManagerCan_ClaimPenalties() public {
            // Get before state
            uint256 assetManagerMocaBefore = mockMoca.balanceOf(assetManager);
            uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();
            
            // Verify penalties exist
            {
                uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();
                uint256 penaltyToVoters = esMoca.ACCRUED_PENALTY_TO_VOTERS();
                uint256 penaltyToTreasury = esMoca.ACCRUED_PENALTY_TO_TREASURY();
                
                assertTrue(totalClaimable > 0, "totalPenaltiesToClaim should be greater than 0");
                assertTrue(penaltyToVoters > 0, "penaltyToVoters should be greater than 0");
                assertTrue(penaltyToTreasury > 0, "penaltyToTreasury should be greater than 0");
                assertEq(esMoca.CLAIMED_PENALTY_FROM_TREASURY() + esMoca.CLAIMED_PENALTY_FROM_TREASURY(), 0);
                
                // Expect event emission
                vm.expectEmit(true, false, false, true, address(esMoca));
                emit Events.PenaltyClaimed(totalClaimable);
                
                // Claim penalties
                vm.prank(assetManager);
                esMoca.claimPenalties();
                
                // Verify after-state
                assertEq(mockMoca.balanceOf(assetManager), assetManagerMocaBefore + totalClaimable, "AssetManager should receive all penalties");
                assertEq(esMoca.TOTAL_MOCA_ESCROWED(), TOTAL_MOCA_ESCROWED_before - totalClaimable, "TOTAL_MOCA_ESCROWED should be decremented by totalClaimable");
            }
            
            // Verify penalties claimed state
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), esMoca.CLAIMED_PENALTY_FROM_VOTERS(), "penaltiesToClaim should be equal to accrued penalties");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), esMoca.CLAIMED_PENALTY_FROM_TREASURY(), "penaltiesToClaim should be equal to accrued penalties");
        }
}


abstract contract StateT30Days_UserOneHasRedemptionScheduled_PenaltiesAreClaimed is StateT0_UsersScheduleTheirRedemptions {

    function setUp() public virtual override {
        super.setUp();

        // fast forward to 30 days
        skip(30 days);

        // claim penalties
        vm.prank(assetManager);
        esMoca.claimPenalties();
    }
}


contract StateT30Days_UserOneHasRedemptionScheduled_Test is StateT30Days_UserOneHasRedemptionScheduled_PenaltiesAreClaimed {

    // --------- tests: claimPenalties() ---------

        function test_AssetManagerHas_ClaimedPenalties() public {
            uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();

            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), esMoca.CLAIMED_PENALTY_FROM_VOTERS());
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), esMoca.CLAIMED_PENALTY_FROM_TREASURY());

            assertEq(mockMoca.balanceOf(assetManager), totalClaimable);
        }

        function test_AssetManagerCannot_ClaimPenalties_WhenZero() public {
            vm.prank(assetManager);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.claimPenalties();
        }

    // --------- tests: releaseEscrowedMoca() ---------

        function testRevert_UserCannot_ReleaseEscrowedMoca() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByAssetManager.selector);
            esMoca.releaseEscrowedMoca(1);
            vm.stopPrank();
        }

        function testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenZero() public {
            vm.prank(assetManager);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.releaseEscrowedMoca(0);
        }

        function testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenInsufficientBalance() public {
            vm.prank(assetManager);
            vm.expectRevert(Errors.InsufficientBalance.selector);
            esMoca.releaseEscrowedMoca(1);
        }

        function test_AssetManagerCan_ReleaseEscrowedMoca() public {
            uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();
            assertEq(mockMoca.balanceOf(assetManager), totalClaimable);
            assertEq(esMoca.balanceOf(assetManager), 0);

            uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();

            // asset manager escrows moca
            vm.startPrank(assetManager);
                mockMoca.approve(address(esMoca), totalClaimable);
                esMoca.escrowMoca(totalClaimable);
            vm.stopPrank();

            // confirm asset manager has esMoca
            assertEq(esMoca.balanceOf(assetManager), totalClaimable);


            // release escrowed moca
            vm.startPrank(assetManager);
                // expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.EscrowedMocaReleased(assetManager, totalClaimable);

                esMoca.releaseEscrowedMoca(totalClaimable);
            vm.stopPrank();

            // confirm asset manager has moca
            assertEq(mockMoca.balanceOf(assetManager), totalClaimable);
            assertEq(esMoca.balanceOf(assetManager), 0);
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), TOTAL_MOCA_ESCROWED_before, "No change to TOTAL_MOCA_ESCROWED");
        }

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
    
    // --------- tests: escrowMocaOnBehalf() ---------

        function testRevert_UserCannot_EscrowMocaOnBehalf() public {
            // build array of users and amounts
            address[] memory users = new address[](1);
            users[0] = user1;
            
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;
            
            vm.prank(user1);
            vm.expectRevert(Errors.OnlyCallableByAssetManager.selector);
            esMoca.escrowMocaOnBehalf(users, amounts);
        }

        function testRevert_AssetManagerCannot_EscrowMocaOnBehalf_WhenMismatchedArrayLengths() public {
            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;


            vm.prank(assetManager);
            vm.expectRevert(Errors.MismatchedArrayLengths.selector);
            esMoca.escrowMocaOnBehalf(users, amounts);
        }

        function testRevert_AssetManagerCannot_EscrowMocaOnBehalf_WhenAmountIsZero() public {
            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 0 ether;

            vm.prank(assetManager);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.escrowMocaOnBehalf(users, amounts);
        }

        function testRevert_AssetManagerCannot_EscrowMocaOnBehalf_WhenUserIsZeroAddress() public {
            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = address(0);

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 1 ether;

            vm.prank(assetManager);
            vm.expectRevert(Errors.InvalidAddress.selector);
            esMoca.escrowMocaOnBehalf(users, amounts);
        }

        function test_AssetManagerCan_EscrowMocaOnBehalf() public {
            uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();
            assertEq(mockMoca.balanceOf(assetManager), totalClaimable);
            
            // capture before states
            uint256 TOTAL_MOCA_ESCROWED_before = esMoca.TOTAL_MOCA_ESCROWED();
            uint256 balanceOfUser1Before = esMoca.balanceOf(user1);
            uint256 balanceOfUser2Before = esMoca.balanceOf(user2);
            uint256 totalSupplyBefore = esMoca.totalSupply();

            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = totalClaimable/2;
            amounts[1] = totalClaimable/2;

            // escrowMocaOnBehalf
            vm.startPrank(assetManager);
                mockMoca.approve(address(esMoca), totalClaimable);

                // expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.StakedOnBehalf(users, amounts);

                esMoca.escrowMocaOnBehalf(users, amounts);
            vm.stopPrank();

            // Check: asset manager balances
            assertEq(mockMoca.balanceOf(assetManager), 0);
            assertEq(esMoca.balanceOf(assetManager), 0);

            // Check: contract state + user balances
            assertEq(esMoca.TOTAL_MOCA_ESCROWED(), TOTAL_MOCA_ESCROWED_before + totalClaimable);
            assertEq(esMoca.balanceOf(user1), balanceOfUser1Before + totalClaimable/2);
            assertEq(esMoca.balanceOf(user2), balanceOfUser2Before + totalClaimable/2);
            assertEq(esMoca.totalSupply(), totalSupplyBefore + totalClaimable);
        }
}

abstract contract StateT60Days_UserTwoHasRedemptionScheduled is StateT30Days_UserOneHasRedemptionScheduled_PenaltiesAreClaimed {

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
                
                // With VOTERS_PENALTY_SPLIT set to 5000, the split should be 50/50 between voters and treasury
                uint256 expectedPenaltyToVoters = expectedPenalty * 5000 / Constants.PRECISION_BASE;
                uint256 expectedPenaltyToTreasury = expectedPenalty - expectedPenaltyToVoters;
                
                // Sanity check: should be equal for 50/50 split
                assertEq(expectedPenaltyToVoters, expectedPenaltyToTreasury, "Penalty split is not 50/50");
                
                // Execute redemption
                vm.startPrank(user1);
                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);
                    
                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.PenaltyAccrued(expectedPenaltyToVoters, expectedPenaltyToTreasury);
                    
                    esMoca.selectRedemptionOption(optionId, redemptionAmount);
                vm.stopPrank();
                
                // --- Assert immediate effects ---
                assertEq(esMoca.balanceOf(user1), esMocaBalBefore - redemptionAmount, "user1 esMoca not deducted correctly");
                assertEq(esMoca.balanceOf(user1), user1Amount / 4, "user1 should have a quarter of esMoca redeemed, three-quarters left");
                assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "totalSupply should reflect burning");
                
                // Ensure penalty is tracked and split is 50/50
                assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), ACCRUED_PENALTY_TO_VOTERS_before + expectedPenaltyToVoters, "penalty to voters incorrect: not 50%");
                assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), ACCRUED_PENALTY_TO_TREASURY_before + expectedPenaltyToTreasury, "penalty to treasury incorrect: not 50%");
                
                // Also ensure the split is exactly half of the penalty (for 50% split)
                assertEq(expectedPenaltyToVoters, expectedPenalty/2, "Voters penalty share is not half");
                assertEq(expectedPenaltyToTreasury, expectedPenalty/2, "Treasury penalty share is not half");
            }
            
            // Block 2: Verify redemption schedule
            {
                uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
                uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
                
                (uint256 mocaReceivable, uint256 claimed, uint256 penalty) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
                assertEq(mocaReceivable, expectedMocaReceivable, "redemption schedule: mocaReceivable wrong");
                assertEq(claimed, 0, "redemption schedule: claimed should be 0");
                assertEq(penalty, expectedPenalty, "redemption schedule: penalty wrong");
            }
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
            // Setup
            uint256 amount = user1Amount / 4;
            uint256 optionPct = 5000; // per context: 50%
            uint256 lockDuration = 30 days;
            uint256 redemptionTimestamp = block.timestamp + lockDuration;
            
            // Verify option is enabled
            (,,bool isEnabled) = esMoca.redemptionOptions(redemptionOption1_30Days);
            assertTrue(isEnabled, "Redemption option should be enabled before selection");
            
            // Execute redemption
            {
                uint256 userEsMocaBalanceBefore = esMoca.balanceOf(user1);
                uint256 esMocaTotalSupplyBefore = esMoca.totalSupply();
                (uint256 mocaReceivableBefore, uint256 claimedBefore, uint256 penaltyBefore) = esMoca.redemptionSchedule(user1, redemptionTimestamp);
                uint256 totalMocaEscrowedBefore = esMoca.TOTAL_MOCA_ESCROWED();
                
                // Calculate expected
                uint256 expectedMocaReceivable = amount * optionPct / 10000;
                uint256 expectedPenalty = amount - expectedMocaReceivable;
                
                // Expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, redemptionTimestamp);
                
                // User selects redemption option
                vm.prank(user1);
                esMoca.selectRedemptionOption(redemptionOption1_30Days, amount);
                
                // After-state checks
                uint256 userEsMocaBalanceAfter = esMoca.balanceOf(user1);
                uint256 esMocaTotalSupplyAfter = esMoca.totalSupply();
                (uint256 mocaReceivableAfter, uint256 claimedAfter, uint256 penaltyAfter) = esMoca.redemptionSchedule(user1, redemptionTimestamp);
                uint256 totalMocaEscrowedAfter = esMoca.TOTAL_MOCA_ESCROWED();
                
                assertEq(userEsMocaBalanceAfter, userEsMocaBalanceBefore - amount, "User esMOCA should decrease by amount");
                assertEq(esMocaTotalSupplyAfter, esMocaTotalSupplyBefore - amount, "Total supply should decrease by amount");
                assertEq(mocaReceivableAfter - mocaReceivableBefore, expectedMocaReceivable, "Moca receivable increased as expected");
                assertEq(penaltyAfter - penaltyBefore, expectedPenalty, "Penalty booked as expected");
                assertEq(claimedAfter, claimedBefore, "No moca claimed immediately for delayed redemption");
                assertEq(totalMocaEscrowedAfter, totalMocaEscrowedBefore, "TOTAL_MOCA_ESCROWED shouldn't be reduced until claim");
            }
        }

    // --------- state transition: setWhitelistStatus() ---------

        function testRevert_UserCannot_SetWhitelistStatus() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByEscrowedMocaAdmin.selector);
            esMoca.setWhitelistStatus(user1, true);
            vm.stopPrank();
        }

        function testRevert_UserCannot_TransferEsMoca_NotWhitelisted() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByWhitelistedAddress.selector);
            esMoca.transfer(user2, user1Amount / 4);
            vm.stopPrank();
        }

        function test_EscrowedMocaAdminCan_SetWhitelistStatus() public {
            // Check before-state: user1 should NOT be whitelisted
            assertFalse(esMoca.whitelist(user1), "user1 should not be whitelisted before");

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.AddressWhitelisted(user1, true);

            // Set whitelist
            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(user1, true);
            vm.stopPrank();

            // Check after-state: user2 should now be whitelisted
            assertTrue(esMoca.whitelist(user1), "user1 should be whitelisted after");
        }
}

// note: whitelist user1
abstract contract StateT60Days_SetWhitelistStatus is StateT60Days_EnableRedemptionOption {
    function setUp() public virtual override {
        super.setUp();

        // set whitelist status
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(user1, true);
        vm.stopPrank();
    }
}

contract StateT60Days_SetWhitelistStatus_Test is StateT60Days_SetWhitelistStatus {

    // --------- negative tests: setWhitelistStatus() ---------
        function testRevert_EscrowedMocaAdminCannot_SetWhitelistStatus_ZeroAddress() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidAddress.selector);
            esMoca.setWhitelistStatus(address(0), true);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdmin_WhitelistStatusUnchanged() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.WhitelistStatusUnchanged.selector);
            esMoca.setWhitelistStatus(user1, true);
            vm.stopPrank();
        }

    // --------- positive tests: setWhitelistStatus() ---------

        function test_EscrowedMocaAdminCan_SetWhitelistStatus_ToFalse() public {
            // Check before-state: user1 should be whitelisted
            assertTrue(esMoca.whitelist(user1), "user1 should be whitelisted before");

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.AddressWhitelisted(user1, false);

            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(user1, false);
            vm.stopPrank();

            // Check after-state: user1 should not be whitelisted
            assertFalse(esMoca.whitelist(user1), "user1 should not be whitelisted after");
        }

    // --------- whitelisted user can transfer() esMoca to other addresses ---------
        function test_User1Can_TransferEsMocaToUser2() public {
            uint256 beforeUser1 = esMoca.balanceOf(user1);
            uint256 beforeUser2 = esMoca.balanceOf(user2);
            uint256 transferAmount = user1Amount / 4;

            vm.startPrank(user1);
            esMoca.transfer(user2, transferAmount);
            vm.stopPrank();

            // Check after-state: User2 should have received the transferred amount
            assertEq(esMoca.balanceOf(user2), beforeUser2 + transferAmount, "user2 should have received transferred esMoca");
            // Check after-state: User1's balance should have decreased by the transfer amount
            assertEq(esMoca.balanceOf(user1), beforeUser1 - transferAmount, "user1's esMoca should decrease by transfer amount");
        }

    // --------- whitelisted user can transferFrom() esMoca to other addresses ---------

        function testRevert_User2_CannotCallTransferFromEsMoca_NotWhitelisted() public {
            uint256 transferAmount = user1Amount / 4;

            vm.startPrank(user2);
            vm.expectRevert(Errors.OnlyCallableByWhitelistedAddress.selector);
            esMoca.transferFrom(user1, user2, transferAmount);
            vm.stopPrank();
        }

        function test_User1Can_TransferFromEsMocaToUser2_Whitelisted() public {
            uint256 beforeUser1 = esMoca.balanceOf(user1);
            uint256 beforeUser2 = esMoca.balanceOf(user2);
            uint256 transferAmount = user1Amount / 4;

            // 1. whitelist user2 so he can call transferFrom
            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(user2, true);
            vm.stopPrank();

            // 2. user1 approves user2 to spend their tokens
            vm.startPrank(user1);
            esMoca.approve(user2, transferAmount);
            vm.stopPrank();

            // 3. user2 calls transferFrom to transfer from user1 to user2
            vm.startPrank(user2);
            esMoca.transferFrom(user1, user2, transferAmount);
            vm.stopPrank();

            // Check after-state: User2 should have received the transferred amount
            assertEq(esMoca.balanceOf(user2), beforeUser2 + transferAmount, "user2 should have received transferred esMoca");
            // Check after-state: User1's balance should have decreased by the transfer amount
            assertEq(esMoca.balanceOf(user1), beforeUser1 - transferAmount, "user1's esMoca should decrease by transfer amount");
        }

    // --------- state transition: pause() ---------
        function testRevert_UserCannot_Pause() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByMonitor.selector);
            esMoca.pause();
            vm.stopPrank();
        }
        
        function testRevert_GlobalAdminCannot_Freeze_WhenContractIsNotPaused() public {
            vm.startPrank(globalAdmin);
            vm.expectRevert(Pausable.ExpectedPause.selector);
            esMoca.freeze();
            vm.stopPrank();
        }

        function test_MonitorCan_Pause() public {
            vm.startPrank(monitor);
            esMoca.pause();
            vm.stopPrank();

            assertEq(esMoca.paused(), true);
        }
}

abstract contract StateT60Days_Paused is StateT60Days_SetWhitelistStatus {

    function setUp() public virtual override {
        super.setUp();

        // pause
        vm.startPrank(monitor);
            esMoca.pause();
        vm.stopPrank();
    }
}


contract StateT60Days_Paused_Test is StateT60Days_Paused {

    function testRevert_MonitorCannot_Pause_WhenContractIsPaused() public {
        vm.startPrank(monitor);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        esMoca.pause();
        vm.stopPrank();
    }

    // --------- negative tests: normal functions cannot be called when contract is paused ---------

        function testRevert_UserCannot_EscrowMoca_WhenPaused() public {
            uint256 amount = 100 ether;
            mockMoca.mint(user1, amount);
            
            vm.startPrank(user1);
            mockMoca.approve(address(esMoca), amount);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.escrowMoca(amount);
            vm.stopPrank();
        }

        function testRevert_UserCannot_SelectRedemptionOption_WhenPaused() public {
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.selectRedemptionOption(redemptionOption2_60Days, 50 ether);
            vm.stopPrank();
        }

        function testRevert_UserCannot_ClaimRedemption_WhenPaused() public {
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.claimRedemption(block.timestamp + 60 days);
            vm.stopPrank();
        }

        function testRevert_AssetManagerCannot_EscrowMocaOnBehalf_WhenPaused() public {
            address[] memory users = new address[](1);
            users[0] = user2;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100 ether;
            
            mockMoca.mint(assetManager, 100 ether);
            
            vm.startPrank(assetManager);
            mockMoca.approve(address(esMoca), 100 ether);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.escrowMocaOnBehalf(users, amounts);
            vm.stopPrank();
        }

        function testRevert_AssetManagerCannot_ClaimPenalties_WhenPaused() public {
            vm.startPrank(assetManager);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.claimPenalties();
            vm.stopPrank();
        }

        function testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenPaused() public {
            vm.startPrank(assetManager);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.releaseEscrowedMoca(50 ether);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetPenaltyToVoters_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.setPenaltyToVoters(2000);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetRedemptionOption_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.setRedemptionOption(4, 90 days, 7500);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetRedemptionOptionStatus_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.setRedemptionOptionStatus(redemptionOption1_30Days, false);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetWhitelistStatus_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.setWhitelistStatus(user2, true);
            vm.stopPrank();
        }


        function testRevert_User1Cannot_Transfer_WhenPaused() public {
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.transfer(user2, 50 ether);
            vm.stopPrank();
        }

        function testRevert_UserCannot_TransferFrom_WhenPaused() public {
            // Setup: user1 approves user2 to spend their tokens
            vm.startPrank(user1);
            esMoca.approve(user2, 50 ether);
            vm.stopPrank();

            vm.startPrank(user2);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.transferFrom(user1, user2, 50 ether);
            vm.stopPrank();
        }

    // --------- negative tests: unpause() ---------
        function test_MonitorCannot_Unpause() public {
            vm.startPrank(monitor);
            vm.expectRevert(Errors.OnlyCallableByGlobalAdmin.selector);
            esMoca.unpause();
            vm.stopPrank();
        }

        function test_MonitorCannot_PauseAgain() public {
            vm.startPrank(monitor);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.pause();
            vm.stopPrank();
        }
        
    // --------- positive tests: unpause() ---------
        function test_GlobalAdminCan_Unpause() public {
            assertEq(esMoca.paused(), true);
            assertEq(esMoca.isFrozen(), 0);

            vm.startPrank(globalAdmin);
            esMoca.unpause();
            vm.stopPrank();

            assertEq(esMoca.paused(), false);
        }

    // --------- state transition: freeze() ---------


        // Test emergencyExit when contract is not frozen (should revert)
        function testRevert_EmergencyExitHandlerCannot_EmergencyExit_WhenNotFrozen() public {
            // Try emergency exit when not frozen
            vm.prank(emergencyExitHandler);
            vm.expectRevert(Errors.NotFrozen.selector);
            esMoca.emergencyExit();
        }

        function test_GlobalAdminCan_Freeze() public {
            assertEq(esMoca.paused(), true);
            assertEq(esMoca.isFrozen(), 0);

            vm.startPrank(globalAdmin);
            esMoca.freeze();
            vm.stopPrank();

            assertEq(esMoca.paused(), true);
            assertEq(esMoca.isFrozen(), 1);
        }
}

abstract contract StateT60Days_Frozen is StateT60Days_Paused {
    function setUp() public virtual override {
        super.setUp();

        // freeze
        vm.startPrank(globalAdmin);
            esMoca.freeze();
        vm.stopPrank();
    }
}

contract StateT60Days_Frozen_Test is StateT60Days_Frozen {
    
    // --------- negative tests: unpause() + freeze() + pause() ---------
        function testRevert_GlobalAdminCannot_Unpause_WhenContractIsFrozen() public {
            vm.startPrank(globalAdmin);
            vm.expectRevert(Errors.IsFrozen.selector);
            esMoca.unpause();
            vm.stopPrank();
        }

        function testRevert_GlobalAdminCannot_Freeze_WhenContractIsFrozen() public {
            vm.startPrank(globalAdmin);
            vm.expectRevert(Errors.IsFrozen.selector);
            esMoca.freeze();
            vm.stopPrank();
        }
        
    // --------- tests: emergencyExit() ---------

    function testRevert_NonEmergencyExitHandlerCannot_EmergencyExit() public {
        vm.prank(user1); 
        vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandler.selector);
        esMoca.emergencyExit();
    }

    // Test emergencyExit when treasury is zero address
    function testRevert_EmergencyExitHandlerCannot_EmergencyExit_WhenTreasuryIsZero() public {
        // Mock addressBook to return zero address for treasury
        vm.mockCall(address(addressBook), abi.encodeWithSelector(IAddressBook.getTreasury.selector), abi.encode(address(0)));
        
        vm.prank(emergencyExitHandler);
        vm.expectRevert(Errors.InvalidAddress.selector);
        esMoca.emergencyExit();
    }
    
    function test_EmergencyExitHandlerCan_EmergencyExit_WhenFrozen() public {
        // Setup: ensure contract has some MOCA tokens
        uint256 mocaBalanceBefore = mockMoca.balanceOf(address(esMoca));
        uint256 treasuryBalanceBefore = mockMoca.balanceOf(treasury);
        
        // Verify contract is frozen
        assertEq(esMoca.isFrozen(), 1);
        
        // Expect event emission
        vm.expectEmit(true, true, false, true, address(esMoca));
        emit Events.EmergencyExit(treasury);
        
        // Execute emergency exit
        vm.prank(emergencyExitHandler);
        esMoca.emergencyExit();
        
        // Verify all MOCA transferred to treasury
        assertEq(mockMoca.balanceOf(address(esMoca)), 0);
        assertEq(mockMoca.balanceOf(treasury), treasuryBalanceBefore + mocaBalanceBefore);
        assertEq(esMoca.TOTAL_MOCA_ESCROWED(), 0);
    }
}