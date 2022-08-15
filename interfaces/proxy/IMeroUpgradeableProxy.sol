// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IMeroUpgradeableProxy {
    function admin() external returns (address admin_);

    function implementation() external returns (address implementation_);

    function changeAdmin(address newAdmin) external;

    function upgradeTo(address newImplementation) external;

    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
