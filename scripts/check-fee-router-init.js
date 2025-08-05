const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

const loadABI = (contractName) => {
  const abiPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  return artifact.abi;
};

async function checkFeeRouterInit() {
  console.log('=== Checking FeeRouter Initialization ===\n');
  
  const feeRouterABI = loadABI('FeeRouter');
  const feeRouter = new ethers.Contract(process.env.FEE_ROUTER, feeRouterABI, provider);
  
  try {
    // Check if pair is set
    const pair = await feeRouter.pair();
    console.log('FeeRouter.pair():', pair);
    console.log('Expected:', process.env.TOK_PAIR);
    console.log('Match:', pair.toLowerCase() === process.env.TOK_PAIR.toLowerCase());
    
    // Check treasury
    const treasury = await feeRouter.treasury();
    console.log('\nFeeRouter.treasury():', treasury);
    
    // Check factory
    const factory = await feeRouter.factory();
    console.log('FeeRouter.factory():', factory);
    
    // Check lastReserve0 and lastReserve1
    try {
      const lastReserve0 = await feeRouter.lastReserve0();
      const lastReserve1 = await feeRouter.lastReserve1();
      console.log('\nlastReserve0:', ethers.formatEther(lastReserve0));
      console.log('lastReserve1:', ethers.formatEther(lastReserve1));
    } catch (e) {
      console.log('\nCould not read lastReserve0/1 - might not exist in this version');
    }
  } catch (error) {
    console.error('Error:', error.message);
  }
}

checkFeeRouterInit().catch(console.error);