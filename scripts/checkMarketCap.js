const { ethers } = require("ethers");

// Configuration
const RPC_URL = "https://palpable-icy-valley.bera-bepolia.quiknode.pro/b2800b4de9d7290d7750adfc75463992a80dfabb/";
const LENS_LITE = "0xADfd8BC5Bcb4a202Ad5e8Cc6cfff1f93D79410D6";

// Token addresses from user
const TOKEN_1 = "0x3a369629DbFBF6E8f3201F5489696486b752bF7e";
const TOKEN_2 = "0x0F9065E9F71d6e86305a4815b3397829AEAa52C9";

// ABI fragments - Match actual LensLite struct order
const LENS_LITE_ABI = [
  {
    "inputs": [{"name": "from", "type": "uint256"}, {"name": "count", "type": "uint256"}],
    "name": "markets",
    "outputs": [{
      "components": [
        {"name": "core", "type": "address"},
        {"name": "token", "type": "address"},
        {"name": "T", "type": "uint128"},
        {"name": "Q", "type": "uint128"},
        {"name": "B", "type": "uint128"},
        {"name": "pMin", "type": "uint256"},
        {"name": "feeBp", "type": "uint256"},
        {"name": "spotPrice", "type": "uint256"},
        {"name": "tvl", "type": "uint256"},
        {"name": "utilization", "type": "uint256"},
        {"name": "apy", "type": "uint256"},
        {"name": "totalSupply", "type": "uint256"},
        {"name": "totalSupplyImmutable", "type": "uint256"},
        {"name": "name", "type": "string"},
        {"name": "symbol", "type": "string"},
        {"name": "metadataURI", "type": "string"}
      ],
      "name": "out",
      "type": "tuple[]"
    }],
    "stateMutability": "view",
    "type": "function"
  }
];

const ERC20_ABI = [
  "function totalSupply() view returns (uint256)",
  "function symbol() view returns (string)",
  "function name() view returns (string)"
];

const PAIR_ABI = [
  "function getReserves() view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast)",
  "function token0() view returns (address)",
  "function token1() view returns (address)",
  "function tokIsToken0() view returns (bool)",
  "function pMin() view returns (uint256)"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  
  console.log("Checking market data from LensLite...\n");
  
  // Get all markets from LensLite
  const lensLite = new ethers.Contract(LENS_LITE, LENS_LITE_ABI, provider);
  const markets = await lensLite.markets(0, 50);
  
  console.log(`Total markets found: ${markets.length}\n`);
  
  // Find our specific tokens
  for (const market of markets) {
    if (market.token.toLowerCase() === TOKEN_1.toLowerCase() || 
        market.token.toLowerCase() === TOKEN_2.toLowerCase()) {
      
      console.log("=".repeat(60));
      console.log(`Token: ${market.symbol} (${market.token})`);
      console.log(`Pair: ${market.core}`);
      console.log("-".repeat(60));
      
      // Raw data from LensLite
      console.log("Raw LensLite Data:");
      console.log(`  T (TOK reserves): ${market.T.toString()}`);
      console.log(`  Q (QT reserves): ${market.Q.toString()}`);
      console.log(`  Total Supply: ${market.totalSupply.toString()}`);
      console.log(`  Initial Supply: ${market.totalSupplyImmutable.toString()}`);
      console.log(`  Burned (B): ${market.B.toString()}`);
      console.log(`  Spot Price (wei): ${market.spotPrice.toString()}`);
      console.log(`  pMin (wei): ${market.pMin.toString()}`);
      
      // Calculate human-readable values
      const spotPriceDecimal = Number(market.spotPrice) / 1e18;
      const pMinDecimal = Number(market.pMin) / 1e18;
      const totalSupplyDecimal = Number(market.totalSupply) / 1e18;
      const tokReservesDecimal = Number(market.T) / 1e18;
      const qtReservesDecimal = Number(market.Q) / 1e18;
      
      console.log("\nCalculated Values:");
      console.log(`  Spot Price: ${spotPriceDecimal.toFixed(18)} QT per TOK`);
      console.log(`  pMin (Floor): ${pMinDecimal.toFixed(18)} QT per TOK`);
      console.log(`  Total Supply: ${totalSupplyDecimal.toLocaleString()} tokens`);
      console.log(`  TOK in Pool: ${tokReservesDecimal.toLocaleString()} (${(tokReservesDecimal/totalSupplyDecimal*100).toFixed(2)}% of supply)`);
      console.log(`  QT in Pool: ${qtReservesDecimal.toFixed(6)} WBERA`);
      
      // Market cap calculation (assuming BERA = $0.05 for testnet)
      const beraPrice = 0.05; // USD per BERA
      const marketCapBera = spotPriceDecimal * totalSupplyDecimal;
      const marketCapUsd = marketCapBera * beraPrice;
      
      console.log("\nMarket Cap:");
      console.log(`  In BERA: ${marketCapBera.toFixed(6)} BERA`);
      console.log(`  In USD: $${marketCapUsd.toFixed(2)}`);
      
      // Verify pair data directly
      console.log("\nDirect Pair Verification:");
      const pair = new ethers.Contract(market.core, PAIR_ABI, provider);
      const [r0, r1] = await pair.getReserves();
      const tokIsToken0 = await pair.tokIsToken0();
      
      console.log(`  Reserve0: ${r0.toString()}`);
      console.log(`  Reserve1: ${r1.toString()}`);
      console.log(`  tokIsToken0: ${tokIsToken0}`);
      
      const actualTokReserves = tokIsToken0 ? r0 : r1;
      const actualQtReserves = tokIsToken0 ? r1 : r0;
      const actualSpotPrice = Number(actualQtReserves) * 1e18 / Number(actualTokReserves);
      
      console.log(`  Actual TOK reserves: ${actualTokReserves.toString()}`);
      console.log(`  Actual QT reserves: ${actualQtReserves.toString()}`);
      console.log(`  Actual Spot Price: ${(actualSpotPrice/1e18).toFixed(18)}`);
      
      // Check token directly
      const token = new ethers.Contract(market.token, ERC20_ABI, provider);
      const directTotalSupply = await token.totalSupply();
      console.log(`  Direct Total Supply: ${directTotalSupply.toString()}`);
      
      console.log("=".repeat(60));
      console.log();
    }
  }
  
  // Check if tokens exist in markets
  const token1Found = markets.some(m => m.token.toLowerCase() === TOKEN_1.toLowerCase());
  const token2Found = markets.some(m => m.token.toLowerCase() === TOKEN_2.toLowerCase());
  
  if (!token1Found) {
    console.log(`⚠️  Token ${TOKEN_1} not found in LensLite markets`);
  }
  if (!token2Found) {
    console.log(`⚠️  Token ${TOKEN_2} not found in LensLite markets`);
  }
}

main().catch(console.error);