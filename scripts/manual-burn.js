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

async function manualBurn() {
  // First, let me add some liquidity as a different user to trigger fee mint
  const pairAddress = process.env.TOK_PAIR;
  const tokAddress = '0xEF059a38E7566285aC2577824ABcd9Ba64080899';
  const wberaAddress = '0x6969696969696969696969696969696969696969';
  
  const pairABI = loadABI('OsitoPair');
  const tokABI = loadABI('OsitoToken');
  const pair = new ethers.Contract(pairAddress, pairABI, wallet);
  const tok = new ethers.Contract(tokAddress, tokABI, wallet);
  
  // Buy some TOK first via SwapRouter
  const swapRouterABI = loadABI('SwapRouter');
  const swapRouter = new ethers.Contract(process.env.SWAP_ROUTER, swapRouterABI, wallet);
  
  console.log('Buying TOK to add liquidity...');
  let tx = await swapRouter.swapExactETHForTokens(
    pairAddress,
    0, // minAmountOut
    wallet.address,
    Math.floor(Date.now() / 1000) + 300,
    { value: ethers.parseEther('0.1') }
  );
  await tx.wait();
  console.log('Bought TOK');
  
  // Now add liquidity
  const tokBalance = await tok.balanceOf(wallet.address);
  console.log('TOK balance:', ethers.formatEther(tokBalance));
  
  // Get reserves to calculate proportional amounts
  const [r0, r1] = await pair.getReserves();
  const tokAmount = tokBalance / 2n; // Use half our TOK
  const wberaAmount = (tokAmount * r1) / r0;
  
  console.log('\nAdding liquidity:');
  console.log('TOK:', ethers.formatEther(tokAmount));
  console.log('WBERA:', ethers.formatEther(wberaAmount));
  
  // Wrap BERA
  const wberaABI = [
    { inputs: [], name: "deposit", outputs: [], type: "function", payable: true },
    { inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], name: "transfer", outputs: [{ name: "", type: "bool" }], type: "function" }
  ];
  const wbera = new ethers.Contract(wberaAddress, wberaABI, wallet);
  
  tx = await wbera.deposit({ value: wberaAmount });
  await tx.wait();
  
  // Transfer to pair
  tx = await tok.transfer(pairAddress, tokAmount);
  await tx.wait();
  
  tx = await wbera.transfer(pairAddress, wberaAmount);
  await tx.wait();
  
  // Check FeeRouter balance before mint
  const feeRouterAddress = await pair.feeRouter();
  const lpBefore = await pair.balanceOf(feeRouterAddress);
  console.log('\nFeeRouter LP before mint:', ethers.formatEther(lpBefore));
  
  // THIS is the key - we need to mint to someone OTHER than FeeRouter
  // to trigger fee minting TO the FeeRouter
  console.log('\nCalling mint (this should trigger fee mint to FeeRouter)...');
  
  // Since mint is restricted to FeeRouter, we need to use OsitoLaunchpad
  // Actually, let's just try to understand the error first
  try {
    tx = await pair.mint(wallet.address);
    await tx.wait();
  } catch (e) {
    console.log('Expected error - mint restricted to FeeRouter');
    console.log('Error:', e.reason || e.message);
  }
  
  // The key insight: In V5, ONLY the FeeRouter can receive LP tokens from mint
  // This means regular users can't add liquidity after launch!
  // The initial liquidity is locked in the FeeRouter
  
  console.log('\nV5 Design insight:');
  console.log('- Initial liquidity is minted to FeeRouter');
  console.log('- No one else can add liquidity (mint restricted)');  
  console.log('- Fees accumulate as K growth');
  console.log('- When FeeRouter burns LP, fees are realized');
  
  // So the solution is: FeeRouter needs to burn some LP to realize fees
  // But it can only burn excess LP (above principal)
  // And fees haven't been minted as LP yet...
  
  // This is a chicken-and-egg problem!
}

manualBurn().catch(console.error);