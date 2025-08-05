const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);
const wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);

async function deployFreshRobust() {
  console.log('=== Deploying Fresh Token with Robust FeeRouter ===\n');
  
  const deployOutput = fs.readFileSync(
    path.join(__dirname, '..', 'broadcast/DeployFreshV5.s.sol/80069/run-latest.json'),
    'utf8'
  );
  
  const deployment = JSON.parse(deployOutput);
  
  console.log('Fresh deployment addresses:');
  console.log('TOK:', deployment.returns['0'].value);
  console.log('Pair:', deployment.returns['1'].value);
  console.log('FeeRouter:', deployment.returns['2'].value);
  
  // Update .env.testnet with new addresses
  const envPath = path.join(__dirname, '..', '.env.testnet');
  let envContent = fs.readFileSync(envPath, 'utf8');
  
  envContent = envContent.replace(/TOK=.*/g, `TOK=${deployment.returns['0'].value}`);
  envContent = envContent.replace(/TOK_PAIR=.*/g, `TOK_PAIR=${deployment.returns['1'].value}`);
  envContent = envContent.replace(/FEE_ROUTER=.*/g, `FEE_ROUTER=${deployment.returns['2'].value}`);
  
  fs.writeFileSync(envPath, envContent);
  console.log('\n✅ Updated .env.testnet with fresh addresses');
}

deployFreshRobust().catch(console.error);