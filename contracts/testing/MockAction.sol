// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../../interfaces/actions/IAction.sol";
import "../actions/BaseAction.sol";
import "../../interfaces/IGasBank.sol";

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract MockAction is BaseAction {
    using EnumerableSet for EnumerableSet.AddressSet;
    mapping(address => uint256) private _totalGasRegistered;

    constructor(IRoleManager roleManager) Authorization(roleManager) {}

    receive() external payable {}

    function failWhenPaused() external notPaused {}

    function failWhenShutdown() external notShutdown {}

    function setEthRequiredForGas(address payer, uint256 amount) external {
        _totalGasRegistered[payer] = amount;
    }

    function withdrawFromGasBank(
        IGasBank bank,
        address account,
        uint256 amount
    ) external {
        bank.withdrawFrom(account, payable(address(this)), amount);
    }

    function getEthRequiredForGas(address payer) external view override returns (uint256) {
        return _totalGasRegistered[payer];
    }

    function updateActionFee(uint256 actionFee_) external pure override {}

    function updateFeeHandler(address feeHandler_) external pure override {}

    function feeHandler() external pure override returns (address) {
        return address(0);
    }
}
