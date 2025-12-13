// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/VaultFactory.sol";
import "../src/RecoveryVault.sol";
import "../src/Templates.sol";
import "./mocks/MockERC20.sol";

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

        (,address iouToken, uint256 supply,) = vault.getTrancheInfo(0);
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

    // ============ Recovery Deposit Tests ============

    function test_DepositRecovery() public {
        vm.prank(recoverer);
        vault.depositRecovery(500_000e6);

        assertEq(vault.pendingRecovery(), 500_000e6);
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

        (,,,,, address submitter,, bool executed,,) = vault.getRoundInfo(0);

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

        // Alice should get 500k / 800k * 800k = 500k (full recovery for senior)
        uint256 aliceClaimable = vault.getClaimable(alice, 0);
        // Note: There's a fee taken, so slightly less than 500k
        uint256 expectedAlice = (500_000e18 * (1_000_000e6 - 100e6)) / 1_000_000e18; // Approx

        vm.prank(alice);
        vault.claim(0);

        // Alice's IOUs should be burned
        (,address seniorIOU,,) = vault.getTrancheInfo(0);
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

        // Alice should have burned ~50% of IOUs (proportional to redemption rate)
        (,address seniorIOU,,) = vault.getTrancheInfo(0);
        // Should have ~400k IOUs remaining (received 400k USDC worth)
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
            uint256 initiatedAt,
            uint256 executedAt,
            address submitter,
            bool vetoed,
            bool executed,
            uint256 vetoVotes,
            uint256 totalClaimed
        ) = vault.getRoundInfo(0);

        assertEq(root, merkleRoot);
        assertEq(snapshot, snapshotBlock);
        assertEq(amount, 500_000e6);
        assertEq(submitter, address(this));
        assertFalse(vetoed);
        assertFalse(executed);
    }
}
