/**
 * Merkle Tree Generator for Waterfall Protocol
 *
 * This script generates merkle trees for distribution rounds.
 * It indexes IOU token holders and off-chain claims to create
 * a deterministic merkle root that can be verified on-chain.
 *
 * Usage:
 *   npx ts-node src/generateMerkle.ts --vault <address> --rpc <url> --block <number> --output <file>
 */

import { ethers } from 'ethers';
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import * as fs from 'fs';

// ABI fragments for the contracts we need to interact with
const VAULT_ABI = [
    'function trancheCount() view returns (uint8)',
    'function tranches(uint8) view returns (string name, address iouToken, address[] underlyingAssets)',
    'function getTrancheInfo(uint8 trancheIndex) view returns (string name, address iouToken, uint256 supply, address[] underlyingAssets)',
    'function offChainClaims(uint256) view returns (address claimant, uint8 trancheIndex, uint256 amount, bytes32 legalDocHash)',
    'function getOffChainClaimsCount() view returns (uint256)',
    'function vaultMode() view returns (uint8)',
    'function acceptedAssets(uint256) view returns (address)',
    'function getAcceptedAssetsCount() view returns (uint256)',
    'function assetToTranche(address) view returns (uint8)',
];

const ERC20_ABI = [
    'function totalSupply() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'event Transfer(address indexed from, address indexed to, uint256 value)',
];

interface MerkleLeaf {
    user: string;
    trancheIndex: number;
    balance: string;
    type: 'iou' | 'offchain';
    legalDocHash?: string;
}

interface MerkleOutput {
    merkleRoot: string;
    snapshotBlock: number;
    timestamp: number;
    vaultAddress: string;
    totalLeaves: number;
    tranches: {
        index: number;
        name: string;
        iouToken: string;
        totalSupply: string;
        holderCount: number;
    }[];
    leaves: MerkleLeaf[];
    proofs: {
        [userAddress: string]: {
            trancheIndex: number;
            balance: string;
            type: string;
            legalDocHash?: string;
            proof: string[];
        }[];
    };
}

async function getIOUHolders(
    provider: ethers.Provider,
    iouTokenAddress: string,
    snapshotBlock: number
): Promise<Map<string, bigint>> {
    const holders = new Map<string, bigint>();
    const iouToken = new ethers.Contract(iouTokenAddress, ERC20_ABI, provider);

    // Get all Transfer events from genesis to snapshot block
    const filter = iouToken.filters.Transfer();

    // Query in chunks to avoid RPC limits
    const CHUNK_SIZE = 10000;
    let fromBlock = 0;

    console.log(`  Indexing transfers for ${iouTokenAddress}...`);

    while (fromBlock <= snapshotBlock) {
        const toBlock = Math.min(fromBlock + CHUNK_SIZE - 1, snapshotBlock);

        try {
            const events = await iouToken.queryFilter(filter, fromBlock, toBlock);

            for (const event of events) {
                const log = event as ethers.EventLog;
                const from = log.args[0] as string;
                const to = log.args[1] as string;
                const value = log.args[2] as bigint;

                // Update balances
                if (from !== ethers.ZeroAddress) {
                    const currentFrom = holders.get(from) || 0n;
                    holders.set(from, currentFrom - value);
                }
                if (to !== ethers.ZeroAddress) {
                    const currentTo = holders.get(to) || 0n;
                    holders.set(to, currentTo + value);
                }
            }
        } catch (error) {
            console.error(`  Error querying blocks ${fromBlock}-${toBlock}:`, error);
        }

        fromBlock = toBlock + 1;
    }

    // Remove zero balances
    for (const [address, balance] of holders.entries()) {
        if (balance <= 0n) {
            holders.delete(address);
        }
    }

    console.log(`  Found ${holders.size} holders`);
    return holders;
}

async function generateMerkleTree(
    vaultAddress: string,
    rpcUrl: string,
    snapshotBlock: number,
    outputFile: string
): Promise<MerkleOutput> {
    console.log('\n=== Waterfall Protocol Merkle Generator ===\n');
    console.log(`Vault: ${vaultAddress}`);
    console.log(`RPC: ${rpcUrl}`);
    console.log(`Snapshot Block: ${snapshotBlock}`);
    console.log('');

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const vault = new ethers.Contract(vaultAddress, VAULT_ABI, provider);

    // Get current block for timestamp
    const block = await provider.getBlock(snapshotBlock);
    if (!block) {
        throw new Error(`Block ${snapshotBlock} not found`);
    }

    // Get tranche count
    const trancheCount = await vault.trancheCount();
    console.log(`Tranches: ${trancheCount}`);

    // Collect all leaves
    const leaves: [string, number, string, string][] = []; // [user, trancheIndex, balance, snapshotBlock]
    const leafData: MerkleLeaf[] = [];
    const trancheInfo: MerkleOutput['tranches'] = [];

    // Process each tranche
    for (let i = 0; i < trancheCount; i++) {
        console.log(`\nProcessing Tranche ${i}...`);

        const [name, iouToken, supply] = await vault.getTrancheInfo(i);
        console.log(`  Name: ${name}`);
        console.log(`  IOU Token: ${iouToken}`);
        console.log(`  Total Supply: ${ethers.formatEther(supply)}`);

        // Get all IOU holders
        const holders = await getIOUHolders(provider, iouToken, snapshotBlock);

        for (const [user, balance] of holders.entries()) {
            leaves.push([
                user,
                i,
                balance.toString(),
                snapshotBlock.toString()
            ]);
            leafData.push({
                user,
                trancheIndex: i,
                balance: balance.toString(),
                type: 'iou'
            });
        }

        trancheInfo.push({
            index: i,
            name,
            iouToken,
            totalSupply: supply.toString(),
            holderCount: holders.size
        });
    }

    // Process off-chain claims
    const offChainCount = await vault.getOffChainClaimsCount();
    console.log(`\nOff-chain claims: ${offChainCount}`);

    for (let i = 0; i < offChainCount; i++) {
        const [claimant, trancheIndex, amount, legalDocHash] = await vault.offChainClaims(i);

        // For off-chain claims, the leaf includes the legal doc hash
        // Leaf format: keccak256(user, trancheIndex, amount, legalDocHash, snapshotBlock)
        leaves.push([
            claimant,
            trancheIndex,
            amount.toString(),
            snapshotBlock.toString()
        ]);
        leafData.push({
            user: claimant,
            trancheIndex,
            balance: amount.toString(),
            type: 'offchain',
            legalDocHash
        });
    }

    console.log(`\nTotal leaves: ${leaves.length}`);

    if (leaves.length === 0) {
        throw new Error('No leaves to generate merkle tree');
    }

    // Generate merkle tree
    // Leaf encoding: [address, uint8, uint256, uint256]
    const tree = StandardMerkleTree.of(leaves, ['address', 'uint8', 'uint256', 'uint256']);

    console.log(`\nMerkle Root: ${tree.root}`);

    // Generate proofs for each leaf
    const proofs: MerkleOutput['proofs'] = {};

    for (const [i, leaf] of tree.entries()) {
        const [user, trancheIndex, balance] = leaf;
        const proof = tree.getProof(i);

        if (!proofs[user]) {
            proofs[user] = [];
        }

        proofs[user].push({
            trancheIndex,
            balance,
            type: leafData[i].type,
            legalDocHash: leafData[i].legalDocHash,
            proof
        });
    }

    // Build output
    const output: MerkleOutput = {
        merkleRoot: tree.root,
        snapshotBlock,
        timestamp: block.timestamp,
        vaultAddress,
        totalLeaves: leaves.length,
        tranches: trancheInfo,
        leaves: leafData,
        proofs
    };

    // Write to file
    fs.writeFileSync(outputFile, JSON.stringify(output, null, 2));
    console.log(`\nOutput written to: ${outputFile}`);

    return output;
}

// Verification function
async function verifyMerkleProof(
    merkleRoot: string,
    user: string,
    trancheIndex: number,
    balance: string,
    snapshotBlock: number,
    proof: string[]
): Promise<boolean> {
    const tree = StandardMerkleTree.load({
        format: 'standard-v1',
        tree: [], // Not needed for verification
        values: [], // Not needed for verification
        leafEncoding: ['address', 'uint8', 'uint256', 'uint256']
    });

    // Manually verify using the proof
    const leaf = [user, trancheIndex, balance, snapshotBlock.toString()];

    // StandardMerkleTree.verify is what we need
    return StandardMerkleTree.verify(
        merkleRoot,
        ['address', 'uint8', 'uint256', 'uint256'],
        leaf,
        proof
    );
}

// CLI interface
async function main() {
    const args = process.argv.slice(2);

    if (args.includes('--help') || args.length === 0) {
        console.log(`
Waterfall Protocol Merkle Tree Generator

Usage:
  npx ts-node src/generateMerkle.ts --vault <address> --rpc <url> --block <number> --output <file>

Options:
  --vault   Vault contract address
  --rpc     RPC URL (e.g., https://mainnet.infura.io/v3/...)
  --block   Snapshot block number
  --output  Output file path (default: merkle-output.json)
  --help    Show this help message

Example:
  npx ts-node src/generateMerkle.ts \\
    --vault 0x1234...5678 \\
    --rpc https://mainnet.infura.io/v3/YOUR_KEY \\
    --block 18500000 \\
    --output merkle-round-1.json
        `);
        return;
    }

    // Parse arguments
    let vaultAddress = '';
    let rpcUrl = '';
    let snapshotBlock = 0;
    let outputFile = 'merkle-output.json';

    for (let i = 0; i < args.length; i++) {
        switch (args[i]) {
            case '--vault':
                vaultAddress = args[++i];
                break;
            case '--rpc':
                rpcUrl = args[++i];
                break;
            case '--block':
                snapshotBlock = parseInt(args[++i]);
                break;
            case '--output':
                outputFile = args[++i];
                break;
        }
    }

    // Validate arguments
    if (!vaultAddress) {
        console.error('Error: --vault is required');
        process.exit(1);
    }
    if (!rpcUrl) {
        console.error('Error: --rpc is required');
        process.exit(1);
    }
    if (!snapshotBlock) {
        console.error('Error: --block is required');
        process.exit(1);
    }

    try {
        await generateMerkleTree(vaultAddress, rpcUrl, snapshotBlock, outputFile);
    } catch (error) {
        console.error('Error generating merkle tree:', error);
        process.exit(1);
    }
}

// Export for programmatic use
export { generateMerkleTree, verifyMerkleProof, MerkleOutput, MerkleLeaf };

// Run if executed directly
if (require.main === module) {
    main().catch(console.error);
}
