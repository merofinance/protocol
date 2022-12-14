// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "./IRewardsGauge.sol";

interface IAmmGauge is IRewardsGauge {
    event AmmStaked(address indexed account, address indexed token, uint256 amount);
    event AmmUnstaked(address indexed account, address indexed token, uint256 amount);

    function kill() external;

    function stake(uint256 amount) external;

    function unstake(uint256 amount) external;

    function stakeFor(address account, uint256 amount) external;

    function unstakeFor(address dst, uint256 amount) external;

    function poolCheckpoint(uint256 updateEndTime) external returns (bool);

    function poolCheckpoint() external returns (bool);

    function getAmmToken() external view returns (address);

    function isAmmToken(address token) external view returns (bool);

    function claimableRewards(address user) external view returns (uint256);
}
