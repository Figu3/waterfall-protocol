// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RecoveryVault.sol";
import "./Templates.sol";

/// @title VaultFactory
/// @notice Factory contract for creating and registering recovery vaults
/// @dev All vaults are immutable after creation
contract VaultFactory {
    using Templates for TemplateType;

    // ============ State ============
    mapping(address => bool) public isVault;
    address[] public allVaults;
    address public immutable waterfallTreasury;

    // ============ Events ============
    event VaultCreated(
        address indexed vault,
        string name,
        address indexed creator,
        TemplateType template,
        VaultMode mode,
        address recoveryToken
    );

    // ============ Constructor ============
    constructor(address _waterfallTreasury) {
        require(_waterfallTreasury != address(0), "Invalid treasury");
        waterfallTreasury = _waterfallTreasury;
    }

    // ============ Factory Functions ============

    /// @notice Create a new recovery vault
    /// @param _name The vault name
    /// @param _template The template type for tranche structure
    /// @param _mode The vault mode (WRAPPED_ONLY or WHOLE_SUPPLY)
    /// @param _recoveryToken The token used for recovery distribution
    /// @param _acceptedAssets Array of asset configurations
    /// @param _offChainClaims Array of off-chain claims (immutable)
    /// @param _unclaimedOption How to handle unclaimed funds after deadline
    /// @return vault The address of the newly created vault
    function createVault(
        string memory _name,
        TemplateType _template,
        VaultMode _mode,
        address _recoveryToken,
        RecoveryVault.AssetConfig[] memory _acceptedAssets,
        RecoveryVault.OffChainClaim[] memory _offChainClaims,
        UnclaimedFundsOption _unclaimedOption
    ) external returns (address vault) {
        Template memory t = _template.get();

        // Validate asset configs match template
        for (uint256 i = 0; i < _acceptedAssets.length; i++) {
            require(_acceptedAssets[i].trancheIndex < t.trancheCount, "Invalid tranche index");
        }

        // Validate off-chain claims match template
        for (uint256 i = 0; i < _offChainClaims.length; i++) {
            require(_offChainClaims[i].trancheIndex < t.trancheCount, "Invalid tranche index");
        }

        vault = address(
            new RecoveryVault(
                _name, t, _mode, _recoveryToken, _acceptedAssets, _offChainClaims, _unclaimedOption, waterfallTreasury
            )
        );

        isVault[vault] = true;
        allVaults.push(vault);

        emit VaultCreated(vault, _name, msg.sender, _template, _mode, _recoveryToken);
    }

    // ============ View Functions ============

    /// @notice Get the total number of vaults created
    function getVaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @notice Get a template by type
    /// @param _template The template type
    function getTemplate(TemplateType _template) external pure returns (Template memory) {
        return _template.get();
    }

    /// @notice Get vault address by index
    /// @param index The index in the allVaults array
    function getVaultAt(uint256 index) external view returns (address) {
        require(index < allVaults.length, "Index out of bounds");
        return allVaults[index];
    }
}
