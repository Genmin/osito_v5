// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "../src/libraries/PMinLib.sol";

contract PMinLibFixedTest is Test {
    
    function test_PMinFixedCorrectly() public pure {
        console2.log("\n=== TESTING FIXED PMIN CALCULATION ===\n");
        
        // Test case: realistic values
        uint256 tokReserves = 900_000_000 * 1e18;  // 900M in pool
        uint256 qtReserves = 100 * 1e18;           // 100 WBERA
        uint256 tokTotalSupply = 1_000_000_000 * 1e18; // 1B total
        uint256 feeBps = 9900; // 99% fee
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        console2.log("Test parameters:");
        console2.log("  TOK reserves: 900M");
        console2.log("  QT reserves: 100 WBERA");
        console2.log("  Total supply: 1B");
        console2.log("  Tokens outside: 100M");
        console2.log("  Fee: 99%");
        
        console2.log("\nCalculated pMin:", pMin);
        console2.log("pMin in WBERA per TOK:", pMin / 1e18);
        console2.log("pMin in decimals:", pMin * 1000 / 1e18, "/ 1000");
        
        // Verify it's reasonable (should be slightly below spot)
        uint256 spotPrice = (qtReserves * 1e18) / tokReserves;
        console2.log("\nSpot price:", spotPrice / 1e18, "WBERA per TOK");
        console2.log("Spot in decimals:", spotPrice * 1000 / 1e18, "/ 1000");
        
        // pMin should be less than spot (it's the floor after all tokens dump)
        assertTrue(pMin < spotPrice, "pMin should be less than spot price");
        
        // But not absurdly high
        assertTrue(pMin < 1e18, "pMin should be less than 1 WBERA per token");
        
        console2.log("\n[SUCCESS] PMinLib fixed - returns reasonable values!");
    }
    
    function test_EdgeCaseNoTokensOutside() public pure {
        // When all tokens are in the pool
        uint256 tokReserves = 1_000_000_000 * 1e18;
        uint256 qtReserves = 100 * 1e18;
        uint256 tokTotalSupply = 1_000_000_000 * 1e18; // Same as reserves
        uint256 feeBps = 9900;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        assertEq(pMin, 0, "pMin should be 0 when no tokens outside pool");
        console2.log("[PASS] Edge case: No tokens outside = pMin 0");
    }
}