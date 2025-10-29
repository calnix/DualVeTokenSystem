// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

/// @title IWMoca - Interface for Wrapped Moca (wMOCA)
interface IWMoca {
    // ERC20 events
    event Approval(address indexed src, address indexed guy, uint256 wad);
    event Transfer(address indexed src, address indexed dst, uint256 wad);

    // wMoca-specific events
    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    // ERC20 view functions
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    // ERC20 mutative functions
    function approve(address guy, uint256 wad) external returns (bool);
    function transfer(address dst, uint256 wad) external returns (bool);
    function transferFrom(address src, address dst, uint256 wad) external returns (bool);

    // wMoca wrapping functions
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}
