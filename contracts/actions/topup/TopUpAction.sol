// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../BaseAction.sol";

import "../../../interfaces/IGasBank.sol";
import "../../../interfaces/pool/ILiquidityPool.sol";
import "../../../interfaces/IController.sol";
import "../../../interfaces/IStakerVault.sol";
import "../../../interfaces/actions/topup/ITopUpHandler.sol";
import "../../../interfaces/actions/topup/ITopUpAction.sol";
import "../../../interfaces/actions/IActionFeeHandler.sol";

import "../../../libraries/AddressProviderHelpers.sol";
import "../../../libraries/Errors.sol";
import "../../../libraries/ScaledMath.sol";
import "../../../libraries/EnumerableExtensions.sol";
import "../../../libraries/UncheckedMath.sol";

/**
 * @notice The logic here should really be part of the top-up action
 * but is split in a library to circumvent the byte-code size limit
 */
library TopUpActionLibrary {
    using SafeERC20 for IERC20;
    using ScaledMath for uint256;
    using AddressProviderHelpers for IAddressProvider;

    /**
     * @dev "Locks" an amount of tokens on behalf of the TopUpAction
     * Funds are taken from staker vault if allowance is sufficient, else direct transfer or a combination of both.
     * @param stakerVaultAddress The address of the staker vault
     * @param payer Owner of the funds to be locked
     * @param token Token to lock
     * @param lockAmount Minimum amount of `token` to lock
     * @param depositAmount Amount of `token` that was deposited.
     *                      If this is 0 then the staker vault allowance should be used.
     *                      If this is greater than `requiredAmount` more tokens will be locked.
     */
    function lockFunds(
        address stakerVaultAddress,
        address payer,
        address token,
        uint256 lockAmount,
        uint256 depositAmount
    ) external {
        IStakerVault stakerVault = IStakerVault(stakerVaultAddress);

        // stake deposit amount
        if (depositAmount > 0) {
            depositAmount = depositAmount > lockAmount ? lockAmount : depositAmount;
            IERC20(token).safeTransferFrom(payer, address(this), depositAmount);
            _approve(token, stakerVaultAddress);
            stakerVault.stake(depositAmount);
            stakerVault.increaseActionLockedBalance(payer, depositAmount);
            lockAmount -= depositAmount;
        }

        // use stake vault allowance if available and required
        if (lockAmount > 0) {
            uint256 balance = stakerVault.balanceOf(payer);
            uint256 allowance = stakerVault.allowance(payer, address(this));
            uint256 availableFunds = balance < allowance ? balance : allowance;
            if (availableFunds >= lockAmount) {
                stakerVault.transferFrom(payer, address(this), lockAmount);
                stakerVault.increaseActionLockedBalance(payer, lockAmount);
                lockAmount = 0;
            }
        }

        require(lockAmount == 0, Error.INSUFFICIENT_UPDATE_BALANCE);
    }

    /**
     * @dev Computes and returns the amount of LP tokens of type `token` that will be received in exchange for an `amount` of the underlying.
     */
    function calcExchangeAmount(
        IAddressProvider addressProvider,
        address token,
        address actionToken,
        uint256 amount
    ) external view returns (uint256) {
        ILiquidityPool pool = addressProvider.getPoolForToken(token);
        uint256 rate = pool.exchangeRate();
        address underlying = pool.getUnderlying();
        require(underlying == actionToken, Error.TOKEN_NOT_USABLE);
        return amount.scaledDivRoundUp(rate);
    }

    /**
     * @dev Approves infinite spending for the given spender.
     * @param token The token to approve for.
     * @param spender The spender to approve.
     */
    function _approve(address token, address spender) private {
        if (IERC20(token).allowance(address(this), spender) > 0) return;
        IERC20(token).safeApprove(spender, type(uint256).max);
    }
}

contract TopUpAction is ITopUpAction, Initializable, BaseAction {
    using ScaledMath for uint256;
    using UncheckedMath for uint256;
    using ScaledMath for uint128;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableExtensions for EnumerableSet.AddressSet;
    using AddressProviderHelpers for IAddressProvider;
    using SafeCast for uint256;

    /**
     * @dev Temporary struct to hold local variables in execute
     * and avoid the stack being "too deep"
     */
    struct ExecuteLocalVars {
        uint256 minActionAmountToTopUp;
        uint256 actionTokenAmount;
        uint256 depositTotalFeesAmount;
        uint256 actionAmountWithFees;
        uint256 userFactor;
        uint256 rate;
        uint256 depositAmountWithFees;
        uint256 depositAmountWithoutFees;
        uint256 actionFee;
        uint256 totalActionTokenAmount;
        uint128 totalTopUpAmount;
        bool topupResult;
        uint256 gasBankBalance;
        uint256 initialGas;
        uint256 gasConsumed;
        uint256 userGasPrice;
        uint256 estimatedRequiredGas;
        uint256 estimatedRequiredWeiForGas;
        uint256 requiredWeiForGas;
        uint256 reimbursedWeiForGas;
        address underlying;
        bool removePosition;
        address topUpHandler;
    }

    mapping(bytes32 => address) public topUpHandlers;
    uint256 internal constant _MAX_ACTION_FEE = 0.5e18;
    uint256 internal constant _MIN_MAX_FEE = 2e9;

    IController public immutable controller;
    IAddressProvider public immutable addressProvider;

    EnumerableSet.Bytes32Set internal _supportedProtocols;

    /// @notice mapping of (payer -> account -> protocol -> Record)
    mapping(address => mapping(bytes32 => mapping(bytes32 => Record))) private _positions;

    mapping(address => RecordMeta[]) internal _userPositions;

    EnumerableSet.AddressSet internal _usersWithPositions;

    uint256 public actionFee;
    address public feeHandler;
    uint256 public estimatedGasUsage = 550_000;

    event TopUpHandlerUpdated(bytes32 protocol, address newHandler);
    event ActionFeeUpdated(uint256 actionFee);
    event FeeHandlerUpdated(address feeHandler);
    event EstimatedGasUsageUpdated(uint256 estimatedGasUsage);

    constructor(IController _controller)
        Authorization(_controller.addressProvider().getRoleManager())
    {
        controller = _controller;
        addressProvider = controller.addressProvider();
    }

    receive() external payable {
        // solhint-disable-previous-line no-empty-blocks
    }

    function initialize(
        address feeHandler_,
        bytes32[] calldata protocols_,
        address[] calldata handlers_
    ) external initializer onlyGovernance {
        require(protocols_.length == handlers_.length, Error.INVALID_ARGUMENT);
        feeHandler = feeHandler_;
        for (uint256 i; i < protocols_.length; i = i.uncheckedInc()) {
            _updateTopUpHandler(protocols_[i], address(0), handlers_[i]);
        }
    }

    /**
     * @notice Register a top up action.
     * @dev The `depositAmount`, once converted to units of `actionToken`, must be greater or equal to the `totalTopUpAmount` (which is denominated in `actionToken`).
     * @param account Account to be topped up (first 20 bytes will typically be the address).
     * @param protocol Protocol which holds position to be topped up.
     * @param depositAmount Amount of `depositToken` that will be locked.
     * @param record containing the data for the position to register
     */
    function register(
        bytes32 account,
        bytes32 protocol,
        uint128 depositAmount,
        Record memory record
    ) external payable override notShutdown notPaused {
        require(record.maxFee >= _MIN_MAX_FEE, Error.INVALID_MAX_FEE);
        require(_supportedProtocols.contains(protocol), Error.PROTOCOL_NOT_FOUND);
        require(record.singleTopUpAmount > 0, Error.INVALID_AMOUNT);
        require(record.threshold > ScaledMath.ONE, Error.INVALID_AMOUNT);
        require(record.singleTopUpAmount <= record.totalTopUpAmount, Error.INVALID_AMOUNT);
        require(
            _positions[msg.sender][account][protocol].threshold == 0,
            Error.POSITION_ALREADY_EXISTS
        );
        require(_isSwappable(record.depositToken, record.actionToken), Error.SWAP_PATH_NOT_FOUND);
        require(isUsable(record.depositToken), Error.TOKEN_NOT_USABLE);

        uint256 gasDeposit = (record.totalTopUpAmount.divRoundUp(record.singleTopUpAmount)) *
            record.maxFee *
            estimatedGasUsage;

        require(msg.value >= gasDeposit, Error.VALUE_TOO_LOW_FOR_GAS);

        uint256 totalLockAmount = _calcExchangeAmount(
            record.depositToken,
            record.actionToken,
            record.totalTopUpAmount
        );
        _lockFunds(msg.sender, record.depositToken, totalLockAmount, depositAmount);

        addressProvider.getGasBank().depositFor{value: msg.value}(msg.sender);

        record.registeredAt = uint64(block.timestamp);
        record.depositTokenBalance = totalLockAmount.toUint128();
        _positions[msg.sender][account][protocol] = record;
        _userPositions[msg.sender].push(RecordMeta(account, protocol));
        _usersWithPositions.add(msg.sender);

        emit Register(
            account,
            protocol,
            record.threshold,
            msg.sender,
            record.depositToken,
            totalLockAmount,
            record.actionToken,
            record.singleTopUpAmount,
            record.totalTopUpAmount,
            record.maxFee,
            record.extra
        );
    }

    /**
     * @notice See overloaded version of `execute` for more details.
     */
    function execute(
        address payer,
        bytes32 account,
        address beneficiary,
        bytes32 protocol
    ) external override notShutdown notPaused {
        execute(payer, account, beneficiary, protocol, 0);
    }

    /**
     * @notice Delete a position to back on the given protocol for `account`.
     * @param account Account holding the position.
     * @param protocol Protocol the position is held on.
     * @param unstake If the tokens should be unstaked from vault.
     */
    function resetPosition(
        bytes32 account,
        bytes32 protocol,
        bool unstake
    ) external override {
        address payer = msg.sender;
        Record memory position = _positions[payer][account][protocol];
        require(position.threshold != 0, Error.NO_POSITION_EXISTS);

        IAddressProvider addressProvider_ = addressProvider;
        address vault = addressProvider_.getStakerVault(position.depositToken); // will revert if vault does not exist
        IStakerVault staker = IStakerVault(vault);
        staker.decreaseActionLockedBalance(payer, position.depositTokenBalance);
        if (unstake) {
            staker.unstake(position.depositTokenBalance);
            IERC20(position.depositToken).safeTransfer(payer, position.depositTokenBalance);
        } else {
            staker.transfer(payer, position.depositTokenBalance);
        }

        _removePosition(payer, account, protocol);
        addressProvider_.getGasBank().withdrawUnused(payer);
    }

    /**
     * @notice Updates the TopUp Handler.
     * @param protocol Protocol for which a new handler should be executed.
     * @param newHandler The new TopUp Handler.
     */
    function updateTopUpHandler(bytes32 protocol, address newHandler)
        external
        override
        onlyGovernance
    {
        address oldHandler = _getHandler(protocol, false);
        _updateTopUpHandler(protocol, oldHandler, newHandler);
        emit TopUpHandlerUpdated(protocol, newHandler);
    }

    /**
     * @notice Update action fee.
     * @param actionFee_ New fee to set.
     */
    function updateActionFee(uint256 actionFee_) external override onlyGovernance {
        require(actionFee_ <= _MAX_ACTION_FEE, Error.INVALID_AMOUNT);
        actionFee = actionFee_;
        emit ActionFeeUpdated(actionFee_);
    }

    /**
     * @notice Update Fee Handler.
     * @param feeHandler_ New Fee Handler.
     */
    function updateFeeHandler(address feeHandler_) external override onlyGovernance {
        feeHandler = feeHandler_;
        emit FeeHandlerUpdated(feeHandler_);
    }

    /**
     * @notice Update the estimated gas usage.
     * @param estimatedGasUsage_ New estimated gas usage.
     */
    function updateEstimatedGasUsage(uint256 estimatedGasUsage_) external override onlyGovernance {
        estimatedGasUsage = estimatedGasUsage_;
        emit EstimatedGasUsageUpdated(estimatedGasUsage_);
    }

    /**
     * @notice Computes the total amount of ETH (as wei) required to pay for all
     * the top-ups assuming the maximum gas price and the current estimated gas
     * usage of a top-up
     */
    function getEthRequiredForGas(address payer) external view override returns (uint256) {
        uint256 totalEthRequired;
        RecordMeta[] memory userRecordsMeta = _userPositions[payer];
        uint256 gasUsagePerCall = estimatedGasUsage;
        uint256 length = userRecordsMeta.length;
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            RecordMeta memory meta = userRecordsMeta[i];
            Record memory record = _positions[payer][meta.account][meta.protocol];
            uint256 totalCalls = record.totalTopUpAmount.divRoundUp(record.singleTopUpAmount);
            totalEthRequired += totalCalls * gasUsagePerCall * record.maxFee;
        }
        return totalEthRequired;
    }

    /**
     * @notice Returns a list of positions for the given payer
     */
    function getUserPositions(address payer) external view override returns (RecordMeta[] memory) {
        return _userPositions[payer];
    }

    /**
     * @notice Get a list supported protocols.
     * @return List of supported protocols.
     */
    function getSupportedProtocols() external view override returns (bytes32[] memory) {
        uint256 length = _supportedProtocols.length();
        bytes32[] memory protocols = new bytes32[](length);
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            protocols[i] = _supportedProtocols.at(i);
        }
        return protocols;
    }

    /*
     * @notice Gets a list of users that have an active position.
     * @dev Uses cursor pagination.
     * @param cursor The cursor for pagination (should start at 0 for first call).
     * @param howMany Maximum number of users to return in this pagination request.
     * @return users List of users that have an active position.
     * @return nextCursor The cursor to use for the next pagination request.
     */
    function usersWithPositions(uint256 cursor, uint256 howMany)
        external
        view
        override
        returns (address[] memory users, uint256 nextCursor)
    {
        uint256 length = _usersWithPositions.length();
        if (cursor >= length) return (new address[](0), 0);
        if (howMany >= length - cursor) {
            howMany = length - cursor;
        }

        address[] memory usersWithPositions_ = new address[](howMany);
        for (uint256 i; i < howMany; i = i.uncheckedInc()) {
            usersWithPositions_[i] = _usersWithPositions.at(i + cursor);
        }

        return (usersWithPositions_, cursor + howMany);
    }

    /**
     * @notice Retrieves the topup handler for the given `protocol`
     */
    function getTopUpHandler(bytes32 protocol) external view override returns (address) {
        return _getHandler(protocol, false);
    }

    /**
     * @notice Successfully tops up a position if it's conditions are met.
     * @dev pool and vault funds are rebalanced after withdrawal for top up
     * @param payer Account that pays for the top up.
     * @param account Account owning the position for top up.
     * @param beneficiary Address of the keeper's wallet for fee accrual.
     * @param protocol Protocol of the top up position.
     * @param maxWeiForGas the maximum extra amount of wei that the keeper is willing to pay for the gas
     */
    function execute(
        address payer,
        bytes32 account,
        address beneficiary,
        bytes32 protocol,
        uint256 maxWeiForGas
    ) public override notShutdown notPaused {
        require(controller.canKeeperExecuteAction(msg.sender), Error.NOT_ENOUGH_MERO_STAKED);

        ExecuteLocalVars memory vars;

        vars.initialGas = gasleft();

        Record storage position = _positions[payer][account][protocol];
        require(position.threshold != 0, Error.NO_POSITION_EXISTS);
        require(position.totalTopUpAmount > 0, Error.INSUFFICIENT_BALANCE);
        require(block.timestamp > position.registeredAt, Error.CANNOT_EXECUTE_IN_SAME_BLOCK);

        vars.topUpHandler = _getHandler(protocol, true);
        vars.userFactor = ITopUpHandler(vars.topUpHandler).getUserFactor(account, position.extra);

        // ensure that the position is actually below its set user factor threshold
        require(vars.userFactor < position.threshold, Error.INSUFFICIENT_THRESHOLD);

        IAddressProvider addressProvider_ = addressProvider;
        IGasBank gasBank = addressProvider_.getGasBank();

        // fail early if the user does not have enough funds in the gas bank
        // to cover the cost of the transaction
        vars.estimatedRequiredGas = estimatedGasUsage;
        vars.estimatedRequiredWeiForGas = vars.estimatedRequiredGas * tx.gasprice;

        // compute the gas price that the user will be paying
        vars.userGasPrice = block.basefee + position.priorityFee;
        if (vars.userGasPrice > tx.gasprice) vars.userGasPrice = tx.gasprice;
        if (vars.userGasPrice > position.maxFee) vars.userGasPrice = position.maxFee;

        // ensure the current position allows for the gas to be paid
        require(
            vars.estimatedRequiredWeiForGas <=
                vars.estimatedRequiredGas * vars.userGasPrice + maxWeiForGas,
            Error.ESTIMATED_GAS_TOO_HIGH
        );

        vars.gasBankBalance = gasBank.balanceOf(payer);
        // ensure the user has enough funds in the gas bank to cover the gas
        require(
            vars.gasBankBalance + maxWeiForGas >= vars.estimatedRequiredWeiForGas,
            Error.GAS_BANK_BALANCE_TOO_LOW
        );

        vars.totalTopUpAmount = position.totalTopUpAmount;
        vars.actionFee = actionFee;
        // add top-up fees to top-up amount
        vars.minActionAmountToTopUp = position.singleTopUpAmount;
        vars.actionAmountWithFees = vars.minActionAmountToTopUp.scaledMul(
            ScaledMath.ONE + vars.actionFee
        );

        // if the amount that we want to top-up (including fees) is higher than
        // the available topup amount, we lower this down to what is left of the position
        if (vars.actionAmountWithFees > vars.totalTopUpAmount) {
            vars.actionAmountWithFees = vars.totalTopUpAmount;
            vars.minActionAmountToTopUp = vars.actionAmountWithFees.scaledDiv(
                ScaledMath.ONE + vars.actionFee
            );
        }
        ILiquidityPool pool = addressProvider_.getPoolForToken(position.depositToken);
        vars.underlying = pool.getUnderlying();
        vars.rate = pool.exchangeRate();

        // compute the deposit tokens amount with and without fees
        // we will need to unstake the amount with fees and to
        // swap the amount without fees into action tokens
        vars.depositAmountWithFees = vars.actionAmountWithFees.scaledDivRoundUp(vars.rate);
        if (position.depositTokenBalance < vars.depositAmountWithFees) {
            vars.depositAmountWithFees = position.depositTokenBalance;
            vars.minActionAmountToTopUp =
                (vars.depositAmountWithFees * vars.rate) /
                (ScaledMath.ONE + vars.actionFee);
        }

        // compute amount of LP tokens needed to pay for action
        // rate is expressed in actionToken per depositToken
        vars.depositAmountWithoutFees = vars.minActionAmountToTopUp.scaledDivRoundUp(vars.rate);
        vars.depositTotalFeesAmount = vars.depositAmountWithFees - vars.depositAmountWithoutFees;

        // will revert if vault does not exist
        address vault = addressProvider_.getStakerVault(position.depositToken);

        // unstake deposit tokens including fees
        IStakerVault(vault).unstake(vars.depositAmountWithFees);
        IStakerVault(vault).decreaseActionLockedBalance(payer, vars.depositAmountWithFees);

        // swap the amount without the fees
        // as the fees are paid in deposit token, not in action token
        vars.actionTokenAmount = pool.redeem(vars.depositAmountWithoutFees);

        // compute how much of action token was actually redeemed and add fees to it
        // this is to ensure that no funds get locked inside the contract
        vars.totalActionTokenAmount =
            vars.actionTokenAmount +
            vars.depositTotalFeesAmount.scaledMul(vars.rate);

        // at this point, we have exactly `vars.actionTokenAmount`
        // (at least `position.singleTopUpAmount`) of action token
        // and exactly `vars.depositTotalFeesAmount` deposit tokens in the contract
        // solhint-disable-next-line avoid-low-level-calls
        uint256 value_;
        if (position.actionToken == address(0)) {
            value_ = vars.actionTokenAmount;
        } else {
            _approve(position.actionToken, vars.topUpHandler);
        }
        ITopUpHandler(vars.topUpHandler).topUp{value: value_}(
            account,
            position.actionToken,
            vars.actionTokenAmount,
            position.extra
        );

        // totalTopUpAmount is updated to reflect the new "balance" of the position
        if (vars.totalTopUpAmount > vars.totalActionTokenAmount) {
            position.totalTopUpAmount -= vars.totalActionTokenAmount.toUint128();
        } else {
            position.totalTopUpAmount = 0;
        }

        position.depositTokenBalance -= vars.depositAmountWithFees.toUint128();

        vars.removePosition = position.totalTopUpAmount == 0 || position.depositTokenBalance == 0;
        _payFees(payer, beneficiary, vars.depositTotalFeesAmount, position.depositToken);
        if (vars.removePosition) {
            if (position.depositTokenBalance > 0) {
                // transfer any unused locked tokens to the payer
                IStakerVault(vault).transfer(payer, position.depositTokenBalance);
                IStakerVault(vault).decreaseActionLockedBalance(
                    payer,
                    position.depositTokenBalance
                );
            }
            _removePosition(payer, account, protocol);
        }

        emit TopUp(
            account,
            protocol,
            payer,
            position.depositToken,
            vars.depositAmountWithFees,
            position.actionToken,
            vars.actionTokenAmount
        );

        // compute gas used and reimburse the keeper by using the
        // funds of payer in the gas bank
        // TODO: add constant gas consumed for transfer and tx prologue
        vars.gasConsumed = vars.initialGas - gasleft();

        vars.reimbursedWeiForGas = vars.userGasPrice * vars.gasConsumed;
        if (vars.reimbursedWeiForGas > vars.gasBankBalance) {
            vars.reimbursedWeiForGas = vars.gasBankBalance;
        }

        // ensure that the keeper is not overpaying
        vars.requiredWeiForGas = tx.gasprice * vars.gasConsumed;
        require(
            vars.reimbursedWeiForGas + maxWeiForGas >= vars.requiredWeiForGas,
            Error.GAS_TOO_HIGH
        );
        gasBank.withdrawFrom(payer, payable(msg.sender), vars.reimbursedWeiForGas);
        if (vars.removePosition) {
            gasBank.withdrawUnused(payer);
        }
    }

    /**
     * @notice Check if action can be executed.
     * @param protocol for which to get the health factor
     * @param account for which to get the health factor
     * @param extra data to be used by the topup handler
     * @return healthFactor of the position
     */
    function getHealthFactor(
        bytes32 protocol,
        bytes32 account,
        bytes calldata extra
    ) public view override returns (uint256 healthFactor) {
        ITopUpHandler topUpHandler_ = ITopUpHandler(_getHandler(protocol, true));
        return topUpHandler_.getUserFactor(account, extra);
    }

    function getHandler(bytes32 protocol) public view override returns (address) {
        return _getHandler(protocol, false);
    }

    /**
     * @notice Get the record for a position.
     * @param payer Registered payer of the position.
     * @param account Address holding the position.
     * @param protocol Protocol where the position is held.
     */
    function getPosition(
        address payer,
        bytes32 account,
        bytes32 protocol
    ) public view override returns (Record memory) {
        return _positions[payer][account][protocol];
    }

    function _updateTopUpHandler(
        bytes32 protocol,
        address oldHandler,
        address newHandler
    ) internal {
        topUpHandlers[protocol] = newHandler;
        if (newHandler == address(0)) {
            _supportedProtocols.remove(protocol);
        } else if (oldHandler == address(0)) {
            _supportedProtocols.add(protocol);
        }
    }

    /**
     * @dev Pays fees to the feeHandler
     * @param payer The account who's position the fees are charged on
     * @param beneficiary The beneficiary of the fees paid (usually this will be the keeper)
     * @param feeAmount The amount in tokens to pay as fees
     * @param depositToken The LpToken used to pay the fees
     */
    function _payFees(
        address payer,
        address beneficiary,
        uint256 feeAmount,
        address depositToken
    ) internal {
        address feeHandler_ = feeHandler;
        IERC20(depositToken).safeApprove(feeHandler_, feeAmount);
        IActionFeeHandler(feeHandler_).payFees(payer, beneficiary, feeAmount, depositToken);
    }

    /**
     * @dev "Locks" an amount of tokens on behalf of the TopUpAction
     * Funds are taken from staker vault if allowance is sufficient, else direct transfer or a combination of both.
     * @param payer Owner of the funds to be locked
     * @param token Token to lock
     * @param lockAmount Minimum amount of `token` to lock
     * @param depositAmount Amount of `token` that was deposited.
     *                      If this is 0 then the staker vault allowance should be used.
     *                      If this is greater than `requiredAmount` more tokens will be locked.
     */
    function _lockFunds(
        address payer,
        address token,
        uint256 lockAmount,
        uint256 depositAmount
    ) internal {
        address stakerVaultAddress = addressProvider.getStakerVault(token);
        TopUpActionLibrary.lockFunds(stakerVaultAddress, payer, token, lockAmount, depositAmount);
    }

    function _removePosition(
        address payer,
        bytes32 account,
        bytes32 protocol
    ) internal {
        delete _positions[payer][account][protocol];
        _removeUserPosition(payer, account, protocol);
        if (_userPositions[payer].length == 0) {
            _usersWithPositions.remove(payer);
        }
        emit Deregister(payer, account, protocol);
    }

    function _removeUserPosition(
        address payer,
        bytes32 account,
        bytes32 protocol
    ) internal {
        RecordMeta[] storage positionsMeta = _userPositions[payer];
        uint256 length = positionsMeta.length;
        for (uint256 i; i < length; i = i.uncheckedInc()) {
            RecordMeta storage positionMeta = positionsMeta[i];
            if (positionMeta.account == account && positionMeta.protocol == protocol) {
                positionsMeta[i] = positionsMeta[length - 1];
                positionsMeta.pop();
                return;
            }
        }
    }

    /**
     * @dev Approves infinite spending for the given spender.
     * @param token The token to approve for.
     * @param spender The spender to approve.
     */
    function _approve(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) > 0) return;
        IERC20(token).safeApprove(spender, type(uint256).max);
    }

    /**
     * @dev Computes and returns the amount of LP tokens of type `token` that will be received in exchange for an `amount` of the `actionToken`.
     */
    function _calcExchangeAmount(
        address token,
        address actionToken,
        uint256 amount
    ) internal view returns (uint256) {
        return TopUpActionLibrary.calcExchangeAmount(addressProvider, token, actionToken, amount);
    }

    function _getHandler(bytes32 protocol, bool ensureExists) internal view returns (address) {
        address handler = topUpHandlers[protocol];
        require(!ensureExists || handler != address(0), Error.PROTOCOL_NOT_FOUND);
        return handler;
    }

    function _isSwappable(address depositToken, address toToken) internal view returns (bool) {
        ILiquidityPool pool = addressProvider.getPoolForToken(depositToken);
        return pool.getUnderlying() == toToken;
    }
}
