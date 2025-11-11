// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
// access control
import {AccessControlEnumerable, AccessControl} from "openzeppelin-contracts/contracts/access/extensions/AccessControlEnumerable.sol";
import {IAccessControlEnumerable, IAccessControl} from "openzeppelin-contracts/contracts/access/extensions/IAccessControlEnumerable.sol";

// libraries
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";
import {Constants} from "./libraries/Constants.sol";

// contracts
import {LowLevelWMoca} from "./LowLevelWMoca.sol";

/**
 * @title IssuerStakingController
 * @author Calnix [@cal_nix]
 * @notice Central contract managing issuer staking and unstaking
 * @dev Integrates with external controllers and enforces protocol-level access and safety checks.
 *      Works with Native Moca - not ERC20 MOCA.
 */


contract IssuerStakingController is LowLevelWMoca, Pausable, AccessControlEnumerable {
    
    // Contracts
    address public immutable WMOCA;

    // Global params
    uint256 public TOTAL_MOCA_STAKED;
    uint256 public TOTAL_MOCA_PENDING_UNSTAKE;
    
    uint256 public UNSTAKE_DELAY;
    uint256 public MAX_SINGLE_STAKE_AMOUNT;    // to prevent fat-finger mistakes on excess allocation on staking

    // gas limit for moca transfer
    uint256 public MOCA_TRANSFER_GAS_LIMIT;

    // Roles
    bytes32 public constant ISSUER_STAKING_CONTROLLER_ADMIN_ROLE = Constants.ISSUER_STAKING_CONTROLLER_ADMIN_ROLE;
    bytes32 public constant EMERGENCY_EXIT_HANDLER_ROLE = Constants.EMERGENCY_EXIT_HANDLER_ROLE;
    bytes32 public constant MONITOR_ADMIN_ROLE = Constants.MONITOR_ADMIN_ROLE;
    bytes32 public constant MONITOR_ROLE = Constants.MONITOR_ROLE;


    // risk management
    uint256 public isFrozen;

//------------------------------- Mappings-----------------------------------------------------

    mapping(address issuer => uint256 mocaStaked) public issuers;

    mapping(address issuer => mapping(uint256 timestamp => uint256 pendingUnstake)) public pendingUnstakedMoca;

    mapping(address issuer => uint256 totalPendingUnstake) public totalPendingUnstakedMoca;

//------------------------------- Constructor---------------------------------------------------------------------

    constructor(
        address globalAdmin, address issuerStakingControllerAdmin, address monitorAdmin, address monitorBot, address emergencyExitHandler, 
        uint256 unstakeDelay, uint256 maxStakeAmount, address wMoca_, uint256 mocaTransferGasLimit) {
       
        // unstakeDelay
        require(unstakeDelay > 0, Errors.InvalidDelayPeriod());
        require(unstakeDelay <= 90 days, Errors.InvalidDelayPeriod());
        UNSTAKE_DELAY = unstakeDelay;

        // max single stake amount
        require(maxStakeAmount > 0, Errors.InvalidAmount());
        MAX_SINGLE_STAKE_AMOUNT = maxStakeAmount;

        // wrapped moca 
        require(wMoca_ != address(0), Errors.InvalidAddress());
        WMOCA = wMoca_;

        // gas limit for moca transfer [EOA is ~2300, gnosis safe with a fallback is ~4029]
        require(mocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());
        MOCA_TRANSFER_GAS_LIMIT = mocaTransferGasLimit;

        // setup roles
        _setupRoles(globalAdmin, issuerStakingControllerAdmin, monitorAdmin, monitorBot, emergencyExitHandler);
    }

    // cronJob is not setup here; as its preferably to not keep it persistent. I.e. add address to cronJob when needed; then revoke.
    function _setupRoles(address globalAdmin, address issuerStakingControllerAdmin, address monitorAdmin, address monitorBot, address emergencyExitHandler) internal {

        // sanity check: all addresses are not zero address
        require(globalAdmin != address(0), Errors.InvalidAddress());
        require(issuerStakingControllerAdmin != address(0), Errors.InvalidAddress());
        require(monitorAdmin != address(0), Errors.InvalidAddress());
        require(monitorBot != address(0), Errors.InvalidAddress());
        require(emergencyExitHandler != address(0), Errors.InvalidAddress());

        // grant roles to addresses
        _grantRole(DEFAULT_ADMIN_ROLE, globalAdmin);    
        _grantRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE, issuerStakingControllerAdmin);
        _grantRole(MONITOR_ADMIN_ROLE, monitorAdmin);
        _grantRole(EMERGENCY_EXIT_HANDLER_ROLE, emergencyExitHandler);

        // there should at least 1 bot address for monitoring at deployment
        _grantRole(MONITOR_ROLE, monitorBot);

        // --------------- Set role admins ------------------------------
        // Operational role administrators managed by global admin
        _setRoleAdmin(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(EMERGENCY_EXIT_HANDLER_ROLE, DEFAULT_ADMIN_ROLE);

        _setRoleAdmin(MONITOR_ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        // High-frequency roles managed by their dedicated admins
        _setRoleAdmin(MONITOR_ROLE, MONITOR_ADMIN_ROLE);
    }

//------------------------------- External functions---------------------------------------------------------------

    /**
     * @notice Allows an issuer to stake native MOCA.
     * @dev Accepts native MOCA via msg.value. Must be > 0 and <= MAX_SINGLE_STAKE_AMOUNT.
     */
    function stakeMoca() external payable whenNotPaused {
        uint256 amount = msg.value;
        require(amount > 0, Errors.InvalidAmount());
        require(amount <= MAX_SINGLE_STAKE_AMOUNT, Errors.InvalidAmount());
        
        // update total moca staked
        TOTAL_MOCA_STAKED += amount;

        // update issuer's moca staked
        issuers[msg.sender] += amount;

        emit Events.Staked(msg.sender, amount);
    }


    /**
     * @notice Initiates the unstaking process for the caller's MOCA tokens. [note: does not transfer moca to issuer]
     * @dev Decrements the issuer's active staked balance and the global staked total.
     *      Increases the global pending unstake total.
     * @param amount The amount of MOCA tokens to unstake. Must be > 0 and <= the issuer's staked balance.
     */
    function initiateUnstake(uint256 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());
        require(amount <= issuers[msg.sender], Errors.InsufficientBalance());

        // calculate claimable timestamp
        uint256 claimableTimestamp = block.timestamp + UNSTAKE_DELAY;

        // book pending unstake
        pendingUnstakedMoca[msg.sender][claimableTimestamp] += amount;
        totalPendingUnstakedMoca[msg.sender] += amount;
        TOTAL_MOCA_PENDING_UNSTAKE += amount;
     
        // decrement active staked 
        issuers[msg.sender] -= amount;
        TOTAL_MOCA_STAKED -= amount;

        emit Events.UnstakeInitiated(msg.sender, amount, claimableTimestamp);
    }


    /**
     * @notice Claims unstaked MOCA tokens for the caller. Can claim multiple timestamps at once.
     * @dev Unstaked MOCA tokens are claimable after the UNSTAKE_DELAY period. 
     *      Wraps to wMoca if transfer fails within gas limit.
     * @param timestamps Array of timestamps at which the unstaked MOCA tokens are claimable.
     */
    function claimUnstake(uint256[] calldata timestamps) external payable whenNotPaused {
        uint256 length = timestamps.length;
        require(length > 0, Errors.InvalidArray());
        require(totalPendingUnstakedMoca[msg.sender] > 0, Errors.NothingToClaim());

        uint256 totalClaimable;

        // check: delay period has passed + non-zero amount
        for(uint256 i; i < length; ++i) {
            uint256 timestamp = timestamps[i];
            
            // sanity checks
            require(timestamp <= block.timestamp, Errors.InvalidTimestamp());
            require(pendingUnstakedMoca[msg.sender][timestamp] > 0, Errors.NothingToClaim());

            // add to total claimable
            totalClaimable += pendingUnstakedMoca[msg.sender][timestamp];
            
            // delete from pending unstake
            delete pendingUnstakedMoca[msg.sender][timestamp];
        }
        
        // update global + user aggregate: only update pending unstake [active staked is not affected]
        TOTAL_MOCA_PENDING_UNSTAKE -= totalClaimable;
        totalPendingUnstakedMoca[msg.sender] -= totalClaimable;

        // transfer moca to issuer [wraps if transfer fails within gas limit]
        _transferMocaAndWrapIfFailWithGasLimit(WMOCA, msg.sender, totalClaimable, MOCA_TRANSFER_GAS_LIMIT);

        emit Events.UnstakeClaimed(msg.sender, totalClaimable);
    }

//------------------------------- Admin: setUnstakeDelay -------------------------------------------------------------

    /**
     * @notice Sets the unstake delay. Only applies to new unstakes initiated after the update.
     * @dev Only callable by the IssuerStakingController admin. Must be > 0 and <= 90 days.
     * @param newUnstakeDelay The new unstake delay.
     */
    function setUnstakeDelay(uint256 newUnstakeDelay) external onlyRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newUnstakeDelay > 0, Errors.InvalidDelayPeriod());
        require(newUnstakeDelay <= 90 days, Errors.InvalidDelayPeriod());

        // cache old + update to new unstake delay
        uint256 oldUnstakeDelay = UNSTAKE_DELAY;
        UNSTAKE_DELAY = newUnstakeDelay;

        emit Events.UnstakeDelayUpdated(oldUnstakeDelay, newUnstakeDelay);
    }

    /**
     * @notice Sets the maximum amount of MOCA that can be staked by an issuer in a single transaction.
     * @dev Only callable by the IssuerStakingController admin.
     * @param newMaxSingleStakeAmount The new maximum single stake amount.
     */

    function setMaxSingleStakeAmount(uint256 newMaxSingleStakeAmount) external onlyRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newMaxSingleStakeAmount > 0, Errors.InvalidAmount());

        // cache old + update to new max stake amount
        uint256 oldMaxSingleStakeAmount = MAX_SINGLE_STAKE_AMOUNT;
        MAX_SINGLE_STAKE_AMOUNT = newMaxSingleStakeAmount;

        emit Events.MaxSingleStakeAmountUpdated(oldMaxSingleStakeAmount, newMaxSingleStakeAmount);
    }

    /**
     * @notice Sets the gas limit for moca transfer.
     * @dev Only callable by the IssuerStakingController admin.
     * @param newMocaTransferGasLimit The new gas limit for moca transfer.
     */
    function setMocaTransferGasLimit(uint256 newMocaTransferGasLimit) external onlyRole(ISSUER_STAKING_CONTROLLER_ADMIN_ROLE) whenNotPaused {
        require(newMocaTransferGasLimit >= 2300, Errors.InvalidGasLimit());

        // cache old + update to new gas limit
        uint256 oldMocaTransferGasLimit = MOCA_TRANSFER_GAS_LIMIT;
        MOCA_TRANSFER_GAS_LIMIT = newMocaTransferGasLimit;

        emit Events.MocaTransferGasLimitUpdated(oldMocaTransferGasLimit, newMocaTransferGasLimit);
    }



//------------------------------- Risk-related functions ---------------------------------------------------------
   
    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external onlyRole(MONITOR_ROLE) whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external onlyRole(DEFAULT_ADMIN_ROLE) whenPaused {
        require(isFrozen == 0, Errors.IsFrozen());
        isFrozen = 1;
        emit Events.ContractFrozen();
    }  


    /**
     * @notice Allows issuers or the emergency exit handler to withdraw all staked and pending-unstake MOCA for specified issuers during an emergency.
     * @dev If called by an issuer, they should pass an array of length 1 with their own address.
     *      If called by the emergency exit handler, they should pass an array of length > 1 with the addresses of the issuers to exit.
     *      Can only be called when the contract is frozen.
     *      The mapping `pendingUnstakedMoca` is not cleared per timestamp; this is a non-issue since the contract is frozen.
     * @param issuerAddresses Array of issuer addresses to process in batch
     */
    function emergencyExit(address[] calldata issuerAddresses) external {
        require(isFrozen == 1, Errors.NotFrozen());
        require(issuerAddresses.length > 0, Errors.InvalidArray());

        uint256 totalMocaStaked;
        uint256 totalMocaPendingUnstake;

        for(uint256 i; i < issuerAddresses.length; ++i) { 
            address issuerAddress = issuerAddresses[i];
            
            // check: if NOT emergency exit handler, AND NOT, the issuer themselves: revert
            if (!hasRole(EMERGENCY_EXIT_HANDLER_ROLE, msg.sender) && msg.sender != issuerAddress) {
                revert Errors.OnlyCallableByEmergencyExitHandlerOrIssuer();
            }

            // get issuer's total moca: staked and pending unstake
            uint256 mocaStaked = issuers[issuerAddress]; 
            uint256 mocaPendingUnstake = totalPendingUnstakedMoca[issuerAddress]; 

            // sanity check: skip if 0; no need for address check
            uint256 totalMocaAmount = mocaStaked + mocaPendingUnstake;
            if(totalMocaAmount == 0) continue;

            // reset issuer's moca staked and pending unstake 
            delete issuers[issuerAddress]; 
            delete totalPendingUnstakedMoca[issuerAddress]; 

            // update counters
            totalMocaStaked += mocaStaked; 
            totalMocaPendingUnstake += mocaPendingUnstake; 

            // transfer moca [wraps if transfer fails within gas limit]
            _transferMocaAndWrapIfFailWithGasLimit(WMOCA, issuerAddress, totalMocaAmount, MOCA_TRANSFER_GAS_LIMIT);
        }

        // globals: decrement accordingly
        if(totalMocaStaked > 0) TOTAL_MOCA_STAKED -= totalMocaStaked; 
        if(totalMocaPendingUnstake > 0) TOTAL_MOCA_PENDING_UNSTAKE -= totalMocaPendingUnstake; 

        // emit event if total moca amount is > 0
        uint256 totalMocaAmountToExit = totalMocaStaked + totalMocaPendingUnstake;
        if(totalMocaAmountToExit > 0) emit Events.EmergencyExit(issuerAddresses, totalMocaAmountToExit); 
    }
}