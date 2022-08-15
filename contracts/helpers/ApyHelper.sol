// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../libraries/UncheckedMath.sol";
import "../../libraries/ScaledMath.sol";

import "../../interfaces/IVault.sol";
import "../../interfaces/IAddressProvider.sol";
import "../../interfaces/helpers/IApyHelper.sol";
import "../../interfaces/pool/ILiquidityPool.sol";
import "../../interfaces/strategies/IStrategy.sol";

// TODO Add deployment script

contract ApyHelper is IApyHelper {
    using ScaledMath for uint256;
    using UncheckedMath for uint256;

    IAddressProvider internal _addressProvider;

    constructor(address addressProvider_) {
        _addressProvider = IAddressProvider(addressProvider_);
    }

    function exchangeRatesIncludingHarvestable()
        external
        view
        override
        returns (PoolExchangeRate[] memory)
    {
        address[] memory pools_ = _addressProvider.allPools();
        PoolExchangeRate[] memory poolExchangeRates_ = new PoolExchangeRate[](pools_.length);
        for (uint256 i; i < pools_.length; i = i.uncheckedInc()) {
            address pool_ = pools_[i];
            uint256 exchangeRate_ = exchangeRateIncludingHarvestable(pool_);
            poolExchangeRates_[i] = PoolExchangeRate(pool_, exchangeRate_);
        }
        return poolExchangeRates_;
    }

    function exchangeRateIncludingHarvestable(address pool_)
        public
        view
        override
        returns (uint256)
    {
        uint256 totalUnderlying_ = ILiquidityPool(pool_).totalUnderlying();
        if (totalUnderlying_ == 0) return 1e18;
        address lpToken_ = ILiquidityPool(pool_).getLpToken();
        uint256 lpTokenSupply_ = IERC20(lpToken_).totalSupply();
        if (lpTokenSupply_ == 0) return 1e18;
        IVault vault_ = ILiquidityPool(pool_).vault();
        if (address(vault_) == address(0)) return totalUnderlying_.scaledDiv(lpTokenSupply_);
        IStrategy strategy_ = vault_.strategy();
        if (address(strategy_) == address(0)) return totalUnderlying_.scaledDiv(lpTokenSupply_);
        uint256 harvestable_ = strategy_.harvestable();
        return (totalUnderlying_ + harvestable_).scaledDiv(lpTokenSupply_);
    }
}
