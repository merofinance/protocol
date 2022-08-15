// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../pool/EthPool.sol";

contract MockEthPool is EthPool {
    uint256 public currentTime;

    constructor(IController _controller) EthPool(_controller) {}

    function setMinWithdrawalFee(uint256 newFee) external onlyGovernance returns (bool) {
        minWithdrawalFee = newFee;
        _checkFeeInvariants(newFee, maxWithdrawalFee);
        return true;
    }

    function setMaxWithdrawalFee(uint256 newFee) external onlyGovernance returns (bool) {
        maxWithdrawalFee = newFee;
        _checkFeeInvariants(minWithdrawalFee, newFee);
        return true;
    }

    function setWithdrawalFeeDecreasePeriod(uint256 period) external onlyGovernance returns (bool) {
        withdrawalFeeDecreasePeriod = period;
        return true;
    }

    function setVault(address payable _vault) external {
        setVault(_vault, true);
    }

    function setMaxBackingReserveDeviationRatio(uint256 newRatio) external onlyGovernance {
        reserveDeviation = newRatio;
        _rebalanceVault();
    }

    function setRequiredBackingReserveRatio(uint256 newRatio) external onlyGovernance {
        requiredReserves = newRatio;
        _rebalanceVault();
    }

    function setTime(uint256 _currentTime) external {
        currentTime = _currentTime;
    }

    function setVault(address payable vault_, bool updateAddressProvider) public onlyGovernance {
        if (updateAddressProvider) {
            addressProvider.updateVault(address(vault), vault_);
        }
        vault = IVault(vault_);
    }

    function _getTime() internal view override returns (uint256) {
        return currentTime == 0 ? block.timestamp : currentTime;
    }
}
