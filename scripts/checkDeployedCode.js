const { ethers } = require("ethers");

const RPC_URL = "https://palpable-icy-valley.bera-bepolia.quiknode.pro/b2800b4de9d7290d7750adfc75463992a80dfabb/";

// FROB pair
const FROB_PAIR = "0x5B0a2eB91E0b72221e98C0A506870A7fD515e047";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  
  console.log("Checking deployed bytecode for FROB pair...\n");
  
  // Get bytecode
  const bytecode = await provider.getCode(FROB_PAIR);
  console.log(`Bytecode length: ${bytecode.length} chars (${bytecode.length/2} bytes)`);
  
  // Call pMin directly
  const pMinCalldata = "0x90e72ed0"; // pMin() function selector
  
  const result = await provider.call({
    to: FROB_PAIR,
    data: pMinCalldata
  });
  
  console.log("\npMin() raw result:", result);
  
  // Decode as uint256
  const pMinValue = BigInt(result);
  console.log("pMin value:", pMinValue.toString());
  console.log("pMin decimal:", Number(pMinValue) / 1e18);
  
  // Now let's try to understand what calculation is being done
  // Get reserves
  const reservesCalldata = "0x0902f1ac"; // getReserves() selector
  const reservesResult = await provider.call({
    to: FROB_PAIR,
    data: reservesCalldata
  });
  
  console.log("\ngetReserves() raw:", reservesResult);
  
  // Decode reserves (uint112, uint112, uint32)
  const r0 = BigInt("0x" + reservesResult.slice(2, 66).padStart(64, '0'));
  const r1 = BigInt("0x" + reservesResult.slice(66, 130).padStart(64, '0'));
  
  console.log("Reserve0:", r0.toString());
  console.log("Reserve1:", r1.toString());
  
  // Get tokIsToken0
  const tokIsToken0Calldata = "0x62cf0486"; // tokIsToken0() selector
  const tokIsToken0Result = await provider.call({
    to: FROB_PAIR,
    data: tokIsToken0Calldata
  });
  
  const tokIsToken0 = BigInt(tokIsToken0Result) === 1n;
  console.log("\ntokIsToken0:", tokIsToken0);
  
  const tokReserves = tokIsToken0 ? r0 : r1;
  const qtReserves = tokIsToken0 ? r1 : r0;
  
  console.log("\nTOK reserves:", tokReserves.toString());
  console.log("QT reserves:", qtReserves.toString());
  
  // Get initial supply
  const initialSupplyCalldata = "0x378dc3dc"; // initialSupply() selector
  const initialSupplyResult = await provider.call({
    to: FROB_PAIR,
    data: initialSupplyCalldata
  });
  
  const initialSupply = BigInt(initialSupplyResult);
  console.log("\ninitialSupply:", initialSupply.toString());
  
  // Try to figure out what calculation produces the pMin we see
  const k = tokReserves * qtReserves;
  console.log("\nConstant product k:", k.toString());
  
  // Test various formulas
  console.log("\n" + "=".repeat(60));
  console.log("TESTING FORMULAS:");
  console.log("-".repeat(40));
  
  // 1. k / tokReserves^2 (wrong formula mentioned in docs)
  const formula1 = k * BigInt(1e18) / (tokReserves * tokReserves / BigInt(1e18));
  console.log("k / tokReserves²:", formula1.toString());
  
  // 2. k / qtReserves^2 
  const formula2 = k * BigInt(1e18) / (qtReserves * qtReserves / BigInt(1e18));
  console.log("k / qtReserves²:", formula2.toString());
  
  // 3. Something with initial supply?
  const formula3 = initialSupply * BigInt(1e18) / tokReserves;
  console.log("initialSupply / tokReserves:", formula3.toString());
  
  // 4. Maybe it's using wrong reserves?
  const formula4 = initialSupply * qtReserves / tokReserves;
  console.log("initialSupply * qtReserves / tokReserves:", formula4.toString());
  
  console.log("\nActual pMin from chain:", pMinValue.toString());
  console.log("\nNone of these match!");
}

main().catch(console.error);