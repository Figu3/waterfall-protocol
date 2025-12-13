# Waterfall Protocol

A permissionless, immutable DeFi coordination layer for distressed asset recovery with waterfall distribution mechanics.

## Overview

Waterfall Protocol enables transparent recovery processes for distressed crypto assets (depeg events, hacks, failed protocols) by implementing traditional finance waterfall structures on-chain.

```
                         WATERFALL PROTOCOL
    ============================================================

    Distressed Asset Holders          Recovery Providers
            |                               |
            v                               v
    +---------------+              +---------------+
    | Deposit xUSD  |              | Deposit USDC  |
    | Deposit LP    |              | (Recovery)    |
    +---------------+              +---------------+
            |                               |
            v                               v
    +--------------------------------------------------+
    |                 RECOVERY VAULT                    |
    |  +------------+  +------------+  +------------+  |
    |  |  SENIOR    |  | MEZZANINE  |  |   JUNIOR   |  |
    |  |  (Debt)    |  |            |  |  (Equity)  |  |
    |  +------------+  +------------+  +------------+  |
    +--------------------------------------------------+
                            |
                            v
                  WATERFALL DISTRIBUTION
                            |
            +---------------+---------------+
            |               |               |
            v               v               v
        SENIOR          MEZZANINE        JUNIOR
        FIRST           SECOND           LAST
        (100%)          (if excess)      (remainder)
```

## How It Works

### 1. Vault Creation

Anyone can create a vault for a distressed asset recovery using predefined templates:

```
TEMPLATE OPTIONS:
+==============================================+
|  Template Type           | Tranches         |
+==============================================+
|  TWO_TRANCHE_DEBT_EQUITY | Senior, Junior   |
|  THREE_TRANCHE           | Senior, Mezz,    |
|                          | Junior           |
|  FOUR_TRANCHE            | Secured, Senior, |
|                          | Mezz, Equity     |
|  PARI_PASSU              | Equal (1 tranche)|
+==============================================+
```

### 2. Depositing Distressed Assets

Token holders deposit their distressed assets and receive IOU tokens representing their claim:

```
USER DEPOSITS 1000 xUSD (valued at $1.00)
                |
                v
+----------------------------------+
|   VAULT DEPOSIT LOGIC            |
|   asset_price = $1.00            |
|   iou_amount = 1000 * $1.00      |
|              = 1000 wf-Senior    |
+----------------------------------+
                |
                v
USER RECEIVES: 1000 wf-Senior IOUs
```

### 3. Recovery Distribution (Waterfall)

When recovery funds arrive, they flow through the waterfall:

```
WATERFALL DISTRIBUTION EXAMPLE
==============================

Total Claims: $500,000
 - Senior:    $300,000 (60%)
 - Junior:    $200,000 (40%)

Recovery Amount: $400,000 (80% recovery rate)

DISTRIBUTION FLOW:

  Recovery: $400,000
       |
       v
+-------------+
|   SENIOR    | <- Gets $300,000 (100% of claim)
|   $300,000  |
+-------------+
       |
       | Remaining: $100,000
       v
+-------------+
|   JUNIOR    | <- Gets $100,000 (50% of claim)
|   $200,000  |
+-------------+

RESULT:
+--------+---------+---------+----------+
| Tranche| Claim   | Received| Recovery |
+--------+---------+---------+----------+
| Senior | $300,000| $300,000|   100%   |
| Junior | $200,000| $100,000|    50%   |
+--------+---------+---------+----------+
| TOTAL  | $500,000| $400,000|    80%   |
+--------+---------+---------+----------+
```

### 4. IOU Burn-on-Claim Mechanism

When users claim, their IOUs are burned proportionally:

```
CLAIM EXAMPLE
=============

Alice holds: 1000 wf-Senior IOUs (out of 300,000 total)
Senior Recovery Rate: 100%

CLAIM CALCULATION:
+------------------------------------------+
|  iou_balance = 1000                      |
|  redemption_rate = 100% (1e18)           |
|  to_burn = 1000 * 100% = 1000            |
|  claim_amount = 1000 USDC                |
+------------------------------------------+

BEFORE CLAIM:            AFTER CLAIM:
Alice: 1000 IOUs   ->    Alice: 0 IOUs
       0 USDC      ->           1000 USDC
```

### 5. Veto Mechanism

IOU holders can veto suspicious distribution proposals:

```
VETO PROCESS TIMELINE
=====================

Day 0: Harvest Initiated
  |
  |  +-----------------------------+
  |  | VETO WINDOW: 3 DAYS         |
  |  | Threshold: 10% of $ value   |
  |  +-----------------------------+
  |
  v
Day 3: If not vetoed, execute harvest
  |
  v
Distribution Complete

VETO WEIGHT CALCULATION:
+----------------------------------------+
| weight = sum of (iou_balance * price)  |
| for each tranche the user holds IOUs   |
+----------------------------------------+

If total_veto_weight >= 10% of total_weight:
  -> Round VETOED
  -> Recovery funds returned to pending
  -> 24-hour cooldown before next attempt
  -> Original submitter banned from resubmit
```

### 6. Unclaimed Funds Handling

After 1 year, unclaimed funds can be distributed:

```
UNCLAIMED FUNDS OPTIONS
=======================

Option 1: REDISTRIBUTE_PRO_RATA
+------------------------------------------+
|                                          |
|  Unclaimed    Claimants who already      |
|  Funds    ->  claimed get proportional   |
|               share of unclaimed         |
+------------------------------------------+

Option 2: DONATE_TO_WATERFALL
+------------------------------------------+
|                                          |
|  Unclaimed    Waterfall Treasury         |
|  Funds    ->  (DAO-controlled)           |
|                                          |
+------------------------------------------+
```

## Architecture

```
+------------------+
|  VaultFactory    |  Creates vaults with templates
+--------+---------+
         |
         | creates
         v
+------------------+     +------------------+
|  RecoveryVault   |---->|   TrancheIOU     |
|                  |     |   (ERC20)        |
|  - Deposits      |     +------------------+
|  - Waterfall     |
|  - Claims        |     +------------------+
|  - Veto          |---->|   Templates      |
|  - Redistribution|     |   (Library)      |
+------------------+     +------------------+
```

## Installation

```bash
# Clone the repository
git clone https://github.com/Figu3/waterfall-protocol.git
cd waterfall-protocol

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Check coverage
forge coverage
```

## Usage

### Creating a Vault

```solidity
// Define accepted assets with their tranche assignments
RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](2);
assets[0] = RecoveryVault.AssetConfig({
    assetAddress: address(xUSD),
    trancheIndex: 0, // Senior
    priceOracle: address(0), // Manual price
    manualPrice: 1e18 // $1
});
assets[1] = RecoveryVault.AssetConfig({
    assetAddress: address(lpToken),
    trancheIndex: 1, // Junior
    priceOracle: address(lpOracle),
    manualPrice: 0
});

// Create the vault
address vault = factory.createVault(
    "xUSD Recovery",
    TemplateType.TWO_TRANCHE_DEBT_EQUITY,
    VaultMode.WRAPPED_ONLY,
    address(usdc), // Recovery token
    assets,
    offChainClaims,
    UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
);
```

### Depositing Assets

```solidity
// Approve vault to spend your distressed tokens
xUSD.approve(address(vault), amount);

// Deposit and receive IOUs
vault.deposit(address(xUSD), amount);
```

### Initiating Distribution

```solidity
// Anyone can initiate a harvest when recovery funds are available
vault.initiateHarvest(merkleRoot, snapshotBlock);

// Wait 3 days for veto period
// ...

// Execute the harvest
vault.executeHarvest(roundId);
```

### Claiming Recovery

```solidity
// Claim your share from a completed round
vault.claim(roundId);
```

## Merkle Tree Generation

The `scripts/` directory contains a TypeScript tool to generate merkle trees for distribution snapshots:

```bash
cd scripts
npm install
npm run generate
```

## Test Coverage

```
| Contract          | Lines   | Statements | Branches | Functions |
|-------------------|---------|------------|----------|-----------|
| RecoveryVault.sol | 99.13%  | 98.45%     | 93.22%   | 100%      |
| TrancheIOU.sol    | 100%    | 100%       | 100%     | 100%      |
| VaultFactory.sol  | 100%    | 100%       | 87.50%   | 100%      |
```

## Key Parameters

| Parameter          | Value    | Description                           |
|--------------------|----------|---------------------------------------|
| HARVEST_TIMELOCK   | 3 days   | Veto window duration                  |
| VETO_THRESHOLD_BPS | 1000     | 10% of total $ value to veto          |
| VETO_COOLDOWN      | 1 day    | Cooldown after vetoed round           |
| HARVESTER_FEE_BPS  | 1        | 0.01% fee to harvest executor         |
| UNCLAIMED_DEADLINE | 365 days | Time before unclaimed redistribution  |

## Security Considerations

- **Immutable**: No admin functions, no upgradability after deployment
- **Reentrancy Protected**: All state-changing functions use ReentrancyGuard
- **No Oracle Manipulation**: Prices snapshotted at harvest initiation
- **Veto Mechanism**: 10% dollar-weighted threshold prevents malicious distributions
- **Cooldown Period**: Prevents rapid succession attacks after veto

## License

MIT
