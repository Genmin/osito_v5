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

async function triggerFeeMint() {
  const pairAddress = process.env.TOK_PAIR;
  const tokAddress = '0xEF059a38E7566285aC2577824ABcd9Ba64080899';
  const wberaAddress = '0x6969696969696969696969696969696969696969';
  
  // Load contracts
  const tokABI = loadABI('OsitoToken');
  const wberaABI = [
    {
      "constant": false,
      "inputs": [],
      "name": "deposit",
      "outputs": [],
      "payable": true,
      "type": "function"
    },
    {
      "constant": false,
      "inputs": [
        {"name": "to", "type": "address"},
        {"name": "amount", "type": "uint256"}
      ],
      "name": "transfer",
      "outputs": [{"name": "", "type": "bool"}],
      "type": "function"
    }
  ];
  const pairABI = loadABI('OsitoPair');
  
  const tok = new ethers.Contract(tokAddress, tokABI, wallet);
  const wbera = new ethers.Contract(wberaAddress, wberaABI, wallet);
  const pair = new ethers.Contract(pairAddress, pairABI, wallet);
  
  // Get current reserves to calculate amounts
  const [r0, r1] = await pair.getReserves();
  console.log('Current reserves:');
  console.log('TOK:', ethers.formatEther(r0));
  console.log('WBERA:', ethers.formatEther(r1));
  
  // Add tiny amount of liquidity to trigger fee mint
  const tokAmount = ethers.parseEther('0.001'); // 0.001 TOK
  const wberaAmount = tokAmount * r1 / r0; // Proportional WBERA
  
  console.log('\nAdding liquidity to trigger fee mint:');
  console.log('TOK amount:', ethers.formatEther(tokAmount));
  console.log('WBERA amount:', ethers.formatEther(wberaAmount));
  
  // Wrap BERA
  console.log('\nWrapping BERA...');
  let tx = await wbera.deposit({ value: wberaAmount });
  await tx.wait();
  
  // Transfer tokens to pair
  console.log('Transferring tokens to pair...');
  tx = await tok.transfer(pairAddress, tokAmount);
  await tx.wait();
  
  tx = await wbera.transfer(pairAddress, wberaAmount);
  await tx.wait();
  
  // Check FeeRouter balance before mint
  const feeRouterAddress = await pair.feeRouter();
  const lpBalanceBefore = await pair.balanceOf(feeRouterAddress);
  console.log('\nFeeRouter LP balance before mint:', ethers.formatEther(lpBalanceBefore));
  
  // Mint to trigger fee collection
  console.log('\nCalling mint to trigger fee collection...');
  tx = await pair.mint(wallet.address);
  const receipt = await tx.wait();
  console.log('Mint transaction:', tx.hash);
  
  // Check if fees were minted
  const lpBalanceAfter = await pair.balanceOf(feeRouterAddress);
  console.log('FeeRouter LP balance after mint:', ethers.formatEther(lpBalanceAfter));
  
  const feeLPMinted = lpBalanceAfter - lpBalanceBefore;
  console.log('Fee LP tokens minted:', ethers.formatEther(feeLPMinted));
  
  // Update kLast
  const kLast = await pair.kLast();
  console.log('\nNew kLast:', kLast.toString());
}

triggerFeeMint().catch(console.error);