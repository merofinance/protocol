// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IApyHelper {
    struct PoolExchangeRate {
        address pool;
        uint256 exchangeRate;
    }

    function exchangeRatesIncludingHarvestable() external view returns (PoolExchangeRate[] memory);

    function exchangeRateIncludingHarvestable(address pool_) external view returns (uint256);
}
