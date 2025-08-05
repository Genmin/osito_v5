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
    uint256 public principalLp;  // Track principal LP separately from fees
    
    event FeesCollected(uint256 tokBurned, uint256 qtCollected);
    event Initialized(address pair, uint256 reserve0, uint256 reserve1);
    
    constructor(address _treasury) {
        treasury = _treasury;
        factory = msg.sender;
    }

    /// @notice Initialize with pair address and principal LP amount
    function setPrincipalLp(address _pair) external {
        require(msg.sender == factory, "ONLY_FACTORY");
        require(pair == address(0), "ALREADY_SET");
        pair = _pair;
        
        // Store the initial LP balance as principal - this should never be burned
        principalLp = OsitoPair(_pair).balanceOf(address(this));
        
        emit Initialized(_pair, principalLp, 0);
    }
    
    /// @notice Collect fees using canonical UniV2 fee-on pattern
    /// @dev Anyone can call - only burns fee LP, never principal
    function collectFees() external nonReentrant {
        OsitoPair p = OsitoPair(pair);
        
        // 1. Trigger _mintFee() with sacrificial 1 wei burn
        if (p.kLast() != 0) {
            uint256 lpBalance = p.balanceOf(address(this));
            require(lpBalance > principalLp, "NO_LP_TO_SACRIFICE");
            p.transfer(pair, 1);
            p.burn(address(this));  // Direct call - will revert if burn fails
        }
        
        // 2. Compute EXCESS LP over principal
        uint256 lpBal = p.balanceOf(address(this));
        if (lpBal <= principalLp) return;  // No fees to collect
        uint256 feeLp = lpBal - principalLp;
        
        // 3. Burn ONLY the fee LP (never touch principal)
        p.transfer(pair, feeLp);
        (uint256 a0, uint256 a1) = p.burn(address(this));
        
        // 4. Split outputs: 100% TOK burned, 100% QT to treasury
        bool is0Tok = p.tokIsToken0();
        (uint256 tokAmt, uint256 qtAmt) = is0Tok ? (a0, a1) : (a1, a0);
        
        // Burn all TOK received from fees
        if (tokAmt > 0) {
            OsitoToken(is0Tok ? p.token0() : p.token1()).burn(tokAmt);
        }
        
        // Send all QT to treasury
        if (qtAmt > 0) {
            (is0Tok ? p.token1() : p.token0()).safeTransfer(treasury, qtAmt);
        }
        
        emit FeesCollected(tokAmt, qtAmt);
    }
}