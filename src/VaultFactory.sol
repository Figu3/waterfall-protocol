// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./RecoveryVault.sol";
import "./Templates.sol";
import {Jurisdiction, JurisdictionParams, JurisdictionTemplates} from "./JurisdictionTemplates.sol";

/// @title VaultFactory
/// @notice Factory contract for creating and registering recovery vaults
/// @dev All vaults are immutable after creation
/// @dev V2: Added jurisdiction support for legal compliance
contract VaultFactory {
    using Templates for TemplateType;
    using JurisdictionTemplates for Jurisdiction;

    // ============ State ============
    mapping(address => bool) public isVault;
    address[] public allVaults;
    address public immutable waterfallTreasury;

    // V2: Jurisdiction tracking
    mapping(address => Jurisdiction) public vaultJurisdiction;
    mapping(Jurisdiction => address[]) public vaultsByJurisdiction;

    // ============ Events ============
    event VaultCreated(
        address indexed vault,
        string name,
        address indexed creator,
        TemplateType template,
        VaultMode mode,
        address recoveryToken
    );

    event VaultCreatedWithJurisdiction(
        address indexed vault,
        string name,
        address indexed creator,
        TemplateType template,
        VaultMode mode,
        address recoveryToken,
        Jurisdiction jurisdiction
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

    /// @notice Create a new recovery vault with jurisdiction specification
    /// @param _name The vault name
    /// @param _template The template type for tranche structure
    /// @param _mode The vault mode (WRAPPED_ONLY or WHOLE_SUPPLY)
    /// @param _recoveryToken The token used for recovery distribution
    /// @param _acceptedAssets Array of asset configurations
    /// @param _offChainClaims Array of off-chain claims (immutable)
    /// @param _unclaimedOption How to handle unclaimed funds after deadline
    /// @param _jurisdiction The jurisdiction for legal compliance
    /// @return vault The address of the newly created vault
    function createVaultWithJurisdiction(
        string memory _name,
        TemplateType _template,
        VaultMode _mode,
        address _recoveryToken,
        RecoveryVault.AssetConfig[] memory _acceptedAssets,
        RecoveryVault.OffChainClaim[] memory _offChainClaims,
        UnclaimedFundsOption _unclaimedOption,
        Jurisdiction _jurisdiction
    ) external returns (address vault) {
        Template memory t = _template.get();
        JurisdictionParams memory jp = _jurisdiction.get();

        // Validate asset configs match template
        for (uint256 i = 0; i < _acceptedAssets.length; i++) {
            require(_acceptedAssets[i].trancheIndex < t.trancheCount, "Invalid tranche index");
        }

        // Validate off-chain claims match template
        for (uint256 i = 0; i < _offChainClaims.length; i++) {
            require(_offChainClaims[i].trancheIndex < t.trancheCount, "Invalid tranche index");
        }

        // Validate template matches jurisdiction rules
        // If jurisdiction requires absolute priority, cannot use PARI_PASSU template
        if (jp.rules.absolutePriorityRule && !jp.rules.parPassuOption) {
            require(_template != TemplateType.PARI_PASSU, "Jurisdiction requires priority tranches");
        }

        vault = address(
            new RecoveryVault(
                _name, t, _mode, _recoveryToken, _acceptedAssets, _offChainClaims, _unclaimedOption, waterfallTreasury
            )
        );

        isVault[vault] = true;
        allVaults.push(vault);
        vaultJurisdiction[vault] = _jurisdiction;
        vaultsByJurisdiction[_jurisdiction].push(vault);

        emit VaultCreatedWithJurisdiction(vault, _name, msg.sender, _template, _mode, _recoveryToken, _jurisdiction);
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

    /// @notice Get jurisdiction parameters
    /// @param _jurisdiction The jurisdiction type
    function getJurisdictionParams(Jurisdiction _jurisdiction) external pure returns (JurisdictionParams memory) {
        return _jurisdiction.get();
    }

    /// @notice Get number of vaults in a jurisdiction
    /// @param _jurisdiction The jurisdiction type
    function getVaultCountByJurisdiction(Jurisdiction _jurisdiction) external view returns (uint256) {
        return vaultsByJurisdiction[_jurisdiction].length;
    }

    /// @notice Get vault address by jurisdiction and index
    /// @param _jurisdiction The jurisdiction type
    /// @param index The index in the jurisdiction's vault array
    function getVaultByJurisdiction(Jurisdiction _jurisdiction, uint256 index) external view returns (address) {
        require(index < vaultsByJurisdiction[_jurisdiction].length, "Index out of bounds");
        return vaultsByJurisdiction[_jurisdiction][index];
    }

    /// @notice Get all jurisdiction names
    function getJurisdictionNames() external pure returns (string[9] memory names) {
        names[0] = "US Chapter 11";
        names[1] = "US Chapter 7";
        names[2] = "UK CVA";
        names[3] = "UK Administration";
        names[4] = "Germany InsO";
        names[5] = "Germany StaRUG";
        names[6] = "Singapore IRDA";
        names[7] = "Cayman Liquidation";
        names[8] = "DeFi Standard";
    }
}
