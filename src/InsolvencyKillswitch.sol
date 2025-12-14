// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Jurisdiction, JurisdictionParams, JurisdictionTemplates} from "./JurisdictionTemplates.sol";

/// @title Insolvency Killswitch
/// @notice Proactive insolvency detection and governance for tokenized funds
/// @dev Monitors redemption queues and enables creditor-governed insolvency proceedings
/// @author Waterfall Protocol

interface IKillswitchToken {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function pause() external;
    function unpause() external;
    function lockTransfers() external;
    function unlockTransfers() external;
}

interface IWaterfallVaultFactory {
    function createVault(
        string memory name,
        uint8 templateType,
        uint8 vaultMode,
        address recoveryToken,
        address[] calldata acceptedAssets,
        uint8[] calldata trancheIndices,
        address[] calldata priceOracles,
        uint256[] calldata manualPrices
    ) external returns (address);
}

contract InsolvencyKillswitch is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using JurisdictionTemplates for Jurisdiction;

    // ============ Enums ============

    enum KillswitchState {
        ACTIVE,             // Normal operation, monitoring redemptions
        BREACH_DETECTED,    // Redemption breach detected, countdown started
        INSOLVENT,          // Insolvency declared, transfers locked
        SETTLEMENT_PROPOSED,// Fund manager proposed settlement
        VOTING,             // Creditors voting on settlement
        SETTLEMENT_ACCEPTED,// Settlement approved, executing
        LIQUIDATION,        // Settlement rejected or timeout, liquidating
        RESOLVED            // Proceedings complete
    }

    enum VoteType {
        NONE,
        APPROVE,
        REJECT
    }

    // ============ Structs ============

    struct RedemptionRequest {
        address creditor;
        uint256 amount;
        uint256 timestamp;
        bool fulfilled;
        bool cancelled;
    }

    struct Settlement {
        uint256 id;
        address proposer;
        uint256 totalOffered;           // Total recovery amount offered
        uint256 haircutBps;             // Haircut percentage (e.g., 2000 = 20% haircut)
        string terms;                   // IPFS hash or description of terms
        uint256 proposedAt;
        uint256 votingEndsAt;
        uint256 approveValueVotes;      // Total value voting approve
        uint256 rejectValueVotes;       // Total value voting reject
        uint256 approveHeadcount;       // Number of addresses voting approve
        uint256 rejectHeadcount;        // Number of addresses voting reject
        bool executed;
        bool rejected;
    }

    struct CreditorSnapshot {
        uint256 balance;
        uint256 snapshotBlock;
        bool hasVoted;
        VoteType vote;
    }

    // ============ State Variables ============

    // Core references
    IKillswitchToken public immutable fundToken;
    IERC20 public immutable recoveryToken;          // e.g., USDC for settlements
    address public immutable fundManager;
    Jurisdiction public immutable jurisdiction;
    JurisdictionParams public jurisdictionParams;

    // Waterfall integration
    IWaterfallVaultFactory public waterfallFactory;
    address public waterfallVault;                  // Created on liquidation

    // State
    KillswitchState public state;
    uint256 public breachDetectedAt;
    uint256 public insolvencyDeclaredAt;
    uint256 public snapshotBlock;
    uint256 public snapshotTotalSupply;

    // Redemption tracking
    RedemptionRequest[] public redemptionQueue;
    uint256 public oldestUnfulfilledIndex;
    uint256 public totalPendingRedemptions;

    // Settlement tracking
    Settlement[] public settlements;
    uint256 public currentSettlementId;
    mapping(uint256 => mapping(address => CreditorSnapshot)) public settlementVotes;

    // Extension tracking
    bool public extensionGranted;
    uint256 public extensionDeposit;
    uint256 public constant EXTENSION_DEPOSIT_BPS = 1000; // 10% of pending redemptions

    // Accumulated recovery funds
    uint256 public recoveryPool;

    // ============ Events ============

    event RedemptionRequested(address indexed creditor, uint256 amount, uint256 index);
    event RedemptionFulfilled(uint256 indexed index, address indexed creditor, uint256 amount);
    event RedemptionCancelled(uint256 indexed index, address indexed creditor);

    event BreachDetected(uint256 timestamp, uint256 oldestRequestAge);
    event BreachCleared(uint256 timestamp);

    event InsolvencyDeclared(uint256 timestamp, uint256 snapshotBlock, uint256 totalSupply);
    event TransfersLocked(uint256 timestamp);

    event SettlementProposed(
        uint256 indexed settlementId,
        address indexed proposer,
        uint256 totalOffered,
        uint256 haircutBps,
        uint256 votingEndsAt
    );
    event VoteCast(
        uint256 indexed settlementId,
        address indexed voter,
        VoteType vote,
        uint256 weight
    );
    event SettlementApproved(uint256 indexed settlementId, uint256 approveValue, uint256 approveCount);
    event SettlementRejected(uint256 indexed settlementId, uint256 rejectValue, uint256 rejectCount);
    event SettlementExecuted(uint256 indexed settlementId, uint256 distributed);

    event ExtensionRequested(address indexed fundManager, uint256 deposit);
    event ExtensionGranted(uint256 newDeadline);

    event LiquidationTriggered(uint256 timestamp, address waterfallVault);
    event RecoveryDeposited(address indexed depositor, uint256 amount);
    event Resolved(uint256 timestamp, uint256 totalRecovered);

    // ============ Errors ============

    error NotFundManager();
    error NotCreditor();
    error InvalidState(KillswitchState current, KillswitchState required);
    error RedemptionNotFound();
    error AlreadyFulfilled();
    error AlreadyCancelled();
    error NoBreachDetected();
    error BreachNotExpired();
    error AlreadyVoted();
    error VotingNotActive();
    error VotingNotEnded();
    error SettlementNotFound();
    error InsufficientDeposit();
    error ExtensionAlreadyUsed();
    error ZeroAmount();
    error TransferFailed();
    error WaterfallNotSet();

    // ============ Modifiers ============

    modifier onlyFundManager() {
        if (msg.sender != fundManager) revert NotFundManager();
        _;
    }

    modifier onlyCreditor() {
        if (fundToken.balanceOf(msg.sender) == 0 &&
            (snapshotBlock == 0 || settlementVotes[currentSettlementId][msg.sender].balance == 0)) {
            revert NotCreditor();
        }
        _;
    }

    modifier inState(KillswitchState required) {
        if (state != required) revert InvalidState(state, required);
        _;
    }

    // ============ Constructor ============

    constructor(
        address _fundToken,
        address _recoveryToken,
        address _fundManager,
        Jurisdiction _jurisdiction,
        address _waterfallFactory
    ) {
        fundToken = IKillswitchToken(_fundToken);
        recoveryToken = IERC20(_recoveryToken);
        fundManager = _fundManager;
        jurisdiction = _jurisdiction;
        jurisdictionParams = _jurisdiction.get();
        waterfallFactory = IWaterfallVaultFactory(_waterfallFactory);
        state = KillswitchState.ACTIVE;
    }

    // ============ Redemption Queue Management ============

    /// @notice Request redemption of fund tokens
    /// @param amount Amount of fund tokens to redeem
    function requestRedemption(uint256 amount) external nonReentrant inState(KillswitchState.ACTIVE) {
        if (amount == 0) revert ZeroAmount();

        redemptionQueue.push(RedemptionRequest({
            creditor: msg.sender,
            amount: amount,
            timestamp: block.timestamp,
            fulfilled: false,
            cancelled: false
        }));

        totalPendingRedemptions += amount;

        emit RedemptionRequested(msg.sender, amount, redemptionQueue.length - 1);

        _checkForBreach();
    }

    /// @notice Fund manager fulfills a redemption request
    /// @param index Index in the redemption queue
    function fulfillRedemption(uint256 index) external nonReentrant onlyFundManager {
        if (index >= redemptionQueue.length) revert RedemptionNotFound();

        RedemptionRequest storage request = redemptionQueue[index];
        if (request.fulfilled) revert AlreadyFulfilled();
        if (request.cancelled) revert AlreadyCancelled();

        request.fulfilled = true;
        totalPendingRedemptions -= request.amount;

        // Transfer recovery tokens to creditor
        recoveryToken.safeTransferFrom(fundManager, request.creditor, request.amount);

        emit RedemptionFulfilled(index, request.creditor, request.amount);

        // Update oldest unfulfilled index
        while (oldestUnfulfilledIndex < redemptionQueue.length &&
               (redemptionQueue[oldestUnfulfilledIndex].fulfilled ||
                redemptionQueue[oldestUnfulfilledIndex].cancelled)) {
            oldestUnfulfilledIndex++;
        }

        // Check if breach is cleared
        if (state == KillswitchState.BREACH_DETECTED) {
            _checkBreachCleared();
        }
    }

    /// @notice Creditor cancels their redemption request
    /// @param index Index in the redemption queue
    function cancelRedemption(uint256 index) external nonReentrant {
        if (index >= redemptionQueue.length) revert RedemptionNotFound();

        RedemptionRequest storage request = redemptionQueue[index];
        if (request.creditor != msg.sender) revert NotCreditor();
        if (request.fulfilled) revert AlreadyFulfilled();
        if (request.cancelled) revert AlreadyCancelled();

        request.cancelled = true;
        totalPendingRedemptions -= request.amount;

        emit RedemptionCancelled(index, msg.sender);

        // Update oldest unfulfilled index
        while (oldestUnfulfilledIndex < redemptionQueue.length &&
               (redemptionQueue[oldestUnfulfilledIndex].fulfilled ||
                redemptionQueue[oldestUnfulfilledIndex].cancelled)) {
            oldestUnfulfilledIndex++;
        }

        if (state == KillswitchState.BREACH_DETECTED) {
            _checkBreachCleared();
        }
    }

    // ============ Breach Detection ============

    /// @notice Check if redemption breach should be detected
    function _checkForBreach() internal {
        if (state != KillswitchState.ACTIVE) return;

        if (oldestUnfulfilledIndex < redemptionQueue.length) {
            RedemptionRequest storage oldest = redemptionQueue[oldestUnfulfilledIndex];
            if (!oldest.fulfilled && !oldest.cancelled) {
                uint256 age = block.timestamp - oldest.timestamp;
                if (age >= jurisdictionParams.timeframes.redemptionBreachPeriod) {
                    state = KillswitchState.BREACH_DETECTED;
                    breachDetectedAt = block.timestamp;
                    emit BreachDetected(block.timestamp, age);
                }
            }
        }
    }

    /// @notice Check if breach has been cleared
    function _checkBreachCleared() internal {
        if (oldestUnfulfilledIndex >= redemptionQueue.length) {
            // All redemptions fulfilled or cancelled
            state = KillswitchState.ACTIVE;
            breachDetectedAt = 0;
            emit BreachCleared(block.timestamp);
            return;
        }

        RedemptionRequest storage oldest = redemptionQueue[oldestUnfulfilledIndex];
        uint256 age = block.timestamp - oldest.timestamp;
        if (age < jurisdictionParams.timeframes.redemptionBreachPeriod) {
            state = KillswitchState.ACTIVE;
            breachDetectedAt = 0;
            emit BreachCleared(block.timestamp);
        }
    }

    /// @notice Anyone can trigger breach check
    function checkBreach() external {
        if (state == KillswitchState.ACTIVE) {
            _checkForBreach();
        }
    }

    // ============ Insolvency Declaration ============

    /// @notice Declare insolvency after breach period expires
    /// @dev Anyone can call this once conditions are met
    function declareInsolvency() external nonReentrant inState(KillswitchState.BREACH_DETECTED) {
        // Check if breach has persisted long enough
        // Using settlement period as grace period after breach detection
        if (block.timestamp < breachDetectedAt + jurisdictionParams.timeframes.settlementPeriod) {
            // Check for extension
            if (!extensionGranted ||
                block.timestamp < breachDetectedAt + jurisdictionParams.timeframes.settlementPeriod + jurisdictionParams.timeframes.extensionPeriod) {
                revert BreachNotExpired();
            }
        }

        // Take snapshot for voting
        snapshotBlock = block.number;
        snapshotTotalSupply = fundToken.totalSupply();
        insolvencyDeclaredAt = block.timestamp;

        // Lock transfers if jurisdiction requires
        if (jurisdictionParams.rules.transferLockOnTrigger) {
            try fundToken.lockTransfers() {
                emit TransfersLocked(block.timestamp);
            } catch {
                // Token may not support locking - continue anyway
            }
        }

        state = KillswitchState.INSOLVENT;

        emit InsolvencyDeclared(block.timestamp, snapshotBlock, snapshotTotalSupply);
    }

    // ============ Settlement Proposals ============

    /// @notice Fund manager proposes a settlement
    /// @param totalOffered Total recovery amount offered
    /// @param haircutBps Haircut in basis points (e.g., 2000 = 20%)
    /// @param terms IPFS hash or description of settlement terms
    function proposeSettlement(
        uint256 totalOffered,
        uint256 haircutBps,
        string calldata terms
    ) external nonReentrant onlyFundManager {
        // Can propose in INSOLVENT or after rejected settlement
        if (state != KillswitchState.INSOLVENT && state != KillswitchState.SETTLEMENT_PROPOSED) {
            revert InvalidState(state, KillswitchState.INSOLVENT);
        }

        // Deposit the offered amount
        recoveryToken.safeTransferFrom(msg.sender, address(this), totalOffered);
        recoveryPool += totalOffered;

        uint256 settlementId = settlements.length;
        settlements.push(Settlement({
            id: settlementId,
            proposer: msg.sender,
            totalOffered: totalOffered,
            haircutBps: haircutBps,
            terms: terms,
            proposedAt: block.timestamp,
            votingEndsAt: block.timestamp + jurisdictionParams.timeframes.votingPeriod,
            approveValueVotes: 0,
            rejectValueVotes: 0,
            approveHeadcount: 0,
            rejectHeadcount: 0,
            executed: false,
            rejected: false
        }));

        currentSettlementId = settlementId;
        state = KillswitchState.VOTING;

        emit SettlementProposed(settlementId, msg.sender, totalOffered, haircutBps, settlements[settlementId].votingEndsAt);
    }

    /// @notice Request extension by posting good faith deposit
    function requestExtension() external nonReentrant onlyFundManager inState(KillswitchState.BREACH_DETECTED) {
        if (extensionGranted) revert ExtensionAlreadyUsed();

        // Calculate required deposit (10% of pending redemptions)
        uint256 requiredDeposit = (totalPendingRedemptions * EXTENSION_DEPOSIT_BPS) / 10000;
        if (requiredDeposit == 0) requiredDeposit = 1; // Minimum 1 token

        recoveryToken.safeTransferFrom(msg.sender, address(this), requiredDeposit);
        extensionDeposit = requiredDeposit;
        extensionGranted = true;
        recoveryPool += requiredDeposit;

        emit ExtensionRequested(msg.sender, requiredDeposit);
        emit ExtensionGranted(breachDetectedAt + jurisdictionParams.timeframes.settlementPeriod + jurisdictionParams.timeframes.extensionPeriod);
    }

    // ============ Voting ============

    /// @notice Cast vote on current settlement
    /// @param vote VoteType.APPROVE or VoteType.REJECT
    function castVote(VoteType vote) external nonReentrant inState(KillswitchState.VOTING) {
        if (vote == VoteType.NONE) revert ZeroAmount();

        Settlement storage settlement = settlements[currentSettlementId];
        if (block.timestamp > settlement.votingEndsAt) revert VotingNotActive();

        CreditorSnapshot storage snapshot = settlementVotes[currentSettlementId][msg.sender];

        // First time voting - record snapshot balance
        if (snapshot.snapshotBlock == 0) {
            // In production, would query historical balance at snapshotBlock
            // For simplicity, using current balance (assumes transfers locked)
            snapshot.balance = fundToken.balanceOf(msg.sender);
            snapshot.snapshotBlock = snapshotBlock;
        }

        if (snapshot.balance == 0) revert NotCreditor();
        if (snapshot.hasVoted) revert AlreadyVoted();

        snapshot.hasVoted = true;
        snapshot.vote = vote;

        if (vote == VoteType.APPROVE) {
            settlement.approveValueVotes += snapshot.balance;
            settlement.approveHeadcount++;
        } else {
            settlement.rejectValueVotes += snapshot.balance;
            settlement.rejectHeadcount++;
        }

        emit VoteCast(currentSettlementId, msg.sender, vote, snapshot.balance);
    }

    /// @notice Finalize voting and determine outcome
    function finalizeVote() external nonReentrant inState(KillswitchState.VOTING) {
        Settlement storage settlement = settlements[currentSettlementId];
        if (block.timestamp <= settlement.votingEndsAt) revert VotingNotEnded();

        uint256 totalVoted = settlement.approveValueVotes + settlement.rejectValueVotes;
        uint256 totalHeadcount = settlement.approveHeadcount + settlement.rejectHeadcount;

        // Check quorum
        bool quorumMet = (totalVoted * 10000) / snapshotTotalSupply >= jurisdictionParams.voting.vetoQuorumBps;

        bool approved = false;

        if (quorumMet) {
            // Check value threshold
            bool valueApproved = (settlement.approveValueVotes * 10000) / totalVoted >= jurisdictionParams.voting.approvalThresholdBps;

            // Check headcount if required
            bool headcountApproved = true;
            if (jurisdictionParams.voting.requiresDualTest && jurisdictionParams.voting.approvalHeadcountBps > 0) {
                headcountApproved = (settlement.approveHeadcount * 10000) / totalHeadcount >= jurisdictionParams.voting.approvalHeadcountBps;
            }

            approved = jurisdictionParams.voting.requiresDualTest ? (valueApproved && headcountApproved) : valueApproved;
        }

        if (approved) {
            settlement.executed = false; // Will be executed separately
            state = KillswitchState.SETTLEMENT_ACCEPTED;
            emit SettlementApproved(currentSettlementId, settlement.approveValueVotes, settlement.approveHeadcount);
        } else {
            settlement.rejected = true;
            // Return to insolvent state - fund manager can propose again or timeout triggers liquidation
            state = KillswitchState.INSOLVENT;
            emit SettlementRejected(currentSettlementId, settlement.rejectValueVotes, settlement.rejectHeadcount);
        }
    }

    // ============ Settlement Execution ============

    /// @notice Execute approved settlement - creates Waterfall vault
    function executeSettlement() external nonReentrant inState(KillswitchState.SETTLEMENT_ACCEPTED) {
        Settlement storage settlement = settlements[currentSettlementId];
        if (settlement.executed) revert AlreadyFulfilled();

        settlement.executed = true;

        // Create Waterfall vault for distribution
        _createWaterfallVault();

        // Transfer recovery pool to Waterfall vault
        if (recoveryPool > 0) {
            recoveryToken.safeTransfer(waterfallVault, recoveryPool);
            emit SettlementExecuted(currentSettlementId, recoveryPool);
            recoveryPool = 0;
        }

        state = KillswitchState.RESOLVED;
        emit Resolved(block.timestamp, settlement.totalOffered);
    }

    // ============ Liquidation (Default Judgment) ============

    /// @notice Trigger liquidation after settlement timeout
    /// @dev Anyone can call after settlementPeriod expires without accepted settlement
    function triggerLiquidation() external nonReentrant {
        // Can trigger from INSOLVENT (no proposal) or after rejected settlement
        if (state != KillswitchState.INSOLVENT) {
            revert InvalidState(state, KillswitchState.INSOLVENT);
        }

        // Check if settlement period has expired
        uint256 deadline = insolvencyDeclaredAt + jurisdictionParams.timeframes.settlementPeriod;
        if (extensionGranted) {
            deadline += jurisdictionParams.timeframes.extensionPeriod;
        }

        if (block.timestamp < deadline) {
            revert BreachNotExpired();
        }

        state = KillswitchState.LIQUIDATION;

        // Create Waterfall vault for distribution
        _createWaterfallVault();

        emit LiquidationTriggered(block.timestamp, waterfallVault);

        // Transfer any recovery pool to vault
        if (recoveryPool > 0) {
            recoveryToken.safeTransfer(waterfallVault, recoveryPool);
            recoveryPool = 0;
        }

        state = KillswitchState.RESOLVED;
        emit Resolved(block.timestamp, recoveryPool);
    }

    /// @notice Deposit recovery funds (from fund manager or external sources)
    function depositRecovery(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        recoveryToken.safeTransferFrom(msg.sender, address(this), amount);
        recoveryPool += amount;

        emit RecoveryDeposited(msg.sender, amount);
    }

    // ============ Waterfall Integration ============

    /// @notice Create Waterfall vault for distribution
    function _createWaterfallVault() internal {
        if (address(waterfallFactory) == address(0)) revert WaterfallNotSet();

        // Prepare parameters for vault creation
        address[] memory acceptedAssets = new address[](1);
        acceptedAssets[0] = address(fundToken);

        uint8[] memory trancheIndices = new uint8[](1);
        trancheIndices[0] = 0; // Single tranche (pari passu)

        address[] memory priceOracles = new address[](1);
        priceOracles[0] = address(0); // Manual price

        uint256[] memory manualPrices = new uint256[](1);
        manualPrices[0] = 1e18; // 1:1

        // Create vault with PARI_PASSU template (index 3)
        // VaultMode.WHOLE_SUPPLY (index 1) so all token holders are creditors
        waterfallVault = waterfallFactory.createVault(
            string(abi.encodePacked("Insolvency: ", jurisdictionParams.name)),
            3,  // PARI_PASSU
            1,  // WHOLE_SUPPLY
            address(recoveryToken),
            acceptedAssets,
            trancheIndices,
            priceOracles,
            manualPrices
        );
    }

    /// @notice Set Waterfall factory (can only be set once if not set in constructor)
    function setWaterfallFactory(address _factory) external onlyFundManager {
        if (address(waterfallFactory) != address(0)) revert WaterfallNotSet();
        waterfallFactory = IWaterfallVaultFactory(_factory);
    }

    // ============ View Functions ============

    /// @notice Get current state as string
    function getStateString() external view returns (string memory) {
        if (state == KillswitchState.ACTIVE) return "ACTIVE";
        if (state == KillswitchState.BREACH_DETECTED) return "BREACH_DETECTED";
        if (state == KillswitchState.INSOLVENT) return "INSOLVENT";
        if (state == KillswitchState.SETTLEMENT_PROPOSED) return "SETTLEMENT_PROPOSED";
        if (state == KillswitchState.VOTING) return "VOTING";
        if (state == KillswitchState.SETTLEMENT_ACCEPTED) return "SETTLEMENT_ACCEPTED";
        if (state == KillswitchState.LIQUIDATION) return "LIQUIDATION";
        if (state == KillswitchState.RESOLVED) return "RESOLVED";
        return "UNKNOWN";
    }

    /// @notice Get jurisdiction parameters
    function getJurisdictionParams() external view returns (JurisdictionParams memory) {
        return jurisdictionParams;
    }

    /// @notice Get redemption queue length
    function getRedemptionQueueLength() external view returns (uint256) {
        return redemptionQueue.length;
    }

    /// @notice Get settlement count
    function getSettlementCount() external view returns (uint256) {
        return settlements.length;
    }

    /// @notice Get current settlement details
    function getCurrentSettlement() external view returns (Settlement memory) {
        if (settlements.length == 0) {
            return Settlement(0, address(0), 0, 0, "", 0, 0, 0, 0, 0, 0, false, false);
        }
        return settlements[currentSettlementId];
    }

    /// @notice Get voter's snapshot for current settlement
    function getVoterSnapshot(address voter) external view returns (CreditorSnapshot memory) {
        return settlementVotes[currentSettlementId][voter];
    }

    /// @notice Calculate time until default judgment
    function timeUntilDefaultJudgment() external view returns (uint256) {
        if (state != KillswitchState.INSOLVENT && state != KillswitchState.BREACH_DETECTED) {
            return type(uint256).max;
        }

        uint256 baseTime = state == KillswitchState.INSOLVENT ? insolvencyDeclaredAt : breachDetectedAt;
        uint256 deadline = baseTime + jurisdictionParams.timeframes.settlementPeriod;

        if (extensionGranted) {
            deadline += jurisdictionParams.timeframes.extensionPeriod;
        }

        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /// @notice Get oldest unfulfilled redemption age
    function getOldestRedemptionAge() external view returns (uint256) {
        if (oldestUnfulfilledIndex >= redemptionQueue.length) return 0;

        RedemptionRequest storage request = redemptionQueue[oldestUnfulfilledIndex];
        if (request.fulfilled || request.cancelled) return 0;

        return block.timestamp - request.timestamp;
    }

    /// @notice Check if settlement would pass with current votes
    function wouldSettlementPass() external view returns (bool valuePass, bool headcountPass, bool quorumMet) {
        if (settlements.length == 0) return (false, false, false);

        Settlement storage settlement = settlements[currentSettlementId];
        uint256 totalVoted = settlement.approveValueVotes + settlement.rejectValueVotes;
        uint256 totalHeadcount = settlement.approveHeadcount + settlement.rejectHeadcount;

        if (totalVoted == 0) return (false, false, false);

        quorumMet = (totalVoted * 10000) / snapshotTotalSupply >= jurisdictionParams.voting.vetoQuorumBps;
        valuePass = (settlement.approveValueVotes * 10000) / totalVoted >= jurisdictionParams.voting.approvalThresholdBps;

        if (jurisdictionParams.voting.requiresDualTest && totalHeadcount > 0) {
            headcountPass = (settlement.approveHeadcount * 10000) / totalHeadcount >= jurisdictionParams.voting.approvalHeadcountBps;
        } else {
            headcountPass = true;
        }
    }
}
