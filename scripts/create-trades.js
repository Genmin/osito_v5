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

async function createTrades() {
  console.log('=== Creating Trades to Generate Fees ===\n');
  
  const swapRouterABI = loadABI('SwapRouter');
  const pairABI = loadABI('OsitoPair');
  
  const swapRouter = new ethers.Contract(process.env.SWAP_ROUTER, swapRouterABI, wallet);
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, wallet);
  
  // Check initial state
  const [r0, r1] = await pair.getReserves();
  const kBefore = r0 * r1;
  const kLastBefore = await pair.kLast();
  
  console.log('Initial State:');
  console.log('Reserve0 (TOK):', ethers.formatEther(r0));
  console.log('Reserve1 (WBERA):', ethers.formatEther(r1));
  console.log('K before:', kBefore.toString());
  console.log('kLast before:', kLastBefore.toString());
  
  // Do 5 buy trades to create K growth
  console.log('\nExecuting trades...');
  
  for (let i = 0; i < 5; i++) {
    const ethAmount = ethers.parseEther('0.1'); // Buy with 0.1 BERA each time
    
    console.log(`\nTrade ${i + 1}: Buying TOK with 0.1 BERA`);
    const tx = await swapRouter.swapExactETHForTokens(
      process.env.TOK_PAIR,
      0, // minAmountOut
      wallet.address,
      Math.floor(Date.now() / 1000) + 300,
      { value: ethAmount }
    );
    
    const receipt = await tx.wait();
    console.log(`TX: ${tx.hash}`);
    console.log(`Gas used: ${receipt.gasUsed.toString()}`);
  }
  
  // Check final state
  const [r0After, r1After] = await pair.getReserves();
  const kAfter = r0After * r1After;
  const kLastAfter = await pair.kLast();
  
  console.log('\nFinal State:');
  console.log('Reserve0 (TOK):', ethers.formatEther(r0After));
  console.log('Reserve1 (WBERA):', ethers.formatEther(r1After));
  console.log('K after:', kAfter.toString());
  console.log('kLast after:', kLastAfter.toString());
  
  const kGrowth = ((kAfter - kLastAfter) * 10000n) / kLastAfter;
  console.log('\n📈 K Growth:', Number(kGrowth) / 100, '%');
  
  console.log('\n✅ Trades complete! Ready to test fee collection.');
}

createTrades().catch(console.error);