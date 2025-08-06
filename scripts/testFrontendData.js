const { ethers } = require("ethers");

// LensLite contract
const LENS_LITE = "0xADfd8BC5Bcb4a202Ad5e8Cc6cfff1f93D79410D6";
const RPC_URL = "https://palpable-icy-valley.bera-bepolia.quiknode.pro/b2800b4de9d7290d7750adfc75463992a80dfabb/";

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

// Simulate frontend calculation
function calculateCoreMetrics({ T, Q, B, totalSupply, pMin, spotPrice, beraUsdPrice }) {
  const price = Number(spotPrice) / 1e18;
  const floor = Number(pMin) / 1e18;
  const maxLev = floor > 0 && price > 0 ? price / floor : 1;
  
  const priceUsd = price * beraUsdPrice;
  const floorUsd = floor * beraUsdPrice;
  
  const totalSupplyFormatted = Number(totalSupply) / 1e18;
  const marketCapBera = price * totalSupplyFormatted;
  const marketCapUsd = priceUsd * totalSupplyFormatted;
  
  return {
    price,
    floor,
    maxLev,
    priceUsd,
    floorUsd,
    marketCapBera,
    marketCapUsd,
    totalSupply
  };
}

function formatScientific(num) {
  if (!isFinite(num) || isNaN(num)) return "0";
  if (num === 0) return "0";
  
  // For large numbers (>= 10000), use compact notation
  if (Math.abs(num) >= 10000) {
    if (num >= 1000000) return `${(num / 1000000).toFixed(1)}M`;
    if (num >= 1000) return `${(num / 1000).toFixed(1)}k`;
    return num.toFixed(0);
  }
  
  // For numbers between 0.01 and 10000, use regular formatting
  if (Math.abs(num) >= 0.01) {
    return num.toFixed(2);
  }
  
  // For very small numbers, use scientific notation
  const exponent = Math.floor(Math.log10(Math.abs(num)));
  const mantissa = num / Math.pow(10, exponent);
  return `${mantissa.toFixed(2)}e${exponent}`;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const lensLite = new ethers.Contract(LENS_LITE, LENS_LITE_ABI, provider);
  
  console.log("SIMULATING FRONTEND MARKET CAP CALCULATION");
  console.log("=".repeat(60));
  
  const markets = await lensLite.markets(0, 50);
  const beraUsdPrice = 0.05; // Assume $0.05 for testnet
  
  for (const market of markets) {
    if (market.symbol === 'FROB' || market.symbol === 'CHOP') {
      console.log(`\n${market.symbol} TOKEN:`);
      console.log("-".repeat(40));
      
      // Raw data
      console.log("Raw Data from LensLite:");
      console.log(`  spotPrice: ${market.spotPrice.toString()}`);
      console.log(`  pMin: ${market.pMin.toString()}`);
      console.log(`  totalSupply: ${market.totalSupply.toString()}`);
      console.log(`  T: ${market.T.toString()}`);
      console.log(`  Q: ${market.Q.toString()}`);
      
      // Calculate metrics like frontend does
      const coreMetrics = calculateCoreMetrics({
        T: market.T,
        Q: market.Q,
        B: market.B,
        totalSupply: market.totalSupply,
        pMin: market.pMin,
        spotPrice: market.spotPrice,
        beraUsdPrice
      });
      
      console.log("\nCalculated Core Metrics:");
      console.log(`  price (decimal): ${coreMetrics.price}`);
      console.log(`  floor (decimal): ${coreMetrics.floor}`);
      console.log(`  marketCapBera: ${coreMetrics.marketCapBera}`);
      console.log(`  marketCapUsd: ${coreMetrics.marketCapUsd}`);
      
      console.log("\nWhat Frontend Shows:");
      console.log(`  Market Cap: $${formatScientific(coreMetrics.marketCapUsd)}`);
      console.log(`  Floor: $${formatScientific(coreMetrics.floorUsd)}`);
      console.log(`  Price: $${formatScientific(coreMetrics.priceUsd)}`);
      
      // Calculate with wrong pMin (what's actually happening)
      const wrongFloor = coreMetrics.floor;
      if (wrongFloor > 1000) {
        console.log("\n⚠️  PROBLEM DETECTED:");
        console.log(`  Floor price is ${wrongFloor.toExponential(2)} - way too high!`);
        console.log(`  This would show as: $${formatScientific(wrongFloor * beraUsdPrice)}`);
      }
    }
  }
}

main().catch(console.error);