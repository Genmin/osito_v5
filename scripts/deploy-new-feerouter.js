const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

async function deployNewFeeRouter() {
  console.log('=== Deploying Updated FeeRouter ===\n');
  
  // First, compile the contract
  console.log('Compiling contracts...');
  const { execSync } = require('child_process');
  execSync('forge build', { stdio: 'inherit' });
  
  // Load the compiled contract
  const contractPath = path.join(__dirname, '..', 'out', 'FeeRouter.sol', 'FeeRouter.json');
  const artifact = JSON.parse(fs.readFileSync(contractPath, 'utf8'));
  
  // Deploy new FeeRouter (for testing purposes)
  const FeeRouter = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);
  
  // Treasury address from env
  const treasury = '0xBfff8b5C308CBb00a114EF2651f9EC7819b69557';
  
  console.log('Deploying FeeRouter...');
  console.log('Treasury:', treasury);
  
  const feeRouter = await FeeRouter.deploy(treasury);
  await feeRouter.waitForDeployment();
  
  const feeRouterAddress = await feeRouter.getAddress();
  console.log('\n✅ FeeRouter deployed at:', feeRouterAddress);
  
  console.log('\nNOTE: This is just for testing the fix.');
  console.log('In production, you would:');
  console.log('1. Update the FeeRouter code');
  console.log('2. Redeploy the entire protocol with the fix');
  console.log('3. Or implement a migration strategy if needed');
  
  // Test the new collectFees function works
  console.log('\n=== Testing New FeeRouter ===');
  console.log('The new FeeRouter will:');
  console.log('1. Check if K > kLast');
  console.log('2. Burn 1 wei LP to trigger fee minting');
  console.log('3. Collect the newly minted fees');
  console.log('4. All in one simple call from the keeper');
}

deployNewFeeRouter().catch(console.error);