// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "../access/AuthorizationBase.sol";
import "./MeroUpgradeableProxy.sol";
import "../../interfaces/IRoleManager.sol";
import "../../libraries/Roles.sol";
import "../../libraries/Errors.sol";

/**
 * @dev This is an auxiliary contract meant to be assigned as the admin of a {MeroUpgradeableProxy}. For an
 * explanation of why you would want to use this see the documentation for {MeroUpgradeableProxy}.
 */
contract MeroProxyAdmin is AuthorizationBase {
    IRoleManager private __roleManager;

    function initializeRoleManager(address roleManager_) external {
        require(address(__roleManager) == address(0), Error.CONTRACT_INITIALIZED);
        __roleManager = IRoleManager(roleManager_);
    }

    /**
     * @dev Upgrades `proxy` to `implementation`. See {MeroUpgradeableProxy-upgradeTo}.
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     */
    function upgrade(MeroUpgradeableProxy proxy, address implementation)
        public
        virtual
        onlyGovernance
    {
        proxy.upgradeTo(implementation);
    }

    /**
     * @dev Upgrades `proxy` to `implementation` and calls a function on the new implementation. See
     * {MeroUpgradeableProxy-upgradeToAndCall}.
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     */
    function upgradeAndCall(
        MeroUpgradeableProxy proxy,
        address implementation,
        bytes memory data
    ) public payable virtual onlyGovernance {
        proxy.upgradeToAndCall{value: msg.value}(implementation, data);
    }

    /**
     * @dev Returns the current implementation of `proxy`.
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     */
    function getProxyImplementation(MeroUpgradeableProxy proxy)
        public
        view
        virtual
        returns (address)
    {
        // We need to manually run the static call since the getter cannot be flagged as view
        // bytes4(keccak256("implementation()")) == 0x5c60da1b
        (bool success, bytes memory returndata) = address(proxy).staticcall(hex"5c60da1b");
        require(success, Error.PROXY_CALL_FAILED);
        return abi.decode(returndata, (address));
    }

    /**
     * @dev Returns the current admin of `proxy`.
     *
     * Requirements:
     *
     * - This contract must be the admin of `proxy`.
     */
    function getProxyAdmin(MeroUpgradeableProxy proxy) public view virtual returns (address) {
        // We need to manually run the static call since the getter cannot be flagged as view
        // bytes4(keccak256("admin()")) == 0xf851a440
        (bool success, bytes memory returndata) = address(proxy).staticcall(hex"f851a440");
        require(success, Error.PROXY_CALL_FAILED);
        return abi.decode(returndata, (address));
    }

    function _roleManager() internal view override returns (IRoleManager) {
        return __roleManager;
    }
}
