// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {AccessControl} from "openzeppelin-contracts/contracts/access/AccessControl.sol";

contract ACLManager is AccessControl {

    /**
        for privileged calls, other contract would refer to this to check permissioning. 
        
        I.e. Voting.sol has modifier:

            function _onlyRiskOrPoolAdmins() internal view {
                IACLManager aclManager = IACLManager(_addressesProvider.getACLManager());
                require(
                    aclManager.isRiskAdmin(msg.sender) || aclManager.isPoolAdmin(msg.sender),
                    Errors.CallerNotRiskOrPoolAdmin()
            );
    */
    
    // roles
    bytes32 public constant override POOL_ADMIN_ROLE = keccak256('POOL_ADMIN');
    bytes32 public constant override ASSET_LISTING_ADMIN_ROLE = keccak256('ASSET_LISTING_ADMIN');
    bytes32 public constant override EMERGENCY_ADMIN_ROLE = keccak256('EMERGENCY_ADMIN');


    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;

    /**
    * @dev Constructor
    * @dev The ACL admin should be initialized at the addressesProvider beforehand
    * @param provider The address of the PoolAddressesProvider
    */
    constructor(IPoolAddressesProvider provider) {
        ADDRESSES_PROVIDER = provider;
        address aclAdmin = provider.getACLAdmin();
        require(aclAdmin != address(0), Errors.AclAdminCannotBeZero());
        _setupRole(DEFAULT_ADMIN_ROLE, aclAdmin);
    }

    function setRoleAdmin(bytes32 role, bytes32 adminRole) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setRoleAdmin(role, adminRole);
    }

    /// @inheritdoc IACLManager
    function addPoolAdmin(address admin) external override {
        grantRole(POOL_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IACLManager
    function removePoolAdmin(address admin) external override {
        revokeRole(POOL_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IACLManager
    function isPoolAdmin(address admin) external view override returns (bool) {
        return hasRole(POOL_ADMIN_ROLE, admin);
    }

}

// https://aave.com/docs/developers/smart-contracts/acl-manager
// https://github.com/aave-dao/aave-v3-origin/blob/main/src/contracts/protocol/configuration/ACLManager.sol