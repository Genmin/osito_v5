// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "../../../src/libraries/PMinLib.sol";

contract PMinLibTest is Test {
    
    // ============ Basic Calculation Tests ============
    
    function test_BasicCalculation() public pure {
        // Simple case: 50% tokens in pool, 50% outside
        uint256 tokReserve = 500_000 * 1e18;
        uint256 qtReserve = 1000 * 1e18;
        uint256 supply = 1_000_000 * 1e18;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // k = 500_000 * 1000 = 500_000_000
        // externalTok = 500_000
        // effectiveExternal = 500_000 * 0.997 = 498_500
        // totalEffective = 500_000 + 498_500 = 998_500
        // pMin = k / (totalEffective^2 / 1e18)
        
        assertTrue(pMin > 0, "pMin should be positive");
    }
    
    function test_AllTokensInPool() public pure {
        uint256 tokReserve = 1_000_000 * 1e18;
        uint256 qtReserve = 1000 * 1e18;
        uint256 supply = 1_000_000 * 1e18;
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // When all tokens are in pool, pMin = spot price
        uint256 spotPrice = (qtReserve * 1e18) / tokReserve;
        assertEq(pMin, spotPrice, "pMin should equal spot price when all tokens in pool");
    }
    
    function test_NoTokensInPool() public {
        uint256 tokReserve = 0;
        uint256 qtReserve = 1000 * 1e18;
        uint256 supply = 1_000_000 * 1e18;
        uint256 feeBps = 30;
        
        // Should revert with division by zero
        vm.expectRevert();
        PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
    }
    
    function test_HighFeeImpact() public pure {
        uint256 tokReserve = 500_000 * 1e18;
        uint256 qtReserve = 1000 * 1e18;
        uint256 supply = 1_000_000 * 1e18;
        
        uint256 pMinLowFee = PMinLib.calculate(tokReserve, qtReserve, supply, 30); // 0.3%
        uint256 pMinHighFee = PMinLib.calculate(tokReserve, qtReserve, supply, 9900); // 99%
        
        assertTrue(pMinHighFee > pMinLowFee, "Higher fee should result in higher pMin");
    }
    
    // ============ Edge Case Tests ============
    
    function test_MinimalReserves() public pure {
        uint256 tokReserve = 1;
        uint256 qtReserve = 1;
        uint256 supply = 1_000_000 * 1e18;
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // Should handle tiny reserves without overflow/underflow
        assertTrue(pMin == 0, "pMin should be effectively 0 with minimal reserves");
    }
    
    function test_MaximalValues() public pure {
        uint256 tokReserve = type(uint112).max;
        uint256 qtReserve = type(uint112).max;
        uint256 supply = type(uint112).max;
        uint256 feeBps = 10000; // 100%
        
        // Should not overflow
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        assertTrue(pMin > 0, "Should handle max values without overflow");
    }
    
    // ============ Fuzz Tests ============
    
    function testFuzz_Calculate(
        uint256 tokReserve,
        uint256 qtReserve,
        uint256 supply,
        uint256 feeBps
    ) public pure {
        // Bound inputs to reasonable ranges
        tokReserve = bound(tokReserve, 1, type(uint112).max);
        qtReserve = bound(qtReserve, 1, type(uint112).max);
        supply = bound(supply, tokReserve, type(uint128).max); // Supply >= tokReserve
        feeBps = bound(feeBps, 0, 10000);
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // Basic invariants
        assertTrue(pMin <= (qtReserve * 1e18) / tokReserve, "pMin should not exceed spot price");
        
        if (supply > tokReserve) {
            // If there are tokens outside the pool, pMin should be less than spot
            uint256 spotPrice = (qtReserve * 1e18) / tokReserve;
            assertTrue(pMin < spotPrice, "pMin should be less than spot when tokens exist outside pool");
        }
    }
    
    function testFuzz_MonotonicWithSupplyBurn(
        uint256 tokReserve,
        uint256 qtReserve,
        uint256 initialSupply,
        uint256 burnAmount
    ) public pure {
        tokReserve = bound(tokReserve, 1e18, type(uint112).max);
        qtReserve = bound(qtReserve, 1e18, type(uint112).max);
        initialSupply = bound(initialSupply, tokReserve, type(uint128).max);
        burnAmount = bound(burnAmount, 0, initialSupply - tokReserve);
        
        uint256 feeBps = 30;
        
        uint256 pMinBefore = PMinLib.calculate(tokReserve, qtReserve, initialSupply, feeBps);
        uint256 pMinAfter = PMinLib.calculate(tokReserve, qtReserve, initialSupply - burnAmount, feeBps);
        
        assertTrue(pMinAfter >= pMinBefore, "pMin should increase when supply burns");
    }
    
    function testFuzz_MonotonicWithKIncrease(
        uint256 tokReserve,
        uint256 qtReserve,
        uint256 supply,
        uint256 kMultiplier
    ) public pure {
        tokReserve = bound(tokReserve, 1e18, type(uint96).max);
        qtReserve = bound(qtReserve, 1e18, type(uint96).max);
        supply = bound(supply, tokReserve, type(uint128).max);
        kMultiplier = bound(kMultiplier, 100, 200); // 1x to 2x
        
        uint256 feeBps = 30;
        
        uint256 pMinBefore = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // Increase k by increasing both reserves proportionally
        uint256 newTokReserve = (tokReserve * kMultiplier) / 100;
        uint256 newQtReserve = (qtReserve * kMultiplier) / 100;
        
        uint256 pMinAfter = PMinLib.calculate(newTokReserve, newQtReserve, supply, feeBps);
        
        assertTrue(pMinAfter >= pMinBefore, "pMin should increase when k increases");
    }
    
    // ============ Precision Tests ============
    
    function test_PrecisionAt18Decimals() public pure {
        uint256 tokReserve = 123_456_789_012_345_678_901_234_567;
        uint256 qtReserve = 987_654_321_098_765_432_109;
        uint256 supply = 999_999_999_999_999_999_999_999_999;
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // Should maintain precision with large numbers
        assertTrue(pMin > 0, "Should maintain precision");
    }
    
    function test_RoundingBehavior() public pure {
        // Test that rounding doesn't cause unexpected behavior
        uint256 tokReserve = 3;
        uint256 qtReserve = 2;
        uint256 supply = 10;
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        
        // With such small numbers, we expect significant rounding
        assertTrue(pMin <= (qtReserve * 1e18) / tokReserve, "Rounding should not violate invariants");
    }
    
    // ============ Gas Tests ============
    
    function test_GasCalculation() public {
        uint256 tokReserve = 500_000 * 1e18;
        uint256 qtReserve = 1000 * 1e18;
        uint256 supply = 1_000_000 * 1e18;
        uint256 feeBps = 30;
        
        uint256 gasStart = gasleft();
        PMinLib.calculate(tokReserve, qtReserve, supply, feeBps);
        uint256 gasUsed = gasStart - gasleft();
        
        console2.log("Gas used for pMin calculation:", gasUsed);
        assertTrue(gasUsed < 5000, "Calculation should be gas efficient");
    }
}