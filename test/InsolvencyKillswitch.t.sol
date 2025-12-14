// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/InsolvencyKillswitch.sol";
import "../src/JurisdictionTemplates.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock fund token with transfer lock capability
contract MockFundToken is ERC20 {
    bool public transfersLocked;
    address public killswitch;

    constructor() ERC20("Mock Fund Token", "MFT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setKillswitch(address _killswitch) external {
        killswitch = _killswitch;
    }

    function lockTransfers() external {
        require(msg.sender == killswitch, "Only killswitch");
        transfersLocked = true;
    }

    function unlockTransfers() external {
        require(msg.sender == killswitch, "Only killswitch");
        transfersLocked = false;
    }

    function _update(address from, address to, uint256 amount) internal virtual override {
        if (transfersLocked && from != address(0) && to != address(0)) {
            revert("Transfers locked");
        }
        super._update(from, to, amount);
    }
}

// Mock recovery token (e.g., USDC)
contract MockRecoveryToken is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract InsolvencyKillswitchTest is Test {
    using JurisdictionTemplates for Jurisdiction;

    InsolvencyKillswitch public killswitch;
    MockFundToken public fundToken;
    MockRecoveryToken public usdc;

    address public fundManager = address(0x1);
    address public creditor1 = address(0x2);
    address public creditor2 = address(0x3);
    address public creditor3 = address(0x4);

    function setUp() public {
        fundToken = new MockFundToken();
        usdc = new MockRecoveryToken();

        killswitch = new InsolvencyKillswitch(
            address(fundToken),
            address(usdc),
            fundManager,
            Jurisdiction.DEFI_STANDARD,
            address(0) // No waterfall factory for these tests
        );

        fundToken.setKillswitch(address(killswitch));

        // Mint fund tokens to creditors
        fundToken.mint(creditor1, 1000e18);
        fundToken.mint(creditor2, 2000e18);
        fundToken.mint(creditor3, 7000e18);

        // Mint USDC to fund manager for settlements
        usdc.mint(fundManager, 10_000_000e6);
        vm.prank(fundManager);
        usdc.approve(address(killswitch), type(uint256).max);
    }

    // ========== State Tests ==========

    function test_InitialState() public view {
        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.ACTIVE));
        assertEq(killswitch.getStateString(), "ACTIVE");
        assertEq(killswitch.getRedemptionQueueLength(), 0);
        assertEq(killswitch.totalPendingRedemptions(), 0);
    }

    function test_JurisdictionParams() public view {
        JurisdictionParams memory p = killswitch.getJurisdictionParams();
        assertEq(p.name, "DeFi Standard");
        assertEq(p.voting.approvalThresholdBps, 6667);
        assertTrue(p.voting.requiresDualTest);
    }

    // ========== Redemption Queue Tests ==========

    function test_RequestRedemption() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        assertEq(killswitch.getRedemptionQueueLength(), 1);
        assertEq(killswitch.totalPendingRedemptions(), 500e18);

        (address creditor, uint256 amount, uint256 timestamp, bool fulfilled, bool cancelled) =
            killswitch.redemptionQueue(0);
        assertEq(creditor, creditor1);
        assertEq(amount, 500e18);
        assertEq(timestamp, block.timestamp);
        assertFalse(fulfilled);
        assertFalse(cancelled);
    }

    function test_RequestRedemption_RevertZeroAmount() public {
        vm.prank(creditor1);
        vm.expectRevert(InsolvencyKillswitch.ZeroAmount.selector);
        killswitch.requestRedemption(0);
    }

    function test_FulfillRedemption() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e6); // Use USDC decimals

        vm.prank(fundManager);
        killswitch.fulfillRedemption(0);

        (,,,bool fulfilled,) = killswitch.redemptionQueue(0);
        assertTrue(fulfilled);
        assertEq(killswitch.totalPendingRedemptions(), 0);
        assertEq(usdc.balanceOf(creditor1), 500e6);
    }

    function test_CancelRedemption() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        vm.prank(creditor1);
        killswitch.cancelRedemption(0);

        (,,,,bool cancelled) = killswitch.redemptionQueue(0);
        assertTrue(cancelled);
        assertEq(killswitch.totalPendingRedemptions(), 0);
    }

    function test_CancelRedemption_RevertNotCreditor() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        vm.prank(creditor2);
        vm.expectRevert(InsolvencyKillswitch.NotCreditor.selector);
        killswitch.cancelRedemption(0);
    }

    // ========== Breach Detection Tests ==========

    function test_BreachDetection_AfterSevenDays() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        // Before 7 days - no breach
        vm.warp(block.timestamp + 6 days);
        killswitch.checkBreach();
        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.ACTIVE));

        // After 7 days - breach detected
        vm.warp(block.timestamp + 2 days);
        killswitch.checkBreach();
        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.BREACH_DETECTED));
        assertEq(killswitch.getStateString(), "BREACH_DETECTED");
    }

    function test_BreachCleared_WhenFulfilled() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e6); // Use USDC decimals

        // Trigger breach
        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();
        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.BREACH_DETECTED));

        // Fulfill redemption - breach should clear
        vm.prank(fundManager);
        killswitch.fulfillRedemption(0);

        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.ACTIVE));
    }

    function test_GetOldestRedemptionAge() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        assertEq(killswitch.getOldestRedemptionAge(), 0);

        vm.warp(block.timestamp + 3 days);
        assertEq(killswitch.getOldestRedemptionAge(), 3 days);
    }

    // ========== Insolvency Declaration Tests ==========

    function test_DeclareInsolvency() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        // Trigger breach
        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        // Wait for settlement period (30 days for DeFi Standard)
        vm.warp(block.timestamp + 31 days);

        // Declare insolvency
        killswitch.declareInsolvency();

        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.INSOLVENT));
        assertTrue(fundToken.transfersLocked());
        assertGt(killswitch.snapshotBlock(), 0);
        assertEq(killswitch.snapshotTotalSupply(), 10000e18); // 1000 + 2000 + 7000
    }

    function test_DeclareInsolvency_RevertIfBreachNotExpired() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        // Try to declare too early
        vm.warp(block.timestamp + 10 days); // Only 10 days, need 30
        vm.expectRevert(InsolvencyKillswitch.BreachNotExpired.selector);
        killswitch.declareInsolvency();
    }

    // ========== Extension Tests ==========

    function test_RequestExtension() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e6); // Use USDC decimals

        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        // Request extension with 10% deposit
        vm.prank(fundManager);
        killswitch.requestExtension();

        assertTrue(killswitch.extensionGranted());
        assertEq(killswitch.extensionDeposit(), 50e6); // 10% of 500e6
    }

    function test_RequestExtension_RevertIfAlreadyGranted() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e6); // Use USDC decimals

        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        vm.prank(fundManager);
        killswitch.requestExtension();

        vm.prank(fundManager);
        vm.expectRevert(InsolvencyKillswitch.ExtensionAlreadyUsed.selector);
        killswitch.requestExtension();
    }

    // ========== Settlement Tests ==========

    function test_ProposeSettlement() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://settlement-terms");

        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.VOTING));
        assertEq(killswitch.getSettlementCount(), 1);

        InsolvencyKillswitch.Settlement memory s = killswitch.getCurrentSettlement();
        assertEq(s.id, 0);
        assertEq(s.proposer, fundManager);
        assertEq(s.totalOffered, 800_000e6);
        assertEq(s.haircutBps, 2000); // 20% haircut
    }

    function test_CastVote_Approve() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        // Creditor 3 votes approve (70% of supply)
        vm.prank(creditor3);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        InsolvencyKillswitch.Settlement memory s = killswitch.getCurrentSettlement();
        assertEq(s.approveValueVotes, 7000e18);
        assertEq(s.approveHeadcount, 1);
    }

    function test_CastVote_Reject() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        vm.prank(creditor1);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);

        InsolvencyKillswitch.Settlement memory s = killswitch.getCurrentSettlement();
        assertEq(s.rejectValueVotes, 1000e18);
        assertEq(s.rejectHeadcount, 1);
    }

    function test_CastVote_RevertIfAlreadyVoted() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        vm.prank(creditor1);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        vm.prank(creditor1);
        vm.expectRevert(InsolvencyKillswitch.AlreadyVoted.selector);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);
    }

    function test_FinalizeVote_Approved() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        // All creditors vote approve (100% approval)
        vm.prank(creditor1);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);
        vm.prank(creditor2);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);
        vm.prank(creditor3);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        // Warp past voting period (14 days for DeFi Standard)
        vm.warp(block.timestamp + 15 days);

        killswitch.finalizeVote();

        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.SETTLEMENT_ACCEPTED));
    }

    function test_FinalizeVote_Rejected() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        // Majority rejects
        vm.prank(creditor1);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);
        vm.prank(creditor2);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);
        vm.prank(creditor3);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);

        vm.warp(block.timestamp + 15 days);

        killswitch.finalizeVote();

        // Back to INSOLVENT (can propose again or timeout triggers liquidation)
        assertEq(uint256(killswitch.state()), uint256(InsolvencyKillswitch.KillswitchState.INSOLVENT));
    }

    function test_FinalizeVote_RevertIfVotingNotEnded() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        vm.prank(creditor3);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        vm.expectRevert(InsolvencyKillswitch.VotingNotEnded.selector);
        killswitch.finalizeVote();
    }

    function test_WouldSettlementPass() public {
        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        // Before votes
        (bool valuePass, bool headcountPass, bool quorumMet) = killswitch.wouldSettlementPass();
        assertFalse(valuePass);
        assertFalse(quorumMet);

        // Creditor 3 votes (70% of supply)
        vm.prank(creditor3);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        // DeFi Standard requires 66.67% value + 50% headcount
        // 70% value passes, and 1/1 headcount of voters = 100%
        (valuePass, headcountPass, quorumMet) = killswitch.wouldSettlementPass();
        assertTrue(valuePass);
        assertTrue(headcountPass); // 1/1 = 100% of voters voted approve
        assertTrue(quorumMet);
    }

    // ========== Liquidation Tests ==========

    function test_TriggerLiquidation_AfterTimeout() public {
        _declareInsolvency();

        // Wait for settlement period (30 days) without proposal
        vm.warp(block.timestamp + 31 days);

        // This will revert because waterfallFactory is not set
        vm.expectRevert(InsolvencyKillswitch.WaterfallNotSet.selector);
        killswitch.triggerLiquidation();
    }

    function test_TimeUntilDefaultJudgment() public {
        _declareInsolvency();

        uint256 timeLeft = killswitch.timeUntilDefaultJudgment();
        assertEq(timeLeft, 30 days); // Full settlement period

        vm.warp(block.timestamp + 10 days);
        timeLeft = killswitch.timeUntilDefaultJudgment();
        assertEq(timeLeft, 20 days);

        vm.warp(block.timestamp + 25 days);
        timeLeft = killswitch.timeUntilDefaultJudgment();
        assertEq(timeLeft, 0); // Expired
    }

    // ========== Recovery Pool Tests ==========

    function test_DepositRecovery() public {
        usdc.mint(address(this), 100_000e6);
        usdc.approve(address(killswitch), 100_000e6);

        killswitch.depositRecovery(100_000e6);

        assertEq(killswitch.recoveryPool(), 100_000e6);
    }

    function test_DepositRecovery_RevertZeroAmount() public {
        vm.expectRevert(InsolvencyKillswitch.ZeroAmount.selector);
        killswitch.depositRecovery(0);
    }

    // ========== Access Control Tests ==========

    function test_FulfillRedemption_RevertNotFundManager() public {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        vm.prank(creditor2);
        vm.expectRevert(InsolvencyKillswitch.NotFundManager.selector);
        killswitch.fulfillRedemption(0);
    }

    function test_ProposeSettlement_RevertNotFundManager() public {
        _declareInsolvency();

        vm.prank(creditor1);
        vm.expectRevert(InsolvencyKillswitch.NotFundManager.selector);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");
    }

    // ========== Helper Functions ==========

    function _declareInsolvency() internal {
        vm.prank(creditor1);
        killswitch.requestRedemption(500e18);

        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        vm.warp(block.timestamp + 31 days);
        killswitch.declareInsolvency();
    }
}

// ========== Jurisdiction-Specific Tests ==========

contract InsolvencyKillswitchUSChapter11Test is Test {
    using JurisdictionTemplates for Jurisdiction;

    InsolvencyKillswitch public killswitch;
    MockFundToken public fundToken;
    MockRecoveryToken public usdc;

    address public fundManager = address(0x1);
    address public creditor1 = address(0x2);
    address public creditor2 = address(0x3);
    address public creditor3 = address(0x4);
    address public creditor4 = address(0x5);

    function setUp() public {
        fundToken = new MockFundToken();
        usdc = new MockRecoveryToken();

        killswitch = new InsolvencyKillswitch(
            address(fundToken),
            address(usdc),
            fundManager,
            Jurisdiction.US_CHAPTER_11,
            address(0)
        );

        fundToken.setKillswitch(address(killswitch));

        // Create 4 creditors for headcount testing
        // Total 10,000 tokens
        fundToken.mint(creditor1, 1000e18); // 10%
        fundToken.mint(creditor2, 1000e18); // 10%
        fundToken.mint(creditor3, 1000e18); // 10%
        fundToken.mint(creditor4, 7000e18); // 70%

        usdc.mint(fundManager, 10_000_000e6);
        vm.prank(fundManager);
        usdc.approve(address(killswitch), type(uint256).max);
    }

    function test_USChapter11_RequiresBothValueAndHeadcount() public {
        // US Chapter 11: 66.67% value AND >50% headcount
        // Headcount is based on voters, not total supply holders

        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        // Creditor 4 alone has 70% value - 100% headcount of those who voted
        vm.prank(creditor4);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        (bool valuePass, bool headcountPass, bool quorumMet) = killswitch.wouldSettlementPass();
        assertTrue(valuePass); // 70% > 66.67%
        assertTrue(headcountPass); // 1/1 = 100% of voters voted approve
        assertTrue(quorumMet);

        // Now test a split vote scenario
        vm.prank(creditor1);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);
        vm.prank(creditor2);
        killswitch.castVote(InsolvencyKillswitch.VoteType.REJECT);

        // Now: 70% value approve, 20% value reject = 70/90 = 77.7% by value
        // Headcount: 1 approve, 2 reject = 1/3 = 33% approve
        (valuePass, headcountPass, quorumMet) = killswitch.wouldSettlementPass();
        assertTrue(valuePass); // 77.7% > 66.67%
        assertFalse(headcountPass); // 1/3 = 33% < 50%
        assertTrue(quorumMet);
    }

    function test_USChapter11_25DayVotingPeriod() public {
        JurisdictionParams memory p = killswitch.getJurisdictionParams();
        assertEq(p.timeframes.votingPeriod, 25 days);
    }

    function _declareInsolvency() internal {
        vm.prank(creditor1);
        killswitch.requestRedemption(100e18);

        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        vm.warp(block.timestamp + 31 days);
        killswitch.declareInsolvency();
    }
}

contract InsolvencyKillswitchGermanyStaRUGTest is Test {
    using JurisdictionTemplates for Jurisdiction;

    InsolvencyKillswitch public killswitch;
    MockFundToken public fundToken;
    MockRecoveryToken public usdc;

    address public fundManager = address(0x1);
    address public creditor1 = address(0x2);
    address public creditor2 = address(0x3);

    function setUp() public {
        fundToken = new MockFundToken();
        usdc = new MockRecoveryToken();

        killswitch = new InsolvencyKillswitch(
            address(fundToken),
            address(usdc),
            fundManager,
            Jurisdiction.GERMANY_STARUG,
            address(0)
        );

        fundToken.setKillswitch(address(killswitch));

        fundToken.mint(creditor1, 2500e18); // 25%
        fundToken.mint(creditor2, 7500e18); // 75%

        usdc.mint(fundManager, 10_000_000e6);
        vm.prank(fundManager);
        usdc.approve(address(killswitch), type(uint256).max);
    }

    function test_StaRUG_ValueOnlyNoHeadcount() public {
        // StaRUG: 75% by value only, no headcount requirement

        _declareInsolvency();

        vm.prank(fundManager);
        killswitch.proposeSettlement(800_000e6, 2000, "ipfs://terms");

        // Creditor 2 alone has exactly 75%
        vm.prank(creditor2);
        killswitch.castVote(InsolvencyKillswitch.VoteType.APPROVE);

        (bool valuePass, bool headcountPass,) = killswitch.wouldSettlementPass();
        assertTrue(valuePass); // 75% = 75% threshold
        assertTrue(headcountPass); // No headcount requirement, always true
    }

    function test_StaRUG_21DayPeriods() public {
        JurisdictionParams memory p = killswitch.getJurisdictionParams();
        assertEq(p.timeframes.settlementPeriod, 21 days);
        assertEq(p.timeframes.votingPeriod, 21 days);
    }

    function _declareInsolvency() internal {
        vm.prank(creditor1);
        killswitch.requestRedemption(100e18);

        vm.warp(block.timestamp + 8 days);
        killswitch.checkBreach();

        // StaRUG has 21-day settlement period
        vm.warp(block.timestamp + 22 days);
        killswitch.declareInsolvency();
    }
}
