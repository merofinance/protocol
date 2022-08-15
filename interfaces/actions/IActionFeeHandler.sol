// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IActionFeeHandler {
    function payFees(
        address payer,
        address keeper,
        uint256 amount,
        address token
    ) external;

    function claimKeeperFeesForPool(address keeper, address token) external;

    function claimTreasuryFees(address token) external;

    function setInitialKeeperGaugeForToken(address lpToken, address _keeperGauge) external;

    function updateKeeperFee(uint256 newKeeperFee) external;

    function updateKeeperGauge(address lpToken, address newKeeperGauge) external;

    function updateTreasuryFee(uint256 newTreasuryFee) external;

    function getKeeperGauge(address lpToken) external view returns (address);
}
