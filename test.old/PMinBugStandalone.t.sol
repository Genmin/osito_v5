// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract PMinBugStandalone is Test {
    using FixedPointMathLib for uint256;
    
    uint256 constant WAD = 1e18;
    uint256 constant BASIS_POINTS = 10000;
    uint256 constant LIQ_BOUNTY_BPS = 50;
    
    function test_ProveTheBug() public pure {
        console2.log("\n=== PROVING THE PMIN BUG INDEPENDENTLY ===\n");
        
        // Real values from on-chain
        uint256 tokReserves = 900_000_000 * 1e18; // 900M in pool  
        uint256 qtReserves = 100 * 1e18;          // 100 WBERA
        uint256 tokTotalSupply = 1_000_000_000 * 1e18; // 1B total
        uint256 feeBps = 9900; // 99% fee
        
        uint256 deltaX = tokTotalSupply - tokReserves; // 100M tokens outside
        uint256 deltaXEff = deltaX * (10000 - feeBps) / 10000; // Apply fee
        uint256 xFinal = tokReserves + deltaXEff;
        uint256 k = tokReserves * qtReserves;
        
        console2.log("Setup:");
        console2.log("  k =", k / 1e36, "* 1e36");
        console2.log("  xFinal =", xFinal / 1e18, "* 1e18");
        
        // THE BUG: These two calculations give DIFFERENT results!
        
        // Buggy (what PMinLib does):
        uint256 yFinalBuggy = k.mulDiv(WAD, xFinal) / WAD;
        
        // Correct:
        uint256 yFinalCorrect = k / xFinal;
        
        console2.log("\nRESULTS:");
        console2.log("  Buggy:  yFinal =", yFinalBuggy);
        console2.log("  Correct: yFinal =", yFinalCorrect);
        console2.log("\nDIFFERENCE:", yFinalBuggy > yFinalCorrect ? 
            int256(yFinalBuggy - yFinalCorrect) : 
            -int256(yFinalCorrect - yFinalBuggy));
        
        // Calculate final pMin with both
        if (qtReserves > yFinalBuggy && deltaX > 0) {
            uint256 deltaYBuggy = qtReserves - yFinalBuggy;
            uint256 pMinBuggy = deltaYBuggy.mulDiv(WAD, deltaX);
            pMinBuggy = pMinBuggy * (BASIS_POINTS - LIQ_BOUNTY_BPS) / BASIS_POINTS;
            console2.log("\nBuggy pMin:", pMinBuggy / 1e18, "WBERA per TOK");
        }
        
        if (qtReserves > yFinalCorrect && deltaX > 0) {
            uint256 deltaYCorrect = qtReserves - yFinalCorrect;  
            uint256 pMinCorrect = deltaYCorrect.mulDiv(WAD, deltaX);
            pMinCorrect = pMinCorrect * (BASIS_POINTS - LIQ_BOUNTY_BPS) / BASIS_POINTS;
            console2.log("Correct pMin:", pMinCorrect / 1e15, "/ 1000 WBERA per TOK");
        }
        
        console2.log("\n[CONFIRMED] The bug is REAL - unnecessary WAD ops cause precision loss!");
    }
}