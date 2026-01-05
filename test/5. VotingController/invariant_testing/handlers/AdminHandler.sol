// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test, console2} from "forge-std/Test.sol";
import {VotingController} from "../../../../src/VotingController.sol";
import {VotingEscrowMoca} from "../../../../src/VotingEscrowMoca.sol";
import {EscrowedMoca} from "../../../../src/EscrowedMoca.sol";
import {DataTypes} from "../../../../src/libraries/DataTypes.sol";
import {EpochMath} from "../../../../src/libraries/EpochMath.sol";
import {Constants} from "../../../../src/libraries/Constants.sol";

/**
 * @title AdminHandler
 * @notice Handler for admin operations: pool creation/removal, lock creation, parameter updates
 * @dev Tracks ghost variables for pool and lock invariants
 */
contract AdminHandler is Test {
    VotingController public vc;
    VotingEscrowMoca public veMoca;
    EscrowedMoca public esMoca;

    // ═══════════════════════════════════════════════════════════════════
    // Role Addresses
    // ═══════════════════════════════════════════════════════════════════
    
    address public votingControllerAdmin;
    address public assetManager;
    address public globalAdmin;
    address public monitor;

    // ═══════════════════════════════════════════════════════════════════
    // Actor Management
    // ═══════════════════════════════════════════════════════════════════
    
    address[] public lockCreators;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Pool Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    uint128 public ghost_totalPoolsCreated;
    uint128 public ghost_totalActivePools;
    uint128[] public ghost_activePoolIds;
    mapping(uint128 => bool) public ghost_poolIsActive;
    
    // Pool counters
    uint256 public ghost_createPoolsCalls;
    uint256 public ghost_removePoolsCalls;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Lock Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    bytes32[] public ghost_activeLockIds;
    mapping(bytes32 => address) public ghost_lockOwner;
    mapping(bytes32 => uint128) public ghost_lockMoca;
    mapping(bytes32 => uint128) public ghost_lockEsMoca;
    mapping(bytes32 => uint128) public ghost_lockExpiry;
    
    uint128 public ghost_totalLockedMoca;
    uint128 public ghost_totalLockedEsMoca;
    
    uint256 public ghost_createLockCalls;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Risk State
    // ═══════════════════════════════════════════════════════════════════
    
    bool public ghost_isPaused;
    bool public ghost_isFrozen;

    // Callback for notifying other handlers
    address public poolCallback;
    address public lockCallback;

    // ═══════════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════════
    
    uint128 public constant MIN_LOCK_AMOUNT = 1e18;
    uint128 public constant MAX_LOCK_DURATION = 728 days;
    uint128 public constant EPOCH_DURATION = 14 days;

    // ═══════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        VotingController _vc,
        VotingEscrowMoca _veMoca,
        EscrowedMoca _esMoca,
        address _votingControllerAdmin,
        address _assetManager,
        address _globalAdmin,
        address _monitor,
        address[] memory _lockCreators
    ) {
        vc = _vc;
        veMoca = _veMoca;
        esMoca = _esMoca;
        votingControllerAdmin = _votingControllerAdmin;
        assetManager = _assetManager;
        globalAdmin = _globalAdmin;
        monitor = _monitor;
        
        for (uint256 i = 0; i < _lockCreators.length; i++) {
            lockCreators.push(_lockCreators[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // External Setters
    // ═══════════════════════════════════════════════════════════════════

    function setPoolCallback(address callback) external {
        poolCallback = callback;
    }

    function setLockCallback(address callback) external {
        lockCallback = callback;
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Pool Management
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create new pools
     */
    function createPools(uint128 count) external {
        if (vc.paused()) return;
        
        // Bound count to valid range
        count = uint128(bound(count, 1, 10));

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Check epoch state allows pool creation
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(currentEpoch);
        if (state != DataTypes.EpochState.Voting) return;

        // Check previous epoch is finalized
        (DataTypes.EpochState prevState,,,,,,,,) = vc.epochs(currentEpoch - 1);
        if (uint8(prevState) < uint8(DataTypes.EpochState.Finalized)) return;

        uint128 startPoolId = vc.TOTAL_POOLS_CREATED() + 1;

        vm.prank(votingControllerAdmin);
        try vc.createPools(count) {
            // Update ghost variables
            for (uint128 i = 0; i < count; i++) {
                uint128 poolId = startPoolId + i;
                ghost_activePoolIds.push(poolId);
                ghost_poolIsActive[poolId] = true;
            }
            ghost_totalPoolsCreated += count;
            ghost_totalActivePools += count;
            ghost_createPoolsCalls++;

            // Notify callback
            if (poolCallback != address(0)) {
                IPoolCallback(poolCallback).onPoolsCreated(startPoolId, count);
            }
        } catch {}
    }

    /**
     * @notice Remove pools
     */
    function removePools(uint256 poolSeed) external {
        if (vc.paused()) return;
        if (ghost_activePoolIds.length == 0) return;

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        
        // Check epoch state
        (DataTypes.EpochState state,,,,,,,,) = vc.epochs(currentEpoch);
        if (state != DataTypes.EpochState.Voting) return;

        // Check previous epoch is finalized
        (DataTypes.EpochState prevState,,,,,,,,) = vc.epochs(currentEpoch - 1);
        if (uint8(prevState) < uint8(DataTypes.EpochState.Finalized)) return;

        // Select pool to remove
        uint256 idx = bound(poolSeed, 0, ghost_activePoolIds.length - 1);
        uint128 poolId = ghost_activePoolIds[idx];

        uint128[] memory poolIds = new uint128[](1);
        poolIds[0] = poolId;

        vm.prank(votingControllerAdmin);
        try vc.removePools(poolIds) {
            // Update ghost variables
            ghost_poolIsActive[poolId] = false;
            ghost_totalActivePools--;
            
            // Remove from active list
            ghost_activePoolIds[idx] = ghost_activePoolIds[ghost_activePoolIds.length - 1];
            ghost_activePoolIds.pop();
            
            ghost_removePoolsCalls++;
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Lock Creation
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a lock for voting power
     */
    function createLock(
        uint256 creatorSeed,
        uint128 mocaAmount,
        uint128 esMocaAmount,
        uint256 durationSeed
    ) external {
        if (lockCreators.length == 0) return;
        if (veMoca.paused()) return;

        address creator = lockCreators[bound(creatorSeed, 0, lockCreators.length - 1)];
        
        // Bound amounts
        mocaAmount = uint128(bound(mocaAmount, 0, 100_000 ether));
        esMocaAmount = uint128(bound(esMocaAmount, 0, 100_000 ether));
        
        // Ensure minimum lock amount
        if (mocaAmount + esMocaAmount < MIN_LOCK_AMOUNT) {
            mocaAmount = MIN_LOCK_AMOUNT;
        }

        // Check balances
        if (creator.balance < mocaAmount) return;
        if (esMoca.balanceOf(creator) < esMocaAmount) return;

        // Calculate expiry (at least 2 epochs from now, aligned to epoch boundary)
        uint128 currentEpochStart = EpochMath.getCurrentEpochStart();
        uint128 minExpiry = currentEpochStart + (3 * EPOCH_DURATION);
        uint128 maxExpiry = uint128(block.timestamp) + MAX_LOCK_DURATION;
        maxExpiry = (maxExpiry / EPOCH_DURATION) * EPOCH_DURATION;
        
        if (minExpiry > maxExpiry) return;
        
        uint128 expiry = uint128(bound(durationSeed, minExpiry, maxExpiry));
        expiry = (expiry / EPOCH_DURATION) * EPOCH_DURATION;

        vm.startPrank(creator);
        try veMoca.createLock{value: mocaAmount}(expiry, esMocaAmount) returns (bytes32 lockId) {
            // Update ghost variables
            ghost_activeLockIds.push(lockId);
            ghost_lockOwner[lockId] = creator;
            ghost_lockMoca[lockId] = mocaAmount;
            ghost_lockEsMoca[lockId] = esMocaAmount;
            ghost_lockExpiry[lockId] = expiry;
            ghost_totalLockedMoca += mocaAmount;
            ghost_totalLockedEsMoca += esMocaAmount;
            ghost_createLockCalls++;

            // Notify callback
            if (lockCallback != address(0)) {
                ILockCallback(lockCallback).onLockCreated(lockId, creator);
            }
        } catch {}
        vm.stopPrank();
    }

    /**
     * @notice Unlock an expired lock
     */
    function unlockLock(uint256 lockSeed) external {
        if (ghost_activeLockIds.length == 0) return;
        if (veMoca.paused()) return;

        uint256 idx = bound(lockSeed, 0, ghost_activeLockIds.length - 1);
        bytes32 lockId = ghost_activeLockIds[idx];
        address owner = ghost_lockOwner[lockId];
        
        // Check lock is expired
        (,uint128 expiry,,,bool isUnlocked,,,) = veMoca.locks(lockId);
        if (block.timestamp < expiry) return;
        if (isUnlocked) return;

        uint128 mocaAmount = ghost_lockMoca[lockId];
        uint128 esMocaAmount = ghost_lockEsMoca[lockId];

        vm.prank(owner);
        try veMoca.unlock(lockId) {
            // Update ghost variables
            ghost_totalLockedMoca -= mocaAmount;
            ghost_totalLockedEsMoca -= esMocaAmount;
            ghost_lockMoca[lockId] = 0;
            ghost_lockEsMoca[lockId] = 0;
            
            // Remove from active list
            ghost_activeLockIds[idx] = ghost_activeLockIds[ghost_activeLockIds.length - 1];
            ghost_activeLockIds.pop();
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Risk Management
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Pause the contract
     * @dev DISABLED: Pause blocks all meaningful operations, causing vacuous invariant passes.
     *      If testing pause behavior specifically, create a dedicated invariant test.
     */
    function pause() external pure {
        // Intentionally disabled - pause causes all operations to early-return,
        // leading to false positive invariant passes with zero state changes.
        return;
    }

    /**
     * @notice Unpause the contract
     * @dev DISABLED: Paired with pause() - kept disabled for consistency.
     */
    function unpause() external pure {
        // Intentionally disabled - see pause() comment
        return;
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    function getActivePoolIds() external view returns (uint128[] memory) {
        return ghost_activePoolIds;
    }

    function getActiveLockIds() external view returns (bytes32[] memory) {
        return ghost_activeLockIds;
    }

    function getLockOwner(bytes32 lockId) external view returns (address) {
        return ghost_lockOwner[lockId];
    }
}

interface IPoolCallback {
    function onPoolsCreated(uint128 startPoolId, uint128 count) external;
}

interface ILockCallback {
    function onLockCreated(bytes32 lockId, address owner) external;
}

