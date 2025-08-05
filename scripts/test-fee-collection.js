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

async function testFeeCollection() {
  console.log('=== Testing Fee Collection ===\n');
  
  const feeRouterABI = loadABI('FeeRouter');
  const pairABI = loadABI('OsitoPair');
  
  const feeRouter = new ethers.Contract(process.env.FEE_ROUTER, feeRouterABI, wallet);
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  
  // Check LP balance
  const lpBalance = await pair.balanceOf(process.env.FEE_ROUTER);
  console.log('FeeRouter LP balance:', ethers.formatEther(lpBalance));
  
  if (lpBalance === 0n) {
    console.log('No LP balance to collect fees from');
    return;
  }
  
  // Check K growth
  const [r0, r1] = await pair.getReserves();
  const currentK = r0 * r1;
  const kLast = await pair.kLast();
  
  console.log('\nCurrent K:', currentK.toString());
  console.log('K Last:', kLast.toString());
  console.log('K Growth:', ((currentK - kLast) * 100n / kLast).toString() + '%');
  
  try {
    console.log('\nCalling collectFees()...');
    const tx = await feeRouter.collectFees({ gasLimit: 500000 });
    console.log('Transaction:', tx.hash);
    
    const receipt = await tx.wait();
    console.log('Status:', receipt.status === 1 ? 'SUCCESS' : 'FAILED');
    console.log('Gas used:', receipt.gasUsed.toString());
    
    // Parse logs
    for (const log of receipt.logs) {
      console.log('\nLog:', log);
    }
  } catch (error) {
    console.error('\nError:', error.message);
    console.error('Reason:', error.reason);
    console.error('Data:', error.data);
  }
}

testFeeCollection().catch(console.error);