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

async function addPairToLens() {
  console.log('=== Adding Pair to LensLite ===\n');
  
  const lensABI = loadABI('LensLite');
  const lens = new ethers.Contract(process.env.LENS_LITE, lensABI, wallet);
  
  try {
    console.log('Adding pair:', process.env.TOK_PAIR);
    const tx = await lens.addPair(process.env.TOK_PAIR);
    console.log('Transaction:', tx.hash);
    
    const receipt = await tx.wait();
    console.log('Status:', receipt.status === 1 ? 'SUCCESS' : 'FAILED');
    
    // Check how many pairs we have now
    const pairCount = await lens.allPairsLength();
    console.log('\nTotal pairs in LensLite:', pairCount.toString());
  } catch (error) {
    console.error('Error:', error.message);
  }
}

addPairToLens().catch(console.error);