const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

// Setup
const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

// Load ABIs
const loadABI = (contractName) => {
  const abiPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  return artifact.abi;
};

const SWAP_ROUTER_ABI = loadABI('SwapRouter');

async function doTrade() {
  const swapRouter = new ethers.Contract(process.env.SWAP_ROUTER, SWAP_ROUTER_ABI, wallet);
  
  // Buy TOK with 0.05 BERA
  console.log('Executing swap: 0.05 BERA -> TOK');
  const tx = await swapRouter.swapExactETHForTokens(
    process.env.TOK_PAIR, // pair address
    0, // minAmountOut
    wallet.address,
    Math.floor(Date.now() / 1000) + 300, // deadline
    { value: ethers.parseEther('0.05') }
  );
  
  console.log('Transaction:', tx.hash);
  const receipt = await tx.wait();
  console.log('Confirmed in block:', receipt.blockNumber);
  
  // Check reserves after
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, wallet);
  const [r0, r1] = await pair.getReserves();
  const kAfter = r0 * r1;
  const kLast = await pair.kLast();
  
  console.log('\nAfter trade:');
  console.log('Reserve0:', r0.toString());
  console.log('Reserve1:', r1.toString());
  console.log('Current K:', kAfter.toString());
  console.log('kLast:', kLast.toString());
  console.log('K growth:', ((kAfter - kLast) * 10000n / kLast).toString(), 'bps');
}

doTrade().catch(console.error);