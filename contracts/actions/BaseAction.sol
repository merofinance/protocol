// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../access/Authorization.sol";

import "../../interfaces/actions/IAction.sol";

abstract contract BaseAction is IAction, Authorization {
    using EnumerableSet for EnumerableSet.AddressSet;

    bool internal _shutdown;
    bool internal _paused;

    EnumerableSet.AddressSet internal _usableTokens;

    modifier notShutdown() {
        require(!_shutdown, Error.ACTION_SHUTDOWN);
        _;
    }

    modifier notPaused() {
        require(!_paused, Error.ACTION_PAUSED);
        _;
    }

    /**
     * @notice Add a new deposit token that is supported by the action.
     * @dev There is a separate check for whether the usable token (i.e. deposit token)
     *      is swappable for some action token.
     * @param token Address of deposit token that can be used by the action.
     */
    function addUsableToken(address token) external override onlyGovernance {
        _usableTokens.add(token);
        emit UsableTokenAdded(token);
    }

    /**
     * @notice Add a new deposit token that is supported by the action.
     * @dev There is a separate check for whether the usable token (i.e. deposit token)
     *      is swappable for some action token.
     * @param token Address of deposit token that can be used by the action.
     */
    function removeUsableToken(address token) external override onlyGovernance {
        _usableTokens.remove(token);
        emit UsableTokenRemoved(token);
    }

    /**
     * @notice Shutdowns the action. This is irreversible
     */
    function shutdownAction() external virtual onlyRole(Roles.CONTROLLER) {
        _shutdown = true;
        emit Shutdown();
    }

    /**
     * @notice Pauses the action
     */
    function pause() external virtual onlyGovernance {
        _paused = true;
        emit Paused();
    }

    /**
     * @notice Pauses the action
     */
    function unpause() external virtual onlyGovernance {
        _paused = false;
        emit Unpaused();
    }

    /**
     * @notice Get a list of all tokens usable for this action.
     * @dev This refers to all tokens that can be used as deposit tokens.
     * @return Array of addresses of usable tokens.
     */
    function getUsableTokens() external view override returns (address[] memory) {
        return _usableTokens.values();
    }

    /**
     * @return true if the action is shutdown
     */
    function isShutdown() external view returns (bool) {
        return _shutdown;
    }

    /**
     * @return true if the action is paused
     */
    function isPaused() external view returns (bool) {
        return _paused;
    }

    /**
     * @notice Check whether a token is usable as a deposit token.
     * @param token Address of token to check.
     * @return True if token is usable as a deposit token for this action.
     */
    function isUsable(address token) public view override returns (bool) {
        return _usableTokens.contains(token);
    }
}
