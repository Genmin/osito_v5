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

async function checkFeeCollection() {
  const txHash = '0xb1e3a8e38a39387439da15ccf0b45bced7efab653507ddb0a4de1714921c0928';
  const receipt = await provider.getTransactionReceipt(txHash);
  
  console.log('Fee Collection Transaction:', txHash);
  console.log('Block:', receipt.blockNumber);
  console.log('Gas Used:', receipt.gasUsed.toString());
  console.log('\nLogs:');
  
  const FEE_ROUTER_ABI = loadABI('FeeRouter');
  const feeRouterInterface = new ethers.Interface(FEE_ROUTER_ABI);
  
  for (const log of receipt.logs) {
    console.log('\nLog from:', log.address);
    console.log('Topics:', log.topics);
    console.log('Data:', log.data);
    
    try {
      const parsed = feeRouterInterface.parseLog(log);
      if (parsed) {
        console.log('Parsed Event:', parsed.name);
        console.log('Args:', parsed.args);
      }
    } catch (e) {
      // Not a FeeRouter event
    }
  }
  
  // Check token supply
  const tokAddress = '0xEF059a38E7566285aC2577824ABcd9Ba64080899';
  const tokABI = loadABI('OsitoToken');
  const tok = new ethers.Contract(tokAddress, tokABI, provider);
  
  const totalSupply = await tok.totalSupply();
  console.log('\n\nTOK Total Supply:', ethers.formatEther(totalSupply), 'TOK');
  
  // Check fee router balance
  const pairAddress = '0x8f596aABc36863E82f0C61456b0f311E16e2e9a6';
  const pairABI = loadABI('OsitoPair');
  const pair = new ethers.Contract(pairAddress, pairABI, provider);
  
  const feeRouterAddress = await pair.feeRouter();
  console.log('FeeRouter address:', feeRouterAddress);
  
  // Check current K and kLast
  const [r0, r1] = await pair.getReserves();
  const currentK = r0 * r1;
  const kLast = await pair.kLast();
  
  console.log('\nPair State:');
  console.log('Reserve0 (TOK):', ethers.formatEther(r0));
  console.log('Reserve1 (WBERA):', ethers.formatEther(r1));
  console.log('Current K:', currentK.toString());
  console.log('kLast:', kLast.toString());
}

checkFeeCollection().catch(console.error);