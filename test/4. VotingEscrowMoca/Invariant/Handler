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
        (, address owner, , , , uint128 expiry, bool isUnlocked) = ve.locks(lockId);
        
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
        (, address owner, , , , uint128 expiry, bool isUnlocked) = ve.locks(lockId);

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
        (, address owner, , uint128 mocaAmt, uint128 esMocaAmt, uint128 expiry, bool isUnlocked) = ve.locks(lockId);

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
        (, address owner, , , , , bool isUnlocked) = ve.locks(lockId);
        
        if (owner == address(0) || isUnlocked) return;
        address target = actors[bound(delegateIndexSeed, 0, actors.length - 1)];
        if (target == owner) return;

        _ensureDelegateRegistered(target);

        vm.startPrank(owner);
        // Current delegate is 0 (required for delegateLock)
        try ve.delegateLock(lockId, target) {
            _updateGhostDelegation(lockId, address(0)); 
        } catch {}
        vm.stopPrank();
    }

    function switchDelegate(uint256 lockIndexSeed, uint256 newDelegateSeed) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        (, address owner, address currentDelegate, , , , bool isUnlocked) = ve.locks(lockId);
        
        if (owner == address(0) || isUnlocked || currentDelegate == address(0)) return;
        address target = actors[bound(newDelegateSeed, 0, actors.length - 1)];
        if (target == currentDelegate) return;

        _ensureDelegateRegistered(target);

        vm.startPrank(owner);
        try ve.switchDelegate(lockId, target) {
            _updateGhostDelegation(lockId, currentDelegate);
        } catch {}
        vm.stopPrank();
    }

    function undelegateLock(uint256 lockIndexSeed) external {
        if (activeLockIds.length == 0) return;
        bytes32 lockId = activeLockIds[bound(lockIndexSeed, 0, activeLockIds.length - 1)];
        (, address owner, address currentDelegate, , , , bool isUnlocked) = ve.locks(lockId);
        
        if (owner == address(0) || isUnlocked || currentDelegate == address(0)) return;

        vm.startPrank(owner);
        try ve.undelegateLock(lockId) {
            _updateGhostDelegation(lockId, currentDelegate);
        } catch {}
        vm.stopPrank();
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
        (,,, uint128 mocaAmt, uint128 esMocaAmt,, bool isUnlocked) = ve.locks(lockId);
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

    function warp(uint256 jump) external {
        jump = bound(jump, 1 days, 4 weeks); 
        vm.warp(block.timestamp + jump);
    }

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