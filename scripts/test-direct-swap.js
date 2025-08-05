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

// Simple WBERA interface
const WBERA_ABI = [
  "function deposit() payable",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)"
];

async function testDirectSwap() {
  console.log('=== Testing Direct Swap to Generate Fees ===\n');
  
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, wallet);
  const wbera = new ethers.Contract(process.env.WBERA_ADDRESS, WBERA_ABI, wallet);
  
  // Check initial state
  const [r0, r1] = await pair.getReserves();
  const kBefore = r0 * r1;
  console.log('Initial reserves:');
  console.log('TOK (r0):', ethers.formatEther(r0));
  console.log('WBERA (r1):', ethers.formatEther(r1));
  console.log('K before:', kBefore.toString());
  
  // Swap amount
  const swapAmount = ethers.parseEther('0.0001');
  
  try {
    // 1. Wrap BERA to WBERA
    console.log('\n1. Wrapping BERA to WBERA...');
    const wrapTx = await wbera.deposit({ value: swapAmount });
    await wrapTx.wait();
    console.log('Wrapped successfully');
    
    // 2. Transfer WBERA to pair
    console.log('\n2. Transferring WBERA to pair...');
    const transferTx = await wbera.transfer(process.env.TOK_PAIR, swapAmount);
    await transferTx.wait();
    console.log('Transferred successfully');
    
    // 3. Calculate expected output (with fee)
    const fee = await pair.currentFeeBps();
    console.log('Current fee:', fee.toString(), 'bps');
    
    const amountInWithFee = swapAmount * (10000n - fee) / 10000n;
    const numerator = amountInWithFee * r0;
    const denominator = r1 + amountInWithFee;
    const amountOut = numerator / denominator;
    
    console.log('\n3. Swapping...');
    console.log('Expected TOK out:', ethers.formatEther(amountOut));
    
    // 4. Execute swap
    const swapTx = await pair.swap(amountOut, 0n, wallet.address);
    console.log('Swap transaction:', swapTx.hash);
    const receipt = await swapTx.wait();
    console.log('Swap successful!');
    
    // Check K after
    const [r0After, r1After] = await pair.getReserves();
    const kAfter = r0After * r1After;
    const kLast = await pair.kLast();
    
    console.log('\nAfter swap:');
    console.log('TOK (r0):', ethers.formatEther(r0After));
    console.log('WBERA (r1):', ethers.formatEther(r1After));
    console.log('K after:', kAfter.toString());
    console.log('K last:', kLast.toString());
    console.log('K growth:', ((kAfter - kLast) * 10000n / kLast).toString(), 'bps');
  } catch (error) {
    console.error('Error:', error.message);
  }
}

testDirectSwap().catch(console.error);