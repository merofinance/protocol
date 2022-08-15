// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../actions/topup/TopUpAction.sol";

contract MockTopUpAction is TopUpAction {
    constructor(IController _controller) TopUpAction(_controller) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function setActionFee(uint256 fee) external onlyGovernance {
        actionFee = fee;
    }

    function testingPayFees(
        address payer,
        address keeper,
        uint256 amount,
        address lpToken
    ) external {
        _payFees(payer, keeper, amount, lpToken);
    }
}
