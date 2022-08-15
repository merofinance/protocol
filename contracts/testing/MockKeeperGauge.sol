// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../Controller.sol";
import "../tokenomics/KeeperGauge.sol";

contract MockKeeperGauge is KeeperGauge {
    constructor(IAddressProvider _addressProvider, address _pool)
        KeeperGauge(_addressProvider, _pool)
    {}

    function advanceEpoch() external override {}
}
