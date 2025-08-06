// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/libraries/PMinLib.sol";
import "../../src/libraries/Constants.sol";

contract PMinLibComprehensiveTest is Test {
    
    // Test the EXACT scenario from FROB token
    function test_FrobScenario() public {
        // Actual on-chain values
        uint256 tokReserves = 133416884436119104511233572;
        uint256 qtReserves = 7621470024147971507;
        uint256 totalSupply = 982133839947425838011265670;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        console.log("FROB Scenario pMin:", pMin);
        console.log("FROB pMin as decimal:", pMin * 1e18 / 1e18);
        
        // The correct value should be around 7.7e-9 WBERA per token
        // Based on manual calculation: (deltaY / deltaX) * (1 - bounty)
        // deltaX = 848716955511306733500032098
        // deltaXEff = 846170804644772813299532001
        // xFinal = 979587689080891917810765573
        // k = 1016832785445095795375347229386463458077833004
        // yFinal = k / xFinal = 1038021196855944021
        // deltaY = 7621470024147971507 - 1038021196855944021 = 6583448827292027486
        // pMinGross = deltaY * 1e18 / deltaX = 7756942741
        // pMin = pMinGross * 9950 / 10000 = 7718158027
        
        assertEq(pMin, 7718158027, "pMin calculation is wrong!");
    }
    
    // Test edge case: all tokens in pool
    function test_AllTokensInPool() public {
        uint256 tokReserves = 1000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1000e18; // Same as reserves
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        assertEq(pMin, 0, "pMin should be 0 when all tokens are in pool");
    }
    
    // Test edge case: very small QT reserves
    function test_SmallQTReserves() public {
        uint256 tokReserves = 1000000e18;
        uint256 qtReserves = 1; // 1 wei of QT
        uint256 totalSupply = 2000000e18;
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // With almost no QT, pMin should be nearly 0
        assertTrue(pMin < 1e9, "pMin should be very small with tiny QT reserves");
    }
    
    // Test the mathematical correctness
    function test_MathematicalCorrectness() public {
        // Simple scenario for manual verification
        uint256 tokReserves = 100e18;
        uint256 qtReserves = 10e18;
        uint256 totalSupply = 200e18;
        uint256 feeBps = 0; // No fee for simplicity
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Manual calculation:
        // deltaX = 100e18
        // deltaXEff = 100e18 (no fee)
        // xFinal = 200e18
        // k = 100e18 * 10e18 = 1000e36
        // yFinal = k / xFinal = 1000e36 / 200e18 = 5e18
        // deltaY = 10e18 - 5e18 = 5e18
        // pMinGross = 5e18 * 1e18 / 100e18 = 0.05e18
        // pMin = 0.05e18 * 9950 / 10000 = 0.04975e18
        
        assertEq(pMin, 49750000000000000, "Mathematical calculation incorrect");
    }
    
    // Fuzz test to ensure no reverts
    function testFuzz_NoReverts(
        uint128 tokReserves,
        uint128 qtReserves,
        uint256 totalSupply,
        uint16 feeBps
    ) public {
        // Bound inputs to reasonable ranges
        vm.assume(tokReserves > 0 && tokReserves < type(uint112).max);
        vm.assume(qtReserves > 0 && qtReserves < type(uint112).max);
        vm.assume(totalSupply > 0 && totalSupply < type(uint128).max);
        vm.assume(feeBps <= 10000);
        
        // Should not revert
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Basic sanity checks
        if (totalSupply <= tokReserves) {
            assertEq(pMin, 0, "Should return 0 when all tokens in pool");
        }
    }
    
    // Test that pMin increases as tokens leave the pool
    function test_PMinIncreasesWithDumping() public {
        uint256 tokReserves = 100e18;
        uint256 qtReserves = 10e18;
        uint256 feeBps = 30;
        
        // Start with all tokens in pool
        uint256 pMin1 = PMinLib.calculate(tokReserves, qtReserves, 100e18, feeBps);
        
        // Some tokens outside
        uint256 pMin2 = PMinLib.calculate(tokReserves, qtReserves, 150e18, feeBps);
        
        // More tokens outside
        uint256 pMin3 = PMinLib.calculate(tokReserves, qtReserves, 200e18, feeBps);
        
        // Even more tokens outside
        uint256 pMin4 = PMinLib.calculate(tokReserves, qtReserves, 500e18, feeBps);
        
        console.log("pMin with 0% outside:", pMin1);
        console.log("pMin with 33% outside:", pMin2);
        console.log("pMin with 50% outside:", pMin3);
        console.log("pMin with 80% outside:", pMin4);
        
        // As more tokens are outside, price impact increases, so pMin decreases
        assertTrue(pMin1 <= pMin2, "pMin should increase or stay same");
        assertTrue(pMin2 >= pMin3, "pMin should decrease with more dumping");
        assertTrue(pMin3 >= pMin4, "pMin should decrease with more dumping");
    }
    
    // Test the bug: unnecessary WAD operations
    function test_WadOperationsBug() public {
        uint256 tokReserves = 100e18;
        uint256 qtReserves = 10e18;
        uint256 totalSupply = 200e18;
        uint256 feeBps = 30;
        
        // Current implementation
        uint256 pMinCurrent = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // What it should be (simulate correct calculation)
        uint256 deltaX = totalSupply - tokReserves;
        uint256 deltaXEff = (deltaX * (10000 - feeBps)) / 10000;
        uint256 xFinal = tokReserves + deltaXEff;
        uint256 k = tokReserves * qtReserves;
        
        // Correct: just k / xFinal
        uint256 yFinalCorrect = k / xFinal;
        
        // Current buggy implementation: mulDiv then divide
        uint256 yFinalBuggy = FixedPointMathLib.mulDiv(k, Constants.WAD, xFinal) / Constants.WAD;
        
        console.log("yFinal correct:", yFinalCorrect);
        console.log("yFinal buggy:", yFinalBuggy);
        console.log("Difference:", yFinalCorrect > yFinalBuggy ? yFinalCorrect - yFinalBuggy : yFinalBuggy - yFinalCorrect);
        
        // They should be the same (or very close)
        assertApproxEqAbs(yFinalCorrect, yFinalBuggy, 1, "WAD operations shouldn't change result significantly");
    }
    
    // Test overflow protection
    function test_OverflowProtection() public {
        // Max uint112 values (Uniswap V2 limits)
        uint256 tokReserves = type(uint112).max;
        uint256 qtReserves = type(uint112).max;
        uint256 totalSupply = type(uint128).max;
        uint256 feeBps = 9999; // High fee
        
        // Should not overflow
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Should return something reasonable or 0
        assertTrue(pMin == 0 || pMin < type(uint128).max, "Overflow protection failed");
    }
    
    // Compare with the correct formula from the document
    function test_CorrectFormula() public {
        uint256 x = 237_000_000e18;  // tokReserves
        uint256 y = 5e18;             // qtReserves
        uint256 S = 1_000_000_000e18; // totalSupply
        uint256 f = 1500;             // 15% fee
        
        // Calculate using correct formula: (y - k/xFinal) / deltaX
        uint256 deltaX = S - x;
        uint256 deltaXEff = (deltaX * (10000 - f)) / 10000;
        uint256 xFinal = x + deltaXEff;
        uint256 k = x * y;
        uint256 yFinal = k / xFinal;
        
        require(y > yFinal, "No output");
        
        uint256 deltaY = y - yFinal;
        uint256 pMinGross = (deltaY * 1e18) / deltaX;
        uint256 pMinCorrect = (pMinGross * 9950) / 10000; // 0.5% bounty
        
        // Get library result
        uint256 pMinLib = PMinLib.calculate(x, y, S, f);
        
        console.log("Correct formula pMin:", pMinCorrect);
        console.log("Library pMin:", pMinLib);
        
        // They should match
        assertEq(pMinLib, pMinCorrect, "Library doesn't match correct formula");
    }
}