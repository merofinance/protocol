// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "../../interfaces/IStakerVault.sol";
import "../../interfaces/IController.sol";
import "../../interfaces/tokenomics/ILpGauge.sol";
import "../../interfaces/tokenomics/IRewardsGauge.sol";

import "../../libraries/ScaledMath.sol";
import "../../libraries/Errors.sol";
import "../../libraries/AddressProviderHelpers.sol";

import "../access/Authorization.sol";

contract LpGauge is ILpGauge, IRewardsGauge, Authorization {
    using AddressProviderHelpers for IAddressProvider;
    using ScaledMath for uint256;

    IAddressProvider public immutable addressProvider;
    IStakerVault public immutable stakerVault;
    IInflationManager public immutable inflationManager;

    bool public override killed;
    uint256 public poolStakedIntegral;
    uint256 public poolLastUpdate;
    mapping(address => uint256) public perUserStakedIntegral;
    mapping(address => uint256) public perUserShare;

    event Killed();

    constructor(IAddressProvider _addressProvider, address _stakerVault)
        Authorization(_addressProvider.getRoleManager())
    {
        require(_stakerVault != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        addressProvider = _addressProvider;
        stakerVault = IStakerVault(_stakerVault);
        IInflationManager _inflationManager = _addressProvider.getInflationManager();
        require(address(_inflationManager) != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        inflationManager = _inflationManager;
        poolLastUpdate = block.timestamp;
    }

    /**
     * @notice Checkpoint function for the pool statistics.
     */
    function kill() external override {
        require(!killed, Error.GAUGE_KILLED);
        require(msg.sender == address(stakerVault), Error.UNAUTHORIZED_ACCESS);
        poolCheckpoint();
        killed = true;
        emit Killed();
    }

    /**
     * @notice Calculates the token rewards a user should receive and mints these.
     * @param beneficiary Address to claim rewards for.
     * @return `true` if success.
     */
    function claimRewards(address beneficiary) external override returns (uint256) {
        require(
            msg.sender == beneficiary || _roleManager().hasRole(Roles.GAUGE_ZAP, msg.sender),
            Error.UNAUTHORIZED_ACCESS
        );
        userCheckpoint(beneficiary);
        uint256 amount = perUserShare[beneficiary];
        if (amount == 0) return 0;
        delete perUserShare[beneficiary];
        _mintRewards(beneficiary, amount);
        return amount;
    }

    /**
     * @notice Checkpoint function for the pool statistics.
     */
    function poolCheckpoint(uint256 updateEndTime) external override {
        require(msg.sender == address(stakerVault), Error.UNAUTHORIZED_ACCESS);
        uint256 elapsedTime = updateEndTime - poolLastUpdate;
        _poolCheckpoint(elapsedTime);
        poolLastUpdate = updateEndTime;
    }

    function claimableRewards(address beneficiary) external view override returns (uint256) {
        uint256 poolTotalStaked = stakerVault.getPoolTotalStaked();
        uint256 poolStakedIntegral_ = poolStakedIntegral;
        if (!killed && poolTotalStaked > 0) {
            poolStakedIntegral_ += (inflationManager.getLpRateForStakerVault(address(stakerVault)) *
                (block.timestamp - poolLastUpdate)).scaledDiv(poolTotalStaked);
        }

        return
            perUserShare[beneficiary] +
            stakerVault.stakedAndActionLockedBalanceOf(beneficiary).scaledMul(
                poolStakedIntegral_ - perUserStakedIntegral[beneficiary]
            );
    }

    /**
     * @notice Checkpoint function for the pool statistics.
     */
    function poolCheckpoint() public override {
        inflationManager.checkPointInflation();
        uint256 elapsedTime = block.timestamp - poolLastUpdate;
        _poolCheckpoint(elapsedTime);
        poolLastUpdate = block.timestamp;
    }

    /**
     * @notice Checkpoint function for the statistics for a particular user.
     * @param user Address of the user to checkpoint.
     * @return `true` if successful.
     */
    function userCheckpoint(address user) public override returns (bool) {
        poolCheckpoint();

        // No checkpoint for the actions, since this does not accumulate tokens
        if (addressProvider.isAction(user)) {
            return false;
        }
        uint256 poolStakedIntegral_ = poolStakedIntegral;
        perUserShare[user] += (
            (stakerVault.stakedAndActionLockedBalanceOf(user)).scaledMul(
                (poolStakedIntegral_ - perUserStakedIntegral[user])
            )
        );

        perUserStakedIntegral[user] = poolStakedIntegral_;

        return true;
    }

    function _mintRewards(address beneficiary, uint256 amount) internal {
        inflationManager.mintRewards(beneficiary, amount);
    }

    function _poolCheckpoint(uint256 elapsedTime) internal {
        if (killed) return;
        uint256 currentRate = inflationManager.getLpRateForStakerVault(address(stakerVault));
        // Update the integral of total token supply for the pool
        uint256 poolTotalStaked = stakerVault.getPoolTotalStaked();
        if (poolTotalStaked > 0) {
            poolStakedIntegral += (currentRate * (elapsedTime)).scaledDiv(poolTotalStaked);
        }
    }
}
