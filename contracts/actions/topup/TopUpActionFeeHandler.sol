// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../../../interfaces/actions/IActionFeeHandler.sol";
import "../../../interfaces/IController.sol";
import "../../../interfaces/tokenomics/IKeeperGauge.sol";

import "../../../libraries/Errors.sol";
import "../../../libraries/ScaledMath.sol";
import "../../../libraries/AddressProviderHelpers.sol";

import "../../LpToken.sol";
import "../../access/Authorization.sol";
import "../../pool/LiquidityPool.sol";

/**
 * @notice Contract to manage the distribution of protocol fees
 */
contract TopUpActionFeeHandler is IActionFeeHandler, Authorization {
    using ScaledMath for uint256;
    using SafeERC20Upgradeable for LpToken;
    using AddressProviderHelpers for IAddressProvider;

    address public immutable actionContract;
    IController public immutable controller;

    mapping(address => uint256) public treasuryAmounts;
    mapping(address => mapping(address => uint256)) public keeperRecords;
    mapping(address => address) public keeperGauges;
    uint256 public keeperFeeFraction;
    uint256 public treasuryFeeFraction;

    event KeeperFeesClaimed(address indexed keeper, address token, uint256 totalClaimed);
    event KeeperFeeUpdated(uint256 keeperFee);
    event KeeperGaugeUpdated(address lpToken, address keeperGauge);
    event TreasuryFeeUpdated(uint256 treasuryFee_);

    event FeesPayed(
        address indexed payer,
        address indexed keeper,
        address token,
        uint256 amount,
        uint256 keeperAmount,
        uint256 lpAmount
    );

    constructor(
        IController _controller,
        address _actionContract,
        uint256 keeperFee,
        uint256 treasuryFee
    ) Authorization(_controller.addressProvider().getRoleManager()) {
        require(keeperFee + treasuryFee <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        actionContract = _actionContract;
        controller = _controller;
        keeperFeeFraction = keeperFee;
        treasuryFeeFraction = treasuryFee;
    }

    function setInitialKeeperGaugeForToken(address lpToken_, address keeperGauge_)
        external
        override
        onlyGovernance
    {
        require(getKeeperGauge(lpToken_) == address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        require(keeperGauge_ != address(0), Error.ZERO_ADDRESS_NOT_ALLOWED);
        keeperGauges[lpToken_] = keeperGauge_;
    }

    /**
     * @notice Transfers the keeper and treasury fees to the fee handler and burns LP fees.
     * @param payer Account who's position the fees are charged on.
     * @param beneficiary Beneficiary of the fees paid (usually this will be the keeper).
     * @param amount Total fee value (both keeper and LP fees).
     * @param lpTokenAddress Address of the lpToken used to pay fees.
     */
    function payFees(
        address payer,
        address beneficiary,
        uint256 amount,
        address lpTokenAddress
    ) external override {
        require(msg.sender == actionContract, Error.UNAUTHORIZED_ACCESS);
        // Handle keeper fees
        uint256 keeperAmount = amount.scaledMul(keeperFeeFraction);
        uint256 treasuryAmount = amount.scaledMul(treasuryFeeFraction);
        LpToken lpToken = LpToken(lpTokenAddress);

        lpToken.safeTransferFrom(msg.sender, address(this), amount);

        address keeperGauge = getKeeperGauge(lpTokenAddress);
        if (keeperGauge != address(0)) {
            IKeeperGauge(keeperGauge).reportFees(beneficiary, keeperAmount, lpTokenAddress);
        }

        // Accrue keeper and treasury fees here for periodic claiming
        keeperRecords[beneficiary][lpTokenAddress] += keeperAmount;
        treasuryAmounts[lpTokenAddress] += treasuryAmount;

        // Handle LP fees
        uint256 lpAmount = amount - keeperAmount - treasuryAmount;
        lpToken.burn(lpAmount);
        emit FeesPayed(payer, beneficiary, lpTokenAddress, amount, keeperAmount, lpAmount);
    }

    /**
     * @notice Claim all accrued fees for an LPToken.
     * @param beneficiary Address to claim the fees for.
     * @param token Address of the lpToken for claiming.
     */
    function claimKeeperFeesForPool(address beneficiary, address token) external override {
        uint256 totalClaimable = keeperRecords[beneficiary][token];
        require(totalClaimable > 0, Error.NOTHING_TO_CLAIM);
        keeperRecords[beneficiary][token] = 0;

        LpToken lpToken = LpToken(token);
        lpToken.safeTransfer(beneficiary, totalClaimable);

        emit KeeperFeesClaimed(beneficiary, token, totalClaimable);
    }

    /**
     * @notice Claim all accrued treasury fees for an LPToken.
     * @param token Address of the lpToken for claiming.
     */
    function claimTreasuryFees(address token) external override {
        uint256 claimable = treasuryAmounts[token];
        treasuryAmounts[token] = 0;
        LpToken(token).safeTransfer(controller.addressProvider().getRewardHandler(), claimable);
    }

    /**
     * @notice Update keeper fee.
     * @param keeperFee_ New keeper fee value.
     */
    function updateKeeperFee(uint256 keeperFee_) external override onlyGovernance {
        require(keeperFee_ <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        require(treasuryFeeFraction + keeperFee_ <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        keeperFeeFraction = keeperFee_;
        emit KeeperFeeUpdated(keeperFee_);
    }

    /**
     * @notice Update the Keeper Gauge for a given LP Token.
     * @param lpToken_ The LP Token to update the Keeper Gauge for.
     * @param keeperGauge_ New keeper fee value.
     */
    function updateKeeperGauge(address lpToken_, address keeperGauge_)
        external
        override
        onlyGovernance
    {
        if (keeperGauge_ == address(0)) {
            delete keeperGauges[lpToken_];
            return;
        }
        keeperGauges[lpToken_] = keeperGauge_;
        emit KeeperGaugeUpdated(lpToken_, keeperGauge_);
    }

    /**
     * @notice Update treasury fee.
     * @param treasuryFee_ New treasury fee value.
     */
    function updateTreasuryFee(uint256 treasuryFee_) external override onlyGovernance {
        require(treasuryFee_ <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        require(treasuryFee_ + keeperFeeFraction <= ScaledMath.ONE, Error.INVALID_AMOUNT);
        treasuryFeeFraction = treasuryFee_;
        emit TreasuryFeeUpdated(treasuryFee_);
    }

    function getKeeperGauge(address lpToken) public view override returns (address) {
        return keeperGauges[lpToken];
    }
}
