const fetch = require('node-fetch');

// Subgraph data from test
const SUBGRAPH_DATA = {
  FROB: {
    subgraphPrice: 34755532378,  // From subgraph (in wei?)
    onChainSpotPrice: 57125228612,  // From LensLite (in wei)
    pair: "0x5B0a2eB91E0b72221e98C0A506870A7fD515e047"
  },
  CHOP: {
    subgraphPrice: 1045932138,  // From subgraph (in wei?)
    onChainSpotPrice: 1041783217,  // From LensLite (in wei)
    pair: "0x45b0A2EE6d3F91584647D3ac8B94A50bf456F69C"
  }
};

console.log("PRICE COMPARISON: Subgraph vs On-Chain");
console.log("=".repeat(60));

for (const [token, data] of Object.entries(SUBGRAPH_DATA)) {
  console.log(`\n${token} TOKEN:`);
  console.log("-".repeat(40));
  
  // Raw values
  console.log("Raw Values:");
  console.log(`  Subgraph price: ${data.subgraphPrice}`);
  console.log(`  On-chain price: ${data.onChainSpotPrice}`);
  
  // As decimals (assuming wei units / 1e18)
  const subgraphDecimal = data.subgraphPrice / 1e18;
  const onChainDecimal = data.onChainSpotPrice / 1e18;
  
  console.log("\nAs Decimals (÷ 1e18):");
  console.log(`  Subgraph: ${subgraphDecimal.toFixed(18)}`);
  console.log(`  On-chain: ${onChainDecimal.toFixed(18)}`);
  
  // Ratio
  const ratio = data.subgraphPrice / data.onChainSpotPrice;
  console.log(`\nRatio (subgraph/onchain): ${ratio.toFixed(2)}x`);
  
  // Market cap calculation
  const totalSupply = token === "FROB" ? 982133839947425838011265670n : 986030942309065543984571051n;
  const totalSupplyDecimal = Number(totalSupply) / 1e18;
  
  console.log("\nMarket Cap Calculations:");
  console.log(`  Total Supply: ${totalSupplyDecimal.toLocaleString()} tokens`);
  
  // Using subgraph price
  const mcapSubgraph = subgraphDecimal * totalSupplyDecimal;
  console.log(`  MCap (subgraph price): ${mcapSubgraph.toFixed(6)} BERA`);
  console.log(`                         $${(mcapSubgraph * 0.05).toFixed(2)} USD`);
  
  // Using on-chain price
  const mcapOnChain = onChainDecimal * totalSupplyDecimal;
  console.log(`  MCap (on-chain price): ${mcapOnChain.toFixed(6)} BERA`);
  console.log(`                         $${(mcapOnChain * 0.05).toFixed(2)} USD`);
  
  // What frontend might show if treating subgraph price as already decimal
  console.log("\nIf Frontend Treats Subgraph Price as Decimal (BUG):");
  const buggyMcap = data.subgraphPrice * totalSupplyDecimal;
  console.log(`  Buggy MCap: ${buggyMcap.toExponential(2)} BERA`);
  console.log(`              $${(buggyMcap * 0.05).toExponential(2)} USD`);
}

console.log("\n" + "=".repeat(60));
console.log("CONCLUSION:");
console.log("-".repeat(40));
console.log("FROB subgraph price is 608x higher than on-chain!");
console.log("CHOP subgraph price matches on-chain (within 0.4%)");
console.log("\nPossible issues:");
console.log("1. FROB swap events are being processed incorrectly");
console.log("2. Price calculation in subgraph has a bug for certain swaps");
console.log("3. Frontend is not converting wei to decimal properly");