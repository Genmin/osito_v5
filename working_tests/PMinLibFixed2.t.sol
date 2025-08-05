// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

/// @title PMinLib Unit Tests - Fixed Version
contract PMinLibFixed2Test is Test {
    
    /// @notice Test basic pMin calculation
    function test_PMinCalculation_Basic() public {
        // Test case from SPEC.MD example
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        
        console2.log("tokReserves:", tokReserves);
        console2.log("qtReserves:", qtReserves);
        console2.log("totalSupply:", totalSupply);
        console2.log("External tokens:", totalSupply - tokReserves);
        console2.log("Calculated pMin:", pMin);
        
        // Calculate expected values
        uint256 spotPrice = qtReserves * 1e18 / tokReserves;
        console2.log("Current spot price:", spotPrice);
        
        // Verify pMin is positive
        assertTrue(pMin > 0, "pMin should be positive");
    }
    
    /// @notice Test pMin monotonicity property
    function test_PMinMonotonicity() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18;
        uint256 feeBps = 30;
        
        // Test burning in steps
        uint256 pMin1 = PMinLib.calculate(tokReserves, qtReserves, totalSupply, feeBps);
        uint256 pMin2 = PMinLib.calculate(tokReserves, qtReserves, totalSupply - 50_000e18, feeBps);
        uint256 pMin3 = PMinLib.calculate(tokReserves, qtReserves, totalSupply - 100_000e18, feeBps);
        uint256 pMin4 = PMinLib.calculate(tokReserves, qtReserves, totalSupply - 200_000e18, feeBps);
        
        console2.log("pMin with 0 burn:", pMin1);
        console2.log("pMin with 50k burn:", pMin2);
        console2.log("pMin with 100k burn:", pMin3);
        console2.log("pMin with 200k burn:", pMin4);
        
        assertTrue(pMin2 >= pMin1, "pMin should increase with burns");
        assertTrue(pMin3 >= pMin2, "pMin should continue increasing");
        assertTrue(pMin4 >= pMin3, "pMin should continue increasing");
    }
    
    /// @notice Test pMin with different fee levels
    function test_PMinFeeLevels() public {
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18;
        
        // Test various fee levels
        uint256 pMin30 = PMinLib.calculate(tokReserves, qtReserves, totalSupply, 30);      // 0.3%
        uint256 pMin300 = PMinLib.calculate(tokReserves, qtReserves, totalSupply, 300);    // 3%
        uint256 pMin3000 = PMinLib.calculate(tokReserves, qtReserves, totalSupply, 3000);  // 30%
        uint256 pMin9900 = PMinLib.calculate(tokReserves, qtReserves, totalSupply, 9900);  // 99%
        
        console2.log("pMin with 0.3% fee:", pMin30);
        console2.log("pMin with 3% fee:", pMin300);
        console2.log("pMin with 30% fee:", pMin3000);
        console2.log("pMin with 99% fee:", pMin9900);
        
        // Higher fees = less external tokens can swap = higher pMin
        assertTrue(pMin300 > pMin30, "Higher fee should mean higher pMin");
        assertTrue(pMin3000 > pMin300, "Higher fee should mean higher pMin");
        assertTrue(pMin9900 > pMin3000, "Higher fee should mean higher pMin");
    }
    
    /// @notice Test edge case: all tokens in pool
    function test_AllTokensInPool() public {
        uint256 tokReserves = 1_000_000e18;
        uint256 qtReserves = 100e18;
        uint256 totalSupply = 1_000_000e18; // All tokens in pool
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, totalSupply, 30);
        uint256 spotPrice = qtReserves * 1e18 / tokReserves;
        uint256 expectedPMin = spotPrice * 9950 / 10000; // 0.5% liquidation bounty
        
        console2.log("Spot price:", spotPrice);
        console2.log("Expected pMin:", expectedPMin);
        console2.log("Actual pMin:", pMin);
        
        assertEq(pMin, expectedPMin, "pMin should be spot price minus bounty");
    }
    
    /// @notice Test extreme values
    function test_ExtremeValues() public {
        // Test 1: Very small reserves
        uint256 pMin1 = PMinLib.calculate(1e18, 1e15, 2e18, 30);
        console2.log("pMin with tiny reserves:", pMin1);
        
        // Test 2: Very large reserves (but safe from overflow)
        uint256 pMin2 = PMinLib.calculate(1e30, 1e28, 2e30, 30);
        console2.log("pMin with large reserves:", pMin2);
        
        // Test 3: Maximum safe UniV2 reserves
        uint256 maxReserve = type(uint112).max;
        uint256 pMin3 = PMinLib.calculate(maxReserve, maxReserve / 1000, maxReserve + 1e18, 30);
        console2.log("pMin with max safe reserves:", pMin3);
    }
}