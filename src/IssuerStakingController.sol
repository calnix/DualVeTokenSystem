// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {Events} from "./libraries/Events.sol";
import {Errors} from "./libraries/Errors.sol";

// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";


/**
 * @title IssuerStakingController
 * @author Calnix [@cal_nix]
 * @notice Central contract managing issuer staking and unstaking
 * @dev Integrates with external controllers and enforces protocol-level access and safety checks
 */


contract IssuerStakingController is Pausable {
    using SafeERC20 for IERC20;

    IAddressBook public immutable addressBook;

    uint256 public TOTAL_MOCA_STAKED;
    uint256 public TOTAL_MOCA_PENDING_UNSTAKE;
    
    uint256 public UNSTAKE_DELAY;
    uint256 public MAX_STAKE_AMOUNT;    // to prevent fat-finger mistakes on excess allocation on staking
    
    // risk management
    uint256 public isFrozen;

//------------------------------- Mappings-----------------------------------------------------

    mapping(address issuer => uint256 mocaStaked) public issuers;

    mapping(address issuer => mapping(uint256 timestamp => uint256 pendingUnstake)) public pendingUnstakedMoca;

    mapping(address issuer => uint256 totalPendingUnstake) public totalPendingUnstakedMoca;

//------------------------------- Constructor---------------------------------------------------------------------

    constructor(address addressBook_, uint256 unstakeDelay, uint256 maxStakeAmount) {
        require(addressBook_ != address(0), Errors.InvalidAddress());
        addressBook = IAddressBook(addressBook_);

        require(unstakeDelay > 0, Errors.InvalidDelayPeriod());
        UNSTAKE_DELAY = unstakeDelay;

        require(maxStakeAmount > 0, Errors.InvalidAmount());
        MAX_STAKE_AMOUNT = maxStakeAmount;
    }

//------------------------------- External functions---------------------------------------------------------------


    /**
     * @notice Allows an issuer to stake a specified amount of MOCA tokens.
     * @dev Transfers MOCA tokens from the sender to this contract.
     * @param amount The amount of MOCA tokens to stake. Must be > 0 and <= MAX_STAKE_AMOUNT.
     */
    function stakeMoca(uint256 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());
        require(amount <= MAX_STAKE_AMOUNT, Errors.InvalidAmount());
        
        // update total moca staked
        TOTAL_MOCA_STAKED += amount;

        // update issuer's moca staked
        issuers[msg.sender] += amount;

        // transfer moca from msg.sender to contract
        _moca().safeTransferFrom(msg.sender, address(this), amount);

        emit Events.Staked(msg.sender, amount);
    }

    // note: does not transfer moca to issuer
    /**
     * @notice Initiates the unstaking process for the caller's MOCA tokens.
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
     * @param timestamps Array of timestamps at which the unstaked MOCA tokens are claimable.
     */
    function claimUnstake(uint256[] calldata timestamps) external whenNotPaused {
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
        
        // update global: only update pending unstake [active staked is not affected]
        TOTAL_MOCA_PENDING_UNSTAKE -= totalClaimable;
        totalPendingUnstakedMoca[msg.sender] -= totalClaimable;

        // transfer moca to issuer
        _moca().safeTransfer(msg.sender, totalClaimable);

        emit Events.UnstakeClaimed(msg.sender, totalClaimable);
    }

//------------------------------- Admin: setUnstakeDelay -------------------------------------------------------------

    /**
     * @notice Sets the unstake delay.
     * @dev Only callable by the IssuerStakingController admin.
     * @param newUnstakeDelay The new unstake delay.
     */
    function setUnstakeDelay(uint256 newUnstakeDelay) external onlyIssuerStakingControllerAdmin whenNotPaused {
        require(newUnstakeDelay > 0, Errors.InvalidDelayPeriod());

        // cache old + update to new unstake delay
        uint256 oldUnstakeDelay = UNSTAKE_DELAY;
        UNSTAKE_DELAY = newUnstakeDelay;

        emit Events.UnstakeDelayUpdated(oldUnstakeDelay, newUnstakeDelay);
    }

    function setMaxStakeAmount(uint256 newMaxStakeAmount) external onlyIssuerStakingControllerAdmin whenNotPaused {
        require(newMaxStakeAmount > 0, Errors.InvalidAmount());

        // cache old + update to new max stake amount
        uint256 oldMaxStakeAmount = MAX_STAKE_AMOUNT;
        MAX_STAKE_AMOUNT = newMaxStakeAmount;

        emit Events.MaxStakeAmountUpdated(oldMaxStakeAmount, newMaxStakeAmount);
    }

//------------------------------- Internal functions---------------------------------------------------------------

    // if zero address, reverts automatically
    function _moca() internal view returns (IERC20){
        return IERC20(addressBook.getMoca());
    }

//------------------------------- Modifiers -------------------------------------------------------

    modifier onlyMonitor() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isMonitor(msg.sender), Errors.OnlyCallableByMonitor());
        _;
    }

    modifier onlyGlobalAdmin() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isGlobalAdmin(msg.sender), Errors.OnlyCallableByGlobalAdmin());
        _;
    } 

    modifier onlyEmergencyExitHandler() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isEmergencyExitHandler(msg.sender), Errors.OnlyCallableByEmergencyExitHandler());
        _;
    }

    modifier onlyIssuerStakingControllerAdmin() {
        IAccessController accessController = IAccessController(addressBook.getAccessController());
        require(accessController.isIssuerStakingControllerAdmin(msg.sender), Errors.OnlyCallableByIssuerStakingControllerAdmin());
        _;
    }

//------------------------------- Risk-related functions ---------------------------------------------------------
   
    /**
     * @notice Pause contract. Cannot pause once frozen
     */
    function pause() external onlyMonitor whenNotPaused {
        _pause();
    }

    /**
     * @notice Unpause pool. Cannot unpause once frozen
     */
    function unpause() external onlyGlobalAdmin whenPaused {
        require(isFrozen == 0, Errors.IsFrozen()); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external onlyGlobalAdmin whenPaused {
        require(isFrozen == 0, Errors.IsFrozen());
        isFrozen = 1;
        emit Events.ContractFrozen();
    }  


    /**
     * @notice Allows the emergency exit handler to withdraw all staked and pending-unstake MOCA for specified issuers during an emergency.
     * @dev Only callable by the emergency exit handler when the contract is frozen.
     *      For each address in `issuerAddresses`, transfers the issuer's staked and pending-unstake MOCA to the issuer, 
     *      resets staked and pending-unstake balances, and emits an EmergencyExit event with the processed issuers and total MOCA transferred.
     *      The mapping `pendingUnstakedMoca` is not cleared per timestamp; this is a non-issue since the contract is frozen.
     * @param issuerAddresses Array of issuer addresses to process in batch.
     */
    function emergencyExit(address[] calldata issuerAddresses) external onlyEmergencyExitHandler {
        require(isFrozen == 1, Errors.NotFrozen());
        require(issuerAddresses.length > 0, Errors.InvalidArray());

        uint256 totalMocaStaked;
        uint256 totalMocaPendingUnstake;

        for(uint256 i; i < issuerAddresses.length; ++i) {

            address issuerAddress = issuerAddresses[i];

            // get issuer's total moca: staked and pending unstake
            uint256 mocaStaked = issuers[issuerAddress];
            uint256 mocaPendingUnstake = totalPendingUnstakedMoca[issuerAddress];

            // sanity check: skip if 0; no need for address check
            uint256 totalMocaAmount = mocaStaked + mocaPendingUnstake;
            if(totalMocaAmount == 0) continue;

            // transfer moca to issuer
            _moca().safeTransfer(issuerAddress, totalMocaAmount);

            // reset issuer's moca staked and pending unstake
            delete issuers[issuerAddress];
            delete totalPendingUnstakedMoca[issuerAddress];

            // update counters
            totalMocaStaked += mocaStaked;
            totalMocaPendingUnstake += mocaPendingUnstake;
        }

        // globals: decrement accordingly
        TOTAL_MOCA_STAKED -= totalMocaStaked;
        TOTAL_MOCA_PENDING_UNSTAKE -= totalMocaPendingUnstake;

        emit Events.EmergencyExit(issuerAddresses, (totalMocaStaked + totalMocaPendingUnstake));
    }
}