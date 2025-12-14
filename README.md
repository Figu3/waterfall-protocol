# Waterfall Protocol

**DeFi's First Decentralized Insolvency Protocol**

A permissionless, immutable, creditor-governed on-chain insolvency framework for distressed crypto assets.

## Overview

Waterfall Protocol brings traditional bankruptcy mechanics on-chain, enabling transparent and fair recovery proceedings for distressed crypto assets (depeg events, hacks, protocol failures). It implements the **absolute priority rule** used in Chapter 7/11 bankruptcy through smart contract-enforced waterfall distributions.

```
                      ON-CHAIN INSOLVENCY PROTOCOL
    ================================================================

    Creditors (Token Holders)           Recovery Estate
            |                               |
            v                               v
    +---------------+              +---------------+
    | File Claim    |              | Deposit       |
    | (Deposit      |              | Recovery      |
    | Distressed    |              | Assets        |
    | Tokens)       |              | (USDC, etc)   |
    +---------------+              +---------------+
            |                               |
            v                               v
    +--------------------------------------------------+
    |              INSOLVENCY VAULT                     |
    |  +------------+  +------------+  +------------+  |
    |  |  SECURED   |  |  SENIOR    |  |  JUNIOR    |  |
    |  |  (First)   |  | (Second)   |  |  (Last)    |  |
    |  +------------+  +------------+  +------------+  |
    +--------------------------------------------------+
                            |
                            v
              WATERFALL DISTRIBUTION
              (Absolute Priority Rule)
                            |
            +---------------+---------------+
            |               |               |
            v               v               v
        SECURED         SENIOR          JUNIOR
        100% FIRST      IF EXCESS       REMAINDER
```

## Bankruptcy Terminology Mapping

| Traditional Bankruptcy | Waterfall Protocol |
|----------------------|-------------------|
| Chapter 7/11 Filing | Vault Creation |
| Bankruptcy Estate | Recovery Token Pool |
| Proof of Claim | Deposit → IOU Token |
| Priority Classes | Tranches (Senior/Mezz/Junior) |
| Absolute Priority Rule | Waterfall Distribution |
| Creditor Committee | IOU Holders (Veto Power) |
| Bankruptcy Trustee | Harvester (Bonded) |
| Claims Bar Date | Deposits Close (WRAPPED_ONLY) |
| Distribution Plan | Merkle Root + Redemption Rates |
| Unclaimed Property | 365-Day Redistribution |

## How It Works

### 1. Vault Creation (Filing for Insolvency)

Anyone can create an insolvency vault for a distressed asset using predefined priority structures:

```
PRIORITY STRUCTURE TEMPLATES:
+================================================+
|  Template                    | Priority Classes |
+================================================+
|  TWO_TRANCHE_DEBT_EQUITY     | Senior, Junior   |
|  THREE_TRANCHE               | Senior, Mezz,    |
|                              | Junior           |
|  FOUR_TRANCHE                | Secured, Senior, |
|                              | Mezz, Equity     |
|  PARI_PASSU                  | Equal (1 class)  |
+================================================+
```

### 2. Filing Claims (Depositing Distressed Assets)

Creditors deposit their distressed tokens and receive IOU tokens representing their claim:

```
CREDITOR FILES CLAIM: 1000 xUSD (valued at $1.00)
                |
                v
+----------------------------------+
|   CLAIM PROCESSING               |
|   asset_value = 1000 * $1.00     |
|   claim_amount = $1000           |
|   class = Senior                 |
+----------------------------------+
                |
                v
CREDITOR RECEIVES: 1000 wf-Senior (IOU Token)
```

### 3. Distribution (Waterfall / Absolute Priority)

When recovery assets arrive, they flow through the waterfall following the absolute priority rule:

```
DISTRIBUTION EXAMPLE
====================

Total Claims by Class:
 - Secured:  $100,000
 - Senior:   $300,000
 - Junior:   $200,000
 - TOTAL:    $600,000

Recovery Estate: $450,000 (75% recovery rate)

WATERFALL FLOW:

  Estate: $450,000
       |
       v
+-------------+
|   SECURED   | <- Gets $100,000 (100% recovery)
|   $100,000  |
+-------------+
       |
       | Remaining: $350,000
       v
+-------------+
|   SENIOR    | <- Gets $300,000 (100% recovery)
|   $300,000  |
+-------------+
       |
       | Remaining: $50,000
       v
+-------------+
|   JUNIOR    | <- Gets $50,000 (25% recovery)
|   $200,000  |
+-------------+

RESULT:
+----------+---------+-----------+----------+
| Class    | Claim   | Received  | Recovery |
+----------+---------+-----------+----------+
| Secured  | $100,000| $100,000  |   100%   |
| Senior   | $300,000| $300,000  |   100%   |
| Junior   | $200,000|  $50,000  |    25%   |
+----------+---------+-----------+----------+
| TOTAL    | $600,000| $450,000  |    75%   |
+----------+---------+-----------+----------+
```

### 4. Claim Redemption (IOU Burn Mechanism)

When creditors redeem their claims, IOUs are burned proportionally:

```
REDEMPTION EXAMPLE
==================

Alice holds: 1000 wf-Senior IOUs (out of 300,000 total)
Senior Class Recovery Rate: 100%

REDEMPTION CALCULATION:
+------------------------------------------+
|  iou_balance = 1000                      |
|  class_recovery_rate = 100%              |
|  redemption_amount = 1000 * 100%         |
|                    = 1000 USDC           |
+------------------------------------------+

BEFORE:              AFTER:
Alice: 1000 IOUs  -> Alice: 0 IOUs
       0 USDC     ->        1000 USDC
```

### 5. Creditor Committee (Veto Mechanism)

IOU holders can veto suspicious distribution proposals:

```
CREDITOR VETO PROCESS
=====================

Day 0: Distribution Proposed
  |
  |  +-----------------------------+
  |  | VETO WINDOW: 3 DAYS         |
  |  | Threshold: 10% of $ value   |
  |  | Quorum: 5% participation    |
  |  +-----------------------------+
  |
  v
Day 3: If not vetoed → Execute Distribution
  |
  v
Distribution Complete

VETO WEIGHT = sum of (iou_balance * asset_price)
              for each class the creditor holds

If total_veto_weight >= 10% of total_claims:
  → Distribution VETOED
  → Recovery assets returned to pending
  → 24-hour cooldown before next proposal
  → Original proposer banned from resubmitting
```

### 6. Trustee Accountability (Harvester Bond)

Harvesters must post a bond when proposing distributions:

```
HARVESTER BOND MECHANISM
========================

1. Harvester posts 1% bond when initiating distribution
2. 7-day challenge period after execution
3. If challenged successfully → bond slashed to challenger
4. If no challenge → bond returned after period

+------------------+     +------------------+
|  INITIATE        | --> |  EXECUTE         |
|  Post 1% bond    |     |  3-day timelock  |
+------------------+     +------------------+
                               |
                               v
                    +------------------+
                    |  CHALLENGE       |
                    |  7-day window    |
                    +------------------+
                         /         \
                        v           v
              +----------+     +----------+
              | SLASHED  |     | RETURNED |
              | (fraud)  |     | (clean)  |
              +----------+     +----------+
```

### 7. Unclaimed Property

After 1 year, unclaimed distributions can be handled:

```
UNCLAIMED PROPERTY OPTIONS
==========================

Option 1: REDISTRIBUTE_PRO_RATA
+------------------------------------------+
|  Unclaimed     Creditors who claimed     |
|  Assets    ->  receive proportional      |
|                share of unclaimed        |
+------------------------------------------+

Option 2: DONATE_TO_WATERFALL
+------------------------------------------+
|  Unclaimed     Protocol Treasury         |
|  Assets    ->  (DAO-controlled)          |
+------------------------------------------+
```

## Architecture

```
+------------------+
|  VaultFactory    |  Creates insolvency vaults
+--------+---------+
         |
         | creates
         v
+------------------+     +------------------+
|  RecoveryVault   |---->|   TrancheIOU     |
|  (Insolvency     |     |   (Claim Token)  |
|   Proceeding)    |     +------------------+
|                  |
|  - Claim Filing  |     +------------------+
|  - Waterfall     |---->|   Templates      |
|  - Distribution  |     |   (Priority      |
|  - Veto          |     |    Structures)   |
|  - Challenges    |     +------------------+
+------------------+
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

### Creating an Insolvency Vault

```solidity
// Define accepted claims with their priority class
RecoveryVault.AssetConfig[] memory assets = new RecoveryVault.AssetConfig[](2);
assets[0] = RecoveryVault.AssetConfig({
    assetAddress: address(xUSD),
    trancheIndex: 0, // Senior (first priority)
    priceOracle: address(0),
    manualPrice: 1e18 // $1
});
assets[1] = RecoveryVault.AssetConfig({
    assetAddress: address(lpToken),
    trancheIndex: 1, // Junior (second priority)
    priceOracle: address(lpOracle),
    manualPrice: 0
});

// Create the insolvency vault
address vault = factory.createVault(
    "xUSD Insolvency Proceeding",
    TemplateType.TWO_TRANCHE_DEBT_EQUITY,
    VaultMode.WRAPPED_ONLY,
    address(usdc), // Recovery asset
    assets,
    offChainClaims,
    UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
);
```

### Filing a Claim (Depositing)

```solidity
// Approve vault to accept distressed tokens
xUSD.approve(address(vault), amount);

// File claim - receive IOU tokens
vault.deposit(address(xUSD), amount);

// Or batch file multiple claims
vault.depositMultiple(
    [address(xUSD), address(lpToken)],
    [amount1, amount2]
);
```

### Initiating Distribution

```solidity
// Harvester posts bond and initiates distribution
usdc.approve(address(vault), bondAmount);
vault.initiateHarvest(merkleRoot, snapshotBlock);

// Wait 3 days for veto period
// ...

// Execute the distribution
vault.executeHarvest(roundId);

// After 7-day challenge period, reclaim bond
vault.returnHarvesterBond(roundId);
```

### Redeeming Claims

```solidity
// Redeem from a single distribution round
vault.claim(roundId);

// Or batch redeem from multiple rounds
vault.claimMultiple([roundId1, roundId2, roundId3]);
```

## Key Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| HARVEST_TIMELOCK | 3 days | Veto window before distribution |
| VETO_THRESHOLD_BPS | 1000 | 10% of claims needed to veto |
| VETO_QUORUM_BPS | 500 | 5% minimum participation |
| VETO_COOLDOWN | 1 day | Cooldown after vetoed distribution |
| HARVESTER_FEE_BPS | 10 | 0.1% fee to distribution executor |
| HARVESTER_BOND_BPS | 100 | 1% bond required from harvester |
| CHALLENGE_PERIOD | 7 days | Window to challenge distributions |
| UNCLAIMED_DEADLINE | 365 days | Time before unclaimed redistribution |

## Security Features

- **Immutable**: No admin functions, no upgradability after deployment
- **Reentrancy Protected**: All state-changing functions use ReentrancyGuard
- **Oracle Validation**: Staleness checks, price bounds, Chainlink integration
- **Snapshot Protection**: IOU supplies snapshotted at distribution initiation
- **Creditor Governance**: 10% threshold + 5% quorum for veto
- **Trustee Accountability**: 1% bond slashable for fraudulent distributions
- **Challenge Period**: 7-day window to dispute executed distributions

## Test Coverage

```
| Contract          | Lines   | Statements | Branches | Functions |
|-------------------|---------|------------|----------|-----------|
| RecoveryVault.sol | 95%+    | 95%+       | 90%+     | 100%      |
| TrancheIOU.sol    | 100%    | 100%       | 100%     | 100%      |
| VaultFactory.sol  | 100%    | 100%       | 87.50%   | 100%      |
```

## Subgraph

A complete subgraph schema is provided in `/subgraph` for indexing with The Graph.

## Use Cases

1. **Stablecoin Depegs**: Coordinate recovery for depeg victims (UST, USDR, etc.)
2. **Protocol Hacks**: Distribute recovered funds from white-hat negotiations
3. **Failed Protocols**: Wind down failed DeFi protocols fairly
4. **Insurance Payouts**: Structured distribution of insurance claims
5. **Legal Settlements**: On-chain distribution of court-ordered recoveries

## License

MIT
