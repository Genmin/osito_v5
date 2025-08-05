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

async function checkFeeRouterState() {
  console.log('=== Checking FeeRouter State ===\n');
  
  const pairABI = loadABI('OsitoPair');
  const feeRouterABI = loadABI('FeeRouter');
  const tokenABI = loadABI('OsitoToken');
  
  const pair = new ethers.Contract(process.env.TOK_PAIR, pairABI, provider);
  const feeRouter = new ethers.Contract(process.env.FEE_ROUTER, feeRouterABI, provider);
  const tok = new ethers.Contract(process.env.TOK, tokenABI, provider);
  
  // Check LP balance
  const lpBalance = await pair.balanceOf(process.env.FEE_ROUTER);
  console.log('FeeRouter LP balance:', ethers.formatEther(lpBalance));
  
  // Check pair state
  const [r0, r1] = await pair.getReserves();
  const totalSupply = await pair.totalSupply();
  const kLast = await pair.kLast();
  const currentK = r0 * r1;
  
  console.log('\nPair state:');
  console.log('Reserve0 (TOK):', ethers.formatEther(r0));
  console.log('Reserve1 (WBERA):', ethers.formatEther(r1));
  console.log('Total LP supply:', ethers.formatEther(totalSupply));
  console.log('Current K:', currentK.toString());
  console.log('K Last:', kLast.toString());
  
  // Check FeeRouter state
  const lastReserve0 = await feeRouter.lastReserve0();
  const lastReserve1 = await feeRouter.lastReserve1();
  
  console.log('\nFeeRouter state:');
  console.log('Last Reserve0:', ethers.formatEther(lastReserve0));
  console.log('Last Reserve1:', ethers.formatEther(lastReserve1));
  
  // Check token balances
  const tokBalance = await tok.balanceOf(process.env.FEE_ROUTER);
  const wberaBalance = await provider.getBalance(process.env.FEE_ROUTER);
  
  console.log('\nFeeRouter token balances:');
  console.log('TOK balance:', ethers.formatEther(tokBalance));
  console.log('WBERA balance:', ethers.formatEther(wberaBalance));
  
  // Check if FeeRouter is set on pair
  const pairFeeRouter = await pair.feeRouter();
  console.log('\nPair fee router:', pairFeeRouter);
  console.log('Expected:', process.env.FEE_ROUTER);
  console.log('Match:', pairFeeRouter.toLowerCase() === process.env.FEE_ROUTER.toLowerCase());
}

checkFeeRouterState().catch(console.error);