// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

contract esMOCA is ERC20, AccessControl {
    using SafeERC20 for IERC20;

    IERC20 public immutable mocaToken;

    // check naming style; MOCA or Moca?
    constructor(address mocaToken_, address owner) ERC20("esMOCA", "esMOCA") {
        mocaToken = IERC20(mocaToken);

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
    }

    //-------------------------------admin functions------------------------------------------

    function stakeMoca(uint256 amount) external {
    //    mocaToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function redeemMoca(uint256 amount) external {
    //    mocaToken.safeTransfer(msg.sender, amount);
    }


    //-------------------------------admin functions------------------------------------------

    function stakeOnBehalf(address user, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    }

}