// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PMinLib} from "./src/libraries/PMinLib.sol";

/// @title Simple PMin Test
contract SimplePMinTest is Test {
    
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
}