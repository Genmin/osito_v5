// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {OsitoPair} from "./OsitoPair.sol";
import {OsitoToken} from "./OsitoToken.sol";

/// @notice Collects fees and burns tokens to increase pMin
/// @dev NO Ownable - fully permissionless, ONE per pair
contract FeeRouter is ReentrancyGuard {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;
    
    address public immutable treasury;
    address public immutable factory;
    address public pair;
    uint256 public principalLp;
    
    event FeesCollected(uint256 tokBurned, uint256 qtCollected);
    event PrincipalLpSet(uint256 amount);
    
    constructor(address _treasury) {
        treasury = _treasury;
        factory = msg.sender;
    }

    /// @notice Set principal LP (called once after initial mint)
    function setPrincipalLp(address _pair) external {
        require(msg.sender == factory, "ONLY_FACTORY");
        require(pair == address(0), "ALREADY_SET");
        pair = _pair;
        principalLp = OsitoPair(_pair).balanceOf(address(this));
        emit PrincipalLpSet(principalLp);
    }
    
    /// @notice Collect fees with reentrancy protection and LP floor
    /// @dev Anyone can call - permissionless fee collection
    function collectFees() external nonReentrant {
        uint256 lpBalance = OsitoPair(pair).balanceOf(address(this));
        
        if (lpBalance <= principalLp) return; // No fees to collect
        
        // Only collect excess LP above principal
        uint256 feeLp = lpBalance - principalLp;
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
        
        // QT (WETH) doesn't have burn - send to treasury
        // SUBTRACTION: Don't return QT to pair - this would shrink k
        if (qtAmount > 0) {
            qtToken.safeTransfer(treasury, qtAmount);
        }
        
        emit FeesCollected(tokAmount, qtAmount);
    }
}