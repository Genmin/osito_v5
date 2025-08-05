// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solady/tokens/ERC20.sol";
import {OsitoToken} from "../core/OsitoToken.sol";
import {OsitoPair} from "../core/OsitoPair.sol";
import {FeeRouter} from "../core/FeeRouter.sol";

/// @notice Permissionless token + pair creation
/// @dev NO Ownable - anyone can launch
contract OsitoLaunchpad {
    address public immutable weth;
    address public immutable treasury;
    
    event TokenLaunched(
        address indexed token,
        address indexed pair,
        address indexed feeRouter,
        string name,
        string symbol,
        uint256 supply
    );
    
    constructor(address _weth, address _treasury) {
        weth = _weth;
        treasury = _treasury;
    }
    
    /// @notice Create token + pair in single tx - PURE ERC20 WETH PATH
    /// @dev Fully permissionless - no restrictions, caller must have WETH
    function launchToken(
        string memory name,
        string memory symbol,
        uint256 supply,
        uint256 wethAmount,
        uint256 startFeeBps,
        uint256 endFeeBps,
        uint256 feeDecayTarget
    ) external returns (address token, address pair, address feeRouter) {
        require(startFeeBps >= endFeeBps, "INVALID_FEE_RANGE");
        
        // Create pair first (will receive all tokens)
        pair = address(new OsitoPair(
            address(0), // token0 placeholder
            weth,       // token1 is always WETH
            address(0), // feeRouter placeholder (will be set after)
            startFeeBps,
            endFeeBps,
            feeDecayTarget,
            true        // tokIsToken0 = true
        ));
        
        // Create FeeRouter with pair address
        feeRouter = address(new FeeRouter(treasury, pair));
        
        // Set feeRouter in pair (needs separate setter since circular dependency)
        OsitoPair(pair).setFeeRouter(feeRouter);
        
        // Create token and mint entire supply to pair
        token = address(new OsitoToken(name, symbol, supply, pair));
        
        // Set token0 in pair and update initialSupply
        OsitoPair(pair).initialize(token);
        
        // Transfer WETH to pair
        ERC20(weth).transferFrom(msg.sender, pair, wethAmount);
        
        // CRITICAL: Mint LP tokens to address(0) - ETERNAL LIQUIDITY LOCK
        OsitoPair(pair).mint(address(0));
        
        emit TokenLaunched(token, pair, feeRouter, name, symbol, supply);
    }
}