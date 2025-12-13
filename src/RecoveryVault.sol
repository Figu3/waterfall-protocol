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
/// @dev V2: Added quorum, harvester bonds, batch operations, WHOLE_SUPPLY fix
contract RecoveryVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant HARVEST_TIMELOCK = 3 days;
    uint256 public constant VETO_THRESHOLD_BPS = 1000; // 10%
    uint256 public constant VETO_QUORUM_BPS = 500; // 5% minimum participation
    uint256 public constant VETO_COOLDOWN = 1 days;
    uint256 public constant HARVESTER_FEE_BPS = 10; // 0.1% (increased)
    uint256 public constant HARVESTER_BOND_BPS = 100; // 1% of recovery as bond
    uint256 public constant CHALLENGE_PERIOD = 7 days;
    uint256 public constant UNCLAIMED_DEADLINE = 365 days;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant MAX_ORACLE_STALENESS = 1 days;
    uint256 public constant MIN_PRICE = 1e14; // $0.0001 minimum
    uint256 public constant MAX_PRICE = 1e24; // $1,000,000 maximum

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
        // V2: Harvester bond tracking
        uint256 harvesterBond;
        bool challenged;
        bool bondReturned;
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

    // Snapshot IOU balances for veto weight calculation
    mapping(uint256 => mapping(address => uint256)) public snapshotBalances;
    mapping(uint256 => mapping(uint8 => uint256)) public snapshotTotalSupply;

    // Snapshot total supply for WHOLE_SUPPLY mode
    mapping(uint256 => mapping(address => uint256)) public snapshotAssetTotalSupply;


    uint256 public firstDistributionTimestamp;
    uint256 public totalClaimedAllRounds;
    mapping(address => uint256) public userTotalClaimed;

    bool public unclaimedDistributed;
    uint256 public redistributionPool;
    uint256 public redistributionPoolRemaining;
    bool public redistributionEnabled;
    mapping(address => bool) public redistributionClaimed;

    // ============ Events ============
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 iouAmount, uint8 trancheIndex);
    event RecoveryDeposited(address indexed depositor, uint256 amount);
    event HarvestInitiated(uint256 indexed roundId, bytes32 merkleRoot, uint256 snapshotBlock, uint256 recoveryAmount, uint256 bond);
    event VetoCast(uint256 indexed roundId, address indexed voter, uint256 weight);
    event HarvestVetoed(uint256 indexed roundId, uint256 vetoVotes, uint256 totalWeight);
    event HarvestExecuted(uint256 indexed roundId, uint256 distributed, uint256 fee, address harvester);
    event Claimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event OffChainClaimed(uint256 indexed roundId, address indexed user, uint8 trancheIndex, uint256 amount);
    event DepositsClosedEvent();
    event UnclaimedDonated(uint256 amount);
    event RedistributionEnabled(uint256 amount);
    event RedistributionClaimed(address indexed user, uint256 amount);
    event OracleFallback(address indexed asset, address indexed oracle, uint256 manualPrice);
    // V2: New events
    event HarvesterBondPosted(uint256 indexed roundId, address indexed harvester, uint256 amount);
    event HarvesterBondReturned(uint256 indexed roundId, address indexed harvester, uint256 amount);
    event HarvestChallenged(uint256 indexed roundId, address indexed challenger, bytes32 invalidLeaf);
    event BatchClaimed(address indexed user, uint256[] roundIds, uint256 totalAmount);

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
    error InvalidSnapshotBlock();
    error InsufficientRedistributionPool();
    // V2: New errors
    error QuorumNotMet();
    error InsufficientBond();
    error ChallengePeriodNotOver();
    error ChallengePeriodOver();
    error AlreadyChallenged();
    error BondAlreadyReturned();
    error InvalidChallenge();
    error ArrayLengthMismatch();
    error IndexOutOfBounds();

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

    /// @notice Batch deposit multiple assets
    /// @param assets Array of asset addresses
    /// @param amounts Array of amounts to deposit
    function depositMultiple(address[] calldata assets, uint256[] calldata amounts) external nonReentrant {
        if (assets.length != amounts.length) revert ArrayLengthMismatch();
        if (!depositsOpen) revert DepositsAreClosed();

        for (uint256 i = 0; i < assets.length; i++) {
            if (!isAcceptedAsset[assets[i]]) revert AssetNotAccepted();
            if (amounts[i] == 0) revert ZeroAmount();

            uint8 trancheIndex = assetToTranche[assets[i]];
            uint256 assetPrice = getAssetPrice(assets[i]);
            uint256 iouAmount = (amounts[i] * assetPrice) / PRECISION;

            IERC20(assets[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            tranches[trancheIndex].iouToken.mint(msg.sender, iouAmount);

            emit Deposited(msg.sender, assets[i], amounts[i], iouAmount, trancheIndex);
        }
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

    /// @notice Initiate a harvest round with a merkle root (requires bond)
    /// @param _merkleRoot The merkle root for this distribution
    /// @param _snapshotBlock The block number for the snapshot
    function initiateHarvest(bytes32 _merkleRoot, uint256 _snapshotBlock) external nonReentrant {
        if (pendingRecovery == 0) revert NoRecoveryToDistribute();
        if (_snapshotBlock > block.number) revert InvalidSnapshotBlock();

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

        // V2: Calculate and collect harvester bond
        uint256 bond = (pendingRecovery * HARVESTER_BOND_BPS) / 10000;
        if (bond > 0) {
            IERC20(recoveryToken).safeTransferFrom(msg.sender, address(this), bond);
        }

        uint256 roundId = rounds.length;

        // Snapshot asset prices for veto weight calculation
        _snapshotAssetPrices(roundId);

        // Snapshot IOU balances and total supplies for veto protection
        _snapshotIOUState(roundId);

        // Snapshot asset total supplies for WHOLE_SUPPLY mode
        if (vaultMode == VaultMode.WHOLE_SUPPLY) {
            _snapshotAssetTotalSupplies(roundId);
        }

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
                totalClaimed: 0,
                harvesterBond: bond,
                challenged: false,
                bondReturned: false
            })
        );

        pendingRecovery = 0;

        emit HarvestInitiated(roundId, _merkleRoot, _snapshotBlock, rounds[roundId].recoveryAmount, bond);
        emit HarvesterBondPosted(roundId, msg.sender, bond);
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

        uint256 voterWeight = getSnapshotVetoWeight(msg.sender, roundId);
        if (voterWeight == 0) revert NoVotingPower();

        roundHasVetoed[roundId][msg.sender] = true;
        round.vetoVotes += voterWeight;

        uint256 totalWeight = getSnapshotTotalVetoWeight(roundId);

        // V2: Check quorum first
        bool quorumMet = (round.vetoVotes * 10000) / totalWeight >= VETO_QUORUM_BPS;
        bool thresholdMet = (round.vetoVotes * 10000) / totalWeight >= VETO_THRESHOLD_BPS;

        if (quorumMet && thresholdMet) {
            round.vetoed = true;
            pendingRecovery += round.recoveryAmount;
            round.recoveryAmount = 0;

            // Return harvester bond on veto
            if (round.harvesterBond > 0 && !round.bondReturned) {
                round.bondReturned = true;
                IERC20(recoveryToken).safeTransfer(round.submitter, round.harvesterBond);
                emit HarvesterBondReturned(roundId, round.submitter, round.harvesterBond);
            }

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

    /// @notice Challenge a harvest with proof of invalid merkle entry
    /// @dev Anyone can challenge by proving an entry that shouldn't be in the merkle tree
    /// @param roundId The round to challenge
    /// @param invalidClaim The claim data that shouldn't be valid
    /// @param proof The merkle proof for the invalid claim
    function challengeHarvest(
        uint256 roundId,
        bytes calldata invalidClaim,
        bytes32[] calldata proof
    ) external nonReentrant {
        if (roundId >= rounds.length) revert RoundDoesNotExist();

        DistributionRound storage round = rounds[roundId];

        if (!round.executed) revert RoundNotExecuted();
        if (block.timestamp > round.executedAt + CHALLENGE_PERIOD) revert ChallengePeriodOver();
        if (round.challenged) revert AlreadyChallenged();

        // Verify the proof is valid for the merkle root
        bytes32 leaf = keccak256(invalidClaim);
        if (!MerkleProof.verify(proof, round.merkleRoot, leaf)) {
            revert InvalidChallenge();
        }

        // If we reach here, the proof is valid but the claim data is fraudulent
        // The challenger must prove off-chain that this claim is invalid
        // For now, we just mark as challenged - governance would need to resolve
        round.challenged = true;

        // Slash the harvester bond - give to challenger
        if (round.harvesterBond > 0 && !round.bondReturned) {
            round.bondReturned = true;
            IERC20(recoveryToken).safeTransfer(msg.sender, round.harvesterBond);
        }

        emit HarvestChallenged(roundId, msg.sender, leaf);
    }

    /// @notice Return harvester bond after challenge period
    /// @param roundId The round to return bond for
    function returnHarvesterBond(uint256 roundId) external nonReentrant {
        if (roundId >= rounds.length) revert RoundDoesNotExist();

        DistributionRound storage round = rounds[roundId];

        if (!round.executed) revert RoundNotExecuted();
        if (block.timestamp <= round.executedAt + CHALLENGE_PERIOD) revert ChallengePeriodNotOver();
        if (round.challenged) revert AlreadyChallenged();
        if (round.bondReturned) revert BondAlreadyReturned();

        round.bondReturned = true;

        if (round.harvesterBond > 0) {
            IERC20(recoveryToken).safeTransfer(round.submitter, round.harvesterBond);
            emit HarvesterBondReturned(roundId, round.submitter, round.harvesterBond);
        }
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

    /// @notice Batch claim from multiple rounds
    /// @param roundIds Array of round IDs to claim from
    function claimMultiple(uint256[] calldata roundIds) external nonReentrant {
        uint256 totalClaim = 0;
        uint256 recoveryDecimals = IERC20Metadata(recoveryToken).decimals();
        uint256 recoveryPrecision = 10 ** recoveryDecimals;

        for (uint256 r = 0; r < roundIds.length; r++) {
            uint256 roundId = roundIds[r];
            if (roundId >= rounds.length) continue;

            DistributionRound storage round = rounds[roundId];

            if (!round.executed) continue;
            if (roundClaimed[roundId][msg.sender]) continue;

            uint256 roundClaim = 0;

            for (uint8 i = 0; i < trancheCount; i++) {
                uint256 iouBalance = tranches[i].iouToken.balanceOf(msg.sender);
                if (iouBalance == 0) continue;

                uint256 redemptionRate = roundTrancheRedemptionRate[roundId][i];
                if (redemptionRate == 0) continue;

                uint256 toBurn = (iouBalance * redemptionRate) / PRECISION;
                if (toBurn > 0) {
                    tranches[i].iouToken.burn(msg.sender, toBurn);
                    uint256 claimAmount = (toBurn * recoveryPrecision) / PRECISION;
                    roundClaim += claimAmount;
                }
            }

            if (roundClaim > 0) {
                roundClaimed[roundId][msg.sender] = true;
                round.totalClaimed += roundClaim;
                totalClaim += roundClaim;

                emit Claimed(roundId, msg.sender, roundClaim);
            }
        }

        if (totalClaim == 0) revert NothingToClaim();

        totalClaimedAllRounds += totalClaim;
        userTotalClaimed[msg.sender] += totalClaim;

        IERC20(recoveryToken).safeTransfer(msg.sender, totalClaim);

        emit BatchClaimed(msg.sender, roundIds, totalClaim);
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
            redistributionPoolRemaining = unclaimed;
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

        if (share > redistributionPoolRemaining) revert InsufficientRedistributionPool();
        redistributionPoolRemaining -= share;

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

    function _snapshotIOUState(uint256 roundId) internal {
        for (uint8 i = 0; i < trancheCount; i++) {
            snapshotTotalSupply[roundId][i] = tranches[i].iouToken.totalSupply();
        }
    }

    function _snapshotAssetTotalSupplies(uint256 roundId) internal {
        for (uint256 i = 0; i < acceptedAssets.length; i++) {
            address asset = acceptedAssets[i];
            snapshotAssetTotalSupply[roundId][asset] = IERC20(asset).totalSupply();
        }
    }

    function _executeWaterfall(uint256 roundId, uint256 amount) internal {
        uint256 remaining = amount;
        uint256 recoveryDecimals = IERC20Metadata(recoveryToken).decimals();
        uint256 recoveryPrecision = 10 ** recoveryDecimals;

        for (uint8 i = 0; i < trancheCount; i++) {
            if (remaining == 0) break;

            uint256 trancheDenominator = _getTrancheDenominator(i, roundId);
            if (trancheDenominator == 0) continue;

            uint256 trancheOutstandingInRecovery = (trancheDenominator * recoveryPrecision) / PRECISION
                - roundTranchePaid[roundId][i];
            uint256 toTranche = remaining < trancheOutstandingInRecovery ? remaining : trancheOutstandingInRecovery;

            if (toTranche > 0) {
                roundTranchePaid[roundId][i] += toTranche;
                roundTrancheRedemptionRate[roundId][i] =
                    (roundTranchePaid[roundId][i] * PRECISION * PRECISION) / (trancheDenominator * recoveryPrecision);
                remaining -= toTranche;
            }
        }

        // Any remaining goes to most junior tranche as bonus
        if (remaining > 0 && trancheCount > 0) {
            uint8 juniorTranche = trancheCount - 1;
            uint256 denominator = _getTrancheDenominator(juniorTranche, roundId);
            if (denominator > 0) {
                roundTranchePaid[roundId][juniorTranche] += remaining;
                uint256 recoveryPrecision2 = 10 ** IERC20Metadata(recoveryToken).decimals();
                roundTrancheRedemptionRate[roundId][juniorTranche] =
                    (roundTranchePaid[roundId][juniorTranche] * PRECISION * PRECISION) / (denominator * recoveryPrecision2);
            }
        }
    }

    function _getTrancheDenominator(uint8 trancheIndex, uint256 roundId) internal view returns (uint256) {
        uint256 denominator;

        if (vaultMode == VaultMode.WRAPPED_ONLY) {
            denominator = tranches[trancheIndex].iouToken.totalSupply();
        } else {
            // WHOLE_SUPPLY mode: use snapshotted total supplies
            address[] storage assets = tranches[trancheIndex].underlyingAssets;
            for (uint256 i = 0; i < assets.length; i++) {
                uint256 supply = snapshotAssetTotalSupply[roundId][assets[i]];
                uint256 price = snapshotPrices[roundId][assets[i]];
                denominator += (supply * price) / PRECISION;
            }
        }

        // Add off-chain claims
        denominator += totalOffChainClaims[trancheIndex];

        return denominator;
    }

    // ============ View Functions ============

    /// @notice Get asset price (from oracle or manual) with validation
    function getAssetPrice(address asset) public view returns (uint256) {
        address oracle = assetPriceOracle[asset];
        if (oracle == address(0)) {
            return assetManualPrice[asset];
        }

        try this._getOraclePrice(oracle) returns (uint256 oraclePrice, bool isValid) {
            if (isValid && oraclePrice >= MIN_PRICE && oraclePrice <= MAX_PRICE) {
                return oraclePrice;
            }
        } catch {
            // Oracle call failed, fall through to manual price
        }

        return assetManualPrice[asset];
    }

    /// @notice External function to get oracle price (used with try/catch)
    function _getOraclePrice(address oracle) external view returns (uint256 price, bool isValid) {
        (bool success, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (success && data.length >= 160) {
            (
                ,
                int256 answer,
                ,
                uint256 updatedAt,

            ) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));

            if (block.timestamp - updatedAt > MAX_ORACLE_STALENESS) {
                return (0, false);
            }

            if (answer <= 0) {
                return (0, false);
            }

            return (uint256(answer) * 1e10, true);
        }

        (success, data) = oracle.staticcall(abi.encodeWithSignature("latestAnswer()"));
        if (success && data.length >= 32) {
            int256 answer = abi.decode(data, (int256));
            if (answer > 0) {
                return (uint256(answer), true);
            }
        }

        return (0, false);
    }

    /// @notice Get veto weight using snapshotted balances
    function getSnapshotVetoWeight(address user, uint256 roundId) public view returns (uint256) {
        uint256 weight = 0;
        for (uint8 i = 0; i < trancheCount; i++) {
            uint256 iouBalance = tranches[i].iouToken.balanceOf(user);
            if (iouBalance == 0) continue;

            address[] storage assets = tranches[i].underlyingAssets;
            if (assets.length > 0) {
                uint256 price = snapshotPrices[roundId][assets[0]];
                weight += (iouBalance * price) / PRECISION;
            } else {
                weight += iouBalance;
            }
        }
        return weight;
    }

    /// @notice Get total veto weight using snapshotted total supplies
    function getSnapshotTotalVetoWeight(uint256 roundId) public view returns (uint256) {
        uint256 total = 0;
        for (uint8 i = 0; i < trancheCount; i++) {
            uint256 supply = snapshotTotalSupply[roundId][i];
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

    /// @notice Get veto weight (legacy)
    function getVetoWeight(address user, uint256 roundId) public view returns (uint256) {
        return getSnapshotVetoWeight(user, roundId);
    }

    /// @notice Get total veto weight (legacy)
    function getTotalVetoWeight(uint256 roundId) public view returns (uint256) {
        return getSnapshotTotalVetoWeight(roundId);
    }

    /// @notice Get claimable amount for a user in a round
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

    /// @notice Get extended round information (V2)
    function getRoundInfoExtended(uint256 roundId)
        external
        view
        returns (
            uint256 harvesterBond,
            bool challenged,
            bool bondReturned
        )
    {
        if (roundId >= rounds.length) revert RoundDoesNotExist();
        DistributionRound storage round = rounds[roundId];
        return (round.harvesterBond, round.challenged, round.bondReturned);
    }

    /// @notice Get tranche information
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

    /// @notice Get remaining redistribution pool
    function getRedistributionPoolRemaining() external view returns (uint256) {
        return redistributionPoolRemaining;
    }

    // ============ Pagination Functions ============

    /// @notice Get accepted assets with pagination
    /// @param offset Starting index
    /// @param limit Maximum number of items to return
    function getAcceptedAssetsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory assets, uint256 total)
    {
        total = acceptedAssets.length;
        if (offset >= total) {
            return (new address[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;

        assets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = acceptedAssets[offset + i];
        }

        return (assets, total);
    }

    /// @notice Get off-chain claims with pagination
    /// @param offset Starting index
    /// @param limit Maximum number of items to return
    function getOffChainClaimsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (OffChainClaim[] memory claims, uint256 total)
    {
        total = offChainClaims.length;
        if (offset >= total) {
            return (new OffChainClaim[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;

        claims = new OffChainClaim[](count);
        for (uint256 i = 0; i < count; i++) {
            claims[i] = offChainClaims[offset + i];
        }

        return (claims, total);
    }

    /// @notice Get rounds with pagination
    /// @param offset Starting index
    /// @param limit Maximum number of items to return
    function getRoundsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (DistributionRound[] memory roundsData, uint256 total)
    {
        total = rounds.length;
        if (offset >= total) {
            return (new DistributionRound[](0), total);
        }

        uint256 remaining = total - offset;
        uint256 count = remaining < limit ? remaining : limit;

        roundsData = new DistributionRound[](count);
        for (uint256 i = 0; i < count; i++) {
            roundsData[i] = rounds[offset + i];
        }

        return (roundsData, total);
    }

    /// @notice Get accepted asset by index
    /// @param index The index in the array
    function getAcceptedAssetAt(uint256 index) external view returns (address) {
        if (index >= acceptedAssets.length) revert IndexOutOfBounds();
        return acceptedAssets[index];
    }

    /// @notice Get off-chain claim by index
    /// @param index The index in the array
    function getOffChainClaimAt(uint256 index) external view returns (OffChainClaim memory) {
        if (index >= offChainClaims.length) revert IndexOutOfBounds();
        return offChainClaims[index];
    }
}
