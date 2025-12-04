// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {Handler} from "./Handler.sol";
import {VotingEscrowMoca} from "../../../src/VotingEscrowMoca.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";
import {EpochMath} from "../../../src/libraries/EpochMath.sol";
import "../../utils/TestingHarness.sol";

contract VotingEscrowMocaInvariant is TestingHarness {
    Handler public handler;

    function setUp() public override {
        super.setUp();

        // 1. Advance time to ensure Epoch > 0 (avoids underflow in epoch calcs)
        vm.warp(10 weeks); 

        // 2. Initialize Handler
        handler = new Handler(veMoca, mockWMoca, esMoca);

        // 3. Configure Fuzzing
        targetContract(address(handler));
        
        // exclude contracts that we don't want to fuzz directly
        excludeContract(address(veMoca));
        excludeContract(address(esMoca));
        excludeContract(address(mockWMoca));
        
        // 4. Set VotingController to the Handler or a mock so we can register delegates
        // For simplicity, we assume the handler pranks the existing VC address
        // Or we can update VE to point to a dummy VC
        vm.prank(votingEscrowMocaAdmin);
        veMoca.setVotingController(address(this)); // Test contract acts as VC for registration checks
    }

    // Allow handler to register delegates by acting as VC
    function delegateRegistrationStatus(address delegate, bool status) external {
        // dummy impl to satisfy interface if needed, or Handler calls veMoca directly via prank
    }

    // ================= INVARIANTS =================

    /// @notice Invariant A: Solvency
    /// The contract must hold at least as many assets as it tracks in TOTAL_LOCKED variables.
    function invariant_Solvency() external view {
        uint256 contractMoca = address(veMoca).balance;
        uint256 contractEsMoca = esMoca.balanceOf(address(veMoca));

        assertEq(contractMoca, veMoca.TOTAL_LOCKED_MOCA(), "MOCA Solvency Failed");
        assertEq(contractEsMoca, veMoca.TOTAL_LOCKED_ESMOCA(), "esMOCA Solvency Failed");
    }

    /// @notice Invariant B: Conservation of Assets (Ghost Checking)
    /// The contract's tracked totals must match the Handler's shadow accounting.
    /// This ensures no assets are created out of thin air or lost during lock/unlock.
    function invariant_AssetConservation() external view {
        assertEq(veMoca.TOTAL_LOCKED_MOCA(), handler.ghost_totalLockedMoca(), "Ghost MOCA Mismatch");
        assertEq(veMoca.TOTAL_LOCKED_ESMOCA(), handler.ghost_totalLockedEsMoca(), "Ghost esMOCA Mismatch");
    }
    
    /// @notice Invariant D: Global State Hygiene
    /// lastUpdatedTimestamp should never be in the future relative to block.timestamp
    function invariant_TimeConsistency() external view {
        assertLe(veMoca.lastUpdatedTimestamp(), block.timestamp, "Global lastUpdate is in future");
    }

    /// @notice Invariant F: Global Voting Power Integrity
    /// Calculates the sum of voting power of all active locks maintained by the Handler
    /// and compares it to the contract's `totalSupplyAtTimestamp`.
    function invariant_GlobalVotingPowerSum() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        uint128 sumVotingPower = 0;
        uint128 currentTimestamp = uint128(block.timestamp);

        for (uint256 i = 0; i < locks.length; i++) {
            // Get VP using contract's view function for the specific lock
            // This relies on the individual lock math being correct (checked by unit tests)
            // But validates that the Aggregated Global State matches the Sum of Parts.
            sumVotingPower += veMoca.getLockVotingPowerAt(locks[i], currentTimestamp);
        }

        uint128 globalTotalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
        
        // Allow for tiny precision loss if any, though VE math usually exact for integer steps
        // If exact match fails due to 1-wei rounding (rare in this implementation), use approx.
        assertApproxEqAbs(globalTotalSupply, sumVotingPower, 1, "Global VP != Sum of Locks");
    }

    /// @notice Invariant G: Delegation Sum Check
    /// For any user, their 'balanceOfAt(user, now, isDelegate=true)' should equal:
    /// Sum(lock.votingPower) for all locks delegated to them.
    /// This is hard to check efficiently without an off-chain indexer, but we can sample random actors.
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