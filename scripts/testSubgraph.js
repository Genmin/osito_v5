const fetch = require('node-fetch');

const SUBGRAPH_URL = 'https://api.goldsky.com/api/public/project_cmdt3hzm9tc4201z12e277v83/subgraphs/osito-v5-charts/v2/gn';

// Token addresses
const FROB_TOKEN = "0x3a369629DbFBF6E8f3201F5489696486b752bF7e";
const FROB_PAIR = "0x5B0a2eB91E0b72221e98C0A506870A7fD515e047";

const CHOP_TOKEN = "0x0F9065E9F71d6e86305a4815b3397829AEAa52C9";
const CHOP_PAIR = "0x45b0A2EE6d3F91584647D3ac8B94A50bf456F69C";

async function querySubgraph(query) {
  const response = await fetch(SUBGRAPH_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query })
  });
  return response.json();
}

async function testCandles(pairId) {
  const query = `
    query {
      candles(
        first: 10, 
        orderBy: timestamp, 
        orderDirection: desc,
        where: { pair: "${pairId.toLowerCase()}" }
      ) {
        timestamp
        open
        high
        low
        close
        volume
        swapCount
        pair {
          id
          token0Symbol
          token1Symbol
          lastPrice
        }
      }
    }
  `;
  
  return querySubgraph(query);
}

async function testPairs() {
  const query = `
    query {
      ositoPairs(first: 10) {
        id
        token0
        token1
        token0Symbol
        token1Symbol
        lastPrice
        swapCount
        createdAtTimestamp
      }
    }
  `;
  
  return querySubgraph(query);
}

async function testSwaps(pairId) {
  const query = `
    query {
      swaps(
        first: 10, 
        orderBy: timestamp, 
        orderDirection: desc,
        where: { pair: "${pairId.toLowerCase()}" }
      ) {
        id
        timestamp
        amount0In
        amount1In
        amount0Out
        amount1Out
        price
        volume
        isBuy
        txHash
      }
    }
  `;
  
  return querySubgraph(query);
}

async function main() {
  console.log("Testing Subgraph:", SUBGRAPH_URL);
  console.log("=".repeat(60));
  
  // Test 1: Get all pairs
  console.log("\n1. FETCHING ALL PAIRS:");
  console.log("-".repeat(40));
  const pairsResult = await testPairs();
  if (pairsResult.errors) {
    console.error("ERRORS:", pairsResult.errors);
  } else if (pairsResult.data?.ositoPairs) {
    console.log(`Found ${pairsResult.data.ositoPairs.length} pairs:`);
    pairsResult.data.ositoPairs.forEach(pair => {
      console.log(`  ${pair.token0Symbol}/${pair.token1Symbol} (${pair.id})`);
      console.log(`    Last Price: ${pair.lastPrice}`);
      console.log(`    Swap Count: ${pair.swapCount}`);
      console.log(`    Created: ${new Date(Number(pair.createdAtTimestamp) * 1000).toISOString()}`);
    });
  } else {
    console.log("NO PAIRS FOUND");
  }
  
  // Test 2: Get candles for FROB
  console.log("\n2. FETCHING CANDLES FOR FROB:");
  console.log("-".repeat(40));
  console.log(`Pair address: ${FROB_PAIR}`);
  const frobCandles = await testCandles(FROB_PAIR);
  if (frobCandles.errors) {
    console.error("ERRORS:", frobCandles.errors);
  } else if (frobCandles.data?.candles?.length > 0) {
    console.log(`Found ${frobCandles.data.candles.length} candles`);
    const latest = frobCandles.data.candles[0];
    console.log("Latest candle:");
    console.log(`  Time: ${new Date(Number(latest.timestamp) * 1000).toISOString()}`);
    console.log(`  Open: ${latest.open}`);
    console.log(`  High: ${latest.high}`);
    console.log(`  Low: ${latest.low}`);
    console.log(`  Close: ${latest.close}`);
    console.log(`  Volume: ${latest.volume}`);
    console.log(`  Swaps: ${latest.swapCount}`);
    if (latest.pair) {
      console.log(`  Pair Last Price: ${latest.pair.lastPrice}`);
    }
  } else {
    console.log("NO CANDLES FOUND FOR FROB");
  }
  
  // Test 3: Get swaps for FROB
  console.log("\n3. FETCHING SWAPS FOR FROB:");
  console.log("-".repeat(40));
  const frobSwaps = await testSwaps(FROB_PAIR);
  if (frobSwaps.errors) {
    console.error("ERRORS:", frobSwaps.errors);
  } else if (frobSwaps.data?.swaps?.length > 0) {
    console.log(`Found ${frobSwaps.data.swaps.length} swaps`);
    const latest = frobSwaps.data.swaps[0];
    console.log("Latest swap:");
    console.log(`  Time: ${new Date(Number(latest.timestamp) * 1000).toISOString()}`);
    console.log(`  Price: ${latest.price}`);
    console.log(`  Volume: ${latest.volume}`);
    console.log(`  Type: ${latest.isBuy ? 'BUY' : 'SELL'}`);
    console.log(`  Tx: ${latest.txHash}`);
  } else {
    console.log("NO SWAPS FOUND FOR FROB");
  }
  
  // Test 4: Get candles for CHOP
  console.log("\n4. FETCHING CANDLES FOR CHOP:");
  console.log("-".repeat(40));
  console.log(`Pair address: ${CHOP_PAIR}`);
  const chopCandles = await testCandles(CHOP_PAIR);
  if (chopCandles.errors) {
    console.error("ERRORS:", chopCandles.errors);
  } else if (chopCandles.data?.candles?.length > 0) {
    console.log(`Found ${chopCandles.data.candles.length} candles`);
    const latest = chopCandles.data.candles[0];
    console.log("Latest candle:");
    console.log(`  Time: ${new Date(Number(latest.timestamp) * 1000).toISOString()}`);
    console.log(`  Close: ${latest.close}`);
    console.log(`  Volume: ${latest.volume}`);
  } else {
    console.log("NO CANDLES FOUND FOR CHOP");
  }
  
  // Test 5: Get swaps for CHOP
  console.log("\n5. FETCHING SWAPS FOR CHOP:");
  console.log("-".repeat(40));
  const chopSwaps = await testSwaps(CHOP_PAIR);
  if (chopSwaps.errors) {
    console.error("ERRORS:", chopSwaps.errors);
  } else if (chopSwaps.data?.swaps?.length > 0) {
    console.log(`Found ${chopSwaps.data.swaps.length} swaps`);
    const latest = chopSwaps.data.swaps[0];
    console.log("Latest swap:");
    console.log(`  Time: ${new Date(Number(latest.timestamp) * 1000).toISOString()}`);
    console.log(`  Price: ${latest.price}`);
    console.log(`  Volume: ${latest.volume}`);
  } else {
    console.log("NO SWAPS FOUND FOR CHOP");
  }
}

main().catch(console.error);