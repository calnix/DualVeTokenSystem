// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {Events} from "../../src/libraries/Events.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";
import {LowLevelWMoca} from "../../src/LowLevelWMoca.sol";

import "./EscrowedMoca.t.sol";
import "../utils/TestingHarness.sol"; // For GasGuzzler

abstract contract StateT1_TransferGasLimitChanged is StateT0_RedemptionOptionsSet {

    function setUp() public virtual override {
        super.setUp();

        vm.startPrank(escrowedMocaAdmin);
        esMoca.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
        vm.stopPrank();
    }
}

contract StateT1_TransferGasLimitChanged_Test is StateT1_TransferGasLimitChanged {

    function testRevert_SetTransferGasLimit_NotEscrowedMocaAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, esMoca.ESCROWED_MOCA_ADMIN_ROLE()));
        vm.startPrank(user1);
            esMoca.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
        vm.stopPrank();

    }

    function testRevert_MustBeMoreThan2300() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        vm.prank(escrowedMocaAdmin);
        esMoca.setMocaTransferGasLimit(2300 - 1);
    }

    function testCan_User_RedeemInstant_WrapIfNativeTransferFails_OnNewLimit() public {
        // user1 has esMoca from StateT0_EscrowedMoca
        uint256 amount = 10 ether; // redeem amount

        // Deploy GasGuzzler code to user1 address
        // We'll use vm.etch to replace user1 with this contract's code
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;        
        vm.etch(user1, gasGuzzlerCode);

        // Record state before
        uint256 user1EsMocaBefore = esMoca.balanceOf(user1);
        uint256 user1WMocaBalanceBefore = mockWMoca.balanceOf(user1);
        // native moca balances before
        uint256 user1NativeBalanceBefore = user1.balance;
        uint256 contractNativeBalanceBefore = address(esMoca).balance;

        // Calculate expected amounts (Instant redemption: option 3, 20% receivable)
        (uint128 lockDuration, uint128 receivablePct,) = esMoca.redemptionOptions(redemptionOption3_Instant);
        uint256 mocaReceivable = amount * receivablePct / Constants.PRECISION_BASE; // 20%
        uint256 penaltyAmount = amount - mocaReceivable;

        // Expect events
        vm.expectEmit(true, true, true, true, address(esMoca));
        emit Events.Redeemed(user1, mocaReceivable, penaltyAmount);

        // Expect fallback event from LowLevelWMoca (inherited by esMoca)
        // MocaWrappedAndTransferred(address indexed wMoca, address indexed to, uint256 amount)
        vm.expectEmit(true, true, false, true, address(esMoca));
        emit LowLevelWMoca.MocaWrappedAndTransferred(address(mockWMoca), user1, mocaReceivable);

        // -- Redeem Instant: should fallback to sending wMoca --
        // Note: user1 is now a contract. We need to prank it.
        vm.prank(user1);
        DataTypes.RedemptionOption memory expectedOption = DataTypes.RedemptionOption({
             lockDuration: lockDuration,
             receivablePct: receivablePct,
             isEnabled: true
        });
        esMoca.selectRedemptionOption(redemptionOption3_Instant, expectedOption, amount);

        // Check storage state after
        // esMoca burned
        assertEq(esMoca.balanceOf(user1), user1EsMocaBefore - amount, "User esMoca burned");

        // Check wrapped moca balances after
        assertEq(mockWMoca.balanceOf(user1), user1WMocaBalanceBefore + mocaReceivable, "User received wrapped MOCA");
        
        // Check native moca balances after
        // User should NOT have received native moca (it failed)
        assertEq(user1.balance, user1NativeBalanceBefore, "User did not receive native MOCA");
        // Contract native balance should decrease by mocaReceivable (it was wrapped and sent)
        assertEq(address(esMoca).balance, contractNativeBalanceBefore - mocaReceivable, "Contract balance decreased (wrapped)");
    }
}