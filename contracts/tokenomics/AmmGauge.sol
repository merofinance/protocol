// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/IController.sol";
import "../../interfaces/tokenomics/IAmmGauge.sol";

import "../../libraries/ScaledMath.sol";
import "../../libraries/Errors.sol";
import "../../libraries/AddressProviderHelpers.sol";

import "../access/Authorization.sol";

contract AmmGauge is Authorization, IAmmGauge {
    using AddressProviderHelpers for IAddressProvider;
    using ScaledMath for uint256;
    using SafeERC20 for IERC20;

    IAddressProvider public immutable addressProvider;

    mapping(address => uint256) public balances;

    // All the data fields required for the staking tracking
    uint256 public ammStakedIntegral;
    uint256 public totalStaked;
    mapping(address => uint256) public perUserStakedIntegral;
    mapping(address => uint256) public perUserShare;

    address public immutable ammToken;
    bool public killed;
    uint48 public ammLastUpdated;

    event RewardClaimed(address indexed account, uint256 amount);
    event Killed();

    constructor(IAddressProvider _addressProvider, address _ammToken)
        Authorization(_addressProvider.getRoleManager())
    {
        ammToken = _ammToken;
        addressProvider = _addressProvider;
        ammLastUpdated = uint48(block.timestamp);
    }

    /**
     * @notice Shut down the gauge.
     * @dev Accrued inflation can still be claimed from the gauge after shutdown.
     */
    function kill() external override onlyRole(Roles.INFLATION_MANAGER) {
        require(!killed, Error.GAUGE_KILLED);
        poolCheckpoint();
        killed = true;
        emit Killed();
    }

    function claimRewards(address beneficiary) external virtual override returns (uint256) {
        require(
            msg.sender == beneficiary || _roleManager().hasRole(Roles.GAUGE_ZAP, msg.sender),
            Error.UNAUTHORIZED_ACCESS
        );
        _userCheckpoint(beneficiary);
        uint256 amount = perUserShare[beneficiary];
        if (amount == 0) return 0;
        delete perUserShare[beneficiary];
        addressProvider.getInflationManager().mintRewards(beneficiary, amount);
        emit RewardClaimed(beneficiary, amount);
        return amount;
    }

    function poolCheckpoint(uint256 updateEndTime)
        external
        override
        onlyRole(Roles.INFLATION_MANAGER)
        returns (bool)
    {
        if (killed) return false;
        // Update the integral of total token supply for the pool
        uint256 timeElapsed = updateEndTime - uint256(ammLastUpdated);
        _poolCheckpoint(timeElapsed);
        ammLastUpdated = uint48(updateEndTime);
        return true;
    }

    function stake(uint256 amount) external virtual override {
        stakeFor(msg.sender, amount);
    }

    function unstake(uint256 amount) external virtual override {
        unstakeFor(msg.sender, amount);
    }

    function getAmmToken() external view override returns (address) {
        return ammToken;
    }

    function isAmmToken(address token) external view override returns (bool) {
        return token == ammToken;
    }

    function claimableRewards(address user) external view virtual override returns (uint256) {
        uint256 ammStakedIntegral_ = ammStakedIntegral;
        if (!killed && totalStaked > 0) {
            ammStakedIntegral_ += (addressProvider.getInflationManager().getAmmRateForToken(
                ammToken
            ) * (block.timestamp - uint256(ammLastUpdated))).scaledDiv(totalStaked);
        }
        return
            perUserShare[user] +
            balances[user].scaledMul(ammStakedIntegral_ - perUserStakedIntegral[user]);
    }

    /**
     * @notice Stake amount of AMM token on behalf of another account.
     * @param account Account for which tokens will be staked.
     * @param amount Amount of token to stake.
     */
    function stakeFor(address account, uint256 amount) public virtual override {
        require(!killed, Error.GAUGE_KILLED);
        require(account != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        require(amount > 0, Error.INVALID_AMOUNT);

        _userCheckpoint(account);

        IERC20(ammToken).safeTransferFrom(msg.sender, address(this), amount);
        balances[account] += amount;
        totalStaked += amount;
        emit AmmStaked(account, ammToken, amount);
    }

    /**
     * @notice Unstake amount of AMM token and send to another account.
     * @param dst Account to which unstaked AMM tokens will be sent.
     * @param amount Amount of token to unstake.
     */
    function unstakeFor(address dst, uint256 amount) public virtual override {
        require(dst != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        require(dst != address(this), Error.SAME_ADDRESS_NOT_ALLOWED);
        require(amount > 0, Error.INVALID_AMOUNT);
        require(balances[msg.sender] >= amount, Error.INSUFFICIENT_BALANCE);

        _userCheckpoint(msg.sender);

        IERC20(ammToken).safeTransfer(dst, amount);
        balances[msg.sender] -= amount;
        totalStaked -= amount;
        emit AmmUnstaked(msg.sender, ammToken, amount);
    }

    function poolCheckpoint() public virtual override returns (bool) {
        if (killed) return false;
        addressProvider.getInflationManager().checkPointInflation();
        // Update the integral of total token supply for the pool
        uint256 timeElapsed = block.timestamp - uint256(ammLastUpdated);
        _poolCheckpoint(timeElapsed);
        ammLastUpdated = uint48(block.timestamp);
        return true;
    }

    function _poolCheckpoint(uint256 timeElapsed) internal {
        uint256 currentRate = addressProvider.getInflationManager().getAmmRateForToken(ammToken);
        if (totalStaked > 0) {
            ammStakedIntegral += (currentRate * timeElapsed).scaledDiv(totalStaked);
        }
    }

    function _userCheckpoint(address user) internal virtual {
        poolCheckpoint();
        perUserShare[user] += balances[user].scaledMul(
            ammStakedIntegral - perUserStakedIntegral[user]
        );
        perUserStakedIntegral[user] = ammStakedIntegral;
    }
}
