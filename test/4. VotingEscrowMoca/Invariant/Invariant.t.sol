// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {Handler} from "./Handler.sol";
import {VotingEscrowMoca} from "../../../src/VotingEscrowMoca.sol";
import {Constants} from "../../../src/libraries/Constants.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {EpochMath} from "../../../src/libraries/EpochMath.sol";
import "../../utils/TestingHarness.sol";

contract VotingEscrowMocaInvariant is TestingHarness {
    Handler public handler;

    function setUp() public override {
        super.setUp();

        vm.warp(10 weeks); 

        handler = new Handler(veMoca, mockWMoca, esMoca);

        targetContract(address(handler));
        excludeContract(address(veMoca));
        excludeContract(address(esMoca));
        excludeContract(address(mockWMoca));
        
        vm.startPrank(globalAdmin);
        veMoca.grantRole(veMoca.DEFAULT_ADMIN_ROLE(), handler.admin());
        veMoca.grantRole(Constants.EMERGENCY_EXIT_HANDLER_ROLE, handler.emergencyHandler());
        veMoca.grantRole(Constants.MONITOR_ADMIN_ROLE, globalAdmin);
        veMoca.grantRole(Constants.CRON_JOB_ADMIN_ROLE, globalAdmin);
        veMoca.grantRole(Constants.MONITOR_ROLE, handler.monitor());
        veMoca.grantRole(Constants.CRON_JOB_ROLE, handler.cronJob());
        vm.stopPrank();

        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(address(this)); 
    }

    function delegateRegistrationStatus(address delegate, bool status) external {}

    // ================= INVARIANTS =================

    function invariant_Solvency() external view {
        uint256 contractMoca = address(veMoca).balance;
        uint256 contractEsMoca = esMoca.balanceOf(address(veMoca));

        assertEq(contractMoca, veMoca.TOTAL_LOCKED_MOCA(), "MOCA Solvency Failed");
        assertEq(contractEsMoca, veMoca.TOTAL_LOCKED_ESMOCA(), "esMOCA Solvency Failed");
    }

    function invariant_AssetConservation() external view {
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), handler.ghost_totalLockedMoca(), "Ghost MOCA Mismatch");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), handler.ghost_totalLockedEsMoca(), "Ghost esMOCA Mismatch");
    }

    /// @notice Invariant: On-Chain Lock Inventory vs TOTAL_LOCKED_*
    function invariant_TotalLockedConsistency() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        uint128 sumMoca;
        uint128 sumEsMoca;
        
        for (uint i; i < locks.length; ++i) {
            (,,, uint128 moca, uint128 esMoca,,) = veMoca.locks(locks[i]);
            sumMoca += moca;
            sumEsMoca += esMoca;
        }
        
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), sumMoca, "TOTAL_LOCKED_MOCA mismatch");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), sumEsMoca, "TOTAL_LOCKED_ESMOCA mismatch");
    }
    
    function invariant_TimeConsistency() external view {
        assertLe(veMoca.lastUpdatedTimestamp(), block.timestamp, "Global lastUpdate is in future");
    }

    function invariant_GlobalVotingPowerSum() external view {
        if (veMoca.isFrozen() == 1) return;

        bytes32[] memory locks = handler.getActiveLocks();
        uint128 sumVotingPower = 0;
        uint128 currentTimestamp = uint128(block.timestamp);

        for (uint256 i; i < locks.length; ++i) {
            sumVotingPower += veMoca.getLockVotingPowerAt(locks[i], currentTimestamp);
        }

        uint128 globalTotalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        assertApproxEqAbs(globalTotalSupply, sumVotingPower, 1, "Global VP != Sum of Locks");
    }

    function invariant_VotingPowerConservation() external view {
        if (veMoca.isFrozen() == 1) return;

        address[] memory actors = handler.getActors();
        uint128 totalVP = 0;
        uint128 currentTimestamp = uint128(block.timestamp);

        for (uint i; i < actors.length; ++i) {
            totalVP += veMoca.balanceOfAt(actors[i], currentTimestamp, false); 
            totalVP += veMoca.balanceOfAt(actors[i], currentTimestamp, true);  
        }

        uint128 globalTotalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        assertApproxEqAbs(totalVP, globalTotalSupply, 1, "User VP Sum != Global Supply");
    }

    function invariant_ActiveLockSlope() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            DataTypes.VeBalance memory ve = veMoca.getLockVeBalance(locks[i]);
            (,,, uint128 moca, uint128 esMoca, uint128 expiry,) = veMoca.locks(locks[i]);
            
            uint128 expectedSlope = (moca + esMoca) / EpochMath.MAX_LOCK_DURATION;
            
            assertEq(ve.slope, expectedSlope, "Lock Slope Mismatch");
            assertEq(ve.bias, ve.slope * expiry, "Lock Bias Mismatch");
        }
    }

    function invariant_SlopeChanges() external view {
        if (veMoca.isFrozen() == 1) return; 
        
        bytes32[] memory locks = handler.getActiveLocks();
        
        for (uint i; i < locks.length; ++i) {
            (,,,,, uint128 targetExpiry,) = veMoca.locks(locks[i]);
            
            uint128 expectedSlopeChange;
            
            for (uint j; j < locks.length; ++j) {
                (,,, uint128 m, uint128 es, uint128 e,) = veMoca.locks(locks[j]);
                if (e == targetExpiry) {
                     expectedSlopeChange += (m + es) / EpochMath.MAX_LOCK_DURATION;
                }
            }
            assertEq(veMoca.slopeChanges(targetExpiry), expectedSlopeChange, "SlopeChanges Mismatch");
        }
    }

    function invariant_LockExpiryAlignment() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (,,,,, uint128 expiry,) = veMoca.locks(locks[i]);
            assertEq(expiry % EpochMath.EPOCH_DURATION, 0, "Lock expiry not aligned to epoch");
        }
    }

    function invariant_ProtocolState() external view {
        if (veMoca.isFrozen() == 1) {
            assertTrue(veMoca.paused(), "Frozen but not Paused");
        }
    }

    function invariant_UnlockedLockState() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (,,, uint128 moca, uint128 esMoca,, bool isUnlocked) = veMoca.locks(locks[i]);
            if (isUnlocked) {
                assertEq(moca, 0, "Unlocked lock has moca");
                assertEq(esMoca, 0, "Unlocked lock has esMoca");
            }
        }
    }

    function invariant_DelegationRegistration() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (,, address delegate,,,,) = veMoca.locks(locks[i]);
            if (delegate != address(0)) {
                assertTrue(veMoca.isRegisteredDelegate(delegate), "Delegate not registered");
            }
        }
    }

    function invariant_NoSelfDelegation() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (, address owner, address delegate,,,,) = veMoca.locks(locks[i]);
            if (delegate != address(0)) {
                assertNotEq(owner, delegate, "Owner delegated to self");
            }
        }
    }

    function invariant_VotingPowerDecay() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        uint128 currentTimestamp = uint128(block.timestamp);
        
        for (uint i; i < locks.length; ++i) {
            (,,,,, uint128 expiry,) = veMoca.locks(locks[i]);
            if (currentTimestamp >= expiry) {
                uint128 vp = veMoca.getLockVotingPowerAt(locks[i], currentTimestamp);
                assertEq(vp, 0, "Expired lock has voting power");
            }
        }
    }

    function invariant_UserBalanceBounded() external view {
        address[] memory actors = handler.getActors();
        uint128 currentTimestamp = uint128(block.timestamp);
        uint128 totalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);

        for (uint i; i < actors.length; ++i) {
            uint128 userVP = veMoca.balanceOfAt(actors[i], currentTimestamp, false);
            uint128 delegateVP = veMoca.balanceOfAt(actors[i], currentTimestamp, true);
            
            assertLe(userVP, totalSupply, "User Personal VP > Total Supply");
            assertLe(delegateVP, totalSupply, "User Delegated VP > Total Supply");
        }
    }
}

/** running

run all tests in the file
    forge test --match-path "test/4. VotingEscrowMoca/Invariant/Invariant.t.sol"

run by contract name
    forge test --match-contract VotingEscrowMocaInvariant

run all invariants
    forge test --match-contract Invariant

Run with Detailed Output (Debugging)
    forge test --match-path "test/4. VotingEscrowMoca/Invariant/Invariant.t.sol" -vvvv

Run w/ config
    forge test --match-path "test/4. VotingEscrowMoca/Invariant/Invariant.t.sol" --invariant-runs 500 --invariant-depth 50

*/