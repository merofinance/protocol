// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IStakerVault {
    event Staked(address indexed account, uint256 amount);
    event Unstaked(address indexed account, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function initialize(address _token) external;

    function initializeLpGauge(address _lpGauge) external;

    function stake(uint256 amount) external;

    function stakeFor(address account, uint256 amount) external;

    function unstake(uint256 amount) external;

    function unstakeFor(
        address src,
        address dst,
        uint256 amount
    ) external;

    function approve(address spender, uint256 amount) external;

    function transfer(address account, uint256 amount) external;

    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external;

    function increaseActionLockedBalance(address account, uint256 amount) external;

    function decreaseActionLockedBalance(address account, uint256 amount) external;

    function updateLpGauge(address _lpGauge) external;

    function poolCheckpoint() external returns (bool);

    function poolCheckpoint(uint256 updateEndTime) external returns (bool);

    function allowance(address owner, address spender) external view returns (uint256);

    function getToken() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    function stakedAndActionLockedBalanceOf(address account) external view returns (uint256);

    function actionLockedBalanceOf(address account) external view returns (uint256);

    function getStakedByActions() external view returns (uint256);

    function getPoolTotalStaked() external view returns (uint256);

    function decimals() external view returns (uint8);

    function lpGauge() external view returns (address);
}
