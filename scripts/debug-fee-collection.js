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

async function debugFeeCollection() {
  console.log('=== Debugging Fee Collection ===\n');
  
  const feeRouterABI = loadABI('FeeRouter');
  const pairABI = loadABI('OsitoPair');
  
  const feeRouter = new ethers.Contract(process.env.FEE_ROUTER, feeRouterABI, provider);
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  
  // Check state
  console.log('FeeRouter:', process.env.FEE_ROUTER);
  console.log('Pair:', process.env.TOK_PAIR);
  
  // Check if FeeRouter is set on pair
  const pairFeeRouter = await pair.feeRouter();
  console.log('\nPair\'s feeRouter:', pairFeeRouter);
  console.log('Match:', pairFeeRouter === process.env.FEE_ROUTER);
  
  // Check LP balance
  const lpBalance = await pair.balanceOf(process.env.FEE_ROUTER);
  console.log('\nFeeRouter LP balance:', ethers.formatEther(lpBalance));
  
  // Check pair state
  const [r0, r1] = await pair.getReserves();
  const totalSupply = await pair.totalSupply();
  console.log('\nPair state:');
  console.log('Reserve0:', ethers.formatEther(r0));
  console.log('Reserve1:', ethers.formatEther(r1));
  console.log('Total LP:', ethers.formatEther(totalSupply));
  
  // Check what burning all LP would give
  const amt0 = (lpBalance * r0) / totalSupply;
  const amt1 = (lpBalance * r1) / totalSupply;
  console.log('\nBurning all LP would give:');
  console.log('TOK:', ethers.formatEther(amt0));
  console.log('WBERA:', ethers.formatEther(amt1));
  
  // Check if amounts are > 0
  console.log('\nWould burn succeed?');
  console.log('amt0 > 0:', amt0 > 0n);
  console.log('amt1 > 0:', amt1 > 0n);
  
  // The burn function in OsitoPair requires both amounts > 0
  if (amt0 === 0n || amt1 === 0n) {
    console.log('\n⚠️  ERROR: One of the amounts is 0!');
    console.log('This would cause INSUFFICIENT_LIQUIDITY_BURNED');
  }
}

debugFeeCollection().catch(console.error);