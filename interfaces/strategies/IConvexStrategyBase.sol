// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "./IStrategy.sol";

interface IConvexStrategyBase is IStrategy {
    function setCrvCommunityReserveShare(uint256 crvCommunityReserveShare_) external;

    function setCvxCommunityReserveShare(uint256 cvxCommunityReserveShare_) external;

    function setImbalanceToleranceIn(uint256 imbalanceToleranceIn_) external;

    function setImbalanceToleranceOut(uint256 imbalanceToleranceOut_) external;

    function addRewardToken(address token_) external returns (bool);

    function removeRewardToken(address token_) external returns (bool);

    function rewardTokens() external view returns (address[] memory);
}
