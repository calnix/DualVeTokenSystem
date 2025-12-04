// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {VotingEscrowMoca} from "../../../src/VotingEscrowMoca.sol";
import {EscrowedMoca} from "../../../src/EscrowedMoca.sol";
import {MockWMoca} from "../../utils/MockWMoca.sol";
import {Constants} from "../../../src/libraries/Constants.sol";
import {EpochMath} from "../../../src/libraries/EpochMath.sol";
import {DataTypes} from "../../../src/libraries/DataTypes.sol";

contract Handler is Test {
    VotingEscrowMoca public ve;
    MockWMoca public wMoca;
    EscrowedMoca public esMoca;

    // Ghost Variables: Track expected totals independent of the contract
    uint256 public ghost_totalLockedMoca;
    uint256 public ghost_totalLockedEsMoca;
    
    // State Tracking
    bytes32[] public activeLockIds;
    address[] public actors;
    address public currentActor;

    // Constrain random actors to our set
    modifier useActor(uint256 actorIndexSeed) {
        currentActor = actors[bound(actorIndexSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(VotingEscrowMoca _ve, MockWMoca _wMoca, EscrowedMoca _esMoca) {
        ve = _ve;
        wMoca = _wMoca;
        esMoca = _esMoca;

        // Create 3 pseudo-random actors
        for (uint256 i; i < 3; ++i) {
            address actor = makeAddr(string(abi.encodePacked("Actor", i)));
            actors.push(actor);
            
            // Fund actors with ETH and EsMoca
            vm.deal(actor, 10_000_000 ether);
            
            // Mint esMoca to actor via the mock (prank as esMoca admin/minter if needed, or directly if mock)
            // Assuming esMoca has a mint function for testing or we use deal
            deal(address(esMoca), actor, 10_000_000 ether);
            
            // Approve VE contract
            vm.startPrank(actor);
            esMoca.approve(address(ve), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------- ACTIONS -------------------

    function createLock(uint128 mocaAmount, uint128 esMocaAmount, uint256 durationSeed, uint256 actorSeed) external useActor(actorSeed) {
        // 1. Bound Amounts: Ensure at least MIN_LOCK_AMOUNT total
        uint128 minAmount = Constants.MIN_LOCK_AMOUNT;
        if (uint256(mocaAmount) + esMocaAmount < minAmount) {
            mocaAmount = uint128(minAmount); 
        }
        
        mocaAmount = uint128(bound(mocaAmount, 0, 1_000_000 ether));
        esMocaAmount = uint128(bound(esMocaAmount, 0, 1_000_000 ether));

        // 2. Bound Duration: From (Current + 3 epochs) to (Current + MAX_LOCK_DURATION)
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        // Minimum expiry is end of 3rd epoch from now (Current + 3 * Duration) - roughly
        // Actually logic is: currentEpochStart + 3 * EPOCH_DURATION
        uint128 minExpiry = currentEpochStart + (3 * EpochMath.EPOCH_DURATION);
        
        // Cast to uint128 to fix compilation error (9574)
        uint128 maxExpiry = uint128(block.timestamp) + uint128(EpochMath.MAX_LOCK_DURATION);
        
        // Align maxExpiry to epoch boundary
        maxExpiry = (maxExpiry / EpochMath.EPOCH_DURATION) * EpochMath.EPOCH_DURATION;
        
        if (minExpiry > maxExpiry) return; // Should rarely happen unless close to overflow or misconfiguration

        uint128 expiry = uint128(bound(durationSeed, minExpiry, maxExpiry));
        // Align expiry to epoch boundary
        expiry = (expiry / EpochMath.EPOCH_DURATION) * EpochMath.EPOCH_DURATION;

        // 3. Create Lock
        // Note: The signature is createLock(expiry, esMoca) with msg.value as moca
        bytes32 lockId = ve.createLock{value: mocaAmount}(expiry, esMocaAmount);

        // 4. Update Ghost State
        ghost_totalLockedMoca += mocaAmount;
        ghost_totalLockedEsMoca += esMocaAmount;
        activeLockIds.push(lockId);
    }

    function increaseAmount(uint256 lockIndexSeed, uint128 mocaAdd, uint128 esMocaAdd) external {
        if (activeLockIds.length == 0) return;
        
        // Pick a random lock
        uint256 idx = bound(lockIndexSeed, 0, activeLockIds.length - 1);
        bytes32 lockId = activeLockIds[idx];
        
        // Fix: Removed shadowed variable declarations by only unpacking needed values
        (,, address owner, , , uint128 expiry, bool isUnlocked) = ve.locks(lockId);
        
        // Validity checks matching contract logic
        if (owner == address(0)) return; // Sanity
        if (isUnlocked) return;
        
        // Check liveliness: must have at least 3 epochs (current + 2)
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        if (expiry < currentEpochStart + (3 * EpochMath.EPOCH_DURATION)) return;

        // Bound amounts
        uint128 minAmount = Constants.MIN_LOCK_AMOUNT;
        // If adding tiny amounts, just ensure valid range.
        // Contract enforces minAmount check on increments too to avoid precision loss
        if (uint256(mocaAdd) + esMocaAdd < minAmount) {
             mocaAdd = uint128(minAmount);
        }
        
        mocaAdd = uint128(bound(mocaAdd, 0, 100_000 ether));
        esMocaAdd = uint128(bound(esMocaAdd, 0, 100_000 ether));

        vm.startPrank(owner);
        try ve.increaseAmount{value: mocaAdd}(lockId, esMocaAdd) {
            ghost_totalLockedMoca += mocaAdd;
            ghost_totalLockedEsMoca += esMocaAdd;
        } catch (bytes memory) {
            // Ignore expected reverts (e.g. if time advanced between check and call)
        }
        vm.stopPrank();
    }

    function increaseDuration(uint256 lockIndexSeed, uint128 epochsToAdd) external {
        if (activeLockIds.length == 0) return;
        
        uint256 idx = bound(lockIndexSeed, 0, activeLockIds.length - 1);
        bytes32 lockId = activeLockIds[idx];
        (,, address owner, , , uint128 expiry, bool isUnlocked) = ve.locks(lockId);

        if (isUnlocked) return;

        // epochsToAdd must be at least 1
        epochsToAdd = uint128(bound(epochsToAdd, 1, 52)); // Max 1 year extension at a time roughly
        uint128 durationIncrease = epochsToAdd * EpochMath.EPOCH_DURATION;
        uint128 newExpiry = expiry + durationIncrease;

        // Validate max duration
        if (newExpiry > block.timestamp + EpochMath.MAX_LOCK_DURATION) return;

        vm.startPrank(owner);
        try ve.increaseDuration(lockId, durationIncrease) {
            // No change to principal ghosts
        } catch {
            // Ignore reverts
        }
        vm.stopPrank();
    }

    function unlock(uint256 lockIndexSeed) external {
        if (activeLockIds.length == 0) return;
        
        uint256 idx = bound(lockIndexSeed, 0, activeLockIds.length - 1);
        bytes32 lockId = activeLockIds[idx];

        // Fix: Rename variables to avoid shadowing 'esMoca' state var
        (,, address owner, uint128 mocaAmt, uint128 esMocaAmt, uint128 expiry, bool isUnlocked) = ve.locks(lockId);

        // Only unlock if expired and not already unlocked
        if (isUnlocked || block.timestamp < expiry) return;

        vm.startPrank(owner);
        try ve.unlock(lockId) {
            ghost_totalLockedMoca -= mocaAmt;
            ghost_totalLockedEsMoca -= esMocaAmt;

            // Remove from active locks by swapping with last
            activeLockIds[idx] = activeLockIds[activeLockIds.length - 1];
            activeLockIds.pop();
        } catch {
            // Ignore reverts
        }
        vm.stopPrank();
    }

    // ------------------- DELEGATION -------------------

    function delegateLock(uint256 lockIndexSeed, uint256 delegateIndexSeed) external {
        if (activeLockIds.length == 0) return;
        
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        (,, address owner, , , , bool isUnlocked) = ve.locks(lockId);
        
        // Cannot delegate unlocked or expired locks usually, but contract allows if not expired
        if (isUnlocked) return;

        // Pick a target delegate (can be another actor)
        address target = actors[bound(delegateIndexSeed, 0, actors.length - 1)];
        if (target == owner) return; // Cannot delegate to self

        // Ideally we need to register the delegate first via VotingController
        // Since we are mocking/ignoring VC for pure VE tests, we might need to prank the VC
        // However, VE checks `isRegisteredDelegate`. We should set this for our actors.
        // See _setDelegateStatus helper.

        _ensureDelegateRegistered(target);

        vm.startPrank(owner);
        try ve.delegateLock(lockId, target) {
            // Successful delegation
        } catch {
            // Ignore logic errors (already delegated etc)
        }
        vm.stopPrank();
    }

    function undelegateLock(uint256 lockIndexSeed) external {
        if (activeLockIds.length == 0) return;
        
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        (,, address owner, , , , bool isUnlocked) = ve.locks(lockId);
        
        if (isUnlocked) return;

        vm.startPrank(owner);
        try ve.undelegateLock(lockId) {} catch {}
        vm.stopPrank();
    }

    // ------------------- TIME & HELPERS -------------------

    function warp(uint256 jump) external {
        // Warp forward. Don't warp too far to avoid huge decay calculations in one step
        // But enough to cross epochs
        jump = bound(jump, 1 days, 4 weeks); 
        vm.warp(block.timestamp + jump);
    }

    // Helper to bypass VC check for delegate registration
    function _ensureDelegateRegistered(address delegate) internal {
        // Only the VC can call delegateRegistrationStatus on VE
        // We assume the test setup has granted the Handler or Test contract ability to mock VC calls
        // Or we impersonate the VC address if it's set in VE.
        
        address vc = ve.VOTING_CONTROLLER();
        if (vc != address(0)) {
            vm.prank(vc);
            ve.delegateRegistrationStatus(delegate, true);
        }
    }
}