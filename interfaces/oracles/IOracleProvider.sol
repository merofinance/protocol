// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IOracleProvider {
    /// @notice Checks whether the asset is supported
    /// @param baseAsset the asset of which the price is to be quoted
    /// @return true if the asset is supported
    function isAssetSupported(address baseAsset) external view returns (bool);

    /// @notice Quotes the USD price of `baseAsset`
    /// @param baseAsset the asset of which the price is to be quoted
    /// @return the USD price of the asset
    function getPriceUSD(address baseAsset) external view returns (uint256);

    /// @notice Quotes the ETH price of `baseAsset`
    /// @param baseAsset the asset of which the price is to be quoted
    /// @return the ETH price of the asset
    function getPriceETH(address baseAsset) external view returns (uint256);
}
