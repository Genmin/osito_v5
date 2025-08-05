// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Constants}        from "./Constants.sol";

/// @notice EXACT pMin formula for maximum borrowing efficiency
/// @dev Implements: pMin = K / xFinal² × (1 - bounty)
library PMinLib {
    using FixedPointMathLib for uint256;

    /// @notice Calculate pMin using the EXACT formula for maximum efficiency
    /// @param tokReserves Current TOK reserves in the AMM (x)
    /// @param qtReserves Current QT reserves in the AMM (y)
    /// @param tokTotalSupply Total supply of TOK tokens (S)
    /// @param feeBps Current swap fee in basis points
    /// @return pMin The minimum achievable price with maximum borrowing efficiency
    function calculate(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 tokTotalSupply,
        uint256 feeBps
    ) internal pure returns (uint256 pMin) {
        if (tokTotalSupply == 0) return 0;
        
        // Edge case: all tokens already in pool
        if (tokReserves >= tokTotalSupply) {
            // Spot price with bounty haircut
            uint256 spotPrice = FixedPointMathLib.mulDiv(qtReserves, Constants.WAD, tokReserves);
            return FixedPointMathLib.mulDiv(spotPrice, 
                Constants.BASIS_POINTS - Constants.LIQ_BOUNTY_BPS, 
                Constants.BASIS_POINTS);
        }
        
        // Calculate xFinal: tokens in pool after everyone dumps with fees
        uint256 k = tokReserves * qtReserves;
        uint256 tokToSwap = tokTotalSupply - tokReserves;
        uint256 effectiveSwapAmount = FixedPointMathLib.mulDiv(tokToSwap, 
            Constants.BASIS_POINTS - feeBps, Constants.BASIS_POINTS);
        uint256 xFinal = tokReserves + effectiveSwapAmount;
        
        // Check for overflow in k calculation
        if (k / tokReserves != qtReserves) return 0; // Overflow detected
        
        // EXACT formula: k / xFinal²
        // Calculate as: (k / xFinal) / xFinal to avoid overflow
        uint256 pMinGross = FixedPointMathLib.mulDiv(k, Constants.WAD, xFinal);
        pMinGross = FixedPointMathLib.mulDiv(pMinGross, Constants.WAD, xFinal);
        
        // Apply liquidation bounty haircut
        return FixedPointMathLib.mulDiv(pMinGross, 
            Constants.BASIS_POINTS - Constants.LIQ_BOUNTY_BPS, 
            Constants.BASIS_POINTS);
    }
}