const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

// Configuration
const CONFIG = {
  RPC_URL: process.env.RPC_URL,
  PRIVATE_KEY: process.env.PRIVATE_KEY,
  PAIR_ADDRESS: '0x45b0A2EE6d3F91584647D3ac8B94A50bf456F69C',
  SWAP_ROUTER: process.env.SWAP_ROUTER,
  WBERA: '0x6969696969696969696969696969696969696969'
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
const SWAP_ROUTER_ABI = loadABI('SwapRouter');
const ERC20_ABI = [
  'function approve(address spender, uint256 amount) returns (bool)',
  'function balanceOf(address owner) view returns (uint256)'
];

async function createSwap() {
  console.log('Creating swap to generate K growth...\n');
  
  const router = new ethers.Contract(CONFIG.SWAP_ROUTER, SWAP_ROUTER_ABI, wallet);
  
  // Check ETH balance
  const balance = await provider.getBalance(wallet.address);
  console.log('ETH Balance:', ethers.formatEther(balance));
  
  if (balance < ethers.parseEther('0.001')) {
    console.log('Insufficient ETH balance');
    return;
  }
  
  const amountIn = ethers.parseEther('0.001'); // Small swap
  
  // Execute swap: ETH -> TOK using swapExactETHForTokens
  console.log('Executing swap: 0.001 ETH -> TOK');
  const swapTx = await router.swapExactETHForTokens(
    CONFIG.PAIR_ADDRESS,    // core (pair)
    0,                     // minAmountOut
    wallet.address,        // to
    Math.floor(Date.now() / 1000) + 3600,  // deadline
    { value: amountIn }    // send ETH as value
  );
  
  console.log('Swap tx:', swapTx.hash);
  const receipt = await swapTx.wait();
  console.log('Swap confirmed in block:', receipt.blockNumber);
  console.log('\nK growth generated! Now run the analysis script again.');
}

createSwap().catch(console.error);