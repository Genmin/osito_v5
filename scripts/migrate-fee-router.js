const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

const loadABI = (contractName) => {
  const abiPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  return artifact.abi;
};

async function migrateFeeRouter() {
  console.log('=== Checking FeeRouter Setup ===\n');
  
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  
  // Check current fee router
  const currentFeeRouter = await pair.feeRouter();
  console.log('Current FeeRouter:', currentFeeRouter);
  console.log('Expected:', process.env.FEE_ROUTER);
  
  // Since feeRouter is immutable, we need to redeploy the entire pair
  // This would require:
  // 1. Remove liquidity from current pair
  // 2. Deploy new pair with new FeeRouter
  // 3. Add liquidity to new pair
  
  console.log('\n⚠️  WARNING: FeeRouter is immutable in OsitoPair');
  console.log('To use a new FeeRouter, you would need to:');
  console.log('1. Deploy a new TOK token');
  console.log('2. Deploy a new pair with the updated FeeRouter');
  console.log('3. Migrate liquidity to the new pair');
}

migrateFeeRouter().catch(console.error);