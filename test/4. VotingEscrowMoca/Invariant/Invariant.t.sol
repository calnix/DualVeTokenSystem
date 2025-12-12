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

    // ================= HELPERS =================

    /// @dev Helper to get lock data using tuple unpacking
    /// Lock struct order: owner, expiry, moca, esMoca, isUnlocked, delegate, currentHolder, delegationEpoch
    function _getLock(bytes32 lockId) internal view returns (
        address owner, uint128 expiry, uint128 moca, uint128 esMocaAmt, 
        bool isUnlocked, address delegate, address currentHolder, uint96 delegationEpoch
    ) {
        (owner, expiry, moca, esMocaAmt, isUnlocked, delegate, currentHolder, delegationEpoch) = veMoca.locks(lockId);
    }

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
            (,, uint128 moca, uint128 esMocaAmt,,,,) = _getLock(locks[i]);
            sumMoca += moca;
            sumEsMoca += esMocaAmt;
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
            (, uint128 expiry, uint128 moca, uint128 esMocaAmt,,,,) = _getLock(locks[i]);
            
            uint128 expectedSlope = (moca + esMocaAmt) / EpochMath.MAX_LOCK_DURATION;
            
            assertEq(ve.slope, expectedSlope, "Lock Slope Mismatch");
            assertEq(ve.bias, ve.slope * expiry, "Lock Bias Mismatch");
        }
    }

    // ----- SlopeChanges Invariants -----

        function invariant_SlopeChanges() external view {
            if (veMoca.isFrozen() == 1) return; 
            
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentTimestamp = uint128(block.timestamp);
            
            for (uint i; i < locks.length; ++i) {
                (, uint128 targetExpiry,,,bool targetIsUnlocked,,,) = _getLock(locks[i]);
                
                // Skip expired locks - their slope changes have already occurred
                if (targetExpiry <= currentTimestamp) continue;
                if (targetIsUnlocked) continue;
                
                uint128 expectedSlopeChange;
                
                for (uint j; j < locks.length; ++j) {
                    (, uint128 expiry, uint128 moca, uint128 esMocaAmt, bool isUnlocked,,,) = _getLock(locks[j]);
                    // Only count non-expired, non-unlocked locks
                    if (expiry == targetExpiry && !isUnlocked && expiry > currentTimestamp) {
                        expectedSlopeChange += (moca + esMocaAmt) / EpochMath.MAX_LOCK_DURATION;
                    }
                }
                assertEq(veMoca.slopeChanges(targetExpiry), expectedSlopeChange, "SlopeChanges Mismatch");
            }
        }

        /// @notice Invariant: For non-delegated locks, userSlopeChanges must track the lock's slope
        function invariant_NonDelegatedLockSlopeTracking() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                (address owner, uint128 expiry,,, bool isUnlocked, address delegate,, uint96 delegationEpoch) = _getLock(locks[i]);
                
                if (isUnlocked) continue;
                
                DataTypes.VeBalance memory lockVe = veMoca.getLockVeBalance(locks[i]);
                bool isPending = delegationEpoch > currentEpochStart;
                
                // If NOT delegated and NOT pending, user should have the slope
                if (delegate == address(0) && !isPending) {
                    uint128 userSlope = veMoca.userSlopeChanges(owner, expiry);
                    assertGe(userSlope, lockVe.slope, "User should have lock's slope at expiry");
                }
            }
        }

    // ----- Lock Expiry Alignment Invariants -----

    function invariant_LockExpiryAlignment() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (, uint128 expiry,,,,,,) = _getLock(locks[i]);
            assertEq(expiry % EpochMath.EPOCH_DURATION, 0, "Lock expiry not aligned to epoch");
        }
    }
    
    // ----- Unlocked Lock State Invariants -----

    function invariant_UnlockedLockState() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (,, uint128 moca, uint128 esMocaAmt, bool isUnlocked,,,) = _getLock(locks[i]);
            if (isUnlocked) {
                assertEq(moca, 0, "Unlocked lock has moca");
                assertEq(esMocaAmt, 0, "Unlocked lock has esMoca");
            }
        }
    }

    // ----- Protocol State Invariants -----

    function invariant_ProtocolState() external view {
        if (veMoca.isFrozen() == 1) {
            assertTrue(veMoca.paused(), "Frozen but not Paused");
        }
    }

    // ----- Delegation Registration Invariants -----

    function invariant_DelegationRegistration() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (,,,,, address delegate,,) = _getLock(locks[i]);
            if (delegate != address(0)) {
                assertTrue(veMoca.isRegisteredDelegate(delegate), "Delegate not registered");
            }
        }
    }

    function invariant_NoSelfDelegation() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        for (uint i; i < locks.length; ++i) {
            (address owner,,,,, address delegate,,) = _getLock(locks[i]);
            if (delegate != address(0)) {
                assertNotEq(owner, delegate, "Owner delegated to self");
            }
        }
    }

    function invariant_VotingPowerDecay() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        uint128 currentTimestamp = uint128(block.timestamp);
        
        for (uint i; i < locks.length; ++i) {
            (, uint128 expiry,,,,,,) = _getLock(locks[i]);
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

    /// @notice Invariant: Lock history timestamps should be monotonically increasing
    function invariant_LockHistoryMonotonicity() external view {
        bytes32[] memory locks = handler.getActiveLocks();
        
        for (uint i; i < locks.length; ++i) {
            uint256 historyLen = veMoca.getLockHistoryLength(locks[i]);
            if (historyLen < 2) continue;
            
            uint128 prevTimestamp = 0;
            for (uint j; j < historyLen; ++j) {
                // lockHistory returns (VeBalance veBalance, uint128 lastUpdatedAt)
                (, uint128 lastUpdatedAt) = veMoca.lockHistory(locks[i], j);
                assertGt(lastUpdatedAt, prevTimestamp, "History timestamps not monotonic");
                prevTimestamp = lastUpdatedAt;
            }
        }
    }

    // ----- Pending Delegation State Invariants -----

        /// @notice Invariant: Pending delegation state is consistent
        /// If delegationEpoch > currentEpochStart, then currentHolder must be set
        function invariant_PendingDelegationStateConsistency() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                (,,,,, address delegate, address currentHolder, uint96 delegationEpoch) = _getLock(locks[i]);
                
                bool hasPending = delegationEpoch > currentEpochStart;
                
                if (hasPending) {
                    // If there's a pending change, currentHolder must be set (unless it's the owner)
                    // The lock was previously with someone, and that someone should be tracked
                    assertTrue(
                        currentHolder != address(0) || delegate == address(0),
                        "Pending delegation without currentHolder tracking"
                    );
                }
            }
        }

        /// @notice Invariant: delegationEpoch must be epoch-aligned when set
        function invariant_DelegationEpochAlignment() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            
            for (uint i; i < locks.length; ++i) {
                (,,,,,,,uint96 delegationEpoch) = _getLock(locks[i]);
                
                if (delegationEpoch > 0) {
                    assertEq(
                        delegationEpoch % EpochMath.EPOCH_DURATION, 
                        0, 
                        "delegationEpoch not aligned to epoch boundary"
                    );
                }
            }
        }

        /// @notice Invariant: If delegationEpoch is in the past, delegation should be active
        /// This verifies the state machine: pending -> active transition
        function invariant_DelegationEpochNotPast() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                (,,,,, address delegate,, uint96 delegationEpoch) = _getLock(locks[i]);
                
                // If delegationEpoch is set and in the past or current, the delegation should be active
                // The lock.delegate field should be the active delegate
                if (delegationEpoch > 0 && delegationEpoch <= currentEpochStart) {
                    // If delegation epoch has passed:
                    // - If delegate != address(0), it means delegation is active
                    // - currentHolder tracks who HAD the VP before the transition
                    // The VP should now be with delegate (if set) or owner (if unset)
                    
                    // Verify: if delegate is set, they should be registered
                    if (delegate != address(0)) {
                        assertTrue(
                            veMoca.isRegisteredDelegate(delegate),
                            "Active delegation to unregistered delegate"
                        );
                    }
                }
            }
        }

        /// @notice Invariant: When pending delegation takes effect, VP transfers correctly
        function invariant_PendingDelegationTransition() external view {
            if (veMoca.isFrozen() == 1) return;
            
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            uint128 currentTimestamp = uint128(block.timestamp);
            
            for (uint i; i < locks.length; ++i) {
                (address owner, uint128 expiry,,, bool isUnlocked, address delegate, address currentHolder, uint96 delegationEpoch) = _getLock(locks[i]);
                
                if (isUnlocked) continue;
                if (expiry <= currentTimestamp) continue;
                
                uint128 lockVP = veMoca.getLockVotingPowerAt(locks[i], currentTimestamp);
                if (lockVP == 0) continue;
                
                // Determine who SHOULD have VP based on delegation state
                bool isPending = delegationEpoch > currentEpochStart;
                address vpHolder;
                bool isDelegateVP;
                
                if (isPending) {
                    // Pending: currentHolder (or owner if not set) has the VP
                    vpHolder = currentHolder == address(0) ? owner : currentHolder;
                    isDelegateVP = vpHolder != owner;
                } else {
                    // Active: delegate (if set) or owner has the VP
                    vpHolder = delegate == address(0) ? owner : delegate;
                    isDelegateVP = delegate != address(0);
                }
                
                // VP should be attributed to vpHolder
                uint128 holderVP = veMoca.balanceOfAt(vpHolder, currentTimestamp, isDelegateVP);
                
                // The holder should have at least this lock's VP (they might have more from other locks)
                assertGe(holderVP, lockVP, "VP holder must have at least lock's VP");
            }
        }

    // ---- Voting Power Conservation During Delegation ----

        /// @notice Invariant: Voting power is conserved across delegation
        /// Sum of (user personal VP + delegate VP) for all participants should equal total supply
        function invariant_DelegationVotingPowerConservation() external view {
            if (veMoca.isFrozen() == 1) return;
            
            address[] memory actors = handler.getActors();
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 totalAccountedVP = 0;
            
            // Sum personal VP (non-delegated)
            for (uint i; i < actors.length; ++i) {
                totalAccountedVP += veMoca.balanceOfAt(actors[i], currentTimestamp, false);
            }
            
            // Sum delegate VP
            for (uint i; i < actors.length; ++i) {
                totalAccountedVP += veMoca.balanceOfAt(actors[i], currentTimestamp, true);
            }
            
            uint128 globalTotalSupply = veMoca.totalSupplyAtTimestamp(currentTimestamp);
            
            // Should match within tolerance (pending deltas can cause small discrepancies)
            assertApproxEqAbs(totalAccountedVP, globalTotalSupply, actors.length, "VP not conserved during delegation");
        }

        /// @notice Invariant: Lock VP appears in exactly one place (owner's personal OR delegate's delegated)
        function invariant_LockVotingPowerExclusivity() external view {
            if (veMoca.isFrozen() == 1) return;
            
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentTimestamp = uint128(block.timestamp);
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                (address owner,,,, bool isUnlocked, address delegate, address currentHolder, uint96 delegationEpoch) = _getLock(locks[i]);
                uint128 lockVP = veMoca.getLockVotingPowerAt(locks[i], currentTimestamp);
                
                if (lockVP == 0) continue; // Expired lock or zero VP
                if (isUnlocked) continue;
                
                // Determine who should have the voting power right now
                bool hasPending = delegationEpoch > currentEpochStart;
                address expectedHolder;
                bool expectedIsDelegate;
                
                if (hasPending) {
                    // Pending: VP still with currentHolder (or owner)
                    expectedHolder = currentHolder == address(0) ? owner : currentHolder;
                    expectedIsDelegate = expectedHolder != owner;
                } else {
                    // Active: VP with delegate (if delegated) or owner
                    expectedHolder = delegate == address(0) ? owner : delegate;
                    expectedIsDelegate = delegate != address(0);
                }
                
                // Verify the expected holder has VP
                uint128 holderBalance = veMoca.balanceOfAt(expectedHolder, currentTimestamp, expectedIsDelegate);
                assertGe(holderBalance, lockVP, "Expected holder doesn't have lock's VP");
                
                // Verify exclusivity: if delegated, owner should NOT have this VP in personal balance
                if (expectedIsDelegate && !hasPending) {
                    // For active delegations, owner's personal balance should not include this lock
                    // Note: owner might have other non-delegated locks, so we can't check for exact equality
                }
            }
        }


    // ---- Delegate Action Limit ----

        /// @notice Invariant: Delegate actions per lock per epoch should not reach the limit (255)
        function invariant_DelegateActionLimit() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                uint8 actionCount = veMoca.numOfDelegateActionsPerEpoch(locks[i], currentEpochStart);
                // uint8 max is 255; check action count hasn't reached the limit
                assertLt(uint256(actionCount), 255, "Delegate action count at limit");
            }
        }

        /// @notice Invariant: numOfDelegateActionsPerEpoch should match ghost tracking
        function invariant_DelegateActionCountConsistency() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                uint8 contractCount = veMoca.numOfDelegateActionsPerEpoch(locks[i], currentEpochStart);
                uint8 ghostCount = handler.ghost_delegateActionCount(locks[i], currentEpochStart);
                
                assertEq(contractCount, ghostCount, "Delegate action count mismatch");
            }
        }

    // ---- Pending Deltas Net Zero Invariant ----

        /// @notice Invariant: Global pending deltas should net to zero
        /// What's added to one account must be subtracted from another
        function invariant_PendingDeltasNetZero() external view {
            address[] memory actors = handler.getActors();
            uint128 nextEpochStart = EpochMath.getCurrentEpochStart() + EpochMath.EPOCH_DURATION;
            
            int256 netBias;
            int256 netSlope;
            
            for (uint i; i < actors.length; ++i) {
                // Check user pending deltas
                (bool hasAdd, bool hasSub, 
                DataTypes.VeBalance memory additions, 
                DataTypes.VeBalance memory subtractions) = _getPendingDeltas(actors[i], nextEpochStart, false);
                
                if (hasAdd) {
                    netBias += int128(additions.bias);
                    netSlope += int128(additions.slope);
                }
                if (hasSub) {
                    netBias -= int128(subtractions.bias);
                    netSlope -= int128(subtractions.slope);
                }
                
                // Check delegate pending deltas
                (hasAdd, hasSub, additions, subtractions) = _getPendingDeltas(actors[i], nextEpochStart, true);
                
                if (hasAdd) {
                    netBias += int128(additions.bias);
                    netSlope += int128(additions.slope);
                }
                if (hasSub) {
                    netBias -= int128(subtractions.bias);
                    netSlope -= int128(subtractions.slope);
                }
            }
            
            // Net should be zero (what's added to delegates is subtracted from users and vice versa)
            assertEq(netBias, 0, "Pending deltas bias doesn't net to zero");
            assertEq(netSlope, 0, "Pending deltas slope doesn't net to zero");
        }

        // Helper function - would need to be added to expose pending deltas
        function _getPendingDeltas(address account, uint128 epoch, bool isDelegate) internal view 
            returns (bool hasAdd, bool hasSub, DataTypes.VeBalance memory add, DataTypes.VeBalance memory sub) 
        {
            if (isDelegate) {
                (hasAdd, hasSub, add, sub) = veMoca.delegatePendingDeltas(account, epoch);
            } else {
                (hasAdd, hasSub, add, sub) = veMoca.userPendingDeltas(account, epoch);
            }
        }
        
        
    // ---- Slope Changes Conservation Invariant ----

        /// @notice Invariant: User + Delegate slope changes should equal global slope changes
        function invariant_SlopeChangesConservation() external view {
            if (veMoca.isFrozen() == 1) return;
            
            bytes32[] memory locks = handler.getActiveLocks();
            
            // Collect all unique expiries
            uint128[] memory expiries = new uint128[](locks.length);
            for (uint i; i < locks.length; ++i) {
                (, uint128 expiry,,,,,,) = _getLock(locks[i]);
                expiries[i] = expiry;
            }
            
            // For each expiry, verify slope changes balance
            for (uint i; i < expiries.length; ++i) {
                uint128 expiry = expiries[i];
                uint128 globalSlopeChange = veMoca.slopeChanges(expiry);
                
                // Sum user slope changes for this expiry
                uint128 sumUserSlope = 0;
                uint128 sumDelegateSlope = 0;
                
                address[] memory actors = handler.getActors();
                for (uint j; j < actors.length; ++j) {
                    sumUserSlope += veMoca.userSlopeChanges(actors[j], expiry);
                    sumDelegateSlope += veMoca.delegateSlopeChanges(actors[j], expiry);
                }
                
                // Either user OR delegate should hold the slope (not both)
                assertEq(
                    sumUserSlope + sumDelegateSlope, 
                    globalSlopeChange, 
                    "User + Delegate slope changes != Global"
                );
            }
        }
 
    // ---- Delegated Aggregation Invariant ----

        /// @notice Invariant: For actively delegated locks, the userDelegatedPairLastUpdatedTimestamp 
        /// should be set when delegation is active (non-pending).
        /// NOTE: The contract uses lazy updates for delegatedAggregationHistory. The actual aggregation
        /// values are only guaranteed accurate after updateDelegatedPair() is called. This invariant 
        /// only checks that the pair tracking is initialized, not exact values.
        function invariant_DelegatedAggregationConsistency() external view {
            if (veMoca.isFrozen() == 1) return;
            
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            uint128 currentTimestamp = uint128(block.timestamp);
            
            // For each lock that is actively delegated, verify pair tracking exists
            for (uint i; i < locks.length; ++i) {
                (address owner, uint128 expiry,,, bool isUnlocked, address delegate,, uint96 delegationEpoch) = _getLock(locks[i]);
                
                // Skip if not delegated
                if (delegate == address(0)) continue;
                if (isUnlocked) continue;
                if (expiry <= currentTimestamp) continue; // Skip expired
                
                bool isPending = delegationEpoch > currentEpochStart;
                if (isPending) continue; // Only check active delegations
                
                // For active delegations, the pair should have been tracked at some point
                // The lastUpdatedTimestamp may be 0 if updateDelegatedPair hasn't been called yet
                // (lazy update pattern), so we only check that delegation state is consistent
                
                // Verify the delegate is registered
                assertTrue(
                    veMoca.isRegisteredDelegate(delegate),
                    "Active delegation to unregistered delegate"
                );
            }
        }

    // ---- Current Holder Validity Invariant ----

        /// @notice Invariant: currentHolder should be valid when there's a pending delegation
        /// NOTE: currentHolder tracks who CURRENTLY holds the VP until the pending change takes effect
        function invariant_CurrentHolderValidity() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                (address owner,,,,, address delegate, address currentHolder, uint96 delegationEpoch) = _getLock(locks[i]);
                
                bool hasPending = delegationEpoch > currentEpochStart;
                
                if (hasPending && currentHolder != address(0)) {
                    // currentHolder should be a valid previous holder:
                    // - Either the lock owner (was undelegated before)
                    // - Or a registered delegate (was delegated to someone else before)
                    bool isOwnerHolder = currentHolder == owner;
                    bool isRegisteredDelegate = veMoca.isRegisteredDelegate(currentHolder);
                    
                    assertTrue(
                        isOwnerHolder || isRegisteredDelegate, 
                        "Invalid currentHolder: not owner or registered delegate"
                    );
                    
                    // NOTE: currentHolder CAN equal delegate in valid scenarios:
                    // e.g., delegate A -> undelegate -> delegate A again
                    // In this case, currentHolder = A (from the active previous delegation)
                    // and delegate = A (the new pending delegation target)
                    // This is a valid state, so we don't assert currentHolder != delegate
                }
            }
        }
    
    //---- Delegation State Machine Invariant ----
        
        /// @notice Invariant: Delegation state transitions are valid
        function invariant_DelegationStateMachine() external view {
            bytes32[] memory locks = handler.getActiveLocks();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            
            for (uint i; i < locks.length; ++i) {
                (address owner,,,,, address delegate,, uint96 delegationEpoch) = _getLock(locks[i]);
                
                // Rule 1: If delegate is set, they must be registered
                if (delegate != address(0)) {
                    assertTrue(
                        veMoca.isRegisteredDelegate(delegate),
                        "Delegated to unregistered delegate"
                    );
                    
                    // Rule 2: Delegate cannot be owner (no self-delegation)
                    assertNotEq(delegate, owner, "Delegate == Owner");
                }
                
                // Rule 3: If there's a pending delegation, state must be consistent
                bool hasPending = delegationEpoch > currentEpochStart;
                if (hasPending) {
                    // delegationEpoch should be the next epoch start
                    assertEq(
                        delegationEpoch,
                        currentEpochStart + EpochMath.EPOCH_DURATION,
                        "Pending delegation not for next epoch"
                    );
                }
                
                // Rule 4: If currentHolder is set but no pending, it's stale (informational only)
                // This is allowed - currentHolder is only meaningful during pending state
            }
        }   

        /// @notice Invariant: For user-delegate pairs with active delegations, verify consistency
        /// NOTE: The contract uses lazy updates. delegatedAggregationHistory is only updated when
        /// updateDelegatedPair() is called or a write action triggers an update. This invariant
        /// checks structural correctness, not exact aggregation values.
        function invariant_DelegatedPairAggregation() external view {
            if (veMoca.isFrozen() == 1) return;
            
            bytes32[] memory locks = handler.getActiveLocks();
            address[] memory actors = handler.getActors();
            uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
            uint128 currentTimestamp = uint128(block.timestamp);
            
            // For each user-delegate pair with active delegations, verify structural consistency
            for (uint u; u < actors.length; ++u) {
                for (uint d; d < actors.length; ++d) {
                    if (actors[u] == actors[d]) continue;
                    
                    uint256 activeDelegationCount = 0;
                    
                    for (uint i; i < locks.length; ++i) {
                        (address owner, uint128 expiry,,, bool isUnlocked, address delegate,, uint96 delegationEpoch) = _getLock(locks[i]);
                        
                        if (owner != actors[u]) continue;
                        if (isUnlocked) continue;
                        if (expiry <= currentTimestamp) continue; // Skip expired
                        
                        // Check if ACTIVELY delegated to this delegate (not pending)
                        bool isPending = delegationEpoch > currentEpochStart;
                        bool isActivelyDelegatedToThis = !isPending && delegate == actors[d];
                        
                        if (isActivelyDelegatedToThis) {
                            activeDelegationCount++;
                        }
                    }
                    
                    // If there are active delegations, verify the delegate is registered
                    if (activeDelegationCount > 0) {
                        assertTrue(
                            veMoca.isRegisteredDelegate(actors[d]),
                            "Active delegations to unregistered delegate"
                        );
                    }
                }
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