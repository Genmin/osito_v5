// Test the actual pMin calculation step by step

const FROB = {
  tokReserves: 133416884436119104511233572n,
  qtReserves: 7621470024147971507n,
  totalSupply: 982133839947425838011265670n,
  feeBps: 30n,
  onChainPMin: 1054352869461567596153118183n  // What chain reports
};

const WAD = 10n ** 18n;
const BASIS_POINTS = 10000n;
const LIQ_BOUNTY_BPS = 50n;

console.log("DEBUGGING PMIN CALCULATION");
console.log("=".repeat(60));

// Step 1: Calculate deltaX
const deltaX = FROB.totalSupply - FROB.tokReserves;
console.log("\n1. Delta X (tokens outside pool):");
console.log(`   ${deltaX}`);
console.log(`   = ${Number(deltaX) / 1e18} tokens`);

// Step 2: Calculate effective deltaX after fee
const deltaXEff = deltaX * (BASIS_POINTS - FROB.feeBps) / BASIS_POINTS;
console.log("\n2. Delta X Effective (after 0.3% fee):");
console.log(`   ${deltaXEff}`);

// Step 3: Calculate xFinal
const xFinal = FROB.tokReserves + deltaXEff;
console.log("\n3. X Final (new token reserves):");
console.log(`   ${xFinal}`);

// Step 4: Calculate k
const k = FROB.tokReserves * FROB.qtReserves;
console.log("\n4. Constant Product k:");
console.log(`   ${k}`);

// Step 5: Calculate yFinal - THIS IS WHERE THE BUG IS
console.log("\n5. Y Final Calculation:");

// What the code is doing (WRONG):
const yFinalWrongStep1 = k * WAD / xFinal;
console.log(`   Wrong Step 1: k * WAD / xFinal = ${yFinalWrongStep1}`);
const yFinalWrong = yFinalWrongStep1 / WAD;
console.log(`   Wrong Step 2: divide by WAD = ${yFinalWrong}`);

// What it SHOULD do:
const yFinalCorrect = k / xFinal;
console.log(`   Correct: k / xFinal = ${yFinalCorrect}`);

console.log(`\n   Difference: ${yFinalWrong - yFinalCorrect}`);

// Step 6: Calculate deltaY
console.log("\n6. Delta Y (QT tokens out):");
const deltaYWrong = FROB.qtReserves - yFinalWrong;
const deltaYCorrect = FROB.qtReserves - yFinalCorrect;
console.log(`   Using wrong yFinal: ${deltaYWrong}`);
console.log(`   Using correct yFinal: ${deltaYCorrect}`);

// Step 7: Calculate pMin
console.log("\n7. pMin Calculation:");
const pMinGrossWrong = deltaYWrong * WAD / deltaX;
const pMinGrossCorrect = deltaYCorrect * WAD / deltaX;
console.log(`   Wrong: ${pMinGrossWrong}`);
console.log(`   Correct: ${pMinGrossCorrect}`);

// Step 8: Apply bounty
const pMinWrong = pMinGrossWrong * (BASIS_POINTS - LIQ_BOUNTY_BPS) / BASIS_POINTS;
const pMinCorrect = pMinGrossCorrect * (BASIS_POINTS - LIQ_BOUNTY_BPS) / BASIS_POINTS;

console.log("\n8. Final pMin after 0.5% bounty:");
console.log(`   Wrong: ${pMinWrong}`);
console.log(`   Correct: ${pMinCorrect}`);
console.log(`   On-chain: ${FROB.onChainPMin}`);

console.log("\n" + "=".repeat(60));
console.log("THE PROBLEM:");
console.log("-".repeat(40));

// The real issue - let's trace through what's actually happening
console.log("\nWait, let me recalculate what the contract ACTUALLY produces...");

// The contract does: yFinal = mulDiv(k, WAD, xFinal) / WAD
// mulDiv(a, b, c) = (a * b) / c
// So: yFinal = ((k * WAD) / xFinal) / WAD

// But wait, that simplifies to k / xFinal which is correct!
// Unless... there's precision loss in the integer division

const kTimesWad = k * WAD;
console.log(`\nk * WAD = ${kTimesWad}`);

const divResult = kTimesWad / xFinal;
console.log(`(k * WAD) / xFinal = ${divResult}`);

const finalYFinal = divResult / WAD;
console.log(`Result / WAD = ${finalYFinal}`);

// The precision loss happens because we're dividing by WAD after already dividing
// This loses the remainder!

const correctDivision = k / xFinal;
console.log(`\nDirect k / xFinal = ${correctDivision}`);

const lostPrecision = correctDivision - finalYFinal;
console.log(`Lost precision: ${lostPrecision}`);

// This makes yFinal SMALLER than it should be
// Which makes deltaY LARGER
// Which makes pMin LARGER!

console.log("\n" + "=".repeat(60));
console.log("WAIT - THAT DOESN'T EXPLAIN THE HUGE pMin!");
console.log("-".repeat(40));

// Let me check if the contract has a different bug...
// What if it's not doing the deltaY calculation at all?
// What if it's returning something else entirely?

const spotPrice = FROB.qtReserves * WAD / FROB.tokReserves;
console.log(`\nSpot price: ${spotPrice}`);

// What about k / xFinal^2 ?
const xFinalSquared = xFinal * xFinal / WAD;  // Need to scale for overflow
const kDivXFinalSquared = k * WAD / xFinalSquared;
console.log(`k / xFinal²: ${kDivXFinalSquared}`);

// Hmm, that's also not matching...

console.log("\n" + "=".repeat(60));
console.log("ACTUAL ISSUE:");
console.log("-".repeat(40));
console.log("The on-chain pMin value doesn't match ANY reasonable calculation!");
console.log("Something else must be wrong in the contract deployment.");