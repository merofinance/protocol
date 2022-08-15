// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../interfaces/actions/IAction.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/IController.sol";
import "../interfaces/IStakerVault.sol";
import "../interfaces/pool/ILiquidityPool.sol";
import "../interfaces/tokenomics/IInflationManager.sol";
import "../interfaces/IRewardHandler.sol";

import "../libraries/AddressProviderHelpers.sol";
import "../libraries/UncheckedMath.sol";

import "./access/Authorization.sol";

contract Controller is IController, Authorization {
    using UncheckedMath for uint256;
    using AddressProviderHelpers for IAddressProvider;

    IAddressProvider public immutable override addressProvider;

    uint256 public override keeperRequireStakedMero;

    event KeeperRequiredStakedMEROUpdated(uint256 amount);

    constructor(IAddressProvider _addressProvider)
        Authorization(_addressProvider.getRoleManager())
    {
        addressProvider = _addressProvider;
    }

    function addStakerVault(address stakerVault)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.POOL_FACTORY)
    {
        addressProvider.addStakerVault(stakerVault);
        IInflationManager inflationManager = addressProvider.safeGetInflationManager();
        if (address(inflationManager) != address(0)) {
            address lpGauge = IStakerVault(stakerVault).lpGauge();
            if (lpGauge != address(0)) {
                inflationManager.whitelistGauge(lpGauge);
            }
        }
    }

    /**
     * @notice Delists an action.
     * @param action Address of action to delist.
     */
    function shutdownAction(IAction action) external override onlyGovernance {
        require(!action.isShutdown(), Error.ALREADY_SHUTDOWN);
        addressProvider.shutdownAction(address(action));
        action.shutdownAction();
    }

    /**
     * @notice Delists pool.
     * @param pool Address of pool to delist.
     * @return `true` if successful.
     */
    function shutdownPool(ILiquidityPool pool, bool shutdownStrategy)
        external
        override
        onlyGovernance
        returns (bool)
    {
        pool.shutdownPool(shutdownStrategy);
        address lpToken = pool.getLpToken();

        IInflationManager inflationManager = addressProvider.safeGetInflationManager();
        if (address(inflationManager) != address(0)) {
            (bool exists, ) = addressProvider.tryGetStakerVault(lpToken);
            if (exists) {
                inflationManager.removeStakerVaultFromInflation(lpToken);
            }
        }

        return true;
    }

    /**
     * @notice Updates the amount of staked MERO required for a keeper
     * @param amount The amount of staked MERO required for a keeper
     */
    function updateKeeperRequiredStakedMERO(uint256 amount) external override onlyGovernance {
        require(addressProvider.getMEROLocker() != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        keeperRequireStakedMero = amount;
        emit KeeperRequiredStakedMEROUpdated(amount);
    }

    /**
     * @notice Returns true if the given keeper has enough staked MERO to execute actions
     * @param keeper The address of the keeper
     */
    function canKeeperExecuteAction(address keeper) external view override returns (bool) {
        uint256 requiredMERO = keeperRequireStakedMero;
        return
            requiredMERO == 0 ||
            IERC20(addressProvider.getMEROLocker()).balanceOf(keeper) >= requiredMERO;
    }

    /**
     * @return totalEthRequired the total amount of ETH require by `payer` to cover the fees for
     * @param payer The address of the payer
     * positions registered in all actions
     */
    function getTotalEthRequiredForGas(address payer)
        external
        view
        override
        returns (uint256 totalEthRequired)
    {
        address[] memory actions = addressProvider.allActiveActions();
        uint256 numActions = actions.length;
        for (uint256 i; i < numActions; i = i.uncheckedInc()) {
            totalEthRequired += IAction(actions[i]).getEthRequiredForGas(payer);
        }
    }
}
