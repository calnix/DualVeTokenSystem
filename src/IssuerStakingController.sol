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
        if(addressBook_ == address(0)) revert Errors.InvalidAddress();
        addressBook = IAddressBook(addressBook_);

        if(unstakeDelay == 0) revert Errors.InvalidDelayPeriod();
        UNSTAKE_DELAY = unstakeDelay;

        if(maxStakeAmount == 0) revert Errors.InvalidAmount();
        MAX_STAKE_AMOUNT = maxStakeAmount;
    }

//------------------------------- External functions---------------------------------------------------------------


    /**
     * @notice Allows an issuer to stake a specified amount of MOCA tokens.
     * @dev Transfers MOCA tokens from the sender to this contract.
     * @param amount The amount of MOCA tokens to stake. Must be > 0 and <= MAX_STAKE_AMOUNT.
     */
    function stakeMoca(uint256 amount) external whenNotPaused {
        if(amount == 0) revert Errors.InvalidAmount();
        if(amount > MAX_STAKE_AMOUNT) revert Errors.InvalidAmount();
        
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
        if(amount == 0) revert Errors.InvalidAmount();
        if(amount > issuers[msg.sender]) revert Errors.InsufficientBalance();

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
        if(length == 0) revert Errors.InvalidArray();
        if(totalPendingUnstakedMoca[msg.sender] == 0) revert Errors.NothingToClaim();

        uint256 totalClaimable;

        // check: delay period has passed + non-zero amount
        for(uint256 i; i < length; ++i) {
            uint256 timestamp = timestamps[i];
            
            // sanity checks
            if(timestamp > block.timestamp) revert Errors.InvalidTimestamp();
            if(pendingUnstakedMoca[msg.sender][timestamp] == 0) revert Errors.NothingToClaim();

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
        if(newUnstakeDelay == 0) revert Errors.InvalidDelayPeriod();

        // cache old + update to new unstake delay
        uint256 oldUnstakeDelay = UNSTAKE_DELAY;
        UNSTAKE_DELAY = newUnstakeDelay;

        emit Events.UnstakeDelayUpdated(oldUnstakeDelay, newUnstakeDelay);
    }

    function setMaxStakeAmount(uint256 newMaxStakeAmount) external onlyIssuerStakingControllerAdmin whenNotPaused {
        if(newMaxStakeAmount == 0) revert Errors.InvalidAmount();

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
        if(isFrozen == 1) revert Errors.IsFrozen(); 
        _unpause();
    }

    /**
     * @notice To freeze the pool in the event of something untoward occurring
     * @dev Only callable from a paused state, affirming that staking should not resume
     *      Nothing to be updated. Freeze as is.
     *      Enables emergencyExit() to be called.
     */
    function freeze() external onlyGlobalAdmin whenPaused {
        if(isFrozen == 1) revert Errors.IsFrozen();
        isFrozen = 1;
        emit Events.ContractFrozen();
    }  


    /**
     * @notice Allows issuers or the emergency exit handler to withdraw all staked and pending-unstake MOCA for specified issuers during an emergency.
     * @dev If called by an issuer, transfers their staked and pending-unstake MOCA to themselves and resets their balances.
     *      If called by the emergency exit handler, processes each address in issuerAddresses, transferring their MOCA and resetting their balances.
     *      Can only be called when the contract is frozen.
     *      mapping `pendingUnstakedMoca` will retain its values per timestamp. No impact, since contract is frozen.
     * @param issuerAddresses List of issuer addresses to process in batch (used only when called by the emergency exit handler).
     */
    function emergencyExit(address[] calldata issuerAddresses) external {
        if(isFrozen == 0) revert Errors.NotFrozen();

        IAccessController accessController = IAccessController(addressBook.getAccessController());
        bool isEmergencyExitHandler = accessController.isEmergencyExitHandler(msg.sender);

        // caller is expected to be an issuer
        if(!isEmergencyExitHandler){

            // get issuer's moca staked
            uint256 mocaStaked = issuers[msg.sender];
            uint256 mocaPendingUnstake = totalPendingUnstakedMoca[msg.sender];
            
            // sanity check
            uint256 totalMoca = mocaStaked + mocaPendingUnstake;
            if(totalMoca == 0) revert Errors.InvalidAmount();

            // transfer moca to issuer
            _moca().safeTransfer(msg.sender, totalMoca);

            // reset issuer's moca staked and pending unstake
            delete issuers[msg.sender];
            delete totalPendingUnstakedMoca[msg.sender];

            // globals: decrement accordingly
            TOTAL_MOCA_STAKED -= mocaStaked;
            TOTAL_MOCA_PENDING_UNSTAKE -= mocaPendingUnstake;
            
            emit Events.EmergencyExit(msg.sender, totalMoca);
            
        } else { // emergency exit handler is calling onBehalfOf

            uint256 totalMocaStaked;
            uint256 totalMocaPendingUnstake;

            for(uint256 i; i < issuerAddresses.length; ++i) {
                
                address issuerAddress = issuerAddresses[i];
                
                // get issuer's total moca: staked and pending unstake
                uint256 mocaStaked = issuers[issuerAddress];
                uint256 mocaPendingUnstake = totalPendingUnstakedMoca[issuerAddress];
                uint256 totalMocaAmount = mocaStaked + mocaPendingUnstake;
                
                // if 0, skip [no need for address check]
                if(totalMocaAmount == 0) continue;

                // transfer moca to issuer
                _moca().safeTransfer(issuerAddress, totalMocaAmount);

                // reset issuer's moca staked and pending unstake
                delete issuers[issuerAddress];
                delete totalPendingUnstakedMoca[issuerAddress];

                totalMocaStaked += mocaStaked;
                totalMocaPendingUnstake += mocaPendingUnstake;
            }

            // globals: decrement accordingly
            TOTAL_MOCA_STAKED -= totalMocaStaked;
            TOTAL_MOCA_PENDING_UNSTAKE -= totalMocaPendingUnstake;

            emit Events.EmergencyExitBatch(issuerAddresses, (totalMocaStaked + totalMocaPendingUnstake));
        }
    }

}