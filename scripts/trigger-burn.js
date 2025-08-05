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

async function triggerFeeMintViaBurn() {
  const pairAddress = process.env.TOK_PAIR;
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(pairAddress, pairABI, wallet);
  
  // Check our LP balance
  const lpBalance = await pair.balanceOf(wallet.address);
  console.log('Our LP balance:', ethers.formatEther(lpBalance));
  
  if (lpBalance === 0n) {
    console.log('No LP tokens to burn');
    return;
  }
  
  // Check FeeRouter balance before
  const feeRouterAddress = await pair.feeRouter();
  const feeRouterLPBefore = await pair.balanceOf(feeRouterAddress);
  console.log('\nFeeRouter LP before:', ethers.formatEther(feeRouterLPBefore));
  
  // Transfer 1 wei of LP to pair and burn it
  const burnAmount = 1n; // Just 1 wei to trigger fee mint
  console.log('\nBurning', burnAmount.toString(), 'wei of LP to trigger fee mint...');
  
  // Transfer LP to pair
  let tx = await pair.transfer(pairAddress, burnAmount);
  await tx.wait();
  console.log('Transferred LP to pair');
  
  // Burn to trigger fee mint
  tx = await pair.burn(wallet.address);
  const receipt = await tx.wait();
  console.log('Burn tx:', tx.hash);
  
  // Check FeeRouter balance after
  const feeRouterLPAfter = await pair.balanceOf(feeRouterAddress);
  console.log('\nFeeRouter LP after:', ethers.formatEther(feeRouterLPAfter));
  
  const feeLPMinted = feeRouterLPAfter - feeRouterLPBefore;
  console.log('Fee LP minted to FeeRouter:', ethers.formatEther(feeLPMinted));
  
  // Check kLast update
  const [r0, r1] = await pair.getReserves();
  const currentK = r0 * r1;
  const kLast = await pair.kLast();
  
  console.log('\nPair state after burn:');
  console.log('Current K:', currentK.toString());
  console.log('kLast:', kLast.toString());
  console.log('K updated?:', currentK.toString() === kLast.toString() ? 'YES ✅' : 'NO ❌');
}

triggerFeeMintViaBurn().catch(console.error);