// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice EXACT pMin calculation for mathematically guaranteed safe lending
/// @dev Implements: pMin = k / [x + (S-x)(1-f)]²
library PMinLib {
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BASIS_POINTS = 10000;
    uint256 internal constant LIQ_BOUNTY_BPS = 50; // 0.5%

    /// @notice Calculate minimum guaranteed price for liquidation safety
    /// @param tokReserves Current TOK reserves in AMM
    /// @param qtReserves Current QT reserves in AMM  
    /// @param tokTotalSupply Current total supply of TOK
    /// @param feeBps Current swap fee in basis points
    /// @return pMin Guaranteed minimum price
    function calculate(
        uint256 tokReserves,
        uint256 qtReserves,
        uint256 tokTotalSupply,
        uint256 feeBps
    ) internal pure returns (uint256 pMin) {
        if (tokTotalSupply == 0) return 0;
        
        // Edge case: all tokens in pool
        if (tokReserves >= tokTotalSupply) {
            uint256 spotPrice = qtReserves.mulDiv(WAD, tokReserves);
            return spotPrice.mulDiv(BASIS_POINTS - LIQ_BOUNTY_BPS, BASIS_POINTS);
        }
        
        // Overflow protection for k
        uint256 k;
        unchecked {
            k = tokReserves * qtReserves;
            if (k / tokReserves != qtReserves) return 0; // Overflow
        }
        
        uint256 tokToSwap = tokTotalSupply - tokReserves;
        uint256 effectiveSwap = tokToSwap.mulDiv(BASIS_POINTS - feeBps, BASIS_POINTS);
        uint256 xFinal = tokReserves + effectiveSwap;
        
        // Prevent division by zero or near-zero
        if (xFinal < 1e9) return 0;
        
        // pMin = k / xFinal² (scaled by WAD)
        // Split calculation to prevent overflow
        uint256 pMinTemp = k.mulDiv(WAD, xFinal);
        if (pMinTemp == 0) return 0;
        
        uint256 pMinGross = pMinTemp.mulDiv(WAD, xFinal);
        
        // Apply liquidation bounty discount
        return pMinGross.mulDiv(BASIS_POINTS - LIQ_BOUNTY_BPS, BASIS_POINTS);
    }
}