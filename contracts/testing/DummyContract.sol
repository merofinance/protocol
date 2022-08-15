// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

contract DummyContract {
    uint256 public value;

    function updateValue(uint256 value_) public {
        value = value_;
    }

    function justRevert(uint256 value_) public {
        value = value_;
        revert("I just revert");
    }
}
