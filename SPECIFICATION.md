# Waterfall Protocol: Complete Specification

## Problem Statement

DeFi has no standardized waterfall system for asset recovery when protocols fail or fraud occurs. When insolvency hits, there's no defined priority between different creditor classes. Debt holders (stablecoin holders) and equity holders (LPs) scramble without a mechanism to adjudicate claims.

Traditional finance solved this centuries ago with legally-enforced waterfalls: secured creditors first, then senior unsecured, then subordinated debt, then equity. Waterfall Protocol brings this to DeFi as permissionless infrastructure.

---

## Solution Overview

Waterfall Protocol is a permissionless coordination layer for distressed asset recovery. It provides:

1. **Vault infrastructure** for creditors to deposit distressed assets
2. **Automatic tranche classification** based on asset type
3. **Waterfall enforcement** via immutable smart contracts
4. **Dual vault modes**: wrapped-only or whole-supply denomination
5. **Veto mechanism** for creditor protection against malicious merkle submissions
6. **Vault templates** for common creditor structures

Waterfall never forces coordination—it offers it. Users opt-in by depositing. The legitimacy of a vault comes from adoption, not governance.

---

## Core Concepts

### Vaults

Each distressed protocol gets its own vault. Vaults are independent—no cross-contamination between different recovery situations.

```
┌─────────────────────────────────────────────────────────┐
│              WATERFALL PROTOCOL                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐      │
│  │ STREAM      │  │ PROTOCOL X  │  │ PROTOCOL Y  │      │
│  │ VAULT       │  │ VAULT       │  │ VAULT       │      │
│  │             │  │             │  │             │      │
│  │ Tranche A   │  │ Tranche A   │  │ Tranche A   │      │
│  │ Tranche B   │  │ Tranche B   │  │ Tranche B   │      │
│  │ Tranche C   │  │             │  │ Tranche C   │      │
│  └─────────────┘  └─────────────┘  └─────────────┘      │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Vault Modes

| Mode | Claim Denominator | Use Case |
|------|-------------------|----------|
| WRAPPED_ONLY | IOU total supply | Only depositors share recovery |
| WHOLE_SUPPLY | Original token total supply | Recovery shared across entire token supply (depositors get pro-rata share) |

**WRAPPED_ONLY**: Deposits freeze when first merkle is submitted. Only IOU holders can claim.

**WHOLE_SUPPLY**: Deposits never freeze. Redemption rate calculated against original token's total supply at snapshot. Depositors receive their pro-rata share; non-depositors dilute the pool but cannot claim without depositing.

### Tranches

Asset type determines tranche assignment—users don't choose. The vault configuration defines which deposited assets map to which tranche. Vaults support arbitrary tranche counts.

| Priority | Example Use Case |
|----------|------------------|
| 1 (Most Senior) | Secured debt, overcollateralized claims |
| 2 | Senior unsecured debt, stablecoin claims |
| 3 | Subordinated debt, junior notes |
| 4 | Mezzanine |
| ... | ... |
| N (Most Junior) | Equity, LP tokens |

Higher priority tranches are paid in full before lower priority tranches receive anything.

### IOU Tokens

When users deposit distressed assets, they receive tranche-specific IOU tokens. Each tranche has its own IOU token.

IOUs are ERC20 tokens with `wf-` prefix (e.g., `wf-xUSD`). They are fully transferable from the moment of minting. They can be transferred, traded on secondary markets, or held. The claim follows the token, not the original depositor.

Ratio is 1:1 at deposit (adjusted by asset price if configured):
- 1000 xUSD deposited (price: $1.00) → 1000 wf-xUSD received
- 1000 LP tokens deposited (price: $0.50) → 500 wf-LP received (dollar-normalized)

**Burn on Claim**: When users claim recovery tokens, they burn IOUs proportionally to the redemption rate. This ensures proper accounting across multiple distribution rounds.

---

## Vault Templates

Vault creation uses predefined templates for common creditor structures. Templates standardize tranche configuration while allowing customization of accepted assets.

### Available Templates

**Template: TWO_TRANCHE_DEBT_EQUITY**
```
Standard debt/equity structure
├── Tranche 0 (Senior): Debt claims
└── Tranche 1 (Junior): Equity claims
```

**Template: THREE_TRANCHE_SENIOR_MEZZ_EQUITY**
```
Senior/mezzanine/equity structure
├── Tranche 0 (Senior): Senior debt
├── Tranche 1 (Mezzanine): Subordinated debt
└── Tranche 2 (Junior): Equity
```

**Template: FOUR_TRANCHE_SECURED_SENIOR_MEZZ_EQUITY**
```
Full capital structure
├── Tranche 0: Secured claims
├── Tranche 1: Senior unsecured
├── Tranche 2: Mezzanine
└── Tranche 3: Equity
```

**Template: PARI_PASSU**
```
Equal priority (no waterfall)
└── Tranche 0: All claims equal
```

### Template Structure

```solidity
enum TemplateType {
    TWO_TRANCHE_DEBT_EQUITY,
    THREE_TRANCHE_SENIOR_MEZZ_EQUITY,
    FOUR_TRANCHE_SECURED_SENIOR_MEZZ_EQUITY,
    PARI_PASSU
}

struct Template {
    string name;
    uint8 trancheCount;
    string[] trancheNames;
}
```

---

## Vault Lifecycle

### 1. Vault Creation

Anyone can create a vault by selecting a template, mode, and mapping assets to tranches:

```solidity
enum VaultMode {
    WRAPPED_ONLY,
    WHOLE_SUPPLY
}

enum UnclaimedFundsOption {
    REDISTRIBUTE_PRO_RATA,
    DONATE_TO_WATERFALL
}

struct AssetConfig {
    address assetAddress;
    uint8 trancheIndex;
    address priceOracle;      // Address of oracle, or address(0) for manual
    uint256 manualPrice;      // Used if priceOracle is address(0), in 1e18
}

struct OffChainClaim {
    address claimant;
    uint8 trancheIndex;
    uint256 amount;           // Dollar value in 1e18
    bytes32 legalDocHash;     // Keccak256 hash of legal agreement
}

function createVault(
    string memory name,
    TemplateType template,
    VaultMode mode,
    address recoveryToken,
    AssetConfig[] memory acceptedAssets,
    OffChainClaim[] memory offChainClaims,
    UnclaimedFundsOption unclaimedOption
) external returns (address vault);
```

**Asset configuration is immutable after deployment.** No assets can be added or removed once the vault is created.

**Off-chain claims are immutable.** They represent legal agreements that bridge on-chain distribution with legal enforceability. The legal document hash provides verifiability.

Example for Stream:
```solidity
createVault(
    "Stream Recovery",
    TemplateType.TWO_TRANCHE_DEBT_EQUITY,
    VaultMode.WRAPPED_ONLY,
    USDC_ADDRESS,
    [
        AssetConfig(xUSD_ADDRESS, 0, address(0), 1e18),     // xUSD → Senior, $1.00 manual
        AssetConfig(LP_TOKEN_ADDRESS, 1, LP_ORACLE, 0)      // LP → Junior, oracle price
    ],
    [],  // No off-chain claims
    UnclaimedFundsOption.REDISTRIBUTE_PRO_RATA
);
```

### 2. Creditor Deposits

Creditors assess the vault configuration and decide individually whether to deposit:

```solidity
function deposit(address asset, uint256 amount) external {
    require(depositsOpen, "Deposits closed");
    require(isAcceptedAsset(asset), "Asset not accepted");

    uint8 trancheIndex = assetToTranche[asset];
    uint256 assetPrice = getAssetPrice(asset);

    // Calculate dollar-normalized IOU amount
    uint256 iouAmount = (amount * assetPrice) / 1e18;

    // Transfer distressed asset in
    IERC20(asset).transferFrom(msg.sender, address(this), amount);

    // Mint appropriate IOU
    tranches[trancheIndex].iouToken.mint(msg.sender, iouAmount);

    emit Deposited(msg.sender, asset, amount, iouAmount, trancheIndex);
}
```

**Deposits close when first merkle is submitted (WRAPPED_ONLY mode) or remain open (WHOLE_SUPPLY mode).**

No voting. No consensus requirement. Pure opt-in.

### 3. Recovery Deposit

Recovering party sends recovery tokens to the vault:

```solidity
function depositRecovery(uint256 amount) external {
    IERC20(recoveryToken).transferFrom(msg.sender, address(this), amount);
    pendingRecovery += amount;

    emit RecoveryDeposited(msg.sender, amount);
}
```

Recovery tokens sit in the vault until a distribution round is executed.

### 4. Merkle Generation & Harvest Initiation

An off-chain script (open-source, anyone can run) generates the merkle tree:

**Merkle includes:**
- All IOU holders (on-chain, indexed from Transfer events)
- Off-chain claims (from vault configuration)
- Original token holders (WHOLE_SUPPLY mode, indexed from original token)

**Merkle leaf structure:**
```solidity
bytes32 leaf = keccak256(abi.encodePacked(
    user,
    trancheIndex,
    dollarBalance,      // IOU balance or off-chain claim amount
    snapshotBlock
));
```

Anyone can submit a merkle to initiate harvest:

```solidity
uint256 public constant HARVEST_TIMELOCK = 3 days;
uint256 public constant VETO_THRESHOLD_BPS = 1000;  // 10%
uint256 public constant VETO_COOLDOWN = 1 days;

function initiateHarvest(bytes32 _merkleRoot, uint256 _snapshotBlock) external {
    require(pendingRecovery > 0, "No recovery to distribute");

    // Check cooldown if previous round was vetoed
    if (rounds.length > 0) {
        DistributionRound storage lastRound = rounds[rounds.length - 1];
        if (lastRound.vetoed) {
            require(block.timestamp > lastRound.initiatedAt + VETO_COOLDOWN, "24h cooldown");
            require(msg.sender != lastRound.submitter, "Vetoed submitter cannot resubmit");
        }
    }

    // Close deposits in WRAPPED_ONLY mode
    if (vaultMode == VaultMode.WRAPPED_ONLY && depositsOpen) {
        depositsOpen = false;
    }

    // Snapshot asset prices for veto weight calculation
    snapshotAssetPrices();

    // Create new round
    rounds.push();
    uint256 roundId = rounds.length - 1;
    DistributionRound storage round = rounds[roundId];
    round.merkleRoot = _merkleRoot;
    round.snapshotBlock = _snapshotBlock;
    round.recoveryAmount = pendingRecovery;
    round.initiatedAt = block.timestamp;
    round.submitter = msg.sender;

    pendingRecovery = 0;

    emit HarvestInitiated(roundId, _merkleRoot, _snapshotBlock, round.recoveryAmount);
}
```

### 5. Veto Period

IOU holders can veto a malicious merkle submission. Veto weight is dollar-based using prices snapshotted at merkle submission:

```solidity
function veto(uint256 roundId) external {
    DistributionRound storage round = rounds[roundId];

    require(round.initiatedAt > 0, "Round does not exist");
    require(block.timestamp < round.initiatedAt + HARVEST_TIMELOCK, "Timelock passed");
    require(!round.hasVetoed[msg.sender], "Already vetoed");
    require(!round.vetoed, "Already vetoed by majority");

    uint256 voterWeight = getVetoWeight(msg.sender);
    require(voterWeight > 0, "No voting power");

    round.hasVetoed[msg.sender] = true;
    round.vetoVotes += voterWeight;

    uint256 totalWeight = getTotalVetoWeight();

    if (round.vetoVotes * 10000 / totalWeight >= VETO_THRESHOLD_BPS) {
        round.vetoed = true;

        // Return recovery amount to pending pool
        pendingRecovery += round.recoveryAmount;
        round.recoveryAmount = 0;

        emit HarvestVetoed(roundId, round.vetoVotes, totalWeight);
    } else {
        emit VetoCast(roundId, msg.sender, voterWeight);
    }
}

function getVetoWeight(address user) public view returns (uint256) {
    uint256 weight = 0;
    for (uint8 i = 0; i < trancheCount; i++) {
        uint256 iouBalance = tranches[i].iouToken.balanceOf(user);
        uint256 price = snapshotPrices[tranches[i].underlyingAsset];
        weight += (iouBalance * price) / 1e18;
    }
    return weight;
}

function getTotalVetoWeight() public view returns (uint256) {
    uint256 total = 0;
    for (uint8 i = 0; i < trancheCount; i++) {
        uint256 supply = tranches[i].iouToken.totalSupply();
        uint256 price = snapshotPrices[tranches[i].underlyingAsset];
        total += (supply * price) / 1e18;
    }
    return total;
}
```

### 6. Execute Harvest

After timelock passes without successful veto:

```solidity
uint256 public constant HARVESTER_FEE_BPS = 1;  // 0.01%

function executeHarvest(uint256 roundId) external {
    DistributionRound storage round = rounds[roundId];

    require(round.initiatedAt > 0, "Round does not exist");
    require(block.timestamp >= round.initiatedAt + HARVEST_TIMELOCK, "Timelock active");
    require(!round.vetoed, "Round was vetoed");
    require(!round.executed, "Already executed");

    round.executed = true;
    round.executedAt = block.timestamp;

    // Pay harvester fee
    uint256 fee = (round.recoveryAmount * HARVESTER_FEE_BPS) / 10000;
    IERC20(recoveryToken).transfer(msg.sender, fee);

    uint256 distributable = round.recoveryAmount - fee;

    // Calculate redemption rates using waterfall
    executeWaterfall(roundId, distributable);

    // Record first distribution timestamp for unclaimed funds deadline
    if (firstDistributionTimestamp == 0) {
        firstDistributionTimestamp = block.timestamp;
    }

    emit HarvestExecuted(roundId, distributable, fee, msg.sender);
}
```

### 7. Waterfall Execution

```solidity
function executeWaterfall(uint256 roundId, uint256 amount) internal {
    DistributionRound storage round = rounds[roundId];
    uint256 remaining = amount;

    // Get denominators based on vault mode
    uint256[] memory denominators = getDenominators(round.snapshotBlock);

    for (uint8 i = 0; i < trancheCount; i++) {
        if (remaining == 0) break;

        uint256 trancheDenominator = denominators[i];
        if (trancheDenominator == 0) continue;

        uint256 trancheOutstanding = trancheDenominator - round.tranchePaid[i];
        uint256 toTranche = min(remaining, trancheOutstanding);

        if (toTranche > 0) {
            round.tranchePaid[i] += toTranche;
            round.trancheRedemptionRate[i] = (round.tranchePaid[i] * 1e18) / trancheDenominator;
            remaining -= toTranche;
        }
    }

    // Any remaining goes to most junior tranche as bonus
    if (remaining > 0) {
        uint8 juniorTranche = trancheCount - 1;
        round.tranchePaid[juniorTranche] += remaining;
        round.trancheRedemptionRate[juniorTranche] =
            (round.tranchePaid[juniorTranche] * 1e18) / denominators[juniorTranche];
    }
}

function getDenominators(uint256 snapshotBlock) internal view returns (uint256[] memory) {
    uint256[] memory denominators = new uint256[](trancheCount);

    for (uint8 i = 0; i < trancheCount; i++) {
        if (vaultMode == VaultMode.WRAPPED_ONLY) {
            // Use IOU supply
            denominators[i] = tranches[i].iouToken.totalSupply();
        } else {
            // Use original token supply at snapshot
            denominators[i] = getOriginalSupplyAtBlock(i, snapshotBlock);
        }

        // Add off-chain claims for this tranche
        denominators[i] += totalOffChainClaims[i];
    }

    return denominators;
}
```

**Example Distribution (Three Tranches)**
```
Vault state:
├── Tranche 0 (Senior) denominator: $500,000
├── Tranche 1 (Mezz) denominator: $300,000
├── Tranche 2 (Junior) denominator: $200,000

Recovery Round 1: 400,000 USDC
├── Tranche 0 gets: 400,000 (80% redemption rate)
├── Tranche 1 gets: 0
├── Tranche 2 gets: 0

Recovery Round 2: 300,000 USDC
├── Tranche 0 gets: 100,000 (now 100% whole)
├── Tranche 1 gets: 200,000 (66.7% redemption rate)
├── Tranche 2 gets: 0

Recovery Round 3: 250,000 USDC
├── Tranche 0 gets: 0 (already whole)
├── Tranche 1 gets: 100,000 (now 100% whole)
├── Tranche 2 gets: 150,000 (75% redemption rate)
```

### 8. Claiming

Depositors claim by burning IOUs proportionally:

```solidity
function claim(uint256 roundId) external {
    DistributionRound storage round = rounds[roundId];

    require(round.executed, "Round not executed");
    require(!round.claimed[msg.sender], "Already claimed this round");

    uint256 totalClaim = 0;

    for (uint8 i = 0; i < trancheCount; i++) {
        uint256 iouBalance = tranches[i].iouToken.balanceOf(msg.sender);
        if (iouBalance == 0) continue;

        uint256 redemptionRate = round.trancheRedemptionRate[i];
        uint256 claimAmount = (iouBalance * redemptionRate) / 1e18;

        if (claimAmount > 0) {
            // Burn IOUs proportionally
            uint256 toBurn = (iouBalance * redemptionRate) / 1e18;
            tranches[i].iouToken.burn(msg.sender, toBurn);

            totalClaim += claimAmount;
        }
    }

    require(totalClaim > 0, "Nothing to claim");

    round.claimed[msg.sender] = true;
    round.totalClaimed += totalClaim;
    totalClaimedAllRounds += totalClaim;
    userTotalClaimed[msg.sender] += totalClaim;

    IERC20(recoveryToken).transfer(msg.sender, totalClaim);

    emit Claimed(roundId, msg.sender, totalClaim);
}
```

Off-chain claimants use merkle proofs:

```solidity
function claimOffChain(
    uint256 roundId,
    uint8 trancheIndex,
    uint256 amount,
    bytes32 legalDocHash,
    bytes32[] calldata proof
) external {
    DistributionRound storage round = rounds[roundId];

    require(round.executed, "Round not executed");

    bytes32 leaf = keccak256(abi.encodePacked(
        msg.sender,
        trancheIndex,
        amount,
        legalDocHash,
        round.snapshotBlock
    ));
    require(MerkleProof.verify(proof, round.merkleRoot, leaf), "Invalid proof");
    require(!round.offChainClaimed[msg.sender][trancheIndex], "Already claimed");

    round.offChainClaimed[msg.sender][trancheIndex] = true;

    uint256 claimAmount = (amount * round.trancheRedemptionRate[trancheIndex]) / 1e18;

    round.totalClaimed += claimAmount;
    totalClaimedAllRounds += claimAmount;
    userTotalClaimed[msg.sender] += claimAmount;

    IERC20(recoveryToken).transfer(msg.sender, claimAmount);

    emit OffChainClaimed(roundId, msg.sender, trancheIndex, claimAmount);
}
```

### 9. Unclaimed Funds

After 1 year from first distribution:

```solidity
uint256 public constant UNCLAIMED_DEADLINE = 365 days;
address public constant WATERFALL_TREASURY = 0x...; // Set at deployment

function distributeUnclaimed() external {
    require(firstDistributionTimestamp > 0, "No distributions yet");
    require(block.timestamp > firstDistributionTimestamp + UNCLAIMED_DEADLINE, "Too early");
    require(!unclaimedDistributed, "Already distributed");

    uint256 unclaimed = IERC20(recoveryToken).balanceOf(address(this));
    require(unclaimed > 0, "Nothing to distribute");

    unclaimedDistributed = true;

    if (unclaimedOption == UnclaimedFundsOption.DONATE_TO_WATERFALL) {
        IERC20(recoveryToken).transfer(WATERFALL_TREASURY, unclaimed);
        emit UnclaimedDonated(unclaimed);
    } else {
        redistributionPool = unclaimed;
        redistributionEnabled = true;
        emit RedistributionEnabled(unclaimed);
    }
}

function claimRedistribution() external {
    require(redistributionEnabled, "Not enabled");
    require(!redistributionClaimed[msg.sender], "Already claimed");
    require(userTotalClaimed[msg.sender] > 0, "Not a claimant");

    redistributionClaimed[msg.sender] = true;

    uint256 share = (userTotalClaimed[msg.sender] * redistributionPool) / totalClaimedAllRounds;

    IERC20(recoveryToken).transfer(msg.sender, share);

    emit RedistributionClaimed(msg.sender, share);
}
```

---

## Merkle Generation Script

The merkle generation script is open-source and deterministic. Anyone can run it to verify correctness.

**Inputs:**
- Vault address
- Snapshot block number
- RPC endpoint

**Process:**
1. Query all IOU Transfer events up to snapshot block
2. Build balance map for each IOU token
3. Query off-chain claims from vault configuration
4. (WHOLE_SUPPLY mode) Query original token Transfer events
5. Build merkle tree from all leaves
6. Output: merkle root + proof file (JSON)

**Leaf types:**
```
On-chain IOU holder:
  keccak256(user, trancheIndex, iouBalance, snapshotBlock)

Off-chain claim:
  keccak256(user, trancheIndex, amount, legalDocHash, snapshotBlock)
```

**Output format:**
```json
{
  "merkleRoot": "0x...",
  "snapshotBlock": 12345678,
  "totalLeaves": 1234,
  "proofs": {
    "0xUserAddress1": {
      "tranche": 0,
      "balance": "1000000000000000000000",
      "proof": ["0x...", "0x..."]
    }
  }
}
```

---

## Contract Architecture

All contracts are fully immutable. No proxy pattern. No admin functions. No upgradability.

```
contracts/
├── VaultFactory.sol
│   ├── createVault()
│   ├── getTemplate()
│   ├── isVault()
│   └── allVaults[]
│
├── RecoveryVault.sol
│   ├── Immutable Configuration
│   │   ├── name
│   │   ├── recoveryToken
│   │   ├── vaultMode
│   │   ├── unclaimedOption
│   │   ├── trancheCount
│   │   ├── assetToTranche
│   │   ├── assetPriceOracles
│   │   ├── assetManualPrices
│   │   └── offChainClaims
│   │
│   ├── State
│   │   ├── depositsOpen
│   │   ├── pendingRecovery
│   │   ├── rounds[]
│   │   ├── snapshotPrices
│   │   ├── firstDistributionTimestamp
│   │   ├── totalClaimedAllRounds
│   │   ├── userTotalClaimed
│   │   └── redistributionPool
│   │
│   ├── Deposit Functions
│   │   └── deposit()
│   │
│   ├── Recovery Functions
│   │   └── depositRecovery()
│   │
│   ├── Distribution Functions
│   │   ├── initiateHarvest()
│   │   ├── veto()
│   │   ├── executeHarvest()
│   │   ├── claim()
│   │   └── claimOffChain()
│   │
│   ├── Unclaimed Functions
│   │   ├── distributeUnclaimed()
│   │   └── claimRedistribution()
│   │
│   └── View Functions
│       ├── getVetoWeight()
│       ├── getTotalVetoWeight()
│       ├── getClaimable()
│       ├── getRoundInfo()
│       └── getTrancheInfo()
│
├── TrancheIOU.sol
│   ├── ERC20 ("wf-{originalTokenName}")
│   ├── mint() - vault only
│   └── burn() - vault only
│
├── Templates.sol
│   └── Template definitions
│
└── interfaces/
    ├── IRecoveryVault.sol
    ├── ITrancheIOU.sol
    └── IVaultFactory.sol
```

### Data Structures

```solidity
struct Tranche {
    string name;
    TrancheIOU iouToken;
    address underlyingAsset;
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
    mapping(uint8 => uint256) tranchePaid;
    mapping(uint8 => uint256) trancheRedemptionRate;
    mapping(address => bool) hasVetoed;
    mapping(address => bool) claimed;
    mapping(address => mapping(uint8 => bool)) offChainClaimed;
}

struct OffChainClaim {
    address claimant;
    uint8 trancheIndex;
    uint256 amount;
    bytes32 legalDocHash;
}
```

---

## Security Considerations

### Veto Mechanism
- 10% threshold prevents single-actor attacks
- 3-day timelock gives creditors time to review merkle
- 24-hour cooldown after veto prevents spam
- Vetoed submitter cannot resubmit (must be different address)
- Dollar-weighted voting prevents Sybil attacks

### Merkle Integrity
- Open-source script ensures verifiability
- Snapshot block prevents manipulation
- Off-chain claims immutable at vault creation

### Economic Security
- No admin keys or upgradability
- Asset configuration immutable after deployment
- Harvester fee (0.01%) incentivizes timely execution
- Unclaimed funds handled transparently (1 year deadline)

### Attack Vectors Considered
- **Malicious merkle submission**: Mitigated by veto mechanism
- **Flash loan voting**: Mitigated by snapshot at merkle submission
- **Late deposit gaming**: Mitigated by deposit freeze (WRAPPED_ONLY) or dilution awareness (WHOLE_SUPPLY)
- **Oracle manipulation**: Mitigated by snapshot prices at merkle submission
- **Reentrancy**: Checks-effects-interactions pattern throughout

---

## Stream Test Case

First deployment configuration:

```
STREAM RECOVERY VAULT
├── Name: "Stream Recovery"
├── Template: TWO_TRANCHE_DEBT_EQUITY
├── Mode: WRAPPED_ONLY
├── Recovery Token: USDC
├── Unclaimed Option: REDISTRIBUTE_PRO_RATA
├── Accepted Assets:
│   ├── xUSD (0x...) → Tranche 0 (Senior), Manual Price: $1.00
│   └── Stream LP Token (0x...) → Tranche 1 (Junior), Oracle: 0x...
├── Off-Chain Claims: None
```

**Expected flow:**

1. Deploy vault via factory with Stream config
2. xUSD holders deposit → receive wf-xUSD (transferable)
3. LP holders deposit → receive wf-LP (transferable)
4. Recoverer deposits USDC into vault
5. Anyone generates merkle and calls initiateHarvest()
6. 3-day veto period (IOU holders can veto if merkle is wrong)
7. Anyone calls executeHarvest() → waterfall executes
8. Users claim their share, burning IOUs proportionally
9. After 1 year, unclaimed funds redistributed to claimants

---

## Summary

Waterfall Protocol is infrastructure for on-chain creditor coordination. It doesn't force participation, doesn't require protocol buy-in, and doesn't rely on governance to determine fairness.

Key features:
- **Immutable**: No admin keys, no upgrades
- **Permissionless**: Anyone can create vaults, deposit, submit merkles
- **Protected**: Veto mechanism guards against malicious merkles
- **Flexible**: Templates for common structures, dual vault modes
- **Transparent**: Open-source merkle generation, on-chain state

Stream is the test case. Build it, deploy it, see if creditors actually use it.
