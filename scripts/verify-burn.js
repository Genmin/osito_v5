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

async function verifyBurn() {
  const txHash = '0xdde766a6374128c2bb560f43e519869f587471a7eb73e53e8159ec3e5f9d1d70';
  const receipt = await provider.getTransactionReceipt(txHash);
  
  console.log('Fee Collection Transaction:', txHash);
  console.log('Block:', receipt.blockNumber);
  console.log('Status:', receipt.status === 1 ? 'SUCCESS' : 'FAILED');
  console.log('Gas Used:', receipt.gasUsed.toString());
  
  // Parse logs
  const FEE_ROUTER_ABI = loadABI('FeeRouter');
  const TOK_ABI = loadABI('OsitoToken');
  const PAIR_ABI = loadABI('OsitoPair');
  
  const feeRouterInterface = new ethers.Interface(FEE_ROUTER_ABI);
  const tokInterface = new ethers.Interface(TOK_ABI);
  const pairInterface = new ethers.Interface(PAIR_ABI);
  
  console.log('\n=== TRANSACTION LOGS ===');
  let burnFound = false;
  let feesCollected = false;
  
  for (const log of receipt.logs) {
    console.log('\nLog from:', log.address);
    
    // Try to parse as FeeRouter event
    try {
      const parsed = feeRouterInterface.parseLog(log);
      if (parsed && parsed.name === 'FeesCollected') {
        console.log('✅ FeesCollected Event Found!');
        console.log('  TOK burned:', ethers.formatEther(parsed.args[0]), 'TOK');
        console.log('  QT collected:', ethers.formatEther(parsed.args[1]), 'WBERA');
        feesCollected = true;
      }
    } catch (e) {}
    
    // Try to parse as Transfer/Burn event
    try {
      const parsed = tokInterface.parseLog(log);
      if (parsed && parsed.name === 'Transfer') {
        if (parsed.args.to === '0x0000000000000000000000000000000000000000') {
          console.log('🔥 BURN Event Found!');
          console.log('  From:', parsed.args.from);
          console.log('  Amount:', ethers.formatEther(parsed.args.amount), 'TOK');
          burnFound = true;
        }
      }
    } catch (e) {}
    
    // Try to parse as Pair event
    try {
      const parsed = pairInterface.parseLog(log);
      if (parsed) {
        console.log('Pair Event:', parsed.name);
        if (parsed.name === 'Mint' || parsed.name === 'Burn' || parsed.name === 'Sync') {
          console.log('  Args:', parsed.args);
        }
      }
    } catch (e) {}
  }
  
  if (!feesCollected) {
    console.log('\n❌ No FeesCollected event found');
  }
  if (!burnFound) {
    console.log('❌ No burn event found');
  }
  
  // Check token supply
  const tokAddress = '0xEF059a38E7566285aC2577824ABcd9Ba64080899';
  const tok = new ethers.Contract(tokAddress, TOK_ABI, provider);
  
  const currentSupply = await tok.totalSupply();
  console.log('\n=== TOKEN SUPPLY ===');
  console.log('Current TOK Supply:', ethers.formatEther(currentSupply), 'TOK');
  
  // Check if supply decreased from initial
  const pairAddress = process.env.TOK_PAIR;
  const pair = new ethers.Contract(pairAddress, PAIR_ABI, provider);
  const initialSupply = await pair.initialSupply();
  
  console.log('Initial TOK Supply:', ethers.formatEther(initialSupply), 'TOK');
  console.log('Burned Amount:', ethers.formatEther(initialSupply - currentSupply), 'TOK');
  
  // Check current state
  const [r0, r1] = await pair.getReserves();
  const currentK = r0 * r1;
  const kLast = await pair.kLast();
  
  console.log('\n=== PAIR STATE ===');
  console.log('Reserve0 (TOK):', ethers.formatEther(r0));
  console.log('Reserve1 (WBERA):', ethers.formatEther(r1));
  console.log('Current K:', currentK.toString());
  console.log('kLast:', kLast.toString());
  console.log('K matches?:', currentK.toString() === kLast.toString() ? 'YES ✅' : 'NO ❌');
  
  // Check FeeRouter LP balance
  const feeRouterAddress = await pair.feeRouter();
  const lpBalance = await pair.balanceOf(feeRouterAddress);
  const principalLp = await provider.call({
    to: feeRouterAddress,
    data: '0x' + ethers.id('principalLp()').slice(2, 10)
  });
  
  console.log('\n=== FEE ROUTER STATE ===');
  console.log('FeeRouter:', feeRouterAddress);
  console.log('LP Balance:', ethers.formatEther(lpBalance));
  const principalLpBigInt = BigInt(principalLp);
  console.log('Principal LP:', ethers.formatEther(principalLpBigInt));
  console.log('Excess LP:', ethers.formatEther(lpBalance - principalLpBigInt));
}

verifyBurn().catch(console.error);