// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IInflationManager {
    event KeeperGaugeListed(address indexed pool, address indexed keeperGauge);
    event AmmGaugeListed(address indexed token, address indexed ammGauge);
    event KeeperGaugeDelisted(address indexed pool, address indexed keeperGauge);
    event AmmGaugeDelisted(address indexed token, address indexed ammGauge);

    /** Pool functions */

    function setKeeperGauge(address pool, address _keeperGauge) external returns (bool);

    function setAmmGauge(address token, address _ammGauge) external returns (bool);

    function setMinter(address _minter) external;

    function advanceKeeperGaugeEpoch(address pool) external;

    function whitelistGauge(address gauge) external;

    function removeStakerVaultFromInflation(address lpToken) external;

    function removeAmmGauge(address token) external returns (bool);

    function addGaugeForVault(address lpToken) external;

    function checkpointAllGauges(uint256 updateEndTime) external;

    function mintRewards(address beneficiary, uint256 amount) external;

    function checkPointInflation() external;

    function removeKeeperGauge(address pool) external;

    function getAllAmmGauges() external view returns (address[] memory);

    function getLpRateForStakerVault(address stakerVault) external view returns (uint256);

    function getKeeperRateForPool(address pool) external view returns (uint256);

    function getAmmRateForToken(address token) external view returns (uint256);

    function getLpPoolWeight(address pool) external view returns (uint256);

    function getKeeperGaugeForPool(address pool) external view returns (address);

    function getAmmGaugeForToken(address token) external view returns (address);

    function gauges(address lpToken) external view returns (bool);

    function ammWeights(address gauge) external view returns (uint256);

    function lpPoolWeights(address gauge) external view returns (uint256);

    function keeperPoolWeights(address gauge) external view returns (uint256);

    function minter() external view returns (address);

    function weightBasedKeeperDistributionDeactivated() external view returns (bool);

    function totalKeeperPoolWeight() external view returns (uint256);

    function totalLpPoolWeight() external view returns (uint256);

    function totalAmmTokenWeight() external view returns (uint256);

    /** Weight setter functions **/

    function updateLpPoolWeight(address lpToken, uint256 newPoolWeight) external;

    function updateAmmTokenWeight(address token, uint256 newTokenWeight) external;

    function updateKeeperPoolWeight(address pool, uint256 newPoolWeight) external;

    function batchUpdateLpPoolWeights(address[] calldata lpTokens, uint256[] calldata weights)
        external;

    function batchUpdateAmmTokenWeights(address[] calldata tokens, uint256[] calldata weights)
        external;

    function batchUpdateKeeperPoolWeights(address[] calldata pools, uint256[] calldata weights)
        external;

    function deactivateWeightBasedKeeperDistribution() external;
}
