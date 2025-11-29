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
        // Check treasury address
        assertEq(esMoca.ESCROWED_MOCA_TREASURY(), esMocaTreasury, "ESCROWED_MOCA_TREASURY not set correctly");
        // Check evenwMoca address
        assertEq(esMoca.WMOCA(), address(mockWMoca), "WMOCA not set correctly");
        // Check moca transfer gas limit
        assertEq(esMoca.MOCA_TRANSFER_GAS_LIMIT(), 2300, "MOCA_TRANSFER_GAS_LIMIT not set correctly");
        // Check voters penalty pct
        assertEq(esMoca.VOTERS_PENALTY_PCT(), 1000, "VOTERS_PENALTY_PCT not set correctly");

        // ERC20 metadata
        assertEq(esMoca.name(), "esMoca", "ERC20: incorrect name");
        assertEq(esMoca.symbol(), "esMOCA", "ERC20: incorrect symbol");
    }

    function testRevert_ConstructorChecks() public {
        // globalAdmin: must not be zero address
        vm.expectRevert(Errors.InvalidAddress.selector);
        new EscrowedMoca(
            address(0), 
            escrowedMocaAdmin, 
            monitorAdmin, 
            cronJobAdmin, 
            monitor, 
            esMocaTreasury, 
            emergencyExitHandler, 
            assetManager, 
            1000, 
            address(mockWMoca), 
            2300
        );

        // votersPenaltyPct > 100%
        vm.expectRevert(Errors.InvalidPercentage.selector);
        new EscrowedMoca(
            globalAdmin, 
            escrowedMocaAdmin, 
            monitorAdmin, 
            cronJobAdmin, 
            monitor, 
            esMocaTreasury, 
            emergencyExitHandler, 
            assetManager, 
            Constants.PRECISION_BASE + 1, 
            address(mockWMoca), 
            2300
        );

        // wMoca: invalid address
        vm.expectRevert(Errors.InvalidAddress.selector);
        new EscrowedMoca(
            globalAdmin, 
            escrowedMocaAdmin, 
            monitorAdmin, 
            cronJobAdmin, 
            monitor, 
            esMocaTreasury, 
            emergencyExitHandler, 
            assetManager, 
            1000, 
            address(0), 
            2300
        );

        // mocaTransferGasLimit < 2300
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        new EscrowedMoca(
            globalAdmin, 
            escrowedMocaAdmin, 
            monitorAdmin, 
            cronJobAdmin, 
            monitor, 
            esMocaTreasury, 
            emergencyExitHandler, 
            assetManager, 
            1000, 
            address(mockWMoca), 
            2299
        );
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
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.ESCROWED_MOCA_ADMIN_ROLE()));
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
        function testRevert_CronJobCannot_ClaimPenalties_WhenZero() public {
            // give cronJob role
            vm.startPrank(cronJobAdmin);
                esMoca.grantRole(esMoca.CRON_JOB_ROLE(), cronJob);
            vm.stopPrank();

            vm.expectRevert(Errors.NothingToClaim.selector);

            vm.prank(cronJob);
            esMoca.claimPenalties();
        }
    
    // --------- state transition: selectRedemptionOption() ---------

        function test_User1Can_SelectRedemptionOption_30Days() public {
            // Setup
            uint256 redemptionAmount = user1Amount / 2;
            uint256 optionId = redemptionOption1_30Days;
            (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(optionId);
            
            // Execute and verify
            uint256 expectedMocaReceivable;
            {
                uint256 esMocaBalBefore = esMoca.balanceOf(user1);
                uint256 mocaBalBefore = user1.balance;
                uint256 totalSupplyBefore = esMoca.totalSupply();
                uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
                // penalties before
                uint256 ACCRUED_PENALTY_TO_VOTERS_before = esMoca.ACCRUED_PENALTY_TO_VOTERS();
                uint256 ACCRUED_PENALTY_TO_TREASURY_before = esMoca.ACCRUED_PENALTY_TO_TREASURY();

                
                // calculation for receivable/penalty
                expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
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
                    
                    esMoca.selectRedemptionOption(optionId, redemptionAmount, expectedMocaReceivable, block.timestamp + lockDuration);
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
                
                uint256 mocaReceivable = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
                assertEq(mocaReceivable, expectedMocaReceivable, "stored mocaReceivable incorrect");
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
                esMoca.selectRedemptionOption(optionId, redemptionAmount, redemptionAmount, block.timestamp + lockDuration); 

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
            uint256 mocaReceivable = esMoca.redemptionSchedule(user2, block.timestamp + lockDuration);
            assertEq(mocaReceivable, redemptionAmount, "stored mocaReceivable incorrect");
        }
}

// note: user1 has a redemption scheduled | partial redemption
abstract contract StateT0_UsersScheduleTheirRedemptions is StateT0_RedemptionOptionsSet {

    function setUp() public virtual override {
        super.setUp();

        // user1 schedules a redemption: penalties booked + redemption scheduled 
        vm.startPrank(user1);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, user1Amount / 2, user1Amount / 4, block.timestamp + 30 days);
        vm.stopPrank();

        // user2 schedules a redemption: penalties booked + redemption scheduled
        vm.startPrank(user2);
            esMoca.selectRedemptionOption(redemptionOption2_60Days, user2Amount, user2Amount, block.timestamp + 60 days);
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
            esMoca.selectRedemptionOption(redemptionOption1_30Days, 0, 0, block.timestamp + 30 days);
            vm.stopPrank();
        }

        function testRevert_UserCannot_SelectRedemptionOption_WhenAmountIsGreaterThanBalance() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.InsufficientBalance.selector);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, user1Amount + 1, user1Amount + 1, block.timestamp + 30 days);
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
            esMoca.selectRedemptionOption(redemptionOption1_30Days, 10 ether, 10 ether, block.timestamp + 30 days);
            vm.stopPrank();
        }

        // select redemption option that has not been setup: isEnabled = false
        function testRevert_UserCannot_SelectRedemptionOption_WhenRedemptionOptionIsDisabled() public {
            vm.startPrank(user1);
            vm.expectRevert(Errors.RedemptionOptionAlreadyDisabled.selector);
            esMoca.selectRedemptionOption(5, user1Amount/2, user1Amount/2, block.timestamp + 30 days);
            vm.stopPrank();
        }

        // select redemption option with incorrect expected redemption timestamp
        function testRevert_UserCannot_SelectRedemptionOption_WhenExpectedRedemptionTimestampIsInvalid() public {
            // Get the redemption option details
            (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(redemptionOption1_30Days);
            
            // Calculate the correct redemption timestamp
            uint256 correctRedemptionTimestamp = block.timestamp + lockDuration;
            
            // Use an incorrect expected timestamp (off by 1 second)
            uint256 incorrectRedemptionTimestamp = correctRedemptionTimestamp + 1;
            
            // Calculate expected receivable
            uint256 redemptionAmount = user1Amount / 4;
            uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;
            
            // Attempt to select redemption option with incorrect expected timestamp
            vm.startPrank(user1);
            vm.expectRevert(Errors.InvalidRedemptionTimestamp.selector);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, redemptionAmount, expectedMocaReceivable, incorrectRedemptionTimestamp);
            vm.stopPrank();
        }


    // --------- negative tests: claimRedemptions() ---------

        function testRevert_User1Cannot_ClaimRedemptions_EmptyArray() public {
            uint256[] memory timestamps = new uint256[](0);

            vm.startPrank(user1);
                vm.expectRevert(Errors.InvalidArray.selector);
                esMoca.claimRedemptions(timestamps);
            vm.stopPrank();
        }

        function testRevert_User1Cannot_ClaimRedemptions_Before30Days() public {
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp + 30 days;

            vm.startPrank(user1);
                vm.expectRevert(Errors.InvalidTimestamp.selector);
                esMoca.claimRedemptions(timestamps);
            vm.stopPrank();
        }


        function testRevert_User3_NoRedemptionsScheduled_NothingToClaim() public {
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp;

            vm.startPrank(user3);
                vm.expectRevert(Errors.NothingToClaim.selector);
                esMoca.claimRedemptions(timestamps);
            vm.stopPrank();
        }

    // --------- positive test: claimRedemptions() for instant redemption ---------

        function test_User3Can_SelectRedemptionOptionInstant_ReceivesMocaImmediately() public {
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
                emit Events.Redeemed(user3, expectedMocaReceivable, expectedPenalty);

                // Execute
                vm.prank(user3);
                esMoca.selectRedemptionOption(redemptionOption3_Instant, instantRedeemAmount, expectedMocaReceivable, block.timestamp + lockDuration);

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
            uint256 mocaReceivableAfter = esMoca.redemptionSchedule(user3, block.timestamp);
            assertEq(mocaReceivableAfter, 0, "mocaReceivable in schedule should equal amount received");
        }

    // --------- positive test: claimRedemptions() for multiple timestamps ---------

        function test_User1Can_ClaimRedemptions_MultipleTimestamps() public {
            // Get lock duration for the redemption option
            (uint128 lockDuration,uint128 receivablePct,) = esMoca.redemptionOptions(redemptionOption1_30Days);
            
            // calculation for receivable/penalty
            uint256 amountForRedemption = user1Amount / 4; 
            uint256 expectedMocaReceivable = amountForRedemption * receivablePct / Constants.PRECISION_BASE;
            uint256 expectedPenalty = amountForRedemption - expectedMocaReceivable;

            // --- Setup: user1 creates multiple redemptions ---
            vm.startPrank(user1);
                esMoca.selectRedemptionOption(redemptionOption1_30Days, amountForRedemption, expectedMocaReceivable, block.timestamp + lockDuration);
                // Store the redemption timestamp
                uint256 timestamp1 = block.timestamp + lockDuration; 
            
                skip(1 days);
                esMoca.selectRedemptionOption(redemptionOption1_30Days, amountForRedemption, expectedMocaReceivable, block.timestamp + lockDuration);
                // Store the redemption timestamp
                uint256 timestamp2 = block.timestamp + lockDuration; 
            vm.stopPrank();

            // Fast forward to when both are claimable (warp to when second one is claimable)
            skip(timestamp2 + 1);
            
            // --- Calculate total claimable ---
            uint256 mocaReceivable1 = esMoca.redemptionSchedule(user1, timestamp1);
            uint256 mocaReceivable2 = esMoca.redemptionSchedule(user1, timestamp2);
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
            uint256[] memory mocaReceivables = new uint256[](2);
                mocaReceivables[0] = mocaReceivable1;
                mocaReceivables[1] = mocaReceivable2;
                
            // --- Events ---
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionsClaimed(user1, timestamps, mocaReceivables);

            // --- Execute ---
            vm.prank(user1);
            esMoca.claimRedemptions(timestamps);

            // --- After state ---
            assertEq(user1.balance, user1BalanceBefore + totalClaimable, "User should receive both redemptions");
            assertEq(esMoca.totalSupply(), totalSupplyBefore, "totalSupply unchanged");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - totalClaimable, "Pending redemptions should be decremented");
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), userTotalMocaPendingRedemption_before - totalClaimable, "userTotalMocaPendingRedemption should be decremented");
        }


        function test_User1Can_ClaimRedemptions_MultipleRedemptionsAtSameTimestamp() public {
            // Get lock duration for the redemption option
            (uint128 lockDuration,uint128 receivablePct,) = esMoca.redemptionOptions(redemptionOption1_30Days);
            
            // Skip time to use a different timestamp than the one from setUp
            skip(lockDuration + 1);

            // calculation for receivable/penalty
            uint256 amountForRedemption = user1Amount / 4; 
            uint256 expectedMocaReceivable = amountForRedemption * receivablePct / Constants.PRECISION_BASE;
            uint256 expectedPenalty = amountForRedemption - expectedMocaReceivable;

            // --- Setup: user1 creates multiple redemptions for the same timestamp ---
            vm.startPrank(user1);
                // First redemption
                esMoca.selectRedemptionOption(redemptionOption1_30Days, amountForRedemption, expectedMocaReceivable, block.timestamp + lockDuration);
                // Store the redemption timestamp
                uint256 timestamp1 = block.timestamp + lockDuration; 
            
                // Second redemption at the same timestamp (no time skip)
                esMoca.selectRedemptionOption(redemptionOption1_30Days, amountForRedemption, expectedMocaReceivable, block.timestamp + lockDuration);
                // This should have the same timestamp as timestamp1
                uint256 timestamp2 = block.timestamp + lockDuration; 
            vm.stopPrank();

            // Verify both redemptions are at the same timestamp
            assertEq(timestamp1, timestamp2, "Both redemptions should be at the same timestamp");

            // Fast forward to when redemptions are claimable
            skip(lockDuration + 1);
            
            // --- Calculate total claimable ---
            // Since both redemptions are at the same timestamp, they should be accumulated
            uint256 mocaReceivableAtTimestamp = esMoca.redemptionSchedule(user1, timestamp1);
            uint256 expectedTotalClaimable = expectedMocaReceivable * 2; // Two redemptions
            assertEq(mocaReceivableAtTimestamp, expectedTotalClaimable, "Redemptions should be accumulated at the same timestamp");
            
            // --- Before state ---
            uint256 user1BalanceBefore = user1.balance;
            uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
            uint256 totalSupplyBefore = esMoca.totalSupply();
            uint256 userTotalMocaPendingRedemption_before = esMoca.userTotalMocaPendingRedemption(user1);
        
            // create array of timestamps to claim (only one timestamp since both redemptions are at the same time)
            uint256[] memory timestamps = new uint256[](1);
                timestamps[0] = timestamp1;
            uint256[] memory mocaReceivables = new uint256[](1);
                mocaReceivables[0] = mocaReceivableAtTimestamp;
                
            // --- Events ---
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionsClaimed(user1, timestamps, mocaReceivables);

            // --- Execute ---
            vm.prank(user1);
            esMoca.claimRedemptions(timestamps);

            // --- After state ---
            assertEq(user1.balance, user1BalanceBefore + expectedTotalClaimable, "User should receive both redemptions");
            assertEq(esMoca.totalSupply(), totalSupplyBefore, "totalSupply unchanged");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - expectedTotalClaimable, "Pending redemptions should be decremented");
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), userTotalMocaPendingRedemption_before - expectedTotalClaimable, "userTotalMocaPendingRedemption should be decremented");
            
            // Verify redemption schedule is cleared
            assertEq(esMoca.redemptionSchedule(user1, timestamp1), 0, "Redemption schedule should be cleared after claiming");
        }

    // --------- tests: claimPenalties() ---------

        function testRevert_UserCannot_ClaimPenalties() public {
            vm.startPrank(user1);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.CRON_JOB_ROLE()));
            esMoca.claimPenalties();
            vm.stopPrank();
        }

        function test_CronJobCan_ClaimPenalties_AssetsSentToTreasury() public {
            
            // give role to cronJob
            vm.startPrank(cronJobAdmin);
                esMoca.grantRole(esMoca.CRON_JOB_ROLE(), cronJob);
            vm.stopPrank();


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
                vm.prank(cronJob);
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

        // give cronJob role
        vm.startPrank(cronJobAdmin);
            esMoca.grantRole(esMoca.CRON_JOB_ROLE(), cronJob);
        vm.stopPrank();

        // claim penalties
        vm.prank(cronJob);
        esMoca.claimPenalties();
    }
}


contract StateT30Days_UserOneHasRedemptionScheduled_Test is StateT30Days_UserOneHasRedemptionScheduled_PenaltiesAreClaimed {

    // --------- tests: claimPenalties() ---------

        function test_CronJobHas_ClaimedPenalties_AssetsWithTreasury() public {
            uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();

            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), esMoca.CLAIMED_PENALTY_FROM_VOTERS());
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), esMoca.CLAIMED_PENALTY_FROM_TREASURY());

            assertEq(esMocaTreasury.balance, totalClaimable);
        }

        function test_CronJobCannot_ClaimPenalties_WhenZero() public {
            vm.prank(cronJob);
            vm.expectRevert(Errors.NothingToClaim.selector);
            esMoca.claimPenalties();
        }

    // --------- tests: releaseEscrowedMoca() ---------

        function testRevert_UserCannot_ReleaseEscrowedMoca() public {
            vm.startPrank(user1);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.ASSET_MANAGER_ROLE()));
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
                esMoca.claimRedemptions(timestamps);
            vm.stopPrank();
        }

        function testRevert_User2Cannot_ClaimRedemptions_PassingFutureTimestamp() public {
            vm.startPrank(user2);
            vm.expectRevert(Errors.InvalidTimestamp.selector);
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp + 1;
            esMoca.claimRedemptions(timestamps);
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
            uint256 mocaReceivableBefore = esMoca.redemptionSchedule(user1, redemptionTimestamp);

            // array of timestamps to claim
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = redemptionTimestamp;

            // array of moca receivables to claim
            uint256[] memory mocaReceivables = new uint256[](1);
            mocaReceivables[0] = mocaReceivableBefore;
            
            // events
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionsClaimed(user1, timestamps, mocaReceivables);

            // --- Execute ---
            vm.startPrank(user1);
                esMoca.claimRedemptions(timestamps);
            vm.stopPrank();
            
            // --- after balances & state ---
            uint256 user1MocaAfter = user1.balance;
            uint256 user1EsMocaAfter = esMoca.balanceOf(user1);
            uint256 totalSupplyAfter = esMoca.totalSupply();

            // user1's redemption schedule after claimRedemptions
            uint256 mocaReceivableAfter = esMoca.redemptionSchedule(user1, redemptionTimestamp);
            
            // check token balances after claimRedemptions
            assertEq(user1MocaAfter, user1MocaBefore + mocaReceivableBefore, "MOCA balance not transferred correctly");
            // esMoca balance should not change in claim
            assertEq(user1EsMocaAfter, user1EsMocaBefore, "esMoca balance should not change in claim");
            assertEq(totalSupplyAfter, totalSupplyBefore, "totalSupply should not change in claim");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - mocaReceivableBefore, "TOTAL_MOCA_PENDING_REDEMPTION should be decremented");
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), userTotalMocaPendingRedemption_before - mocaReceivableBefore, "userTotalMocaPendingRedemption should be decremented");

            // check redemption schedule updates
            assertEq(mocaReceivableAfter, 0, "mocaReceivable in redemptionSchedule should be 0");
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
                vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.CRON_JOB_ROLE()));
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
            uint256 mocaReceivableBefore = esMoca.redemptionSchedule(user2, redemptionTimestamp);

            // deal native MOCA to contract to cover redemption
            vm.deal(address(esMoca), mocaReceivableBefore);

            // arrays
            uint256[] memory redemptionTimestamps = new uint256[](1);
            redemptionTimestamps[0] = redemptionTimestamp;
            uint256[] memory mocaReceivables = new uint256[](1);
            mocaReceivables[0] = mocaReceivableBefore;

            // expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.RedemptionsClaimed(user2, redemptionTimestamps, mocaReceivables);

            // claimRedemptions
            vm.startPrank(user2);
            esMoca.claimRedemptions(redemptionTimestamps);
            vm.stopPrank();

            // --- after balances & state ---
            uint256 user2MocaAfter = user2.balance;
            uint256 user2EsMocaAfter = esMoca.balanceOf(user2);
            uint256 totalSupplyAfter = esMoca.totalSupply();
            uint256 mocaReceivableAfter = esMoca.redemptionSchedule(user2, redemptionTimestamp);

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
            assertEq(mocaReceivableAfter, 0, "mocaReceivable in redemptionSchedule should be 0");
        }

    // --------- state transition: change penalty split ---------
        function test_UserCannot_SetPenaltyToVoters() public {
            vm.startPrank(user2);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, esMoca.ESCROWED_MOCA_ADMIN_ROLE()));
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

        // invalid percentage: 100%
        function test_EscrowedMocaAdminCannot_SetInvalidVotersPenaltyPct_GreaterThan100() public {
            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidPercentage.selector);
            esMoca.setVotersPenaltyPct(Constants.PRECISION_BASE+1);
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

                    esMoca.selectRedemptionOption(optionId, redemptionAmount, expectedMocaReceivable, block.timestamp + lockDuration);
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
                
                uint256 mocaReceivable = esMoca.redemptionSchedule(user1, block.timestamp + lockDuration);
                assertEq(mocaReceivable, expectedMocaReceivable, "redemption schedule: mocaReceivable wrong");
            }
        }
    
    // --------- state transition: disable redemption option ---------
        function test_UserCannot_DisableRedemptionOption() public {
            vm.startPrank(user1);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.ESCROWED_MOCA_ADMIN_ROLE()));
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
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.ESCROWED_MOCA_ADMIN_ROLE()));
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
            esMoca.selectRedemptionOption(redemptionOption1_30Days, user1Amount/4, user1Amount/4, block.timestamp + 30 days);
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
                uint256 mocaReceivableBefore = esMoca.redemptionSchedule(user1, redemptionTimestamp);
                uint256 TOTAL_MOCA_PENDING_REDEMPTION_before = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
                
                // Calculate expected
                uint256 expectedMocaReceivable = amount * optionPct / 10000;
                uint256 expectedPenalty = amount - expectedMocaReceivable;
                
                // Expect event emission
                vm.expectEmit(true, true, false, true, address(esMoca));
                emit Events.RedemptionScheduled(user1, expectedMocaReceivable, expectedPenalty, redemptionTimestamp);
                
                // User selects redemption option
                vm.prank(user1);
                esMoca.selectRedemptionOption(redemptionOption1_30Days, amount, expectedMocaReceivable, block.timestamp + lockDuration);
                
                // After-state checks
                uint256 userEsMocaBalanceAfter = esMoca.balanceOf(user1);
                uint256 esMocaTotalSupplyAfter = esMoca.totalSupply();
                uint256 mocaReceivableAfter = esMoca.redemptionSchedule(user1, redemptionTimestamp);
                uint256 TOTAL_MOCA_PENDING_REDEMPTION_after = esMoca.TOTAL_MOCA_PENDING_REDEMPTION();
                
                assertEq(userEsMocaBalanceAfter, userEsMocaBalanceBefore - amount, "User esMOCA should decrease by amount");
                assertEq(esMocaTotalSupplyAfter, esMocaTotalSupplyBefore - amount, "Total supply should decrease by amount");
                assertEq(mocaReceivableAfter - mocaReceivableBefore, expectedMocaReceivable, "Moca receivable increased as expected");
                assertEq(TOTAL_MOCA_PENDING_REDEMPTION_after, TOTAL_MOCA_PENDING_REDEMPTION_before + expectedMocaReceivable, "TOTAL_MOCA_PENDING_REDEMPTION should increment");
            }
        }

    // --------- state transition: setWhitelistStatus() ---------

        function testRevert_UserCannot_SetWhitelistStatus() public {
            address[] memory addrs = new address[](1);
            addrs[0] = user1;
            bool isWhitelisted = true;

            vm.startPrank(user1);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.ESCROWED_MOCA_ADMIN_ROLE()));
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
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

            // array + bool
            address[] memory addrs = new address[](1);
            addrs[0] = user1;
            bool isWhitelisted = true;

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.AddressWhitelisted(addrs, isWhitelisted);

            // set whitelist status
            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
            vm.stopPrank();

            // Check after-state: user1 should now be whitelisted
            assertTrue(esMoca.whitelist(user1), "user1 should be whitelisted after");
        }
}

// note: whitelist user1
abstract contract StateT60Days_SetWhitelistStatus is StateT60Days_EnableRedemptionOption {
    function setUp() public virtual override {
        super.setUp();

        // array + bool
        address[] memory addrs = new address[](1);
        addrs[0] = user1;
        bool isWhitelisted = true;

        // set whitelist status
        vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
        vm.stopPrank();

        // calc. expected receivable
        uint256 redemptionAmount = user1Amount / 10;
        (uint128 lockDuration, uint128 receivablePct, ) = esMoca.redemptionOptions(redemptionOption1_30Days);
        uint256 expectedMocaReceivable = (redemptionAmount * receivablePct) / Constants.PRECISION_BASE;


        // user to selectRedemptionOption, so that there are penalties in frozen state to claim via emergencyExitPenalties()
       vm.startPrank(user1);
            esMoca.selectRedemptionOption(redemptionOption1_30Days, redemptionAmount, expectedMocaReceivable, block.timestamp + lockDuration); // 10% of user1's balance
        vm.stopPrank();
    }
}

contract StateT60Days_SetWhitelistStatus_Test is StateT60Days_SetWhitelistStatus {

    // --------- negative tests: setWhitelistStatus() ---------
        function testRevert_EscrowedMocaAdminCannot_SetWhitelistStatus_ZeroAddress() public {
            // array + bool
            address[] memory addrs = new address[](1);
            addrs[0] = address(0);
            bool isWhitelisted = true;

            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.InvalidAddress.selector);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
            vm.stopPrank();
        }

        function testRevert_EscrowedMocaAdminCannot_SetWhitelistStatus_WhitelistStatusUnchanged() public {
            // array + bool
            address[] memory addrs = new address[](1);
            addrs[0] = user1;
            bool isWhitelisted = true;

            vm.startPrank(escrowedMocaAdmin);
            vm.expectRevert(Errors.WhitelistStatusUnchanged.selector);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
            vm.stopPrank();
        }

    // --------- positive tests: setWhitelistStatus() ---------

        function test_EscrowedMocaAdminCan_SetWhitelistStatus_ToFalse() public {
            // Check before-state: user1 should be whitelisted
            assertTrue(esMoca.whitelist(user1), "user1 should be whitelisted before");

            // array + bool
            address[] memory addrs = new address[](1);
            addrs[0] = user1;
            bool isWhitelisted = false;

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.AddressWhitelisted(addrs, isWhitelisted);

            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
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
                // array + bool
                address[] memory addrs = new address[](1);
                addrs[0] = user2;
                bool isWhitelisted = true;

            // Expect event emission
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.AddressWhitelisted(addrs, isWhitelisted);

            // set whitelist status
            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
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
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.MONITOR_ROLE()));
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
    using stdStorage for StdStorage;

    function testRevert_MonitorCannot_Pause_WhenContractIsPaused() public {
        vm.startPrank(monitor);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            esMoca.pause();
        vm.stopPrank();
    }

    //note: whitelisted addresses can still transfer when paused
    function test_User1WhoIsWhitelistedCan_Transfer_WhenPaused() public {
            assertTrue(esMoca.whitelist(user1), "user1 should be whitelisted");
            assertFalse(esMoca.whitelist(user2), "user2 should be whitelisted");

            // before
            uint256 user1BalanceBefore = esMoca.balanceOf(user1);
            uint256 user2BalanceBefore = esMoca.balanceOf(user2);
            uint256 transferAmount = 1 ether;

            vm.startPrank(user1);
            esMoca.transfer(user2, transferAmount);
            vm.stopPrank();

            // after
            uint256 user1BalanceAfter = esMoca.balanceOf(user1);
            uint256 user2BalanceAfter = esMoca.balanceOf(user2);
            assertEq(user1BalanceAfter, user1BalanceBefore - transferAmount, "user1 should have transferred esMoca");
            assertEq(user2BalanceAfter, user2BalanceBefore + transferAmount, "user2 should have received esMoca");
    }
        
    // note: user2 is not whitelisted and therefore cannot initiate transferFrom()
    function test_User1WhoIsWhitelistedCan_TransferFrom_WhenPaused() public {
            assertTrue(esMoca.whitelist(user1), "user1 should be whitelisted");
            assertFalse(esMoca.whitelist(user2), "user2 should be whitelisted");

            // set user2's balance to 1 ether
            stdstore.target(address(esMoca)).sig(esMoca.balanceOf.selector).with_key(user2).checked_write(1 ether);

            // before
            uint256 user1BalanceBefore = esMoca.balanceOf(user1);
            uint256 user2BalanceBefore = esMoca.balanceOf(user2);
            uint256 transferAmount = 1 ether;

            assertTrue(user2BalanceBefore > 0, "user2 should have esMoca");           

            // Setup: user2 approves user1 to spend their tokens
            vm.startPrank(user2);
            esMoca.approve(user1, transferAmount);
            vm.stopPrank();

            // Setup: user1 calls transferFrom to transfer from user2 to user1
            vm.startPrank(user1);
            esMoca.transferFrom(user2, user1, transferAmount);
            vm.stopPrank();

            // after
            uint256 user1BalanceAfter = esMoca.balanceOf(user1);
            uint256 user2BalanceAfter = esMoca.balanceOf(user2);
            assertEq(user1BalanceAfter, user1BalanceBefore + transferAmount, "user1 should have received esMoca");
            assertEq(user2BalanceAfter, user2BalanceBefore - transferAmount, "user2 should have transferred esMoca");
    }

    function test_CronJobCan_ClaimPenalities_WhenPaused() public {
            // Get before state
            uint256 esMocaTreasuryMocaBefore = esMocaTreasury.balance;
            uint256 contractMocaBefore = address(esMoca).balance;
            
            // Verify penalties exist
            uint256 totalClaimable = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY() - esMoca.CLAIMED_PENALTY_FROM_VOTERS() - esMoca.CLAIMED_PENALTY_FROM_TREASURY();
            uint256 penaltyToVoters = esMoca.ACCRUED_PENALTY_TO_VOTERS() - esMoca.CLAIMED_PENALTY_FROM_VOTERS();
            uint256 penaltyToTreasury = esMoca.ACCRUED_PENALTY_TO_TREASURY() - esMoca.CLAIMED_PENALTY_FROM_TREASURY();
            assertTrue(totalClaimable > 0, "totalPenaltiesToClaim should be greater than 0");
            
            // Expect event emission
            vm.expectEmit(true, false, false, true, address(esMoca));
            emit Events.PenaltyClaimed(esMocaTreasury, totalClaimable);

            // claim penalties
            vm.startPrank(cronJob);
            esMoca.claimPenalties{value: 0}();
            vm.stopPrank();

            // Verify after-state
            assertEq(esMocaTreasury.balance, esMocaTreasuryMocaBefore + totalClaimable, "Treasury should receive all penalties");
            assertEq(address(esMoca).balance, contractMocaBefore - totalClaimable, "Contract should have less moca after claiming penalties");
            assertEq(esMoca.ACCRUED_PENALTY_TO_VOTERS(), esMoca.CLAIMED_PENALTY_FROM_VOTERS(), "accrued penalties to voters should be equal to claimed penalties from voters");
            assertEq(esMoca.ACCRUED_PENALTY_TO_TREASURY(), esMoca.CLAIMED_PENALTY_FROM_TREASURY(), "accrued penalties to treasury should be equal to claimed penalties from treasury");
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
            esMoca.selectRedemptionOption(redemptionOption2_60Days, 50 ether, 50 ether, block.timestamp + 60 days);
            vm.stopPrank();
        }

        function testRevert_UserCannot_ClaimRedemptions_WhenPaused() public {
            vm.startPrank(user1);
            vm.expectRevert(Pausable.EnforcedPause.selector);
            uint256[] memory timestamps = new uint256[](1);
            timestamps[0] = block.timestamp + 60 days;
            esMoca.claimRedemptions(timestamps);
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


    // ----- positive tests: functions that can be called when paused ------

        function test_EscrowedMocaAdminCan_SetMocaTransferGasLimit_WhenPaused() public {
            vm.startPrank(escrowedMocaAdmin);
            esMoca.setMocaTransferGasLimit(3000);
            vm.stopPrank();

            assertEq(esMoca.MOCA_TRANSFER_GAS_LIMIT(), 3000);
        }

        function test_EscrowedMocaAdminCan_SetWhitelistStatus_WhenPaused() public {
            // array + bool
            address[] memory addrs = new address[](1);
            addrs[0] = user2;
            bool isWhitelisted = true;

            vm.startPrank(escrowedMocaAdmin);
            esMoca.setWhitelistStatus(addrs, isWhitelisted);
            vm.stopPrank();

        assertTrue(esMoca.whitelist(user2), "user2 should be whitelisted");
        }



    // --------- negative tests: unpause() ---------
        function test_MonitorCannot_Unpause() public {
            vm.startPrank(monitor);
            vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, monitor, esMoca.DEFAULT_ADMIN_ROLE()));
            esMoca.unpause();
            vm.stopPrank();
        }

        function testRevert_MonitorCannot_PauseAgain() public {
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
            esMoca.emergencyExit(users);
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
            esMoca.emergencyExit(users);
        }

        function testRevert_EmergencyExit_NeitherEmergencyExitHandlerNorUser() public {
            address[] memory users = new address[](1);
            users[0] = user1;
         
            vm.prank(user2);
            vm.expectRevert(Errors.OnlyCallableByEmergencyExitHandlerOrUser.selector);
            esMoca.emergencyExit(users);
        }

        function testRevert_UserCannot_EmergencyExit_MultipleUsers() public {
            // array of users to exit
            address[] memory users = new address[](2);
            users[0] = user1;
            users[1] = user1;

            vm.prank(user1);
            vm.expectRevert(Errors.InvalidArray.selector);
            esMoca.emergencyExit(users);
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
            esMoca.emergencyExit(users);

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
            esMoca.emergencyExit(users);

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
            esMoca.emergencyExit(users);


            // user
            assertEq(esMoca.balanceOf(user1), 0, "User esMoca should be burned");
            assertEq(user1.balance, user1NativeMocaBefore + totalMocaExpected, "User should receive esMoca balance + pending redemptions");

            // contract
            assertEq(esMoca.userTotalMocaPendingRedemption(user1), 0, "Pending redemptions should be cleared");
            assertEq(esMoca.TOTAL_MOCA_PENDING_REDEMPTION(), TOTAL_MOCA_PENDING_REDEMPTION_before - user1TotalPendingRedemptions, "Pending redemptions should be cleared");
        }

    // --------- tests: emergencyExitPenalties() ---------


        function test_CronJobCan_ClaimPenalties() public {
            // Calculate claimable penalty
            uint256 totalPenaltyAccrued = esMoca.ACCRUED_PENALTY_TO_VOTERS() + esMoca.ACCRUED_PENALTY_TO_TREASURY();
            uint256 totalClaimable = totalPenaltyAccrued - esMoca.CLAIMED_PENALTY_FROM_VOTERS() - esMoca.CLAIMED_PENALTY_FROM_TREASURY();
            assertTrue(totalClaimable > 0, "No penalties to claim");

            // Record state before
            uint256 treasuryBalanceBefore = esMocaTreasury.balance;
            uint256 contractBalanceBefore = address(esMoca).balance;
            uint256 totalSupplyBefore = esMoca.totalSupply();

            // Expect event from cronjob calling claimPenalties
            vm.expectEmit(true, true, false, true, address(esMoca));
            emit Events.PenaltyClaimed(esMocaTreasury, totalClaimable);

            vm.startPrank(cronJob);
            esMoca.claimPenalties();
            vm.stopPrank();

            // After: treasury increases, contract decreases, supply unchanged
            assertEq(esMocaTreasury.balance, treasuryBalanceBefore + totalClaimable, "Treasury should receive penalties");
            assertEq(address(esMoca).balance, contractBalanceBefore - totalClaimable, "Contract Moca reduced by penalties claimed");
            assertEq(esMoca.totalSupply(), totalSupplyBefore, "esMoca totalSupply unchanged");

            assertEq(esMoca.CLAIMED_PENALTY_FROM_VOTERS(), esMoca.ACCRUED_PENALTY_TO_VOTERS(), "Penalty claimed for voters");
            assertEq(esMoca.CLAIMED_PENALTY_FROM_TREASURY(), esMoca.ACCRUED_PENALTY_TO_TREASURY(), "Penalty claimed for treasury");
        }
}