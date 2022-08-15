// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

interface IGovernanceTimelock {
    struct Call {
        uint64 id;
        uint64 prepared;
        address target;
        bytes4 selector;
        bytes data;
    }

    function prepareCall(
        address target_,
        bytes calldata data_,
        bool validateCall_
    ) external;

    function executeCall(uint64 id_) external;

    function cancelCall(uint64 id_) external;

    function quickExecuteCall(address target_, bytes calldata data_) external;

    function setDelay(
        address target_,
        bytes4 selector_,
        uint64 delay_
    ) external;

    function updateDelay(
        address target_,
        bytes4 selector_,
        uint64 delay_
    ) external;

    function pendingCalls() external view returns (Call[] memory calls);

    function executedCalls() external view returns (Call[] memory calls);

    function cancelledCalls() external view returns (Call[] memory calls);

    function readyCalls() external view returns (Call[] memory calls);

    function notReadyCalls() external view returns (Call[] memory calls);

    function pendingCallIndex(uint64 id_) external view returns (uint256 index);

    function pendingCall(uint64 id_) external view returns (Call memory call);

    function pendingCallDelay(uint64 id_) external view returns (uint64);

    function delays(address target_, bytes4 selector_) external view returns (uint64);
}
