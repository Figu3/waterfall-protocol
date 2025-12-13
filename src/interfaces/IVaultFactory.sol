// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Templates.sol";
import "../RecoveryVault.sol";

interface IVaultFactory {
    event VaultCreated(
        address indexed vault,
        string name,
        address indexed creator,
        TemplateType template,
        VaultMode mode,
        address recoveryToken
    );

    function createVault(
        string memory _name,
        TemplateType _template,
        VaultMode _mode,
        address _recoveryToken,
        RecoveryVault.AssetConfig[] memory _acceptedAssets,
        RecoveryVault.OffChainClaim[] memory _offChainClaims,
        UnclaimedFundsOption _unclaimedOption
    ) external returns (address vault);

    function isVault(address vault) external view returns (bool);
    function allVaults(uint256 index) external view returns (address);
    function waterfallTreasury() external view returns (address);
    function getVaultCount() external view returns (uint256);
    function getTemplate(TemplateType _template) external pure returns (Template memory);
    function getVaultAt(uint256 index) external view returns (address);
}
