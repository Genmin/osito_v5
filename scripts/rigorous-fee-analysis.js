const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

// Configuration
const CONFIG = {
  RPC_URL: process.env.RPC_URL,
  PRIVATE_KEY: process.env.PRIVATE_KEY,
  PAIR_ADDRESS: '0x45b0A2EE6d3F91584647D3ac8B94A50bf456F69C',
  FEE_ROUTER: '0xD42c1CA2875bdebBd0b657726E26Fb5b57ebe6AB'
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
const PAIR_ABI = loadABI('OsitoPair');
const TOKEN_ABI = loadABI('OsitoToken');
const FEE_ROUTER_ABI = loadABI('FeeRouter');

async function captureState(pair, label) {
  const [reserve0, reserve1] = await pair.getReserves();
  const tokIsToken0 = await pair.tokIsToken0();
  const token0 = await pair.token0();
  const token1 = await pair.token1();
  
  const tokAddr = tokIsToken0 ? token0 : token1;
  const qtAddr = tokIsToken0 ? token1 : token0;
  
  const tokContract = new ethers.Contract(tokAddr, TOKEN_ABI, provider);
  const tokSupply = await tokContract.totalSupply();
  
  const rTok = tokIsToken0 ? reserve0 : reserve1;
  const rQt = tokIsToken0 ? reserve1 : reserve0;
  
  const spotPrice = rQt * 10n**18n / rTok;
  const marketCap = spotPrice * tokSupply / 10n**18n;
  
  const totalLpSupply = await pair.totalSupply();
  const feeRouterLp = await pair.balanceOf(CONFIG.FEE_ROUTER);
  const kLast = await pair.kLast();
  const currentK = reserve0 * reserve1;
  
  console.log(`\n📊 ${label}:`);
  console.log('  Reserves:');
  console.log(`    TOK: ${ethers.formatEther(rTok)}`);
  console.log(`    QT:  ${ethers.formatEther(rQt)}`);
  console.log(`  Spot Price: ${ethers.formatEther(spotPrice)} QT/TOK`);
  console.log(`  TOK Supply: ${ethers.formatEther(tokSupply)}`);
  console.log(`  Market Cap: ${ethers.formatEther(marketCap)} QT`);
  console.log(`  LP Supply: ${ethers.formatEther(totalLpSupply)}`);
  console.log(`  FeeRouter LP: ${ethers.formatEther(feeRouterLp)}`);
  console.log(`  Current K: ${currentK}`);
  console.log(`  K Last: ${kLast}`);
  
  return {
    rTok,
    rQt,
    spotPrice,
    tokSupply,
    marketCap,
    totalLpSupply,
    feeRouterLp,
    currentK,
    kLast,
    reserve0,
    reserve1
  };
}

async function simulateFeeCollection() {
  console.log('🔬 RIGOROUS FEE COLLECTION ANALYSIS');
  console.log('=====================================\n');
  
  const pair = new ethers.Contract(CONFIG.PAIR_ADDRESS, PAIR_ABI, wallet);
  const feeRouter = new ethers.Contract(CONFIG.FEE_ROUTER, FEE_ROUTER_ABI, wallet);
  
  // Capture initial state
  const beforeState = await captureState(pair, 'BEFORE Fee Collection');
  
  // Check if there are fees to collect
  if (beforeState.currentK <= beforeState.kLast) {
    console.log('\n⚠️  No K growth, no fees to collect');
    return;
  }
  
  const kGrowth = ((beforeState.currentK - beforeState.kLast) * 10000n) / beforeState.kLast;
  console.log(`\n📈 K Growth: ${Number(kGrowth) / 100}%`);
  
  // Calculate expected LP mint using contract formula
  const rootK = sqrt(beforeState.currentK);
  const rootKLast = sqrt(beforeState.kLast);
  
  if (rootK > rootKLast) {
    const numerator = beforeState.totalLpSupply * (rootK - rootKLast);
    const denominator = rootK * 5n + rootKLast;
    const oneSixth = numerator / denominator;
    const expectedLpMint = oneSixth * 54n / 10n; // 90% of fees
    
    console.log(`\n🧮 Expected LP Mint: ${ethers.formatEther(expectedLpMint)}`);
    
    // Calculate what will be removed from reserves
    const newTotalLp = beforeState.totalLpSupply + expectedLpMint;
    const lpPercent = expectedLpMint * 10000n / newTotalLp;
    
    const tokToRemove = beforeState.rTok * expectedLpMint / newTotalLp;
    const qtToRemove = beforeState.rQt * expectedLpMint / newTotalLp;
    
    console.log(`\n⚠️  Expected Reserve Removal:`);
    console.log(`    TOK: ${ethers.formatEther(tokToRemove)} (${Number(lpPercent)/100}% of reserves)`);
    console.log(`    QT:  ${ethers.formatEther(qtToRemove)} (${Number(lpPercent)/100}% of reserves)`);
    
    const newRTok = beforeState.rTok - tokToRemove;
    const newRQt = beforeState.rQt - qtToRemove;
    const newSpotPrice = newRQt * 10n**18n / newRTok;
    const newTokSupply = beforeState.tokSupply - tokToRemove; // TOK gets burned
    const newMarketCap = newSpotPrice * newTokSupply / 10n**18n;
    
    console.log(`\n📊 PREDICTED After Fee Collection:`);
    console.log('  Reserves:');
    console.log(`    TOK: ${ethers.formatEther(newRTok)}`);
    console.log(`    QT:  ${ethers.formatEther(newRQt)}`);
    console.log(`  Spot Price: ${ethers.formatEther(newSpotPrice)} QT/TOK`);
    console.log(`  TOK Supply: ${ethers.formatEther(newTokSupply)}`);
    console.log(`  Market Cap: ${ethers.formatEther(newMarketCap)} QT`);
    
    // Calculate the ACTUAL price change
    const priceRatioBefore = beforeState.rQt * 10000n / beforeState.rTok;
    const priceRatioAfter = newRQt * 10000n / newRTok;
    const priceChange = priceRatioBefore > 0n ? ((priceRatioAfter - priceRatioBefore) * 10000n) / priceRatioBefore : 0n;
    
    console.log(`\n🎯 CRITICAL ANALYSIS:`);
    console.log(`  Price Ratio Before: ${priceRatioBefore}`);
    console.log(`  Price Ratio After: ${priceRatioAfter}`);
    console.log(`  Price Change: ${Number(priceChange) / 100}%`);
    console.log(`  Market Cap Change: ${ethers.formatEther(newMarketCap - beforeState.marketCap)} QT`);
    
    if (Math.abs(Number(priceChange)) < 1) {
      console.log(`\n✅ Price ratio remains virtually unchanged (< 0.01% change)`);
      console.log(`   This confirms UniV2 behavior: removing liquidity proportionally doesn't change price`);
      console.log(`\n⚠️  BUT: Market cap still decreases because:`);
      console.log(`   1. Spot price stays ~same`);
      console.log(`   2. TOK supply decreases from burning`);
      console.log(`   3. Market Cap = price × supply, so MC decreases!`);
    }
  }
  
  console.log('\n---\nExecuting actual fee collection...\n');
  
  // Actually collect fees
  try {
    const tx = await feeRouter.collectFees({ gasLimit: 500000 });
    console.log(`Transaction: ${tx.hash}`);
    const receipt = await tx.wait();
    console.log(`Confirmed in block ${receipt.blockNumber}`);
    
    // Capture state after
    const afterState = await captureState(pair, 'ACTUAL After Fee Collection');
    
    // Compare
    console.log('\n📊 COMPARISON:');
    console.log(`  Reserve TOK Change: ${ethers.formatEther(afterState.rTok - beforeState.rTok)}`);
    console.log(`  Reserve QT Change: ${ethers.formatEther(afterState.rQt - beforeState.rQt)}`);
    console.log(`  Spot Price Change: ${ethers.formatEther(afterState.spotPrice - beforeState.spotPrice)}`);
    console.log(`  TOK Supply Change: ${ethers.formatEther(afterState.tokSupply - beforeState.tokSupply)}`);
    console.log(`  Market Cap Change: ${ethers.formatEther(afterState.marketCap - beforeState.marketCap)}`);
    
    const actualPriceChange = ((afterState.spotPrice - beforeState.spotPrice) * 10000n) / beforeState.spotPrice;
    console.log(`  Actual Price Change: ${Number(actualPriceChange) / 100}%`);
    
  } catch (error) {
    console.error('Fee collection failed:', error.message);
  }
}

// Helper function for square root
function sqrt(value) {
  if (value < 0n) throw new Error('Square root of negative number');
  if (value === 0n) return 0n;
  
  let z = value;
  let x = value / 2n + 1n;
  while (x < z) {
    z = x;
    x = (value / x + x) / 2n;
  }
  return z;
}

simulateFeeCollection().catch(console.error);