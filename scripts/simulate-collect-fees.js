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

async function simulateCollectFees() {
  console.log('=== Simulating collectFees() ===\n');
  
  const feeRouterABI = loadABI('FeeRouter');
  const feeRouter = new ethers.Contract(process.env.FEE_ROUTER, feeRouterABI, provider);
  
  // Also check LP balance
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  const lpBalance = await pair.balanceOf(process.env.FEE_ROUTER);
  console.log('FeeRouter LP balance:', ethers.formatEther(lpBalance));
  
  try {
    // Simulate the call
    await feeRouter.collectFees.staticCall();
    console.log('Simulation succeeded!');
  } catch (error) {
    console.error('Simulation failed:', error.message);
    console.error('Reason:', error.reason);
    console.error('Method:', error.method);
    console.error('Error code:', error.code);
    
    if (error.data) {
      console.error('\nError data:', error.data);
      
      // Try to decode revert reason
      if (error.data.startsWith('0x08c379a0')) {
        // Standard revert string
        const reason = ethers.AbiCoder.defaultAbiCoder().decode(['string'], '0x' + error.data.slice(10));
        console.error('Revert reason:', reason[0]);
      }
    }
  }
}

simulateCollectFees().catch(console.error);