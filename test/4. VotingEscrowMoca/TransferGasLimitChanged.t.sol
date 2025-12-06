// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

import "./veUserTest.t.sol";

// Inherits from StateE3_User2_CreateLock3 where lock1 is about to expire
// lock1 expires at end of epoch 3, we warp to epoch 4 to unlock
abstract contract StateE3_TransferGasLimitChanged is StateE3_User2_CreateLock3 {

    function setUp() public virtual override {
        super.setUp();

        // Change gas limit using votingEscrowMocaAdmin
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }
}

contract StateE3_TransferGasLimitChanged_Test is StateE3_TransferGasLimitChanged {

    // ---- Negative tests: setMocaTransferGasLimit ----

    function testRevert_SetTransferGasLimit_NotVotingEscrowMocaAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, 
                user1, 
                Constants.VOTING_ESCROW_MOCA_ADMIN_ROLE
            )
        );
        vm.prank(user1);
        veMoca.setMocaTransferGasLimit(MOCA_TRANSFER_GAS_LIMIT * 2);
    }

    function testRevert_SetTransferGasLimit_MustBeAtLeast2300() public {
        vm.expectRevert(Errors.InvalidGasLimit.selector);
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setMocaTransferGasLimit(2300 - 1);
    }

    // ---- Positive test: setMocaTransferGasLimit ----

    function test_SetTransferGasLimit_Success() public {
        uint256 oldLimit = veMoca.MOCA_TRANSFER_GAS_LIMIT();
        uint256 newLimit = 10000;

        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.MocaTransferGasLimitUpdated(oldLimit, newLimit);

        vm.prank(votingEscrowMocaAdmin);
        veMoca.setMocaTransferGasLimit(newLimit);

        assertEq(veMoca.MOCA_TRANSFER_GAS_LIMIT(), newLimit, "Gas limit should be updated");
    }

    // ---- Test: Wrap fallback during unlock when native transfer fails ----

    function test_Unlock_WrapIfNativeTransferFails_OnNewLimit() public {
        // ============ 1) Warp to Epoch 4 so lock1 is expired ============
        uint128 epoch4StartTimestamp = uint128(getEpochStartTimestamp(4));
        vm.warp(epoch4StartTimestamp);
        assertEq(getCurrentEpochNumber(), 4, "Current epoch number is 4");

        // ============ 2) Verify lock1 is expired and can be unlocked ============
        DataTypes.Lock memory lock1Before = getLock(lock1_Id);
        assertEq(lock1Before.expiry, epoch4StartTimestamp, "Lock1 expiry must equal epoch 4 start");
        assertFalse(lock1Before.isUnlocked, "Lock1 must not be unlocked yet");
        assertGt(lock1Before.moca, 0, "Lock1 must have moca");

        // ============ 3) Deploy GasGuzzler and replace user1's code ============
        // This makes user1 have an expensive receive function that exceeds gas limit
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;
        vm.etch(user1, gasGuzzlerCode);

        // ============ 4) Record state before unlock ============
        uint256 user1NativeBalanceBefore = user1.balance;
        uint256 user1WMocaBalanceBefore = mockWMoca.balanceOf(user1);
        uint256 user1EsMocaBalanceBefore = esMoca.balanceOf(user1);
        
        uint256 contractNativeBalanceBefore = address(veMoca).balance;
        uint256 contractWMocaBalanceBefore = mockWMoca.balanceOf(address(veMoca));
        
        uint128 totalLockedMocaBefore = veMoca.TOTAL_LOCKED_MOCA();
        uint128 totalLockedEsMocaBefore = veMoca.TOTAL_LOCKED_ESMOCA();

        // ============ 5) Expect event emission ============
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.LockUnlocked(lock1_Id, user1, lock1Before.moca, lock1Before.esMoca);

        // ============ 6) Execute unlock - should fallback to sending wMoca ============
        vm.prank(user1);
        veMoca.unlock(lock1_Id);

        // ============ 7) Verify lock state after ============
        DataTypes.Lock memory lock1After = getLock(lock1_Id);
        assertTrue(lock1After.isUnlocked, "Lock1 must be marked as unlocked");
        assertEq(lock1After.moca, 0, "Lock1 moca must be 0 after unlock");
        assertEq(lock1After.esMoca, 0, "Lock1 esMoca must be 0 after unlock");

        // ============ 8) Verify global totals decreased ============
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), totalLockedMocaBefore - lock1Before.moca, "TOTAL_LOCKED_MOCA must decrease");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), totalLockedEsMocaBefore - lock1Before.esMoca, "TOTAL_LOCKED_ESMOCA must decrease");

        // ============ 9) Verify wrapped MOCA was sent (native transfer failed) ============
        // User should receive wrapped MOCA, not native MOCA
        assertEq(user1.balance, user1NativeBalanceBefore, "User1 did not receive native MOCA (transfer failed)");
        assertEq(mockWMoca.balanceOf(user1), user1WMocaBalanceBefore + lock1Before.moca, "User1 received wrapped MOCA instead");
        
        // Contract native balance should decrease (wrapped to wMOCA and sent)
        assertEq(address(veMoca).balance, contractNativeBalanceBefore - lock1Before.moca, "Contract native MOCA decreased");
        assertEq(mockWMoca.balanceOf(address(veMoca)), 0, "Contract has no wrapped MOCA");

        // ============ 10) Verify esMOCA was sent normally ============
        assertEq(esMoca.balanceOf(user1), user1EsMocaBalanceBefore + lock1Before.esMoca, "User1 received esMOCA");
    }

    // ---- Test: Wrap fallback during emergencyExit when native transfer fails ----

    function test_EmergencyExit_WrapIfNativeTransferFails_OnNewLimit() public {
        // ============ 1) Pause and freeze contract ============
        vm.prank(monitor);
        veMoca.pause();
        
        vm.prank(globalAdmin);
        veMoca.freeze();

        // ============ 2) Get lock2 (user1's active lock) state ============
        DataTypes.Lock memory lock2Before = getLock(lock2_Id);
        assertFalse(lock2Before.isUnlocked, "Lock2 should not be unlocked");
        assertGt(lock2Before.moca, 0, "Lock2 must have moca");

        // ============ 3) Deploy GasGuzzler and replace user1's code ============
        GasGuzzler gasGuzzler = new GasGuzzler();
        bytes memory gasGuzzlerCode = address(gasGuzzler).code;
        vm.etch(user1, gasGuzzlerCode);

        // ============ 4) Record state before emergencyExit ============
        uint256 user1NativeBalanceBefore = user1.balance;
        uint256 user1WMocaBalanceBefore = mockWMoca.balanceOf(user1);
        uint256 user1EsMocaBalanceBefore = esMoca.balanceOf(user1);
        
        uint256 contractNativeBalanceBefore = address(veMoca).balance;

        // ============ 5) Prepare lockIds ============
        bytes32[] memory lockIds = new bytes32[](1);
        lockIds[0] = lock2_Id;

        // ============ 6) Expect event emission ============
        vm.expectEmit(true, true, true, true, address(veMoca));
        emit Events.EmergencyExit(lockIds, 1, lock2Before.moca, lock2Before.esMoca);

        // ============ 7) Execute emergencyExit ============
        vm.prank(emergencyExitHandler);
        (uint256 totalLocks, uint256 totalMoca, uint256 totalEsMoca) = veMoca.emergencyExit(lockIds);

        // ============ 8) Verify return values ============
        assertEq(totalLocks, 1, "Should process 1 lock");
        assertEq(totalMoca, lock2Before.moca, "Total MOCA returned must match");
        assertEq(totalEsMoca, lock2Before.esMoca, "Total esMOCA returned must match");

        // ============ 9) Verify wrapped MOCA was sent (native transfer failed) ============
        assertEq(user1.balance, user1NativeBalanceBefore, "User1 did not receive native MOCA");
        assertEq(mockWMoca.balanceOf(user1), user1WMocaBalanceBefore + lock2Before.moca, "User1 received wrapped MOCA");
        assertEq(address(veMoca).balance, contractNativeBalanceBefore - lock2Before.moca, "Contract native MOCA decreased");

        // ============ 10) Verify esMOCA was sent normally ============
        assertEq(esMoca.balanceOf(user1), user1EsMocaBalanceBefore + lock2Before.esMoca, "User1 received esMOCA");
    }
}