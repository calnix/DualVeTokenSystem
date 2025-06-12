// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
    esMoca is given out to:
    1. validators as direct emissions
    2. voters gets esMoca from verification fee split
    3. verifiers claim subsidies as esMoca
 */

contract esMOCA is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable mocaToken;



    struct RedemptionOption {
        uint128 lockDuration;       // number of seconds until redemption is available
        uint128 conversionRate;     // range:[1,100] 100%: 100 | 1%: 1. no decimal places
    }

    struct Redemption {
        uint256 amount;
        bool claimed; // true if claimed, false if not
    }

    mapping(uint256 redemptionOption => RedemptionOption redemptionOption) public redemptionOptions;

    mapping(address user => mapping(uint256 timestamp => Redemption redemption)) public redemptions;

//-------------------------------constructor------------------------------------------

    // check naming style; MOCA or Moca?
    constructor(address mocaToken_, address owner) ERC20("esMOCA", "esMOCA") {
        mocaToken = IERC20(mocaToken);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

//-------------------------------external functions------------------------------------------

    function stakeMoca(uint256 amount) external {
    //    mocaToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Allows users to redeem esMOCA for MOCA with different redemption options
     * @dev Cannot cancel redemption once initiated
     * @param amount The amount of esMOCA to redeem
     * @param redemptionOption The redemption option (0: Standard, 1: Early, 2: Instant)
     */
    function redeemMoca(uint256 amount, uint256 redemptionOption) external {
        require(amount > 0, "Amount must be greater than zero");
        require(redemptionOption <= 2, "Invalid redemption option");
        require(balanceOf(msg.sender) >= amount, "Insufficient esMOCA balance");

        // burn esMoca tokens from the sender
        _burn(msg.sender, amount);

        // get redemption option 
        RedemptionOption memory option = redemptionOptions[redemptionOption];

        // calculate moca receivable based on conversion rate
        uint256 mocaReceivable = amount * option.conversionRate / 100;
        uint256 lockupTime = block.timestamp + option.lockDuration;

        // book redemption amount
        redemptions[msg.sender][lockupTime].amount += mocaReceivable;

        // for instant redemption (no lockup), transfer tokens immediately
        if (option.lockDuration == 0) {
            
            // book claimed + transfer
            redemptions[msg.sender][lockupTime].claimed = true;
            mocaToken.safeTransfer(msg.sender, mocaReceivable);

            // event: claimed
        }

        //event: redeemed
    }

    // claim everything. no partial claims.
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


//-------------------------------admin functions------------------------------------------

    function stakeOnBehalf(address user, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    }

}