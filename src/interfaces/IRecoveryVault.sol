// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../Templates.sol";

interface IRecoveryVault {
    // Structs
    struct AssetConfig {
        address assetAddress;
        uint8 trancheIndex;
        address priceOracle;
        uint256 manualPrice;
    }

    struct OffChainClaim {
        address claimant;
        uint8 trancheIndex;
        uint256 amount;
        bytes32 legalDocHash;
    }

    // Events
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 iouAmount, uint8 trancheIndex);
    event RecoveryDeposited(address indexed depositor, uint256 amount);
    event HarvestInitiated(uint256 indexed roundId, bytes32 merkleRoot, uint256 snapshotBlock, uint256 recoveryAmount);
    event VetoCast(uint256 indexed roundId, address indexed voter, uint256 weight);
    event HarvestVetoed(uint256 indexed roundId, uint256 vetoVotes, uint256 totalWeight);
    event HarvestExecuted(uint256 indexed roundId, uint256 distributed, uint256 fee, address harvester);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event OffChainClaimed(uint256 indexed roundId, address indexed user, uint8 trancheIndex, uint256 amount);
    event UnclaimedDonated(uint256 amount);
    event RedistributionEnabled(uint256 amount);
    event RedistributionClaimed(address indexed user, uint256 amount);

    // Deposit Functions
    function deposit(address asset, uint256 amount) external;
    function depositRecovery(uint256 amount) external;

    // Distribution Functions
    function initiateHarvest(bytes32 _merkleRoot, uint256 _snapshotBlock) external;
    function veto(uint256 roundId) external;
    function executeHarvest(uint256 roundId) external;
    function claim(uint256 roundId) external;
    function claimOffChain(
        uint256 roundId,
        uint8 trancheIndex,
        uint256 amount,
        bytes32 legalDocHash,
        bytes32[] calldata proof
    ) external;

    // Unclaimed Functions
    function distributeUnclaimed() external;
    function claimRedistribution() external;

    // View Functions
    function name() external view returns (string memory);
    function recoveryToken() external view returns (address);
    function vaultMode() external view returns (VaultMode);
    function unclaimedOption() external view returns (UnclaimedFundsOption);
    function trancheCount() external view returns (uint8);
    function depositsOpen() external view returns (bool);
    function pendingRecovery() external view returns (uint256);

    function getAssetPrice(address asset) external view returns (uint256);
    function getVetoWeight(address user, uint256 roundId) external view returns (uint256);
    function getTotalVetoWeight(uint256 roundId) external view returns (uint256);
    function getClaimable(address user, uint256 roundId) external view returns (uint256);

    function getRoundInfo(uint256 roundId)
        external
        view
        returns (
            bytes32 merkleRoot,
            uint256 snapshotBlock,
            uint256 recoveryAmount,
            uint256 initiatedAt,
            uint256 executedAt,
            address submitter,
            bool vetoed,
            bool executed,
            uint256 vetoVotes,
            uint256 totalClaimed
        );

    function getTrancheInfo(uint8 trancheIndex)
        external
        view
        returns (string memory trancheName, address iouToken, uint256 iouSupply, address[] memory underlyingAssets);

    function getRoundCount() external view returns (uint256);
    function getAcceptedAssetsCount() external view returns (uint256);
    function getOffChainClaimsCount() external view returns (uint256);
}
