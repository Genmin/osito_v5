const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

// Configuration
const CONFIG = {
  RPC_URL: process.env.RPC_URL,
  PAIR_ADDRESS: '0x45b0A2EE6d3F91584647D3ac8B94A50bf456F69C', // The affected pair
};

// Load ABIs
const loadABI = (contractName) => {
  const abiPath = path.join(__dirname, '..', 'out', `${contractName}.sol`, `${contractName}.json`);
  const artifact = JSON.parse(fs.readFileSync(abiPath, 'utf8'));
  return artifact.abi;
};

// Initialize provider
const provider = new ethers.JsonRpcProvider(CONFIG.RPC_URL);

// Contract ABIs
const PAIR_ABI = loadABI('OsitoPair');
const TOKEN_ABI = loadABI('OsitoToken');

async function investigateFeeImpact() {
  console.log('🔍 Investigating Fee Collection Impact on Price\n');
  console.log('Pair:', CONFIG.PAIR_ADDRESS);
  console.log('---\n');

  const pair = new ethers.Contract(CONFIG.PAIR_ADDRESS, PAIR_ABI, provider);
  
  // Get token addresses
  const token0 = await pair.token0();
  const token1 = await pair.token1();
  const tokIsToken0 = await pair.tokIsToken0();
  
  const tokAddr = tokIsToken0 ? token0 : token1;
  const qtAddr = tokIsToken0 ? token1 : token0;
  
  console.log('TOK Address:', tokAddr);
  console.log('QT Address:', qtAddr);
  console.log('TOK is token0:', tokIsToken0);
  console.log('---\n');
  
  // Get current reserves
  const [reserve0, reserve1] = await pair.getReserves();
  const rTok = tokIsToken0 ? reserve0 : reserve1;
  const rQt = tokIsToken0 ? reserve1 : reserve0;
  
  console.log('Current Reserves:');
  console.log('  TOK Reserve:', ethers.formatEther(rTok));
  console.log('  QT Reserve:', ethers.formatEther(rQt));
  console.log('  Spot Price (QT/TOK):', ethers.formatEther(rQt * 10n**18n / rTok));
  console.log('---\n');
  
  // Get total supply of both tokens
  const tokContract = new ethers.Contract(tokAddr, TOKEN_ABI, provider);
  const qtContract = new ethers.Contract(qtAddr, TOKEN_ABI, provider);
  
  const tokSupply = await tokContract.totalSupply();
  const qtSupply = await qtContract.totalSupply();
  
  console.log('Token Supplies:');
  console.log('  TOK Total Supply:', ethers.formatEther(tokSupply));
  console.log('  QT Total Supply:', ethers.formatEther(qtSupply));
  console.log('---\n');
  
  // Calculate market cap
  const mcap = rQt * tokSupply / rTok;
  console.log('Market Cap (in QT):', ethers.formatEther(mcap));
  console.log('---\n');
  
  // Get LP token info
  const totalLpSupply = await pair.totalSupply();
  const feeRouter = await pair.feeRouter();
  const feeRouterLp = await pair.balanceOf(feeRouter);
  
  console.log('LP Token Info:');
  console.log('  Total LP Supply:', ethers.formatEther(totalLpSupply));
  console.log('  FeeRouter LP Balance:', ethers.formatEther(feeRouterLp));
  console.log('  FeeRouter Address:', feeRouter);
  console.log('---\n');
  
  // Calculate K values
  const currentK = reserve0 * reserve1;
  const kLast = await pair.kLast();
  
  console.log('K Values:');
  console.log('  Current K:', currentK.toString());
  console.log('  K Last:', kLast.toString());
  if (kLast > 0n) {
    const kGrowth = ((currentK - kLast) * 10000n) / kLast;
    console.log('  K Growth:', Number(kGrowth) / 100, '%');
  }
  console.log('---\n');
  
  // CRITICAL ANALYSIS
  console.log('⚠️  CRITICAL ANALYSIS:');
  console.log('When fees are collected:');
  console.log('1. LP tokens are minted to FeeRouter (dilutes all LP holders)');
  console.log('2. FeeRouter burns these LP tokens to get TOK + QT');
  console.log('3. This REMOVES liquidity from the pool reserves');
  console.log('4. TOK is burned (reduces supply) but QT goes to treasury');
  console.log('5. Result: Both reserves decrease, changing the price!\n');
  
  // Simulate what happens during fee collection
  if (feeRouterLp > 0n) {
    const lpPercent = feeRouterLp * 10000n / totalLpSupply;
    const tokRemoved = rTok * lpPercent / 10000n;
    const qtRemoved = rQt * lpPercent / 10000n;
    
    console.log('📊 Simulated Fee Collection Impact:');
    console.log('  LP to burn:', ethers.formatEther(feeRouterLp), `(${Number(lpPercent)/100}% of total)`);
    console.log('  TOK to remove from reserves:', ethers.formatEther(tokRemoved));
    console.log('  QT to remove from reserves:', ethers.formatEther(qtRemoved));
    
    const newRTok = rTok - tokRemoved;
    const newRQt = rQt - qtRemoved;
    const newPrice = newRQt * 10n**18n / newRTok;
    const oldPrice = rQt * 10n**18n / rTok;
    
    console.log('\n  Old Price:', ethers.formatEther(oldPrice));
    console.log('  New Price:', ethers.formatEther(newPrice));
    console.log('  Price Change:', ((Number(newPrice - oldPrice) / Number(oldPrice)) * 100).toFixed(2), '%');
    
    // New market cap after TOK burn
    const newTokSupply = tokSupply - tokRemoved;
    const newMcap = newRQt * newTokSupply / newRTok;
    
    console.log('\n  Old Market Cap:', ethers.formatEther(mcap));
    console.log('  New Market Cap:', ethers.formatEther(newMcap));
    console.log('  Market Cap Change:', ((Number(newMcap - mcap) / Number(mcap)) * 100).toFixed(2), '%');
  }
}

investigateFeeImpact().catch(console.error);