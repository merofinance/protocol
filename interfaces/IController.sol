// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "./IAddressProvider.sol";
import "./IGasBank.sol";
import "./pool/ILiquidityPool.sol";
import "./actions/IAction.sol";
import "./tokenomics/IInflationManager.sol";

// solhint-disable ordering

interface IController {
    function addressProvider() external view returns (IAddressProvider);

    function addStakerVault(address stakerVault) external;

    function shutdownPool(ILiquidityPool pool, bool shutdownStrategy) external returns (bool);

    function shutdownAction(IAction action) external;

    /** Keeper functions */
    function updateKeeperRequiredStakedMERO(uint256 amount) external;

    function canKeeperExecuteAction(address keeper) external view returns (bool);

    function keeperRequireStakedMero() external view returns (uint256);

    /** Miscellaneous functions */

    function getTotalEthRequiredForGas(address payer) external view returns (uint256);
}
