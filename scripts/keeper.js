const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

// Configuration
const CONFIG = {
  // RPC endpoint - should be set via environment variable
  RPC_URL: process.env.RPC_URL,
  
  // Private key for the keeper account (using testnet key for now)
  PRIVATE_KEY: process.env.PRIVATE_KEY,
  
  // Contract addresses from deployment
  OSITO_PAIR_FACTORY: process.env.OSITO_PAIR_FACTORY,
  
  // Polling interval in milliseconds (default: 30 seconds)
  POLLING_INTERVAL: process.env.POLLING_INTERVAL || 30000,
  
  // Minimum fees to collect (in wei) - to avoid wasting gas on small amounts
  MIN_FEES_THRESHOLD: process.env.MIN_FEES_THRESHOLD || '1000000000000000', // 0.001 tokens
  
  // Gas settings
  GAS_LIMIT: process.env.GAS_LIMIT || 500000,
  MAX_FEE_PER_GAS: process.env.MAX_FEE_PER_GAS,
  MAX_PRIORITY_FEE_PER_GAS: process.env.MAX_PRIORITY_FEE_PER_GAS,
  
  // Network info
  CHAIN_ID: process.env.CHAIN_ID
};

// Load ABIs
const loadABI = (contractName) => {
  const abiPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  return artifact.abi;
};

// Initialize provider and wallet
const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);
const wallet = new ethers.Wallet(CONFIG.PRIVATE_KEY, provider);

// Contract ABIs
const PAIR_FACTORY_ABI = loadABI('OsitoPairFactoryOptimized');
const PAIR_ABI = loadABI('OsitoPairOptimized');
const FEE_ROUTER_ABI = loadABI('FeeRouterOptimized');

// Contract instances
const pairFactory = new ethers.Contract(CONFIG.OSITO_PAIR_FACTORY, PAIR_FACTORY_ABI, wallet);

async function getAllPairs() {
  try {
    const pairCount = await pairFactory.allPairsLength();
    const pairs = [];
    
    for (let i = 0; i < pairCount; i++) {
      const pairAddress = await pairFactory.allPairs(i);
      pairs.push(pairAddress);
    }
    
    return pairs;
  } catch (error) {
    console.error('Error fetching pairs:', error);
    return [];
  }
}

async function checkAndCollectFees(pairAddress) {
  try {
    // Get the pair contract
    const pair = new ethers.Contract(pairAddress, PAIR_ABI, wallet);
    
    // Get the fee router address
    const feeRouterAddress = await pair.feeRouter();
    if (!feeRouterAddress || feeRouterAddress === ethers.ZeroAddress) {
      console.log(`No fee router set for pair ${pairAddress}`);
      return false;
    }
    
    // Get the fee router contract
    const feeRouter = new ethers.Contract(feeRouterAddress, FEE_ROUTER_ABI, wallet);
    
    // Check for K growth (indicates fees to collect)
    const [reserve0, reserve1] = await pair.getReserves();
    const currentK = reserve0 * reserve1;
    const kLast = await pair.kLast();
    
    console.log(`Pair ${pairAddress}:`);
    console.log(`  Current K: ${currentK}`);
    console.log(`  Last K: ${kLast}`);
    
    // If kLast is 0, this is a new pair with no trades yet
    if (kLast === 0n) {
      console.log(`  New pair with no trades yet`);
      return false;
    }
    
    if (currentK <= kLast) {
      console.log(`  No K growth (no fees to collect)`);
      return false;
    }
    
    // Calculate K growth percentage
    const kGrowth = ((currentK - kLast) * 10000n) / kLast;
    console.log(`  K growth: ${Number(kGrowth) / 100}%`);
    
    // Only collect if K growth is significant (e.g., > 0.1%)
    if (kGrowth < 10n) { // 0.1% = 10 basis points
      console.log(`  K growth too small, skipping collection`);
      return false;
    }
    
    // Estimate gas for the transaction
    const gasEstimate = await feeRouter.collectFees.estimateGas();
    console.log(`  Estimated gas: ${gasEstimate}`);
    
    // Prepare transaction options
    const txOptions = {
      gasLimit: CONFIG.GAS_LIMIT,
    };
    
    // Add EIP-1559 gas settings if provided
    if (CONFIG.MAX_FEE_PER_GAS) {
      txOptions.maxFeePerGas = ethers.parseUnits(CONFIG.MAX_FEE_PER_GAS, 'gwei');
    }
    if (CONFIG.MAX_PRIORITY_FEE_PER_GAS) {
      txOptions.maxPriorityFeePerGas = ethers.parseUnits(CONFIG.MAX_PRIORITY_FEE_PER_GAS, 'gwei');
    }
    
    // Collect fees
    console.log(`  Collecting fees...`);
    const tx = await feeRouter.collectFees(txOptions);
    console.log(`  Transaction hash: ${tx.hash}`);
    
    // Wait for confirmation
    const receipt = await tx.wait();
    console.log(`  Transaction confirmed in block ${receipt.blockNumber}`);
    console.log(`  Gas used: ${receipt.gasUsed}`);
    
    return true;
  } catch (error) {
    console.error(`Error collecting fees for pair ${pairAddress}:`, error.message);
    return false;
  }
}

async function runKeeper() {
  console.log('Starting Osito Fee Collector Keeper (Testnet)');  
  console.log(`Chain ID: ${CONFIG.CHAIN_ID}`);
  console.log(`RPC URL: ${CONFIG.RPC_URL}`);
  console.log(`Pair Factory: ${CONFIG.OSITO_PAIR_FACTORY}`);
  console.log(`Keeper Address: ${wallet.address}`);
  console.log(`Polling Interval: ${CONFIG.POLLING_INTERVAL}ms`);
  console.log('---');
  
  while (true) {
    try {
      console.log(`\n[${new Date().toISOString()}] Checking for fees to collect...`);
      
      // Get all pairs
      const pairs = await getAllPairs();
      console.log(`Found ${pairs.length} pairs`);
      
      // Check and collect fees for each pair
      let collectionsCount = 0;
      for (const pairAddress of pairs) {
        const collected = await checkAndCollectFees(pairAddress);
        if (collected) {
          collectionsCount++;
        }
      }
      
      console.log(`\nCompleted cycle. Collected fees from ${collectionsCount} pairs.`);
      
    } catch (error) {
      console.error('Error in keeper loop:', error);
    }
    
    // Wait for next cycle
    const waitSeconds = CONFIG.POLLING_INTERVAL / 1000;
    console.log(`Waiting ${waitSeconds} seconds until next check...`);
    await new Promise(resolve => setTimeout(resolve, CONFIG.POLLING_INTERVAL));
  }
}

// Graceful shutdown handler
process.on('SIGINT', () => {
  console.log('\nShutting down keeper...');
  process.exit(0);
});

// Validate configuration
if (!CONFIG.PRIVATE_KEY) {
  console.error('ERROR: PRIVATE_KEY not found in .env.testnet');
  process.exit(1);
}

if (!CONFIG.OSITO_PAIR_FACTORY) {
  console.error('ERROR: OSITO_PAIR_FACTORY not found in .env.testnet');
  process.exit(1);
}

// Start the keeper
runKeeper().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});