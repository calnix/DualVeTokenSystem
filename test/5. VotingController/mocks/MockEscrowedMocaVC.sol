// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockEscrowedMocaVC
 * @notice Standalone mock EscrowedMoca for VotingController tests
 * @dev Simple ERC20 with mint/burn capabilities for testing
 */
contract MockEscrowedMocaVC is ERC20 {

    // Whitelist for transfers (non-whitelisted addresses can still receive but not send)
    mapping(address => bool) public whitelist;

    constructor() ERC20("esMoca", "esMOCA") {}

    // ═══════════════════════════════════════════════════════════════════
    // Mock Functions for Testing
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Mint esMoca tokens directly to an address (for testing)
     * @param to The recipient address
     * @param amount The amount to mint
     */
    function mintForTesting(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn esMoca tokens from an address (for testing)
     * @param from The address to burn from
     * @param amount The amount to burn
     */
    function burnForTesting(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /**
     * @notice Set whitelist status for an address
     * @param addrs Array of addresses
     * @param status Whitelist status to set
     */
    function setWhitelistStatus(address[] calldata addrs, bool status) external {
        for (uint256 i = 0; i < addrs.length; ++i) {
            whitelist[addrs[i]] = status;
        }
    }

    /**
     * @notice Check if address is whitelisted
     */
    function isWhitelisted(address addr) external view returns (bool) {
        return whitelist[addr];
    }
}
