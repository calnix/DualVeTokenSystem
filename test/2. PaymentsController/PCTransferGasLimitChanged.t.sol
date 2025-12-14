// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";

import "./PaymentsController.t.sol";

abstract contract StateT11_TransferGasLimitChanged is StateT10_Verifier1StakeMOCA {

    function setUp() public virtual override {
        super.setUp();

        vm.prank(paymentsControllerAdmin);
        paymentsController.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }
}

contract StateT11_TransferGasLimitChanged_Test is StateT11_TransferGasLimitChanged {


    function testRevert_SetTransferGasLimit_NotPaymentsControllerAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, verifier1Asset, paymentsController.PAYMENTS_CONTROLLER_ADMIN_ROLE()));
        vm.prank(verifier1Asset);
        paymentsController.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }

    function testRevert_MustBeMoreThan2300() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        vm.prank(paymentsControllerAdmin);
        paymentsController.setMocaTransferGasLimit(2300 - 1);
    }


    function testCan_Verifier1StakeMOCA_WrapIfNativeTransferFails_OnNewLimit() public {
        // Deploy a contract with expensive receive function that exceeds MOCA_TRANSFER_GAS_LIMIT
        // We'll use vm.etch to replace verifier1Asset with this contract's code
        
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;        
        vm.etch(verifier1Asset, gasGuzzlerCode);

        uint128 amount = 10 ether;

        // Record state before
        uint256 verifier1MocaStakedBefore = paymentsController.getVerifier(verifier1).mocaStaked;
        uint256 totalMocaStakedBefore = paymentsController.TOTAL_MOCA_STAKED();
        // wrapped moca balances before
        uint256 verifier1WMocaBalanceBefore = mockWMoca.balanceOf(verifier1Asset);
        uint256 contractWMocaBalanceBefore = mockWMoca.balanceOf(address(paymentsController));
        // native moca balances before
        uint256 verifier1AssetNativeBalanceBefore = verifier1Asset.balance;
        uint256 contractNativeBalanceBefore = address(paymentsController).balance;

        // Expect event emission
        vm.expectEmit(true, true, false, true, address(paymentsController));
        emit Events.VerifierMocaUnstaked(verifier1, verifier1Asset, amount);

        // -- Unstake: should fallback to sending wMoca --
        vm.prank(verifier1Asset);
        paymentsController.unstakeMoca(verifier1, amount);


        // Check storage state after
        DataTypes.Verifier memory verifier = paymentsController.getVerifier(verifier1);
        assertEq(verifier.mocaStaked, verifier1MocaStakedBefore - amount, "VerifierAssetAddress unstaked MOCA");
        assertEq(paymentsController.TOTAL_MOCA_STAKED(), totalMocaStakedBefore - amount, "TOTAL_MOCA_STAKED not updated correctly");

        // Check wrapped moca balances after
        assertEq(mockWMoca.balanceOf(verifier1Asset), verifier1WMocaBalanceBefore + amount, "VerifierAssetAddress received wrapped MOCA");
        assertEq(mockWMoca.balanceOf(address(paymentsController)), 0, "Contract has no wrapped MOCA");

        // Check native moca balances after
        assertEq(verifier1Asset.balance, verifier1AssetNativeBalanceBefore, "VerifierAssetAddress did not receive native MOCA");
        assertEq(address(paymentsController).balance, contractNativeBalanceBefore - amount, "Contract gave out native MOCA");
    }

}