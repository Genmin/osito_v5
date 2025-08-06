const { ethers } = require("hardhat");

async function main() {
    console.log("=== INDEPENDENT pMin CALCULATION VERIFICATION ===\n");
    
    // Test case: realistic AMM values
    const testCases = [
        {
            name: "FROB token (from deployment)",
            tokReserves: ethers.parseEther("1000000000"),  // 1B tokens
            qtReserves: ethers.parseEther("100"),           // 100 WBERA
            tokTotalSupply: ethers.parseEther("1000000000"), // 1B total
            feeBps: 9900n  // 99% fee
        },
        {
            name: "After some trading",
            tokReserves: ethers.parseEther("900000000"),   // 900M in pool
            qtReserves: ethers.parseEther("111.111"),      // 111 WBERA
            tokTotalSupply: ethers.parseEther("1000000000"), // 1B total
            feeBps: 9500n  // 95% fee
        }
    ];
    
    console.log("MANUAL CALCULATION (what it SHOULD be):");
    console.log("=========================================\n");
    
    for (const test of testCases) {
        console.log(`Test: ${test.name}`);
        console.log(`Reserves: ${ethers.formatEther(test.tokReserves)} TOK / ${ethers.formatEther(test.qtReserves)} QT`);
        
        // Calculate what pMin SHOULD be
        const deltaX = test.tokTotalSupply - test.tokReserves;
        
        if (deltaX === 0n) {
            console.log("No tokens outside pool - pMin = 0\n");
            continue;
        }
        
        // Apply fee to deltaX
        const deltaXEff = (deltaX * (10000n - test.feeBps)) / 10000n;
        const xFinal = test.tokReserves + deltaXEff;
        
        // Calculate k
        const k = test.tokReserves * test.qtReserves;
        
        // yFinal = k / xFinal (CORRECT formula)
        const yFinal = k / xFinal;
        
        // deltaY = qtReserves - yFinal
        const deltaY = test.qtReserves - yFinal;
        
        // pMin = deltaY / deltaX
        const pMinGross = (deltaY * ethers.parseEther("1")) / deltaX;
        
        // Apply 0.5% haircut
        const pMin = (pMinGross * 9950n) / 10000n;
        
        console.log(`deltaX (tokens to dump): ${ethers.formatEther(deltaX)}`);
        console.log(`deltaXEff (after ${test.feeBps/100n}% fee): ${ethers.formatEther(deltaXEff)}`);
        console.log(`k (constant product): ${k}`);
        console.log(`yFinal (QT after dump): ${ethers.formatEther(yFinal)}`);
        console.log(`deltaY (QT received): ${ethers.formatEther(deltaY)}`);
        console.log(`pMin (CORRECT): ${ethers.formatEther(pMin)} QT per TOK\n`);
    }
    
    console.log("\nBUG IN PMinLib.sol:");
    console.log("==================\n");
    console.log("Lines 39-40 have unnecessary WAD operations:");
    console.log("  uint256 yFinal = FixedPointMathLib.mulDiv(k, Constants.WAD, xFinal);");
    console.log("  yFinal = yFinal / Constants.WAD; // Convert back from WAD");
    console.log("\nThis multiplies by 1e18 then divides by 1e18 - BUT:");
    console.log("1. mulDiv(k, WAD, xFinal) = (k * WAD) / xFinal");
    console.log("2. Then dividing by WAD gives: ((k * WAD) / xFinal) / WAD");
    console.log("3. This is NOT equal to k / xFinal due to integer division!");
    console.log("\nThe correct formula should be just: yFinal = k / xFinal");
    
    console.log("\nDEMONSTRATION WITH NUMBERS:");
    console.log("============================\n");
    
    const k = ethers.parseEther("100000000000"); // 100B
    const xFinal = ethers.parseEther("950000000"); // 950M
    
    // Buggy calculation
    const yFinalBuggy1 = (k * ethers.parseEther("1")) / xFinal;
    const yFinalBuggy = yFinalBuggy1 / ethers.parseEther("1");
    
    // Correct calculation
    const yFinalCorrect = k / xFinal;
    
    console.log(`k = ${ethers.formatEther(k)}`);
    console.log(`xFinal = ${ethers.formatEther(xFinal)}`);
    console.log(`\nBuggy: ((k * 1e18) / xFinal) / 1e18 = ${ethers.formatEther(yFinalBuggy)}`);
    console.log(`Correct: k / xFinal = ${ethers.formatEther(yFinalCorrect)}`);
    console.log(`\nError factor: ${yFinalBuggy > 0n ? yFinalCorrect * 10000n / yFinalBuggy : "INFINITY"}/10000`);
    
    // Now check actual on-chain
    console.log("\n\nCHECKING ACTUAL ON-CHAIN DATA:");
    console.log("===============================\n");
    
    const LENS_LITE = "0xDcE5527b2813d37AEe5EFD032D2920A5e5069607";
    const lensLite = await ethers.getContractAt([
        "function markets(uint256 start, uint256 count) view returns (tuple(address pair, address tok, address qt, uint256 tokReserves, uint256 qtReserves, uint256 tokTotalSupply, uint256 pMin, uint256 feeBps, uint256 tvl, uint256 lenderSupply, uint256 lenderBorrows, uint256 borrowRate)[])"
    ], LENS_LITE);
    
    const markets = await lensLite.markets(0, 100);
    
    const targetAddresses = [
        "0x3a369629DbFBF6E8f3201F5489696486b752bF7e", // FROB
        "0x0F9065E9F71d6e86305a4815b3397829AEAa52C9"  // CHOP
    ];
    
    for (const addr of targetAddresses) {
        const market = markets.find(m => m.pair.toLowerCase() === addr.toLowerCase());
        if (market) {
            console.log(`\nPair: ${market.pair}`);
            console.log(`TOK reserves: ${ethers.formatEther(market.tokReserves)}`);
            console.log(`QT reserves: ${ethers.formatEther(market.qtReserves)}`);
            console.log(`TOK total supply: ${ethers.formatEther(market.tokTotalSupply)}`);
            console.log(`pMin returned: ${ethers.formatEther(market.pMin)} QT per TOK`);
            
            // Calculate what it SHOULD be
            const deltaX = market.tokTotalSupply - market.tokReserves;
            if (deltaX > 0n) {
                const deltaXEff = (deltaX * (10000n - market.feeBps)) / 10000n;
                const xFinal = market.tokReserves + deltaXEff;
                const k = market.tokReserves * market.qtReserves;
                const yFinalCorrect = k / xFinal;
                const deltaY = market.qtReserves - yFinalCorrect;
                const pMinCorrect = (deltaY * ethers.parseEther("1")) / deltaX;
                const pMinWithHaircut = (pMinCorrect * 9950n) / 10000n;
                
                console.log(`pMin SHOULD BE: ${ethers.formatEther(pMinWithHaircut)} QT per TOK`);
                console.log(`ERROR FACTOR: ${market.pMin / pMinWithHaircut}x too high!`);
            }
        }
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });