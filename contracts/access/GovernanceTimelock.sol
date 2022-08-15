// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../../libraries/UncheckedMath.sol";
import "../../interfaces/access/IGovernanceTimelock.sol";

contract GovernanceTimelock is IGovernanceTimelock, Ownable {
    using UncheckedMath for uint256;
    using Address for address;

    Call[] internal _pendingCalls; // Calls that have not yet been executed or cancelled
    Call[] internal _executedCalls; // Calls that have been executed
    Call[] internal _cancelledCalls; // Calls that have been cancelled

    uint64 public totalCalls; // The total number of calls that have been prepared, executed, or cancelled
    mapping(address => mapping(bytes4 => uint64)) public delays; // The delay for each target and selector

    event CallPrepared(uint64 id); // Emitted when a call is prepared
    event CallExecuted(uint64 id); // Emitted when a call is executed
    event CallCancelled(uint64 id); // Emitted when a call is cancelled
    event CallQuickExecuted(address target, bytes data); // Emitted when a call is executed without a delay
    event DelaySet(address target, bytes4 selector, uint64 delay); // Emitted when a delay is set
    event DelayUpdated(address target, bytes4 selector, uint64 delay); // Emitted when a delay is updated

    modifier onlySelf() {
        require(msg.sender == address(this), "Must be called via timelock");
        _;
    }

    /**
     * @notice Used for validating if a call is valid.
     * @dev Can only be called internally, do not use.
     */
    function testCall(Call memory call_) external {
        require(msg.sender == address(this), "Only callable by this contract");
        _executeCall(call_);
        revert("OK");
    }

    /**
     * @notice Prepares a call for being executed.
     * @param target_ The contract to call.
     * @param data_ The data for the call.
     * @param validateCall_ If the call should be validated (i.e. checks if it will revert when executing).
     */
    function prepareCall(
        address target_,
        bytes calldata data_,
        bool validateCall_
    ) public override onlyOwner {
        Call memory call_ = _createCall(target_, data_);
        if (validateCall_) _validateCallIsExecutable(call_);
        _pendingCalls.push(call_);
        totalCalls++;
        emit CallPrepared(call_.id);
    }

    /**
     * @notice Executes a call.
     * @param id_ The id of the call to execute.
     */
    function executeCall(uint64 id_) public override {
        uint256 index_ = pendingCallIndex(id_);
        Call memory call_ = _pendingCalls[index_];
        require(call_.prepared + _getDelay(call_) <= block.timestamp, "Call not ready");
        _executeCall(call_);
        _removePendingCall(index_);
        _executedCalls.push(call_);
        emit CallExecuted(id_);
    }

    /**
     * @notice Cancels a call.
     * @param id_ The id of the call to cancel.
     */
    function cancelCall(uint64 id_) public override onlyOwner {
        uint256 index_ = pendingCallIndex(id_);
        Call memory call_ = _pendingCalls[index_];
        _removePendingCall(index_);
        _cancelledCalls.push(call_);
        emit CallCancelled(id_);
    }

    /**
     * @notice Executes a call without a delay.
     * @param target_ The contract to call.
     * @param data_ The data for the call.
     */
    function quickExecuteCall(address target_, bytes calldata data_) public override onlyOwner {
        Call memory call_ = _createCall(target_, data_);
        require(_getDelay(call_) == 0, "Call has a delay");
        _executeCall(call_);
        emit CallQuickExecuted(target_, data_);
    }

    /**
     * @notice Sets the delay for a given target and selector.
     * @param target_ The contract to set the delay for.
     * @param selector_ The selector to set the delay for.
     * @param delay_ The delay to set.
     */
    function setDelay(
        address target_,
        bytes4 selector_,
        uint64 delay_
    ) public override onlyOwner {
        require(delays[target_][selector_] == 0, "Delay already set");
        _updateDelay(target_, selector_, delay_);
        emit DelaySet(target_, selector_, delay_);
    }

    /**
     * @notice Updates the delay for a given target and selector.
     * @param target_ The contract to update the delay for.
     * @param selector_ The selector to update the delay for.
     * @param delay_ The delay to update.
     */
    function updateDelay(
        address target_,
        bytes4 selector_,
        uint64 delay_
    ) public override onlySelf {
        require(delays[target_][selector_] != 0, "Delay not already set");
        _updateDelay(target_, selector_, delay_);
        emit DelayUpdated(target_, selector_, delay_);
    }

    /**
     * @notice Returns the list of pending calls.
     * @return calls The list of pending calls.
     */
    function pendingCalls() public view override returns (Call[] memory calls) {
        return _pendingCalls;
    }

    /**
     * @notice Returns the list of executed calls.
     * @return calls The list of executed calls.
     */
    function executedCalls() public view override returns (Call[] memory calls) {
        return _executedCalls;
    }

    /**
     * @notice Returns the list of cancelled calls.
     * @return calls The list of cancelled calls.
     */
    function cancelledCalls() public view override returns (Call[] memory calls) {
        return _cancelledCalls;
    }

    /**
     * @notice Returns the list of ready calls.
     * @dev View is expensive, best to only call for off-chain use.
     * @return calls The list of ready calls.
     */
    function readyCalls() public view override returns (Call[] memory calls) {
        Call[] memory calls_ = new Call[](_pendingCalls.length);
        uint256 readyCount_;
        for (uint256 i = 0; i < _pendingCalls.length; i++) {
            Call memory call_ = _pendingCalls[i];
            if (call_.prepared + _getDelay(call_) <= block.timestamp) {
                calls_[i] = call_;
                readyCount_++;
            }
        }
        return _shortenCalls(calls_, readyCount_);
    }

    /**
     * @notice Returns the list of not-ready calls.
     * @dev View is expensive, best to only call for off-chain use.
     * @return calls The list of not-ready calls.
     */
    function notReadyCalls() public view override returns (Call[] memory calls) {
        Call[] memory calls_ = new Call[](_pendingCalls.length);
        uint256 readyCount_;
        for (uint256 i = 0; i < _pendingCalls.length; i++) {
            Call memory call_ = _pendingCalls[i];
            if (call_.prepared + _getDelay(call_) > block.timestamp) {
                calls_[i] = call_;
                readyCount_++;
            }
        }
        return _shortenCalls(calls_, readyCount_);
    }

    /**
     * @notice Returns the index of a given pending call id.
     * @param id_ The id of the pending call to return the index for.
     * @return index The index of the given pending call id.
     */
    function pendingCallIndex(uint64 id_) public view override returns (uint256 index) {
        for (uint256 i; i < _pendingCalls.length; i = i.uncheckedInc()) {
            if (_pendingCalls[i].id == id_) return i;
        }
        revert("Call not found");
    }

    /**
     * @notice Returns the call of a given pending call id.
     * @param id_ The id of the pending call to return the call for.
     * @return call The call of the given pending call id.
     */
    function pendingCall(uint64 id_) public view override returns (Call memory call) {
        return _pendingCalls[pendingCallIndex(id_)];
    }

    /**
     * @notice Returns the delay of a given pending call id.
     * @param id_ The id of the pending call to return the delay for.
     * @return call The delay of the given pending call id.
     */
    function pendingCallDelay(uint64 id_) public view override returns (uint64) {
        return _getDelay(pendingCall(id_));
    }

    function _validateCallIsExecutable(Call memory call_) internal {
        uint256 size;
        address target_ = call_.target;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            size := extcodesize(target_)
        }
        if (size == 0) revert("Call would revert when executed: invalid contract");
        try this.testCall(call_) {
            revert("Error validating call");
        } catch Error(string memory msg_) {
            if (keccak256(abi.encodePacked(msg_)) == keccak256(abi.encodePacked("OK"))) return;
            revert(string(abi.encodePacked("Call would revert when executed: ", msg_)));
        }
    }

    function _executeCall(Call memory call_) internal {
        call_.target.functionCall(call_.data);
    }

    function _removePendingCall(uint256 index_) internal {
        _pendingCalls[index_] = _pendingCalls[_pendingCalls.length - 1];
        _pendingCalls.pop();
    }

    function _updateDelay(
        address target_,
        bytes4 selector_,
        uint64 delay_
    ) internal {
        require(target_ != address(0), "Zero address not allowed");
        delays[target_][selector_] = delay_;
    }

    function _createCall(address target_, bytes calldata data_)
        internal
        view
        returns (Call memory)
    {
        require(target_ != address(0), "Zero address not allowed");
        bytes4 selector_ = bytes4(data_[:4]);
        _validatePendingCallIsUnique(target_, selector_);
        Call memory call_ = Call({
            id: totalCalls,
            prepared: uint64(block.timestamp),
            target: target_,
            selector: selector_,
            data: data_
        });
        return call_;
    }

    function _validatePendingCallIsUnique(address target_, bytes4 selector_) internal view {
        if (target_ == address(this)) return;
        for (uint256 i; i < _pendingCalls.length; i = i.uncheckedInc()) {
            if (_pendingCalls[i].target != target_) continue;
            if (_pendingCalls[i].selector != selector_) continue;
            revert("Call already pending");
        }
    }

    function _getDelay(Call memory call_) internal view returns (uint64) {
        address target = call_.target;
        bytes4 selector = call_.selector;

        if (call_.selector == this.updateDelay.selector) {
            bytes memory callData = call_.data;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                target := mload(add(callData, 36)) // skip bytes length and selector
                selector := mload(add(callData, 68)) // skip bytes length, selector, and target
            }
        }

        return delays[target][selector];
    }

    function _shortenCalls(Call[] memory calls_, uint256 length_)
        internal
        pure
        returns (Call[] memory)
    {
        Call[] memory shortened_ = new Call[](length_);
        for (uint256 i; i < length_; i = i.uncheckedInc()) {
            shortened_[i] = calls_[i];
        }
        return shortened_;
    }
}
