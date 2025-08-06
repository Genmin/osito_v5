// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/libraries/PMinLib.sol";

contract PMinFixTest is Test {
    
    function test_FrobRegression() public {
        // FROB token actual values
        uint256 x = 237_000_000e18;  // 237M tokens in pool
        uint256 y = 5e18;             // 5 WBERA
        uint256 S = 1_000_000_000e18; // 1B total supply
        uint256 f = 1_500;            // 15% fee
        
        uint256 pMin = PMinLib.calculate(x, y, S, f);
        
        // Expected: ~4.775e-9 WBERA/TOK (with 0.5% haircut)
        // In wei: 4.775e-9 * 1e18 = 4775280898
        assertApproxEqAbs(pMin, 4775280898, 1e6, "FROB pMin should be ~4.775e-9");
        
        // Should NOT be the astronomical 1.5e9 from the old formula
        assertLt(pMin, 1e10, "pMin should be less than 10 gwei");
    }
    
    function test_AllTokensInPool() public {
        uint256 x = 1_000_000_000e18; // All tokens in pool
        uint256 y = 1e18;             // 1 WBERA
        uint256 S = 1_000_000_000e18; // Total supply
        uint256 f = 9_500;            // 95% fee
        
        uint256 pMin = PMinLib.calculate(x, y, S, f);
        
        // When all tokens are in pool, pMin should be 0
        assertEq(pMin, 0, "pMin should be 0 when all tokens in pool");
    }
    
    function test_NormalScenario() public {
        uint256 x = 500_000_000e18;  // 500M tokens (50% in pool)
        uint256 y = 1000e18;          // 1000 WBERA
        uint256 S = 1_000_000_000e18; // 1B total supply
        uint256 f = 300;              // 3% fee
        
        uint256 pMin = PMinLib.calculate(x, y, S, f);
        
        // Expected: ~9.798e-7 WBERA/TOK
        // In wei: ~979_847_715_735
        assertApproxEqRel(pMin, 979_847_715_735, 0.01e18, "Normal scenario pMin");
        
        // Should be less than spot price (2e-6)
        uint256 spotPrice = (y * 1e18) / x;
        assertLt(pMin, spotPrice, "pMin should be less than spot price");
    }
    
    function test_MinimalWBERA() public {
        uint256 x = 900_000_000e18;  // 900M tokens
        uint256 y = 0.001e18;         // 0.001 WBERA (very little)
        uint256 S = 1_000_000_000e18; // 1B total supply
        uint256 f = 300;              // 3% fee
        
        uint256 pMin = PMinLib.calculate(x, y, S, f);
        
        // Should be very small but not astronomical
        assertLt(pMin, 1e6, "pMin should not explode with low WBERA");
        assertGt(pMin, 0, "pMin should be positive");
    }
    
    function test_MonotonicWithBurns() public {
        uint256 x = 500_000_000e18; // Fixed pool reserves
        uint256 y = 1000e18;
        uint256 f = 300;
        
        // Test decreasing supply (simulating burns)
        uint256 lastPMin = 0;
        uint256[] memory supplies = new uint256[](5);
        supplies[0] = 1_000_000_000e18; // 1B
        supplies[1] = 800_000_000e18;   // 800M
        supplies[2] = 700_000_000e18;   // 700M
        supplies[3] = 600_000_000e18;   // 600M
        supplies[4] = 550_000_000e18;   // 550M
        
        for (uint i = 0; i < supplies.length; i++) {
            uint256 pMin = PMinLib.calculate(x, y, supplies[i], f);
            assertGe(pMin, lastPMin, "pMin should increase with burns");
            lastPMin = pMin;
        }
    }
    
    function test_LendingSafety() public {
        uint256 x = 300_000_000e18;  // 300M tokens
        uint256 y = 10e18;            // 10 WBERA
        uint256 S = 1_000_000_000e18; // 1B total supply
        uint256 f = 500;              // 5% fee
        
        uint256 pMin = PMinLib.calculate(x, y, S, f);
        
        // Verify lending safety
        uint256 collateral = 1_000_000e18; // 1M tokens
        uint256 maxBorrow = (collateral * pMin) / 1e18;
        
        // Calculate actual average price if all external tokens dump
        uint256 deltaX = S - x;
        uint256 deltaXEff = (deltaX * (10_000 - f)) / 10_000;
        uint256 xFinal = x + deltaXEff;
        uint256 k = x * y;
        uint256 yFinal = k / xFinal;
        uint256 deltaY = y - yFinal;
        uint256 avgPrice = (deltaY * 1e18) / deltaX;
        
        // Liquidation value should exceed max borrow
        uint256 liquidationValue = (collateral * avgPrice) / 1e18;
        assertGe(liquidationValue, maxBorrow, "Liquidation should cover debt");
    }
    
    function testFuzz_CorrectFormula(
        uint128 _x,
        uint128 _y,
        uint128 _S,
        uint16 _f
    ) public {
        // Reasonable bounds
        vm.assume(_x > 1e18 && _x < 1e30);
        vm.assume(_y > 1e15 && _y < 1e25); 
        vm.assume(_S > _x && _S < 1e31);
        vm.assume(_f <= 9_999);
        
        uint256 x = uint256(_x);
        uint256 y = uint256(_y);
        uint256 S = uint256(_S);
        uint256 f = uint256(_f);
        
        uint256 pMin = PMinLib.calculate(x, y, S, f);
        
        if (S > x) {
            // pMin should be positive when tokens exist outside pool
            assertGt(pMin, 0, "pMin should be positive");
            
            // pMin should be less than current spot price
            uint256 spotPrice = (y * 1e18) / x;
            assertLt(pMin, spotPrice, "pMin should be less than spot");
        } else {
            // pMin should be 0 when all tokens in pool
            assertEq(pMin, 0, "pMin should be 0 when S <= x");
        }
    }
}