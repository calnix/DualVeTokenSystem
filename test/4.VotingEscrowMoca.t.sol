// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

import "./utils/TestingHarness.sol";

abstract contract StateD0_Epoch0_Deploy is TestingHarness {    

    // PERIODICITY:  does not account for leap year or leap seconds
    uint256 public constant EPOCH_DURATION = 14 days;                    
    uint256 public constant MIN_LOCK_DURATION = 28 days;            // double the epoch duration for minimum lock duration: for forward decay liveliness
    uint256 public constant MAX_LOCK_DURATION = 728 days;               
    
    /** note: why use dummy variable? 
        When you call EpochMath.getCurrentEpochNumber() directly in a test, these internal functions get inlined into the test contract at compile time. 
        This can cause issues with Foundry's runtime state modifications like vm.warp().
        The issue is that the Solidity optimizer might be evaluating block.timestamp at a different point than expected, 
        or caching values in unexpected ways when dealing with inlined library code.
        So we need to use a dummy variable to prevent the compiler from inlining the functions.
     */
    uint256 private dummy; // so that solidity compiler does not optimize out the functions

    function setUp() public virtual override {
        super.setUp();
    }

    // =============== HELPERS ===============

    function getUserTokenBalances(address user) public view returns (uint128[3] memory) {
        return [
            uint128(mockMoca.balanceOf(user)),
            uint128(esMoca.balanceOf(user)),
            uint128(veMoca.balanceOf(user))
        ];
    }

    function getContractTokenBalances() public view returns (uint128[2] memory) {
        return [
            uint128(mockMoca.balanceOf(address(veMoca))),
            uint128(esMoca.balanceOf(address(veMoca)))
        ];
    }

    function getVeGlobal() public view returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory veGlobal;
        (veGlobal.bias, veGlobal.slope) = veMoca.veGlobal();
        return veGlobal;
    }

    function getGlobalPrincipal() public view returns (uint128[2] memory) {
        return [
            uint128(veMoca.TOTAL_LOCKED_MOCA()),
            uint128(veMoca.TOTAL_LOCKED_ESMOCA())
        ];
    }

    function getUserHistory(address user, uint256 currentEpochStart) public view returns (DataTypes.VeBalance memory) {
        DataTypes.VeBalance memory userHistory;
        (userHistory.bias, userHistory.slope) = veMoca.userHistory(user, currentEpochStart);
        return userHistory;
    }

    function getLock(bytes32 lockId) public view returns (DataTypes.Lock memory) {
        DataTypes.Lock memory lock;
        (bytes32 id, address owner, address delegate, uint128 moca, uint128 esMoca_, uint128 expiry, bool isUnlocked) = veMoca.locks(lockId);
        lock.lockId = id;
        lock.owner = owner;
        lock.delegate = delegate;
        lock.moca = moca;
        lock.esMoca = esMoca_;
        lock.expiry = expiry;
        lock.isUnlocked = isUnlocked;
        return lock;
    }

    function getLockHistory(bytes32 lockId, uint256 index) public view returns (DataTypes.Checkpoint memory) {
        DataTypes.Checkpoint memory checkpoint;
        (checkpoint.veBalance, checkpoint.lastUpdatedAt) = veMoca.lockHistory(lockId, index);
        return checkpoint;
    }
    
    // =============== EPOCH MATH ===============

    ///@dev returns epoch number for a given timestamp
    function getEpochNumber(uint256 timestamp) public returns (uint256) {
        dummy = 1;
        return timestamp / EPOCH_DURATION;
    }

    ///@dev returns current epoch number
    function getCurrentEpochNumber() public returns (uint256) {
        dummy = 1;
        return getEpochNumber(block.timestamp);
    }

    ///@dev returns epoch start time for a given timestamp
    function getEpochStartForTimestamp(uint256 timestamp) public returns (uint256) {
        dummy = 1;
        // intentionally divide first to "discard" remainder
        return (timestamp / EPOCH_DURATION) * EPOCH_DURATION;   // forge-lint: disable-line(divide-before-multiply)
    }

    ///@dev returns epoch end time for a given timestamp
    function getEpochEndForTimestamp(uint256 timestamp) public returns (uint256) {
        dummy = 1;
        return getEpochStartForTimestamp(timestamp) + EPOCH_DURATION;
    }
    

    ///@dev returns current epoch start time | uint128: Checkpoint{veBla, uint128 lastUpdatedAt}
    function getCurrentEpochStart() public returns (uint128) {
        dummy = 1;
        return uint128(getEpochStartForTimestamp(block.timestamp));
    }

    ///@dev returns current epoch end time
    function getCurrentEpochEnd() public returns (uint256) {
        dummy = 1;
        return getEpochEndTimestamp(getCurrentEpochNumber());
    }

    function getEpochStartTimestamp(uint256 epoch) public returns (uint256) {
        dummy = 1;
        return epoch * EPOCH_DURATION;
    }

    ///@dev returns epoch end time for a given epoch number
    function getEpochEndTimestamp(uint256 epoch) public returns (uint256) {
        dummy = 1;
        // end of epoch:N is the start of epoch:N+1
        return (epoch + 1) * EPOCH_DURATION;
    }

    // used in _createLockFor()
    function isValidEpochTime(uint256 timestamp) public returns (bool) {
        dummy = 1;
        return timestamp % EPOCH_DURATION == 0;
    }
}

contract StateD0_Epoch0_Deploy_Test is StateD0_Epoch0_Deploy {
    using stdStorage for StdStorage;
    
    function testRevert_ConstructorChecks() public {
        vm.expectRevert(Errors.InvalidAddress.selector);
        new VotingEscrowMoca(address(0));
    }


    function test_Constructor() public {
        assertEq(address(veMoca.addressBook()), address(addressBook), "addressBook not set correctly");
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), 0);
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), 0);
    }
    // --------------------------negative tests: _createLockFor -----------------------------------------

        function testRevert_CreateLock_InvalidUser() public {
            vm.expectRevert(Errors.InvalidUser.selector);

            vm.prank(address(0));
            veMoca.createLock(uint128(getEpochEndTimestamp(3)), 0, 0, address(0));
        }


        function testRevert_CreateLock_InvalidExpiry() public {
            vm.expectRevert(Errors.InvalidExpiry.selector);
        
            vm.prank(user1);
            veMoca.createLock(1, 1 ether, 0, address(0));
        }

        function testRevert_CreateLock_InvalidAmount() public {
            vm.expectRevert(Errors.InvalidAmount.selector);
        
            vm.prank(user1);
            veMoca.createLock(uint128(getEpochEndTimestamp(3)), 0, 0, address(0));
        }

        //note: prior check "require(EpochMath.isValidEpochTime(expiry), Errors.InvalidExpiry())" will revert first.
        // it would not be possible to reach this test case.
        /*function testRevert_CreateLock_InvalidLockDuration_ExceedMinLockDuration() public {
            vm.expectRevert(Errors.InvalidLockDuration.selector);
            
            vm.prank(user1);
            veMoca.createLock(MIN_LOCK_DURATION - 1, 0, 0, address(0));
        }*/

        function testRevert_CreateLock_InvalidLockDuration_ExceedMaxLockDuration() public {
            vm.expectRevert(Errors.InvalidLockDuration.selector);
            
            vm.prank(user1);
            veMoca.createLock(uint128(MAX_LOCK_DURATION + EPOCH_DURATION), 1 ether, 0, address(0));
        }
        
        /** note: prior check "require(expiry >= EpochMath.getEpochEndTimestamp(EpochMath.getCurrentEpochNumber() + 1), Errors.LockExpiresTooSoon())" will revert first.
        it would not be possible to reach this test case.
        function testRevert_CreateLock_LockExpiresTooSoon() public {
            vm.expectRevert(Errors.LockExpiresTooSoon.selector);
        
            vm.prank(user1);
            veMoca.createLock(uint128(getEpochEndTimestamp(2)), 1 ether, 0, address(0));
        }*/

        function testRevert_CreateLock_DelegateNotRegistered() public {
            vm.expectRevert(Errors.DelegateNotRegistered.selector);
        
            vm.prank(user1);
            veMoca.createLock(uint128(getEpochEndTimestamp(3)), 1 ether, 0, user2);
        }

        function testRevert_CreateLock_InvalidDelegate() public {
            
            // register user2 as delegate
            stdstore
                .target(address(veMoca))
                .sig("isRegisteredDelegate(address)")
                .with_key(user1)
                .checked_write(bool(true));

            assertEq(veMoca.isRegisteredDelegate(user1), true, "User1 is registered as delegate");

            vm.expectRevert(Errors.InvalidDelegate.selector);

            vm.prank(user1);
            veMoca.createLock(uint128(getEpochEndTimestamp(3)), 1 ether, 0, user1);
        }
        
        

    //------------------------------ state transition: user creates lock --------------------------------

    function testCan_User_CreateLock_T1() public {
        // Foundry starts at timestamp 1
        assertEq(block.timestamp, 1, "Block timestamp is 1");
        assertTrue(getCurrentEpochStart() == 0, "Current epoch start time is 0");
        
        // Setup: fund user with MOCA and escrow some to get esMOCA
        vm.startPrank(user1);
            mockMoca.mint(user1, 200 ether);
            mockMoca.approve(address(esMoca), 100 ether);
            esMoca.escrowMoca(100 ether);
            // Approve VotingEscrowMoca to transfer tokens
            mockMoca.approve(address(veMoca), 100 ether);
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // Test parameters
        uint128 expiry = uint128(getEpochEndTimestamp(3)); // expiry at end of epoch 3
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;
        address delegate = address(0);
        bytes32 expectedLockId = generateLockId(block.number, user1);
        uint256 currentEpochStart = getCurrentEpochStart();
        
        // Calculate expected values
        uint128 expectedSlope = (mocaAmount + esMocaAmount) / uint128(MAX_LOCK_DURATION);
        uint128 expectedVeMoca = expectedSlope * expiry;

        assertGt(expectedVeMoca, 0, "More than 0");
        assertGt(expectedSlope, 0, "More than 0");

        // ---------- CAPTURE BEFORE STATE ----------
        
        // Token balances
        uint128[3] memory beforeBalances = getUserTokenBalances(user1);
        uint128[2] memory beforeContractBalances = getContractTokenBalances();

        // Global state
        DataTypes.VeBalance memory beforeGlobal = getVeGlobal();
        uint128[2] memory beforeTotals = getGlobalPrincipal();

        // User state  
        DataTypes.VeBalance memory beforeUser = getUserHistory(user1, currentEpochStart);
        
        // Mappings
        uint256 beforeSlopeChange = veMoca.slopeChanges(expiry);
        uint256 beforeTotalSupplyAt = veMoca.totalSupplyAt(currentEpochStart);
        uint256 beforeUserSlopeChange = veMoca.userSlopeChanges(user1, expiry);

        // ---------- EXECUTE CREATE LOCK ----------
            
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.LockCreated(expectedLockId, user1, delegate, mocaAmount, esMocaAmount, expiry);

            vm.prank(user1);
            bytes32 actualLockId = veMoca.createLock(expiry, mocaAmount, esMocaAmount, delegate);

        // ---------- VERIFY STATE CHANGES ----------

        // 1) Token balances
        assertEq(mockMoca.balanceOf(user1), beforeBalances[0] - mocaAmount, "User MOCA balance");
        assertEq(esMoca.balanceOf(user1), beforeBalances[1] - esMocaAmount, "User esMOCA balance"); 
        
        // 1.1) Check veMoca balance (voting power)
        uint256 userVeMocaBalance = veMoca.balanceOf(user1);
        
        // The voting power calculation in VotingEscrowMoca is: bias - (slope * timestamp) | _getValueAt()
        // where bias = slope * expiry (stored in veBalance)
        // so voting power = slope * expiry - slope * current_timestamp = slope * (expiry - current_timestamp)
        uint256 expectedVotingPower = expectedSlope * (expiry - block.timestamp);
        
        // The balance should be non-zero and match the calculated voting power
        assertGt(userVeMocaBalance, 0, "User should have veMOCA balance");
        assertEq(userVeMocaBalance, expectedVotingPower, "User veMOCA balance matches voting power calculation");
        
        // 1.2) Token balances: contract
        assertEq(mockMoca.balanceOf(address(veMoca)), beforeContractBalances[0] + mocaAmount, "Contract MOCA balance");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeContractBalances[1] + esMocaAmount, "Contract esMOCA balance");

        // 2) LockId generation
        assertEq(actualLockId, expectedLockId, "LockId generation");

        // 3) LockHistory checkpoint
        uint256 lockHistoryLength = veMoca.getLockHistoryLength(expectedLockId);
        assertEq(lockHistoryLength, 1, "Lock history length");
        
        // 3.1) Access the first checkpoint using the generated getter (takes lockId and index)
        DataTypes.Checkpoint memory lockCheckpoint = getLockHistory(expectedLockId, 0);
        assertEq(lockCheckpoint.veBalance.bias, expectedVeMoca, "Lock history bias");
        assertEq(lockCheckpoint.veBalance.slope, expectedSlope, "Lock history slope");
        assertEq(lockCheckpoint.lastUpdatedAt, currentEpochStart, "Lock history lastUpdatedAt");
        
        // 4) Verify lock data
        DataTypes.Lock memory lock = getLock(expectedLockId);
        assertEq(lock.lockId, expectedLockId, "Lock ID");
        assertEq(lock.owner, user1, "Lock owner");
        assertEq(lock.delegate, delegate, "Lock delegate");
        assertEq(lock.moca, mocaAmount, "Lock MOCA amount");
        assertEq(lock.esMoca, esMocaAmount, "Lock esMOCA amount");
        assertEq(lock.expiry, expiry, "Lock expiry");
        assertFalse(lock.isUnlocked, "Lock should not be unlocked");

        // 5) Global totals and mappings: [veGlobal, lastUpdatedTimestamp]
        DataTypes.VeBalance memory afterGlobal = getVeGlobal();
        assertEq(afterGlobal.bias, beforeGlobal.bias + uint128(expectedVeMoca), "veGlobal bias");
        assertEq(afterGlobal.slope, beforeGlobal.slope + uint128(expectedSlope), "veGlobal slope");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdatedTimestamp");

        // 5.1) Global totals and mappings: [TOTAL_LOCKED_MOCA, TOTAL_LOCKED_ESMOCA]
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeTotals[0] + mocaAmount, "TOTAL_LOCKED_MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeTotals[1] + esMocaAmount, "TOTAL_LOCKED_ESMOCA");
        
        // 6) Global totals and mappings [slopeChanges, totalSupplyAt]
        assertEq(veMoca.slopeChanges(expiry), beforeSlopeChange + expectedSlope, "slopeChanges mapping");
        // Note: totalSupplyAt is only updated when advancing epochs, so it may still be 0 for the current epoch
        // We'll verify it's not decreased at least
        assertGe(veMoca.totalSupplyAt(currentEpochStart), beforeTotalSupplyAt, "totalSupplyAt should not decrease");

        // 6) User history and slope changes [userHistory, userSlopeChanges, userLastUpdatedTimestamp]
        DataTypes.VeBalance memory afterUser = getUserHistory(user1, currentEpochStart);
        assertEq(afterUser.bias, beforeUser.bias + uint128(expectedVeMoca), "User history bias");
        assertEq(afterUser.slope, beforeUser.slope + uint128(expectedSlope), "User history slope");
        assertEq(afterUser.bias, lockCheckpoint.veBalance.bias, "User history bias matches lock bias");
        assertEq(afterUser.slope, lockCheckpoint.veBalance.slope, "User history slope matches lock slope");
        assertEq(veMoca.userSlopeChanges(user1, expiry), beforeUserSlopeChange + expectedSlope, "User slope changes");

        // 7) Timestamp synchronization [userLastUpdatedTimestamp, lastUpdatedTimestamp]
        assertEq(veMoca.userLastUpdatedTimestamp(user1), currentEpochStart, "User lastUpdatedTimestamp");
        assertEq(veMoca.userLastUpdatedTimestamp(user1), veMoca.lastUpdatedTimestamp(), "Timestamp sync");
    }
    
    
}

abstract contract StateD14_Epoch1_LockCreatedAtT1 is StateD0_Epoch0_Deploy {

    bytes32 public lock1_Id;
    uint128 public lock1_Expiry;
    uint128 public lock1_MocaAmount;
    uint128 public lock1_EsMocaAmount;
    address public lock1_Delegate;

    function setUp() public virtual override {
        super.setUp();

        assertEq(block.timestamp, 1, "Current timestamp is 1");
        assertTrue(getCurrentEpochNumber() == 0, "Current epoch number is 0");


        // Setup: fund user with MOCA and escrow some to get esMOCA
        vm.startPrank(user1);
            mockMoca.mint(user1, 200 ether);
            mockMoca.approve(address(esMoca), 100 ether);
            esMoca.escrowMoca(100 ether);
            // Approve VotingEscrowMoca to transfer tokens
            mockMoca.approve(address(veMoca), 100 ether);
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // Input params
        lock1_Expiry = uint128(getEpochEndTimestamp(3)); // Fixed to epoch 3
        lock1_MocaAmount = 100 ether;
        lock1_EsMocaAmount = 100 ether;
        lock1_Delegate = address(0);

        vm.prank(user1);
        lock1_Id = veMoca.createLock(lock1_Expiry, lock1_MocaAmount, lock1_EsMocaAmount, lock1_Delegate);

        // After creating first lock
        DataTypes.VeBalance memory firstLockBalance = getUserHistory(user1, 0);
        console2.log("First lock bias at epoch 0:", firstLockBalance.bias);
        console2.log("First lock slope at epoch 0:", firstLockBalance.slope);

        uint256 epoch1StartTime = getEpochStartTimestamp(1);
        console2.log("epoch1StartTime", epoch1StartTime);
        // epoch has incremented by 1
        vm.warp(14 days);
        console2.log("block.timestamp", block.timestamp);

        uint256 currentEpoch = getCurrentEpochNumber();
        assertEq(currentEpoch, 1, "Current epoch number is 1");
    }
}

contract StateD14_Epoch1_LockCreatedAtT1_Test is StateD14_Epoch1_LockCreatedAtT1 {

    function test_Lock2CreatedAtT14_User1() public {
        // epoch has incremented by 1
        assertEq(getCurrentEpochNumber(), 1, "Current epoch number is 1");
        
        // Setup: fund user with MOCA and escrow some to get esMOCA
        vm.startPrank(user1);
            mockMoca.mint(user1, 200 ether);
            mockMoca.approve(address(esMoca), 100 ether);
            esMoca.escrowMoca(100 ether);
            // Approve VotingEscrowMoca to transfer tokens
            mockMoca.approve(address(veMoca), 100 ether);
            esMoca.approve(address(veMoca), 100 ether);
        vm.stopPrank();

        // Test parameters
        uint128 expiry = uint128(getEpochEndTimestamp(3)); // expiry at end of epoch 3
        uint128 mocaAmount = 100 ether;
        uint128 esMocaAmount = 100 ether;
        address delegate = address(0);
        bytes32 expectedLockId = generateLockId(block.number, user1);
        uint256 currentEpochStart = getCurrentEpochStart();
        
        // Calculate expected values
        uint128 expectedSlope = (mocaAmount + esMocaAmount) / uint128(MAX_LOCK_DURATION);
        uint128 expectedVeMoca = expectedSlope * expiry;

        assertGt(expectedVeMoca, 0, "More than 0");
        assertGt(expectedSlope, 0, "More than 0");

        // ---------- CAPTURE BEFORE STATE ----------
        
        // Token balances
        uint128[3] memory beforeBalances = getUserTokenBalances(user1);
        uint128[2] memory beforeContractBalances = getContractTokenBalances();

        // Global state
        DataTypes.VeBalance memory beforeGlobal = getVeGlobal();
        uint128[2] memory beforeTotals = getGlobalPrincipal();

        // User state - Epoch 1 [userHistory for new epoch not updated - since no txn made]
        DataTypes.VeBalance memory beforeUser = getUserHistory(user1, currentEpochStart);
        assertEq(beforeUser.bias, 0, "User bias is 0");
        assertEq(beforeUser.slope, 0, "User slope is 0");

        // User state - Epoch 0 [reflecting lock 1 that was created in Epoch 0]
        DataTypes.VeBalance memory beforeUser_Epoch0 = getUserHistory(user1, 0);
        assertGt(beforeUser_Epoch0.bias, 0, "User bias must be greater than 0");    // from lock 1
        assertGt(beforeUser_Epoch0.slope, 0, "User slope must be greater than 0");

        uint256 userVeMocaBalance_Before = veMoca.balanceOf(user1);
        assertGt(userVeMocaBalance_Before, 0, "User veMOCA balance is greater than 0");

        // Mappings
        uint256 beforeSlopeChange = veMoca.slopeChanges(expiry);
        uint256 beforeTotalSupplyAt = veMoca.totalSupplyAt(currentEpochStart);
        uint256 beforeUserSlopeChange = veMoca.userSlopeChanges(user1, expiry);

        // ---------- EXECUTE CREATE LOCK 2 ----------
            
            vm.expectEmit(true, true, true, true, address(veMoca));
            emit Events.LockCreated(expectedLockId, user1, delegate, mocaAmount, esMocaAmount, expiry);

            vm.prank(user1);
            bytes32 actualLockId2 = veMoca.createLock(expiry, mocaAmount, esMocaAmount, delegate);


        // ---------- VERIFY STATE CHANGES ----------

        // 1) Token balances
        assertEq(mockMoca.balanceOf(user1), beforeBalances[0] - mocaAmount, "User MOCA balance");
        assertEq(esMoca.balanceOf(user1), beforeBalances[1] - esMocaAmount, "User esMOCA balance"); 
        
        // 1.1) Check veMoca balance (voting power)
        uint256 userVeMocaBalance = veMoca.balanceOf(user1); //note: review
        
        // The voting power calculation in VotingEscrowMoca is: bias - (slope * timestamp) | _getValueAt()
        // where bias = slope * expiry (stored in veBalance)
        // so voting power = slope * expiry - slope * current_timestamp = slope * (expiry - current_timestamp)
        uint256 expectedVotingPower_FromLock2 = expectedSlope * (expiry - block.timestamp);
        
        // The balance should be non-zero and match the calculated voting power
        assertGt(userVeMocaBalance, 0, "User should have veMOCA balance");
        assertEq(userVeMocaBalance, expectedVotingPower_FromLock2 + userVeMocaBalance_Before, "User veMOCA balance matches voting power calculation");
        
        // 1.2) Token balances: contract
        assertEq(mockMoca.balanceOf(address(veMoca)), beforeContractBalances[0] + mocaAmount, "Contract MOCA balance");
        assertEq(esMoca.balanceOf(address(veMoca)), beforeContractBalances[1] + esMocaAmount, "Contract esMOCA balance");

        // 2) LockId generation
        assertEq(actualLockId2, expectedLockId, "LockId generation");

        // 3) LockHistory checkpoint
        uint256 lockHistoryLength = veMoca.getLockHistoryLength(expectedLockId);
        assertEq(lockHistoryLength, 1, "Lock history length");
        
        // 3.1) Access the first checkpoint using the generated getter (takes lockId and index)
        DataTypes.Checkpoint memory lockCheckpoint = getLockHistory(expectedLockId, 0);
        assertEq(lockCheckpoint.veBalance.bias, expectedVeMoca, "Lock history bias");
        assertEq(lockCheckpoint.veBalance.slope, expectedSlope, "Lock history slope");
        assertEq(lockCheckpoint.lastUpdatedAt, currentEpochStart, "Lock history lastUpdatedAt");
        
        // 4) Verify lock data
        DataTypes.Lock memory lock = getLock(expectedLockId);
        assertEq(lock.lockId, expectedLockId, "Lock ID");
        assertEq(lock.owner, user1, "Lock owner");
        assertEq(lock.delegate, delegate, "Lock delegate");
        assertEq(lock.moca, mocaAmount, "Lock MOCA amount");
        assertEq(lock.esMoca, esMocaAmount, "Lock esMOCA amount");
        assertEq(lock.expiry, expiry, "Lock expiry");
        assertFalse(lock.isUnlocked, "Lock should not be unlocked");

        // 5) Global totals and mappings: [veGlobal, lastUpdatedTimestamp]
        DataTypes.VeBalance memory afterGlobal = getVeGlobal();
        assertEq(afterGlobal.bias, beforeGlobal.bias + uint128(expectedVeMoca), "veGlobal bias");
        assertEq(afterGlobal.slope, beforeGlobal.slope + uint128(expectedSlope), "veGlobal slope");
        assertEq(veMoca.lastUpdatedTimestamp(), currentEpochStart, "Global lastUpdatedTimestamp");

        // 5.1) Global totals and mappings: [TOTAL_LOCKED_MOCA, TOTAL_LOCKED_ESMOCA]
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), beforeTotals[0] + mocaAmount, "TOTAL_LOCKED_MOCA");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), beforeTotals[1] + esMocaAmount, "TOTAL_LOCKED_ESMOCA");
        
        // 6) Global totals and mappings [slopeChanges, totalSupplyAt]
        assertEq(veMoca.slopeChanges(expiry), beforeSlopeChange + expectedSlope, "slopeChanges mapping");
        // Note: totalSupplyAt is only updated when advancing epochs, so it may still be 0 for the current epoch
        // We'll verify it's not decreased at least
        assertGe(veMoca.totalSupplyAt(currentEpochStart), beforeTotalSupplyAt, "totalSupplyAt should not decrease");
        // uint256 expectedVotingPower_FromLock2 = expectedSlope * (expiry - block.timestamp);
        assertEq(veMoca.totalSupplyAt(currentEpochStart), beforeTotalSupplyAt + expectedVotingPower_FromLock2, "totalSupplyAt should increase by expectedVeMoca: accounting for 1 tick decay");

        // 6) User history and slope changes [userHistory, userSlopeChanges, userLastUpdatedTimestamp]
        DataTypes.VeBalance memory afterUser = getUserHistory(user1, currentEpochStart);    // epoch 1
        assertEq(afterUser.bias, beforeUser_Epoch0.bias + uint128(expectedVeMoca), "User history bias");    // bias at epoch1: bias from Epoch0 + bias from lock 2 [aggregation]
        assertEq(afterUser.slope, beforeUser_Epoch0.slope + uint128(expectedSlope), "User history slope");
        assertEq(veMoca.userSlopeChanges(user1, expiry), beforeUserSlopeChange + expectedSlope, "User slope changes");  // since both locks expire at the same time, slopChanges should be aggregated

        // 7) Timestamp synchronization [userLastUpdatedTimestamp, lastUpdatedTimestamp]
        assertEq(veMoca.userLastUpdatedTimestamp(user1), currentEpochStart, "User lastUpdatedTimestamp");
        assertEq(veMoca.userLastUpdatedTimestamp(user1), veMoca.lastUpdatedTimestamp(), "Timestamp sync");
    }

    // --------------------------state_transition: increaseAmount() | negative tests ----------------------------------

        function testRevert_IncreaseAmount_InvalidLockId() public {
            vm.expectRevert(Errors.InvalidLockId.selector);

            vm.prank(user1);
            veMoca.increaseAmount(bytes32(0), 100 ether, 100 ether);
        }

        function testRevert_IncreaseAmount_InvalidOwner() public {
            vm.expectRevert(Errors.InvalidOwner.selector);

            vm.prank(user2);
            veMoca.increaseAmount(lock1_Id, 100 ether, 100 ether);
        }

        function testRevert_IncreaseAmount_InvalidAmount() public {
            vm.expectRevert(Errors.InvalidAmount.selector);

            vm.prank(user1);
            veMoca.increaseAmount(lock1_Id, 0, 0);
        }

        function testRevert_IncreaseAmount_LockExpiresTooSoon() public {
            vm.expectRevert(Errors.LockExpiresTooSoon.selector);

            vm.warp(lock1_Expiry - 14 days);

            vm.prank(user1);
            veMoca.increaseAmount(lock1_Id, 100 ether, 100 ether);
        }



}

abstract contract StateD28_Epoch2_LockUpdates is StateD14_Epoch1_LockCreatedAtT1 {

}