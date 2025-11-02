// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

import "../utils/TestingHarness.sol";

abstract contract StateT0_Deploy is TestingHarness {    

    function setUp() public virtual override {
        super.setUp();
    }
}

contract StateT0_Deploy_Test is StateT0_Deploy {

    function test_Constructor() public {
        assertEq(address(esMoca.accessController()), address(accessController), "accessController not set correctly");
        assertEq(address(esMoca.WMOCA()), address(mockWMoca), "WMOCA not set correctly");
        assertEq(esMoca.MOCA_TRANSFER_GAS_LIMIT(), 2300, "MOCA_TRANSFER_GAS_LIMIT not set correctly");
        assertEq(esMoca.VOTERS_PENALTY_PCT(), 1000, "VOTERS_PENALTY_PCT not set correctly");
        
        // erc20
        assertEq(esMoca.name(), "esMoca", "name not set correctly");
        assertEq(esMoca.symbol(), "esMOCA", "symbol not set correctly");
    }

    function testRevert_ConstructorChecks() public {
        // accessController: static check
        vm.expectRevert();
        new EscrowedMoca(address(0), 1000, address(mockWMoca), 2300);

        // votersPenaltyPct > 100%
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new EscrowedMoca(address(accessController), Constants.PRECISION_BASE + 1, address(mockWMoca), 2300);

        //wMoca: invalid address
        vm.expectRevert(Errors.InvalidAddress.selector);
        new EscrowedMoca(address(accessController), 1000, address(0), 2300);

        // mocaTransferGasLimit < 2300
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        new EscrowedMoca(address(accessController), 1000, address(mockWMoca), 2300 - 1);
    }

    function testRevert_CannotEscrowZeroMoca_InvalidAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        esMoca.escrowMoca{value: 0}();
    }

    // state transition: escrow moca
    function testCan_User_EscrowMoca() public {
        // setup: deal native MOCA to user
        uint256 amount = 100 ether;
        vm.deal(user1, amount);

        // --- before balances & state ---
        // user
        uint256 beforeUserMoca = user1.balance;
        uint256 beforeUserEsMoca = esMoca.balanceOf(user1);
        // contract
        uint256 beforeTotalSupply = esMoca.totalSupply();
        uint256 beforeContractMoca = address(esMoca).balance;

        // escrow native MOCA via msg.value
        vm.startPrank(user1);
            // event
            vm.expectEmit(true, true, true, true, address(esMoca));
            emit Events.EscrowedMoca(user1, amount);

            esMoca.escrowMoca{value: amount}();
        vm.stopPrank();

        // --- after balances & state ---
        // user
        uint256 afterUserMoca = user1.balance;
        uint256 afterUserEsMoca = esMoca.balanceOf(user1);
        // contract
        uint256 afterTotalSupply = esMoca.totalSupply();
        uint256 afterContractMoca = address(esMoca).balance;

        // User: esMoca + moca
        assertEq(afterUserEsMoca, beforeUserEsMoca + amount, "User: esMoca not minted correctly");
        assertEq(afterUserMoca, beforeUserMoca - amount, "User: MOCA not transferred from user");

        // Contract: esMoca totalSupply + moca
        assertEq(afterTotalSupply, beforeTotalSupply + amount, "Contract: esMoca totalSupply not incremented correctly");
        assertEq(afterContractMoca, beforeContractMoca + amount, "Contract: native MOCA balance not incremented correctly");
        assertEq(afterTotalSupply, afterContractMoca, "Contract: esMoca totalSupply should be equal to native MOCA balance");
    }
}

// note: all users escrow native MOCA
abstract contract StateT0_EscrowedMoca is StateT0_Deploy {

    uint256 user1Amount = 100 ether;
    uint256 user2Amount = 200 ether;
    uint256 user3Amount = 300 ether;

    function setUp() public virtual override {
        super.setUp();


        // setup: deal native MOCA to users
        vm.deal(user1, user1Amount);
        vm.deal(user2, user2Amount);
        vm.deal(user3, user3Amount);

        // escrow native MOCA
        vm.startPrank(user1);
        esMoca.escrowMoca{value: user1Amount}();
        vm.stopPrank();

        vm.startPrank(user2);
        esMoca.escrowMoca{value: user2Amount}();
        vm.stopPrank();

        vm.startPrank(user3);
        esMoca.escrowMoca{value: user3Amount}();
        vm.stopPrank();
    }
}

contract StateT0_EscrowedMoca_Test is StateT0_EscrowedMoca {

    function testRevert_EscrowedMoca_InvalidAmount() public {
        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user1);
        esMoca.escrowMoca{value: 0}();
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

        // > 100% receivablePct
        function testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidPercentage() public {
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(escrowedMocaAdmin);
            esMoca.setRedemptionOption(1, 30 days, uint128(Constants.PRECISION_BASE + 1)); 
        }

        // 0% receivablePct
        function testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidPercentage_0() public {
            vm.expectRevert(Errors.InvalidPercentage.selector);
            vm.prank(escrowedMocaAdmin);
            esMoca.setRedemptionOption(1, 30 days, 0); 
        }    

        // lock duration must be <= 888 days
        function testRevert_EscrowedMocaAdmin_SetRedemptionOption_InvalidLockDuration() public {
            vm.expectRevert(Errors.InvalidLockDuration.selector);
            vm.prank(escrowedMocaAdmin);
            esMoca.setRedemptionOption(1, 889 days, 5_000); // 889 days lock duration
        }

        // no penalties to claim
        function testRevert_AssetManagerCannot_ClaimPenalties_WhenZero() public {
            vm.expectRevert(Errors.NothingToClaim.selector);

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
                uint256 mocaBalBefore = user1.balance;
                uint256 totalSupplyBefore = esMoca.totalSupply();
                uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
                // penalties before
                uint256 ACCRUED_PENALTY_TO_VOTERS_before = esMoca.ACCRUED_PENALTY_TO_VOTERS();
                uint256 ACCRUED_PENALTY_TO_TREASURY_before = esMoca.ACCRUED_PENALTY_TO_TREASURY();

                
                // calculation for receivable/penalty
                uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
                uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
                
                // calculate penalty amount
                uint256 penaltyToVoters = expectedPenalty * esMoca.VOTERS_PENALTY_PCT() / Constants.PRECISION_BASE;
                uint256 penaltyToTreasury = expectedPenalty - penaltyToVoters;
                
                // --- redeem ---
                vm.startPrank(user1);               
    
                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);

                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);
                    
                    esMoca.selectRedemptionOption{value: 0}(optionId, redemptionAmount);
                vm.stopPrank();
                
                // --- assert ---
                // esMoca: balance & totalSupply should decrement
                assertEq(esMoca.balanceOf(user1), esMocaBalBefore - redemptionAmount, "esMoca balance not decremented correctly");
                assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "esMoca totalSupply not decremented");
                
                // pending: TOTAL_MOCA_PENDING_REDEMPTION & userTotalMocaPendingRedemption should increment
                assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before + expectedMocaReceivable, "TOTAL_MOCA_PENDING_REDEMPTION should increment");
                assertEq(esMoca.userTotalMocaPendingRedemption(user1), expectedMocaReceivable, "userTotalMocaPendingRedemption not incremented correctly");

                // penalties should increment
                assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), ACCRUED_PENALTY_TO_VOTERS_before + penaltyToVoters, "penaltyToVoters not accrued correctly");
                assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), ACCRUED_PENALTY_TO_TREASURY_before + penaltyToTreasury, "penaltyToTreasury not accrued correctly");
                
                // user: moca should not increment
                assertEq(user1.balance, mocaBalBefore, "MOCA balance should not increment until claimRedemption");
            }
            
            // Verify redemption schedule
            {
                uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
                uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
                
                (uint256 mocaReceivable, uint256 penalty, uint256 claimed) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
                assertEq(mocaReceivable, expectedMocaReceivable, "stored mocaReceivable incorrect");
                assertEq(claimed, 0, "claimed should be 0");
                assertEq(penalty, expectedPenalty, "penalty incorrect");
            }
        }

        // note: user2 schedules a 60 day redemption: no penalties [PenaltyAccrued not emitted]
        function test_User2Can_SelectRedemptionOption_60Days() public {
            // --- Setup ---
            uint256 redemptionAmount = user2Amount;
            uint256 optionId = redemptionOption2_60Days;
            // Get redemption option params
            (uint128 lockDuration, uint128 receivablePct, bool isEnabled) = esMoca.redemptionOptions(optionId);

            // Before state: balances + burn
            uint256 esMocaBalBefore = esMoca.balanceOf(user2);
            uint256 mocaBalBefore = user2.balance;
            // esMoca totalSupply before
            uint256 totalSupplyBefore = esMoca.totalSupply();
            // pending redemption before
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            // penalties before
            uint256 ACCRUED_PENALTY_TO_VOTERS_before = esMoca.ACCRUED_PENALTY_TO_VOTERS();
            uint256 ACCRUED_PENALTY_TO_TREASURY_before = esMoca.ACCRUED_PENALTY_TO_TREASURY();

            // calculation for receivable/penalty
            uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
            uint256 expectedPenalty = redemptionAmount - expectedMocaReceivable;
            
            // calculate penalty amount
            uint256 penaltyToVoters = expectedPenalty * esMoca.VOTERS_PENALTY_PCT() / Constants.PRECISION_BASE;
            uint256 penaltyToTreasury = expectedPenalty - penaltyToVoters;
            

            // --- redeem ---
            vm.startPrank(user2);

                // event emission for redemption scheduled
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user2, redemptionAmount, 0, block.timestamp + lockDuration);

                // full redemption with no penalty | 60 days lock
                esMoca.selectRedemptionOption{value: 0}(optionId, redemptionAmount); 

            vm.stopPrank();

            // --- assert ---

            // esMoca: balance & totalSupply should decrement
            assertEq(esMoca.balanceOf(user2), esMocaBalBefore - redemptionAmount, "esMoca balance not decremented correctly");
            assertEq(esMoca.totalSupply(), totalSupplyBefore - redemptionAmount, "esMoca totalSupply not decremented");

            // pending: TOTAL_MOCA_PENDING_REDEMPTION & userTotalMocaPendingRedemption should increment
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before + redemptionAmount, "TOTAL_MOCA_PENDING_REDEMPTION should increment");
            assertEq(esMoca.userTotalMocaPendingRedemption(user2), redemptionAmount, "userTotalMocaPendingRedemption not incremented correctly");

            // Penalty accrued: 0 because no penalty
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), ACCRUED_PENALTY_TO_VOTERS_before, "penaltyToVoters not accrued correctly");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), ACCRUED_PENALTY_TO_TREASURY_before, "penaltyToTreasury not accrued correctly");

            // Moca not received yet
            assertEq(user2.balance, mocaBalBefore, "MOCA balance should not increment until claimRedemption");

            // Redemption schedule created for user2 
            (uint256 mocaReceivable, uint256 penalty, uint256 claimed) = esMoca.redemptionSchedule(user2, block.timestamp + lockDuration);
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
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, user1Amount / 2);
        vm.stopPrank();

        // user2 schedules a redemption: penalties booked + redemption scheduled
        vm.startPrank(user2);
            esMoca.selectRedemptionOption{value: 0}(redemptionOption2_60Days, user2Amount);
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
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, 0);
            vm.stopPrank();
        }

        function testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanBalance() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.InsufficientBalance.selector);
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, user1Amount + 1);
            vm.stopPrank();
        }

        // invariant check
        function testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanTotalSupply() public {
            
            // modify storage to set totalSupply to 1
            stdstore
                .target(address(esMoca))
                .sig("totalSupply()")
                .checked_write(uint256(0));

            assertTrue(esMoca.totalSupply() == 0);
            assertTrue(esMoca.totalSupply() < 10 ether);

            vm.startPrank(user3);
            vm.expectRevert(Errors.TotalMocaEscrowedExceeded.selector);
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, 10 ether);
            vm.stopPrank();
        }

        // select redemption option that has not been setup: isEnabled = false
        function testRevert_UserCannot_SelectRedemptionOption_WhenRedemptionOptionIsDisabled() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.RedemptionOptionAlreadyDisabled.selector);
            esMoca.selectRedemptionOption{value: 0}(5, user1Amount/2);
            vm.stopPrank();
        }


    // --------- negative tests: claimRedemptions() ---------

        function testRevert_User1Cannot_ClaimRedemptions_EmptyArray() public {
            uint256[] memory timestamps = new uint256[](0);

            vm.startPrank(user1);
                vm.expectRevert(Errors.InvalidArray.selector);
                esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
        }

        function testRevert_User1Cannot_ClaimRedemptions_Before30Days() public {
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp + 30 days;

            vm.startPrank(user1);
                vm.expectRevert(Errors.InvalidTimestamp.selector);
                esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
        }


        function testRevert_User3_NoRedemptionsScheduled_NothingToClaim() public {
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp;

            vm.startPrank(user3);
                vm.expectRevert(Errors.NothingToClaim.selector);
                esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
        }

    // --------- positive test: claimRedemptions() for instant redemption ---------

    function test_User3Can_RedeemInstant_ReceivesMocaImmediately() public {
        // Setup
        uint256 instantRedeemAmount = user3Amount / 2;
        (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(redemptionOption3_Instant);

        // Execute instant redemption
        {
            // balances before
            uint256 user3MocaBefore = user3.balance;
            uint256 user3EsMocaBefore = esMoca.balanceOf(user3);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 contractMocaBefore = address(esMoca).balance;
            // pending before
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            uint256 userTotalMocaPendingRedemption_before = esMoca.userTotalMocaPendingRedemption(user3);
            // penalties before
            uint256 ACCRUED_PENALTY_TO_VOTERS_before = esMoca.ACCRUED_PENALTY_TO_VOTERS();
            uint256 ACCRUED_PENALTY_TO_TREASURY_before = esMoca.ACCRUED_PENALTY_TO_TREASURY();

            // calculation for receivable/penalty
            uint256 expectedMocaReceivable = instantRedeemAmount * receivablePct / Constants.PRECISION_BASE;
            uint256 expectedPenalty = instantRedeemAmount - expectedMocaReceivable;
            // calculate penalty amount
            uint256 penaltyToVoters = expectedPenalty * esMoca.VOTERS_PENALTY_PCT() / Constants.PRECISION_BASE;
            uint256 penaltyToTreasury = expectedPenalty - penaltyToVoters;

            // Event expectations
            //vm.expectEmit(true, true, false, true, address(esMoca));
            //emit IERC20.Transfer(user3, address(0), expectedMocaReceivable);

            vm.expectEmit(true, false, false, false, address(esMoca));
            emit Events.PenaltyAccrued(penaltyToVoters, penaltyToTreasury);


            vm.expectEmit(true, false, false, false, address(esMoca));
            emit Events.Redeemed(user3, expectedMocaReceivable, block.timestamp);

            // Execute
            vm.prank(user3);
            esMoca.selectRedemptionOption{value: 0}(redemptionOption3_Instant, instantRedeemAmount);

            // --- assert ---
            
            // esMoca: balance & totalSupply should decrement
            assertEq(esMoca.balanceOf(user3), user3EsMocaBefore - instantRedeemAmount, "esMoca balance should decrease by redeemed amount");
            assertEq(esMoca.totalSupply(), totalSupplyBefore - instantRedeemAmount, "totalSupply should decrease by redeemed amount");
            
            // pending: TOTAL_MOCA_PENDING_REDEMPTION & userTotalMocaPendingRedemption should increment
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before, "TOTAL_MOCA_PENDING_REDEMPTION should NOT increment");
            assertEq(esMoca.userTotalMocaPendingRedemption(user3), 0, "userTotalMocaPendingRedemption should be 0");

            // penalties should increment
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), ACCRUED_PENALTY_TO_VOTERS_before + penaltyToVoters, "penaltyToVoters not accrued correctly");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), ACCRUED_PENALTY_TO_TREASURY_before + penaltyToTreasury, "penaltyToTreasury not accrued correctly");

            // user: moca balance should increment
            assertEq(user3.balance, user3MocaBefore + expectedMocaReceivable, "MOCA balance should increase immediately by mocaReceivable");
            // contract: MOCA should decrease by amount sent out
            assertEq(address(esMoca).balance, contractMocaBefore - expectedMocaReceivable, "Contract MOCA should decrease by mocaReceivable");
        }

        // Verify redemption schedule
        {
            uint256 expectedMocaReceivable = instantRedeemAmount * receivablePct / Constants.PRECISION_BASE;
            uint256 expectedPenalty = instantRedeemAmount - expectedMocaReceivable;

            (uint256 mocaReceivableAfter, uint256 penaltyAfter, uint256 claimedAfter) = esMoca.redemptionSchedule(user3, block.timestamp);
            assertEq(mocaReceivableAfter, expectedMocaReceivable, "mocaReceivable in schedule should equal amount received");
            assertEq(claimedAfter, expectedMocaReceivable, "claimed in redemptionSchedule should match mocaReceivable for instant");
            assertEq(penaltyAfter, expectedPenalty, "penalty should be stored in schedule");

            assertEq(mocaReceivableAfter, claimedAfter, "mocaReceivable should be equal to claimed");
        }
    }

    // --------- positive test: claimRedemptions() for multiple timestamps ---------

    function test_UserCan_ClaimRedemptions_MultipleTimestamps() public {
        // Get lock duration for the redemption option
        (uint128 lockDuration,,) = esMoca.redemptionOptions(redemptionOption1_30Days);
        
        // --- Setup: user1 creates multiple redemptions ---
        vm.startPrank(user1);
            uint256 amount1 = user1Amount / 4; 
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, amount1);
            // Store the redemption timestamp
            uint256 timestamp1 = block.timestamp + lockDuration; 
        
            skip(1 days);
            uint256 amount2 = user1Amount / 4;
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, amount2);
            // Store the redemption timestamp
            uint256 timestamp2 = block.timestamp + lockDuration; 
        vm.stopPrank();

        // Fast forward to when both are claimable (warp to when second one is claimable)
        skip(timestamp2 + 1);
        
        // --- Calculate total claimable ---
        (uint256 mocaReceivable1,,) = esMoca.redemptionSchedule(user1, timestamp1);
        (uint256 mocaReceivable2,,) = esMoca.redemptionSchedule(user1, timestamp2);
        uint256 totalClaimable = mocaReceivable1 + mocaReceivable2;
        
        // --- Before state ---
        uint256 user1BalanceBefore = user1.balance;
        uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
        uint256 totalSupplyBefore = esMoca.totalSupply();
        uint256 userTotalMocaPendingRedemption_before = esMoca.userTotalMocaPendingRedemption(user1);
    
        // create array of timestamps to claim
        uint256[] memory timestamps = new uint256[](2);
            timestamps[0] = timestamp1;
            timestamps[1] = timestamp2;

        // --- Events ---
        vm.expectEmit(true, true, false, true, address(esMoca));
        emit Events.RedemptionsClaimed(user1, timestamps, totalClaimable);

        // --- Execute ---
        vm.prank(user1);
        esMoca.claimRedemptions{value: 0}(timestamps);

        // --- After state ---
        assertEq(user1.balance, user1BalanceBefore + totalClaimable, "User should receive both redemptions");
        assertEq(esMoca.totalSupply(), totalSupplyBefore, "totalSupply unchanged");
        assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - totalClaimable, "Pending redemptions should be decremented");
        assertEq(esMoca.userTotalMocaPendingRedemption(user1), userTotalMocaPendingRedemption_before - totalClaimable, "userTotalMocaPendingRedemption should be decremented");
    }

    // --------- tests: claimPenalties() ---------

        function testRevert_UserCannot_ClaimPenalties() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByAssetManager.selector);
            esMoca.claimPenalties();
            vm.stopPrank();
        }

        function test_AssetManagerCan_ClaimPenalties_AssetsSentToTreasury() public {
            // Get before state
            uint256 esMocaTreasuryMocaBefore = esMocaTreasury.balance;
            uint256 contractMocaBefore = address(esMoca).balance;
            
            // Verify penalties exist
            {
                uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();
                uint256 penaltyToVoters = esMoca.ACCRUED_PENALTY_TO_VOTERS();
                uint256 penaltyToTreasury = esMoca.ACCRUED_PENALTY_TO_TREASURY();
                
                assertTrue(totalClaimable > 0, "totalPenaltiesToClaim should be greater than 0");
                assertTrue(penaltyToVoters > 0, "penaltyToVoters should be greater than 0");
                assertTrue(penaltyToTreasury > 0, "penaltyToTreasury should be greater than 0");
                assertEq(esMoca.CLAIMED_PENALTY_FROM_VOTERS() + esMoca.CLAIMED_PENALTY_FROM_TREASURY(), 0);
                
                // Expect event emission
                vm.expectEmit(true, false, false, true, address(esMoca));
                emit Events.PenaltyClaimed(esMocaTreasury, totalClaimable);
                
                // Claim penalties
                vm.prank(assetManager);
                esMoca.claimPenalties();
                
                // Verify after-state
                assertEq(esMocaTreasury.balance, esMocaTreasuryMocaBefore + totalClaimable, "Treasury should receive all penalties");
                assertEq(address(esMoca).balance, contractMocaBefore - totalClaimable, "Contract MOCA should be decremented by totalClaimable");
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

        function test_AssetManagerHas_ClaimedPenalties_AssetsWithTreasury() public {
            uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();

            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), esMoca.CLAIMED_PENALTY_FROM_VOTERS());
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), esMoca.CLAIMED_PENALTY_FROM_TREASURY());

            assertEq(esMocaTreasury.balance, totalClaimable);
        }

        function test_AssetManagerCannot_ClaimPenalties_WhenZero() public {
            vm.prank(assetManager);
            vm.expectRevert(Errors.NothingToClaim.selector);
            esMoca.claimPenalties();
        }

    // --------- tests: releaseEscrowedMoca() ---------

        function testRevert_UserCannot_ReleaseEscrowedMoca() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByAssetManager.selector);
            esMoca.releaseEscrowedMoca{value: 0}(1);
            vm.stopPrank();
        }

        function testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenZero() public {
            vm.prank(assetManager);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.releaseEscrowedMoca{value: 0}(0);
        }

        function testRevert_AssetManagerCannot_ReleaseEscrowedMoca_WhenInsufficientBalance() public {
            vm.prank(assetManager);
            vm.expectRevert(Errors.InsufficientBalance.selector);
            esMoca.releaseEscrowedMoca{value: 0}(1);
        }

        function test_AssetManagerCan_ReleaseEscrowedMoca() public {
            assertEq(assetManager.balance, 0);
            assertEq(esMoca.balanceOf(assetManager), 0);

            uint256 contractMocaBefore = address(esMoca).balance;

            // Deal MOCA to assetManager so it can escrow it
            vm.deal(assetManager, 1 ether);

            // asset manager escrows moca
            vm.startPrank(assetManager);
                esMoca.escrowMoca{value: 1 ether}();
            vm.stopPrank();

            // confirm asset manager has esMoca
            assertEq(esMoca.balanceOf(assetManager), 1 ether);

            // release escrowed moca
            vm.startPrank(assetManager);
                
                // expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.EscrowedMocaReleased(assetManager, 1 ether);

                esMoca.releaseEscrowedMoca(1 ether);
            vm.stopPrank();

            // confirm asset manager has moca
            assertEq(assetManager.balance, 1 ether);
            assertEq(esMoca.balanceOf(assetManager), 0);
            assertEq(address(esMoca).balance, contractMocaBefore, "No change to contract MOCA balance");
        }

    // --------- negative tests: claimRedemptions() ---------
        
        function testRevert_User2Cannot_ClaimRedemptions_Before60Days() public {
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp;
        
            vm.startPrank(user2);
                vm.expectRevert(Errors.NothingToClaim.selector);
                esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
        }

        function testRevert_User2Cannot_ClaimRedemptions_PassingFutureTimestamp() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.InvalidTimestamp.selector);
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp + 1;
            esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
        }

    // --------- positive test: claimRedemptions() for 30 days lock ---------
        function test_User1Can_ClaimRedemptions_30Days() public {
            // --- before balances & state ---
            uint256 user1MocaBefore = user1.balance;
            uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            uint256 userTotalMocaPendingRedemption_before = esMoca.userTotalMocaPendingRedemption(user1);
            
            // user1's redemption schedule
            uint256 redemptionTimestamp = block.timestamp;
            (uint256 mocaReceivableBefore, uint256 penaltyBefore, uint256 claimedBefore) = esMoca.redemptionSchedule(user1, redemptionTimestamp);

            // array of timestamps to claim
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = redemptionTimestamp;

            // events
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionsClaimed(user1, timestamps, mocaReceivableBefore);

            // --- Execute ---
            vm.startPrank(user1);
                esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
            
            // --- after balances & state ---
            uint256 user1MocaAfter = user1.balance;
            uint256 user1EsMocaAfter = esMoca.balanceOf(user1);
            uint256 totalSupplyAfter = esMoca.totalSupply();

            // user1's redemption schedule after claimRedemptions
            (uint256 mocaReceivableAfter, uint256 penaltyAfter, uint256 claimedAfter) = esMoca.redemptionSchedule(user1, redemptionTimestamp);
            
            // check token balances after claimRedemptions
            assertEq(user1MocaAfter, user1MocaBefore + mocaReceivableBefore, "MOCA balance not transferred correctly");
            // esMoca balance should not change in claim
            assertEq(user1EsMocaAfter, user1EsMocaBefore, "esMoca balance should not change in claim");
            assertEq(totalSupplyAfter, totalSupplyBefore, "totalSupply should not change in claim");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - mocaReceivableBefore, "TOTAL_MOCA_PENDING_REDEMPTION should be decremented");
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), userTotalMocaPendingRedemption_before - mocaReceivableBefore, "userTotalMocaPendingRedemption should be decremented");

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

            vm.deal(user1, 1 ether);
            
            vm.startPrank(user1);
                vm.expectRevert(Errors.OnlyCallableByCronJob.selector);
                esMoca.escrowMocaOnBehalf{value: 1 ether}(users, amounts);
            vm.stopPrank();
        }

        function testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenMismatchedArrayLengths() public {
            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;

            vm.deal(cronJob, 1 ether);


            vm.prank(cronJob);
            vm.expectRevert(Errors.MismatchedArrayLengths.selector);
            esMoca.escrowMocaOnBehalf{value: 1 ether}(users, amounts);
        }

        function testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenAmountIsZero() public {
            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 0 ether;

            vm.deal(cronJob, 1 ether);

            vm.prank(cronJob);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.escrowMocaOnBehalf{value: 1 ether}(users, amounts);
        }

        function testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenUserIsZeroAddress() public {
            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = address(0);

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 1 ether;

            vm.deal(cronJob, 2 ether);

            vm.prank(cronJob);
            vm.expectRevert(Errors.InvalidAddress.selector);
            esMoca.escrowMocaOnBehalf{value: 2 ether}(users, amounts);
        }

        function testRevert_CronJobCannot_EscrowMocaOnBehalf_WhenMsgValueMismatch() public {
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 1 ether;

            vm.deal(cronJob, 1 ether);

            vm.prank(cronJob);
            vm.expectRevert(Errors.InvalidAmount.selector);
            esMoca.escrowMocaOnBehalf{value: 1 ether}(users, amounts); // should be 2 ether
        }

        function test_CronJobCan_EscrowMocaOnBehalf() public {
            // ---- capture before states ----
            // contract
            uint256 contractNativeMocaBefore = address(esMoca).balance;
            uint256 contractWrappedMocaBefore = mockWMoca.balanceOf(address(esMoca));
            // users
            uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
            uint256 user2EsMocaBefore = esMoca.balanceOf(user2);
            // esMoca
            uint256 totalSupplyBefore = esMoca.totalSupply();

            // build array of users and amounts
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            uint256[] memory amounts = new uint256[](2);
            amounts[0] = 1 ether;
            amounts[1] = 1 ether;

            // finance cronJob with native moca
            vm.deal(cronJob, 2 ether);

            // escrowMocaOnBehalf
            vm.startPrank(cronJob);
                // expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.StakedOnBehalf(users, amounts);

                esMoca.escrowMocaOnBehalf{value: 2 ether}(users, amounts);
            vm.stopPrank();

            // Check: cronJob balances
            assertEq(cronJob.balance, 0);
            assertEq(esMoca.balanceOf(cronJob), 0);

            // Check: contract state
            assertEq(esMoca.totalSupply(), totalSupplyBefore + 2 ether);
            assertEq(address(esMoca).balance, contractNativeMocaBefore + 2 ether);
            assertEq(mockWMoca.balanceOf(address(esMoca)), contractWrappedMocaBefore);
            
            // Check: users
            assertEq(esMoca.balanceOf(user1), user1EsMocaBefore + 1 ether);
            assertEq(esMoca.balanceOf(user2), user2EsMocaBefore + 1 ether);
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

    // --------- positive test: claimRedemptions() for 60 days lock ---------

        function test_User2Can_ClaimRedemptions_60Days() public {
            // --- before balances & state ---
            uint256 user2MocaBefore = user2.balance;
            uint256 user2EsMocaBefore = esMoca.balanceOf(user2);
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            uint256 userTotalMocaPendingRedemption_before = esMoca.userTotalMocaPendingRedemption(user2);

            // user2's redemption schedule
            uint256 redemptionTimestamp = block.timestamp;
            (uint256 mocaReceivableBefore, uint256 penaltyBefore, uint256 claimedBefore) = esMoca.redemptionSchedule(user2, redemptionTimestamp);

            // deal native MOCA to contract to cover redemption
            vm.deal(address(esMoca), mocaReceivableBefore);

            // events
            vm.expectEmit(true, true, false, true, address(esMoca));
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = redemptionTimestamp;
            emit Events.RedemptionsClaimed(user2, timestamps, mocaReceivableBefore);

            vm.startPrank(user2);
            esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();

            // --- after balances & state ---
            uint256 user2MocaAfter = user2.balance;
            uint256 user2EsMocaAfter = esMoca.balanceOf(user2);
            uint256 totalSupplyAfter = esMoca.totalSupply();
            (uint256 mocaReceivableAfter, uint256 penaltyAfter, uint256 claimedAfter) = esMoca.redemptionSchedule(user2, redemptionTimestamp);

            // check token balances after claimRedemptions
            assertEq(user2MocaAfter, user2MocaBefore + mocaReceivableBefore, "MOCA balance not transferred correctly");
            assertEq(user2EsMocaAfter, 0, "esMoca balance should be 0 after claimRedemptions");

            // user
            assertEq(user2EsMocaAfter, user2EsMocaBefore, "user: esMoca unchanged; supply was burned in selectRedemptionOption");
            assertEq(esMoca.userTotalMocaPendingRedemption(user2), userTotalMocaPendingRedemption_before - mocaReceivableBefore, "userTotalMocaPendingRedemption should be decremented");

            // contract
            assertEq(totalSupplyAfter, totalSupplyBefore, "totalSupply should not change in claim");
            assertEq(esMoca.totalSupply(), totalSupplyBefore, "totalSupply unchanged: supply was burned in selectRedemptionOption");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - mocaReceivableBefore, "TOTAL_MOCA_PENDING_REDEMPTION should be decremented");
            
            // check redemption schedule updates
            assertEq(mocaReceivableAfter, mocaReceivableBefore, "mocaReceivable in redemptionSchedule should not change");
            assertEq(claimedAfter, mocaReceivableBefore, "claimed should be updated to full amount");
        }

    // --------- state transition: change penalty split ---------
        function test_UserCannot_SetPenaltyToVoters() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.OnlyCallableByEscrowedMocaAdmin.selector);
            esMoca.setVotersPenaltyPct(5000); 
            vm.stopPrank();
        }

        function test_EscrowedMocaAdminCan_SetPenaltyToVoters() public {
            // record old value
            uint256 oldVotersPenaltyPct = esMoca.VOTERS_PENALTY_PCT();
            assertEq(esMoca.VOTERS_PENALTY_PCT(), 1000);

            // expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.VotersPenaltyPctUpdated(oldVotersPenaltyPct, 5000);

            vm.startPrank(escrowedMocaAdmin);
                esMoca.setVotersPenaltyPct(5000); // 50% penalty
            vm.stopPrank();

            // check state update
            assertEq(esMoca.VOTERS_PENALTY_PCT(), 5000, "VOTERS_PENALTY_PCT not updated");
        }
}

// note: change penalty split to 50%
abstract contract StateT60Days_ChangePenaltySplit is StateT60Days_UserTwoHasRedemptionScheduled {

    function setUp() public virtual override {
        super.setUp();

        // change penalty split: 50% split between voters and treasury
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setVotersPenaltyPct(5000);
        vm.stopPrank();
    }
}

contract StateT60Days_ChangePenaltySplit_Test is StateT60Days_ChangePenaltySplit {

    // --------- negative tests: setVotersPenaltyPct() ---------

        // invalid percentage: >= 100%
        function test_EscrowedMocaAdminCannot_SetInvalidVotersPenaltyPct_GreaterThanOrEqual100() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidPercentage.selector);
            esMoca.setVotersPenaltyPct(Constants.PRECISION_BASE);
            vm.stopPrank();
        }

    // --------- positive tests: setVotersPenaltyPct() ---------

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
                
                // With VOTERS_PENALTY_PCT set to 5000, the split should be 50/50 between voters and treasury
                uint256 expectedPenaltyToVoters = expectedPenalty * 5000 / Constants.PRECISION_BASE;
                uint256 expectedPenaltyToTreasury = expectedPenalty - expectedPenaltyToVoters;
                
                // Sanity check: should be equal for 50/50 split
                assertEq(expectedPenaltyToVoters, expectedPenaltyToTreasury, "Penalty split is not 50/50");
                
                // Execute redemption
                vm.startPrank(user1);

                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.PenaltyAccrued(expectedPenaltyToVoters, expectedPenaltyToTreasury);

                    vm.expectEmit(true, true, false, true, address(esMoca));
                    emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, block.timestamp + lockDuration);

                    esMoca.selectRedemptionOption{value: 0}(optionId, redemptionAmount);
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
                
                (uint256 mocaReceivable, uint256 penalty, uint256 claimed) = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
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

    // --------- tests: setMocaTransferGasLimit() ---------
        function testRevert_UserCannot_SetMocaTransferGasLimit() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.OnlyCallableByEscrowedMocaAdmin.selector);
            esMoca.setMocaTransferGasLimit(3000);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetMocaTransferGasLimit_BelowMinimum() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidGasLimit.selector);
            esMoca.setMocaTransferGasLimit(2299); // below 2300
            vm.stopPrank();
        }

        function test_EscrowedMocaAdminCan_SetMocaTransferGasLimit() public {
            uint256 oldGasLimit = esMoca.MOCA_TRANSFER_GAS_LIMIT();
            uint256 newGasLimit = 4029; // typical for Gnosis Safe

            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.MocaTransferGasLimitUpdated(oldGasLimit, newGasLimit);

            vm.startPrank(escrowedMocaAdmin);
            esMoca.setMocaTransferGasLimit(newGasLimit);
            vm.stopPrank();

            assertEq(esMoca.MOCA_TRANSFER_GAS_LIMIT(), newGasLimit, "Gas limit not updated");
        }
}

// note: disable redemption option
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
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, user1Amount/4);
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
                (uint256 mocaReceivableBefore, uint256 penaltyBefore, uint256 claimedBefore) = esMoca.redemptionSchedule(user1, redemptionTimestamp);
                uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
                
                // Calculate expected
                uint256 expectedMocaReceivable = amount * optionPct / 10000;
                uint256 expectedPenalty = amount - expectedMocaReceivable;
                
                // Expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, redemptionTimestamp);
                
                // User selects redemption option
                vm.prank(user1);
                esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, amount);
                
                // After-state checks
                uint256 userEsMocaBalanceAfter = esMoca.balanceOf(user1);
                uint256 esMocaTotalSupplyAfter = esMoca.totalSupply();
                (uint256 mocaReceivableAfter, uint256 penaltyAfter, uint256 claimedAfter) = esMoca.redemptionSchedule(user1, redemptionTimestamp);
                uint256 TOTAL_MOCA_PENDING_REDEMPTION_after = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
                
                assertEq(userEsMocaBalanceAfter, userEsMocaBalanceBefore - amount, "User esMOCA should decrease by amount");
                assertEq(esMocaTotalSupplyAfter, esMocaTotalSupplyBefore - amount, "Total supply should decrease by amount");
                assertEq(mocaReceivableAfter - mocaReceivableBefore, expectedMocaReceivable, "Moca receivable increased as expected");
                assertEq(penaltyAfter - penaltyBefore, expectedPenalty, "Penalty booked as expected");
                assertEq(claimedAfter, claimedBefore, "No moca claimed immediately for delayed redemption");
                assertEq(TOTAL_MOCA_PENDING_REDEMPTION_after, TOTAL_MOCA_PENDING_REDEMPTION_before + expectedMocaReceivable, "TOTAL_MOCA_PENDING_REDEMPTION should increment");
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

        // user to selectRedemptionOption, so that there are penalties in frozen state to claim via emergencyExitPenalties()
       vm.startPrank(user1);
            esMoca.selectRedemptionOption{value: 0}(redemptionOption1_30Days, user1Amount / 10); // 10% of user1's balance
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
            vm.deal(user1, amount);
            
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.escrowMoca{value: amount}();
            vm.stopPrank();
        }

        function testRevert_UserCannot_SelectRedemptionOption_WhenPaused() public {
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.selectRedemptionOption{value: 0}(redemptionOption2_60Days, 50 ether);
            vm.stopPrank();
        }

        function testRevert_UserCannot_ClaimRedemptions_WhenPaused() public {
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp + 60 days;
            esMoca.claimRedemptions{value: 0}(timestamps);
            vm.stopPrank();
        }

        function testRevert_AssetManagerCannot_EscrowMocaOnBehalf_WhenPaused() public {
            address[] memory users = new address[](1);
            users[0] = user2;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 100 ether;
            
            vm.deal(cronJob, 100 ether);
            
            vm.startPrank(cronJob);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.escrowMocaOnBehalf{value: 100 ether}(users, amounts);
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
            esMoca.releaseEscrowedMoca{value: 0}(50 ether);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetVotersPenaltyPct_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.setVotersPenaltyPct(2000);
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

        function testRevert_EscrowedMocaAdminCannot_SetMocaTransferGasLimit_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.setMocaTransferGasLimit(3000);
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

        function testRevert_EmergencyExitHandlerCannot_EmergencyExitPenalties_WhenNotFrozen() public {
            vm.startPrank(emergencyExitHandler);
                vm.expectRevert(Errors.NotFrozen.selector);
                esMoca.emergencyExitPenalties();
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
            address[] memory users = new address[](1);
            users[0] = user1;
            vm.expectRevert(Errors.NotFrozen.selector);
            esMoca.emergencyExit{value: 0}(users);
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
    using stdStorage for StdStorage;
    
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

        function testRevert_EmergencyExit_EmptyArray() public {
            address[] memory users = new address[](0);
            vm.prank(emergencyExitHandler);
            vm.expectRevert(Errors.InvalidArray.selector);
            esMoca.emergencyExit{value: 0}(users);
        }

        function testRevert_EmergencyExit_NeitherEmergencyExitHandlerNorUser() public {
            address[] memory users = new address[](1);
            users[0] = user1;
         
            vm.prank(user2);
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandlerOrUser.selector);
            esMoca.emergencyExit{value: 0}(users);
        }

        function test_UserCan_EmergencyExit_Themselves() public {
            // user
            uint256 user1NativeMocaBefore = user1.balance;
            uint256 user1WrappedMocaBefore = mockWMoca.balanceOf(user1);
            uint256 user1EsMocaBalance = esMoca.balanceOf(user1);
            uint256 user1TotalPendingRedemptions = esMoca.userTotalMocaPendingRedemption(user1);
            uint256 totalMocaToReceive = user1EsMocaBalance + user1TotalPendingRedemptions;
            
            // contract
            uint256 contractNativeMocaBefore = address(esMoca).balance;
            uint256 esMocaTotalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            
            address[] memory users = new address[](1);
            users[0] = user1;

            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.EmergencyExitEscrowedMoca(users, totalMocaToReceive);

            vm.prank(user1);
            esMoca.emergencyExit{value: 0}(users);

            // after: user
            assertEq(esMoca.balanceOf(user1), 0, "User esMoca should be burned");
            assertEq(user1.balance, user1NativeMocaBefore + totalMocaToReceive, "User should receive esMoca balance + pending redemptions");
            assertEq(mockWMoca.balanceOf(user1), user1WrappedMocaBefore, "User should not receive any wMoca");

            // after: contract
            assertEq(esMoca.totalSupply(), esMocaTotalSupplyBefore - user1EsMocaBalance, "esMoca totalSupply should decrease by user1 esMoca balance");
            assertEq(address(esMoca).balance, contractNativeMocaBefore - totalMocaToReceive, "contract native moca balance should decrease by total sent");
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), 0, "Pending redemptions should be cleared");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - user1TotalPendingRedemptions, "Global pending redemptions should be cleared");
        }

        function test_EmergencyExitHandlerCan_EmergencyExit_MultipleUsers() public {
            // esmoca
            uint256 user1EsMocaBalance = esMoca.balanceOf(user1);
            uint256 user2EsMocaBalance = esMoca.balanceOf(user2);
            uint256 totalEsMocaBalance = user1EsMocaBalance + user2EsMocaBalance;

            // pending redemptions
            uint256 user1TotalPendingRedemptions = esMoca.userTotalMocaPendingRedemption(user1);
            uint256 user2TotalPendingRedemptions = esMoca.userTotalMocaPendingRedemption(user2);

            // total moca to receive per user
            uint256 user1TotalMoca = user1EsMocaBalance + user1TotalPendingRedemptions;
            uint256 user2TotalMoca = user2EsMocaBalance + user2TotalPendingRedemptions;
            
            // native moca before
            uint256 user1BalanceBefore = user1.balance;
            uint256 user2BalanceBefore = user2.balance;
            // contract before
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            
            // array of users to exit
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user2;

            // total exfil amount
            uint256 totalMocaToReceive = totalEsMocaBalance + user1TotalPendingRedemptions + user2TotalPendingRedemptions;

            // events
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.EmergencyExitEscrowedMoca(users, totalMocaToReceive);

            // execute
            vm.prank(emergencyExitHandler);
            esMoca.emergencyExit{value: 0}(users);

            // after: user
            assertEq(esMoca.balanceOf(user1), 0, "user1: esMoca should be burned");
            assertEq(esMoca.balanceOf(user2), 0, "user2: esMoca should be burned");
            assertEq(user1.balance, user1BalanceBefore + user1TotalMoca, "user1: should receive native moca balance");
            assertEq(user2.balance, user2BalanceBefore + user2TotalMoca, "user2: should receive native moca balance");

            // after: contract
            assertEq(esMoca.totalSupply(), totalSupplyBefore - user1EsMocaBalance - user2EsMocaBalance, "esMoca totalSupply should decrease by user1 and user2 esMoca balance");
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), 0, "user1: Pending redemptions should be cleared");
            assertEq(esMoca.userTotalMocaPendingRedemption(user2), 0, "user2: Pending redemptions should be cleared");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - user1TotalPendingRedemptions - user2TotalPendingRedemptions, "Global: pending redemptions should be cleared");
        }

        function test_EmergencyExitHandlerCan_EmergencyExit_WithPendingRedemptions() public {
            // Setup: user1 has pending redemption
            uint256 redemptionAmount = user1Amount / 2;
            skip(30 days);
            
            // Use the aggregate pending redemptions (matches emergencyExit logic)
            uint256 user1TotalPendingRedemptions = esMoca.userTotalMocaPendingRedemption(user1);
            uint256 user1EsMocaBalance = esMoca.balanceOf(user1);
            uint256 totalMocaExpected = user1EsMocaBalance + user1TotalPendingRedemptions;

            // before
            uint256 user1NativeMocaBefore = user1.balance;
            uint256 user1WrappedMocaBefore = mockWMoca.balanceOf(user1);
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();


            address[] memory users = new address[](1);
            users[0] = user1;
            
            vm.prank(emergencyExitHandler);
            esMoca.emergencyExit{value: 0}(users);


            // user
            assertEq(esMoca.balanceOf(user1), 0, "User esMoca should be burned");
            assertEq(user1.balance, user1NativeMocaBefore + totalMocaExpected, "User should receive esMoca balance + pending redemptions");

            // contract
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), 0, "Pending redemptions should be cleared");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - user1TotalPendingRedemptions, "Pending redemptions should be cleared");
        }

    // --------- tests: emergencyExitPenalties() ---------

        function testRevert_emergencyExitPenalties_TreasuryAddressZero() public {
            // Mock the accessController to return address(0) for ESCROWED_MOCA_TREASURY
            vm.mockCall(
                address(accessController),
                abi.encodeWithSelector(accessController.ESCROWED_MOCA_TREASURY.selector),
                abi.encode(address(0))
            );

            // Verify the mock is working
            assertEq(accessController.ESCROWED_MOCA_TREASURY(), address(0), "Mock should return address(0)");

            // Attempt to call emergencyExitPenalties - should revert with InvalidAddress
            vm.prank(emergencyExitHandler);
            vm.expectRevert(Errors.InvalidAddress.selector);
            esMoca.emergencyExitPenalties();

            // Clear the mock
            vm.clearMockedCalls();
        }

        function testRevert_EmergencyExitHandlerCannot_EmergencyExitPenalties_WhenNoPenalties() public {
            // First, claim the existing penalties from the setup
            vm.prank(emergencyExitHandler);
            esMoca.emergencyExitPenalties();
            
            // Verify penalties have been claimed
            assertEq(esMoca.CLAIMED_PENALTY_FROM_VOTERS(), esMoca.ACCRUED_PENALTY_TO_VOTERS(), "Penalties should be marked as claimed");
            assertEq(esMoca.CLAIMED_PENALTY_FROM_TREASURY(), esMoca.ACCRUED_PENALTY_TO_TREASURY(), "Penalties should be marked as claimed");
            
            // Now try to claim again - should revert with NothingToClaim
            vm.prank(emergencyExitHandler);
            vm.expectRevert(Errors.NothingToClaim.selector);
            esMoca.emergencyExitPenalties();
        }

        function test_EmergencyExitHandlerCan_EmergencyExitPenalties() public {
            uint256 totalPenaltyAccrued = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();
            uint256 totalClaimable = totalPenaltyAccrued - esMoca.CLAIMED_PENALTY_FROM_VOTERS() - esMoca.CLAIMED_PENALTY_FROM_TREASURY();
            assertTrue(totalClaimable > 0, "No penalties to claim");

            // before
            uint256 esMocaTreasuryMocaBefore = esMocaTreasury.balance;
            uint256 contractNativeMocaBefore = address(esMoca).balance;
            uint256 esMocaTotalSupplyBefore = esMoca.totalSupply();

            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.EmergencyExitPenalties(esMocaTreasury, totalClaimable);

            vm.prank(emergencyExitHandler);
            esMoca.emergencyExitPenalties();

            // after: treasury + contract
            assertEq(esMocaTreasury.balance, esMocaTreasuryMocaBefore + totalClaimable, "Treasury should receive penalties");
            assertEq(address(esMoca).balance, contractNativeMocaBefore - totalClaimable, "Contract native moca balance should decrease by total sent");
            // totalSupply should remain unchanged - emergencyExitPenalties does not burn tokens
            assertEq(esMoca.totalSupply(), esMocaTotalSupplyBefore, "esMoca totalSupply should remain unchanged");
            // counters should match
            assertEq(esMoca.CLAIMED_PENALTY_FROM_VOTERS(), esMoca.ACCRUED_PENALTY_TO_VOTERS(), "Penalties should be marked as claimed");
            assertEq(esMoca.CLAIMED_PENALTY_FROM_TREASURY(), esMoca.ACCRUED_PENALTY_TO_TREASURY(), "Penalties should be marked as claimed");
        }
}