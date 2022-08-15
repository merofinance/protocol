// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../../interfaces/IController.sol";
import "../../interfaces/pool/ILiquidityPool.sol";
import "../../interfaces/ILpToken.sol";
import "../../interfaces/IVault.sol";

import "../../libraries/AddressProviderHelpers.sol";
import "../../libraries/Errors.sol";
import "../../libraries/ScaledMath.sol";

import "../access/Authorization.sol";
import "../utils/Pausable.sol";

/**
 * @dev Pausing/unpausing the pool will disable/re-enable deposits.
 */
abstract contract LiquidityPool is ILiquidityPool, Authorization, Pausable, Initializable {
    using AddressProviderHelpers for IAddressProvider;
    using ScaledMath for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct WithdrawalFeeMeta {
        uint64 timeToWait;
        uint64 feeRatio;
        uint64 lastActionTimestamp;
    }

    IVault public vault;
    uint256 public reserveDeviation = 0.005e18;
    uint256 public requiredReserves = ScaledMath.ONE;
    uint256 public maxWithdrawalFee;
    uint256 public minWithdrawalFee;
    uint256 public withdrawalFeeDecreasePeriod = 1 weeks;

    /**
     * @notice even through admin votes and later governance, the withdrawal
     * fee will never be able to go above this value
     */
    uint256 internal constant _MAX_WITHDRAWAL_FEE = 0.05e18;

    /**
     * @notice Keeps track of the withdrawal fees on a per-address basis
     */
    mapping(address => WithdrawalFeeMeta) public withdrawalFeeMetas;

    IController public immutable controller;
    IAddressProvider public immutable addressProvider;

    IStakerVault public staker;
    ILpToken public lpToken;
    string public name;

    bool internal _shutdown;

    event RequiredReservesUpdated(uint256 requireReserves);
    event ReserveDeviationUpdated(uint256 reserveDeviation);
    event MinWithdrawalFeeUpdated(uint256 minWithdrawalFee);
    event MaxWithdrawalFeeUpdated(uint256 maxWithdrawalFee);
    event WithdrawalFeeDecreasePeriodUpdated(uint256 withdrawalFeeDecreasePeriod);
    event VaultUpdated(address vault);

    modifier notShutdown() {
        require(!_shutdown, Error.POOL_SHUTDOWN);
        _;
    }

    constructor(IController _controller)
        Authorization(_controller.addressProvider().getRoleManager())
    {
        controller = IController(_controller);
        addressProvider = IController(_controller).addressProvider();
    }

    /**
     * @notice Deposit funds into liquidity pool and mint LP tokens in exchange.
     * @param depositAmount Amount of the underlying asset to supply.
     * @return The actual amount minted.
     */
    function deposit(uint256 depositAmount) external payable override returns (uint256) {
        return depositFor(msg.sender, depositAmount, 0);
    }

    /**
     * @notice Deposit funds into liquidity pool and mint LP tokens in exchange.
     * @param depositAmount Amount of the underlying asset to supply.
     * @param minTokenAmount Minimum amount of LP tokens that should be minted.
     * @return The actual amount minted.
     */
    function deposit(uint256 depositAmount, uint256 minTokenAmount)
        external
        payable
        override
        returns (uint256)
    {
        return depositFor(msg.sender, depositAmount, minTokenAmount);
    }

    /**
     * @notice Deposit funds into liquidity pool and stake LP Tokens in Staker Vault.
     * @param depositAmount Amount of the underlying asset to supply.
     * @param minTokenAmount Minimum amount of LP tokens that should be minted.
     * @return The actual amount minted and staked.
     */
    function depositAndStake(uint256 depositAmount, uint256 minTokenAmount)
        external
        payable
        override
        returns (uint256)
    {
        uint256 amountMinted_ = depositFor(address(this), depositAmount, minTokenAmount);
        staker.stakeFor(msg.sender, amountMinted_);
        return amountMinted_;
    }

    /**
     * @notice Withdraws all funds from vault.
     * @dev Should be called in case of emergencies.
     */
    function shutdownStrategy() external override onlyGovernance {
        vault.shutdownStrategy();
    }

    /**
     * @notice permanently shuts down the pool
     * @param _shutdownStrategy if true, will also shut down the strategy
     * and withdraw all the funds back to the pool
     */
    function shutdownPool(bool _shutdownStrategy) external onlyRole(Roles.CONTROLLER) {
        require(!_shutdown, Error.ALREADY_SHUTDOWN);

        _shutdown = true;
        maxWithdrawalFee = 0;
        minWithdrawalFee = 0;

        if (_shutdownStrategy) {
            vault.shutdownStrategy();
        } else {
            vault.withdrawAvailableToPool();
        }

        emit Shutdown();
    }

    function setLpToken(address _lpToken)
        external
        override
        onlyRoles2(Roles.GOVERNANCE, Roles.POOL_FACTORY)
    {
        require(address(lpToken) == address(0), Error.ADDRESS_ALREADY_SET);
        require(ILpToken(_lpToken).minter() == address(this), Error.INVALID_MINTER);
        lpToken = ILpToken(_lpToken);
        _approveStakerVaultSpendingLpTokens();
        emit LpTokenSet(_lpToken);
    }

    /**
     * @notice Checkpoint function to update a user's withdrawal fees on deposit and redeem
     * @param from Address sending from
     * @param to Address sending to
     * @param amount Amount to redeem or deposit
     */
    function handleLpTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) external override {
        require(
            msg.sender == address(lpToken) || msg.sender == address(staker),
            Error.UNAUTHORIZED_ACCESS
        );
        if (
            addressProvider.isStakerVault(to, address(lpToken)) ||
            addressProvider.isStakerVault(from, address(lpToken)) ||
            addressProvider.isAction(to) ||
            addressProvider.isAction(from) ||
            addressProvider.isWhiteListedFeeHandler(to) ||
            addressProvider.isWhiteListedFeeHandler(from)
        ) {
            return;
        }

        if (to != address(0)) {
            _updateUserFeesOnDeposit(to, from, amount);
        }
    }

    /**
     * @notice Update required reserve ratio.
     * @param requireReserves_ New required reserve ratio.
     */
    function updateRequiredReserves(uint256 requireReserves_) external override onlyGovernance {
        require(requireReserves_ <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        requiredReserves = requireReserves_;
        _rebalanceVault();
        emit RequiredReservesUpdated(requireReserves_);
    }

    /**
     * @notice Update reserve deviation ratio.
     * @param reserveDeviation_ New reserve deviation ratio.
     */
    function updateReserveDeviation(uint256 reserveDeviation_) external override onlyGovernance {
        require(reserveDeviation_ <= (ScaledMath.DECIMAL_SCALE * 50) / 100, Error.INVALID_AMOUNT);
        reserveDeviation = reserveDeviation_;
        _rebalanceVault();
        emit ReserveDeviationUpdated(reserveDeviation_);
    }

    /**
     * @notice Update min withdrawal fee.
     * @param minWithdrawalFee_ New min withdrawal fee.
     */
    function updateMinWithdrawalFee(uint256 minWithdrawalFee_) external override onlyGovernance {
        _checkFeeInvariants(minWithdrawalFee_, maxWithdrawalFee);
        minWithdrawalFee = minWithdrawalFee_;
        emit MinWithdrawalFeeUpdated(minWithdrawalFee_);
    }

    /**
     * @notice Update max withdrawal fee.
     * @param maxWithdrawalFee_ New max withdrawal fee.
     */
    function updateMaxWithdrawalFee(uint256 maxWithdrawalFee_) external override onlyGovernance {
        _checkFeeInvariants(minWithdrawalFee, maxWithdrawalFee_);
        maxWithdrawalFee = maxWithdrawalFee_;
        emit MaxWithdrawalFeeUpdated(maxWithdrawalFee_);
    }

    /**
     * @notice Update withdrawal fee decrease period.
     * @param withdrawalFeeDecreasePeriod_ New withdrawal fee decrease period.
     */
    function updateWithdrawalFeeDecreasePeriod(uint256 withdrawalFeeDecreasePeriod_)
        external
        override
        onlyGovernance
    {
        withdrawalFeeDecreasePeriod = withdrawalFeeDecreasePeriod_;
        emit WithdrawalFeeDecreasePeriodUpdated(withdrawalFeeDecreasePeriod_);
    }

    /**
     * @notice Set the staker vault for this pool's LP token
     * @dev Staker vault and LP token pairs are immutable and the staker vault can only be set once for a pool.
     *      Only one vault exists per LP token. This information will be retrieved from the controller of the pool.
     */
    function setStaker() external override onlyRoles2(Roles.GOVERNANCE, Roles.POOL_FACTORY) {
        require(address(staker) == address(0), Error.ADDRESS_ALREADY_SET);
        address stakerVault = addressProvider.getStakerVault(address(lpToken));
        require(stakerVault != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        staker = IStakerVault(stakerVault);
        _approveStakerVaultSpendingLpTokens();
        emit StakerVaultSet(stakerVault);
    }

    /**
     * @notice Update vault.
     * @param vault_ Address of new Vault contract.
     */
    function updateVault(address vault_) external override onlyGovernance {
        IVault oldVault = IVault(vault);
        if (address(oldVault) != address(0)) oldVault.shutdownStrategy();
        vault = IVault(vault_);
        addressProvider.updateVault(address(oldVault), vault_);
        emit VaultUpdated(vault_);
    }

    /**
     * @notice Redeems the underlying asset by burning LP tokens.
     * @param redeemLpTokens Number of tokens to burn for redeeming the underlying.
     * @return Actual amount of the underlying redeemed.
     */
    function redeem(uint256 redeemLpTokens) external override returns (uint256) {
        return redeem(redeemLpTokens, 0);
    }

    /**
     * @notice Rebalance vault according to required underlying backing reserves.
     */
    function rebalanceVault() external override onlyGovernance {
        _rebalanceVault();
    }

    /**
     * @notice Deposit funds for an address into liquidity pool and mint LP tokens in exchange.
     * @param account Account to deposit for.
     * @param depositAmount Amount of the underlying asset to supply.
     * @return Actual amount minted.
     */
    function depositFor(address account, uint256 depositAmount)
        external
        payable
        override
        returns (uint256)
    {
        return depositFor(account, depositAmount, 0);
    }

    /**
     * @notice Redeems the underlying asset by burning LP tokens, unstaking any LP tokens needed.
     * @param redeemLpTokens Number of tokens to unstake and/or burn for redeeming the underlying.
     * @param minRedeemAmount Minimum amount of underlying that should be received.
     * @return Actual amount of the underlying redeemed.
     */
    function unstakeAndRedeem(uint256 redeemLpTokens, uint256 minRedeemAmount)
        external
        override
        returns (uint256)
    {
        uint256 lpBalance_ = lpToken.balanceOf(msg.sender);
        require(
            lpBalance_ + staker.balanceOf(msg.sender) >= redeemLpTokens,
            Error.INSUFFICIENT_BALANCE
        );
        if (lpBalance_ < redeemLpTokens) {
            staker.unstakeFor(msg.sender, msg.sender, redeemLpTokens - lpBalance_);
        }
        return redeem(redeemLpTokens, minRedeemAmount);
    }

    /**
     * @notice Returns the address of the LP token of this pool
     * @return The address of the LP token
     */
    function getLpToken() external view override returns (address) {
        return address(lpToken);
    }

    /**
     * @return whether the pool is shut down or not
     */
    function isShutdown() external view override returns (bool) {
        return _shutdown;
    }

    /**
     * @notice Calculates the amount of LP tokens that need to be redeemed to get a certain amount of underlying (includes fees and exchange rate)
     * @param account Address of the account redeeming.
     * @param underlyingAmount The amount of underlying desired.
     * @return Amount of LP tokens that need to be redeemed.
     */
    function calcRedeem(address account, uint256 underlyingAmount)
        external
        view
        override
        returns (uint256)
    {
        require(underlyingAmount > 0, Error.INVALID_AMOUNT);
        ILpToken lpToken_ = lpToken;
        require(lpToken_.balanceOf(account) > 0, Error.INSUFFICIENT_BALANCE);

        uint256 currentExchangeRate = exchangeRate();
        uint256 withoutFeesLpAmount = underlyingAmount.scaledDiv(currentExchangeRate);
        if (withoutFeesLpAmount == lpToken_.totalSupply()) {
            return withoutFeesLpAmount;
        }

        WithdrawalFeeMeta memory meta = withdrawalFeeMetas[account];

        uint256 currentFeeRatio;
        if (!addressProvider.isAction(account)) {
            currentFeeRatio = getNewCurrentFees(
                meta.timeToWait,
                meta.lastActionTimestamp,
                meta.feeRatio
            );
        }
        uint256 scalingFactor = currentExchangeRate.scaledMul((ScaledMath.ONE - currentFeeRatio));
        uint256 neededLpTokens = underlyingAmount.scaledDivRoundUp(scalingFactor);

        return neededLpTokens;
    }

    function getUnderlying() external view virtual override returns (address);

    /**
     * @notice Deposit funds for an address into liquidity pool and mint LP tokens in exchange.
     * @param account Account to deposit for.
     * @param depositAmount Amount of the underlying asset to supply.
     * @param minTokenAmount Minimum amount of LP tokens that should be minted.
     * @return Actual amount minted.
     */
    function depositFor(
        address account,
        uint256 depositAmount,
        uint256 minTokenAmount
    ) public payable override notPaused notShutdown returns (uint256) {
        if (depositAmount == 0) return 0;
        uint256 rate = exchangeRate();

        _doTransferInFromSender(depositAmount);
        uint256 mintedLp = depositAmount.scaledDiv(rate);
        require(mintedLp >= minTokenAmount && mintedLp > 0, Error.INVALID_AMOUNT);

        lpToken.mint(account, mintedLp);

        _rebalanceVault();

        if (msg.sender == account || address(this) == account) {
            emit Deposit(msg.sender, depositAmount, mintedLp);
        } else {
            emit DepositFor(msg.sender, account, depositAmount, mintedLp);
        }
        return mintedLp;
    }

    /**
     * @notice Redeems the underlying asset by burning LP tokens.
     * @param redeemLpTokens Number of tokens to burn for redeeming the underlying.
     * @param minRedeemAmount Minimum amount of underlying that should be received.
     * @return Actual amount of the underlying redeemed.
     */
    function redeem(uint256 redeemLpTokens, uint256 minRedeemAmount)
        public
        override
        returns (uint256)
    {
        require(redeemLpTokens > 0, Error.INVALID_AMOUNT);
        ILpToken lpToken_ = lpToken;
        require(lpToken_.balanceOf(msg.sender) >= redeemLpTokens, Error.INSUFFICIENT_BALANCE);

        uint256 withdrawalFee = addressProvider.isAction(msg.sender)
            ? 0
            : getWithdrawalFee(msg.sender, redeemLpTokens);
        uint256 redeemMinusFees = redeemLpTokens - withdrawalFee;
        // Pay no fees on the last withdrawal (avoid locking funds in the pool)
        if (redeemLpTokens == lpToken_.totalSupply()) {
            redeemMinusFees = redeemLpTokens;
        }
        uint256 redeemUnderlying = redeemMinusFees.scaledMul(exchangeRate());
        require(redeemUnderlying >= minRedeemAmount, Error.NOT_ENOUGH_FUNDS_WITHDRAWN);

        if (!_shutdown) {
            _rebalanceVault(redeemUnderlying);
        }

        lpToken_.burn(msg.sender, redeemLpTokens);
        _doTransferOut(payable(msg.sender), redeemUnderlying);
        emit Redeem(msg.sender, redeemUnderlying, redeemLpTokens);
        return redeemUnderlying;
    }

    /**
     * @notice Compute current exchange rate of LP tokens to underlying scaled to 1e18.
     * @dev Exchange rate means: underlying = LP token * exchangeRate
     * @return Current exchange rate.
     */
    function exchangeRate() public view override returns (uint256) {
        uint256 totalUnderlying_ = totalUnderlying();
        uint256 totalSupply = lpToken.totalSupply();
        if (totalSupply == 0 || totalUnderlying_ == 0) {
            return ScaledMath.ONE;
        }

        return totalUnderlying_.scaledDiv(totalSupply);
    }

    /**
     * @notice Compute total amount of underlying tokens for this pool.
     * @return Total amount of underlying in pool.
     */
    function totalUnderlying() public view override returns (uint256) {
        IVault vault_ = vault;
        if (address(vault_) == address(0)) {
            return _getBalanceUnderlying();
        }
        uint256 investedUnderlying = vault_.getTotalUnderlying();
        return investedUnderlying + _getBalanceUnderlying();
    }

    /**
     * @notice Returns the withdrawal fee for `account`
     * @param account Address to get the withdrawal fee for
     * @param amount Amount to calculate the withdrawal fee for
     * @return Withdrawal fee in LP tokens
     */
    function getWithdrawalFee(address account, uint256 amount)
        public
        view
        override
        returns (uint256)
    {
        WithdrawalFeeMeta memory meta = withdrawalFeeMetas[account];

        if (lpToken.balanceOf(account) == 0) {
            return 0;
        }
        uint256 currentFee = getNewCurrentFees(
            meta.timeToWait,
            meta.lastActionTimestamp,
            meta.feeRatio
        );
        return amount.scaledMul(currentFee);
    }

    /**
     * @notice Calculates the withdrawal fee a user would currently need to pay on currentBalance.
     * @param timeToWait The total time to wait until the withdrawal fee reached the min. fee
     * @param lastActionTimestamp Timestamp of the last fee update
     * @param feeRatio Fees that would currently be paid on the user's entire balance
     * @return Updated fee amount on the currentBalance
     */
    function getNewCurrentFees(
        uint256 timeToWait,
        uint256 lastActionTimestamp,
        uint256 feeRatio
    ) public view override returns (uint256) {
        uint256 timeElapsed = _getTime() - lastActionTimestamp;
        uint256 minFeePercentage = minWithdrawalFee;
        if (timeElapsed >= timeToWait || minFeePercentage > feeRatio) {
            return minFeePercentage;
        }
        uint256 elapsedShare = timeElapsed.scaledDiv(timeToWait);
        return feeRatio - (feeRatio - minFeePercentage).scaledMul(elapsedShare);
    }

    function _rebalanceVault() internal {
        _rebalanceVault(0);
    }

    function _initialize(
        string calldata name_,
        address vault_,
        uint256 maxWithdrawalFee_,
        uint256 minWithdrawalFee_
    ) internal initializer {
        name = name_;
        vault = IVault(vault_);
        maxWithdrawalFee = maxWithdrawalFee_;
        minWithdrawalFee = minWithdrawalFee_;
    }

    function _approveStakerVaultSpendingLpTokens() internal {
        address staker_ = address(staker);
        address lpToken_ = address(lpToken);
        if (staker_ == address(0) || lpToken_ == address(0)) return;
        if (IERC20(lpToken_).allowance(address(this), staker_) > 0) return;
        IERC20(lpToken_).safeApprove(staker_, type(uint256).max);
    }

    function _doTransferInFromSender(uint256 amount) internal virtual;

    function _doTransferOut(address payable to, uint256 amount) internal virtual;

    /**
     * @dev Rebalances the pool's allocations to the vault
     * @param underlyingToWithdraw Amount of underlying to withdraw such that after the withdrawal the pool and vault allocations are correctly balanced.
     */
    function _rebalanceVault(uint256 underlyingToWithdraw) internal {
        IVault vault_ = vault;

        if (address(vault_) == address(0)) return;
        uint256 lockedLp = staker.getStakedByActions();
        uint256 totalUnderlyingStaked = lockedLp.scaledMul(exchangeRate());

        uint256 underlyingBalance = _getBalanceUnderlying(true);
        uint256 maximumDeviation = totalUnderlyingStaked.scaledMul(reserveDeviation);

        uint256 nextTargetBalance = totalUnderlyingStaked.scaledMul(requiredReserves);

        if (
            underlyingToWithdraw > underlyingBalance ||
            (underlyingBalance - underlyingToWithdraw) + maximumDeviation < nextTargetBalance
        ) {
            uint256 requiredDeposits = nextTargetBalance + underlyingToWithdraw - underlyingBalance;
            vault_.withdraw(requiredDeposits);
        } else {
            uint256 nextBalance = underlyingBalance - underlyingToWithdraw;
            if (nextBalance > nextTargetBalance + maximumDeviation) {
                uint256 excessDeposits = nextBalance - nextTargetBalance;
                _doTransferOut(payable(address(vault_)), excessDeposits);
                vault_.deposit();
            }
        }
    }

    function _updateUserFeesOnDeposit(
        address account,
        address from,
        uint256 amountAdded
    ) internal {
        WithdrawalFeeMeta storage meta = withdrawalFeeMetas[account];
        uint256 balance = lpToken.balanceOf(account) +
            staker.stakedAndActionLockedBalanceOf(account);
        uint256 newCurrentFeeRatio = getNewCurrentFees(
            meta.timeToWait,
            meta.lastActionTimestamp,
            meta.feeRatio
        );
        uint256 shareAdded = amountAdded.scaledDiv(amountAdded + balance);
        uint256 shareExisting = ScaledMath.ONE - shareAdded;
        uint256 feeOnDeposit;
        if (from == address(0)) {
            feeOnDeposit = maxWithdrawalFee;
            meta.lastActionTimestamp = _getTime().toUint64();
        } else {
            WithdrawalFeeMeta memory fromMeta = withdrawalFeeMetas[from];
            feeOnDeposit = getNewCurrentFees(
                fromMeta.timeToWait,
                fromMeta.lastActionTimestamp,
                fromMeta.feeRatio
            );
            uint256 minTime_ = _getTime() - meta.timeToWait;
            if (meta.lastActionTimestamp < minTime_) {
                meta.lastActionTimestamp = minTime_.toUint64();
            }
            meta.lastActionTimestamp = ((shareExisting *
                uint256(meta.lastActionTimestamp) +
                shareAdded *
                _getTime()) / (shareExisting + shareAdded)).toUint64();
        }

        uint256 newFeeRatio = shareExisting.scaledMul(newCurrentFeeRatio) +
            shareAdded.scaledMul(feeOnDeposit);

        meta.feeRatio = newFeeRatio.toUint64();
        meta.timeToWait = withdrawalFeeDecreasePeriod.toUint64();
    }

    function _getBalanceUnderlying() internal view virtual returns (uint256);

    function _getBalanceUnderlying(bool transferInDone) internal view virtual returns (uint256);

    function _isAuthorizedToPause(address account) internal view override returns (bool) {
        return _roleManager().hasRole(Roles.GOVERNANCE, account);
    }

    /**
     * @dev Overridden for testing
     */
    function _getTime() internal view virtual returns (uint256) {
        return block.timestamp;
    }

    function _checkFeeInvariants(uint256 minFee, uint256 maxFee) internal pure {
        require(maxFee >= minFee, Error.INVALID_AMOUNT);
        require(maxFee <= _MAX_WITHDRAWAL_FEE, Error.INVALID_AMOUNT);
    }
}
