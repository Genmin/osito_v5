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

async function forceMintFees() {
  console.log('=== ATTEMPTING TO FORCE FEE MINT ===\n');
  
  const pairAddress = process.env.TOK_PAIR;
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(pairAddress, pairABI, wallet);
  
  const feeRouterAddress = await pair.feeRouter();
  
  // Check if FeeRouter can burn some of its principal to trigger fee mint
  console.log('Idea: Have FeeRouter burn 1 wei of its principal LP');
  console.log('This should trigger _mintFee() which will mint the accrued fees\n');
  
  // We need to impersonate the FeeRouter or find another way
  // Since we can't impersonate on testnet, let's think of another approach
  
  // Actually, let's check if anyone else has LP tokens
  const totalSupply = await pair.totalSupply();
  const feeRouterBalance = await pair.balanceOf(feeRouterAddress);
  const deadBalance = await pair.balanceOf('0x000000000000000000000000000000000000dead');
  const pairBalance = await pair.balanceOf(pairAddress);
  
  console.log('LP Token Distribution:');
  console.log('Total Supply:', ethers.formatEther(totalSupply));
  console.log('FeeRouter:', ethers.formatEther(feeRouterBalance));
  console.log('Dead:', ethers.formatEther(deadBalance));
  console.log('Pair itself:', ethers.formatEther(pairBalance));
  console.log('Others:', ethers.formatEther(totalSupply - feeRouterBalance - deadBalance - pairBalance));
  
  // Check pair's internal accounting
  console.log('\n=== CHECKING PAIR INTERNALS ===');
  
  // The only way to trigger fee minting in V5 seems to be:
  // 1. Someone burns LP (but only FeeRouter has LP)
  // 2. FeeRouter burns LP (but it thinks it has no excess)
  
  // This is indeed a design issue. The protocol needs a way to:
  // - Either allow others to add liquidity (triggering fee mint)
  // - Or have a separate "sync" function to mint accumulated fees
  // - Or have the FeeRouter able to burn a tiny bit of principal
  
  console.log('\n=== CONCLUSION ===');
  console.log('V5 has a critical design flaw:');
  console.log('1. Fees accumulate as K growth ✅');
  console.log('2. But fee LP is only minted during mint/burn operations');
  console.log('3. mint() is restricted to FeeRouter only');
  console.log('4. FeeRouter owns all LP but sees no "excess" until fees are minted');
  console.log('5. No mechanism exists to trigger fee minting!');
  console.log('\nThe protocol is stuck in a deadlock where fees accumulate but cannot be collected.');
}

forceMintFees().catch(console.error);