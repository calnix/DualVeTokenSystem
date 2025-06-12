// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

contract Validators is AccessControl {
    using SafeERC20 for IERC20;

    struct Validator {
        uint256 stakedAmount;
        uint256 lockedUntil;
        uint256 totalSlashed;
    }

    mapping(address => Validator) public validators;
    mapping(address validator => mapping(uint256 timestamp => uint256 amountSlashed)) public slashedAmounts;
    
    IERC20 public immutable mocaToken;
    
    // validator staking requirements
    uint256 public MOCA_STAKING_REQUIREMENT;
    uint256 public LOCK_DURATION;
    
    // roles
    bytes32 public constant VALIDATOR_ROLE = keccak256("VALIDATOR_ROLE"); 

//-------------------------------constructor------------------------------------------

    constructor(address mocaToken_, address owner, uint256 mocaStakingRequirement, uint256 lockDuration) {
        mocaToken = IERC20(mocaToken_);

        MOCA_STAKING_REQUIREMENT = mocaStakingRequirement;
        LOCK_DURATION = lockDuration;

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

//-------------------------------validator functions------------------------------------------


    function lockMoca() external onlyRole(VALIDATOR_ROLE) {
        //require(isValidator[msg.sender], "Not a validator");

        mocaToken.safeTransferFrom(msg.sender, address(this), MOCA_STAKING_REQUIREMENT);
    }

    function unlockMoca() external onlyRole(VALIDATOR_ROLE) {
        //require(isValidator[msg.sender], "Not a validator");

        mocaToken.safeTransferFrom(address(this), msg.sender, MOCA_STAKING_REQUIREMENT);
    }

//-------------------------------admin functions--------------------------------------------

    function whitelistValidator(address validator, bool toWhitelist) external onlyRole(DEFAULT_ADMIN_ROLE) {
        //isValidator[validator] = true;
        if (toWhitelist) {
            _grantRole(VALIDATOR_ROLE, validator);
        } else {
            _revokeRole(VALIDATOR_ROLE, validator);
        }
    }

    function slashValidator(address validator, uint256 penalty) external onlyRole(DEFAULT_ADMIN_ROLE) {

        // update validator struct
        validators[validator].totalSlashed += penalty;

        // update slashed amounts
        slashedAmounts[validator][block.timestamp] += penalty;


        //_revokeRole(VALIDATOR_ROLE, validator);



        // event
    }


    function setMocaStakingRequirement(uint256 mocaStakingRequirement) external onlyRole(DEFAULT_ADMIN_ROLE) {
        MOCA_STAKING_REQUIREMENT = mocaStakingRequirement;
        // event
    }

    function setLockDuration(uint256 lockDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        LOCK_DURATION = lockDuration;
        //event
    }



//-------------------------------view functions--------------------------------------------
}