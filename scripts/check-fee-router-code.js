const { ethers } = require('ethers');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.join(__dirname, '..', '.env.testnet') });

const provider = new ethers.JsonRpcProvider(process.env.RPC_URL);

async function checkFeeRouterCode() {
  console.log('=== Checking FeeRouter Code ===\n');
  
  // Get deployed bytecode
  const deployedCode = await provider.getCode(process.env.FEE_ROUTER);
  console.log('FeeRouter address:', process.env.FEE_ROUTER);
  console.log('Deployed code length:', deployedCode.length);
  
  // Check for specific function selectors in the bytecode
  // collectFees() = 0xc8796572
  const collectFeesSelector = 'c8796572';
  
  if (deployedCode.includes(collectFeesSelector)) {
    console.log('✓ collectFees function found in bytecode');
    
    // Look for "INSUFFICIENT_LIQUIDITY_BURNED" error string
    // This would be in the old implementation
    const errorString = '494e53554646494349454e545f4c49515549444954595f4255524e4544'; // hex of the error
    
    if (deployedCode.includes(errorString)) {
      console.log('⚠️  WARNING: Found "INSUFFICIENT_LIQUIDITY_BURNED" error in bytecode');
      console.log('This suggests the OLD FeeRouter implementation is deployed!');
    } else {
      console.log('✓ No "INSUFFICIENT_LIQUIDITY_BURNED" error found');
      console.log('This might be the new implementation');
    }
  } else {
    console.log('✗ collectFees function NOT found in bytecode');
  }
  
  // Check if it has the burn function selector (old implementation)
  // This is a hacky way but can help identify
  const burnSelector = '42966c68'; // burn(uint256)
  if (deployedCode.includes(burnSelector)) {
    console.log('⚠️  Found burn() selector - might be calling token burn');
  }
}

checkFeeRouterCode().catch(console.error);