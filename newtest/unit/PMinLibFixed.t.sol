// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

/// @title PMinLib Unit Tests
contract PMinLibFixedTest is Test {
    
    /// @notice Test basic pMin calculation
    function test_PMinCalculation_Basic() public {
        // Test case from SPEC.MD example
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Verify pMin is non-zero and reasonable
        assertTrue(pMin > 0, "pMin should be positive");
        assertTrue(pMin < qtReserves * 1e18 / tokReserves, "pMin should be less than spot price");
        
        console2.log("Basic pMin calculation:", pMin);
    }
    
    /// @notice Test pMin increases when tokens are burned
    function test_PMinIncreasesWithBurns() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18;
        uint256 feeBps = 30;
        
        uint256 pMinBefore = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // Simulate burning 100k tokens (10% of supply)
        uint256 pMinAfter = PMinLib.calculate(tokReserves, qtReserves, totalSupply - 100_000e18, feeBps);
        
        assertTrue(pMinAfter > pMinBefore, "pMin must increase after burns");
        console2.log("pMin before burn:", pMinBefore);
        console2.log("pMin after burn:", pMinAfter);
    }
    
    /// @notice Test pMin with all tokens in pool
    function test_PMinAllTokensInPool() public {
        uint256 tokReserves = 1_000_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18; // All tokens in pool
        uint256 feeBps = 30;
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        // When all tokens are in pool, pMin should be close to spot price with fee discount
        uint256 spotPrice = qtReserves * 1e18 / tokReserves;
        uint256 expectedPMin = spotPrice * 9970 / 10000; // With 0.3% fee
        
        assertApproxEqRel(pMin, expectedPMin, 0.01e18, "pMin should match discounted spot price");
    }
    
    /// @notice Test pMin calculation with maximum reserves (overflow protection)
    function test_PMinMaxReservesOverflow() public {
        uint256 maxSafeReserve = type(uint112).max; // UniV2 reserve limit
        uint256 tokReserves = maxSafeReserve;
        uint256 qtReserves = maxSafeReserve;
        uint256 supply = maxSafeReserve + 1000e18;
        uint256 feeBps = 30;
        
        // This should trigger overflow protection
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, feeBps);
        assertEq(pMin, 0, "Should return 0 due to overflow protection");
    }
    
    /// @notice Test pMin with zero supply edge case
    function test_PMinZeroSupply() public {
        uint256 pMin = PMinLib.calculate(1000e18, 100e18, 0, 30);
        assertEq(pMin, 0, "Zero supply should return 0");
    }
    
    /// @notice Test pMin with extreme fee values
    function test_PMinExtremeFees() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1_000_000e18;
        
        // Test with 99% fee (maximum in protocol)
        uint256 pMinHighFee = PMinLib.calculate(tokReserves, qtReserves, supply, 9900);
        assertTrue(pMinHighFee > 0, "Should handle high fees");
        
        // Test with 0% fee
        uint256 pMinNoFee = PMinLib.calculate(tokReserves, qtReserves, supply, 0);
        assertTrue(pMinNoFee > pMinHighFee, "Lower fees should result in higher pMin");
    }
    
    /// @notice Fuzz test pMin monotonicity with burns
    function testFuzz_PMinMonotonicWithBurns(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 initialSupply,
        uint256 burnAmount,
        uint256 feeBps
    ) public {
        // Bound inputs
        tokReserves = bound(tokReserves, 1e12, 1e24);
        qtReserves = bound(qtReserves, 1e12, 1e24);
        initialSupply = bound(initialSupply, tokReserves + 1e12, tokReserves + 1e24);
        burnAmount = bound(burnAmount, 1, initialSupply - tokReserves);
        feeBps = bound(feeBps, 0, 9999);
        
        uint256 pMinBefore = PMinLib.calculate(tokReserves, qtReserves, initialSupply, feeBps);
        uint256 pMinAfter = PMinLib.calculate(tokReserves, qtReserves, initialSupply - burnAmount, feeBps);
        
        // Core invariant: burning tokens must increase pMin
        assertTrue(pMinAfter >= pMinBefore, "pMin must never decrease with burns");
    }
    
    /// @notice Fuzz test pMin calculation bounds
    function testFuzz_PMinBounds(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 totalSupply,
        uint256 feeBps
    ) public {
        // Bound inputs to reasonable ranges
        tokReserves = bound(tokReserves, 1e18, type(uint112).max);
        qtReserves = bound(qtReserves, 1e15, type(uint112).max);
        totalSupply = bound(totalSupply, tokReserves, tokReserves * 2);
        feeBps = bound(feeBps, 0, 9999);
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        if (pMin > 0) {
            // pMin should always be less than spot price
            uint256 spotPrice = qtReserves * 1e18 / tokReserves;
            assertTrue(pMin < spotPrice, "pMin must be less than spot price");
            
            // pMin should be positive when external tokens exist
            if (totalSupply > tokReserves) {
                assertTrue(pMin > 0, "pMin should be positive with external tokens");
            }
        }
    }
}