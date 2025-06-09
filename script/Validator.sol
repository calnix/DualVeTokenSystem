// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Validator {

    address public owner;
    address[] public validators;

    constructor() {
        owner = msg.sender;
    }
}