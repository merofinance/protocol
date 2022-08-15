// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IAction {
    event UsableTokenAdded(address token);
    event UsableTokenRemoved(address token);
    event Paused();
    event Unpaused();
    event Shutdown();

    function addUsableToken(address token) external;

    function removeUsableToken(address token) external;

    function updateActionFee(uint256 actionFee) external;

    function updateFeeHandler(address feeHandler) external;

    function shutdownAction() external;

    function pause() external;

    function unpause() external;

    function getEthRequiredForGas(address payer) external view returns (uint256);

    function getUsableTokens() external view returns (address[] memory);

    function isUsable(address token) external view returns (bool);

    function feeHandler() external view returns (address);

    function isShutdown() external view returns (bool);

    function isPaused() external view returns (bool);
}
