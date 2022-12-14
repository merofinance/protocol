// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "../../interfaces/tokenomics/IMeroToken.sol";

import "../../libraries/ScaledMath.sol";
import "../../libraries/Errors.sol";

contract MeroToken is IMeroToken, ERC20 {
    using ScaledMath for uint256;

    uint256 internal constant _CAP = 268_435_456e18; // 2 ** 28 cap

    address public immutable minter;

    constructor(
        string memory name_,
        string memory symbol_,
        address _minter
    ) ERC20(name_, symbol_) {
        minter = _minter;
    }

    /**
     * @notice Mints tokens for a given address.
     * @dev Fails if msg.sender is not the minter.
     * @param account Account for which tokens should be minted.
     * @param amount Amount of tokens to mint.
     */
    function mint(address account, uint256 amount) external override {
        require(msg.sender == minter, Error.UNAUTHORIZED_ACCESS);
        uint256 currentSupply = totalSupply();
        if (currentSupply + amount > _CAP) {
            amount = _CAP - currentSupply;
        }
        _mint(account, amount);
    }

    /**
     * @notice returns the cap i.e. the total number of tokens that can ever be minted.
     */
    function cap() external pure override returns (uint256) {
        return _CAP;
    }
}
