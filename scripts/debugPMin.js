const { ethers } = require("ethers");

// Test case 1: FROB
const FROB = {
  tokReserves: 133416884436119104511233572n,
  qtReserves: 7621470024147971507n,
  totalSupply: 982133839947425838011265670n,
  feeBps: 30n // 0.3%
};

// Test case 2: CHOP
const CHOP = {
  tokReserves: 986030942309065543984571051n,
  qtReserves: 1027230488117786144n,
  totalSupply: 986030942309065543984571051n,
  feeBps: 30n // 0.3%
};

const WAD = 10n ** 18n;
const BASIS_POINTS = 10000n;
const LIQ_BOUNTY_BPS = 50n; // 0.5%

function calculatePMin(tokReserves, qtReserves, tokTotalSupply, feeBps) {
  console.log("\n=== PMin Calculation Debug ===");
  console.log("Input:");
  console.log("  tokReserves:", tokReserves.toString());
  console.log("  qtReserves:", qtReserves.toString());
  console.log("  tokTotalSupply:", tokTotalSupply.toString());
  console.log("  feeBps:", feeBps.toString());
  
  // Early return: nothing outside pool
  if (tokTotalSupply <= tokReserves) {
    console.log("All tokens in pool, pMin = 0");
    return 0n;
  }
  
  // Calculate tokens to dump and effective amount after fees
  const deltaX = tokTotalSupply - tokReserves;
  console.log("\nTokens outside pool (deltaX):", deltaX.toString());
  console.log("  As decimal:", Number(deltaX) / 1e18);
  
  const deltaXEff = (deltaX * (BASIS_POINTS - feeBps)) / BASIS_POINTS;
  console.log("Effective tokens after fee (deltaXEff):", deltaXEff.toString());
  
  const xFinal = tokReserves + deltaXEff;
  console.log("Final TOK reserves (xFinal):", xFinal.toString());
  
  // Constant product k
  const k = tokReserves * qtReserves;
  console.log("\nConstant product (k):", k.toString());
  
  // THIS IS THE BUG: The contract is doing extra WAD operations
  // WRONG: yFinal = (k * WAD / xFinal) / WAD
  // This is essentially just k / xFinal but with precision loss
  
  // Let's see what the contract is actually doing:
  console.log("\n--- Contract's buggy calculation ---");
  const yFinalWrong = (k * WAD / xFinal) / WAD;
  console.log("yFinal (WRONG):", yFinalWrong.toString());
  
  // The correct calculation should be:
  console.log("\n--- Correct calculation ---");
  const yFinalCorrect = k / xFinal;
  console.log("yFinal (CORRECT):", yFinalCorrect.toString());
  
  // Using the WRONG value (what contract does):
  if (qtReserves <= yFinalWrong) {
    console.log("No output (qtReserves <= yFinal)");
    return 0n;
  }
  
  const deltaY = qtReserves - yFinalWrong;
  console.log("\nQT tokens that come out (deltaY):", deltaY.toString());
  console.log("  As decimal:", Number(deltaY) / 1e18);
  
  // Average execution price: deltaY / deltaX
  const pMinGross = (deltaY * WAD) / deltaX;
  console.log("\nGross pMin (wei):", pMinGross.toString());
  console.log("  As decimal:", Number(pMinGross) / 1e18);
  
  // Apply liquidation bounty haircut (0.5%)
  const pMin = (pMinGross * (BASIS_POINTS - LIQ_BOUNTY_BPS)) / BASIS_POINTS;
  console.log("\nFinal pMin after bounty (wei):", pMin.toString());
  console.log("  As decimal:", Number(pMin) / 1e18);
  
  // Now show what the CORRECT calculation would give:
  console.log("\n=== What CORRECT calculation would give ===");
  const deltaYCorrect = qtReserves - yFinalCorrect;
  const pMinGrossCorrect = (deltaYCorrect * WAD) / deltaX;
  const pMinCorrect = (pMinGrossCorrect * (BASIS_POINTS - LIQ_BOUNTY_BPS)) / BASIS_POINTS;
  console.log("Correct pMin (wei):", pMinCorrect.toString());
  console.log("  As decimal:", Number(pMinCorrect) / 1e18);
  
  return pMin;
}

console.log("\n" + "=".repeat(60));
console.log("FROB TOKEN ANALYSIS");
console.log("=".repeat(60));
const frobPMin = calculatePMin(FROB.tokReserves, FROB.qtReserves, FROB.totalSupply, FROB.feeBps);

console.log("\n" + "=".repeat(60));
console.log("CHOP TOKEN ANALYSIS");
console.log("=".repeat(60));
const chopPMin = calculatePMin(CHOP.tokReserves, CHOP.qtReserves, CHOP.totalSupply, CHOP.feeBps);

console.log("\n" + "=".repeat(60));
console.log("SUMMARY");
console.log("=".repeat(60));
console.log("FROB pMin (from chain):", "1054352869461567596153118183");
console.log("FROB pMin (calculated):", frobPMin.toString());
console.log("Match?", frobPMin.toString() === "1054352869461567596153118183");

console.log("\nCHOP pMin (from chain):", "1036574300");
console.log("CHOP pMin (calculated):", chopPMin.toString());
console.log("Match?", chopPMin.toString() === "1036574300");