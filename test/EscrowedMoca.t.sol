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
    function setUp() public virtual override {
        super.setUp();

        // setup
        uint256 amount = 100 ether;
        mockMoca.mint(user1, amount);

        // approve + escrow
        vm.startPrank(user1);
        mockMoca.approve(address(esMoca), amount);
        esMoca.escrowMoca(amount);
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

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(escrowedMocaAdmin);
            // option 1: 30 days, 50% penalty
            esMoca.setRedemptionOption(1, 30 days, 5_000); // 50% penalty
            // option 2: 60 days, 0% penalty
            esMoca.setRedemptionOption(2, 60 days, 0); // 0% penalty
            // option 3: 0 days, 80% penalty
            esMoca.setRedemptionOption(3, 0, 8_000); // 80% penalty
        vm.stopPrank();
    }
}

contract StateT0_RedemptionOptionsSet_Test is StateT0_RedemptionOptionsSet {



}