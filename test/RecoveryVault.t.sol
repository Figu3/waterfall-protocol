// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/VaultFactory.sol";
import "../src/RecoveryVault.sol";
import "../src/Templates.sol";
import "../src/TrancheIOU.sol";
import "./mocks/MockERC20.sol";
import "./mocks/MockOracle.sol";

contract RecoveryVaultTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD; // Distressed stablecoin (senior)
    MockERC20 public lpToken; // LP token (junior)
    MockERC20 public usdc; // Recovery token

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public charlie = address(0xC);
    address public recoverer = address(0xDEAD);

    uint256 constant PRECISION = 1e18;

    function setUp() public {
        // Deploy tokens
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        lpToken = new MockERC20("Stream LP", "sLP", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Deploy factory
        factory = new VaultFactory(treasury);

        // Create vault with 2 tranches (debt/equity)
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](2);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0, // Senior
            priceOracle: address(0),
            manualPrice: 1e18 // $1
        });
        assets[1] = RecoveryVault.AssetConfig({
            assetAddress: address(lpToken),
            trancheIndex: 1, // Junior
            priceOracle: address(0),
            manualPrice: 1e18 // $1
        });

        RecoveryVault.OffChainClaim[] memory offChainClaims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Stream Recovery",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            offChainClaims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        // Mint tokens to users
        xUSD.mint(alice, 1_000_000e18);
        xUSD.mint(bob, 1_000_000e18);
        lpToken.mint(charlie, 500_000e18);
        usdc.mint(recoverer, 10_000_000e6);

        // Approve vault
        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        xUSD.approve(address(vault), type(uint256).max);
        vm.prank(charlie);
        lpToken.approve(address(vault), type(uint256).max);
        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Deposit Tests ============

    function test_Deposit() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        (, address iouToken, uint256 supply,) = vault.getTrancheInfo(0);
        assertEq(supply, 100_000e18);
        assertEq(TrancheIOU(iouToken).balanceOf(alice), 100_000e18);
    }

    function test_Deposit_MultipleUsers() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(bob);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 200_000e18);

        (,, uint256 seniorSupply,) = vault.getTrancheInfo(0);
        (,, uint256 juniorSupply,) = vault.getTrancheInfo(1);

        assertEq(seniorSupply, 800_000e18);
        assertEq(juniorSupply, 200_000e18);
    }

    function test_Deposit_RevertIfAssetNotAccepted() public {
        MockERC20 randomToken = new MockERC20("Random", "RND", 18);
        randomToken.mint(alice, 1000e18);

        vm.prank(alice);
        randomToken.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(RecoveryVault.AssetNotAccepted.selector);
        vault.deposit(address(randomToken), 1000e18);
    }

    function test_Deposit_RevertIfZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryVault.ZeroAmount.selector);
        vault.deposit(address(xUSD), 0);
    }

    function test_Deposit_RevertIfDepositsClosed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Deposits should be closed now
        vm.prank(alice);
        vm.expectRevert(RecoveryVault.DepositsAreClosed.selector);
        vault.deposit(address(xUSD), 100_000e18);
    }

    // ============ Recovery Deposit Tests ============

    function test_DepositRecovery() public {
        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        assertEq(vault.pendingRecovery(), 500_000e6);
    }

    function test_DepositRecovery_RevertIfZeroAmount() public {
        vm.prank(recoverer);
        vm.expectRevert(RecoveryVault.ZeroAmount.selector);
        vault.depositRecovery(0);
    }

    // ============ Harvest Initiation Tests ============

    function test_InitiateHarvest() public {
        // Setup deposits
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        // Initiate harvest
        bytes32 merkleRoot = keccak256("test");
        vault.initiateHarvest(merkleRoot, block.number);

        (bytes32 root, uint256 snapshotBlock, uint256 amount,,,,,,,) = vault.getRoundInfo(0);

        assertEq(root, merkleRoot);
        assertEq(snapshotBlock, block.number);
        assertEq(amount, 500_000e6);
        assertEq(vault.pendingRecovery(), 0);
    }

    function test_InitiateHarvest_ClosesDepositsInWrappedOnlyMode() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        assertTrue(vault.depositsOpen());

        vault.initiateHarvest(keccak256("test"), block.number);

        assertFalse(vault.depositsOpen());
    }

    function test_InitiateHarvest_RevertIfNoRecovery() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.expectRevert(RecoveryVault.NoRecoveryToDistribute.selector);
        vault.initiateHarvest(keccak256("test"), block.number);
    }

    // ============ Veto Tests ============

    function test_Veto() public {
        // Setup
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(bob);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Alice vetos (500k / 800k = 62.5% > 10%)
        vm.prank(alice);
        vault.veto(0);

        (,,,,,, bool vetoed,,,) = vault.getRoundInfo(0);
        assertTrue(vetoed);
        assertEq(vault.pendingRecovery(), 500_000e6); // Returned to pending
    }

    function test_Veto_NotEnoughWeight() public {
        // Setup with more users to dilute
        vm.prank(alice);
        vault.deposit(address(xUSD), 50_000e18); // 5%

        vm.prank(bob);
        vault.deposit(address(xUSD), 300_000e18);

        xUSD.mint(address(0x999), 650_000e18);
        vm.prank(address(0x999));
        xUSD.approve(address(vault), type(uint256).max);
        vm.prank(address(0x999));
        vault.deposit(address(xUSD), 650_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Alice vetos (50k / 1M = 5% < 10%)
        vm.prank(alice);
        vault.veto(0);

        (,,,,,, bool vetoed,,,) = vault.getRoundInfo(0);
        assertFalse(vetoed); // Not enough weight to veto
    }

    function test_Veto_RevertIfTimelockPassed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Warp past timelock
        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(alice);
        vm.expectRevert(RecoveryVault.TimelockPassed.selector);
        vault.veto(0);
    }

    function test_Veto_RevertIfAlreadyVetoed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        vm.prank(alice);
        vault.veto(0);

        vm.prank(alice);
        vm.expectRevert(RecoveryVault.AlreadyVetoed.selector);
        vault.veto(0);
    }

    function test_Veto_RevertIfRoundDoesNotExist() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(alice);
        vm.expectRevert(RecoveryVault.RoundDoesNotExist.selector);
        vault.veto(0);
    }

    function test_Veto_RevertIfRoundAlreadyVetoed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(bob);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Alice vetos successfully
        vm.prank(alice);
        vault.veto(0);

        // Bob tries to veto already vetoed round
        vm.prank(bob);
        vm.expectRevert(RecoveryVault.RoundAlreadyVetoed.selector);
        vault.veto(0);
    }

    function test_Veto_RevertIfNoVotingPower() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Random address with no IOUs tries to veto
        vm.prank(address(0x999));
        vm.expectRevert(RecoveryVault.NoVotingPower.selector);
        vault.veto(0);
    }

    // ============ Execute Harvest Tests ============

    function test_ExecuteHarvest() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Warp past timelock
        vm.warp(block.timestamp + 3 days + 1);

        uint256 harvesterBalanceBefore = usdc.balanceOf(address(this));

        vault.executeHarvest(0);

        (,,,,,,, bool executed,,) = vault.getRoundInfo(0);

        assertTrue(executed);

        // Harvester should receive 0.01% fee
        uint256 expectedFee = (500_000e6 * 1) / 10000;
        assertEq(usdc.balanceOf(address(this)) - harvesterBalanceBefore, expectedFee);
    }

    function test_ExecuteHarvest_RevertIfTimelockNotPassed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        vm.expectRevert(RecoveryVault.TimelockNotPassed.selector);
        vault.executeHarvest(0);
    }

    function test_ExecuteHarvest_RevertIfVetoed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        vm.prank(alice);
        vault.veto(0);

        vm.warp(block.timestamp + 3 days + 1);

        vm.expectRevert(RecoveryVault.RoundAlreadyVetoed.selector);
        vault.executeHarvest(0);
    }

    function test_ExecuteHarvest_RevertIfRoundDoesNotExist() public {
        vm.expectRevert(RecoveryVault.RoundDoesNotExist.selector);
        vault.executeHarvest(0);
    }

    function test_ExecuteHarvest_RevertIfAlreadyExecuted() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.expectRevert(RecoveryVault.RoundAlreadyExecuted.selector);
        vault.executeHarvest(0);
    }

    // ============ Claim Tests ============

    function test_Claim_FullRecovery() public {
        // Senior gets 800k, Junior gets 200k
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(bob);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 200_000e18);

        // Full recovery: 1M USDC
        vm.prank(recoverer);
        vault.depositRecovery(1_000_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.prank(alice);
        vault.claim(0);

        // Alice's IOUs should be burned
        (, address seniorIOU,,) = vault.getTrancheInfo(0);
        assertEq(TrancheIOU(seniorIOU).balanceOf(alice), 0);
    }

    function test_Claim_PartialRecovery_WaterfallOrder() public {
        // Senior: 800k, Junior: 200k
        vm.prank(alice);
        vault.deposit(address(xUSD), 800_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 200_000e18);

        // Partial recovery: 400k USDC (50% of senior)
        vm.prank(recoverer);
        vault.depositRecovery(400_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Senior should get everything, Junior gets nothing
        uint256 aliceClaimable = vault.getClaimable(alice, 0);
        uint256 charlieClaimable = vault.getClaimable(charlie, 0);

        assertTrue(aliceClaimable > 0);
        assertEq(charlieClaimable, 0);

        vm.prank(alice);
        vault.claim(0);
    }

    function test_Claim_RevertIfAlreadyClaimed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.prank(alice);
        vault.claim(0);

        vm.prank(alice);
        vm.expectRevert(RecoveryVault.AlreadyClaimedRound.selector);
        vault.claim(0);
    }

    function test_Claim_RevertIfRoundDoesNotExist() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryVault.RoundDoesNotExist.selector);
        vault.claim(0);
    }

    function test_Claim_RevertIfRoundNotExecuted() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        vm.prank(alice);
        vm.expectRevert(RecoveryVault.RoundNotExecuted.selector);
        vault.claim(0);
    }

    function test_Claim_RevertIfNothingToClaim() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Bob didn't deposit anything
        vm.prank(bob);
        vm.expectRevert(RecoveryVault.NothingToClaim.selector);
        vault.claim(0);
    }

    // ============ Multiple Rounds Tests ============

    function test_MultipleRecoveryRounds() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 800_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 200_000e18);

        // Round 1: 400k recovery
        vm.prank(recoverer);
        vault.depositRecovery(400_000e6);

        vault.initiateHarvest(keccak256("round1"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.prank(alice);
        vault.claim(0);

        // Round 2: Another 400k recovery
        usdc.mint(recoverer, 400_000e6);
        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(recoverer);
        vault.depositRecovery(400_000e6);

        vault.initiateHarvest(keccak256("round2"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(1);

        // Alice can claim round 2
        uint256 aliceClaimable = vault.getClaimable(alice, 1);
        assertTrue(aliceClaimable > 0);

        vm.prank(alice);
        vault.claim(1);

        assertEq(vault.getRoundCount(), 2);
    }

    // ============ Veto Cooldown Tests ============

    function test_VetoCooldown() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        address submitter1 = address(0x111);
        vm.prank(submitter1);
        vault.initiateHarvest(keccak256("test"), block.number);

        vm.prank(alice);
        vault.veto(0);

        // Try to submit new merkle immediately (should fail - cooldown)
        usdc.mint(recoverer, 500_000e6);
        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vm.expectRevert(RecoveryVault.VetoCooldownActive.selector);
        vault.initiateHarvest(keccak256("test2"), block.number);

        // Warp past cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // Same submitter should still fail
        vm.prank(submitter1);
        vm.expectRevert(RecoveryVault.VetoedSubmitterCannotResubmit.selector);
        vault.initiateHarvest(keccak256("test2"), block.number);

        // Different submitter should succeed
        address submitter2 = address(0x222);
        vm.prank(submitter2);
        vault.initiateHarvest(keccak256("test2"), block.number);

        assertEq(vault.getRoundCount(), 2);
    }

    // ============ Unclaimed Funds Tests ============

    function test_DistributeUnclaimed_Redistribute() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(bob);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Only Alice claims
        vm.prank(alice);
        vault.claim(0);

        // Warp past unclaimed deadline (1 year)
        vm.warp(block.timestamp + 365 days + 1);

        uint256 unclaimedBefore = usdc.balanceOf(address(vault));
        assertTrue(unclaimedBefore > 0);

        vault.distributeUnclaimed();

        assertTrue(vault.redistributionEnabled());

        // Alice can claim redistribution
        vm.prank(alice);
        vault.claimRedistribution();

        assertTrue(usdc.balanceOf(alice) > 0);
    }

    function test_DistributeUnclaimed_RevertIfTooEarly() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.expectRevert(RecoveryVault.TooEarlyForUnclaimed.selector);
        vault.distributeUnclaimed();
    }

    function test_DistributeUnclaimed_RevertIfNoDistributionYet() public {
        vm.expectRevert(RecoveryVault.RoundNotExecuted.selector);
        vault.distributeUnclaimed();
    }

    function test_DistributeUnclaimed_RevertIfAlreadyDistributed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.warp(block.timestamp + 365 days + 1);
        vault.distributeUnclaimed();

        vm.expectRevert(RecoveryVault.AlreadyDistributedUnclaimed.selector);
        vault.distributeUnclaimed();
    }

    function test_ClaimRedistribution_RevertIfNotEnabled() public {
        vm.prank(alice);
        vm.expectRevert(RecoveryVault.RedistributionNotEnabled.selector);
        vault.claimRedistribution();
    }

    function test_ClaimRedistribution_RevertIfAlreadyClaimed() public {
        // Alice deposits in senior, Charlie in junior
        vm.prank(alice);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 200_000e18);

        // Only 400k recovery - senior gets full 300k, junior gets 100k (leaves 100k unclaimed)
        vm.prank(recoverer);
        vault.depositRecovery(400_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Alice claims her senior portion
        vm.prank(alice);
        vault.claim(0);

        // Charlie does NOT claim - leaving 100k unclaimed

        vm.warp(block.timestamp + 365 days + 1);
        vault.distributeUnclaimed();

        // Alice claims redistribution
        vm.prank(alice);
        vault.claimRedistribution();

        // Alice tries to claim again
        vm.prank(alice);
        vm.expectRevert(RecoveryVault.AlreadyClaimedRedistribution.selector);
        vault.claimRedistribution();
    }

    function test_ClaimRedistribution_RevertIfNotAClaimant() public {
        // Alice deposits in senior, Charlie in junior
        vm.prank(alice);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 200_000e18);

        // Only 400k recovery - senior gets 300k, junior gets 100k
        vm.prank(recoverer);
        vault.depositRecovery(400_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Alice claims her senior portion
        vm.prank(alice);
        vault.claim(0);

        // Charlie does NOT claim - leaving 100k unclaimed

        vm.warp(block.timestamp + 365 days + 1);
        vault.distributeUnclaimed();

        // Bob never deposited, so he can't claim redistribution
        vm.prank(bob);
        vm.expectRevert(RecoveryVault.NotAClaimant.selector);
        vault.claimRedistribution();
    }

    // ============ View Function Tests ============

    function test_GetTrancheInfo() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        (string memory name, address iouToken, uint256 supply, address[] memory assets) = vault.getTrancheInfo(0);

        assertEq(name, "Senior");
        assertTrue(iouToken != address(0));
        assertEq(supply, 500_000e18);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(xUSD));
    }

    function test_GetRoundInfo() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        bytes32 merkleRoot = keccak256("test");
        uint256 snapshotBlock = block.number;

        vault.initiateHarvest(merkleRoot, snapshotBlock);

        (
            bytes32 root,
            uint256 snapshot,
            uint256 amount,
            ,
            ,
            address submitter,
            bool vetoed,
            bool executed,
            ,
        ) = vault.getRoundInfo(0);

        assertEq(root, merkleRoot);
        assertEq(snapshot, snapshotBlock);
        assertEq(amount, 500_000e6);
        assertEq(submitter, address(this));
        assertFalse(vetoed);
        assertFalse(executed);
    }

    function test_GetRoundInfo_RevertIfRoundDoesNotExist() public {
        vm.expectRevert(RecoveryVault.RoundDoesNotExist.selector);
        vault.getRoundInfo(0);
    }

    function test_GetClaimable_ReturnsZeroIfNotExecuted() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Round not executed yet
        assertEq(vault.getClaimable(alice, 0), 0);
    }

    function test_GetClaimable_ReturnsZeroIfAlreadyClaimed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        vm.prank(alice);
        vault.claim(0);

        assertEq(vault.getClaimable(alice, 0), 0);
    }

    function test_GetClaimable_ReturnsZeroForNonExistentRound() public {
        assertEq(vault.getClaimable(alice, 999), 0);
    }

    function test_GetRoundCount() public {
        assertEq(vault.getRoundCount(), 0);

        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        assertEq(vault.getRoundCount(), 1);
    }

    function test_GetAcceptedAssetsCount() public {
        assertEq(vault.getAcceptedAssetsCount(), 2);
    }

    function test_GetOffChainClaimsCount() public {
        assertEq(vault.getOffChainClaimsCount(), 0);
    }

    function test_GetVetoWeight() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        uint256 aliceWeight = vault.getVetoWeight(alice, 0);
        assertTrue(aliceWeight > 0);
    }

    function test_GetTotalVetoWeight() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(bob);
        vault.deposit(address(xUSD), 300_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        uint256 totalWeight = vault.getTotalVetoWeight(0);
        assertTrue(totalWeight > 0);
    }

    // ============ Waterfall Bonus Tests ============

    function test_Waterfall_ExcessGoesToJunior() public {
        // Senior: 100k, Junior: 100k
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(charlie);
        vault.deposit(address(lpToken), 100_000e18);

        // Recovery: 300k (more than total claims)
        vm.prank(recoverer);
        vault.depositRecovery(300_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Both should get full recovery, excess goes to junior as bonus
        uint256 aliceClaimable = vault.getClaimable(alice, 0);
        uint256 charlieClaimable = vault.getClaimable(charlie, 0);

        assertTrue(aliceClaimable > 0);
        assertTrue(charlieClaimable > aliceClaimable); // Charlie gets excess as bonus
    }
}

// Additional test contract for factory and templates
contract VaultFactoryTest is Test {
    VaultFactory public factory;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
    }

    function test_CreateVault_TwoTranche() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vault = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        assertTrue(factory.isVault(vault));
        assertEq(factory.getVaultCount(), 1);
        assertEq(factory.getVaultAt(0), vault);
    }

    function test_CreateVault_ThreeTranche() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 1, // Mezzanine
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vault = factory.createVault(
            "Test Vault",
            TemplateType.THREE_TRANCHE_SENIOR_MEZZ_EQUITY,
            VaultMode.WHOLE_SUPPLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.DONATE_TO_WATERFALL
        );

        assertTrue(factory.isVault(vault));
    }

    function test_CreateVault_FourTranche() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 2, // Mezzanine
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vault = factory.createVault(
            "Test Vault",
            TemplateType.FOUR_TRANCHE_SECURED_SENIOR_MEZZ_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        assertTrue(factory.isVault(vault));
        assertEq(RecoveryVault(vault).trancheCount(), 4);
    }

    function test_CreateVault_PariPassu() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vault = factory.createVault(
            "Test Vault",
            TemplateType.PARI_PASSU,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        assertTrue(factory.isVault(vault));
        assertEq(RecoveryVault(vault).trancheCount(), 1);
    }

    function test_CreateVault_WithOffChainClaims() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](2);
        claims[0] = RecoveryVault.OffChainClaim({
            claimant: address(0x111),
            trancheIndex: 0,
            amount: 100_000e18,
            legalDocHash: keccak256("legal1")
        });
        claims[1] = RecoveryVault.OffChainClaim({
            claimant: address(0x222),
            trancheIndex: 1,
            amount: 50_000e18,
            legalDocHash: keccak256("legal2")
        });

        address vault = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        assertEq(RecoveryVault(vault).getOffChainClaimsCount(), 2);
    }

    function test_CreateVault_RevertIfInvalidTrancheIndex() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 5, // Invalid for 2-tranche template
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        vm.expectRevert("Invalid tranche index");
        factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );
    }

    function test_CreateVault_RevertIfInvalidOffChainTrancheIndex() public {
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](1);
        claims[0] = RecoveryVault.OffChainClaim({
            claimant: address(0x111),
            trancheIndex: 5, // Invalid
            amount: 100_000e18,
            legalDocHash: keccak256("legal1")
        });

        vm.expectRevert("Invalid tranche index");
        factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );
    }

    function test_GetTemplate() public view {
        Template memory t = factory.getTemplate(TemplateType.TWO_TRANCHE_DEBT_EQUITY);
        assertEq(t.trancheCount, 2);
        assertEq(t.trancheNames[0], "Senior");
        assertEq(t.trancheNames[1], "Junior");
    }

    function test_GetVaultAt_RevertIfOutOfBounds() public {
        vm.expectRevert("Index out of bounds");
        factory.getVaultAt(0);
    }

    function test_WaterfallTreasury() public view {
        assertEq(factory.waterfallTreasury(), treasury);
    }
}

// Test TrancheIOU
contract TrancheIOUTest is Test {
    TrancheIOU public iou;
    address public vault = address(0x1234);
    address public alice = address(0xA11CE);

    function setUp() public {
        vm.prank(vault);
        iou = new TrancheIOU("wf-Senior", "wfSR", vault, 0);
    }

    function test_Mint() public {
        vm.prank(vault);
        iou.mint(alice, 1000e18);
        assertEq(iou.balanceOf(alice), 1000e18);
    }

    function test_Mint_RevertIfNotVault() public {
        vm.prank(alice);
        vm.expectRevert(TrancheIOU.OnlyVault.selector);
        iou.mint(alice, 1000e18);
    }

    function test_Burn() public {
        vm.prank(vault);
        iou.mint(alice, 1000e18);

        vm.prank(vault);
        iou.burn(alice, 500e18);

        assertEq(iou.balanceOf(alice), 500e18);
    }

    function test_Burn_RevertIfNotVault() public {
        vm.prank(vault);
        iou.mint(alice, 1000e18);

        vm.prank(alice);
        vm.expectRevert(TrancheIOU.OnlyVault.selector);
        iou.burn(alice, 500e18);
    }

    function test_Transfer() public {
        address bob = address(0xB0B);

        vm.prank(vault);
        iou.mint(alice, 1000e18);

        vm.prank(alice);
        iou.transfer(bob, 400e18);

        assertEq(iou.balanceOf(alice), 600e18);
        assertEq(iou.balanceOf(bob), 400e18);
    }

    function test_VaultAddress() public view {
        assertEq(iou.vault(), vault);
    }

    function test_TrancheIndex() public view {
        assertEq(iou.trancheIndex(), 0);
    }
}

// Test with oracle pricing
contract OraclePricingTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public lpToken;
    MockERC20 public usdc;
    MockOracle public lpOracle;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public recoverer = address(0xDEAD);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        lpToken = new MockERC20("LP", "LP", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        lpOracle = new MockOracle(5e17); // $0.50

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](2);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18 // $1
        });
        assets[1] = RecoveryVault.AssetConfig({
            assetAddress: address(lpToken),
            trancheIndex: 1,
            priceOracle: address(lpOracle),
            manualPrice: 0
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1000e18);
        lpToken.mint(alice, 1000e18);
        usdc.mint(recoverer, 1_000_000e6);

        vm.startPrank(alice);
        xUSD.approve(address(vault), type(uint256).max);
        lpToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_OraclePricing() public {
        // Deposit 100 xUSD (manual $1) -> 100 IOUs
        vm.prank(alice);
        vault.deposit(address(xUSD), 100e18);

        (, address seniorIOU,,) = vault.getTrancheInfo(0);
        assertEq(TrancheIOU(seniorIOU).balanceOf(alice), 100e18);

        // Deposit 100 LP (oracle $0.50) -> 50 IOUs
        vm.prank(alice);
        vault.deposit(address(lpToken), 100e18);

        (, address juniorIOU,,) = vault.getTrancheInfo(1);
        assertEq(TrancheIOU(juniorIOU).balanceOf(alice), 50e18);
    }

    function test_GetAssetPrice_Manual() public view {
        uint256 price = vault.getAssetPrice(address(xUSD));
        assertEq(price, 1e18);
    }

    function test_GetAssetPrice_Oracle() public view {
        uint256 price = vault.getAssetPrice(address(lpToken));
        assertEq(price, 5e17);
    }
}

// Test donate to waterfall option
contract DonateToWaterfallTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public recoverer = address(0xDEAD);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.DONATE_TO_WATERFALL
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1_000_000e18);
        usdc.mint(recoverer, 1_000_000e6);

        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_DonateToWaterfall() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Don't claim, let funds go unclaimed
        vm.warp(block.timestamp + 365 days + 1);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vault.distributeUnclaimed();

        uint256 treasuryAfter = usdc.balanceOf(treasury);
        assertTrue(treasuryAfter > treasuryBefore);
    }
}

// Test WHOLE_SUPPLY mode
contract WholeSupplyModeTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public recoverer = address(0xDEAD);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WHOLE_SUPPLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        // Total supply: 1M xUSD
        xUSD.mint(alice, 500_000e18);
        xUSD.mint(bob, 500_000e18);
        usdc.mint(recoverer, 1_000_000e6);

        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        xUSD.approve(address(vault), type(uint256).max);

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_WholeSupplyMode_DepositsStayOpen() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Deposits should still be open in WHOLE_SUPPLY mode
        assertTrue(vault.depositsOpen());

        // Bob can still deposit
        vm.prank(bob);
        vault.deposit(address(xUSD), 100_000e18);
    }

    function test_WholeSupplyMode_WaterfallUsesTotalSupply() public {
        // Alice wraps 100k of the 1M total supply
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Alice only gets 10% of recovery (100k/1M total supply)
        uint256 claimable = vault.getClaimable(alice, 0);
        // Roughly 50k (10% of 500k recovery)
        assertApproxEqRel(claimable, 50_000e6, 0.01e18);
    }
}

// Test off-chain claim functionality
contract OffChainClaimTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public offChainUser = address(0x333);
    address public recoverer = address(0xDEAD);

    bytes32 public legalDocHash = keccak256("legal_agreement_v1");

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](1);
        claims[0] = RecoveryVault.OffChainClaim({
            claimant: offChainUser,
            trancheIndex: 0,
            amount: 100_000e18,
            legalDocHash: legalDocHash
        });

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1_000_000e18);
        usdc.mint(recoverer, 1_000_000e6);

        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_ClaimOffChain_Success() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 400_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        // Build merkle tree for snapshot
        uint256 snapshotBlock = block.number;
        bytes32 leaf = keccak256(
            abi.encodePacked(offChainUser, uint8(0), uint256(100_000e18), legalDocHash, snapshotBlock)
        );
        bytes32 merkleRoot = leaf; // Single leaf = root

        vault.initiateHarvest(merkleRoot, snapshotBlock);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Off-chain user claims with proof
        bytes32[] memory proof = new bytes32[](0); // No proof needed for single leaf

        uint256 balBefore = usdc.balanceOf(offChainUser);
        vm.prank(offChainUser);
        vault.claimOffChain(0, 0, 100_000e18, legalDocHash, proof);
        uint256 balAfter = usdc.balanceOf(offChainUser);

        assertTrue(balAfter > balBefore);
    }

    function test_ClaimOffChain_RevertIfInvalidProof() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 400_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("fake_root"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(offChainUser);
        vm.expectRevert(RecoveryVault.InvalidMerkleProof.selector);
        vault.claimOffChain(0, 0, 100_000e18, legalDocHash, proof);
    }

    function test_ClaimOffChain_RevertIfAlreadyClaimed() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 400_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        uint256 snapshotBlock = block.number;
        bytes32 leaf = keccak256(
            abi.encodePacked(offChainUser, uint8(0), uint256(100_000e18), legalDocHash, snapshotBlock)
        );
        bytes32 merkleRoot = leaf;

        vault.initiateHarvest(merkleRoot, snapshotBlock);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(offChainUser);
        vault.claimOffChain(0, 0, 100_000e18, legalDocHash, proof);

        vm.prank(offChainUser);
        vm.expectRevert(RecoveryVault.AlreadyClaimedOffChain.selector);
        vault.claimOffChain(0, 0, 100_000e18, legalDocHash, proof);
    }

    function test_ClaimOffChain_RevertIfRoundDoesNotExist() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(offChainUser);
        vm.expectRevert(RecoveryVault.RoundDoesNotExist.selector);
        vault.claimOffChain(999, 0, 100_000e18, legalDocHash, proof);
    }

    function test_ClaimOffChain_RevertIfRoundNotExecuted() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 400_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        // Don't execute

        bytes32[] memory proof = new bytes32[](0);

        vm.prank(offChainUser);
        vm.expectRevert(RecoveryVault.RoundNotExecuted.selector);
        vault.claimOffChain(0, 0, 100_000e18, legalDocHash, proof);
    }
}

// Test veto cooldown and submitter restrictions
contract VetoCooldownTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public bob = address(0xB0B);
    address public harvester1 = address(0x111);
    address public harvester2 = address(0x222);
    address public recoverer = address(0xDEAD);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.PARI_PASSU,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1_000_000e18);
        usdc.mint(recoverer, 10_000_000e6);

        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_VetoCooldown_CannotResubmitDuringCooldown() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        // Harvester1 initiates harvest
        vm.prank(harvester1);
        vault.initiateHarvest(keccak256("test1"), block.number);

        // Alice vetoes (100% of voting power)
        vm.prank(alice);
        vault.veto(0);

        // Try to submit during cooldown
        vm.prank(harvester2);
        vm.expectRevert(RecoveryVault.VetoCooldownActive.selector);
        vault.initiateHarvest(keccak256("test2"), block.number);
    }

    function test_VetoCooldown_CanResubmitAfterCooldown() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vm.prank(harvester1);
        vault.initiateHarvest(keccak256("test1"), block.number);

        vm.prank(alice);
        vault.veto(0);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // Now can resubmit
        vm.prank(harvester2);
        vault.initiateHarvest(keccak256("test2"), block.number);

        assertEq(vault.getRoundCount(), 2);
    }

    function test_VetoedSubmitter_CannotResubmit() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 500_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        vm.prank(harvester1);
        vault.initiateHarvest(keccak256("test1"), block.number);

        vm.prank(alice);
        vault.veto(0);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // Original submitter cannot resubmit
        vm.prank(harvester1);
        vm.expectRevert(RecoveryVault.VetoedSubmitterCannotResubmit.selector);
        vault.initiateHarvest(keccak256("test2"), block.number);
    }
}

// Test edge cases with zero amounts and empty tranches
contract EdgeCaseTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public lpToken;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public recoverer = address(0xDEAD);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        lpToken = new MockERC20("LP", "LP", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](2);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });
        assets[1] = RecoveryVault.AssetConfig({
            assetAddress: address(lpToken),
            trancheIndex: 1,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1_000_000e18);
        lpToken.mint(alice, 1_000_000e18);
        usdc.mint(recoverer, 10_000_000e6);

        vm.startPrank(alice);
        xUSD.approve(address(vault), type(uint256).max);
        lpToken.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_Waterfall_EmptyTranche() public {
        // Only deposit in senior, leave junior empty
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(200_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Alice should get full 100k (senior limit)
        uint256 claimable = vault.getClaimable(alice, 0);
        assertEq(claimable, 100_000e6);
    }

    function test_Waterfall_PartialRecovery_SeniorOnly() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(alice);
        vault.deposit(address(lpToken), 50_000e18);

        // Only 50k recovery - less than senior tranche
        vm.prank(recoverer);
        vault.depositRecovery(50_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // Check senior gets 50% recovery (50k out of 100k)
        uint256 seniorClaimable = vault.getClaimable(alice, 0);
        assertTrue(seniorClaimable > 0);
        // Note: Junior gets nothing since senior isn't fully covered
    }

    function test_Waterfall_ZeroRecoveryInRound() public {
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(100_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(0);

        // First round done, now add recovery for second round
        vm.prank(recoverer);
        vault.depositRecovery(50_000e6);

        vault.initiateHarvest(keccak256("test2"), block.number);
        vm.warp(block.timestamp + 3 days + 1);
        vault.executeHarvest(1);

        // Should have 2 rounds
        assertEq(vault.getRoundCount(), 2);
    }

    function test_GetTrancheInfo_InvalidTranche() public {
        vm.expectRevert("Invalid tranche");
        vault.getTrancheInfo(5);
    }
}

// Test with failing oracle (fallback to manual price)
contract OracleFallbackTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Use a non-oracle contract as oracle (will fail staticcall)
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(usdc), // USDC doesn't have latestAnswer()
            manualPrice: 5e17 // $0.50 fallback
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.PARI_PASSU,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1_000_000e18);

        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);
    }

    function test_OracleFallback_UsesManualPrice() public {
        // When oracle fails, should use manual price ($0.50)
        uint256 price = vault.getAssetPrice(address(xUSD));
        assertEq(price, 5e17);
    }

    function test_Deposit_WithOracleFallback() public {
        // Deposit 100 xUSD at $0.50 = 50 IOUs
        vm.prank(alice);
        vault.deposit(address(xUSD), 100e18);

        (,address iouToken,,) = vault.getTrancheInfo(0);
        assertEq(TrancheIOU(iouToken).balanceOf(alice), 50e18);
    }
}

// Test mock contracts for coverage
contract MockCoverageTest is Test {
    MockERC20 public token;
    MockOracle public oracle;

    function setUp() public {
        token = new MockERC20("Test", "TST", 18);
        oracle = new MockOracle(1e18);
    }

    function test_MockERC20_Burn() public {
        token.mint(address(this), 100e18);
        assertEq(token.balanceOf(address(this)), 100e18);

        token.burn(address(this), 50e18);
        assertEq(token.balanceOf(address(this)), 50e18);
    }

    function test_MockOracle_SetPrice() public {
        assertEq(oracle.latestAnswer(), 1e18);

        oracle.setPrice(2e18);
        assertEq(oracle.latestAnswer(), 2e18);
    }
}

// Test vault constants and immutables
contract VaultConstantsTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0,
            priceOracle: address(0),
            manualPrice: 1e18
        });

        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](0);

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);
    }

    function test_Constants() public view {
        assertEq(vault.HARVEST_TIMELOCK(), 3 days);
        assertEq(vault.VETO_THRESHOLD_BPS(), 1000);
        assertEq(vault.VETO_COOLDOWN(), 1 days);
        assertEq(vault.HARVESTER_FEE_BPS(), 1);
        assertEq(vault.UNCLAIMED_DEADLINE(), 365 days);
        assertEq(vault.PRECISION(), 1e18);
    }

    function test_Immutables() public view {
        assertEq(vault.recoveryToken(), address(usdc));
        assertTrue(vault.vaultMode() == VaultMode.WRAPPED_ONLY);
        assertTrue(vault.unclaimedOption() == UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA);
        assertEq(vault.trancheCount(), 2);
        assertEq(vault.waterfallTreasury(), treasury);
    }

    function test_VaultName() public view {
        assertEq(vault.name(), "Test Vault");
    }

    function test_InitialState() public view {
        assertTrue(vault.depositsOpen());
        assertEq(vault.pendingRecovery(), 0);
        assertEq(vault.getRoundCount(), 0);
        assertFalse(vault.unclaimedDistributed());
        assertFalse(vault.redistributionEnabled());
    }
}

// Test tranche with no underlying assets (off-chain only)
contract TrancheNoUnderlyingTest is Test {
    VaultFactory public factory;
    RecoveryVault public vault;
    MockERC20 public xUSD;
    MockERC20 public usdc;

    address public treasury = address(0x1234);
    address public alice = address(0xA11CE);
    address public offChainUser = address(0x333);
    address public recoverer = address(0xDEAD);

    function setUp() public {
        factory = new VaultFactory(treasury);
        xUSD = new MockERC20("xUSD", "xUSD", 18);
        usdc = new MockERC20("USDC", "USDC", 6);

        // Senior tranche has an asset, junior tranche has only off-chain claims
        RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](1);
        assets[0] = RecoveryVault.AssetConfig({
            assetAddress: address(xUSD),
            trancheIndex: 0, // Only senior has asset
            priceOracle: address(0),
            manualPrice: 1e18
        });

        // Junior tranche has only off-chain claims (no underlying assets)
        RecoveryVault.OffChainClaim[] memory claims = new RecoveryVault.OffChainClaim[](1);
        claims[0] = RecoveryVault.OffChainClaim({
            claimant: offChainUser,
            trancheIndex: 1, // Junior tranche has no assets, only off-chain
            amount: 100_000e18,
            legalDocHash: keccak256("legal")
        });

        address vaultAddr = factory.createVault(
            "Test Vault",
            TemplateType.TWO_TRANCHE_DEBT_EQUITY,
            VaultMode.WRAPPED_ONLY,
            address(usdc),
            assets,
            claims,
            UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
        );

        vault = RecoveryVault(vaultAddr);

        xUSD.mint(alice, 1_000_000e18);
        usdc.mint(recoverer, 1_000_000e6);

        vm.prank(alice);
        xUSD.approve(address(vault), type(uint256).max);

        vm.prank(recoverer);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_VetoWeight_TrancheWithNoUnderlyingAssets() public {
        // Alice deposits in senior (which has assets)
        vm.prank(alice);
        vault.deposit(address(xUSD), 100_000e18);

        vm.prank(recoverer);
        vault.depositRecovery(200_000e6);

        vault.initiateHarvest(keccak256("test"), block.number);

        // Get veto weights - this should handle tranche with no underlying
        uint256 aliceWeight = vault.getVetoWeight(alice, 0);
        assertTrue(aliceWeight > 0);

        uint256 totalWeight = vault.getTotalVetoWeight(0);
        assertTrue(totalWeight > 0);
    }
}
