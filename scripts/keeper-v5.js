const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

// Configuration
const CONFIG = {
  RPC_URL: process.env.RPC_URL,
  PRIVATE_KEY: process.env.PRIVATE_KEY,
  LENS_LITE: process.env.LENS_LITE,
  POLLING_INTERVAL: process.env.POLLING_INTERVAL || 30000,
  MIN_K_GROWTH: 10n, // 0.1% minimum K growth to collect
  GAS_LIMIT: process.env.GAS_LIMIT || 500000,
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
const LENS_LITE_ABI = loadABI('LensLite');
const PAIR_ABI = loadABI('OsitoPair');
const FEE_ROUTER_ABI = loadABI('FeeRouter');

// Contract instances
const lensLite = new ethers.Contract(CONFIG.LENS_LITE, LENS_LITE_ABI, wallet);

async function getAllPairs() {
  try {
    const pairCount = await lensLite.allPairsLength();
    const pairs = [];
    
    for (let i = 0; i < pairCount; i++) {
      const pairAddress = await lensLite.allPairs(i);
      pairs.push(pairAddress);
    }
    
    console.log(`Found ${pairs.length} pairs from LensLite`);
    return pairs;
  } catch (error) {
    console.error('Error fetching pairs:', error);
    return [];
  }
}

async function checkAndCollectFees(pairAddress) {
  try {
    const pair = new ethers.Contract(pairAddress, PAIR_ABI, wallet);
    
    // Get fee router address
    const feeRouterAddress = await pair.feeRouter();
    if (!feeRouterAddress || feeRouterAddress === ethers.ZeroAddress) {
      console.log(`No fee router for pair ${pairAddress}`);
      return false;
    }
    
    const feeRouter = new ethers.Contract(feeRouterAddress, FEE_ROUTER_ABI, wallet);
    
    // Check K growth
    const [reserve0, reserve1] = await pair.getReserves();
    const currentK = reserve0 * reserve1;
    const kLast = await pair.kLast();
    
    console.log(`\nPair ${pairAddress}:`);
    console.log(`  Current K: ${currentK}`);
    console.log(`  Last K: ${kLast}`);
    
    if (kLast === 0n) {
      console.log(`  New pair, no trades yet`);
      return false;
    }
    
    if (currentK <= kLast) {
      console.log(`  No K growth`);
      return false;
    }
    
    // Calculate growth
    const kGrowth = ((currentK - kLast) * 10000n) / kLast;
    console.log(`  K growth: ${Number(kGrowth) / 100}%`);
    
    if (kGrowth < CONFIG.MIN_K_GROWTH) {
      console.log(`  K growth too small`);
      return false;
    }
    
    // Just call collectFees - it handles everything internally now
    console.log(`  💰 Collecting fees...`);
    const tx = await feeRouter.collectFees({ gasLimit: CONFIG.GAS_LIMIT });
    console.log(`  Transaction: ${tx.hash}`);
    
    const receipt = await tx.wait();
    console.log(`  ✅ Confirmed in block ${receipt.blockNumber}`);
    console.log(`  Gas used: ${receipt.gasUsed}`);
    
    // Parse logs to see what was collected
    for (const log of receipt.logs) {
      if (log.address.toLowerCase() === feeRouterAddress.toLowerCase()) {
        try {
          const parsed = feeRouter.interface.parseLog(log);
          if (parsed && parsed.name === 'FeesCollected') {
            console.log(`  🔥 TOK burned: ${ethers.formatEther(parsed.args[0])}`);
            console.log(`  💎 QT to treasury: ${ethers.formatEther(parsed.args[1])}`);
          }
        } catch (e) {
          // Try manual parsing
          if (log.topics[0] === ethers.id('FeesCollected(uint256,uint256)')) {
            const tokBurned = BigInt(log.topics[1]);
            const qtCollected = BigInt(log.topics[2]);
            console.log(`  🔥 TOK burned: ${ethers.formatEther(tokBurned)}`);
            console.log(`  💎 QT to treasury: ${ethers.formatEther(qtCollected)}`);
          }
        }
      }
    }
    
    return true;
  } catch (error) {
    console.error(`Error collecting fees for ${pairAddress}:`, error.message);
    return false;
  }
}

async function runKeeper() {
  console.log('🤖 Starting Osito V5 Fee Collector Keeper');
  console.log(`Chain: ${CONFIG.CHAIN_ID}`);
  console.log(`Keeper: ${wallet.address}`);
  console.log(`LensLite: ${CONFIG.LENS_LITE}`);
  console.log('---');
  
  // Run once immediately
  try {
    const pairs = await getAllPairs();
    for (const pairAddress of pairs) {
      await checkAndCollectFees(pairAddress);
    }
  } catch (error) {
    console.error('Error:', error);
  }
}

// Start keeper
runKeeper().catch(error => {
  console.error('Fatal error:', error);
  process.exit(1);
});