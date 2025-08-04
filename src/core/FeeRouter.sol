// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {OsitoPair} from "./OsitoPair.sol";
import {OsitoToken} from "./OsitoToken.sol";

/// @notice Collects fees and burns tokens to increase pMin
/// @dev NO Ownable - fully permissionless
contract FeeRouter is ReentrancyGuard {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    
    mapping(address => uint256) public principalLp; // Track seed liquidity per pair

    /// @notice Set principal LP (called once after initial mint)
    function setPrincipalLp(address pair) external {
        require(principalLp[pair] == 0, "ALREADY_SET");
        principalLp[pair] = OsitoPair(pair).balanceOf(address(this));
    }
    
    /// @notice Collect fees with reentrancy protection and LP floor
    /// @dev Anyone can call - permissionless fee collection
    function collectFees(address pair) external nonReentrant {
        uint256 lpBalance = OsitoPair(pair).balanceOf(address(this));
        uint256 principal = principalLp[pair];
        
        if (lpBalance <= principal) return; // No fees to collect
        
        // Only collect excess LP above principal
        uint256 feeLp = lpBalance - principal;
        OsitoPair(pair).transfer(pair, feeLp);
        (uint256 amt0, uint256 amt1) = OsitoPair(pair).burn(address(this));
        
        bool tokIsToken0 = OsitoPair(pair).tokIsToken0();
        address tokToken = tokIsToken0 ? OsitoPair(pair).token0() : OsitoPair(pair).token1();
        address qtToken = tokIsToken0 ? OsitoPair(pair).token1() : OsitoPair(pair).token0();
        
        uint256 tokAmount = tokIsToken0 ? amt0 : amt1;
        uint256 qtAmount = tokIsToken0 ? amt1 : amt0;
        
        // CRITICAL: Burn TOK tokens to reduce supply S (increases pMin)
        if (tokAmount > 0) {
            OsitoToken(tokToken).burn(tokAmount);
        }
        
        // QT (WETH) doesn't have burn - send to treasury/dead address
        // SUBTRACTION: Don't return QT to pair - this would shrink k
        if (qtAmount > 0) {
            // WETH cannot be burned, send to dead address for now
            // In production, this should go to treasury
            qtToken.safeTransfer(0x000000000000000000000000000000000000dEaD, qtAmount);
        }
    }
}