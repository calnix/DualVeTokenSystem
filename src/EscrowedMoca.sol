// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// libraries
import {EpochMath} from "./libraries/EpochMath.sol";
import {DataTypes} from "./libraries/DataTypes.sol";

import {Errors} from "./libraries/Errors.sol";
import {Events} from "./libraries/Events.sol";

// interfaces
import {IAddressBook} from "./interfaces/IAddressBook.sol";
import {IAccessController} from "./interfaces/IAccessController.sol";


/**
 * @title EscrowedMoca
 * @author Calnix [@cal_nix]
 * @notice EscrowedMoca is a non-transferable token representing the escrowed MOCA tokens.
 * @dev EscrowedMoca represents MOCA tokens held in escrow, which can be redeemed under various options—similar to early bond redemption—with penalties applied based on the chosen redemption method.
*/


/**
    esMoca is given out to:
    1. validators as direct emissions
    2. voters gets esMoca from verification fee split
    3. verifiers claim subsidies as esMoca

    voters+verifiers will have to initiate claim through voting contract
 */

contract EscrowedMoca is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable mocaToken;
    uint256 public constant PRECISION_BASE = 100;    // 100%: 100, 1%: 1 | no decimal places

    uint256 public PENALTY_FACTOR_TO_VOTERS;         // range:[1,100] 100%: 100 | 1%: 1. no decimal places
    
    uint256 public totalPenaltyToVoters; 
    uint256 public totalPenaltyToTreasury; 
    
    address public TREASURY; // multisig or contract?

    struct RedemptionOption {
        uint128 lockDuration;       // number of seconds until redemption is available    | 0 for instant redemption
        uint128 conversionRate;     // range:[1,100] 100%: 100 | 1%: 1. no decimal places | if 0, redemption type is disabled
    }

    struct Redemption {
        uint256 amount;
        bool claimed; // true if claimed, false if not
    }

    mapping(uint256 redemptionType => RedemptionOption redemptionOption) public redemptionOptions;

    mapping(address user => mapping(uint256 timestamp => Redemption redemption)) public redemptions;

    // addresses that can transfer esMoca to other addresses: voting claims, verifier subsidy claims
    mapping(address addr => bool isWhitelisted) public whitelist;


//-------------------------------constructor------------------------------------------

    // check naming style; MOCA or Moca?
    constructor(address mocaToken_, address owner) ERC20("esMOCA", "esMOCA") {
        mocaToken = IERC20(mocaToken_);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

//-------------------------------user functions------------------------------------------

    //convert moca to esMoca
    function escrow(uint256 amount) external {
        mocaToken.safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }


    /**
     * @notice Allows users to redeem esMOCA for MOCA with different redemption options
     * @dev Cannot cancel redemption once initiated
     * @param redemptionAmount The amount of esMOCA to redeem
     * @param redemptionOption The redemption option (0: Standard, 1: Early, 2: Instant)
     */
    function redeem(uint256 redemptionAmount, uint256 redemptionOption) external {
        require(redemptionAmount > 0, "Amount must be greater than zero");
        require(redemptionOption <= 2, "Invalid redemption option");
        require(balanceOf(msg.sender) >= redemptionAmount, "Insufficient esMOCA balance");

        // get redemption option 
        RedemptionOption memory option = redemptionOptions[redemptionOption];
        require(option.conversionRate > 0, "Redemption option not enabled");

        // burn corresponding esMoca tokens from the caller
        _burn(msg.sender, redemptionAmount);

        // calculate moca receivable + lockup time
        uint256 lockupTime = block.timestamp + option.lockDuration;
        uint256 mocaReceivable = redemptionAmount * option.conversionRate / PRECISION_BASE;
        // book redemption amount
        redemptions[msg.sender][lockupTime].amount += mocaReceivable;

        // ------ if penalty, calculate and book penalty ------
        if(option.conversionRate < PRECISION_BASE) {
            
            // calculate penalty amount
            uint256 penaltyAmount = redemptionAmount - mocaReceivable;
            uint256 penaltyToVoters = penaltyAmount * PENALTY_FACTOR_TO_VOTERS / PRECISION_BASE;        //note: how/where to push the tokens to for claiming?
            uint256 penaltyToTreasury = penaltyAmount - penaltyToVoters;

            _mint(address(this), penaltyToVoters);  // note: update depending how distribution is done
            _mint(TREASURY, penaltyToTreasury);

            // book penalty amount
            totalPenaltyToVoters += penaltyToVoters;
            totalPenaltyToTreasury += penaltyToTreasury;
        }

        //event: redeemed

        // for instant redemption (no lockup), transfer tokens immediately
        if(option.lockDuration == 0) {
            
            // book claimed + transfer
            redemptions[msg.sender][lockupTime].claimed = true;
            mocaToken.safeTransfer(msg.sender, mocaReceivable);

            // event: claimed
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