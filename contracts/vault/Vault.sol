// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../../interfaces/IVault.sol";
import "../../interfaces/IVaultReserve.sol";
import "../../interfaces/IController.sol";

import "../../libraries/ScaledMath.sol";
import "../../libraries/Errors.sol";
import "../../libraries/EnumerableExtensions.sol";
import "../../libraries/AddressProviderHelpers.sol";
import "../../libraries/AddressProviderKeys.sol";
import "../../libraries/UncheckedMath.sol";

import "./VaultStorage.sol";
import "../utils/IPausable.sol";
import "../access/Authorization.sol";

abstract contract Vault is IVault, Authorization, VaultStorageV1, Initializable {
    using ScaledMath for uint256;
    using UncheckedMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableExtensions for EnumerableSet.AddressSet;
    using EnumerableMapping for EnumerableMapping.AddressToUintMap;
    using EnumerableExtensions for EnumerableMapping.AddressToUintMap;
    using AddressProviderHelpers for IAddressProvider;

    IStrategy public strategy;
    uint256 public performanceFee;
    uint256 public strategistFee = 0.1e18;
    uint256 public debtLimit;
    uint256 public targetAllocation;
    uint256 public reserveFee = 0.01e18;
    uint256 public bound;

    uint256 public constant MAX_PERFORMANCE_FEE = 0.5e18;
    uint256 public constant MAX_DEVIATION_BOUND = 0.5e18;
    uint256 public constant STRATEGY_DELAY = 5 days;

    IController public immutable controller;
    IAddressProvider public immutable addressProvider;

    event StrategyUpdated(address newStrategy);
    event PerformanceFeeUpdated(uint256 performanceFee);
    event StrategistFeeUpdated(uint256 strategistFee);
    event DebtLimitUpdated(uint256 debtLimit);
    event TargetAllocationUpdated(uint256 targetAllocation);
    event ReserveFeeUpdated(uint256 reserveFee);
    event BoundUpdated(uint256 bound);
    event AllFundsWithdrawn();

    modifier onlyPool() {
        require(msg.sender == pool, Error.UNAUTHORIZED_ACCESS);
        _;
    }

    modifier onlyPoolOrGovernance() {
        require(
            msg.sender == pool || _roleManager().hasRole(Roles.GOVERNANCE, msg.sender),
            Error.UNAUTHORIZED_ACCESS
        );
        _;
    }

    modifier onlyPoolOrMaintenance() {
        require(
            msg.sender == pool || _roleManager().hasRole(Roles.MAINTENANCE, msg.sender),
            Error.UNAUTHORIZED_ACCESS
        );
        _;
    }

    constructor(IController _controller)
        Authorization(_controller.addressProvider().getRoleManager())
    {
        controller = _controller;
        IAddressProvider addressProvider_ = _controller.addressProvider();
        addressProvider = addressProvider_;
    }

    function _initialize(
        address pool_,
        uint256 debtLimit_,
        uint256 targetAllocation_,
        uint256 bound_
    ) internal {
        require(debtLimit_ <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        require(targetAllocation_ <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        require(bound_ <= MAX_DEVIATION_BOUND, Error.INVALID_AMOUNT);

        pool = pool_;
        debtLimit = debtLimit_;
        targetAllocation = targetAllocation_;
        bound = bound_;
    }

    /**
     * @notice Handles deposits from the liquidity pool
     */
    function deposit() external payable override onlyPoolOrMaintenance {
        // solhint-disable-previous-line ordering
        _deposit();
    }

    /**
     * @notice Withdraws specified amount of underlying from vault.
     * @dev If the specified amount exceeds idle funds, an amount of funds is withdrawn
     *      from the strategy such that it will achieve a target allocation for after the
     *      amount has been withdrawn.
     * @param amount Amount to withdraw.
     * @return `true` if successful.
     */
    function withdraw(uint256 amount) external override onlyPoolOrGovernance returns (bool) {
        IStrategy strategy_ = strategy;
        uint256 availableUnderlying_ = _availableUnderlying();

        if (availableUnderlying_ < amount) {
            if (address(strategy_) == address(0)) return false;
            uint256 allocated = strategy_.balance();
            uint256 requiredWithdrawal = amount.uncheckedSub(availableUnderlying_);

            if (requiredWithdrawal > allocated) return false;

            // compute withdrawal amount to sustain target allocation
            uint256 newTarget = allocated.uncheckedSub(requiredWithdrawal).scaledMul(
                targetAllocation
            );
            uint256 excessAmount = allocated - newTarget;
            strategy_.withdraw(excessAmount);
            currentAllocated = _computeNewAllocated(currentAllocated, excessAmount);
        } else {
            uint256 allocatedUnderlying;
            if (address(strategy_) != address(0))
                allocatedUnderlying = IStrategy(strategy_).balance();
            uint256 totalUnderlying = availableUnderlying_ +
                allocatedUnderlying +
                waitingForRemovalAllocated;
            uint256 totalUnderlyingAfterWithdraw = totalUnderlying.uncheckedSub(amount);
            _rebalance(totalUnderlyingAfterWithdraw, allocatedUnderlying);
        }

        _transfer(pool, amount);
        return true;
    }

    /**
     * @notice Shuts down the strategy, withdraws all funds from vault and
     * strategy and transfer them to the pool.
     */
    function shutdownStrategy() external override onlyPool {
        _withdrawAllFromStrategy();
        _transfer(pool, _availableUnderlying());
    }

    /**
     * @notice Transfers all the available funds to the pool
     */
    function withdrawAvailableToPool() external onlyPoolOrGovernance {
        _transfer(pool, _availableUnderlying());
    }

    /**
     * @notice Withdraws specified amount of underlying from reserve to vault.
     * @dev Withdraws from reserve will cause a spike in pool exchange rate.
     *  Pool deposits should be paused during this to prevent front running
     * @param amount Amount to withdraw.
     */
    function withdrawFromReserve(uint256 amount) external override onlyGovernance {
        IVaultReserve reserve_ = _reserve();
        require(amount > 0, Error.INVALID_AMOUNT);
        require(IPausable(pool).isPaused(), Error.POOL_NOT_PAUSED);
        uint256 reserveBalance_ = reserve_.getBalance(address(this), getUnderlying());
        require(amount <= reserveBalance_, Error.INSUFFICIENT_BALANCE);
        reserve_.withdraw(getUnderlying(), amount);
    }

    /**
     * @notice Activate the current strategy set for the vault.
     * @return `true` if strategy has been activated
     */
    function activateStrategy() external override onlyGovernance returns (bool) {
        return _activateStrategy();
    }

    /**
     * @notice Deactivates a strategy.
     * @return `true` if strategy has been deactivated
     */
    function deactivateStrategy() external override onlyGovernance returns (bool) {
        return _deactivateStrategy();
    }

    /**
     * @notice Initializes the vault's strategy.
     * @dev Bypasses the time delay, but can only be called if strategy is not set already.
     * @param strategy_ Address of the strategy.
     */
    function initializeStrategy(address strategy_) external override onlyGovernance {
        require(address(strategy) == address(0), Error.ADDRESS_ALREADY_SET);
        require(strategy_ != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        strategy = IStrategy(strategy_);
        _activateStrategy();
        require(IStrategy(strategy_).strategist() != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
    }

    /**
     * @notice Update the vault's strategy (with time delay enforced).
     * @param newStrategy_ Address of the new strategy.
     */
    function updateStrategy(address newStrategy_) external override onlyGovernance {
        IStrategy strategy_ = strategy;
        if (address(strategy_) != address(0)) {
            _harvest();
            strategy_.shutdown();
            strategy_.withdrawAll();

            // there might still be some balance left if the strategy did not
            // manage to withdraw all funds (e.g. due to locking)
            uint256 remainingStrategyBalance = strategy_.balance();
            if (remainingStrategyBalance > 0) {
                _strategiesWaitingForRemoval.set(address(strategy_), remainingStrategyBalance);
                waitingForRemovalAllocated += remainingStrategyBalance;
            }
        }
        _deactivateStrategy();
        currentAllocated = 0;
        totalDebt = 0;
        strategy = IStrategy(newStrategy_);

        if (newStrategy_ != address(0)) _activateStrategy();
        emit StrategyUpdated(newStrategy_);
    }

    /**
     * @notice Update performance fee.
     * @param performanceFee_ New performance fee value.
     */
    function updatePerformanceFee(uint256 performanceFee_) external override onlyGovernance {
        require(performanceFee_ <= MAX_PERFORMANCE_FEE, Error.INVALID_AMOUNT);
        performanceFee = performanceFee_;
        emit PerformanceFeeUpdated(performanceFee_);
    }

    /**
     * @notice Update strategist fee (with time delay enforced).
     * @param strategistFee_ New strategist fee value.
     */
    function updateStrategistFee(uint256 strategistFee_) external override onlyGovernance {
        _checkFeesInvariant(reserveFee, strategistFee_);
        strategistFee = strategistFee_;
        emit StrategistFeeUpdated(strategistFee_);
    }

    /**
     * @notice Update debt limit.
     * @param debtLimit_ New debt limit.
     */
    function updateDebtLimit(uint256 debtLimit_) external override onlyGovernance {
        debtLimit = debtLimit_;
        if (totalDebt >= currentAllocated.scaledMul(debtLimit_)) _handleExcessDebt();
        emit DebtLimitUpdated(debtLimit_);
    }

    /**
     * @notice Update target allocation.
     * @param targetAllocation_ New target allocation.
     */
    function updateTargetAllocation(uint256 targetAllocation_) external override onlyGovernance {
        targetAllocation = targetAllocation_;
        _deposit();
        emit TargetAllocationUpdated(targetAllocation_);
    }

    /**
     * @notice Update reserve fee.
     * @param reserveFee_ New reserve fee.
     */
    function updateReserveFee(uint256 reserveFee_) external override onlyGovernance {
        _checkFeesInvariant(reserveFee_, strategistFee);
        reserveFee = reserveFee_;
        emit ReserveFeeUpdated(reserveFee_);
    }

    /**
     * @notice Update deviation bound for strategy allocation.
     * @param bound_ New deviation bound for target allocation.
     */
    function updateBound(uint256 bound_) external override onlyGovernance {
        require(bound_ <= MAX_DEVIATION_BOUND, Error.INVALID_AMOUNT);
        bound = bound_;
        _deposit();
        emit BoundUpdated(bound_);
    }

    /**
     * @notice Withdraws an amount of underlying from the strategy to the vault.
     * @param amount Amount of underlying to withdraw.
     * @return True if successful withdrawal.
     */
    function withdrawFromStrategy(uint256 amount) external override onlyGovernance returns (bool) {
        IStrategy strategy_ = strategy;
        if (address(strategy_) == address(0)) return false;
        if (strategy_.balance() < amount) return false;
        uint256 oldBalance = _availableUnderlying();
        strategy_.withdraw(amount);
        uint256 newBalance = _availableUnderlying();
        currentAllocated -= newBalance - oldBalance;
        return true;
    }

    function withdrawFromStrategyWaitingForRemoval(address strategy_)
        external
        override
        returns (uint256)
    {
        (bool exists, uint256 allocated) = _strategiesWaitingForRemoval.tryGet(strategy_);
        require(exists, Error.STRATEGY_DOES_NOT_EXIST);

        IStrategy(strategy_).harvest();
        uint256 withdrawn = IStrategy(strategy_).withdrawAll();

        uint256 _waitingForRemovalAllocated = waitingForRemovalAllocated;
        if (withdrawn >= _waitingForRemovalAllocated) {
            waitingForRemovalAllocated = 0;
        } else {
            waitingForRemovalAllocated = _waitingForRemovalAllocated.uncheckedSub(withdrawn);
        }

        if (withdrawn > allocated) {
            uint256 profit = withdrawn.uncheckedSub(allocated);
            uint256 strategistShare = _shareFees(profit.scaledMul(performanceFee));
            if (strategistShare > 0) {
                _payStrategist(strategistShare, IStrategy(strategy_).strategist());
            }
            allocated = 0;
            emit Harvest(profit, 0);
        } else {
            allocated = allocated.uncheckedSub(withdrawn);
        }

        if (IStrategy(strategy_).balance() == 0) {
            _strategiesWaitingForRemoval.remove(strategy_);
        } else {
            _strategiesWaitingForRemoval.set(strategy_, allocated);
        }

        return withdrawn;
    }

    function getStrategiesWaitingForRemoval() external view override returns (address[] memory) {
        return _strategiesWaitingForRemoval.keysArray();
    }

    /**
     * @notice Computes the total underlying of the vault: idle funds + allocated funds
     * @return Total amount of underlying.
     */
    function getTotalUnderlying() external view override returns (uint256) {
        if (address(strategy) == address(0)) {
            return _availableUnderlying();
        }

        return _availableUnderlying() + currentAllocated + waitingForRemovalAllocated;
    }

    function getAllocatedToStrategyWaitingForRemoval(address strategy_)
        external
        view
        override
        returns (uint256)
    {
        return _strategiesWaitingForRemoval.get(strategy_);
    }

    /**
     * @notice Withdraws all funds from strategy to vault.
     * @dev Harvests profits before withdrawing. Deactivates strategy after withdrawing.
     * @return `true` if successful.
     */
    function withdrawAllFromStrategy() public override onlyPoolOrGovernance returns (bool) {
        return _withdrawAllFromStrategy();
    }

    /**
     * @notice Harvest profits from the vault's strategy.
     * @dev Harvesting adds profits to the vault's balance and deducts fees.
     *  No performance fees are charged on profit used to repay debt.
     * @return `true` if successful.
     */
    function harvest() public override onlyPoolOrMaintenance returns (bool) {
        return _harvest();
    }

    function getUnderlying() public view virtual override returns (address);

    function _activateStrategy() internal returns (bool) {
        IStrategy strategy_ = strategy;
        if (address(strategy_) == address(0)) return false;

        strategyActive = true;
        emit StrategyActivated(address(strategy_));
        _deposit();
        return true;
    }

    function _harvest() internal returns (bool) {
        IStrategy strategy_ = strategy;
        if (address(strategy_) == address(0)) {
            return false;
        }

        strategy_.harvest();

        uint256 strategistShare;

        uint256 allocatedUnderlying = strategy_.balance();
        uint256 amountAllocated = currentAllocated;
        uint256 currentDebt = totalDebt;

        if (allocatedUnderlying > amountAllocated) {
            // we made profits
            uint256 profit = allocatedUnderlying.uncheckedSub(amountAllocated);

            if (profit > currentDebt) {
                if (currentDebt > 0) {
                    profit = profit.uncheckedSub(currentDebt);
                    currentDebt = 0;
                }
                (profit, strategistShare) = _shareProfit(profit);
            } else {
                currentDebt = currentDebt.uncheckedSub(profit);
            }
            emit Harvest(profit, 0);
        } else if (allocatedUnderlying < amountAllocated) {
            // we made a loss
            uint256 loss = amountAllocated.uncheckedSub(allocatedUnderlying);
            currentDebt += loss;

            // check debt limit and withdraw funds if exceeded
            uint256 debtLimitAllocated = amountAllocated.scaledMul(debtLimit);
            if (currentDebt > debtLimitAllocated) {
                currentDebt = _handleExcessDebt(currentDebt);
            }
            emit Harvest(0, loss);
        } else {
            // nothing to declare
            return true;
        }

        totalDebt = currentDebt;
        currentAllocated = strategy_.balance();

        if (strategistShare > 0) {
            _payStrategist(strategistShare);
        }

        return true;
    }

    function _withdrawAllFromStrategy() internal returns (bool) {
        IStrategy strategy_ = strategy;
        if (address(strategy_) == address(0)) return false;
        _harvest();
        strategy_.withdrawAll();
        currentAllocated = 0;
        totalDebt = 0;
        _deactivateStrategy();
        emit AllFundsWithdrawn();
        return true;
    }

    function _handleExcessDebt(uint256 currentDebt) internal returns (uint256) {
        IVaultReserve reserve_ = _reserve();
        uint256 underlyingReserves = reserve_.getBalance(address(this), getUnderlying());
        if (currentDebt > underlyingReserves) {
            _emergencyStop(underlyingReserves);
        } else if (reserve_.canWithdraw(address(this))) {
            reserve_.withdraw(getUnderlying(), currentDebt);
            currentDebt = 0;
            _deposit();
        }
        return currentDebt;
    }

    function _handleExcessDebt() internal {
        uint256 currentDebt = totalDebt;
        uint256 newDebt = _handleExcessDebt(currentDebt);
        if (currentDebt != newDebt) {
            totalDebt = newDebt;
        }
    }

    /**
     * @notice Invest the underlying money in the vault after a deposit from the pool is made.
     * @dev After each deposit, the vault checks whether it needs to rebalance underlying funds allocated to strategy.
     * If no strategy is set then all deposited funds will be idle.
     */
    function _deposit() internal {
        if (!strategyActive) return;

        uint256 allocatedUnderlying = strategy.balance();
        uint256 totalUnderlying = _availableUnderlying() +
            allocatedUnderlying +
            waitingForRemovalAllocated;

        if (totalUnderlying == 0) return;
        _rebalance(totalUnderlying, allocatedUnderlying);
    }

    function _shareProfit(uint256 profit) internal returns (uint256, uint256) {
        uint256 totalFeeAmount = profit.scaledMul(performanceFee);
        if (_availableUnderlying() < totalFeeAmount) {
            strategy.withdraw(totalFeeAmount);
        }
        uint256 strategistShare = _shareFees(totalFeeAmount);

        return ((profit - totalFeeAmount), strategistShare);
    }

    function _shareFees(uint256 totalFeeAmount) internal returns (uint256) {
        uint256 strategistShare = totalFeeAmount.scaledMul(strategistFee);

        uint256 reserveShare = totalFeeAmount.scaledMul(reserveFee);
        uint256 govShare = totalFeeAmount - strategistShare - reserveShare;

        _depositToReserve(reserveShare);
        if (govShare > 0) {
            _depositToRewardHandler(govShare);
        }
        return strategistShare;
    }

    function _emergencyStop(uint256 underlyingReserves) internal {
        // debt limit exceeded: withdraw funds from strategy
        uint256 withdrawn = strategy.withdrawAll();

        uint256 actualDebt = _computeNewAllocated(currentAllocated, withdrawn);

        if (_reserve().canWithdraw(address(this))) {
            // check if debt can be covered with reserve funds
            if (underlyingReserves >= actualDebt) {
                _reserve().withdraw(getUnderlying(), actualDebt);
            } else if (underlyingReserves > 0) {
                // debt can not be covered with reserves
                _reserve().withdraw(getUnderlying(), underlyingReserves);
            }
        }

        // too much money lost, stop the strategy
        _deactivateStrategy();
    }

    /**
     * @notice Deactivates a strategy. All positions of the strategy are exited.
     * @return `true` if strategy has been deactivated
     */
    function _deactivateStrategy() internal returns (bool) {
        if (!strategyActive) return false;

        strategyActive = false;
        emit StrategyDeactivated(address(strategy));
        return true;
    }

    function _payStrategist(uint256 amount) internal {
        _payStrategist(amount, strategy.strategist());
    }

    function _payStrategist(uint256 amount, address strategist) internal virtual;

    function _transfer(address to, uint256 amount) internal virtual;

    function _depositToReserve(uint256 amount) internal virtual;

    function _depositToRewardHandler(uint256 amount) internal virtual;

    function _availableUnderlying() internal view virtual returns (uint256);

    function _computeNewAllocated(uint256 allocated, uint256 withdrawn)
        internal
        pure
        returns (uint256)
    {
        if (allocated > withdrawn) {
            return allocated - withdrawn;
        }
        return 0;
    }

    function _checkFeesInvariant(uint256 reserveFee_, uint256 strategistFee_) internal pure {
        require(
            reserveFee_ + strategistFee_ <= ScaledMath.ONE,
            "sum of strategist fee and reserve fee should be below 1"
        );
    }

    function _rebalance(uint256 totalUnderlying, uint256 allocatedUnderlying)
        private
        returns (bool)
    {
        if (!strategyActive) return false;
        uint256 targetAllocation_ = targetAllocation;

        uint256 bound_ = bound;

        uint256 target = totalUnderlying.scaledMul(targetAllocation_);
        uint256 upperBound = targetAllocation_ == 0 ? 0 : targetAllocation_ + bound_;
        upperBound = upperBound > ScaledMath.ONE ? ScaledMath.ONE : upperBound;
        uint256 lowerBound = bound_ > targetAllocation_ ? 0 : targetAllocation_ - bound_;
        if (allocatedUnderlying > totalUnderlying.scaledMul(upperBound)) {
            // withdraw funds from strategy
            uint256 withdrawAmount = allocatedUnderlying - target;
            strategy.withdraw(withdrawAmount);

            currentAllocated = _computeNewAllocated(currentAllocated, withdrawAmount);
        } else if (allocatedUnderlying < totalUnderlying.scaledMul(lowerBound)) {
            // allocate more funds to strategy
            uint256 depositAmount = target - allocatedUnderlying;
            _transfer(address(strategy), depositAmount);
            currentAllocated += depositAmount;
            strategy.deposit();
        }
        return true;
    }

    function _reserve() internal view returns (IVaultReserve) {
        return addressProvider.getVaultReserve();
    }
}
