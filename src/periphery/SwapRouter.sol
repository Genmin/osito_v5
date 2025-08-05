// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import "../core/OsitoPair.sol";

interface IWBERA {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title SwapRouter
 * @notice Router for atomic BERA ↔ TOK swaps using existing OsitoPair contracts
 * @dev Composes over existing contracts with NO modifications required
 */
contract SwapRouter is ReentrancyGuard {
    using SafeTransferLib for address;
    
    address public immutable WBERA;
    
    error InsufficientOutputAmount();
    error ExcessiveInputAmount();
    error InsufficientETH();
    error TransferFailed();
    error InvalidPath();
    error SwapFailed();
    
    event SwapETHForTokens(
        address indexed pair,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );
    
    event SwapTokensForETH(
        address indexed pair,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );
    
    constructor(address _wbera) {
        WBERA = _wbera;
    }
    
    /**
     * @notice Swap exact BERA for TOK tokens
     * @param pair OsitoPair contract address
     * @param amountOutMin Minimum amount of TOK to receive
     * @param to Address to receive TOK tokens
     * @param deadline Transaction deadline (not enforced, for interface compatibility)
     */
    function swapExactETHForTokens(
        address pair,
        uint256 amountOutMin,
        address to,
        uint256 deadline // Not enforced for simplicity, but kept for interface compatibility
    ) external payable nonReentrant returns (uint256[] memory amounts) {
        if (msg.value == 0) revert InsufficientETH();
        
        OsitoPair ositoP = OsitoPair(pair);
        
        // Step 1: Wrap BERA to WBERA
        IWBERA(WBERA).deposit{value: msg.value}();
        
        // Step 2: Transfer WBERA to the pair
        IWBERA(WBERA).transfer(pair, msg.value);
        
        // Step 3: Calculate expected output and perform swap
        bool tokIsToken0 = ositoP.tokIsToken0();
        uint256 amountOut;
        
        if (tokIsToken0) {
            // TOK is token0, we're receiving TOK
            amountOut = _getAmountOut(pair, msg.value, false); // QT -> TOK
            if (amountOut < amountOutMin) revert InsufficientOutputAmount();
            ositoP.swap(amountOut, 0, to);
        } else {
            // TOK is token1, we're receiving TOK  
            amountOut = _getAmountOut(pair, msg.value, false); // QT -> TOK
            if (amountOut < amountOutMin) revert InsufficientOutputAmount();
            ositoP.swap(0, amountOut, to);
        }
        
        amounts = new uint256[](2);
        amounts[0] = msg.value;   // Amount of ETH in
        amounts[1] = amountOut;   // Amount of TOK out
        
        emit SwapETHForTokens(pair, msg.value, amountOut, to);
    }
    
    /**
     * @notice Swap exact TOK tokens for BERA
     * @param pair OsitoPair contract address
     * @param amountIn Amount of TOK to swap
     * @param amountOutMin Minimum amount of BERA to receive
     * @param to Address to receive BERA
     * @param deadline Transaction deadline (not enforced, for interface compatibility)
     */
    function swapExactTokensForETH(
        address pair,
        uint256 amountIn,
        uint256 amountOutMin,
        address to,
        uint256 deadline // Not enforced for simplicity, but kept for interface compatibility
    ) external nonReentrant returns (uint256[] memory amounts) {
        if (amountIn == 0) revert InsufficientOutputAmount();
        
        OsitoPair ositoP = OsitoPair(pair);
        address tokAddress = ositoP.tokIsToken0() ? ositoP.token0() : ositoP.token1();
        
        // Step 1: Transfer TOK from user to pair
        tokAddress.safeTransferFrom(msg.sender, pair, amountIn);
        
        // Step 2: Calculate expected WBERA output and perform swap
        bool tokIsToken0 = ositoP.tokIsToken0();
        uint256 wberaOut = _getAmountOut(pair, amountIn, true); // TOK -> QT
        if (wberaOut < amountOutMin) revert InsufficientOutputAmount();
        
        // Step 3: Swap TOK for WBERA (to this contract)
        if (tokIsToken0) {
            // TOK is token0, WBERA is token1
            ositoP.swap(0, wberaOut, address(this));
        } else {
            // WBERA is token0, TOK is token1
            ositoP.swap(wberaOut, 0, address(this));
        }
        
        // Step 4: Unwrap WBERA to BERA and send to recipient
        IWBERA(WBERA).withdraw(wberaOut);
        SafeTransferLib.safeTransferETH(to, wberaOut);
        
        amounts = new uint256[](2);
        amounts[0] = amountIn;    // Amount of TOK in
        amounts[1] = wberaOut;    // Amount of ETH out
        
        emit SwapTokensForETH(pair, amountIn, wberaOut, to);
    }
    
    /**
     * @notice Get amount out for a swap (uses the same logic as LensLite)
     * @param pair OsitoPair address
     * @param amountIn Input amount
     * @param tokIn True if swapping TOK for QT, false for QT to TOK
     */
    function _getAmountOut(address pair, uint256 amountIn, bool tokIn) internal view returns (uint256 amountOut) {
        OsitoPair ositoP = OsitoPair(pair);
        (uint112 r0, uint112 r1,) = ositoP.getReserves();
        bool tokIsToken0 = ositoP.tokIsToken0();
        uint112 rTOK = tokIsToken0 ? r0 : r1;
        uint112 rQT = tokIsToken0 ? r1 : r0;
        uint256 feeBps = ositoP.currentFeeBps();
        
        if (tokIn) {
            // TOK → QT
            amountOut = _calculateAmountOut(amountIn, rTOK, rQT, feeBps);
        } else {
            // QT → TOK
            amountOut = _calculateAmountOut(amountIn, rQT, rTOK, feeBps);
        }
    }
    
    /**
     * @notice Calculate output amount using UniswapV2 formula with fees
     */
    function _calculateAmountOut(
        uint256 amountIn, 
        uint112 reserveIn, 
        uint112 reserveOut, 
        uint256 feeBps
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "INSUFFICIENT_LIQUIDITY");
        
        // Standard Uniswap V2 formula with fees
        uint256 amountInWithFee = amountIn * (10000 - feeBps);
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 10000 + amountInWithFee;
        amountOut = numerator / denominator;
    }
    
    /**
     * @notice Get amounts out for display/estimation purposes
     * @param pair OsitoPair address
     * @param amountIn Input amount
     * @param tokIn True if swapping TOK for QT, false for QT to TOK
     */
    function getAmountOut(address pair, uint256 amountIn, bool tokIn) external view returns (uint256 amountOut) {
        return _getAmountOut(pair, amountIn, tokIn);
    }
    
    /**
     * @notice Get amounts out for a specific path (for frontend compatibility)
     * @param amountIn Input amount
     * @param path Array containing [inputToken, outputToken] - only 2 elements supported
     * @param pair OsitoPair address
     */
    function getAmountsOut(uint256 amountIn, address[] calldata path, address pair) 
        external view returns (uint256[] memory amounts) 
    {
        if (path.length != 2) revert InvalidPath();
        
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        
        OsitoPair ositoP = OsitoPair(pair);
        address tokAddress = ositoP.tokIsToken0() ? ositoP.token0() : ositoP.token1();
        
        bool tokIn = (path[0] == tokAddress);
        amounts[1] = _getAmountOut(pair, amountIn, tokIn);
    }
    
    // Required to receive ETH when unwrapping WBERA
    receive() external payable {
        // Only accept ETH from WBERA contract
        require(msg.sender == WBERA, "Only WBERA");
    }
}