// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../../interfaces/IStakerVault.sol";
import "../../interfaces/tokenomics/IInflationManager.sol";
import "../../interfaces/tokenomics/IKeeperGauge.sol";
import "../../interfaces/tokenomics/IAmmGauge.sol";
import "../../interfaces/pool/ILiquidityPool.sol";
import "../../interfaces/actions/IAction.sol";
import "../../interfaces/actions/IActionFeeHandler.sol";

import "../../libraries/EnumerableMapping.sol";
import "../../libraries/EnumerableExtensions.sol";
import "../../libraries/AddressProviderHelpers.sol";
import "../../libraries/UncheckedMath.sol";

import "./Minter.sol";
import "../access/Authorization.sol";

contract InflationManager is Authorization, IInflationManager {
    using UncheckedMath for uint256;
    using EnumerableMapping for EnumerableMapping.AddressToAddressMap;
    using EnumerableExtensions for EnumerableMapping.AddressToAddressMap;
    using AddressProviderHelpers for IAddressProvider;

    IAddressProvider public immutable addressProvider;

    mapping(address => uint256) public override keeperPoolWeights;
    mapping(address => uint256) public override lpPoolWeights;
    mapping(address => uint256) public override ammWeights;

    address public override minter;
    bool public override weightBasedKeeperDistributionDeactivated;
    uint256 public override totalKeeperPoolWeight;
    uint256 public override totalLpPoolWeight;
    uint256 public override totalAmmTokenWeight;

    // Pool -> keeperGauge
    EnumerableMapping.AddressToAddressMap private _keeperGauges;
    // AMM token -> ammGauge
    EnumerableMapping.AddressToAddressMap private _ammGauges;

    mapping(address => bool) public override gauges;

    event NewKeeperWeight(address indexed pool, uint256 newWeight);
    event NewLpWeight(address indexed pool, uint256 newWeight);
    event NewAmmTokenWeight(address indexed token, uint256 newWeight);
    event WeightBasedKeeperDistributionDeactivated();

    modifier onlyGauge() {
        require(gauges[msg.sender], Error.UNAUTHORIZED_ACCESS);
        _;
    }

    constructor(IAddressProvider _addressProvider)
        Authorization(_addressProvider.getRoleManager())
    {
        addressProvider = _addressProvider;
    }

    function setMinter(address _minter) external override onlyGovernance {
        require(minter == address(0), Error.ADDRESS_ALREADY_SET);
        require(_minter != address(0), Error.INVALID_MINTER);
        minter = _minter;
    }

    /**
     * @notice Advance the keeper gauge for a pool by an epoch.
     * @param pool Pool for which the keeper gauge is advanced.
     */
    function advanceKeeperGaugeEpoch(address pool) external override onlyGovernance {
        IKeeperGauge(_keeperGauges.get(pool)).advanceEpoch();
    }

    /**
     * @notice Mints MERO tokens.
     * @param beneficiary Address to receive the tokens.
     * @param amount Amount of tokens to mint.
     */
    function mintRewards(address beneficiary, uint256 amount) external override onlyGauge {
        Minter(minter).mint(beneficiary, amount);
    }

    function checkPointInflation() external override {
        Minter(minter).executeInflationRateUpdate();
    }

    /**
     * @notice Deactivates the weight-based distribution of keeper inflation.
     * @dev This can only be done once, when the keeper inflation mechanism is altered.
     */
    function deactivateWeightBasedKeeperDistribution() external override onlyGovernance {
        require(!weightBasedKeeperDistributionDeactivated, "Weight-based dist. deactivated.");
        address[] memory liquidityPools = addressProvider.allPools();
        uint256 length = liquidityPools.length;
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            _removeKeeperGauge(address(liquidityPools[i]));
        }
        weightBasedKeeperDistributionDeactivated = true;
        emit WeightBasedKeeperDistributionDeactivated();
    }

    /**
     * @notice Checkpoints all gauges.
     * @param updateEndTime is the time until which to update the gauges.
     * @dev This is mostly used upon inflation rate updates.
     */
    function checkpointAllGauges(uint256 updateEndTime) external override {
        require(msg.sender == minter, Error.UNAUTHORIZED_ACCESS);
        uint256 length = _keeperGauges.length();
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            IKeeperGauge(_keeperGauges.valueAt(i)).poolCheckpoint(updateEndTime);
        }
        address[] memory stakerVaults = addressProvider.allStakerVaults();
        for (uint256 i; i < stakerVaults.length; i = i.uncheckedInc()) {
            IStakerVault(stakerVaults[i]).poolCheckpoint(updateEndTime);
        }

        length = _ammGauges.length();
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            IAmmGauge(_ammGauges.valueAt(i)).poolCheckpoint(updateEndTime);
        }
    }

    /**
     * @notice Update a keeper pool weight.
     * @param pool_ Pool to update the keeper weight for.
     * @param weight_ New weight for the keeper inflation for the pool.
     */
    function updateKeeperPoolWeight(address pool_, uint256 weight_)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.INFLATION_ADMIN)
    {
        require(_keeperGauges.contains(pool_), Error.INVALID_ARGUMENT);
        _executeKeeperPoolWeight(pool_, weight_);
    }

    /**
     * @notice Update of a batch of keeperGauge weights.
     * @dev Each entry in the pools array corresponds to an entry in the weights array.
     * @param pools Pools to update the keeper weight for.
     * @param weights New weights for the keeper inflation for the pools.
     */
    function batchUpdateKeeperPoolWeights(address[] calldata pools, uint256[] calldata weights)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.INFLATION_ADMIN)
    {
        require(pools.length == weights.length, Error.INVALID_ARGUMENT);
        for (uint256 i; i < pools.length; i = i.uncheckedInc()) {
            require(_keeperGauges.contains(pools[i]), Error.INVALID_ARGUMENT);
            _executeKeeperPoolWeight(pools[i], weights[i]);
        }
    }

    function whitelistGauge(address gauge) external override onlyRole(Roles.CONTROLLER) {
        gauges[gauge] = true;
    }

    function removeStakerVaultFromInflation(address lpToken)
        external
        override
        onlyRole(Roles.CONTROLLER)
    {
        _executeLpPoolWeight(lpToken, 0);
    }

    /**
     * @notice Update a lp pool weight.
     * @param lpToken_ LP token to update the weight for.
     * @param weight_ New LP inflation weight.
     */
    function updateLpPoolWeight(address lpToken_, uint256 weight_)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.INFLATION_ADMIN)
    {
        address stakerVault_ = addressProvider.getStakerVault(lpToken_);
        // Require both that gauge is registered and that pool is still in action
        require(gauges[IStakerVault(stakerVault_).lpGauge()], Error.GAUGE_DOES_NOT_EXIST);
        require(IStakerVault(stakerVault_).lpGauge() != address(0), Error.ADDRESS_NOT_FOUND);
        _ensurePoolExists(lpToken_);

        _executeLpPoolWeight(lpToken_, weight_);
    }

    /**
     * @notice Update a batch of LP token weights.
     * @dev Each entry in the lpTokens array corresponds to an entry in the weights array.
     * @param lpTokens_ LpTokens to update the inflation weight for.
     * @param weights_ New weights for the inflation for the LpTokens.
     */
    function batchUpdateLpPoolWeights(address[] calldata lpTokens_, uint256[] calldata weights_)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.INFLATION_ADMIN)
    {
        require(lpTokens_.length == weights_.length, "Invalid length of arguments");
        for (uint256 i; i < lpTokens_.length; i = i.uncheckedInc()) {
            address stakerVault_ = addressProvider.getStakerVault(lpTokens_[i]);
            // Require both that gauge is registered and that pool is still in action
            require(IStakerVault(stakerVault_).lpGauge() != address(0), Error.ADDRESS_NOT_FOUND);
            _ensurePoolExists(lpTokens_[i]);
            _executeLpPoolWeight(lpTokens_[i], weights_[i]);
        }
    }

    /**
     * @notice Update inflation weight for an AMM token.
     * @param token_ AMM token to update the weight for.
     * @param weight_ New AMM token inflation weight.
     */
    function updateAmmTokenWeight(address token_, uint256 weight_)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.INFLATION_ADMIN)
    {
        require(_ammGauges.contains(token_), "amm gauge not found");
        _executeAmmTokenWeight(token_, weight_);
    }

    /**
     * @notice Update a batch of AMM token weights.
     * @dev Each entry in the tokens array corresponds to an entry in the weights array.
     * @param tokens_ AMM tokens to update the inflation weight for.
     * @param weights_ New weights for the inflation for the AMM tokens.
     */
    function batchUpdateAmmTokenWeights(address[] calldata tokens_, uint256[] calldata weights_)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.INFLATION_ADMIN)
    {
        require(tokens_.length == weights_.length, "Invalid length of arguments");
        for (uint256 i; i < tokens_.length; i = i.uncheckedInc()) {
            require(_ammGauges.contains(tokens_[i]), "amm gauge not found");
            _executeAmmTokenWeight(tokens_[i], weights_[i]);
        }
    }

    /**
     * @notice Sets the KeeperGauge for a pool.
     * @dev Multiple pools can have the same KeeperGauge.
     * @param pool Address of pool to set the KeeperGauge for.
     * @param _keeperGauge Address of KeeperGauge.
     * @return `true` if successful.
     */
    function setKeeperGauge(address pool, address _keeperGauge)
        external
        override
        onlyGovernance
        returns (bool)
    {
        uint256 length = _keeperGauges.length();
        bool keeperGaugeExists = false;
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            if (address(_keeperGauges.valueAt(i)) == _keeperGauge) {
                keeperGaugeExists = true;
                break;
            }
        }
        // Check to make sure that once weight-based dist is deactivated, only one gauge can exist
        if (!keeperGaugeExists && weightBasedKeeperDistributionDeactivated && length >= 1) {
            return false;
        }
        (bool exists, address keeperGauge) = _keeperGauges.tryGet(pool);
        require(!exists || keeperGauge != _keeperGauge, Error.INVALID_ARGUMENT);

        if (exists && !IKeeperGauge(keeperGauge).killed()) {
            IKeeperGauge(keeperGauge).kill();
        }
        _keeperGauges.set(pool, _keeperGauge);
        gauges[_keeperGauge] = true;
        return true;
    }

    function removeKeeperGauge(address pool) external override onlyGovernance {
        _removeKeeperGauge(pool);
    }

    /**
     * @notice Sets the AmmGauge for a particular AMM token.
     * @param token Address of the amm token.
     * @param _ammGauge Address of AmmGauge.
     * @return `true` if successful.
     */
    function setAmmGauge(address token, address _ammGauge)
        external
        override
        onlyGovernance
        returns (bool)
    {
        require(IAmmGauge(_ammGauge).isAmmToken(token), Error.ADDRESS_NOT_WHITELISTED);
        uint256 length = _ammGauges.length();
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            if (address(_ammGauges.valueAt(i)) == _ammGauge) {
                return false;
            }
        }
        if (_ammGauges.contains(token)) {
            address ammGauge = _ammGauges.get(token);
            IAmmGauge(ammGauge).kill();
        }
        _ammGauges.set(token, _ammGauge);
        gauges[_ammGauge] = true;
        return true;
    }

    function removeAmmGauge(address token_) external override onlyGovernance returns (bool) {
        if (!_ammGauges.contains(token_)) return false;
        address ammGauge_ = _ammGauges.get(token_);
        _executeAmmTokenWeight(token_, 0);
        IAmmGauge(ammGauge_).kill();
        _ammGauges.remove(token_);
        // Do not delete from the gauges map to allow claiming of remaining balances
        emit AmmGaugeDelisted(token_, ammGauge_);
        return true;
    }

    function addGaugeForVault(address lpToken) external override {
        IStakerVault _stakerVault = IStakerVault(msg.sender);
        require(addressProvider.isStakerVault(msg.sender, lpToken), Error.UNAUTHORIZED_ACCESS);
        address lpGauge = _stakerVault.lpGauge();
        require(lpGauge != address(0), Error.GAUGE_DOES_NOT_EXIST);
        gauges[lpGauge] = true;
    }

    function getAllAmmGauges() external view override returns (address[] memory) {
        return _ammGauges.valuesArray();
    }

    function getLpRateForStakerVault(address stakerVault) external view override returns (uint256) {
        uint256 totalLpPoolWeight_ = totalLpPoolWeight;
        address minter_ = minter;
        if (minter_ == address(0) || totalLpPoolWeight_ == 0) return 0;
        uint256 lpInflationRate_ = Minter(minter_).getLpInflationRate();
        address lpToken_ = IStakerVault(stakerVault).getToken();
        return (lpPoolWeights[lpToken_] * lpInflationRate_) / totalLpPoolWeight_;
    }

    function getKeeperRateForPool(address pool) external view override returns (uint256) {
        if (minter == address(0)) {
            return 0;
        }
        uint256 keeperInflationRate = Minter(minter).getKeeperInflationRate();
        // After deactivation of weight based dist, KeeperGauge handles the splitting
        if (weightBasedKeeperDistributionDeactivated) return keeperInflationRate;
        if (totalKeeperPoolWeight == 0) return 0;
        uint256 poolInflationRate = (keeperPoolWeights[pool] * keeperInflationRate) /
            totalKeeperPoolWeight;
        return poolInflationRate;
    }

    function getAmmRateForToken(address token_) external view override returns (uint256) {
        if (minter == address(0) || totalAmmTokenWeight == 0) {
            return 0;
        }
        uint256 ammInflationRate = Minter(minter).getAmmInflationRate();
        uint256 ammTokenInflationRate = (ammWeights[token_] * ammInflationRate) /
            totalAmmTokenWeight;
        return ammTokenInflationRate;
    }

    function getLpPoolWeight(address lpToken) external view override returns (uint256) {
        return lpPoolWeights[lpToken];
    }

    function getKeeperGaugeForPool(address pool) external view override returns (address) {
        (, address keeperGauge) = _keeperGauges.tryGet(pool);
        return keeperGauge;
    }

    function getAmmGaugeForToken(address token) external view override returns (address) {
        (, address ammGauge) = _ammGauges.tryGet(token);
        return ammGauge;
    }

    function _executeKeeperPoolWeight(address pool_, uint256 weight_) internal {
        uint256 length = _keeperGauges.length();
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            IKeeperGauge(_keeperGauges.valueAt(i)).poolCheckpoint();
        }
        totalKeeperPoolWeight = totalKeeperPoolWeight - keeperPoolWeights[pool_] + weight_;
        keeperPoolWeights[pool_] = weight_;
        emit NewKeeperWeight(pool_, weight_);
    }

    function _executeLpPoolWeight(address lpToken_, uint256 weight_) internal {
        address[] memory stakerVaults = addressProvider.allStakerVaults();
        for (uint256 i; i < stakerVaults.length; i = i.uncheckedInc()) {
            IStakerVault(stakerVaults[i]).poolCheckpoint();
        }
        totalLpPoolWeight = totalLpPoolWeight - lpPoolWeights[lpToken_] + weight_;
        lpPoolWeights[lpToken_] = weight_;
        emit NewLpWeight(lpToken_, weight_);
    }

    function _executeAmmTokenWeight(address token_, uint256 weight_) internal {
        uint256 length = _ammGauges.length();
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            IAmmGauge(_ammGauges.valueAt(i)).poolCheckpoint();
        }
        totalAmmTokenWeight = totalAmmTokenWeight - ammWeights[token_] + weight_;
        ammWeights[token_] = weight_;
        emit NewAmmTokenWeight(token_, weight_);
    }

    function _removeKeeperGauge(address pool) internal {
        if (!_keeperGauges.contains(pool)) return;
        address keeperGauge = _keeperGauges.get(pool);

        // Checking if the Keeper Gauge is still in use
        address[] memory pools_ = addressProvider.allPools();
        address[] memory actions_ = addressProvider.allActions();
        for (uint256 i; i < pools_.length; i = i.uncheckedInc()) {
            ILiquidityPool pool_ = ILiquidityPool(pools_[i]);
            address lpToken_ = pool_.getLpToken();
            for (uint256 j; j < actions_.length; j = j.uncheckedInc()) {
                IAction action_ = IAction(actions_[j]);
                IActionFeeHandler feeHandler_ = IActionFeeHandler(action_.feeHandler());
                address keeperGauge_ = feeHandler_.getKeeperGauge(lpToken_);
                require(keeperGauge_ != keeperGauge, Error.GAUGE_STILL_ACTIVE);
            }
        }

        _executeKeeperPoolWeight(pool, 0);
        _keeperGauges.remove(pool);
        IKeeperGauge(keeperGauge).kill();
        // Do not delete from the gauges map to allow claiming of remaining balances
        emit KeeperGaugeDelisted(pool, keeperGauge);
    }

    function _ensurePoolExists(address lpToken) internal view {
        address pool = addressProvider.safeGetPoolForToken(lpToken);
        require(pool != address(0), Error.ADDRESS_NOT_FOUND);
        require(!ILiquidityPool(pool).isShutdown(), Error.POOL_SHUTDOWN);
    }
}
