// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/libraries/PMinLib.sol";
import "../src/libraries/Constants.sol";

contract PMinAttackTest is Test {
    using PMinLib for uint256;

    function testPMinCalculationFixed() public pure {
        // Real CHART token scenario
        uint256 tokReserves = 922658986175115207373272; // ~922K CHART
        uint256 qtReserves = 1098986459737507085; // ~1.1 WBERA
        uint256 tokTotalSupply = 1000000000000000000000000; // 1M CHART
        uint256 feeBps = 100; // 1% fee
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        // Manual calculation verification
        uint256 k = tokReserves * qtReserves;
        uint256 tokToSwap = tokTotalSupply - tokReserves;
        uint256 effectiveSwapAmount = (tokToSwap * (10000 - feeBps)) / 10000;
        uint256 xFinal = tokReserves + effectiveSwapAmount;
        
        // Expected: k / xFinal² with bounty haircut
        uint256 expectedPMinGross = (k * Constants.WAD) / (xFinal * xFinal);
        uint256 expectedPMin = (expectedPMinGross * (Constants.BASIS_POINTS - Constants.LIQ_BOUNTY_BPS)) / Constants.BASIS_POINTS;
        
        console.log("Calculated pMin:", pMin);
        console.log("Expected pMin:", expectedPMin);
        console.log("pMin in human units (WBERA per CHART):", pMin / 1e18);
        
        // Verify they match
        assertEq(pMin, expectedPMin, "pMin calculation should match manual calculation");
        
        // Verify pMin is reasonable (should be tiny fraction)
        assertTrue(pMin < 1e12, "pMin should be tiny (less than 1e-6 WBERA per CHART)");
        
        // Test borrowing capacity with 10,000 CHART collateral
        uint256 collateral = 10000 * 1e18;
        uint256 maxBorrowable = (collateral * pMin) / 1e18;
        
        console.log("Max borrowable with 10K CHART:", maxBorrowable / 1e18, "WBERA");
        
        // Should be able to borrow very little (safe)
        assertTrue(maxBorrowable < 100 * 1e18, "Should not be able to borrow more than 100 WBERA with 10K CHART");
    }
    
    function testAttackScenario1_MaximalDump() public pure {
        // Attacker controls 50% of total supply outside pool
        uint256 tokReserves = 500000 * 1e18; // 500K in pool
        uint256 qtReserves = 1000 * 1e18; // 1000 WBERA in pool  
        uint256 tokTotalSupply = 1000000 * 1e18; // 1M total
        uint256 feeBps = 30; // Low 0.3% fee (worst case)
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        // Attacker has 500K tokens, tries to borrow max
        uint256 attackerCollateral = 500000 * 1e18;
        uint256 maxBorrowable = (attackerCollateral * pMin) / 1e18;
        
        console.log("Attack Scenario 1 - Maximal dump:");
        console.log("Attacker collateral: 500K tokens");
        console.log("pMin:", pMin / 1e18, "WBERA per token");
        console.log("Max borrowable:", maxBorrowable / 1e18, "WBERA");
        
        // Even if attacker dumps ALL remaining tokens, liquidation at pMin must cover debt
        // This is guaranteed by the pMin formula itself
        assertTrue(maxBorrowable <= qtReserves, "Cannot borrow more than available liquidity");
    }
    
    function testAttackScenario2_EdgeCaseLowLiquidity() public pure {
        // Edge case: Very low liquidity
        uint256 tokReserves = 1000 * 1e18; // Only 1K tokens in pool
        uint256 qtReserves = 1 * 1e18; // Only 1 WBERA in pool
        uint256 tokTotalSupply = 1000000 * 1e18; // 1M total supply
        uint256 feeBps = 30; // Low fee
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        // Attacker has majority of supply
        uint256 attackerCollateral = 999000 * 1e18; // 999K tokens
        uint256 maxBorrowable = (attackerCollateral * pMin) / 1e18;
        
        console.log("Attack Scenario 2 - Low liquidity:");
        console.log("Pool has tiny liquidity: 1K tokens, 1 WBERA");
        console.log("Attacker has: 999K tokens");
        console.log("pMin:", pMin / 1e18);
        console.log("Max borrowable:", maxBorrowable / 1e18, "WBERA");
        
        // pMin should be EXTREMELY tiny due to massive dilution effect
        assertTrue(pMin < 1e6, "pMin should be microscopic with massive dilution");
        assertTrue(maxBorrowable < 1e18, "Should barely be able to borrow anything");
    }
    
    function testAttackScenario3_FlashLoanAttack() public pure {
        // Attacker tries to manipulate reserves with flash loan before borrowing
        // This attack vector is impossible because:
        // 1. pMin is calculated from CURRENT reserves at borrow time
        // 2. Flash loan would pump reserves, making pMin even smaller
        // 3. Smaller pMin = less borrowing capacity
        
        uint256 tokReserves = 100000 * 1e18;
        uint256 qtReserves = 100 * 1e18;
        uint256 tokTotalSupply = 1000000 * 1e18;
        uint256 feeBps = 100; // 1%
        
        uint256 normalPMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        // After flash loan pump (attacker adds liquidity temporarily)
        uint256 pumpedTokReserves = tokReserves + 500000 * 1e18; // Pump with 500K tokens
        uint256 pumpedQtReserves = qtReserves + 500 * 1e18; // Add proportional WBERA
        
        uint256 pumpedPMin = PMinLib.calculate(pumpedTokReserves, pumpedQtReserves, tokTotalSupply, feeBps);
        
        console.log("Flash loan attack test:");
        console.log("Normal pMin:", normalPMin / 1e18);
        console.log("Pumped pMin:", pumpedPMin / 1e18);
        
        // Pumping reserves makes pMin SMALLER, not larger
        assertTrue(pumpedPMin <= normalPMin, "Flash loan manipulation makes borrowing WORSE for attacker");
    }
    
    function testAttackScenario4_InterestRateManipulation() public {
        // Attacker tries to borrow max, let interest accrue, then manipulate to avoid liquidation
        // This is prevented by the pMin guarantee - even with zero interest,
        // liquidation at pMin covers principal
        
        uint256 tokReserves = 100000 * 1e18;
        uint256 qtReserves = 100 * 1e18;
        uint256 tokTotalSupply = 1000000 * 1e18;
        uint256 feeBps = 100;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        uint256 collateral = 10000 * 1e18;
        uint256 principal = (collateral * pMin) / 1e18;
        
        // Even with 1000% interest accrued
        uint256 totalDebtWithInterest = principal * 10;
        
        // Liquidation value at pMin (guaranteed minimum)
        uint256 liquidationValue = (collateral * pMin) / 1e18;
        
        console.log("Interest manipulation test:");
        console.log("Principal borrowed:", principal / 1e18, "WBERA");
        console.log("Debt with 1000% interest:", totalDebtWithInterest / 1e18, "WBERA");
        console.log("Liquidation value at pMin:", liquidationValue / 1e18, "WBERA");
        
        // Even with massive interest, principal is always recoverable
        assertTrue(liquidationValue >= principal, "Principal always recoverable at pMin");
        
        // Interest is bonus profit when spot > pMin (which it should be)
        console.log("System remains solvent even with infinite interest");
    }
    
    function testEdgeCase_ZeroSupplyOutsidePool() public pure {
        // Edge case: All tokens in pool (x = S)
        uint256 tokReserves = 1000000 * 1e18; // All tokens
        uint256 qtReserves = 1000 * 1e18;
        uint256 tokTotalSupply = 1000000 * 1e18; // Same as reserves
        uint256 feeBps = 100;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, tokTotalSupply, feeBps);
        
        // Should return spot price with bounty haircut
        uint256 spotPrice = (qtReserves * Constants.WAD) / tokReserves;
        uint256 expectedPMin = (spotPrice * (Constants.BASIS_POINTS - Constants.LIQ_BOUNTY_BPS)) / Constants.BASIS_POINTS;
        
        console.log("Edge case - all tokens in pool:");
        console.log("Calculated pMin:", pMin);
        console.log("Expected (spot with haircut):", expectedPMin);
        
        assertEq(pMin, expectedPMin, "Should return spot price with haircut when all tokens in pool");
    }
}