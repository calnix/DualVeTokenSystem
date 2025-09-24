// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

// External: OZ
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

// libraries
import {EpochMath} from "../libraries/EpochMath.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {Constants} from "../libraries/Constants.sol";

import {Errors} from "../libraries/Errors.sol";
import {Events} from "../libraries/Events.sol";

// interfaces
import {IAddressBook} from "../interfaces/IAddressBook.sol";
import {IAccessController} from "../interfaces/IAccessController.sol";


/**
 * @title EscrowedMoca
 * @author Calnix [@cal_nix]
 * @notice EscrowedMoca is a non-transferable token representing the escrowed MOCA tokens.
 * @dev EscrowedMoca represents MOCA tokens held in escrow, which can be redeemed under various options—similar to early bond redemption—with penalties applied based on the chosen redemption method.
*/


/**
    esMoca is given out to:
    1. validators as discretionary rewards
    2. voters receive their voting rewards as esMoca [from verification fee split]
    3. verifiers receive subsidies as esMoca

    USD8 must be withdrawn from PaymentsController
    converted to Moca
    Moca must be then converted to esMoca, via this contract
 */

contract EscrowedMoca is ERC20, Pausable {
    using SafeERC20 for IERC20;

    // immutable
    IAddressBook internal immutable _addressBook;

    // penalty split between voters and treasury
    uint256 public VOTERS_PENALTY_SPLIT;         // 2dp precision (XX.yy) | range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 
    
    //note: or just combine and track the sum total. distribution is discretionary and through finalizeEpoch on VotingController
    uint256 public TOTAL_ACCRUED_TO_VOTERS; 
    uint256 public TOTAL_ACCRUED_TO_TREASURY; 

//-------------------------------mapping----------------------------------------------

    // redemption options | range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 | 2dp precision (XX.yy)
    mapping(uint256 redemptionType => DataTypes.RedemptionOption redemptionOption) public redemptionOptions;
    
    // redemption history
    mapping(address user => mapping(uint256 redemptionTimestamp => DataTypes.Redemption redemption)) public redemptionSchedule;

    // addresses that can transfer esMoca to other addresses: Asset Manager to deposit to VotingController
    mapping(address addr => bool isWhitelisted) public whitelist;


//-------------------------------constructor------------------------------------------

    constructor(address addressBook) ERC20("esMoca", "esMoca") {
        
        _addressBook = IAddressBook(addressBook);
    }

//-------------------------------user functions------------------------------------------

    /**
     * @notice Converts Moca tokens to esMoca by transferring Moca from the user and minting an equivalent amount of esMoca.
     * @dev Moca tokens are transferred from the caller to this contract and esMoca is minted 1:1 to the caller.
     * @custom:security Non-reentrant, only callable when not paused.
     * @custom:assumptions Assumes Moca token address is valid and user has approved sufficient Moca.
     * @param amount The amount of Moca to convert to esMoca.
     */
    function escrowMoca(uint256 amount) external whenNotPaused {
        require(amount > 0, Errors.InvalidAmount());

        _moca().safeTransferFrom(msg.sender, address(this), amount);

        // mint esMoca to user
        _mint(msg.sender, amount);

        emit EscrowedMoca(msg.sender, amount);
    }


    /**
     * @notice Redeems esMoca for Moca using a specified redemption option.
     * @dev Redemption is irreversible once initiated. Users select from available redemption options, each with distinct lock durations and penalty structures.
     * @param redemptionAmount Amount of esMoca to redeem.
     * @param redemptionOption Redemption option index. (0: Standard, 1: Early, 2: Instant)
     * @custom:requirements `redemptionOption` must be enabled and configured.
     * Emits {RedemptionScheduled} or {Redeemed} depending on lock duration.
     */
    function selectRedemptionOption(uint256 redemptionOption, uint128 redemptionAmount) external whenNotPaused {
        // sanity checks: amount & balance
        require(redemptionAmount > 0, Errors.InvalidAmount());
        require(balanceOf(msg.sender) >= redemptionAmount, Errors.InsufficientBalance());
        
        // get redemption option ptr + sanity check: redemption option
        DataTypes.RedemptionOption memory option = redemptionOptions[redemptionOption];
        require(option.isEnabled, Errors.RedemptionOptionAlreadyDisabled());
        
        uint128 mocaReceivable;
        uint128 penaltyAmount;
        // calculate moca receivable + penalty
        if(option.receivablePct == Constants.PRECISION_BASE) {
            // redemption with no penalty
            mocaReceivable = redemptionAmount;
        } else {
            // redemption with penalty
            mocaReceivable = redemptionAmount * option.receivablePct / Constants.PRECISION_BASE;
            penaltyAmount = redemptionAmount - mocaReceivable;
        }
        
        // calculate redemptionTimestamp
        uint256 redemptionTimestamp = block.timestamp + option.lockDuration;

        // book redemption amount + penalty amount
        redemptionSchedule[msg.sender][redemptionTimestamp].amount += mocaReceivable;
        redemptionSchedule[msg.sender][redemptionTimestamp].penalty += penaltyAmount;

        if(option.lockDuration == 0) {
            
            // Instant redemption: mark claimed, transfer immediately
            redemptionSchedule[msg.sender][redemptionTimestamp].claimed = true;
            emit Redeemed(msg.sender, mocaReceivable, redemptionTimestamp, redemptionOption);

            _moca().safeTransfer(msg.sender, mocaReceivable);

        } else {    // Scheduled redemption
            emit RedemptionScheduled(msg.sender, mocaReceivable, penaltyAmount, redemptionTimestamp, redemptionOption);
        }

        // burn corresponding esMoca tokens from the caller
        _burn(msg.sender, redemptionAmount);


        // ------ if penalty, calculate and book splits ------
        if(penaltyAmount > 0) {
            
            // calculate penalty amount
            uint256 penaltyToVoters = penaltyAmount * VOTERS_PENALTY_SPLIT / Constants.PRECISION_BASE;
            uint256 penaltyToTreasury = penaltyAmount - penaltyToVoters;
            
            // book penalty amounts to globals
            if(penaltyToTreasury > 0) TOTAL_ACCRUED_TO_TREASURY += penaltyToTreasury;
            if(penaltyToVoters > 0) TOTAL_ACCRUED_TO_VOTERS += penaltyToVoters;

            emit PenaltyAccrued(penaltyToVoters, penaltyToTreasury);
        }
    }


    /**
     * @notice Claims the redeemed MOCA tokens after the lock period has elapsed.
     * @dev Transfers the receivable MOCA to the caller and marks the redemption as claimed.
     *      Emits a {Redeemed} event upon successful claim.
     * @param redemptionTimestamp The timestamp at which the redemption becomes available for claim.
     * @custom:revert RedemptionNotAvailableYet if the redemption is not yet available.
     * @custom:revert AlreadyClaimed if the redemption has already been claimed.
     */
    function claimRedemption(uint256 redemptionTimestamp) external whenNotPaused {
        // check redemption eligibility
        require(redemptionTimestamp < block.timestamp, Errors.RedemptionNotAvailableYet());

        DataTypes.Redemption storage redemptionPtr = redemptionSchedule[msg.sender][redemptionTimestamp];

        // check if redemption is claimed
        require(redemptionPtr.claimed == false, Errors.AlreadyClaimed());

        // get redemption amount + update claimed status
        uint128 mocaReceivable = redemptionPtr.amount;
        redemptionPtr.claimed = true;

        emit Redeemed(msg.sender, mocaReceivable, redemptionTimestamp, redemptionPtr.penalty);

        // transfer moca
        _moca().safeTransfer(msg.sender, mocaReceivable);
    }


//-------------------------------asset manager functions-----------------------------------------


    /**
     * @notice Escrows Moca on behalf of multiple users.
     * @dev Transfers Moca from the caller to the contract and mints esMoca to each user.
     * @param users Array of user addresses to escrow for.
     * @param amounts Array of amounts to escrow for each user.
     */
    function escrowMocaOnBehalf(address[] calldata users, uint256[] calldata amounts) external onlyAssetManager {
        uint256 length = users.length;
        require(length == amounts.length, Errors.InvalidArrayLength());
        
        uint256 totalMocaAmount;
        for (uint256 i; i < length; ++i) {
            // get user + amount
            address user = users[i];
            uint256 amount = amounts[i];

            // sanity checks
            require(amount > 0, Errors.InvalidAmount());
            require(user != address(0), Errors.InvalidAddress());

            // mint esMoca to user
            _mint(user, amount);

            // add to total amount
            totalMocaAmount += amount;
        }

        // transfer total moca 
        _moca().safeTransferFrom(msg.sender, address(this), totalMocaAmount);

        emit StakedOnBehalf(users, amounts);
    }

//-------------------------------admin: update functions-----------------------------------------


    /**
     * @notice Updates the percentage of penalty allocated to voters.
     * @dev The value must be within (0, 10_000), representing up to 100% with 2 decimal precision.
     *      Only callable by EscrowedMocaAdmin.
     * @param penaltyToVoters The new penalty percentage for voters (2dp precision, e.g., 100 = 1%).
     */
    function setPenaltyToVoters(uint256 penaltyToVoters) external onlyEscrowedMocaAdmin {
        // 2dp precision (XX.yy) | range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 
        require(penaltyToVoters < 10_000, Errors.InvalidPercentage());
        require(penaltyToVoters > 0, Errors.InvalidPercentage());

        uint256 oldPenaltyToVoters = VOTERS_PENALTY_SPLIT;
        VOTERS_PENALTY_SPLIT = penaltyToVoters;

        emit PenaltyToVotersUpdated(oldPenaltyToVoters, penaltyToVoters);
    }


    /**
     * @notice Sets the redemption option for a given redemption type.
     * @dev The receivablePct must be greater than 0.
     *      Only callable by EscrowedMocaAdmin.
     * @param redemptionOption The redemption option index.
     * @param lockDuration The lock duration for the redemption option. [0 for instant redemption]
     * @param receivablePct The conversion rate for the redemption option. [cannot be 0; else nothing is receivable]
     */
    function setRedemptionOption(uint256 redemptionOption, uint128 lockDuration, uint128 receivablePct) external onlyEscrowedMocaAdmin {
        // range:[1,10_000] 100%: 10_000 | 1%: 100 | 0.1%: 10 | 0.01%: 1 
        require(receivablePct > 0, Errors.InvalidPercentage());
        require(receivablePct <= 10_000, Errors.InvalidPercentage());

        redemptionOptions[redemptionOption] = DataTypes.RedemptionOption({
            lockDuration: lockDuration,
            receivablePct: receivablePct,
            isEnabled: true
        });

        emit RedemptionOptionUpdated(redemptionOption, lockDuration, receivablePct);
    }

    /**
     * @notice Enables or disables a redemption option.
     * @dev  Only callable by EscrowedMocaAdmin.
     * @param redemptionOption Index of the redemption option to update.
     * @param enable Set to true to enable, false to disable the redemption option.
     */
    function setRedemptionOptionStatus(uint256 redemptionOption, bool enable) external onlyEscrowedMocaAdmin {
        DataTypes.RedemptionOption storage optionPtr = redemptionOptions[redemptionOption];

        if (enable) {
            require(optionPtr.isDisabled, Errors.RedemptionOptionAlreadyEnabled());
            optionPtr.isDisabled = false;
            emit RedemptionOptionEnabled(redemptionOption, optionPtr.receivablePct, optionPtr.lockDuration);
            
        } else {
            require(!optionPtr.isDisabled, Errors.RedemptionOptionAlreadyDisabled());
            optionPtr.receivablePct = 0;
            optionPtr.isDisabled = true;
            emit RedemptionOptionDisabled(redemptionOption);
        }
    }

    // Note: for Asset Manager to deposit esMoca to VotingController
    /**
     * @notice Updates the whitelist status for an address, allowing or revoking permission to transfer esMoca.
     * @dev   Whitelisted addresses can transfer esMoca to other addresses (e.g., Asset Manager to VotingController).
     * @param addr The address to update whitelist status for.
     * @param isWhitelisted True to whitelist, false to remove from whitelist.
     */
    function setWhitelistStatus(address addr, bool isWhitelisted) external onlyEscrowedMocaAdmin {
        require(addr != address(0), Errors.InvalidAddress());

        bool currentStatus = whitelist[addr];
        require(currentStatus != isWhitelisted, Errors.WhitelistStatusUnchanged());

        whitelist[addr] = isWhitelisted;

        emit AddressWhitelisted(addr, isWhitelisted);
    }


    // claim for voters and treasury

//-------------------------------Internal functions---------------------------------------------------------------

    function _moca() internal view returns (IERC20){
        return IERC20(_addressBook.getMoca());
    }

//-------------------------------Modifiers---------------------------------------------------------------
    
    // for setting contract params
    modifier onlyEscrowedMocaAdmin() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isEscrowedMocaAdmin(msg.sender), Errors.OnlyCallableByEscrowedMocaAdmin());
        _;
    }

    // for depositing/withdrawing assets [stakeOnBehalf(), ]
    modifier onlyAssetManager() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isAssetManager(msg.sender), Errors.OnlyCallableByAssetManager());
        _;
    }

    // pause
    modifier onlyMonitor() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isMonitor(msg.sender), Errors.OnlyCallableByMonitor());
        _;
    }

    // for unpause + freeze 
    modifier onlyGlobalAdmin() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isGlobalAdmin(msg.sender), Errors.OnlyCallableByGlobalAdmin());
        _;
    }   
    
    // to exfil assets, when frozen
    modifier onlyEmergencyExitHandler() {
        IAccessController accessController = IAccessController(_addressBook.getAccessController());
        require(accessController.isEmergencyExitHandler(msg.sender), Errors.OnlyCallableByEmergencyExitHandler());
        _;
    }

//-------------------------------Transfer Function Overrides-----------------------------------------

    /**
     * @notice Override ERC20 transfer function to restrict transfers to whitelisted addresses only.
     * @dev Only addresses in the whitelist can transfer esMoca; all others are blocked.
     * @param recipient The address to transfer to.
     * @param amount The amount to transfer.
     * @return success True if transfer is allowed and successful.
     */
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        require(whitelist[msg.sender], Errors.OnlyCallableByWhitelistedAddress());
        return super.transfer(recipient, amount);
    }

    /**
     * @notice Override the transferFrom function to restrict transfers to whitelisted addresses only.
     * @dev Only addresses in the whitelist can transfer esMoca; all others are blocked.
     * @param sender The address which owns the tokens.
     * @param recipient The address to transfer to.
     * @param amount The amount to transfer.
     * @return success True if transfer is allowed and successful.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        require(whitelist[sender], Errors.OnlyCallableByWhitelistedAddress());
        return super.transferFrom(sender, recipient, amount);
    }
}