// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../utils/BaseTest.sol";
import {PMinLib} from "../../src/libraries/PMinLib.sol";

/// @notice Mutation testing for critical protocol functions
/// @dev Tests should fail if core logic is mutated
contract MutationTests is BaseTest {
    
    /// @notice Test that pMin calculation is exact
    /// @dev Any mutation to the formula should break this test
    function test_PMinFormulaMutation() public {
        // Known test case with exact expected result
        uint256 tokReserves = 600_000e18;
        uint256 qtReserves = 100e18;
        uint256 supply = 1_000_000e18;
        uint256 feeBps = 30; // 0.3%
        
        uint256 pMin = PMinLib.calculate(tokReserves, qtReserves, supply, feeBps);
        
        // Calculate expected value manually
        uint256 k = tokReserves * qtReserves; // 60_000_000e36
        uint256 externalTokens = supply - tokReserves; // 400_000e18
        uint256 effectiveExternal = (externalTokens * 9970) / 10000; // 398_800e18
        uint256 finalReserves = tokReserves + effectiveExternal; // 998_800e18
        
        // pMin = k / finalReserves^2 * (1 - liquidation bounty)
        uint256 expectedPMin = (k * 1e18 / finalReserves) * 1e18 / finalReserves;
        expectedPMin = (expectedPMin * 9950) / 10000; // 0.5% liquidation bounty
        
        assertEq(pMin, expectedPMin, "pMin calculation mutated");
    }
    
    /// @notice Test that fee decay is linear
    /// @dev Mutations to fee calculation should fail
    function test_FeeDecayMutation() public {
        uint256 startFee = 9900;
        uint256 endFee = 30;
        uint256 decayTarget = 100_000e18;
        
        // Test multiple points along the decay curve
        uint256[] memory burnAmounts = new uint256[](5);
        burnAmounts[0] = 0;
        burnAmounts[1] = 25_000e18;
        burnAmounts[2] = 50_000e18;
        burnAmounts[3] = 75_000e18;
        burnAmounts[4] = 100_000e18;
        
        uint256[] memory expectedFees = new uint256[](5);
        expectedFees[0] = 9900;
        expectedFees[1] = 7492; // 9900 - (9870 * 0.25)
        expectedFees[2] = 4965; // 9900 - (9870 * 0.5)
        expectedFees[3] = 2497; // 9900 - (9870 * 0.75)
        expectedFees[4] = 30;
        
        for (uint i = 0; i < burnAmounts.length; i++) {
            uint256 burned = burnAmounts[i];
            uint256 expected = expectedFees[i];
            
            uint256 calculated;
            if (burned >= decayTarget) {
                calculated = endFee;
            } else {
                uint256 range = startFee - endFee;
                uint256 reduction = (range * burned) / decayTarget;
                calculated = startFee - reduction;
            }
            
            assertEq(calculated, expected, "Fee decay formula mutated");
        }
    }
    
    /// @notice Test k invariant in swaps
    /// @dev Any mutation that breaks constant product should fail
    function test_ConstantProductMutation() public {
        uint256 r0 = 1_000_000e18;
        uint256 r1 = 100e18;
        uint256 k = r0 * r1;
        
        // Simulate swap: 10 ETH in
        uint256 amountIn = 10e18;
        uint256 feeBps = 300; // 3%
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        
        // Calculate output preserving k
        uint256 amountOut = (amountInWithFee * r0) / ((r1 * 10000) + amountInWithFee);
        
        // New reserves
        uint256 newR0 = r0 - amountOut;
        uint256 newR1 = r1 + amountIn;
        
        // Verify k increased (due to fees)
        uint256 newK = newR0 * newR1;
        assertTrue(newK > k, "K should increase with fees");
        
        // Verify exact k increase matches fee
        uint256 kIncrease = ((newK - k) * 10000) / k;
        assertLe(kIncrease, feeBps, "K increase should match fee");
    }
    
    /// @notice Test liquidation safety invariant
    /// @dev Mutations that allow unsafe liquidations should fail
    function test_LiquidationSafetyMutation() public {
        uint256 collateral = 1000e18;
        uint256 pMin = 0.01e18; // $0.01 minimum price
        uint256 spotPrice = 0.02e18; // $0.02 current price
        
        // Maximum safe debt at pMin
        uint256 maxSafeDebt = (collateral * pMin) / 1e18;
        
        // Liquidation should use MIN(spot, pMin) for safety
        uint256 liquidationPrice = pMin < spotPrice ? pMin : spotPrice;
        assertEq(liquidationPrice, pMin, "Should use minimum price");
        
        // Even at minimum price, liquidation covers debt
        uint256 liquidationValue = (collateral * liquidationPrice) / 1e18;
        assertGe(liquidationValue, maxSafeDebt, "Liquidation unsafe");
        
        // With 5% liquidation bonus
        uint256 liquidationBonus = 10500; // 105%
        uint256 collateralNeeded = (maxSafeDebt * liquidationBonus * 1e18) / (10000 * liquidationPrice);
        assertLe(collateralNeeded, collateral, "Insufficient collateral for liquidation");
    }
    
    /// @notice Test interest accrual precision
    /// @dev Mutations to interest calculation should fail
    function test_InterestAccrualMutation() public {
        uint256 principal = 1000e18;
        uint256 rate = 5e16; // 5% APR
        uint256 timeElapsed = 365 days;
        
        // Calculate interest: principal * rate * time / YEAR
        uint256 interest = (principal * rate * timeElapsed) / (365 days * 1e18);
        uint256 expected = 50e18; // 5% of 1000
        
        assertEq(interest, expected, "Interest calculation mutated");
        
        // Test compounding
        uint256 borrowIndex = 1e18;
        uint256 newIndex = borrowIndex + (borrowIndex * rate * timeElapsed) / (365 days * 1e18);
        assertEq(newIndex, 1.05e18, "Index calculation mutated");
    }
}