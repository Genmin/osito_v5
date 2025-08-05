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

async function testSwap() {
  console.log('=== Testing Swap to Generate Fees ===\n');
  
  const routerABI = loadABI('SwapRouter');
  const pairABI = loadABI('OsitoPair');
  const tokenABI = loadABI('OsitoToken');
  
  const router = new ethers.Contract(process.env.SWAP_ROUTER, routerABI, wallet);
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  const tok = new ethers.Contract(process.env.TOK, tokenABI, provider);
  
  // Check initial state
  const [r0, r1] = await pair.getReserves();
  const kBefore = r0 * r1;
  console.log('Initial reserves:');
  console.log('TOK:', ethers.formatEther(r0));
  console.log('WBERA:', ethers.formatEther(r1));
  console.log('K before:', kBefore.toString());
  
  // Swap 0.0001 WBERA for TOK
  const swapAmount = ethers.parseEther('0.0001');
  
  try {
    console.log('\nSwapping 0.0001 WBERA for TOK...');
    const tx = await router.swapExactETHForTokens(
      0, // min out
      [process.env.WBERA_ADDRESS, process.env.TOK],
      wallet.address,
      Math.floor(Date.now() / 1000) + 3600,
      { value: swapAmount }
    );
    
    console.log('Transaction:', tx.hash);
    const receipt = await tx.wait();
    console.log('Status:', receipt.status === 1 ? 'SUCCESS' : 'FAILED');
    
    // Check K after
    const [r0After, r1After] = await pair.getReserves();
    const kAfter = r0After * r1After;
    const kLast = await pair.kLast();
    
    console.log('\nAfter swap:');
    console.log('TOK:', ethers.formatEther(r0After));
    console.log('WBERA:', ethers.formatEther(r1After));
    console.log('K after:', kAfter.toString());
    console.log('K last:', kLast.toString());
    console.log('K growth:', ((kAfter - kBefore) * 100n / kBefore).toString() + '%');
  } catch (error) {
    console.error('Error:', error.message);
  }
}

testSwap().catch(console.error);