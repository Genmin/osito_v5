const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

async function verifyBytecode() {
  console.log('=== Verifying FeeRouter Bytecode ===\n');
  
  // Get deployed bytecode
  const deployedBytecode = await provider.getCode(process.env.FEE_ROUTER);
  console.log('Deployed bytecode length:', deployedBytecode.length);
  console.log('First 100 chars:', deployedBytecode.substring(0, 100));
  
  // Load expected bytecode
  const artifactPath = path.join(__dirname, '..', 'out', 'FeeRouter.sol', 'FeeRouter.json');
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  const expectedBytecode = artifact.deployedBytecode.object;
  
  console.log('\nExpected bytecode length:', expectedBytecode.length);
  console.log('First 100 chars:', expectedBytecode.substring(0, 100));
  
  // Simple check - deployed bytecode should contain expected bytecode
  // (deployed might have constructor args appended)
  const matches = deployedBytecode.includes(expectedBytecode.substring(2));
  console.log('\nBytecode matches:', matches);
  
  if (!matches) {
    console.log('\n⚠️  WARNING: Deployed bytecode does not match expected!');
    console.log('The contract at', process.env.FEE_ROUTER, 'may be outdated');
  }
}

verifyBytecode().catch(console.error);