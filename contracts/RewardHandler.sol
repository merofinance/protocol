// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IFeeBurner.sol";
import "../interfaces/IMeroLocker.sol";
import "../interfaces/IController.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/IRewardHandler.sol";
import "./access/Authorization.sol";
import "../libraries/AddressProviderHelpers.sol";
import "../libraries/UncheckedMath.sol";

contract RewardHandler is IRewardHandler, Authorization {
    using UncheckedMath for uint256;
    using SafeERC20 for IERC20;
    using AddressProviderHelpers for IAddressProvider;

    IController public immutable controller;
    IAddressProvider public immutable addressProvider;

    constructor(IController _controller)
        Authorization(_controller.addressProvider().getRoleManager())
    {
        controller = _controller;
        addressProvider = IAddressProvider(controller.addressProvider());
    }

    receive() external payable {}

    /**
     * @notice Burns all accumulated fees and pays these out to the MERO locker.
     */
    function burnFees() external override {
        IMeroLocker meroLocker = IMeroLocker(addressProvider.getMEROLocker());
        IFeeBurner feeBurner = addressProvider.getFeeBurner();
        address targetLpToken = meroLocker.rewardToken();
        address[] memory pools = addressProvider.allPools();
        address[] memory tokens = new address[](pools.length);

        uint256 ethValue = 0;
        for (uint256 i; i < pools.length; i = i.uncheckedInc()) {
            ILiquidityPool pool = ILiquidityPool(pools[i]);
            address underlying = pool.getUnderlying();
            if (underlying != address(0)) {
                _approve(underlying, address(feeBurner));
            } else {
                ethValue = address(this).balance;
            }
            tokens[i] = underlying;
        }

        feeBurner.burnToTarget{value: ethValue}(tokens, targetLpToken);
        uint256 burnedAmount = IERC20(targetLpToken).balanceOf(address(this));
        _approve(targetLpToken, address(meroLocker));
        meroLocker.depositFees(burnedAmount);
        emit Burned(targetLpToken, burnedAmount);
    }

    /**
     * @dev Approves infinite spending for the given spender.
     * @param token The token to approve for.
     * @param spender The spender to approve.
     */
    function _approve(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) > 0) return;
        IERC20(token).safeApprove(spender, type(uint256).max);
    }
}
