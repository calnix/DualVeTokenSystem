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

    // Ghost Variables
    uint256 public ghost_totalLockedMoca;
    uint256 public ghost_totalLockedEsMoca;
    
    // Delegation Ghost State
    mapping(bytes32 => uint256) public ghost_delegationEffectEpoch;
    mapping(bytes32 => address) public ghost_previousDelegate; // Who held it before current state?
    // Track pending delegation transitions
    mapping(bytes32 lockId => bool) public ghost_hasPendingDelegation;
    mapping(bytes32 lockId => address) public ghost_expectedCurrentHolder;
    mapping(bytes32 lockId => address) public ghost_expectedFutureDelegate;
    mapping(bytes32 lockId => uint128) public ghost_delegationEffectiveEpoch;
    // Track pending deltas
    mapping(address account => mapping(uint128 epoch => int256)) public ghost_pendingDeltaBias;
    mapping(address account => mapping(uint128 epoch => int256)) public ghost_pendingDeltaSlope;
    // Track user-delegate pair aggregations
    mapping(address user => mapping(address delegate => uint256)) public ghost_userDelegatedToDelegate;
    // Track delegate action counts
    mapping(bytes32 lockId => mapping(uint128 epoch => uint8)) public ghost_delegateActionCount;

    // State Tracking
    bytes32[] public activeLockIds;
    address[] public actors;
    address public currentActor;

    // Simulated Roles
    address public admin;
    address public monitor;
    address public cronJob;
    address public emergencyHandler;

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

        admin = msg.sender; 
        monitor = makeAddr("monitor");
        cronJob = makeAddr("cronJob");
        emergencyHandler = makeAddr("emergencyHandler");

        for (uint256 i; i < 3; ++i) {
            address actor = makeAddr(string(abi.encodePacked("Actor", i)));
            actors.push(actor);
            vm.deal(actor, 10_000_000 ether);
            deal(address(esMoca), actor, 10_000_000 ether);
            vm.startPrank(actor);
            esMoca.approve(address(ve), type(uint256).max);
            vm.stopPrank();
        }
        vm.deal(cronJob, 10_000_000 ether);
    }

    // Helper to update ghost delegation state
    function _updateGhostDelegation(bytes32 lockId, address oldDelegate) internal {
        ghost_delegationEffectEpoch[lockId] = EpochMath.getCurrentEpochNumber() + 1;
        ghost_previousDelegate[lockId] = oldDelegate;
    }

    // ------------------- ACTIONS -------------------

    function createLock(uint128 mocaAmount, uint128 esMocaAmount, uint256 durationSeed, uint256 actorSeed) external useActor(actorSeed) {
        if (ve.paused()) return;

        uint128 minAmount = Constants.MIN_LOCK_AMOUNT;
        if (uint256(mocaAmount) + esMocaAmount < minAmount) mocaAmount = uint128(minAmount);
        mocaAmount = uint128(bound(mocaAmount, 0, 1_000_000 ether));
        esMocaAmount = uint128(bound(esMocaAmount, 0, 1_000_000 ether));

        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        uint128 minExpiry = currentEpochStart + (3 * EpochMath.EPOCH_DURATION);
        uint128 maxExpiry = uint128(block.timestamp) + uint128(EpochMath.MAX_LOCK_DURATION);
        maxExpiry = (maxExpiry / EpochMath.EPOCH_DURATION) * EpochMath.EPOCH_DURATION;
        if (minExpiry > maxExpiry) return;

        uint128 expiry = uint128(bound(durationSeed, minExpiry, maxExpiry));
        expiry = (expiry / EpochMath.EPOCH_DURATION) * EpochMath.EPOCH_DURATION;

        bytes32 lockId = ve.createLock{value: mocaAmount}(expiry, esMocaAmount);

        ghost_totalLockedMoca += mocaAmount;
        ghost_totalLockedEsMoca += esMocaAmount;
        activeLockIds.push(lockId);
        
        // Initial state: Not delegated. Effect epoch 0 (active). Previous: 0.
        ghost_delegationEffectEpoch[lockId] = 0;
        ghost_previousDelegate[lockId] = address(0);
    }

    function increaseAmount(uint256 lockIndexSeed, uint128 mocaAdd, uint128 esMocaAdd) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        (address owner,,,,,uint128 expiry, bool isUnlocked) = _getLockData(lockId);
        
        if (owner == address(0) || isUnlocked) return;
        if (expiry < EpochMath.getCurrentEpochStart() + (3 * EpochMath.EPOCH_DURATION)) return;

        uint128 minAmount = Constants.MIN_LOCK_AMOUNT;
        if (uint256(mocaAdd) + esMocaAdd < minAmount) mocaAdd = uint128(minAmount);
        mocaAdd = uint128(bound(mocaAdd, 0, 100_000 ether));
        esMocaAdd = uint128(bound(esMocaAdd, 0, 100_000 ether));

        vm.startPrank(owner);
        try ve.increaseAmount{value: mocaAdd}(lockId, esMocaAdd) {
            ghost_totalLockedMoca += mocaAdd;
            ghost_totalLockedEsMoca += esMocaAdd;
        } catch {}
        vm.stopPrank();
    }

    function increaseDuration(uint256 lockIndexSeed, uint128 epochsToAdd) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        (address owner,,,,,uint128 expiry, bool isUnlocked) = _getLockData(lockId);

        if (isUnlocked) return;
        epochsToAdd = uint128(bound(epochsToAdd, 1, 52)); 
        uint128 durationIncrease = epochsToAdd * EpochMath.EPOCH_DURATION;
        uint128 newExpiry = expiry + durationIncrease;
        if (newExpiry > block.timestamp + EpochMath.MAX_LOCK_DURATION) return;

        vm.startPrank(owner);
        try ve.increaseDuration(lockId, durationIncrease) {} catch {}
        vm.stopPrank();
    }

    function unlock(uint256 lockIndexSeed) external {
        if (activeLockIds.length == 0) return;
        uint256 idx = bound(lockIndexSeed, 0, activeLockIds.length - 1);
        bytes32 lockId = activeLockIds[idx];
        (address owner,,, uint128 mocaAmt, uint128 esMocaAmt, uint128 expiry, bool isUnlocked) = _getLockData(lockId);

        if (isUnlocked || block.timestamp < expiry) return;

        vm.startPrank(owner);
        try ve.unlock(lockId) {
            ghost_totalLockedMoca -= mocaAmt;
            ghost_totalLockedEsMoca -= esMocaAmt;
            activeLockIds[idx] = activeLockIds[activeLockIds.length - 1];
            activeLockIds.pop();
        } catch {}
        vm.stopPrank();
    }

    function delegateLock(uint256 lockIndexSeed, uint256 delegateIndexSeed) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        
        // Get lock data including new fields
        (address owner, address currentDelegate,,,,uint128 expiry, bool isUnlocked) = _getLockData(lockId);
        
        if (owner == address(0) || isUnlocked) return;
        if (currentDelegate != address(0)) return; // Already delegated
        
        address target = actors[bound(delegateIndexSeed, 0, actors.length - 1)];
        if (target == owner) return;

        _ensureDelegateRegistered(target);

        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        
        vm.startPrank(owner);
        try ve.delegationAction(lockId, target, DataTypes.DelegationType.Delegate) {
            // Update ghost state
            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;
            ghost_hasPendingDelegation[lockId] = true;
            ghost_expectedCurrentHolder[lockId] = owner;
            ghost_expectedFutureDelegate[lockId] = target;
            ghost_delegationEffectiveEpoch[lockId] = nextEpochStart;
            
            // Track delegate action
            ghost_delegateActionCount[lockId][currentEpochStart]++;
            
            // Track pending deltas (veBalance moves from user to delegate next epoch)
            DataTypes.VeBalance memory lockVe = ve.getLockVeBalance(lockId);
            ghost_pendingDeltaBias[owner][nextEpochStart] -= int128(lockVe.bias);
            ghost_pendingDeltaSlope[owner][nextEpochStart] -= int128(lockVe.slope);
            ghost_pendingDeltaBias[target][nextEpochStart] += int128(lockVe.bias);
            ghost_pendingDeltaSlope[target][nextEpochStart] += int128(lockVe.slope);
            
        } catch {}
        vm.stopPrank();
    }

    function switchDelegate(uint256 lockIndexSeed, uint256 newDelegateSeed) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        
        (address owner, address currentDelegate,,,,, bool isUnlocked) = _getLockData(lockId);
        
        if (owner == address(0) || isUnlocked || currentDelegate == address(0)) return;
        
        address newTarget = actors[bound(newDelegateSeed, 0, actors.length - 1)];
        if (newTarget == currentDelegate || newTarget == owner) return;

        _ensureDelegateRegistered(newTarget);

        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        
        vm.startPrank(owner);
        try ve.delegationAction(lockId, newTarget, DataTypes.DelegationType.Switch) {
            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;
            
            // Update ghost state - current holder is the old delegate
            ghost_hasPendingDelegation[lockId] = true;
            ghost_expectedCurrentHolder[lockId] = currentDelegate;
            ghost_expectedFutureDelegate[lockId] = newTarget;
            ghost_delegationEffectiveEpoch[lockId] = nextEpochStart;
            
            ghost_delegateActionCount[lockId][currentEpochStart]++;
            
            // Track pending deltas (veBalance moves from oldDelegate to newDelegate)
            DataTypes.VeBalance memory lockVe = ve.getLockVeBalance(lockId);
            ghost_pendingDeltaBias[currentDelegate][nextEpochStart] -= int128(lockVe.bias);
            ghost_pendingDeltaSlope[currentDelegate][nextEpochStart] -= int128(lockVe.slope);
            ghost_pendingDeltaBias[newTarget][nextEpochStart] += int128(lockVe.bias);
            ghost_pendingDeltaSlope[newTarget][nextEpochStart] += int128(lockVe.slope);
            
        } catch {}
        vm.stopPrank();
    }

    function undelegateLock(uint256 lockIndexSeed) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        
        (address owner, address currentDelegate,,,,, bool isUnlocked) = _getLockData(lockId);
        
        if (owner == address(0) || isUnlocked || currentDelegate == address(0)) return;

        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        
        vm.startPrank(owner);
        try ve.delegationAction(lockId, address(0), DataTypes.DelegationType.Undelegate) {
            uint128 nextEpochStart = currentEpochStart + EpochMath.EPOCH_DURATION;
            
            ghost_hasPendingDelegation[lockId] = true;
            ghost_expectedCurrentHolder[lockId] = currentDelegate;
            ghost_expectedFutureDelegate[lockId] = address(0); // Back to owner
            ghost_delegationEffectiveEpoch[lockId] = nextEpochStart;
            
            ghost_delegateActionCount[lockId][currentEpochStart]++;
            
            // Track pending deltas (veBalance moves from delegate back to owner)
            DataTypes.VeBalance memory lockVe = ve.getLockVeBalance(lockId);
            ghost_pendingDeltaBias[currentDelegate][nextEpochStart] -= int128(lockVe.bias);
            ghost_pendingDeltaSlope[currentDelegate][nextEpochStart] -= int128(lockVe.slope);
            ghost_pendingDeltaBias[owner][nextEpochStart] += int128(lockVe.bias);
            ghost_pendingDeltaSlope[owner][nextEpochStart] += int128(lockVe.slope);
            
        } catch {}
        vm.stopPrank();
    }


    // Helper to clear pending state when epoch advances past delegationEpoch
    function warp(uint256 jump) external {
        jump = bound(jump, 1 days, 4 weeks);
        uint128 oldEpoch = EpochMath.getCurrentEpochStart();
        
        vm.warp(block.timestamp + jump);
        
        uint128 newEpoch = EpochMath.getCurrentEpochStart();
        
        // If epoch advanced, clear pending delegations that are now active
        if (newEpoch > oldEpoch) {
            _clearActivatedDelegations(newEpoch);
        }
    }


    function _clearActivatedDelegations(uint128 currentEpochStart) internal {
        for (uint256 i; i < activeLockIds.length; ++i) {
            bytes32 lockId = activeLockIds[i];
            if (ghost_delegationEffectiveEpoch[lockId] <= currentEpochStart && ghost_delegationEffectiveEpoch[lockId] > 0) {
                ghost_hasPendingDelegation[lockId] = false;
                delete ghost_expectedCurrentHolder[lockId];
                delete ghost_expectedFutureDelegate[lockId];
                delete ghost_delegationEffectiveEpoch[lockId];
            }
        }
    }


    // Helper to get full lock data using tuple unpacking
    // Lock struct order: owner, expiry, moca, esMoca, isUnlocked, delegate, currentHolder, delegationEpoch
    function _getLockData(bytes32 lockId) internal view returns (
        address owner, address delegate, address currentHolder, 
        uint128 moca, uint128 esMocaAmt, uint128 expiry, bool isUnlocked
    ) {
        (address _owner, uint128 _expiry, uint128 _moca, uint128 _esMoca, bool _isUnlocked, address _delegate, address _currentHolder,) = ve.locks(lockId);
        return (_owner, _delegate, _currentHolder, _moca, _esMoca, _expiry, _isUnlocked);
    }

    
    // ------------------- ADMIN/CRON ACTIONS -------------------

    function createLockFor(uint256 amountSeed, uint256 durationSeed) external {
        if (ve.paused()) return;
        address user = actors[bound(amountSeed, 0, actors.length - 1)];
        uint128 mocaAmt = uint128(bound(amountSeed, 1 ether, 100_000 ether));
        
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        uint128 minExpiry = currentEpochStart + (3 * EpochMath.EPOCH_DURATION);
        uint128 maxExpiry = uint128(block.timestamp) + uint128(EpochMath.MAX_LOCK_DURATION);
        maxExpiry = (maxExpiry / EpochMath.EPOCH_DURATION) * EpochMath.EPOCH_DURATION;
        if (minExpiry > maxExpiry) return;
        uint128 expiry = uint128(bound(durationSeed, minExpiry, maxExpiry));
        expiry = (expiry / EpochMath.EPOCH_DURATION) * EpochMath.EPOCH_DURATION;

        address[] memory users = new address[](1); users[0] = user;
        uint128[] memory mocas = new uint128[](1); mocas[0] = mocaAmt;
        uint128[] memory esMocas = new uint128[](1); esMocas[0] = 0;

        vm.startPrank(cronJob);
        try ve.createLockFor{value: mocaAmt}(users, esMocas, mocas, expiry) returns (bytes32[] memory ids) {
            ghost_totalLockedMoca += mocaAmt;
            activeLockIds.push(ids[0]);
            ghost_delegationEffectEpoch[ids[0]] = 0;
            ghost_previousDelegate[ids[0]] = address(0);
        } catch {}
        vm.stopPrank();
    }

    function pause() external {
        vm.prank(monitor);
        try ve.pause() {} catch {}
    }

    function unpause() external {
        vm.prank(admin);
        try ve.unpause() {} catch {}
    }

    function freeze() external {
        vm.prank(admin);
        try ve.freeze() {} catch {}
    }

    function emergencyExit(uint256 lockIndexSeed) external {
        if (activeLockIds.length == 0) return;
        if (ve.isFrozen() == 0) return;
        uint256 idx = bound(lockIndexSeed, 0, activeLockIds.length - 1);
        bytes32 lockId = activeLockIds[idx];
        (,,, uint128 mocaAmt, uint128 esMocaAmt,, bool isUnlocked) = _getLockData(lockId);
        if (isUnlocked) return;

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = lockId;

        vm.prank(emergencyHandler);
        try ve.emergencyExit(ids) {
            ghost_totalLockedMoca -= mocaAmt;
            ghost_totalLockedEsMoca -= esMocaAmt;
            activeLockIds[idx] = activeLockIds[activeLockIds.length - 1];
            activeLockIds.pop();
        } catch {}
    }

    // ------------------- HELPERS -------------------


    function _ensureDelegateRegistered(address delegate) internal {
        address vc = ve.VOTING_CONTROLLER();
        if (vc != address(0)) {
            vm.prank(vc);
            ve.delegateRegistrationStatus(delegate, true);
        }
    }

    function getActiveLocks() external view returns (bytes32[] memory) {
        return activeLockIds;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }
}