// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

contract PMinLibTest is BaseTest {
    using PMinLib for *;
    
    uint256 constant WAD = 1e18;
    uint256 constant BASIS_POINTS = 10000;
    
    function test_Calculate_ZeroSupply() public {
        uint256 pMin = PMinLib.calculate(1000e18, 100e18, 0, 30);
        assertEq(pMin, 0);
    }
    
    function test_Calculate_AllTokensInPool() public {
        uint256 tokReserves = 1000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1000e18;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, 30);
        
        // When all tokens are in pool, pMin should be spot price minus liquidation bounty
        uint256 spotPrice = (qtReserves * WAD) / tokReserves; // 0.1 ETH per token
        uint256 expectedPMin = (spotPrice * 9950) / 10000; // 0.5% liquidation bounty
        
        assertEq(pMin, expectedPMin);
    }
    
    function test_Calculate_HalfTokensInPool() public {
        uint256 tokReserves = 500e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1000e18;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, feeBps);
        
        // Calculate expected pMin manually
        uint256 k = tokReserves * qtReserves;
        uint256 tokToSwap = supply - tokReserves; // 500e18
        uint256 effectiveSwap = (tokToSwap * (BASIS_POINTS - feeBps)) / BASIS_POINTS;
        uint256 xFinal = tokReserves + effectiveSwap;
        uint256 pMinGross = (k * WAD / xFinal) * WAD / xFinal;
        uint256 expectedPMin = (pMinGross * 9950) / 10000;
        
        assertEq(pMin, expectedPMin);
    }
    
    function test_Calculate_VaryingFees() public {
        uint256 tokReserves = 600e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1000e18;
        
        // Test with different fee levels
        uint256 pMin1 = PMinLib.calculate(tokReserves, qtReserves, supply, 9900); // 99% fee
        uint256 pMin2 = PMinLib.calculate(tokReserves, qtReserves, supply, 30); // 0.3% fee
        
        // Lower fees should result in lower pMin (more tokens can be swapped)
        assertTrue(pMin1 > pMin2);
    }
    
    function test_PMinIncreasesWithBurns() public {
        uint256 tokReserves = 500e18;
        uint256 qtReserves = 100e18;
        uint256 initialSupply = 1000e18;
        uint256 feeBps = 30;
        
        uint256 pMinBefore = PMinLib.calculate(tokReserves, qtReserves, initialSupply, feeBps);
        
        // Simulate burning 100 tokens (reducing supply)
        uint256 newSupply = initialSupply - 100e18;
        uint256 pMinAfter = PMinLib.calculate(tokReserves, qtReserves, newSupply, feeBps);
        
        // pMin should increase when supply decreases
        assertTrue(pMinAfter > pMinBefore);
    }
    
    function test_PMinIncreasesWithFees() public {
        uint256 tokReserves = 500e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1000e18;
        uint256 feeBps = 30;
        
        uint256 k1 = tokReserves * qtReserves;
        uint256 pMin1 = PMinLib.calculate(tokReserves, qtReserves, supply, feeBps);
        
        // Simulate fee accumulation (k increases)
        uint256 newTokReserves = 510e18;
        uint256 newQtReserves = (k1 * 105) / (100 * newTokReserves); // 5% increase in k
        uint256 pMin2 = PMinLib.calculate(newTokReserves, newQtReserves, supply, feeBps);
        
        // pMin should increase when k increases
        assertTrue(pMin2 > pMin1);
    }
    
    // Fuzz tests
    function testFuzz_Calculate(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 supply,
        uint256 feeBps
    ) public {
        // Bound inputs to realistic ranges
        tokReserves = bound(tokReserves, 1000e18, 1e27);
        
        // For a new token, qtReserves should be much smaller than tokReserves
        // This represents realistic initial liquidity (e.g., 100 ETH for 1M tokens)
        qtReserves = bound(qtReserves, 1e16, tokReserves / 1000);
        
        supply = bound(supply, tokReserves, tokReserves * 10); // Supply >= reserves
        feeBps = bound(feeBps, 0, 9900); // 0% to 99%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, feeBps);
        
        // Skip test if pMin is 0 (edge case)
        if (pMin == 0) return;
        
        if (supply == tokReserves) {
            // All tokens in pool case
            uint256 spotPrice = (qtReserves * WAD) / tokReserves;
            uint256 expectedPMin = (spotPrice * 9950) / 10000;
            assertApproxEqRel(pMin, expectedPMin, 1e15, "pMin should match spot - bounty");
        } else {
            // pMin should be positive and less than spot price
            uint256 spotPrice = (qtReserves * WAD) / tokReserves;
            assertTrue(pMin > 0);
            assertTrue(pMin < spotPrice);
        }
    }
    
    function testFuzz_MonotonicWithBurns(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 supply,
        uint256 burnAmount,
        uint256 feeBps
    ) public {
        // Setup realistic bounds
        tokReserves = bound(tokReserves, 1000e18, 1e25);
        
        // Ensure realistic price range
        qtReserves = bound(qtReserves, 1e16, tokReserves / 1000);
        
        supply = bound(supply, tokReserves, tokReserves * 10);
        burnAmount = bound(burnAmount, 0, supply - tokReserves); // Can't burn pool tokens
        feeBps = bound(feeBps, 0, 9900);
        
        uint256 pMinBefore = PMinLib.calculate(tokReserves, qtReserves, supply, feeBps);
        
        // Skip test if pMinBefore is 0
        if (pMinBefore == 0) return;
        
        uint256 pMinAfter = PMinLib.calculate(tokReserves, qtReserves, supply - burnAmount, feeBps);
        
        if (burnAmount > 0) {
            assertTrue(pMinAfter >= pMinBefore, "pMin must not decrease with burns");
        } else {
            assertEq(pMinAfter, pMinBefore, "pMin unchanged without burns");
        }
    }
}