// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/ScaledMath.sol";
import "../libraries/Errors.sol";
import "../libraries/EnumerableExtensions.sol";
import "../libraries/UncheckedMath.sol";
import "../interfaces/IMeroLocker.sol";
import "../interfaces/tokenomics/IMigrationContract.sol";
import "./access/Authorization.sol";

contract MeroLocker is IMeroLocker, Authorization {
    using ScaledMath for uint256;
    using UncheckedMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableMapping for EnumerableMapping.AddressToUintMap;
    using EnumerableExtensions for EnumerableMapping.AddressToUintMap;

    struct AccountInfo {
        uint128 balance;
        uint128 totalStashed;
        uint64 boostFactor;
        uint64 lastUpdated;
        WithdrawStash[] stashedGovTokens;
    }

    uint256 public startBoost;
    uint256 public maxBoost;
    uint256 public increasePeriod;
    uint256 public withdrawalDelay;

    // User-specific data
    mapping(address => AccountInfo) public accountInfo;

    // Global data
    uint256 public totalLocked;
    uint256 public totalLockedBoosted;
    uint256 public lastMigrationEvent;
    bool private _initialized;
    EnumerableMapping.AddressToUintMap private _replacedRewardTokens;

    // Reward token data
    mapping(address => RewardTokenData) public rewardTokenData;
    address public override rewardToken;
    IERC20 public immutable govToken;

    event Migrated(address newRewardToken);
    event StartBoostUpdated(uint256 newStartBoost);
    event IncreasePeriodUpdated(uint256 newIncreasePeriod);
    event WithdrawalDelayUpdated(uint256 newWithdrawalDelay);

    constructor(
        address _rewardToken,
        address _govToken,
        IRoleManager roleManager
    ) Authorization(roleManager) {
        rewardToken = _rewardToken;
        govToken = IERC20(_govToken);
    }

    function initialize(
        uint256 startBoost_,
        uint256 maxBoost_,
        uint256 increasePeriod_,
        uint256 withdrawDelay_
    ) external override onlyGovernance {
        require(!_initialized, Error.CONTRACT_INITIALIZED);
        startBoost = startBoost_;
        maxBoost = maxBoost_;
        increasePeriod = increasePeriod_;
        withdrawalDelay = withdrawDelay_;
        _initialized = true;
    }

    /**
     * @notice Sets a new token to be the rewardToken. Fees are then accumulated in this token.
     * @dev Previously used rewardTokens can be set again here.
     */
    function migrate(address newRewardToken) external override onlyGovernance {
        require(newRewardToken != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        _replacedRewardTokens.set(rewardToken, block.timestamp);
        _replacedRewardTokens.remove(newRewardToken);
        lastMigrationEvent = block.timestamp;
        rewardToken = newRewardToken;
        emit Migrated(newRewardToken);
    }

    /**
     * @notice Lock gov. tokens.
     * @dev The amount needs to be approved in advance.
     */
    function lock(uint256 amount) external override {
        return lockFor(msg.sender, amount);
    }

    /**
     * @notice Deposit fees (in the rewardToken) to be distributed to lockers of gov. tokens.
     * @dev `deposit` or `depositFor` needs to be called at least once before this function can be called
     * @param amount Amount of rewardToken to deposit.
     */
    function depositFees(uint256 amount) external override {
        require(amount > 0, Error.INVALID_AMOUNT);
        require(totalLockedBoosted > 0, Error.NOT_ENOUGH_FUNDS);
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);

        RewardTokenData storage curRewardTokenData = rewardTokenData[rewardToken];

        curRewardTokenData.feeIntegral += amount.scaledDiv(totalLockedBoosted);
        curRewardTokenData.feeBalance += amount;
        emit FeesDeposited(amount);
    }

    function claimFees() external override {
        claimFees(rewardToken);
    }

    /**
     * @notice Checkpoint function to update user data, in particular the boost factor.
     */
    function userCheckpoint(address user) external override {
        _userCheckpoint(user, 0, accountInfo[user].balance);
    }

    /**
     * @notice Prepare unlocking of locked gov. tokens.
     * @dev A delay is enforced and unlocking can only be executed after that.
     * @param amount Amount of gov. tokens to prepare for unlocking.
     */
    function prepareUnlock(uint256 amount) external override {
        AccountInfo memory accountInfo_ = accountInfo[msg.sender];
        require(
            accountInfo_.totalStashed + amount <= accountInfo_.balance,
            "Amount exceeds locked balance"
        );
        accountInfo[msg.sender].totalStashed += uint128(amount);
        accountInfo[msg.sender].stashedGovTokens.push(
            WithdrawStash(block.timestamp + withdrawalDelay, amount)
        );
        emit WithdrawPrepared(msg.sender, amount);
    }

    /**
     * @notice Execute all prepared gov. token withdrawals.
     */
    function executeUnlocks() external override {
        uint256 totalAvailableToWithdraw;
        AccountInfo memory accountInfo_ = accountInfo[msg.sender];
        WithdrawStash[] storage stashedWithdraws = accountInfo[msg.sender].stashedGovTokens;
        uint256 length = stashedWithdraws.length;
        require(length > 0, "No entries");
        uint256 i = length;
        while (i > 0) {
            i = i.uncheckedSub(1);
            if (stashedWithdraws[i].releaseTime <= block.timestamp) {
                totalAvailableToWithdraw += stashedWithdraws[i].amount;

                stashedWithdraws[i] = stashedWithdraws[stashedWithdraws.length.uncheckedSub(1)];

                stashedWithdraws.pop();
            }
        }
        accountInfo[msg.sender].totalStashed -= uint128(totalAvailableToWithdraw);
        uint256 newTotal = accountInfo_.balance - totalAvailableToWithdraw;
        _userCheckpoint(msg.sender, 0, newTotal);
        totalLocked -= totalAvailableToWithdraw;
        govToken.safeTransfer(msg.sender, totalAvailableToWithdraw);
        emit WithdrawExecuted(msg.sender, totalAvailableToWithdraw);
    }

    /**
     * @notice Updates the start boost.
     * @dev Values won't be updated per user until their next checkpoint.
     * @param startBoost_ The new start boost.
     */
    function updateStartBoost(uint256 startBoost_) external override onlyGovernance {
        startBoost = startBoost_;
        emit StartBoostUpdated(startBoost);
    }

    /**
     * @notice Updates the increase period.
     * @dev Values won't be updated per user until their next checkpoint.
     * @param increasePeriod_ The new increase period.
     */
    function updateIncreasePeriod(uint256 increasePeriod_) external override onlyGovernance {
        increasePeriod = increasePeriod_;
        emit IncreasePeriodUpdated(increasePeriod);
    }

    /**
     * @notice Updates the withdrawal delay.
     * @param withdrawalDelay_ The new withdrawal delay.
     */
    function updateWithdrawalDelay(uint256 withdrawalDelay_) external override onlyGovernance {
        withdrawalDelay = withdrawalDelay_;
        emit WithdrawalDelayUpdated(withdrawalDelay);
    }

    function getUserShare(address user) external view override returns (uint256) {
        return getUserShare(user, rewardToken);
    }

    /**
     * @notice Get the boosted locked balance for a user.
     * @dev This includes the gov. tokens queued for withdrawal.
     * @param user Address to get the boosted balance for.
     * @return boosted balance for user.
     */
    function boostedBalance(address user) external view override returns (uint256) {
        return uint256(accountInfo[user].balance).scaledMul(accountInfo[user].boostFactor);
    }

    /**
     * @notice Get the vote weight for a user.
     * @dev This does not include the gov. tokens queued for withdrawal.
     * @param user Address to get the vote weight for.
     * @return vote weight for user.
     */
    function balanceOf(address user) external view override returns (uint256) {
        AccountInfo memory accountInfo_ = accountInfo[user];
        return
            (uint256(accountInfo_.balance) - uint256(accountInfo_.totalStashed)).scaledMul(
                accountInfo[user].boostFactor
            );
    }

    /**
     * @notice Get the share of the total boosted locked balance for a user.
     * @dev This includes the gov. tokens queued for withdrawal.
     * @param user Address to get the share of the total boosted balance for.
     * @return share of the total boosted balance for user.
     */
    function getShareOfTotalBoostedBalance(address user) external view override returns (uint256) {
        AccountInfo memory accountInfo_ = accountInfo[user];
        return
            uint256(accountInfo_.balance).scaledMul(accountInfo_.boostFactor).scaledDiv(
                totalLockedBoosted
            );
    }

    function getStashedGovTokens(address user)
        external
        view
        override
        returns (WithdrawStash[] memory)
    {
        return accountInfo[user].stashedGovTokens;
    }

    function claimableFees(address user) external view override returns (uint256) {
        return claimableFees(user, rewardToken);
    }

    /**
     * @notice Claim fees accumulated in the Locker.
     */
    function claimFees(address _rewardToken) public override {
        require(
            _rewardToken == rewardToken || _replacedRewardTokens.contains(_rewardToken),
            Error.INVALID_ARGUMENT
        );
        _userCheckpoint(msg.sender, 0, accountInfo[msg.sender].balance);
        RewardTokenData storage curRewardTokenData = rewardTokenData[_rewardToken];
        uint256 claimable = curRewardTokenData.userShares[msg.sender];
        delete curRewardTokenData.userShares[msg.sender];
        curRewardTokenData.feeBalance -= claimable;
        IERC20(_rewardToken).safeTransfer(msg.sender, claimable);
        emit RewardsClaimed(msg.sender, _rewardToken, claimable);
    }

    /**
     * @notice Lock gov. tokens on behalf of another user.
     * @dev The amount needs to be approved in advance.
     * @param user Address of user to lock on behalf of.
     * @param amount Amount of gov. tokens to lock.
     */
    function lockFor(address user, uint256 amount) public override {
        require(user != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        govToken.safeTransferFrom(msg.sender, address(this), amount);
        _userCheckpoint(user, amount, accountInfo[user].balance + amount);
        totalLocked += amount;
        emit Locked(user, amount);
    }

    function getUserShare(address user, address _rewardToken)
        public
        view
        override
        returns (uint256)
    {
        return rewardTokenData[_rewardToken].userShares[user];
    }

    function claimableFees(address user, address _rewardToken)
        public
        view
        override
        returns (uint256)
    {
        uint256 currentShare;
        AccountInfo memory accountInfo_ = accountInfo[user];
        RewardTokenData storage curRewardTokenData = rewardTokenData[_rewardToken];

        // Compute the share earned by the user since they last updated
        if (accountInfo_.balance > 0) {
            currentShare += (curRewardTokenData.feeIntegral -
                curRewardTokenData.userFeeIntegrals[user]).scaledMul(
                    uint256(accountInfo_.balance).scaledMul(accountInfo_.boostFactor)
                );
        }
        return curRewardTokenData.userShares[user] + currentShare;
    }

    function computeNewBoost(
        address user,
        uint256 amountAdded,
        uint256 newTotal
    ) public view override returns (uint256) {
        uint256 newBoost;
        AccountInfo memory accountInfo_ = accountInfo[user];
        uint256 startBoost_ = startBoost;
        if (accountInfo_.balance == 0 || newTotal == 0) {
            newBoost = startBoost_;
        } else {
            uint256 maxBoost_ = maxBoost;
            newBoost = accountInfo_.boostFactor;
            newBoost += (block.timestamp - accountInfo_.lastUpdated)
                .scaledDiv(increasePeriod)
                .scaledMul(maxBoost_ - startBoost_);
            if (newBoost > maxBoost_) {
                newBoost = maxBoost_;
            }
            if (newTotal <= accountInfo_.balance) {
                return newBoost;
            }
            newBoost =
                newBoost.scaledMul(uint256(accountInfo_.balance).scaledDiv(newTotal)) +
                startBoost_.scaledMul(amountAdded.scaledDiv(newTotal));
        }
        return newBoost;
    }

    function _userCheckpoint(
        address user,
        uint256 amountAdded,
        uint256 newTotal
    ) internal {
        RewardTokenData storage curRewardTokenData = rewardTokenData[rewardToken];

        // Compute the share earned by the user since they last updated
        AccountInfo memory accountInfo_ = accountInfo[user];
        if (accountInfo_.balance > 0) {
            curRewardTokenData.userShares[user] += (curRewardTokenData.feeIntegral -
                curRewardTokenData.userFeeIntegrals[user]).scaledMul(
                    uint256(accountInfo_.balance).scaledMul(accountInfo_.boostFactor)
                );

            // Update values for previous rewardTokens
            if (accountInfo_.lastUpdated < lastMigrationEvent) {
                uint256 length = _replacedRewardTokens.length();
                for (uint256 i; i < length; i = i.uncheckedInc()) {
                    (address token, uint256 replacedAt) = _replacedRewardTokens.at(i);
                    if (accountInfo_.lastUpdated < replacedAt) {
                        RewardTokenData storage prevRewardTokenData = rewardTokenData[token];
                        prevRewardTokenData.userShares[user] += (prevRewardTokenData.feeIntegral -
                            prevRewardTokenData.userFeeIntegrals[user]).scaledMul(
                                uint256(accountInfo_.balance).scaledMul(accountInfo_.boostFactor)
                            );
                        prevRewardTokenData.userFeeIntegrals[user] = prevRewardTokenData
                            .feeIntegral;
                    }
                }
            }
        }

        uint256 newBoost = computeNewBoost(user, amountAdded, newTotal);
        accountInfo_ = accountInfo[user];
        totalLockedBoosted =
            totalLockedBoosted +
            newTotal.scaledMul(newBoost) -
            uint256(accountInfo_.balance).scaledMul(accountInfo_.boostFactor);

        // Update user values
        curRewardTokenData.userFeeIntegrals[user] = curRewardTokenData.feeIntegral;
        accountInfo[user].lastUpdated = uint64(block.timestamp);
        accountInfo[user].boostFactor = uint64(newBoost);
        accountInfo[user].balance = uint128(newTotal);
    }
}
