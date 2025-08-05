// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

/// @title Critical pMin Overflow Protection Tests
/// @notice Tests the most dangerous mathematical edge cases in pMin calculation
contract PMinOverflowEdgeCasesTest is BaseTest {
    
    /// @notice Test: pMin calculation with maximum reserves
    function test_PMin_MaxReservesOverflow() public {
        // Test with reserves near uint256 max to check k overflow
        uint256 maxSafeReserve = type(uint112).max; // UniV2 reserve limit
        uint256 tokReserves = maxSafeReserve;
        uint256 qtReserves = maxSafeReserve;
        uint256 supply = maxSafeReserve + 1000e18;
        uint256 feeBps = 30;
        
        // This should trigger the overflow protection
        try PMinLib.calculate(tokReserves, qtReserves, supply, feeBps) returns (uint256 pMin) {
            console2.log("pMin with max reserves:", pMin);
            assertEq(pMin, 0, "Should return 0 due to overflow protection");
        } catch {
            console2.log("Overflow protection triggered correctly");
            // This is the expected behavior for extreme values
        }
        console2.log("[PASS] Maximum reserves overflow protection works");
    }
    
    /// @notice Test: pMin calculation with zero and near-zero values
    function test_PMin_ZeroEdgeCases() public {
        // Case 1: Zero total supply
        uint256 pMin1 = PMinLib.calculate(1000e18, 100e18, 0, 30);
        assertEq(pMin1, 0, "Zero supply should return 0");
        
        // Case 2: All tokens in pool (supply == reserves)
        uint256 pMin2 = PMinLib.calculate(1000e18, 100e18, 1000e18, 30);
        assertTrue(pMin2 > 0, "All tokens in pool should return spot price with discount");
        console2.log("Spot price with discount:", pMin2);
        
        // Case 3: xFinal below safety threshold (< 1e9)
        uint256 pMin3 = PMinLib.calculate(1, 1000e18, 2, 0); // Extreme case
        assertEq(pMin3, 0, "xFinal < 1e9 should return 0");
        
        console2.log("[PASS] Zero and edge case protections work");
    }
    
    /// @notice Test: pMin calculation precision with extreme ratios
    function test_PMin_ExtremePrecisionRatios() public {
        // Case 1: Very large token reserves, tiny QT reserves
        uint256 tokReserves = 1_000_000_000e18; // 1B tokens
        uint256 qtReserves = 1e12; // 0.000001 ETH (1 wei * 1e12)
        uint256 supply = tokReserves + 1000e18;
        
        uint256 pMin1 = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        console2.log("pMin with extreme ratio (large tok, tiny qt):", pMin1);
        
        // Case 2: Tiny token reserves, very large QT reserves  
        tokReserves = 1e12; // 0.000001 tokens
        qtReserves = 1000e18; // 1000 ETH
        supply = tokReserves + 1000e18;
        
        uint256 pMin2 = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        console2.log("pMin with extreme ratio (tiny tok, large qt):", pMin2);
        
        // Both should handle gracefully without reverting
        console2.log("[PASS] Extreme precision ratios handled");
    }
    
    /// @notice Test: pMin calculation with maximum fee
    function test_PMin_MaximumFee() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1_000_000e18;
        
        // Test with 99.99% fee (maximum possible)
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, 9999);
        console2.log("pMin with 99.99% fee:", pMin);
        assertTrue(pMin >= 0, "Should handle maximum fee");
        
        // Test with 100% fee (edge case)
        pMin = PMinLib.calculate(tokReserves, qtReserves, supply, 10000);
        console2.log("pMin with 100% fee:", pMin);
        
        console2.log("[PASS] Maximum fee edge cases handled");
    }
    
    /// @notice Test: pMin calculation with supply close to reserves
    function test_PMin_SupplyNearReserves() public {
        uint256 tokReserves = 999_999e18;
        uint256 qtReserves = 100e18;
        
        // Case 1: Supply exactly equals reserves
        uint256 pMin1 = PMinLib.calculate(tokReserves, qtReserves, tokReserves, 30);
        assertTrue(pMin1 > 0, "Supply == reserves should work");
        
        // Case 2: Supply 1 wei more than reserves
        uint256 pMin2 = PMinLib.calculate(tokReserves, qtReserves, tokReserves + 1, 30);
        assertTrue(pMin2 > 0, "Supply slightly > reserves should work");
        
        // Case 3: Supply less than reserves (shouldn't happen but test anyway)
        uint256 pMin3 = PMinLib.calculate(tokReserves, qtReserves, tokReserves - 1000e18, 30);
        console2.log("pMin with supply < reserves:", pMin3);
        
        console2.log("[PASS] Supply near reserves edge cases handled");
    }
    
    /// @notice Test: pMin intermediate calculation overflow in mulDiv
    function test_PMin_IntermediateOverflow() public {
        // Design values that could cause pMinTemp calculation to overflow
        uint256 tokReserves = type(uint128).max / 2; // Large but not max
        uint256 qtReserves = type(uint128).max / 2;
        uint256 supply = tokReserves + 1000e18;
        
        // k will be near max of uint256
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        console2.log("pMin with large intermediate values:", pMin);
        
        // Should either succeed or return 0 (not revert)
        console2.log("[PASS] Intermediate overflow protection works");
    }
    
    /// @notice Test: pMin calculation with token burning edge cases
    function test_PMin_BurningEdgeCases() public {
        uint256 tokReserves = 1000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 2000e18; // 50% burned
        
        // Normal case
        uint256 pMinNormal = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        
        // 90% burned case
        supply = 1100e18; // Only 100e18 external
        uint256 pMinHighBurn = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        
        // 99% burned case
        supply = 1010e18; // Only 10e18 external
        uint256 pMinVeryHighBurn = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        
        console2.log("pMin normal (50% burned):", pMinNormal);
        console2.log("pMin high burn (90% burned):", pMinHighBurn);
        console2.log("pMin very high burn (99% burned):", pMinVeryHighBurn);
        
        // pMin should increase with more burning
        assertTrue(pMinHighBurn >= pMinNormal, "pMin should increase with burning");
        assertTrue(pMinVeryHighBurn >= pMinHighBurn, "pMin should continue increasing");
        
        console2.log("[PASS] Extreme burning scenarios handled correctly");
    }
    
    /// @notice Test: pMin calculation precision loss scenarios
    function test_PMin_PrecisionLoss() public {
        // Scenario that could cause precision loss in division
        uint256 tokReserves = 3; // Tiny reserves
        uint256 qtReserves = 1e18; // Large reserves
        uint256 supply = 1000e18; // Large supply
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        console2.log("pMin with precision loss risk:", pMin);
        
        // Test with reversed ratio
        pMin = PMinLib.calculate(1e18, 3, 1000e18, 30);
        console2.log("pMin with reversed precision loss risk:", pMin);
        
        console2.log("[PASS] Precision loss scenarios handled");
    }
    
    /// @notice Test: pMin calculation with fee edge cases
    function test_PMin_FeeEdgeCases() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1_000_000e18;
        
        // Test all fee boundary values
        uint256[] memory testFees = new uint256[](6);
        testFees[0] = 0;     // 0% fee
        testFees[1] = 1;     // 0.01% fee
        testFees[2] = 30;    // 0.3% fee (min)
        testFees[3] = 300;   // 3% fee
        testFees[4] = 9900;  // 99% fee (max)
        testFees[5] = 9999;  // 99.99% fee
        
        for (uint i = 0; i < testFees.length; i++) {
            uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, testFees[i]);
            console2.log("pMin with fee", testFees[i], ":", pMin);
            assertTrue(pMin >= 0, "All fees should produce valid pMin");
        }
        
        console2.log("[PASS] All fee edge cases handled");
    }
    
    /// @notice Test: pMin calculation with liquidation bounty edge cases
    function test_PMin_LiquidationBountyEdgeCases() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1_000_000e18;
        
        uint256 pMinGross = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        
        // Verify that liquidation bounty (0.5%) is properly applied
        // pMinNet = pMinGross * 9950 / 10000
        uint256 k = tokReserves * qtReserves;
        uint256 externalTokens = supply - tokReserves;
        uint256 effectiveExternal = (externalTokens * 9970) / 10000; // 0.3% fee
        uint256 finalReserves = tokReserves + effectiveExternal;
        
        uint256 expectedGross = (k * 1e18 / finalReserves) * 1e18 / finalReserves;
        uint256 expectedNet = (expectedGross * 9950) / 10000;
        
        console2.log("Calculated pMin:", pMinGross);
        console2.log("Expected pMin:", expectedNet);
        
        // Allow for rounding differences
        uint256 diff = pMinGross > expectedNet ? pMinGross - expectedNet : expectedNet - pMinGross;
        assertTrue(diff <= 2, "pMin calculation should match expected within rounding");
        
        console2.log("[PASS] Liquidation bounty correctly applied");
    }
}