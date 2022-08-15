// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "./IMockInflationManager.sol";
import "../tokenomics/InflationManager.sol";

contract MockInflationManager is InflationManager, IMockInflationManager {
    constructor(IAddressProvider addressProvider) InflationManager(addressProvider) {}

    function callKillKeeperGauge(address _keeperGauge) external override {
        IKeeperGauge(_keeperGauge).kill();
    }
}
