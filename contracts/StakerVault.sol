// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "../libraries/ScaledMath.sol";
import "../libraries/Errors.sol";
import "../libraries/AddressProviderHelpers.sol";
import "../libraries/UncheckedMath.sol";

import "../interfaces/IStakerVault.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/IVault.sol";
import "../interfaces/tokenomics/IRewardsGauge.sol";
import "../interfaces/pool/ILiquidityPool.sol";
import "../interfaces/tokenomics/ILpGauge.sol";
import "../interfaces/IERC20Full.sol";

import "./Controller.sol";
import "./pool/LiquidityPool.sol";
import "./access/Authorization.sol";
import "./utils/Pausable.sol";

/**
 * @notice This contract handles staked tokens from Mero pools
 * However, note that this is NOT an ERC-20 compliant contract and these
 * tokens should never be integrated with any protocol assuming ERC-20 compliant
 * tokens
 * @dev When paused, allows only withdraw/unstake
 */
contract StakerVault is IStakerVault, Authorization, Pausable, Initializable {
    using AddressProviderHelpers for IAddressProvider;
    using SafeERC20 for IERC20;
    using ScaledMath for uint256;
    using UncheckedMath for uint256;

    struct AccountInfo {
        uint128 balance;
        uint128 actionLockedBalance;
    }

    address public lpGauge;

    IAddressProvider public immutable addressProvider;

    address public token;

    mapping(address => AccountInfo) public accountInfo;

    mapping(address => mapping(address => uint256)) internal _allowances;

    // All the data fields required for the staking tracking
    uint256 private _poolTotalStaked;

    event LpGaugeUpdated(address lpGauge_);

    constructor(IAddressProvider _addressProvider)
        Authorization(_addressProvider.getRoleManager())
    {
        addressProvider = _addressProvider;
    }

    function initialize(address _token) external override initializer {
        token = _token;
    }

    function initializeLpGauge(address lpGauge_) external override onlyGovernance {
        require(lpGauge == address(0), Error.ROLE_EXISTS);
        lpGauge = lpGauge_;
        addressProvider.getInflationManager().addGaugeForVault(token);
    }

    function updateLpGauge(address lpGauge_) external override onlyGovernance {
        require(!ILpGauge(lpGauge_).killed(), Error.GAUGE_KILLED);
        ILpGauge(lpGauge).kill();
        lpGauge = lpGauge_;
        addressProvider.getInflationManager().addGaugeForVault(token);
        emit LpGaugeUpdated(lpGauge_);
    }

    /**
     * @notice Transfer staked tokens to an account.
     * @dev This is not an ERC20 transfer, as tokens are still owned by this contract, but fees get updated in the LP pool.
     * @param account Address to transfer to.
     * @param amount Amount to transfer.
     */
    function transfer(address account, uint256 amount) external override notPaused {
        require(account != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        require(msg.sender != account, Error.SELF_TRANSFER_NOT_ALLOWED);
        AccountInfo memory accountInfo_ = accountInfo[msg.sender];
        require(accountInfo_.balance >= amount, Error.INSUFFICIENT_BALANCE);

        ILiquidityPool pool = addressProvider.getPoolForToken(token);
        pool.handleLpTokenTransfer(msg.sender, account, amount);

        address lpGauge_ = lpGauge;
        if (lpGauge_ != address(0)) {
            ILpGauge(lpGauge_).userCheckpoint(msg.sender);
            ILpGauge(lpGauge_).userCheckpoint(account);
        }

        accountInfo[msg.sender].balance = uint128(
            uint256(accountInfo_.balance).uncheckedSub(amount)
        );
        accountInfo[account].balance += uint128(amount);

        emit Transfer(msg.sender, account, amount);
    }

    /**
     * @notice Transfer staked tokens from src to dst.
     * @dev This is not an ERC20 transfer, as tokens are still owned by this contract, but fees get updated in the LP pool.
     * @param src Address to transfer from.
     * @param dst Address to transfer to.
     * @param amount Amount to transfer.
     */
    function transferFrom(
        address src,
        address dst,
        uint256 amount
    ) external override notPaused {
        require(src != address(0) && dst != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);

        /* Do not allow self transfers */
        require(src != dst, Error.SAME_ADDRESS_NOT_ALLOWED);

        /* Get the allowance, infinite for the account owner */
        uint256 startingAllowance;
        if (msg.sender == src) {
            startingAllowance = type(uint256).max;
        } else {
            startingAllowance = _allowances[src][msg.sender];
        }
        require(startingAllowance >= amount, Error.INSUFFICIENT_ALLOWANCE);

        AccountInfo memory accountInfo_ = accountInfo[src];
        uint256 srcTokens = accountInfo_.balance;
        require(srcTokens >= amount, Error.INSUFFICIENT_BALANCE);

        address lpGauge_ = lpGauge;
        if (lpGauge_ != address(0)) {
            ILpGauge(lpGauge_).userCheckpoint(src);
            ILpGauge(lpGauge_).userCheckpoint(dst);
        }
        ILiquidityPool pool = addressProvider.getPoolForToken(token);
        pool.handleLpTokenTransfer(src, dst, amount);

        /* Update token balances */
        accountInfo[src].balance = uint128(srcTokens.uncheckedSub(amount));
        accountInfo[dst].balance += uint128(amount);

        /* Update allowance if necessary */
        if (startingAllowance != type(uint256).max) {
            _allowances[src][msg.sender] = startingAllowance.uncheckedSub(amount);
        }
        emit Transfer(src, dst, amount);
    }

    /**
     * @notice Approve staked tokens for spender.
     * @param spender Address to approve tokens for.
     * @param amount Amount to approve.
     */
    function approve(address spender, uint256 amount) external override notPaused {
        require(spender != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
    }

    /**
     * @notice If an action is registered and stakes funds, this updates the actionLockedBalances for the user.
     * @param account Address that registered the action.
     * @param amount Amount staked by the action.
     */
    function increaseActionLockedBalance(address account, uint256 amount)
        external
        override
        onlyRole(Roles.ACTION)
    {
        address lpGauge_ = lpGauge;
        if (lpGauge_ != address(0)) {
            ILpGauge(lpGauge_).userCheckpoint(account);
        }
        accountInfo[account].actionLockedBalance += uint128(amount);
    }

    /**
     * @notice If an action is executed/reset, this updates the actionLockedBalances for the user.
     * @param account Address that registered the action.
     * @param amount Amount executed/reset by the action.
     */
    function decreaseActionLockedBalance(address account, uint256 amount)
        external
        override
        onlyRole(Roles.ACTION)
    {
        address lpGauge_ = lpGauge;
        if (lpGauge_ != address(0)) {
            ILpGauge(lpGauge_).userCheckpoint(account);
        }
        uint256 actionLockedBalance_ = accountInfo[account].actionLockedBalance;
        if (actionLockedBalance_ > amount) {
            accountInfo[account].actionLockedBalance = uint128(
                actionLockedBalance_.uncheckedSub(amount)
            );
        } else {
            accountInfo[account].actionLockedBalance = 0;
        }
    }

    function poolCheckpoint() external override returns (bool) {
        address lpGauge_ = lpGauge;
        if (lpGauge_ == address(0)) return false;
        ILpGauge(lpGauge_).poolCheckpoint();
        return true;
    }

    function poolCheckpoint(uint256 updateEndTime)
        external
        override
        onlyRole(Roles.INFLATION_MANAGER)
        returns (bool)
    {
        if (lpGauge == address(0)) return false;
        ILpGauge(lpGauge).poolCheckpoint(updateEndTime);
        return true;
    }

    /**
     * @notice Get the total amount of tokens that are staked by actions
     * @return Total amount staked by actions
     */
    function getStakedByActions() external view override returns (uint256) {
        address[] memory actions = addressProvider.allActions();
        uint256 total;
        for (uint256 i; i < actions.length; i = i.uncheckedInc()) {
            total += accountInfo[actions[i]].balance;
        }
        return total;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function balanceOf(address account) external view override returns (uint256) {
        return accountInfo[account].balance;
    }

    function getPoolTotalStaked() external view override returns (uint256) {
        return _poolTotalStaked;
    }

    /**
     * @notice Returns the total balance in the staker vault, including that locked in positions.
     * @param account Account to query balance for.
     * @return Total balance in staker vault for account.
     */
    function stakedAndActionLockedBalanceOf(address account)
        external
        view
        override
        returns (uint256)
    {
        AccountInfo memory accountInfo_ = accountInfo[account];
        return accountInfo_.balance + accountInfo_.actionLockedBalance;
    }

    function actionLockedBalanceOf(address account) external view override returns (uint256) {
        return accountInfo[account].actionLockedBalance;
    }

    function decimals() external view override returns (uint8) {
        return IERC20Full(token).decimals();
    }

    function getToken() external view override returns (address) {
        return token;
    }

    function unstake(uint256 amount) public override {
        unstakeFor(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Stake an amount of vault tokens.
     * @param amount Amount of token to stake.
     */
    function stake(uint256 amount) public override {
        stakeFor(msg.sender, amount);
    }

    /**
     * @notice Stake amount of vault token on behalf of another account.
     * @param account Account for which tokens will be staked.
     * @param amount Amount of token to stake.
     */
    function stakeFor(address account, uint256 amount) public override notPaused {
        require(account != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        IERC20 token_ = IERC20(token);
        require(token_.balanceOf(msg.sender) >= amount, Error.INSUFFICIENT_BALANCE);

        address lpGauge_ = lpGauge;
        if (lpGauge_ != address(0)) {
            ILpGauge(lpGauge_).userCheckpoint(account);
        }

        uint256 oldBal = token_.balanceOf(address(this));

        if (msg.sender != account) {
            ILiquidityPool pool = addressProvider.getPoolForToken(address(token_));
            pool.handleLpTokenTransfer(msg.sender, account, amount);
        }

        token_.safeTransferFrom(msg.sender, address(this), amount);
        uint256 staked = token_.balanceOf(address(this)) - oldBal;
        require(staked == amount, Error.INVALID_AMOUNT);
        accountInfo[account].balance += uint128(staked);

        _poolTotalStaked += staked;
        emit Staked(account, amount);
    }

    /**
     * @notice Unstake tokens on behalf of another account.
     * @dev Needs to be approved.
     * @param src Account for which tokens will be unstaked.
     * @param dst Account receiving the tokens.
     * @param amount Amount of token to unstake/receive.
     */
    function unstakeFor(
        address src,
        address dst,
        uint256 amount
    ) public override {
        require(src != address(0) && dst != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        require(dst != address(this), Error.SAME_ADDRESS_NOT_ALLOWED);
        IERC20 token_ = IERC20(token);
        ILiquidityPool pool = addressProvider.getPoolForToken(address(token_));
        AccountInfo memory srcAccountInfo_ = accountInfo[src];
        uint256 allowance_ = _allowances[src][msg.sender];
        require(
            src == msg.sender || allowance_ >= amount || address(pool) == msg.sender,
            Error.UNAUTHORIZED_ACCESS
        );
        require(srcAccountInfo_.balance >= amount, Error.INSUFFICIENT_BALANCE);
        address lpGauge_ = lpGauge;
        if (lpGauge_ != address(0)) {
            ILpGauge(lpGauge_).userCheckpoint(src);
        }

        if (src != dst) {
            pool.handleLpTokenTransfer(src, dst, amount);
        }

        if (src != msg.sender && allowance_ != type(uint256).max && address(pool) != msg.sender) {
            // update allowance
            _allowances[src][msg.sender] -= amount;
        }
        accountInfo[src].balance -= uint128(amount);

        _poolTotalStaked -= amount;

        token_.safeTransfer(dst, amount);

        emit Unstaked(src, amount);
    }

    function _isAuthorizedToPause(address account) internal view override returns (bool) {
        return _roleManager().hasRole(Roles.GOVERNANCE, account);
    }
}
