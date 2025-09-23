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

        IERC20 mocaToken = IERC20(_addressBook.getMoca());
        require(address(mocaToken) != address(0), Errors.InvalidAddress());

        mocaToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }


    /**
     * @notice Redeems esMoca for Moca using a specified redemption option.
     * @dev Redemption is irreversible once initiated. Users select from available redemption options, each with distinct lock durations and penalty structures.
     * @param redemptionAmount Amount of esMoca to redeem.
     * @param redemptionOption Redemption option index. (0: Standard, 1: Early, 2: Instant)
     * @custom:requirements `redemptionOption` must be enabled and configured.
     * Emits {RedemptionScheduled} or {Redeemed} depending on lock duration.
     */
    function redeem(uint128 redemptionAmount, uint256 redemptionOption) external whenNotPaused {
        // sanity checks: amount & balance
        require(redemptionAmount > 0, Errors.InvalidAmount());
        require(balanceOf(msg.sender) >= redemptionAmount, Errors.InsufficientBalance());
        
        // get redemption option ptr + sanity check: redemption option
        DataTypes.RedemptionOption memory option = redemptionOptions[redemptionOption];
        require(option.receivablePct > 0, Errors.InvalidRedemptionOption());    //  redemption type is not set or disabled

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

            mocaToken.safeTransfer(msg.sender, mocaReceivable);

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

    // claim everything. no partial claims.
    // validators to claim esMoca from direct emissions
    function claimRedemption(uint256 redemptionTimestamp) external {
        // check if redemption is available
        require(redemptionTimestamp < block.timestamp, "Redemption not available yet");
        
        Redemption memory redemption = redemptions[msg.sender][redemptionTimestamp];

        // check if there is anything to claim
        require(redemption.claimed == false, "Already claimed");

        // update claimed status
        redemptions[msg.sender][redemptionTimestamp].claimed = true;

        // event: claimed

        // transfer moca
        mocaToken.safeTransfer(msg.sender, redemption.amount);
    }


//-------------------------------admin functions-----------------------------------------

    // might need a fn to convert moca to esMoca
    // might also needs a stakeOnBehalf fn

    // note: for distributing esMoca to validators - direct emissions
    // note: for allocating subsidies to a pool, per epoch
    function stakeOnBehalf(address user, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(user != address(0), "Invalid user address");
        require(amount > 0, "Amount must be greater than 0");
        
        mocaToken.safeTransferFrom(msg.sender, address(this), amount);
        
        _mint(user, amount);
        
        // Emit stake event
    }

    function setPenaltyToVoters(uint256 penaltyToVoters) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(penaltyToVoters <= 100, "Penalty to voters must be less than or equal to 100");

        PENALTY_FACTOR_TO_VOTERS = penaltyToVoters;

        // event
    }

    // redemptionOption & lockDuration, can have 0 values
    function setRedemptionOption(uint256 redemptionOption, uint128 lockDuration, uint128 conversionRate) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(conversionRate > 0, "Conversion rate must be greater than 0");

        redemptionOptions[redemptionOption] = RedemptionOption({
            lockDuration: lockDuration,
            conversionRate: conversionRate
        });

        // event
    }

    // disable redemption option
    function disableRedemption(uint256 redemptionOption) external onlyRole(DEFAULT_ADMIN_ROLE) {
        redemptionOptions[redemptionOption].conversionRate = 0;

        // event
    }

    function setTreasury(address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TREASURY = treasury;
        // event
    }

    // for voting contract to claim esMoca from voters
    // for verifier subsidy claims
    function whitelistAddress(address addr, bool isWhitelisted) external onlyRole(DEFAULT_ADMIN_ROLE) {
        whitelist[addr] = isWhitelisted;

        // event
    }


    // claim for voters and treasury

//-------------------------------overrides-----------------------------------------

    /**
     * @notice Override the transfer function to block transfers
     * @dev veMOCA is non-transferable
     */
    function transfer(address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }

    /**
     * @notice Override the transferFrom function to block transfers
     * @dev veMOCA is non-transferable
     */
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("veMOCA is non-transferable");
    }
}