// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../../interfaces/tokenomics/IInflationManager.sol";

interface IMockInflationManager is IInflationManager {
    function callKillKeeperGauge(address _keeperGauge) external;
}
