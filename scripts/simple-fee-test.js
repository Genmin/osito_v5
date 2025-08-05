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

async function simpleFeeTest() {
  const pairAddress = process.env.TOK_PAIR;
  const pairABI = loadABI('OsitoPair');
  const feeRouterABI = loadABI('FeeRouter');
  
  const pair = new ethers.Contract(pairAddress, pairABI, wallet);
  const feeRouterAddress = await pair.feeRouter();
  const feeRouter = new ethers.Contract(feeRouterAddress, feeRouterABI, wallet);
  
  console.log('=== SIMPLE FEE COLLECTION TEST ===\n');
  
  // Step 1: Check K growth
  const [r0, r1] = await pair.getReserves();
  const currentK = r0 * r1;
  const kLast = await pair.kLast();
  console.log('K growth:', ((currentK - kLast) * 10000n / kLast).toString(), 'bps');
  
  // Step 2: FeeRouter already has the LP, it just needs to:
  // - Transfer 1 LP to pair
  // - Call burn() to trigger _mintFee
  // - Then collect the newly minted fees
  
  // But wait... FeeRouter.collectFees() already does this!
  // It transfers LP to pair (line 53) and calls burn (line 54)
  
  console.log('\nThe issue is FeeRouter thinks it has no excess LP.');
  console.log('But if it burns even 1 wei from principal, it will trigger fee minting.');
  console.log('\nThe fix is simple: modify FeeRouter to burn 1 wei when K > kLast');
  
  // Let's prove this would work by manually doing it:
  // We can't impersonate FeeRouter on testnet, but we can show the logic
  
  const lpBalance = await pair.balanceOf(feeRouterAddress);
  const principalLp = await feeRouter.principalLp();
  
  console.log('\nCurrent state:');
  console.log('FeeRouter LP:', ethers.formatEther(lpBalance));
  console.log('Principal LP:', ethers.formatEther(principalLp));
  console.log('Excess:', ethers.formatEther(lpBalance - principalLp));
  
  console.log('\n=== THE FIX ===');
  console.log('Modify FeeRouter.collectFees() to:');
  console.log('1. Check if K > kLast (fees accrued)');
  console.log('2. If yes, burn 1 wei to trigger _mintFee');
  console.log('3. Then collect the newly minted excess LP');
  console.log('\nThis is a 5-line change to FeeRouter, no new complexity.');
}

simpleFeeTest().catch(console.error);