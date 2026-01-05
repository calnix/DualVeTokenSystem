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
 * @title DelegateHandler
 * @notice Handler for delegate registration, fee management, and veMoca delegation actions
 * @dev Tracks ghost variables for delegation invariants
 */
contract DelegateHandler is Test {
    VotingController public vc;
    VotingEscrowMoca public veMoca;
    EscrowedMoca public esMoca;

    // ═══════════════════════════════════════════════════════════════════
    // Actor Management
    // ═══════════════════════════════════════════════════════════════════
    
    address[] public potentialDelegates;
    address[] public lockOwners;
    address public currentActor;

    // ═══════════════════════════════════════════════════════════════════
    // Lock Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    bytes32[] public activeLockIds;
    mapping(bytes32 => address) public lockIdToOwner;

    // ═══════════════════════════════════════════════════════════════════
    // Ghost Variables - Delegation Tracking
    // ═══════════════════════════════════════════════════════════════════
    
    // Registered delegates
    mapping(address => bool) public ghost_isRegistered;
    address[] public ghost_registeredDelegates;
    
    // Fee tracking
    mapping(address => uint128) public ghost_currentFeePct;
    mapping(address => uint128) public ghost_nextFeePct;
    mapping(address => uint128) public ghost_nextFeePctEpoch;
    mapping(address => mapping(uint128 => uint128)) public ghost_historicalFeePcts;
    
    // Registration fee tracking
    uint128 public ghost_totalRegistrationFees;
    
    // Lock delegation tracking
    mapping(bytes32 => address) public ghost_lockDelegate;
    mapping(bytes32 => uint128) public ghost_delegationEpoch;
    
    // Action counters
    uint256 public ghost_totalRegistrations;
    uint256 public ghost_totalUnregistrations;
    uint256 public ghost_totalFeeUpdates;
    uint256 public ghost_totalDelegationActions;

    // ═══════════════════════════════════════════════════════════════════
    // Parameters
    // ═══════════════════════════════════════════════════════════════════
    
    uint128 public registrationFee;
    uint128 public maxFeePct;

    // ═══════════════════════════════════════════════════════════════════
    // Modifier
    // ═══════════════════════════════════════════════════════════════════

    modifier useDelegate(uint256 actorSeed) {
        if (potentialDelegates.length == 0) return;
        currentActor = potentialDelegates[bound(actorSeed, 0, potentialDelegates.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    modifier useLockOwner(uint256 actorSeed) {
        if (lockOwners.length == 0) return;
        currentActor = lockOwners[bound(actorSeed, 0, lockOwners.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════

    constructor(
        VotingController _vc,
        VotingEscrowMoca _veMoca,
        EscrowedMoca _esMoca,
        address[] memory _potentialDelegates,
        address[] memory _lockOwners,
        uint128 _registrationFee,
        uint128 _maxFeePct
    ) {
        vc = _vc;
        veMoca = _veMoca;
        esMoca = _esMoca;
        registrationFee = _registrationFee;
        maxFeePct = _maxFeePct;
        
        for (uint256 i = 0; i < _potentialDelegates.length; i++) {
            potentialDelegates.push(_potentialDelegates[i]);
        }
        for (uint256 i = 0; i < _lockOwners.length; i++) {
            lockOwners.push(_lockOwners[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // External Setters
    // ═══════════════════════════════════════════════════════════════════

    function addLock(bytes32 lockId, address owner) external {
        activeLockIds.push(lockId);
        lockIdToOwner[lockId] = owner;
    }

    function removeLock(bytes32 lockId) external {
        for (uint256 i = 0; i < activeLockIds.length; i++) {
            if (activeLockIds[i] == lockId) {
                activeLockIds[i] = activeLockIds[activeLockIds.length - 1];
                activeLockIds.pop();
                delete lockIdToOwner[lockId];
                break;
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Delegate Registration
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Register as a delegate with a fee percentage
     */
    function registerAsDelegate(uint256 actorSeed, uint128 feePct) external useDelegate(actorSeed) {
        if (vc.paused()) return;
        
        // Already registered
        if (ghost_isRegistered[currentActor]) return;
        
        // Bound fee to valid range
        feePct = uint128(bound(feePct, 0, maxFeePct));
        
        // Ensure sufficient balance
        if (currentActor.balance < registrationFee) return;

        try vc.registerAsDelegate{value: registrationFee}(feePct) {
            // Update ghost variables
            ghost_isRegistered[currentActor] = true;
            ghost_registeredDelegates.push(currentActor);
            ghost_currentFeePct[currentActor] = feePct;
            ghost_historicalFeePcts[currentActor][EpochMath.getCurrentEpochNumber()] = feePct;
            ghost_totalRegistrationFees += registrationFee;
            ghost_totalRegistrations++;
        } catch {}
    }

    /**
     * @notice Update delegate fee (decrease = immediate, increase = delayed)
     */
    function updateDelegateFee(uint256 actorSeed, uint128 newFeePct) external useDelegate(actorSeed) {
        if (vc.paused()) return;
        
        // Must be registered
        if (!ghost_isRegistered[currentActor]) return;
        
        // Bound fee
        newFeePct = uint128(bound(newFeePct, 0, maxFeePct));
        
        // Cannot be same as current
        if (newFeePct == ghost_currentFeePct[currentActor]) return;

        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();

        try vc.updateDelegateFee(newFeePct) {
            if (newFeePct < ghost_currentFeePct[currentActor]) {
                // Immediate decrease
                ghost_currentFeePct[currentActor] = newFeePct;
                ghost_historicalFeePcts[currentActor][currentEpoch] = newFeePct;
                delete ghost_nextFeePct[currentActor];
                delete ghost_nextFeePctEpoch[currentActor];
            } else {
                // Delayed increase
                ghost_nextFeePct[currentActor] = newFeePct;
                ghost_nextFeePctEpoch[currentActor] = currentEpoch + vc.FEE_INCREASE_DELAY_EPOCHS();
            }
            ghost_totalFeeUpdates++;
        } catch {}
    }

    /**
     * @notice Unregister as delegate (requires no active votes)
     */
    function unregisterAsDelegate(uint256 actorSeed) external useDelegate(actorSeed) {
        if (vc.paused()) return;
        
        // Must be registered
        if (!ghost_isRegistered[currentActor]) return;
        
        // Check no active votes in current epoch
        uint128 currentEpoch = EpochMath.getCurrentEpochNumber();
        (uint128 votesSpent,) = vc.delegateEpochData(currentEpoch, currentActor);
        if (votesSpent > 0) return;

        try vc.unregisterAsDelegate() {
            // Update ghost variables
            ghost_isRegistered[currentActor] = false;
            delete ghost_currentFeePct[currentActor];
            delete ghost_nextFeePct[currentActor];
            delete ghost_nextFeePctEpoch[currentActor];
            ghost_totalUnregistrations++;
            
            // Remove from registered delegates list
            for (uint256 i = 0; i < ghost_registeredDelegates.length; i++) {
                if (ghost_registeredDelegates[i] == currentActor) {
                    ghost_registeredDelegates[i] = ghost_registeredDelegates[ghost_registeredDelegates.length - 1];
                    ghost_registeredDelegates.pop();
                    break;
                }
            }
        } catch {}
    }

    // ═══════════════════════════════════════════════════════════════════
    // Actions - Lock Delegation (veMoca)
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Delegate a lock to a registered delegate
     */
    function delegateLock(
        uint256 lockSeed,
        uint256 delegateSeed
    ) external {
        if (activeLockIds.length == 0) return;
        if (ghost_registeredDelegates.length == 0) return;
        if (veMoca.paused()) return;

        // Select lock
        bytes32 lockId = activeLockIds[bound(lockSeed, 0, activeLockIds.length - 1)];
        address owner = lockIdToOwner[lockId];
        if (owner == address(0)) return;

        // Get lock details
        (address lockOwner,,,,, address currentDelegate,,) = veMoca.locks(lockId);
        if (lockOwner != owner) return;
        if (currentDelegate != address(0)) return; // Already delegated

        // Select delegate (not owner)
        address targetDelegate = ghost_registeredDelegates[bound(delegateSeed, 0, ghost_registeredDelegates.length - 1)];
        if (targetDelegate == owner) return;

        vm.startPrank(owner);
        try veMoca.delegationAction(lockId, targetDelegate, DataTypes.DelegationType.Delegate) {
            ghost_lockDelegate[lockId] = targetDelegate;
            ghost_delegationEpoch[lockId] = EpochMath.getCurrentEpochStart() + EpochMath.EPOCH_DURATION;
            ghost_totalDelegationActions++;
        } catch {}
        vm.stopPrank();
    }

    /**
     * @notice Undelegate a lock
     */
    function undelegateLock(uint256 lockSeed) external {
        if (activeLockIds.length == 0) return;
        if (veMoca.paused()) return;

        bytes32 lockId = activeLockIds[bound(lockSeed, 0, activeLockIds.length - 1)];
        address owner = lockIdToOwner[lockId];
        if (owner == address(0)) return;

        // Get lock details
        (address lockOwner,,,,, address currentDelegate,,) = veMoca.locks(lockId);
        if (lockOwner != owner) return;
        if (currentDelegate == address(0)) return; // Not delegated

        vm.startPrank(owner);
        try veMoca.delegationAction(lockId, address(0), DataTypes.DelegationType.Undelegate) {
            ghost_lockDelegate[lockId] = address(0);
            ghost_delegationEpoch[lockId] = EpochMath.getCurrentEpochStart() + EpochMath.EPOCH_DURATION;
            ghost_totalDelegationActions++;
        } catch {}
        vm.stopPrank();
    }

    /**
     * @notice Switch lock delegation to a different delegate
     */
    function switchDelegate(uint256 lockSeed, uint256 newDelegateSeed) external {
        if (activeLockIds.length == 0) return;
        if (ghost_registeredDelegates.length < 2) return;
        if (veMoca.paused()) return;

        bytes32 lockId = activeLockIds[bound(lockSeed, 0, activeLockIds.length - 1)];
        address owner = lockIdToOwner[lockId];
        if (owner == address(0)) return;

        // Get lock details
        (address lockOwner,,,,, address currentDelegate,,) = veMoca.locks(lockId);
        if (lockOwner != owner) return;
        if (currentDelegate == address(0)) return; // Not delegated

        // Select new delegate
        address newDelegate = ghost_registeredDelegates[bound(newDelegateSeed, 0, ghost_registeredDelegates.length - 1)];
        if (newDelegate == currentDelegate || newDelegate == owner) return;

        vm.startPrank(owner);
        try veMoca.delegationAction(lockId, newDelegate, DataTypes.DelegationType.Switch) {
            ghost_lockDelegate[lockId] = newDelegate;
            ghost_delegationEpoch[lockId] = EpochMath.getCurrentEpochStart() + EpochMath.EPOCH_DURATION;
            ghost_totalDelegationActions++;
        } catch {}
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════

    function getRegisteredDelegates() external view returns (address[] memory) {
        return ghost_registeredDelegates;
    }

    function getActiveLockIds() external view returns (bytes32[] memory) {
        return activeLockIds;
    }

    function isRegistered(address delegate) external view returns (bool) {
        return ghost_isRegistered[delegate];
    }
}

