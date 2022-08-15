// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "./strategies/IStrategy.sol";

/**
 * @title Interface for a Vault
 */

interface IVault {
    event StrategyActivated(address indexed strategy);

    event StrategyDeactivated(address indexed strategy);

    /**
     * @dev 'netProfit' is the profit after all fees have been deducted
     */
    event Harvest(uint256 indexed netProfit, uint256 indexed loss);

    function initialize(
        address _pool,
        uint256 _debtLimit,
        uint256 _targetAllocation,
        uint256 _bound
    ) external;

    function withdrawFromStrategyWaitingForRemoval(address strategy) external returns (uint256);

    function deposit() external payable;

    function withdraw(uint256 amount) external returns (bool);

    function withdrawAvailableToPool() external;

    function initializeStrategy(address strategy_) external;

    function shutdownStrategy() external;

    function withdrawFromReserve(uint256 amount) external;

    function updateStrategy(address newStrategy) external;

    function activateStrategy() external returns (bool);

    function deactivateStrategy() external returns (bool);

    function updatePerformanceFee(uint256 newPerformanceFee) external;

    function updateStrategistFee(uint256 newStrategistFee) external;

    function updateDebtLimit(uint256 newDebtLimit) external;

    function updateTargetAllocation(uint256 newTargetAllocation) external;

    function updateReserveFee(uint256 newReserveFee) external;

    function updateBound(uint256 newBound) external;

    function withdrawFromStrategy(uint256 amount) external returns (bool);

    function withdrawAllFromStrategy() external returns (bool);

    function harvest() external returns (bool);

    function getStrategiesWaitingForRemoval() external view returns (address[] memory);

    function getAllocatedToStrategyWaitingForRemoval(address strategy)
        external
        view
        returns (uint256);

    function getTotalUnderlying() external view returns (uint256);

    function getUnderlying() external view returns (address);

    function strategy() external view returns (IStrategy);
}
