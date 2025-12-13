// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TrancheIOU
/// @notice ERC20 token representing a claim in a specific tranche of a recovery vault
/// @dev Minting and burning are restricted to the vault that deployed this token
contract TrancheIOU is ERC20 {
    address public immutable vault;
    uint8 public immutable trancheIndex;

    error OnlyVault();

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        address _vault,
        uint8 _trancheIndex
    ) ERC20(name, symbol) {
        vault = _vault;
        trancheIndex = _trancheIndex;
    }

    /// @notice Mint IOUs to a user (called when they deposit distressed assets)
    /// @param to The recipient of the IOUs
    /// @param amount The amount to mint
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// @notice Burn IOUs from a user (called when they claim recovery tokens)
    /// @param from The address to burn from
    /// @param amount The amount to burn
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }
}
