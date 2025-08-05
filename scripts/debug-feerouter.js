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

async function debugFeeRouter() {
  const pairAddress = process.env.TOK_PAIR;
  const pairABI = loadABI('OsitoPair');
  const feeRouterABI = loadABI('FeeRouter');
  
  const pair = new ethers.Contract(pairAddress, pairABI, provider);
  const feeRouterAddress = await pair.feeRouter();
  const feeRouter = new ethers.Contract(feeRouterAddress, feeRouterABI, provider);
  
  console.log('=== FEE ROUTER DEBUG ===');
  console.log('Pair:', pairAddress);
  console.log('FeeRouter:', feeRouterAddress);
  
  // Get all relevant values
  const lpBalance = await pair.balanceOf(feeRouterAddress);
  const principalLp = await feeRouter.principalLp();
  const totalSupply = await pair.totalSupply();
  
  console.log('\nLP Token State:');
  console.log('Total LP Supply:', ethers.formatEther(totalSupply));
  console.log('FeeRouter LP Balance:', ethers.formatEther(lpBalance));
  console.log('Principal LP:', ethers.formatEther(principalLp));
  console.log('Excess LP:', ethers.formatEther(lpBalance - principalLp));
  
  // Get K values
  const [r0, r1] = await pair.getReserves();
  const currentK = r0 * r1;
  const kLast = await pair.kLast();
  
  console.log('\nK Values:');
  console.log('Current K:', currentK.toString());
  console.log('kLast:', kLast.toString());
  console.log('K Growth:', ((currentK - kLast) * 10000n / kLast).toString(), 'bps');
  
  // Calculate expected fee LP
  if (currentK > kLast && kLast > 0n) {
    const rootK = sqrt(currentK);
    const rootKLast = sqrt(kLast);
    const numerator = totalSupply * (rootK - rootKLast);
    const denominator = (rootK * 5n) + rootKLast;
    const expectedFeeLp = numerator / denominator;
    
    console.log('\nExpected Fee Calculation:');
    console.log('sqrt(K):', rootK.toString());
    console.log('sqrt(kLast):', rootKLast.toString());
    console.log('Expected Fee LP:', ethers.formatEther(expectedFeeLp));
  }
  
  // Simulate collectFees to see what would happen
  console.log('\n=== SIMULATING collectFees ===');
  
  if (lpBalance <= principalLp) {
    console.log('❌ Would return early: lpBalance <= principalLp');
    console.log('No excess LP to collect!');
  } else {
    const excessLp = lpBalance - principalLp;
    const feeLp = excessLp * 9000n / 10000n;
    console.log('✅ Would proceed with collection:');
    console.log('Excess LP:', ethers.formatEther(excessLp));
    console.log('Fee LP (90%):', ethers.formatEther(feeLp));
  }
  
  // The key issue: Fees haven't been minted as LP yet!
  console.log('\n=== ROOT CAUSE ===');
  console.log('Fees accumulate as K growth but are NOT minted as LP until:');
  console.log('1. Someone calls mint() - but it\'s restricted to FeeRouter only!');
  console.log('2. Someone calls burn() - but who has LP to burn?');
  console.log('\nThis appears to be a design issue in V5.');
}

// Babylonian square root
function sqrt(y) {
  if (y > 3n) {
    let z = y;
    let x = y / 2n + 1n;
    while (x < z) {
      z = x;
      x = (y / x + x) / 2n;
    }
    return z;
  } else if (y != 0n) {
    return 1n;
  } else {
    return 0n;
  }
}

debugFeeRouter().catch(console.error);