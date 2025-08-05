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

async function launchTestToken() {
  console.log('=== Launching Test Token on Fresh V5 ===\n');
  
  const launchpadABI = loadABI('OsitoLaunchpad');
  const launchpad = new ethers.Contract(process.env.OSITO_LAUNCHPAD, launchpadABI, wallet);
  
  // Parameters for test token
  const name = "Test Token V5";
  const symbol = "TESTV5";
  const supply = ethers.parseEther('1000000000'); // 1B tokens
  const metadataURI = "https://ipfs.io/metadata/test"; // metadata URI
  const wethAmount = ethers.parseEther('1'); // 1 WBERA initial liquidity
  
  console.log('Token Parameters:');
  console.log('Name:', name);
  console.log('Symbol:', symbol);
  console.log('Supply:', ethers.formatEther(supply));
  console.log('Initial WBERA:', ethers.formatEther(wethAmount));
  
  // Approve WBERA spending
  const wberaABI = ['function approve(address,uint256) returns (bool)'];
  const wbera = new ethers.Contract(process.env.WBERA_ADDRESS, wberaABI, wallet);
  
  console.log('\nApproving WBERA...');
  let tx = await wbera.approve(process.env.OSITO_LAUNCHPAD, wethAmount);
  await tx.wait();
  
  // Launch token with fee parameters
  const startFeeBps = 100; // 1% start fee
  const endFeeBps = 30;    // 0.3% end fee
  const feeDecayTarget = ethers.parseEther('100000000'); // 100M volume target
  
  console.log('Launching token...');
  tx = await launchpad.launchToken(name, symbol, supply, metadataURI, wethAmount, startFeeBps, endFeeBps, feeDecayTarget);
  const receipt = await tx.wait();
  console.log('Transaction:', tx.hash);
  console.log('Block:', receipt.blockNumber);
  
  // Parse events to get addresses
  const event = receipt.logs.find(log => {
    try {
      const parsed = launchpad.interface.parseLog(log);
      return parsed && parsed.name === 'TokenLaunched';
    } catch (e) {
      return false;
    }
  });
  
  if (event) {
    const parsed = launchpad.interface.parseLog(event);
    const [token, pair, feeRouter] = parsed.args;
    
    console.log('\n✅ Token Launched Successfully!');
    console.log('Token:', token);
    console.log('Pair:', pair);
    console.log('FeeRouter:', feeRouter);
    
    // Update env with new addresses
    console.log('\nAdding to .env.testnet...');
    fs.appendFileSync('.env.testnet', `\n# Test Token (Fresh V5 with FeeRouter Fix)\nTOK=${token}\nTOK_PAIR=${pair}\nFEE_ROUTER=${feeRouter}\n`);
    
    // Add pair to LensLite
    const lensLiteABI = loadABI('LensLite');
    const lensLite = new ethers.Contract(process.env.LENS_LITE, lensLiteABI, wallet);
    
    console.log('\nAdding pair to LensLite...');
    tx = await lensLite.addPair(pair);
    await tx.wait();
    console.log('✅ Pair added to LensLite');
    
    console.log('\n=== Ready for Testing ===');
    console.log('1. Do some trades to create K growth');
    console.log('2. Run keeper to test fee collection');
    console.log('3. Verify TOK burning and treasury QT collection');
  }
}

launchTestToken().catch(console.error);