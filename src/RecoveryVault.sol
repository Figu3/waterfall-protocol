// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./TrancheIOU.sol";
import "./Templates.sol";

/// @title RecoveryVault
/// @notice Core vault for distressed asset recovery with waterfall distribution
/// @dev Immutable after deployment - no admin functions, no upgradability
contract RecoveryVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant HARVEST_TIMELOCK = 3 days;
    uint256 public constant VETO_THRESHOLD_BPS = 1000; // 10%
    uint256 public constant VETO_COOLDOWN = 1 days;
    uint256 public constant HARVESTER_FEE_BPS = 1; // 0.01%
    uint256 public constant UNCLAIMED_DEADLINE = 365 days;
    uint256 public constant PRECISION = 1e18;

    // ============ Immutable Configuration ============
    string public name;
    address public immutable recoveryToken;
    VaultMode public immutable vaultMode;
    UnclaimedFundsOption public immutable unclaimedOption;
    uint8 public immutable trancheCount;
    address public immutable waterfallTreasury;

    // ============ Structs ============
    struct AssetConfig {
        address assetAddress;
        uint8 trancheIndex;
        address priceOracle; // address(0) for manual price
        uint256 manualPrice; // in 1e18, used if priceOracle is address(0)
    }

    struct OffChainClaim {
        address claimant;
        uint8 trancheIndex;
        uint256 amount; // Dollar value in 1e18
        bytes32 legalDocHash;
    }

    struct Tranche {
        string name;
        TrancheIOU iouToken;
        address[] underlyingAssets;
    }

    struct DistributionRound {
        bytes32 merkleRoot;
        uint256 snapshotBlock;
        uint256 recoveryAmount;
        uint256 initiatedAt;
        uint256 executedAt;
        address submitter;
        bool vetoed;
        bool executed;
        uint256 vetoVotes;
        uint256 totalClaimed;
    }

    // ============ State ============
    Tranche[] public tranches;
    mapping(address => uint8) public assetToTranche;
    mapping(address => bool) public isAcceptedAsset;
    mapping(address => address) public assetPriceOracle;
    mapping(address => uint256) public assetManualPrice;
    address[] public acceptedAssets;

    OffChainClaim[] public offChainClaims;
    mapping(uint8 => uint256) public totalOffChainClaims;

    bool public depositsOpen = true;
    uint256 public pendingRecovery;

    DistributionRound[] public rounds;
    mapping(uint256 => mapping(uint8 => uint256)) public roundTranchePaid;
    mapping(uint256 => mapping(uint8 => uint256)) public roundTrancheRedemptionRate;
    mapping(uint256 => mapping(address => bool)) public roundHasVetoed;
    mapping(uint256 => mapping(address => bool)) public roundClaimed;
    mapping(uint256 => mapping(address => mapping(uint8 => bool))) public roundOffChainClaimed;
    mapping(uint256 => mapping(address => uint256)) public snapshotPrices;

    uint256 public firstDistributionTimestamp;
    uint256 public totalClaimedAllRounds;
    mapping(address => uint256) public userTotalClaimed;

    bool public unclaimedDistributed;
    uint256 public redistributionPool;
    bool public redistributionEnabled;
    mapping(address => bool) public redistributionClaimed;

    // ============ Events ============
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 iouAmount, uint8 trancheIndex);
    event RecoveryDeposited(address indexed depositor, uint256 amount);
    event HarvestInitiated(uint256 indexed roundId, bytes32 merkleRoot, uint256 snapshotBlock, uint256 recoveryAmount);
    event VetoCast(uint256 indexed roundId, address indexed voter, uint256 weight);
    event HarvestVetoed(uint256 indexed roundId, uint256 vetoVotes, uint256 totalWeight);
    event HarvestExecuted(uint256 indexed roundId, uint256 distributed, uint256 fee, address harvester);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event OffChainClaimed(uint256 indexed roundId, address indexed user, uint8 trancheIndex, uint256 amount);
    event DepositsClosedEvent();
    event UnclaimedDonated(uint256 amount);
    event RedistributionEnabled(uint256 amount);
    event RedistributionClaimed(address indexed user, uint256 amount);

    // ============ Errors ============
    error DepositsAreClosed();
    error AssetNotAccepted();
    error ZeroAmount();
    error NoRecoveryToDistribute();
    error VetoCooldownActive();
    error VetoedSubmitterCannotResubmit();
    error RoundDoesNotExist();
    error TimelockNotPassed();
    error TimelockPassed();
    error AlreadyVetoed();
    error RoundAlreadyVetoed();
    error NoVotingPower();
    error RoundNotExecuted();
    error AlreadyClaimedRound();
    error NothingToClaim();
    error InvalidMerkleProof();
    error AlreadyClaimedOffChain();
    error TooEarlyForUnclaimed();
    error AlreadyDistributedUnclaimed();
    error NothingToDistribute();
    error RedistributionNotEnabled();
    error AlreadyClaimedRedistribution();
    error NotAClaimant();
    error RoundAlreadyExecuted();

    // ============ Constructor ============
    constructor(
        string memory _name,
        Template memory _template,
        VaultMode _mode,
        address _recoveryToken,
        AssetConfig[] memory _acceptedAssets,
        OffChainClaim[] memory _offChainClaims,
        UnclaimedFundsOption _unclaimedOption,
        address _waterfallTreasury
    ) {
        name = _name;
        vaultMode = _mode;
        recoveryToken = _recoveryToken;
        trancheCount = _template.trancheCount;
        unclaimedOption = _unclaimedOption;
        waterfallTreasury = _waterfallTreasury;

        // Initialize tranches
        for (uint8 i = 0; i < _template.trancheCount; i++) {
            string memory iouName = string.concat("wf-", _template.trancheNames[i]);
            string memory iouSymbol = string.concat("wf", _template.trancheNames[i]);

            TrancheIOU iouToken = new TrancheIOU(iouName, iouSymbol, address(this), i);

            Tranche storage t = tranches.push();
            t.name = _template.trancheNames[i];
            t.iouToken = iouToken;
        }

        // Configure accepted assets
        for (uint256 i = 0; i < _acceptedAssets.length; i++) {
            AssetConfig memory config = _acceptedAssets[i];
            require(config.trancheIndex < _template.trancheCount, "Invalid tranche index");

            assetToTranche[config.assetAddress] = config.trancheIndex;
            isAcceptedAsset[config.assetAddress] = true;
            assetPriceOracle[config.assetAddress] = config.priceOracle;
            assetManualPrice[config.assetAddress] = config.manualPrice;
            acceptedAssets.push(config.assetAddress);
            tranches[config.trancheIndex].underlyingAssets.push(config.assetAddress);
        }

        // Store off-chain claims
        for (uint256 i = 0; i < _offChainClaims.length; i++) {
            offChainClaims.push(_offChainClaims[i]);
            totalOffChainClaims[_offChainClaims[i].trancheIndex] += _offChainClaims[i].amount;
        }
    }

    // ============ Deposit Functions ============

    /// @notice Deposit distressed assets to receive IOUs
    /// @param asset The distressed asset to deposit
    /// @param amount The amount to deposit
    function deposit(address asset, uint256 amount) external nonReentrant {
        if (!depositsOpen) revert DepositsAreClosed();
        if (!isAcceptedAsset[asset]) revert AssetNotAccepted();
        if (amount == 0) revert ZeroAmount();

        uint8 trancheIndex = assetToTranche[asset];
        uint256 assetPrice = getAssetPrice(asset);
        uint256 iouAmount = (amount * assetPrice) / PRECISION;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        tranches[trancheIndex].iouToken.mint(msg.sender, iouAmount);

        emit Deposited(msg.sender, asset, amount, iouAmount, trancheIndex);
    }

    /// @notice Deposit recovery tokens for distribution
    /// @param amount The amount of recovery tokens to deposit
    function depositRecovery(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        IERC20(recoveryToken).safeTransferFrom(msg.sender, address(this), amount);
        pendingRecovery += amount;

        emit RecoveryDeposited(msg.sender, amount);
    }

    // ============ Distribution Functions ============

    /// @notice Initiate a harvest round with a merkle root
    /// @param _merkleRoot The merkle root for this distribution
    /// @param _snapshotBlock The block number for the snapshot
    function initiateHarvest(bytes32 _merkleRoot, uint256 _snapshotBlock) external nonReentrant {
        if (pendingRecovery == 0) revert NoRecoveryToDistribute();

        // Check cooldown if previous round was vetoed
        if (rounds.length > 0) {
            DistributionRound storage lastRound = rounds[rounds.length - 1];
            if (lastRound.vetoed) {
                if (block.timestamp < lastRound.initiatedAt + VETO_COOLDOWN) {
                    revert VetoCooldownActive();
                }
                if (msg.sender == lastRound.submitter) {
                    revert VetoedSubmitterCannotResubmit();
                }
            }
        }

        // Close deposits in WRAPPED_ONLY mode
        if (vaultMode == VaultMode.WRAPPED_ONLY && depositsOpen) {
            depositsOpen = false;
            emit DepositsClosedEvent();
        }

        // Snapshot asset prices for veto weight calculation
        _snapshotAssetPrices(rounds.length);

        // Create new round
        rounds.push(
            DistributionRound({
                merkleRoot: _merkleRoot,
                snapshotBlock: _snapshotBlock,
                recoveryAmount: pendingRecovery,
                initiatedAt: block.timestamp,
                executedAt: 0,
                submitter: msg.sender,
                vetoed: false,
                executed: false,
                vetoVotes: 0,
                totalClaimed: 0
            })
        );

        uint256 roundId = rounds.length - 1;
        pendingRecovery = 0;

        emit HarvestInitiated(roundId, _merkleRoot, _snapshotBlock, rounds[roundId].recoveryAmount);
    }

    /// @notice Cast a veto vote against a pending distribution
    /// @param roundId The round to veto
    function veto(uint256 roundId) external nonReentrant {
        if (roundId >= rounds.length) revert RoundDoesNotExist();

        DistributionRound storage round = rounds[roundId];

        if (round.initiatedAt == 0) revert RoundDoesNotExist();
        if (block.timestamp >= round.initiatedAt + HARVEST_TIMELOCK) revert TimelockPassed();
        if (roundHasVetoed[roundId][msg.sender]) revert AlreadyVetoed();
        if (round.vetoed) revert RoundAlreadyVetoed();

        uint256 voterWeight = getVetoWeight(msg.sender, roundId);
        if (voterWeight == 0) revert NoVotingPower();

        roundHasVetoed[roundId][msg.sender] = true;
        round.vetoVotes += voterWeight;

        uint256 totalWeight = getTotalVetoWeight(roundId);

        if ((round.vetoVotes * 10000) / totalWeight >= VETO_THRESHOLD_BPS) {
            round.vetoed = true;
            pendingRecovery += round.recoveryAmount;
            round.recoveryAmount = 0;

            emit HarvestVetoed(roundId, round.vetoVotes, totalWeight);
        } else {
            emit VetoCast(roundId, msg.sender, voterWeight);
        }
    }

    /// @notice Execute a harvest after timelock passes
    /// @param roundId The round to execute
    function executeHarvest(uint256 roundId) external nonReentrant {
        if (roundId >= rounds.length) revert RoundDoesNotExist();

        DistributionRound storage round = rounds[roundId];

        if (round.initiatedAt == 0) revert RoundDoesNotExist();
        if (block.timestamp < round.initiatedAt + HARVEST_TIMELOCK) revert TimelockNotPassed();
        if (round.vetoed) revert RoundAlreadyVetoed();
        if (round.executed) revert RoundAlreadyExecuted();

        round.executed = true;
        round.executedAt = block.timestamp;

        // Pay harvester fee
        uint256 fee = (round.recoveryAmount * HARVESTER_FEE_BPS) / 10000;
        if (fee > 0) {
            IERC20(recoveryToken).safeTransfer(msg.sender, fee);
        }

        uint256 distributable = round.recoveryAmount - fee;

        // Execute waterfall
        _executeWaterfall(roundId, distributable);

        // Record first distribution timestamp
        if (firstDistributionTimestamp == 0) {
            firstDistributionTimestamp = block.timestamp;
        }

        emit HarvestExecuted(roundId, distributable, fee, msg.sender);
    }

    /// @notice Claim recovery tokens for a specific round
    /// @param roundId The round to claim from
    function claim(uint256 roundId) external nonReentrant {
        if (roundId >= rounds.length) revert RoundDoesNotExist();

        DistributionRound storage round = rounds[roundId];

        if (!round.executed) revert RoundNotExecuted();
        if (roundClaimed[roundId][msg.sender]) revert AlreadyClaimedRound();

        uint256 totalClaim = 0;
        uint256 recoveryDecimals = IERC20Metadata(recoveryToken).decimals();
        uint256 recoveryPrecision = 10 ** recoveryDecimals;

        for (uint8 i = 0; i < trancheCount; i++) {
            uint256 iouBalance = tranches[i].iouToken.balanceOf(msg.sender);
            if (iouBalance == 0) continue;

            uint256 redemptionRate = roundTrancheRedemptionRate[roundId][i];
            if (redemptionRate == 0) continue;

            // Burn IOUs proportionally (redemptionRate is percentage in 1e18)
            uint256 toBurn = (iouBalance * redemptionRate) / PRECISION;
            if (toBurn > 0) {
                tranches[i].iouToken.burn(msg.sender, toBurn);

                // Claim amount in recovery token decimals
                // toBurn is in IOU decimals (1e18), convert to recovery decimals
                uint256 claimAmount = (toBurn * recoveryPrecision) / PRECISION;
                totalClaim += claimAmount;
            }
        }

        if (totalClaim == 0) revert NothingToClaim();

        roundClaimed[roundId][msg.sender] = true;
        round.totalClaimed += totalClaim;
        totalClaimedAllRounds += totalClaim;
        userTotalClaimed[msg.sender] += totalClaim;

        IERC20(recoveryToken).safeTransfer(msg.sender, totalClaim);

        emit Claimed(roundId, msg.sender, totalClaim);
    }

    /// @notice Claim for off-chain claims using merkle proof
    /// @param roundId The round to claim from
    /// @param trancheIndex The tranche of the claim
    /// @param amount The claim amount
    /// @param legalDocHash Hash of the legal document
    /// @param proof Merkle proof
    function claimOffChain(
        uint256 roundId,
        uint8 trancheIndex,
        uint256 amount,
        bytes32 legalDocHash,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (roundId >= rounds.length) revert RoundDoesNotExist();

        DistributionRound storage round = rounds[roundId];

        if (!round.executed) revert RoundNotExecuted();
        if (roundOffChainClaimed[roundId][msg.sender][trancheIndex]) revert AlreadyClaimedOffChain();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, trancheIndex, amount, legalDocHash, round.snapshotBlock));

        if (!MerkleProof.verify(proof, round.merkleRoot, leaf)) revert InvalidMerkleProof();

        roundOffChainClaimed[roundId][msg.sender][trancheIndex] = true;

        uint256 redemptionRate = roundTrancheRedemptionRate[roundId][trancheIndex];
        uint256 recoveryDecimals = IERC20Metadata(recoveryToken).decimals();
        uint256 recoveryPrecision = 10 ** recoveryDecimals;

        // amount is in 1e18, redemption rate is percentage in 1e18
        uint256 redeemed = (amount * redemptionRate) / PRECISION;
        uint256 claimAmount = (redeemed * recoveryPrecision) / PRECISION;

        round.totalClaimed += claimAmount;
        totalClaimedAllRounds += claimAmount;
        userTotalClaimed[msg.sender] += claimAmount;

        IERC20(recoveryToken).safeTransfer(msg.sender, claimAmount);

        emit OffChainClaimed(roundId, msg.sender, trancheIndex, claimAmount);
    }

    // ============ Unclaimed Funds Functions ============

    /// @notice Distribute unclaimed funds after deadline
    function distributeUnclaimed() external nonReentrant {
        if (firstDistributionTimestamp == 0) revert RoundNotExecuted();
        if (block.timestamp <= firstDistributionTimestamp + UNCLAIMED_DEADLINE) revert TooEarlyForUnclaimed();
        if (unclaimedDistributed) revert AlreadyDistributedUnclaimed();

        uint256 unclaimed = IERC20(recoveryToken).balanceOf(address(this));
        if (unclaimed == 0) revert NothingToDistribute();

        unclaimedDistributed = true;

        if (unclaimedOption == UnclaimedFundsOption.DONATE_TO_WATERFALL) {
            IERC20(recoveryToken).safeTransfer(waterfallTreasury, unclaimed);
            emit UnclaimedDonated(unclaimed);
        } else {
            redistributionPool = unclaimed;
            redistributionEnabled = true;
            emit RedistributionEnabled(unclaimed);
        }
    }

    /// @notice Claim redistribution of unclaimed funds
    function claimRedistribution() external nonReentrant {
        if (!redistributionEnabled) revert RedistributionNotEnabled();
        if (redistributionClaimed[msg.sender]) revert AlreadyClaimedRedistribution();
        if (userTotalClaimed[msg.sender] == 0) revert NotAClaimant();

        redistributionClaimed[msg.sender] = true;

        uint256 share = (userTotalClaimed[msg.sender] * redistributionPool) / totalClaimedAllRounds;

        IERC20(recoveryToken).safeTransfer(msg.sender, share);

        emit RedistributionClaimed(msg.sender, share);
    }

    // ============ Internal Functions ============

    function _snapshotAssetPrices(uint256 roundId) internal {
        for (uint256 i = 0; i < acceptedAssets.length; i++) {
            address asset = acceptedAssets[i];
            snapshotPrices[roundId][asset] = getAssetPrice(asset);
        }
    }

    function _executeWaterfall(uint256 roundId, uint256 amount) internal {
        uint256 remaining = amount;
        uint256 recoveryDecimals = IERC20Metadata(recoveryToken).decimals();
        uint256 recoveryPrecision = 10 ** recoveryDecimals;

        for (uint8 i = 0; i < trancheCount; i++) {
            if (remaining == 0) break;

            uint256 trancheDenominator = _getTrancheDenominator(i);
            if (trancheDenominator == 0) continue;

            // Normalize tranche denominator to recovery token decimals for comparison
            // trancheDenominator is in 1e18, we need it in recovery token decimals
            uint256 trancheOutstandingInRecovery = (trancheDenominator * recoveryPrecision) / PRECISION
                - roundTranchePaid[roundId][i];
            uint256 toTranche = remaining < trancheOutstandingInRecovery ? remaining : trancheOutstandingInRecovery;

            if (toTranche > 0) {
                roundTranchePaid[roundId][i] += toTranche;
                // Redemption rate: how much of the tranche has been paid (in PRECISION scale)
                // paid is in recovery decimals, denominator is in 1e18
                // rate = (paid * 1e18) / (denominator * recoveryPrecision / 1e18)
                // Simplified: rate = (paid * 1e18 * 1e18) / (denominator * recoveryPrecision)
                roundTrancheRedemptionRate[roundId][i] =
                    (roundTranchePaid[roundId][i] * PRECISION * PRECISION) / (trancheDenominator * recoveryPrecision);
                remaining -= toTranche;
            }
        }

        // Any remaining goes to most junior tranche as bonus
        if (remaining > 0 && trancheCount > 0) {
            uint8 juniorTranche = trancheCount - 1;
            uint256 denominator = _getTrancheDenominator(juniorTranche);
            if (denominator > 0) {
                roundTranchePaid[roundId][juniorTranche] += remaining;
                roundTrancheRedemptionRate[roundId][juniorTranche] =
                    (roundTranchePaid[roundId][juniorTranche] * PRECISION * PRECISION) / (denominator * recoveryPrecision);
            }
        }
    }

    function _getTrancheDenominator(uint8 trancheIndex) internal view returns (uint256) {
        uint256 denominator;

        if (vaultMode == VaultMode.WRAPPED_ONLY) {
            denominator = tranches[trancheIndex].iouToken.totalSupply();
        } else {
            // WHOLE_SUPPLY mode: sum of all underlying asset supplies
            address[] storage assets = tranches[trancheIndex].underlyingAssets;
            for (uint256 i = 0; i < assets.length; i++) {
                uint256 supply = IERC20(assets[i]).totalSupply();
                uint256 price = getAssetPrice(assets[i]);
                denominator += (supply * price) / PRECISION;
            }
        }

        // Add off-chain claims
        denominator += totalOffChainClaims[trancheIndex];

        return denominator;
    }

    // ============ View Functions ============

    /// @notice Get asset price (from oracle or manual)
    /// @param asset The asset to price
    /// @return price The price in 1e18
    function getAssetPrice(address asset) public view returns (uint256) {
        address oracle = assetPriceOracle[asset];
        if (oracle == address(0)) {
            return assetManualPrice[asset];
        }
        // Simple oracle interface - assumes oracle returns price in 1e18
        // In production, would need proper oracle integration (Chainlink, etc.)
        (bool success, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        return assetManualPrice[asset]; // Fallback to manual
    }

    /// @notice Get veto weight for a user in a specific round
    /// @param user The user address
    /// @param roundId The round ID
    /// @return weight The voting weight in dollar terms
    function getVetoWeight(address user, uint256 roundId) public view returns (uint256) {
        uint256 weight = 0;
        for (uint8 i = 0; i < trancheCount; i++) {
            uint256 iouBalance = tranches[i].iouToken.balanceOf(user);
            if (iouBalance == 0) continue;

            // Use snapshot prices
            address[] storage assets = tranches[i].underlyingAssets;
            if (assets.length > 0) {
                uint256 price = snapshotPrices[roundId][assets[0]];
                weight += (iouBalance * price) / PRECISION;
            } else {
                weight += iouBalance; // Default 1:1 if no underlying
            }
        }
        return weight;
    }

    /// @notice Get total veto weight for a round
    /// @param roundId The round ID
    /// @return total The total voting weight
    function getTotalVetoWeight(uint256 roundId) public view returns (uint256) {
        uint256 total = 0;
        for (uint8 i = 0; i < trancheCount; i++) {
            uint256 supply = tranches[i].iouToken.totalSupply();
            if (supply == 0) continue;

            address[] storage assets = tranches[i].underlyingAssets;
            if (assets.length > 0) {
                uint256 price = snapshotPrices[roundId][assets[0]];
                total += (supply * price) / PRECISION;
            } else {
                total += supply;
            }
        }
        return total;
    }

    /// @notice Get claimable amount for a user in a round
    /// @param user The user address
    /// @param roundId The round ID
    /// @return claimable The claimable amount in recovery token decimals
    function getClaimable(address user, uint256 roundId) external view returns (uint256) {
        if (roundId >= rounds.length) return 0;
        if (!rounds[roundId].executed) return 0;
        if (roundClaimed[roundId][user]) return 0;

        uint256 totalClaim = 0;
        uint256 recoveryDecimals = IERC20Metadata(recoveryToken).decimals();
        uint256 recoveryPrecision = 10 ** recoveryDecimals;

        for (uint8 i = 0; i < trancheCount; i++) {
            uint256 iouBalance = tranches[i].iouToken.balanceOf(user);
            if (iouBalance == 0) continue;

            uint256 redemptionRate = roundTrancheRedemptionRate[roundId][i];
            if (redemptionRate == 0) continue;

            uint256 toBurn = (iouBalance * redemptionRate) / PRECISION;
            uint256 claimAmount = (toBurn * recoveryPrecision) / PRECISION;
            totalClaim += claimAmount;
        }
        return totalClaim;
    }

    /// @notice Get round information
    /// @param roundId The round ID
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
        )
    {
        if (roundId >= rounds.length) revert RoundDoesNotExist();
        DistributionRound storage round = rounds[roundId];
        return (
            round.merkleRoot,
            round.snapshotBlock,
            round.recoveryAmount,
            round.initiatedAt,
            round.executedAt,
            round.submitter,
            round.vetoed,
            round.executed,
            round.vetoVotes,
            round.totalClaimed
        );
    }

    /// @notice Get tranche information
    /// @param trancheIndex The tranche index
    function getTrancheInfo(uint8 trancheIndex)
        external
        view
        returns (string memory trancheName, address iouToken, uint256 iouSupply, address[] memory underlyingAssets)
    {
        require(trancheIndex < trancheCount, "Invalid tranche");
        Tranche storage t = tranches[trancheIndex];
        return (t.name, address(t.iouToken), t.iouToken.totalSupply(), t.underlyingAssets);
    }

    /// @notice Get number of distribution rounds
    function getRoundCount() external view returns (uint256) {
        return rounds.length;
    }

    /// @notice Get number of accepted assets
    function getAcceptedAssetsCount() external view returns (uint256) {
        return acceptedAssets.length;
    }

    /// @notice Get number of off-chain claims
    function getOffChainClaimsCount() external view returns (uint256) {
        return offChainClaims.length;
    }
}
