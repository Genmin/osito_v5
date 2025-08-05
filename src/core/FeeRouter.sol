// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {OsitoPair} from "./OsitoPair.sol";
import {OsitoToken} from "./OsitoToken.sol";

/// @notice Collects fees and burns tokens to increase pMin
/// @dev NO Ownable - fully permissionless, ONE per pair
contract FeeRouter is ReentrancyGuard {
    using SafeTransferLib for address;
    
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
    
    /// @notice Collect fees using UniV2's _mintFee mechanism
    /// @dev Battle-tested logic that avoids deadlock
    function collectFees() external nonReentrant {
        OsitoPair pair_ = OsitoPair(pair);

        // ------------------------------------------------------------------- //
        // 1. Has k grown since last mint/burn?  If not, exit early            //
        // ------------------------------------------------------------------- //
        (uint112 r0, uint112 r1,) = pair_.getReserves();
        uint256 currentK  = uint256(r0) * uint256(r1);
        uint256 storedK   = pair_.kLast();          // 0 straight after launch

        if (storedK == 0 || currentK <= storedK) return;   // nothing to crystallise

        // ------------------------------------------------------------------- //
        // 2. Calculate EXACT minimum LP to satisfy burn requirements          //
        //    Must ensure: liquidity * balance / totalSupply > 0 for BOTH tokens //
        // ------------------------------------------------------------------- //
        uint256 totalSupply = pair_.totalSupply();
        uint256 bal0 = ERC20(pair_.token0()).balanceOf(address(pair_));
        uint256 bal1 = ERC20(pair_.token1()).balanceOf(address(pair_));
        
        // UniV2 burn requires: amt = (L * B) / S > 0 for both tokens
        // With integer division rounding down, this means: L * B >= S + 1
        // Therefore: L > S / min(B0, B1)
        // Using floor division + 1 ensures strict inequality
        uint256 minBalance = bal0 < bal1 ? bal0 : bal1;
        uint256 sacrificeAmount = (totalSupply / minBalance) + 1;
        
        require(pair_.balanceOf(address(this)) >= sacrificeAmount, "ROUTER_HAS_NO_LP");
        pair_.transfer(pair, sacrificeAmount);
        pair_.burn(address(this));                  // revert bubbles if impossible

        // ------------------------------------------------------------------- //
        // 3. Whatever is now above principalLp is pure fee‑LP – burn it       //
        // ------------------------------------------------------------------- //
        uint256 lpBal = pair_.balanceOf(address(this));
        if (lpBal <= principalLp) return;           // unlikely, but safe‑guard
        uint256 feeLp = lpBal - principalLp;

        pair_.transfer(pair, feeLp);                // send only fee‑LP
        (uint256 amt0, uint256 amt1) = pair_.burn(address(this));

        // ------------------------------------------------------------------- //
        // 4. Destroy TOK, route QT to treasury                                //
        // ------------------------------------------------------------------- //
        bool tokIs0     = pair_.tokIsToken0();
        address tokAddr = tokIs0 ? pair_.token0() : pair_.token1();
        address qtAddr  = tokIs0 ? pair_.token1() : pair_.token0();

        uint256 tokAmt  = tokIs0 ? amt0 : amt1;
        uint256 qtAmt   = tokIs0 ? amt1 : amt0;

        if (tokAmt > 0) OsitoToken(tokAddr).burn(tokAmt);
        if (qtAmt  > 0) qtAddr.safeTransfer(treasury, qtAmt);

        emit FeesCollected(tokAmt, qtAmt);
    }
}