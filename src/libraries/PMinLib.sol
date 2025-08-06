// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Constants}        from "./Constants.sol";

/// @notice Correct pMin formula for maximum borrowing safety
/// @dev Implements: pMin = (y - k/xFinal) / deltaX × (1 - bounty)
library PMinLib {
    using FixedPointMathLib for uint256;

    /// @notice Calculate pMin using the CORRECT average execution price formula
    /// @param tokReserves Current TOK reserves in the AMM (x)
    /// @param qtReserves Current QT reserves in the AMM (y)  
    /// @param tokTotalSupply Total supply of TOK tokens (S)
    /// @param feeBps Current swap fee in basis points
    /// @return pMin The average execution price if all external tokens were dumped
    function calculate(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 tokTotalSupply,
        uint256 feeBps
    ) internal pure returns (uint256 pMin) {
        // Early return: nothing outside pool
        if (tokTotalSupply <= tokReserves) return 0;
        
        // Calculate tokens to dump and effective amount after fees
        uint256 deltaX = tokTotalSupply - tokReserves;
        uint256 deltaXEff = FixedPointMathLib.mulDiv(deltaX, 
            Constants.BASIS_POINTS - feeBps, Constants.BASIS_POINTS);
        uint256 xFinal = tokReserves + deltaXEff;
        
        // Constant product k
        uint256 k = tokReserves * qtReserves;
        if (tokReserves != 0 && k / tokReserves != qtReserves) return 0; // Overflow guard
        
        // Quote reserve after dump: yFinal = k / xFinal
        // Using mulDiv to maintain precision
        uint256 yFinal = FixedPointMathLib.mulDiv(k, Constants.WAD, xFinal);
        yFinal = yFinal / Constants.WAD; // Convert back from WAD
        
        // No output case (should not happen in practice)
        if (qtReserves <= yFinal) return 0;
        
        // Quote tokens that come out
        uint256 deltaY = qtReserves - yFinal;
        
        // Average execution price: deltaY / deltaX
        uint256 pMinGross = FixedPointMathLib.mulDiv(deltaY, Constants.WAD, deltaX);
        
        // Apply liquidation bounty haircut (0.5%)
        return FixedPointMathLib.mulDiv(pMinGross, 
            Constants.BASIS_POINTS - Constants.LIQ_BOUNTY_BPS, 
            Constants.BASIS_POINTS);
    }
}