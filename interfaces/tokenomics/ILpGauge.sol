// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface ILpGauge {
    function kill() external;

    function poolCheckpoint() external;

    function poolCheckpoint(uint256 updateEndTime) external;

    function userCheckpoint(address user) external returns (bool);

    function claimableRewards(address beneficiary) external view returns (uint256);

    function killed() external view returns (bool);
}
